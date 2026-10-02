import Foundation
import FoundationModels

/// 要約の受け皿。**行番号・短い見出し・種別しか返せない形**にしてある。
/// 本文を返すフィールドが無いので、要約本文をモデルが創作する経路が構造的に存在しない。
@available(macOS 26.0, *)
@Generable
struct SummarySelectionList {
    @Guide(description: "重要な要点。多くても4件。相槌しか無い場合に限り空でよい。", .count(0...4))
    var points: [SummaryPointDraft]
}

@available(macOS 26.0, *)
@Generable
struct SummaryPointDraft {
    @Guide(description: "この要点の根拠になる行の番号。本文に付いている番号をそのまま使う。1〜3個。", .count(1...3))
    var lines: [Int]

    @Guide(description: "その行の内容を短く言い直した見出し。30文字以内。行に書かれていない数値・英単語・カタカナ語を足してはならない。")
    var headline: String

    @Guide(description: "要点の種別。")
    var kind: SummaryKindChoice
}

@available(macOS 26.0, *)
@Generable
enum SummaryKindChoice {
    case topic
    case decision
    case action
    case number
    case question
}

/// Apple Foundation Models を使う要約エンジン。
///
/// 責務は「どの行が重要か選ぶ」ことと「短い見出しを書く」ことだけ。
/// 見出しは `SummaryGate` を通り、原文に無い数値・英数字・カタカナ語を含むものは捨てられる。
/// 本文は `Summarizer` が文字起こしから直接引用するので、ここを通らない。
@available(macOS 26.0, *)
public final class FoundationModelsSummarizer: SummaryEngine, @unchecked Sendable {
    public let displayName = "Apple Foundation Models (on-device)"

    private let instructions = """
    あなたは日本語の書き起こしから要点を抜き出す。

    やること:
    - 本文の各行には番号が付いている。重要な行の番号を選ぶ
    - 選んだ行の内容を、30文字以内の見出しに短く言い直す

    入力は話し言葉の書き起こしなので、言い淀み・言い直し・助詞の抜けが混ざっている。
    文章として整っていないことを理由に飛ばさず、**何について話しているか**で選ぶ。

    厳守:
    - 行に書かれていない数値・日付・固有名詞・英単語・カタカナ語を見出しに書いてはならない
    - 推測で補ってはならない。行に書いてあることだけを使う
    - 存在しない行番号を書いてはならない
    - 相槌だけの行（「はい」「そうですね」）は選ばない
    - 内容のある行が1つでもあるなら、必ず1件以上選ぶ。
      「全体的に重要でない」という理由で空にしてはならない

    種別の使い分け:
    - decision: 決まったこと
    - action: これからやること、宿題、提出物
    - number: 数値・日付・期限・条件
    - question: 質問とその答え
    - topic: それ以外の説明・話題
    """

    private let options: GenerationOptions

    public init(temperature: Double = 0.0) {
        self.options = GenerationOptions(sampling: .greedy,
                                         temperature: temperature,
                                         maximumResponseTokens: 700)
    }

    public func isAvailable() async -> CorrectionAvailability {
        SystemLanguageModel.default.availability.correctionAvailability
    }

    public func select(from chunk: SummaryChunk, maxPoints: Int) async throws -> [SummarySelection] {
        guard !chunk.lines.isEmpty else { return [] }
        let prompt = """
        次の書き起こしから重要な要点を最大\(maxPoints)件選ぶ。
        話し言葉なので整っていないが、内容のある行があるなら必ず選ぶこと。

        \(chunk.numberedText)
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt,
                                                 generating: SummarySelectionList.self,
                                                 options: options)
        return response.content.points.prefix(maxPoints).map {
            SummarySelection(lineNumbers: $0.lines,
                             headline: $0.headline,
                             kind: Self.map($0.kind))
        }
    }

    private static func map(_ k: SummaryKindChoice) -> Summary.PointKind {
        switch k {
        case .topic: return .topic
        case .decision: return .decision
        case .action: return .action
        case .number: return .number
        case .question: return .question
        }
    }
}
