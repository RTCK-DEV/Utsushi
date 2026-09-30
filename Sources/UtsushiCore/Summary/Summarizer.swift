import Foundation

/// 要約エンジンに渡す1塊。
public struct SummaryChunk: Sendable, Equatable {
    /// 塊の中のセグメント。`index` は塊内での 1 始まりの番号で、
    /// モデルにはこの番号だけを返させる。
    public struct Line: Sendable, Equatable {
        public var index: Int
        public var segmentID: UUID
        public var start: Double
        public var end: Double
        public var text: String
        public init(index: Int, segmentID: UUID, start: Double, end: Double, text: String) {
            self.index = index; self.segmentID = segmentID
            self.start = start; self.end = end; self.text = text
        }
    }
    public var lines: [Line]
    public var start: Double { lines.first?.start ?? 0 }
    public var end: Double { lines.last?.end ?? 0 }
    /// モデルに見せる本文。行番号つき。
    public var numberedText: String {
        lines.map { "\($0.index): \($0.text)" }.joined(separator: "\n")
    }
    /// ゲートの照合対象になる素の本文
    public var plainText: String {
        lines.map(\.text).joined(separator: "")
    }
    public init(lines: [Line]) { self.lines = lines }
}

/// モデルが返す1件の選択。
public struct SummarySelection: Sendable, Equatable {
    /// 塊内の行番号（1始まり）。範囲外は呼び出し側が捨てる。
    public var lineNumbers: [Int]
    public var headline: String
    public var kind: Summary.PointKind
    public init(lineNumbers: [Int], headline: String, kind: Summary.PointKind) {
        self.lineNumbers = lineNumbers; self.headline = headline; self.kind = kind
    }
}

/// 要約エンジン。本文は返さず、**どの行が重要か**と短い見出しだけを返す。
public protocol SummaryEngine: Sendable {
    var displayName: String { get }
    func isAvailable() async -> CorrectionAvailability
    func select(from chunk: SummaryChunk, maxPoints: Int) async throws -> [SummarySelection]
}

/// 文字起こしを塊に割り、エンジンに選ばせ、引用を組み立てる。
///
/// 本文は必ずセグメントからそのまま取る。モデルの出力で本文を作る経路は存在しない。
public struct Summarizer: Sendable {

    public struct Configuration: Sendable {
        /// 1塊の最大文字数。Foundation Models の文脈長は 8,192 トークンで、
        /// 日本語は約1.24文字/トークン。指示と出力の分を引いて実測上限は約1万文字なので、
        /// 行番号のオーバーヘッドと余裕を見てこの値にしている。
        public var maxCharactersPerChunk: Int = 3_000
        /// 1塊あたりに取り出す要点の上限
        public var maxPointsPerChunk: Int = 4
        /// 1要点あたりの引用行数の上限。多いと要約の意味が無くなる。
        public var maxLinesPerPoint: Int = 3
        public var gatePolicy: SummaryGate.Policy = .init()
        public init() {}
    }

    public var engine: (any SummaryEngine)?
    public var config: Configuration

    public init(engine: (any SummaryEngine)?, config: Configuration = Configuration()) {
        self.engine = engine
        self.config = config
    }

    /// 抑制済み・空のセグメントは要約に入れない。
    /// 幻聴として捨てた本文を要約が拾い直したら、除去した意味が無い。
    public func chunks(from segments: [Segment]) -> [SummaryChunk] {
        let usable = segments.filter {
            !$0.isSuppressed && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var out: [SummaryChunk] = []
        var lines: [SummaryChunk.Line] = []
        var count = 0
        for seg in usable {
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if count + t.count > config.maxCharactersPerChunk, !lines.isEmpty {
                out.append(SummaryChunk(lines: lines))
                lines = []; count = 0
            }
            lines.append(.init(index: lines.count + 1, segmentID: seg.id,
                               start: seg.start, end: seg.end, text: t))
            count += t.count
        }
        if !lines.isEmpty { out.append(SummaryChunk(lines: lines)) }
        return out
    }

    public func run(on segments: [Segment],
                    progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                    isCancelled: @escaping @Sendable () -> Bool = { false }) async -> Summary {
        var summary = Summary()
        let all = chunks(from: segments)
        summary.stats.chunkCount = all.count
        guard let engine else { return summary }

        let gate = SummaryGate(policy: config.gatePolicy)

        // 塊ごとの選択は互いに独立した LLM 呼び出しなので、上限を付けて並行に投げる。
        // ゲート評価と統計の畳み込みは入力順に逐次で行い、結果は直列と同じになる。
        let selected = await BoundedParallel.compactMap(
            all, concurrency: 4,
            progress: { progress($0, all.count) },
            isCancelled: isCancelled
        ) { chunk -> (SummaryChunk, [SummarySelection]?)? in
            if isCancelled() { return nil }
            return (chunk, try? await engine.select(from: chunk, maxPoints: config.maxPointsPerChunk))
        }

        for (chunk, selections) in selected {
            guard let selections else {
                summary.stats.failedChunkCount += 1
                continue
            }
            for sel in selections {
                summary.stats.selectedCount += 1
                // 行番号は塊内の実在する番号でなければならない。
                // 存在しない番号を指してきたら、その要点は丸ごと捨てる。
                let valid = sel.lineNumbers
                    .compactMap { n in chunk.lines.first { $0.index == n } }
                if valid.isEmpty {
                    summary.stats.invalidReferenceCount += 1
                    continue
                }
                if valid.count != sel.lineNumbers.count {
                    summary.stats.invalidReferenceCount += 1
                }
                let picked = Array(valid.sorted { $0.index < $1.index }.prefix(config.maxLinesPerPoint))
                let quotes = picked.map(\.text)
                let source = quotes.joined(separator: "")

                let verdict = gate.evaluate(headline: sel.headline, source: source)
                let headline: String
                let headlineSource: Summary.HeadlineSource
                if verdict.isAccepted {
                    headline = sel.headline.trimmingCharacters(in: .whitespacesAndNewlines)
                    headlineSource = .model
                } else {
                    summary.stats.rejectedHeadlineCount += 1
                    if case .reject(let reason) = verdict {
                        summary.stats.headlineRejections[reason.rawValue, default: 0] += 1
                    }
                    headline = SummaryGate.extractHeadline(from: source)
                    headlineSource = .extracted
                }

                summary.points.append(.init(headline: headline,
                                            headlineSource: headlineSource,
                                            kind: sel.kind,
                                            segmentIDs: picked.map(\.segmentID),
                                            quotes: quotes,
                                            start: picked.first?.start ?? chunk.start,
                                            end: picked.last?.end ?? chunk.end))
            }
        }
        progress(all.count, all.count)
        summary.points.sort { $0.start < $1.start }
        return summary
    }
}
