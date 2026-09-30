import Foundation

/// 文脈に合わない語の指摘。**本文は書き換えない。表示するだけ。**
///
/// 照合（`TranscriptAlignment`）はエンジン間の不一致しか見ないので、
/// **全エンジンが同じ間違え方をした箇所には無力**だった。
/// 実データでは「期初」が4エンジンすべてで「気象」になっており、
/// 「大体気象の目標を3月から4月ぐらいに立てまして」がそのまま出ていた。
/// 音響からの多数決では原理的に拾えない。残っている手掛かりは文脈だけになる。
///
/// そこで言語モデルに「日本語として意味が通らない語」を指摘させる。
/// ただし**モデルに本文を書かせない**という原則は変えない。
///
/// ## `alternative` が省略可能な理由（実測に基づく）
///
/// 実モデルで測ったところ、能力が非対称だった:
///
/// | 問い | 結果 |
/// |---|---|
/// | 「期初」という語を知っているか | 知っている。意味を正しく説明する |
/// | 本文から浮いている語はどれか | **3回とも同じ答え**（「気象」）。安定している |
/// | その語は本来何か（生成） | **外す**。「境界」「気温」「目標」。読みを与えても「気象」を返す |
/// | 4択から選べるか | 選べることがある（「期初」を選べた） |
///
/// **語の位置は当てられるが、正しい語は取り出せない。** 知識が無いのではなく
/// 生成タスクとして取り出せない。プロンプトの工夫で越えられる壁ではなかった。
///
/// そこで候補は「出せたら添える」ものとして扱う。`PlausibilityGate` が読みの近さで
/// 検証し、遠い候補は**候補だけ捨てて指摘は残す**。「気象」→「目標」のような
/// 誤った候補を本文の横に並べるのは、何も出さないより悪い。
public struct PlausibilityFlag: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    /// 指摘された語を含むセグメントの開始時刻
    public var start: Double
    /// 本文にあるその語。**本文に実在することを検証済み。**
    public var surface: String
    /// ありうる語。**読みの近さを検証して通ったものだけが入る。**
    /// nil なら「この語は文脈に合わない可能性がある」とだけ伝える。
    public var alternative: String?

    public init(id: UUID = UUID(), start: Double, surface: String, alternative: String? = nil) {
        self.id = id; self.start = start
        self.surface = surface; self.alternative = alternative
    }

    /// 候補の有無で書き分けた注記。書き出しと画面の両方がこれを使う。
    /// **無い候補を埋めない。** 埋めると読み手はそれを正解として読む。
    /// 文言が2箇所にあると片方だけ直って、画面とファイルで言うことが変わる。
    public var alternativeNote: String {
        if let alternative, !alternative.isEmpty {
            return String(localized: "→「\(alternative)」かもしれない")
        }
        return String(localized: "（正しい語は不明）")
    }
}

/// モデルからの生の指摘。ゲートを通る前のもの。
public struct PlausibilityDraft: Sendable, Equatable {
    public var lineNumber: Int
    public var surface: String
    /// モデルが候補を出さなかった場合は空。
    public var alternative: String
    public init(lineNumber: Int, surface: String, alternative: String = "") {
        self.lineNumber = lineNumber; self.surface = surface; self.alternative = alternative
    }
}

public protocol PlausibilityChecker: Sendable {
    var displayName: String { get }
    func isAvailable() async -> CorrectionAvailability
    /// 番号付きの本文を渡し、文脈に合わない語を指摘させる。
    func check(numberedText: String, lineCount: Int) async throws -> [PlausibilityDraft]
}

/// モデルの指摘を機械的に検証する。
///
/// 判定は2段になっている:
///
/// 1. **指摘そのものを通すか** — 語が本文に実在するか、内容語か
/// 2. **候補を見せてよいか** — 読みが近いか、創作していないか
///
/// 2 で落ちても 1 が通っていれば指摘は残る。モデルは「どの語が浮いているか」は
/// 当てられて「その語が本来何か」は当てられないので、両者を同じ扱いにすると
/// **当てられる方の情報まで一緒に捨てることになる。**
///
/// `EditGate`（校正）ほど厳しくしていないのは、**ここでは本文を書き換えないから**。
/// ただし「読みが一致すること」までは要求しない。それをやると
/// 「気象（きしょう）→期初（きしょ）」という**一番拾いたい形**が落ちる。
/// 要求するのは一致ではなく近さ。
public struct PlausibilityGate: Sendable {

