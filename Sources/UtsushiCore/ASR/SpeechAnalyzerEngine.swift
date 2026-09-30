import Foundation
import AVFoundation
import Speech
import CoreMedia

/// OS内蔵の SpeechAnalyzer / SpeechTranscriber を使うエンジン。
///
/// モデル管理が不要になる代わりに、whisper.cpp と違って
/// トークン尤度・no_speech確率・VAD閾値に触れない。
/// そのぶん監査層の一部（低尤度判定）が効かなくなるので、
/// `exposesConfidence = false` を返し、パイプライン側で自動的に検証を弱める。
@available(macOS 26.0, *)
public actor SpeechAnalyzerEngine: ASREngine {
    public nonisolated let identifier = "apple.speechanalyzer"
    public nonisolated var displayName: String {
        String(localized: "Apple SpeechTranscriber (OS内蔵)")
    }
    public nonisolated let supportsVAD = false
    public nonisolated let exposesConfidence = false
    /// SpeechTranscriber に initial_prompt 相当のAPIは無い。
    /// 語彙で誘導したい場合は SFCustomLanguageModelData を別途用意する必要がある（未実装）。
    public nonisolated let supportsVocabularyHint = false

    private let locale: Locale
    private var prepared = false

    public init(locale: Locale = Locale(identifier: "ja-JP")) {
        self.locale = locale
    }

    public static func isLocaleSupported(_ locale: Locale) async -> Bool {
        let supported = await SpeechTranscriber.supportedLocales
        return supported.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    public func prepare(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress(String(localized: "対応言語を確認中"), 0.05)
        guard await Self.isLocaleSupported(locale) else {
            throw ASRError.localeUnsupported(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            progress(String(localized: "言語モデルをインストール中"), 0.2)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        prepared = true
        progress(String(localized: "準備完了"), 1.0)
    }

    public func transcribe(_ request: ASRRequest,
                           progress: @escaping @Sendable (Double) -> Void,
                           isCancelled: @escaping @Sendable () -> Bool) async throws -> [Segment] {
        guard prepared else { throw ASRError.engineFailed("prepare() が呼ばれていない") }

        // 部分再認識に対応するため、対象区間だけを切り出して一時WAVに落とす。
        let slice = Self.slice(request.samples, range: request.timeRange)
        let offset = request.timeRange?.lowerBound ?? 0
        let fileURL = try Self.writeTemporaryWAV(samples: slice)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: fileURL)
        let totalSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate

        // キャンセルを analyzeSequence に伝える監視。入れないとコレクタは止まっても
        // 解析本体はファイルの最後まで走り続ける（43分素材で数十秒待たされていた）。
        let cancellationWatcher = Task {
            while !Task.isCancelled {
                if isCancelled() { await analyzer.cancelAndFinishNow(); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { cancellationWatcher.cancel() }

        // actor 隔離された変数を Task 内で書き換えるとデータ競合になるため、
        // ロック付きの箱に集めてから取り出す。
        let sink = SegmentSink()
        let collector = Task {
            for try await result in transcriber.results {
                if isCancelled() { break }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = CMTimeGetSeconds(result.range.start) + offset
                let end = CMTimeGetSeconds(CMTimeAdd(result.range.start, result.range.duration)) + offset
                sink.append(Segment(start: start, end: max(end, start), original: text))
                if totalSeconds > 0 {
                    progress(min(1.0, (end - offset) / totalSeconds))
                }
            }
        }
        // 解析が投げて返ってきた経路でも、結果を待ち続けるタスクを残さない
        defer { collector.cancel() }
        // キャンセルによる中断が Speech 側のエラーとして上がることがある。
        // isCancelled が立っていたら理由に関わらず cancelled で返す。
        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            if isCancelled() { throw ASRError.cancelled }
            throw error
        }
        _ = try? await collector.value
        if isCancelled() { throw ASRError.cancelled }

        progress(1.0)
        // SpeechTranscriber は確定結果を細切れ（1〜数文字）で返してくるため、
        // そのままセグメントにすると「自」「己評価と」のような断片が並ぶ。
        // 文末記号か無音の切れ目でまとめ直して、発話単位に揃える。
        return Self.coalesce(sink.drain().sorted { $0.start < $1.start })
    }

    /// 細切れの確定結果を発話単位にまとめる。
    /// 区切る条件は「文末記号で終わっている」か「次の発話まで一定以上空いている」。
    static func coalesce(_ segments: [Segment],
                         gapSeconds: Double = 0.6,
                         maxDuration: Double = 20,
                         maxCharacters: Int = 140) -> [Segment] {
        let terminators: Set<Character> = ["。", "．", ".", "！", "!", "？", "?"]
        var out: [Segment] = []
        for seg in segments {
            let text = seg.original.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if var last = out.last {
                let gap = seg.start - last.end
                let endsSentence = last.original.last.map { terminators.contains($0) } ?? false
                let tooLong = (seg.end - last.start) > maxDuration
                    || (last.original.count + text.count) > maxCharacters
                if !endsSentence && gap <= gapSeconds && !tooLong {
                    last.original += text
                    last.corrected = last.original
                    last.end = max(last.end, seg.end)
                    out[out.count - 1] = last
                    continue
                }
            }
            var fresh = seg
            fresh.original = text
            fresh.corrected = text
            out.append(fresh)
        }
        return out
    }

    private static func slice(_ samples: [Float], range: ClosedRange<Double>?) -> [Float] {
        guard let range else { return samples }
        let sr = AudioExtractor.sampleRate
        let i0 = max(0, Int(range.lowerBound * sr))
        let i1 = min(samples.count, Int(range.upperBound * sr))
        guard i0 < i1 else { return [] }
        return Array(samples[i0..<i1])
    }

    private static func writeTemporaryWAV(samples: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("utsushi-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioExtractor.sampleRate,
                                         channels: 1, interleaved: false) else {
            throw ASRError.engineFailed("AVAudioFormat を作れない")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 16
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
                  let dst = buffer.floatChannelData?[0] else {
                throw ASRError.engineFailed("PCMバッファを作れない")
            }
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!.advanced(by: offset), count: n)
            }
            buffer.frameLength = AVAudioFrameCount(n)
            try file.write(from: buffer)
            offset += n
        }
        return url
    }
}


/// SpeechAnalyzer の結果を並行安全に集めるための箱。
private final class SegmentSink: @unchecked Sendable {
    private var items: [Segment] = []
    private let lock = NSLock()
    func append(_ s: Segment) { lock.lock(); items.append(s); lock.unlock() }
    func drain() -> [Segment] { lock.lock(); defer { lock.unlock() }; return items }
}
