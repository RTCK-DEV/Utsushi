import Foundation
import AVFoundation
import Accelerate

/// 動画・音声から 16kHz モノラル Float32 を取り出す。
/// ffmpeg を同梱しないので、配布物にGPL/LGPLが混ざらず、署名対象の実行ファイルも増えない。
public struct AudioExtractor: Sendable {

    public enum ExtractionError: LocalizedError {
        case noAudioTrack
        case readerFailed(String)
        case cancelled
        public var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "音声トラックが見つからない"
            case .readerFailed(let m): return "音声の読み出しに失敗: \(m)"
            case .cancelled: return "キャンセルされた"
            }
        }
    }

    public static let sampleRate: Double = 16_000

    public struct Result: Sendable {
        public var samples: [Float]
        public var duration: Double
        /// 100ms刻みの dBFS。監査層の無音ゲートが使う。
        public var envelope: [Float]
        public var envelopeHopSeconds: Double
    }

    public init() {}

    public func extract(url: URL,
                        progress: (@Sendable (Double) -> Void)? = nil,
                        isCancelled: (@Sendable () -> Bool)? = nil) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw ExtractionError.noAudioTrack }
        let duration = try await asset.load(.duration).seconds

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExtractionError.readerFailed("output を追加できない") }
        reader.add(output)
        guard reader.startReading() else {
            throw ExtractionError.readerFailed(reader.error?.localizedDescription ?? "startReading が失敗")
        }

        let hop = 0.1
        let hopSamples = Int(Self.sampleRate * hop)
        var samples: [Float] = []
        samples.reserveCapacity(Int(Self.sampleRate * max(duration, 1)))
        var envelope: [Float] = []
        var pending: [Float] = []
        pending.reserveCapacity(hopSamples)

        while let buffer = output.copyNextSampleBuffer() {
            if isCancelled?() == true { reader.cancelReading(); throw ExtractionError.cancelled }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                    totalLengthOut: &length, dataPointerOut: &dataPointer)
            guard status == kCMBlockBufferNoErr, let dataPointer else { continue }
            let count = length / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: count) { fp in
                let chunk = UnsafeBufferPointer(start: fp, count: count)
                samples.append(contentsOf: chunk)
                pending.append(contentsOf: chunk)
            }
            while pending.count >= hopSamples {
                let frame = Array(pending[0..<hopSamples])
                pending.removeFirst(hopSamples)
                envelope.append(Self.dbfs(frame))
            }
            if duration > 0 {
                progress?(min(1.0, Double(samples.count) / Self.sampleRate / duration))
            }
        }
        if !pending.isEmpty { envelope.append(Self.dbfs(pending)) }

        if reader.status == .failed {
            throw ExtractionError.readerFailed(reader.error?.localizedDescription
                                               ?? String(localized: "不明"))
        }
        progress?(1.0)
        let actual = Double(samples.count) / Self.sampleRate
        return Result(samples: samples,
                      duration: duration > 0 ? duration : actual,
                      envelope: envelope,
                      envelopeHopSeconds: hop)
    }

    public static func dbfs(_ frame: [Float]) -> Float {
        guard !frame.isEmpty else { return -120 }
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frame.count))
        if rms <= 1e-7 { return -120 }
        return 20 * log10f(rms)
    }
}

/// 区間ごとの音圧を引くための小道具。
public struct AudioEnvelope: Sendable {
    public let values: [Float]
    public let hop: Double
    public init(values: [Float], hop: Double) { self.values = values; self.hop = hop }

    /// [start, end) の最大 dBFS。無音判定は「区間内のどこにも音が無い」で行うため max を使う。
    public func peakDBFS(from start: Double, to end: Double) -> Float {
        guard !values.isEmpty, end > start else { return -120 }
        guard let r = frames(from: start, to: end) else {
            // 1フレームに満たない区間。そのフレームの値を返す。
            return values[min(max(0, Int(start / hop)), values.count - 1)]
        }
        return values[r].max() ?? -120
    }

    /// 閾値を下回り続ける区間のうち、指定秒数以上のもの。
    /// 「発話が無い区間」の一次情報。セグメントの並びから推測すると、
    /// 無音をまたぐセグメントがあるだけで見えなくなる（実際に見えなくなった）。
    public func silentRanges(minimumSeconds: Double,
                             threshold: Float,
                             totalDuration: Double) -> [ClosedRange<Double>] {
        guard !values.isEmpty, minimumSeconds > 0 else { return [] }
        var out: [ClosedRange<Double>] = []
        var runStart: Int? = nil
        func close(_ endIndex: Int) {
            guard let s = runStart else { return }
            let a = Double(s) * hop
            let b = min(Double(endIndex) * hop, totalDuration)
            if b - a >= minimumSeconds { out.append(a...b) }
            runStart = nil
        }
        for i in values.indices {
            if values[i] <= threshold {
                if runStart == nil { runStart = i }
            } else {
                close(i)
            }
        }
        close(values.count)
        return out
    }

    /// [start, end) に対応するフレーム添字の範囲。始点は切り捨て、終点は切り上げ。
    /// **この丸めが唯一の定義。** 4つのメソッドがそれぞれ同じ式を持っていた時期があり、
    /// 片方だけ丸めを変えると先頭と末尾のトリムが違うフレーム格子に乗ってしまう。
    private func frames(from start: Double, to end: Double) -> Range<Int>? {
        guard !values.isEmpty, end > start else { return nil }
        let i0 = max(0, Int(start / hop))
        let i1 = min(values.count, Int(ceil(end / hop)))
        return i0 < i1 ? i0..<i1 : nil
    }

    /// [start, end) の中で音がある区間。最初に閾値を超えたフレームの開始から、
    /// 最後に閾値を超えたフレームの終端まで。全部無音なら nil。
    ///
    /// whisper の VAD 時刻マッピングは、無音の手前のセグメントに無音の向こう側の end を
    /// 与えることも、無音の向こうのセグメントに無音の手前の start を与えることもある。
    /// 両端を一度に取り、尺の切り詰めを1つの計算にする。
    public func voicedSpan(from start: Double, to end: Double, threshold: Float) -> ClosedRange<Double>? {
        guard let r = frames(from: start, to: end) else { return nil }
        guard let first = r.first(where: { values[$0] > threshold }),
              let last = r.last(where: { values[$0] > threshold }) else { return nil }
        return (Double(first) * hop)...(Double(last + 1) * hop)
    }

    /// [start, end) で最後に閾値を超えたフレームの終端時刻。全部無音なら nil。
    public func lastVoicedTime(from start: Double, to end: Double, threshold: Float) -> Double? {
        voicedSpan(from: start, to: end, threshold: threshold)?.upperBound
    }

    /// [start, end) で最初に閾値を超えたフレームの開始時刻。全部無音なら nil。
    public func firstVoicedTime(from start: Double, to end: Double, threshold: Float) -> Double? {
        voicedSpan(from: start, to: end, threshold: threshold)?.lowerBound
    }

    /// [start, end) のうち閾値を超えた割合
    public func voicedRatio(from start: Double, to end: Double, threshold: Float) -> Double {
        guard let r = frames(from: start, to: end) else { return 0 }
        let slice = values[r]
        let voiced = slice.filter { $0 > threshold }.count
        return Double(voiced) / Double(slice.count)
    }
}