    public enum Rejection: String, Sendable, Equatable {
        /// 存在しない行を指した
        case lineOutOfRange
        /// 指摘した語がその行に無い（モデルの創作）
        case surfaceNotInLine
        /// 元の語と同じ
        case unchanged
        /// 長すぎる・短すぎる・釣り合わない
        case badLength
        /// ひらがな・約物だけ。助詞のゆれを指摘されても読み手にできることが無い
        case notAContentWord
        /// 元に無い英字を持ち込んだ
        case inventedLatin
        /// 読みが遠すぎる。音声認識の誤りは音が近いはずなので、
        /// 読みが違う候補は文脈の指摘ではなくモデルの連想。
        case readingTooFar
        /// 読みが取れない。比べようがないので候補として出さない。
        case readingUnavailable
    }

    /// ゲートの判定。指摘の採否と候補の採否を分けて返す。
    public struct Verdict: Sendable, Equatable {
        /// 指摘ごと落とす理由。nil なら指摘は通る。
        public var rejection: Rejection?
        /// 候補だけ落とす理由。nil なら候補も見せてよい。
        public var alternativeRejection: Rejection?

        public var isAccepted: Bool { rejection == nil }
        public var keepsAlternative: Bool { rejection == nil && alternativeRejection == nil }

        public init(rejection: Rejection? = nil, alternativeRejection: Rejection? = nil) {
            self.rejection = rejection
            self.alternativeRejection = alternativeRejection
        }
    }

    public var maxLength: Int
    /// 読みの距離（長い方の文字数で割ったもの）の上限。
    ///
    /// 実測値で決めている:
    ///
    /// | 組 | 読み | 正規化距離 |
    /// |---|---|---|
    /// | 気象 → 期初 | kishou / kisho | 0.17（**通したい**）|
    /// | 一気通関 → 一気通貫 | 同音 | 0.00（**通したい**）|
    /// | 機構 → 気候 | 同音 | 0.00（**通したい**）|
    /// | 気象 → 気温 | kishou / kion | 0.50（落としたい）|
    /// | 気象 → 目標 | kishou / mokuhyou | 0.62（落としたい）|
    /// | 気象 → 境界 | kishou / kyoukai | 0.86（落としたい）|
    /// | 採用 → 再度 | saiyou / saido | 0.33（**閾値の内側に入る**。近い読みの2字熟語はここまで来る）|
    ///
    /// 通したい側の最大が 0.17、落としたい側の最小が 0.50。
    /// その間の 0.34 に置いた。片方に寄せた値ではない。
    /// 数値は `Reading.key` + `TextDistance.normalized` で検算したもの
    /// （以前の表は 0.67 / 0.88 / 0.75 と書いていたが、実際に計算すると上の値になる。
    /// 余裕は思っていたより狭い）。
    ///
    /// **この値の出所はここだけ。** `readingProximity` の static 版に既定値を持たせていた時期があり、
    /// `judge` がそちらを呼んでいたため、このプロパティを変えても本番の判定が変わらなかった。
    public var maxReadingDistance: Double

    public static let defaultMaxReadingDistance = 0.34

    public init(maxLength: Int = 8, maxReadingDistance: Double = defaultMaxReadingDistance) {
        self.maxLength = maxLength
        self.maxReadingDistance = maxReadingDistance
    }

    public func judge(_ d: PlausibilityDraft, lines: [String]) -> Verdict {
        guard d.lineNumber >= 1, d.lineNumber <= lines.count else {
            return Verdict(rejection: .lineOutOfRange)
        }
        let line = lines[d.lineNumber - 1]
        let surface = d.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let alternative = d.alternative.trimmingCharacters(in: .whitespacesAndNewlines)

        // --- 1段目: 指摘そのものを通すか ---
        guard !surface.isEmpty else { return Verdict(rejection: .badLength) }
        guard surface.count <= maxLength else { return Verdict(rejection: .badLength) }
        guard line.contains(surface) else { return Verdict(rejection: .surfaceNotInLine) }
        guard Self.hasContentCharacter(surface) else { return Verdict(rejection: .notAContentWord) }

        // --- 2段目: 候補を見せてよいか ---
        // ここで落ちても指摘は残る。
        if alternative.isEmpty { return Verdict(alternativeRejection: .badLength) }
        if alternative == surface { return Verdict(alternativeRejection: .unchanged) }

        let shortest = min(surface.count, alternative.count)
        let longest = max(surface.count, alternative.count)
        if longest > maxLength || longest > shortest * 2 {
            return Verdict(alternativeRejection: .badLength)
        }
        // 元に英字が無いのに英字を持ち込む候補は、文脈の指摘ではなく創作。
        if Self.hasLatin(alternative) && !Self.hasLatin(surface) {
            return Verdict(alternativeRejection: .inventedLatin)
        }
        switch readingProximity(surface, alternative) {
        case .unavailable: return Verdict(alternativeRejection: .readingUnavailable)
        case .far:         return Verdict(alternativeRejection: .readingTooFar)
        case .close:       return Verdict()
        }
    }

