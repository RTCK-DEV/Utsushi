import Foundation
import FoundationModels

/// 書き換え案の受け皿。@Generable で **文字列1本しか返せない形** に型で縛る。
/// 自由記述の説明や理由を返す余地を与えないのが狙い（説明を書ける＝作文の余地）。
@available(macOS 26.0, *)
@Generable
struct SegmentRewrite {
    @Guide(description: "誤変換だけを直した本文。読み（発音）は絶対に変えない。内容の追加・要約・言い換えは禁止。直す箇所がなければ入力をそのまま返す。")
    var corrected: String
}

/// Apple Foundation Models（OS内蔵の on-device モデル）を使う校正エンジン。
///
/// 責務は「書き換え案を出す」ことだけで、採否の判断は持たない。
/// 案は必ず `EditGate` を通り、読みが変わる案・長さが外れる案・
/// 原文に無い英数字を含む案はここを通っても採用されない。
@available(macOS 26.0, *)
public final class FoundationModelsCorrector: CorrectionEngine, @unchecked Sendable {
    public let displayName = "Apple Foundation Models (on-device)"

    private let instructions = """
    あなたは日本語音声認識の結果を校正する。出力は校正後の本文のみ。

    許可される変更は次の4種類だけ:
    1. 同音異義語の誤変換を直す（例: 機構→気候）
    2. 読点・句点を補う
    3. かな書きを適切な漢字に直す、またはその逆（例: シュウショク活動→就職活動）
    4. 送り仮名を統一する

    禁止:
    - 読み（発音）が変わる書き換え。別の語に置き換えてはならない
    - 内容の追加、削除、要約、言い換え、敬語の変更
    - 入力に無い固有名詞・数値・英単語を書くこと
    - 説明や注釈を出力に混ぜること

    直す箇所が無ければ、入力をそのまま返す。
    """

    private let options: GenerationOptions

    public init(temperature: Double = 0.0) {
        self.options = GenerationOptions(sampling: .greedy,
                                         temperature: temperature,
                                         maximumResponseTokens: 400)
    }

    public func isAvailable() async -> CorrectionAvailability {
        SystemLanguageModel.default.availability.correctionAvailability
    }

    public func propose(segment: String, context: CorrectionContext) async throws -> String? {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        // 短すぎる断片はLLMに渡さない。文脈が無い状態での書き換えは事故率が高い。
        guard trimmed.count >= 4 else { return nil }

        var prompt = ""
        if !context.vocabulary.isEmpty {
            prompt += "この分野で使われる固有名詞: \(context.vocabulary.prefix(30).joined(separator: "、"))\n"
        }
        if !context.precedingText.isEmpty {
            prompt += "直前の文脈（参考。書き換え対象ではない）: \(context.precedingText.suffix(120))\n"
        }
        prompt += "校正対象:\n\(trimmed)"

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt,
                                                 generating: SegmentRewrite.self,
                                                 options: options)
        let out = response.content.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}
