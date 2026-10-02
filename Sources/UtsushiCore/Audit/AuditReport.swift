import Foundation

/// 監査層が「何を疑い、何をどう処理したか」を全部残す。
/// 黙って直す・黙って捨てるをさせないための記録。
public struct AuditReport: Sendable, Codable, Equatable {
    public var findings: [Finding]
    public var stats: Stats

    public static let empty = AuditReport(findings: [], stats: Stats())

    public init(findings: [Finding], stats: Stats) {
        self.findings = findings; self.stats = stats
    }

    public struct Finding: Sendable, Codable, Equatable, Identifiable {
        public var id: UUID
        public var kind: Kind
        public var start: Double
        public var end: Double
        public var detail: String
        public var action: Action

        public init(id: UUID = UUID(), kind: Kind, start: Double, end: Double,
                    detail: String, action: Action) {
            self.id = id; self.kind = kind; self.start = start
            self.end = end; self.detail = detail; self.action = action
        }

        public enum Kind: String, Sendable, Codable {
            case silentHallucination   // 無音区間に本文が出た
            case repetitionLoop        // 同一文の連続
            case densityAnomaly        // 尺に対して文字数が少なすぎる
            case densityExcess         // 尺に対して文字数が多すぎる（継ぎ目・重複の疑い）
            case lowConfidence         // 尤度が低い
            case coverageGap           // セグメント間に無視できない空白
            case segmentOverrun        // 発話の終わりより先まで尺が伸びていた
        }
        public enum Action: String, Sendable, Codable {
            case suppressed   // 本文を破棄
            case repaired     // 再認識して差し替え
            case marked       // 印だけ付けて残した
            case unresolved   // 検出したが処理できていない
        }
    }

    public struct TimeRange: Sendable, Codable, Equatable {
        public var start: Double
        public var end: Double
        public var duration: Double { max(0, end - start) }
        public init(start: Double, end: Double) { self.start = start; self.end = end }
    }

    public struct Stats: Sendable, Codable, Equatable {
        public var segmentCount: Int = 0
        public var suppressedCount: Int = 0
        public var repairedCount: Int = 0
        public var coverageRatio: Double = 0      // 発話区間 / 総尺
        public var maxRepetitionRun: Int = 0
        /// 音声側から出した無音区間。セグメントの並びからは復元できないので記録する。
        public var silentRanges: [TimeRange] = []
        public var voicedSeconds: Double = 0
        public var silentSeconds: Double = 0
        /// 有声時間のうち文字起こしが覆っている秒数
        public var transcribedVoicedSeconds: Double = 0
        /// 尺を切り詰めたセグメント数と、削った合計秒数。
        /// カバー率がこれで変わるので、黙って直したことにしない。
        public var overrunTrimmedCount: Int = 0
        public var overrunTrimmedSeconds: Double = 0
        public init() {}
    }
}