    public enum Proximity: Sendable, Equatable { case close, far, unavailable }

    /// 読みの近さ。音声認識の誤りは**音が近い**はずで、
    /// 読みまで違う候補はモデルが意味だけで連想したもの。
    public func readingProximity(_ a: String, _ b: String) -> Proximity {
        Self.readingProximity(a, b, limit: maxReadingDistance)
    }

    static func readingProximity(_ a: String, _ b: String, limit: Double) -> Proximity {
        let ka = Reading.key(a), kb = Reading.key(b)
        guard !ka.isEmpty, !kb.isEmpty else { return .unavailable }
        if ka == kb { return .close }
        return TextDistance.normalized(ka, kb) <= limit ? .close : .far
    }

    static func hasContentCharacter(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)         // 漢字
                || (0x3400...0x4DBF).contains($0.value)
                || (0x30A0...0x30FF).contains($0.value)  // カタカナ
                || Self.isLatinScalar($0)
        }
    }

    static func hasLatin(_ s: String) -> Bool { s.unicodeScalars.contains(where: isLatinScalar) }

    private static func isLatinScalar(_ v: Unicode.Scalar) -> Bool {
        (0x0041...0x005A).contains(v.value) || (0x0061...0x007A).contains(v.value)
    }
}

/// 指摘を集めてゲートに通す司令塔。
///
/// 本文は**窓に分けて**モデルに見せる。1回で全文を渡すと、
///
/// 1. 2時間の録画（1万字超）は on-device モデルの文脈長を超えて呼び出しごと失敗し、
///    「エラー1件・指摘0件」が「問題なし」と同じ見た目になる
/// 2. 収まったとしても、2段目が1件に絞るので**収録全体で指摘が最大1件**になる
///
/// 「区間ごとに1件」を成り立たせるのはここの責務で、モデル側の責務ではない。
public struct PlausibilityAuditor: Sendable {
    public var checker: (any PlausibilityChecker)?
    /// 同じ指摘が2回出た場合のみ採る。
    ///
    /// **一致を見るのは語（行番号 + surface）だけで、候補は見ない。**
    /// 候補はモデルが毎回違うものを思いつく（実測で「境界」「気温」「目標」）ので、
    /// 候補まで一致を要求すると、安定している語の指摘まで巻き添えで消える。
    public var requireAgreement: Bool
    public var gate: PlausibilityGate
    /// 1つの窓に入れる文字数の上限。窓ごとに指摘が最大1件出る。
    ///
    /// 小さくすると指摘が増え（誤りの無い窓でも1件出る）、大きくすると拾い漏れる。
    /// 実測は5行・約200字の窓で命中している。2時間の収録で数十件に収まる値として置いた。
    /// **本番サイズでの最適値は未計測。** 指摘が多すぎる/少なすぎると感じたらここを動かす。
    public var windowCharacters: Int

    public init(checker: (any PlausibilityChecker)?,
                requireAgreement: Bool = true,
                gate: PlausibilityGate = PlausibilityGate(),
                windowCharacters: Int = 800) {
        self.checker = checker
        self.requireAgreement = requireAgreement
        self.gate = gate
        self.windowCharacters = windowCharacters
    }

    public struct Outcome: Sendable, Codable, Equatable {
        public var proposed: Int = 0
        public var accepted: Int = 0
        public var rejectedByGate: Int = 0
        public var droppedForDisagreement: Int = 0
        /// 候補は出たが、読みが遠いなどの理由で候補だけ落とした件数。
        /// モデルが候補を出さなかった（空）ものは数えない。
        /// **0件と区別できないと「候補が出ない」を「指摘が無い」と読んでしまう。**
        public var alternativesDropped: Int = 0
        /// 窓の数。指摘の上限がこれで決まるので、件数を読むときの分母になる。
        public var windows: Int = 0
        public var errors: Int = 0
        /// 失敗した理由。0件と失敗を取り違えないために残す。
        public var lastError: String?
        public init() {}
    }

    /// 窓。`segments` の中の連続した範囲。
    struct Window: Sendable, Equatable {
        /// `segments` 内での先頭の添字
        var offset: Int
        var lines: [String]
    }

    /// 文字数で窓に切る。1セグメントが上限を超えていても切らない（行の途中で切ると
    /// 行番号と本文の対応が崩れる）。
    func windows(for segments: [Segment]) -> [Window] {
        var out: [Window] = []
        var offset = 0
        var lines: [String] = []
        var count = 0
        for (i, seg) in segments.enumerated() {
            let t = seg.text
            if count + t.count > windowCharacters, !lines.isEmpty {
                out.append(Window(offset: offset, lines: lines))
                offset = i; lines = []; count = 0
            }
            lines.append(t)
            count += t.count
        }
        if !lines.isEmpty { out.append(Window(offset: offset, lines: lines)) }
        return out
    }

    /// `segments` の並びがそのまま行番号（1始まり）になる。窓の中では窓内の番号で渡し、
    /// 戻ってきた番号に窓の先頭を足して元の並びへ戻す。
    public func run(on segments: [Segment],
                    progress: @Sendable (Int, Int) -> Void = { _, _ in },
                    isCancelled: @Sendable () -> Bool = { false }) async -> ([PlausibilityFlag], Outcome) {
        var stat = Outcome()
        guard let checker, !segments.isEmpty else { return ([], stat) }

        let windows = windows(for: segments)
        stat.windows = windows.count
        var out: [PlausibilityFlag] = []
        var seen = Set<String>()

        for (w, window) in windows.enumerated() {
            if isCancelled() { break }
            progress(w, windows.count)
            let numbered = window.lines.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")

            var rounds: [[PlausibilityDraft]] = []
            let times = requireAgreement ? 2 : 1
            for _ in 0..<times {
                do {
                    rounds.append(try await checker.check(numberedText: numbered,
                                                          lineCount: window.lines.count))
                } catch {
                    // 「モデルが0件返した」と「呼び出しが失敗した」は結果が同じ形になる。
                    // 区別できないと、動いていないものを「指摘が無い」と読んでしまう。
                    // 1つの窓が失敗しても他の窓は続ける。件数は errors に残る。
                    stat.errors += 1
                    stat.lastError = String(describing: error)
                    rounds = []
                    break
                }
            }
            guard let first = rounds.first else { continue }
            stat.proposed += first.count

            // 一致は trim 後の語で見る。ゲートも同じ集合で trim するので、
            // 「気象」と「気象 」を別の語と数えて droppedForDisagreement にしない。
            var kept: [PlausibilityDraft] = []
            for d in first {
                if requireAgreement {
                    let key = Self.agreementKey(d)
                    let agreed = rounds[1].contains { Self.agreementKey($0) == key }
                    if !agreed { stat.droppedForDisagreement += 1; continue }
                }
                kept.append(d)
            }

            for d in kept {
                let verdict = gate.judge(d, lines: window.lines)
                guard verdict.isAccepted else { stat.rejectedByGate += 1; continue }
                let surface = d.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                let alternative = d.alternative.trimmingCharacters(in: .whitespacesAndNewlines)
                if !verdict.keepsAlternative, !alternative.isEmpty { stat.alternativesDropped += 1 }

                let index = window.offset + d.lineNumber - 1
                let key = "\(index)|\(surface)"
                guard seen.insert(key).inserted else { continue }
                out.append(PlausibilityFlag(
                    start: segments[index].start,
                    surface: surface,
                    alternative: verdict.keepsAlternative ? alternative : nil))
            }
        }
        progress(windows.count, windows.count)
        stat.accepted = out.count
        return (out, stat)
    }

    private static func agreementKey(_ d: PlausibilityDraft) -> String {
        "\(d.lineNumber)|\(d.surface.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
