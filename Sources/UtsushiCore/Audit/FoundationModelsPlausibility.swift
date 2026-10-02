import FoundationModels

/// 指摘の受け皿。**本文を返すフィールドが無い。**
/// 返せるのは行番号と、その行にある語と、ありうる語の3つだけ。
@available(macOS 26.0, *)
@Generable
struct PlausibilityList {
    @Guide(description: "前後の文脈と意味が合わない語。多くても4件。", .count(0...4))
    var items: [PlausibilityItem]
}

@available(macOS 26.0, *)
@Generable
struct PlausibilityItem {
    @Guide(description: "その語がある行の番号。本文に付いている番号をそのまま使う。")
    var line: Int

    @Guide(description: "本文にそのまま書かれている、意味の通らない語。1〜8文字。本文から一字一句そのまま写す。")
    var surface: String

    /// **ここが0件の直接の原因だった。**
    /// 以前は「思いつかない場合はその語を挙げない」と書いていた。実モデルは
    /// 正しい語をまず思いつけない（読みを与えても「気象」を「気象」と返す）ので、
    /// この指示に忠実に従った結果、**語の指摘ごと出さなくなっていた。**
    /// 当てられる方（どの語が浮いているか）まで巻き添えで消えていた。
    @Guide(description: "その語の代わりに入るはずの語。音が近く、文脈に合うもの。1〜8文字。思いつかなければ空文字にする。空でも語の指摘は必ず残すこと。")
    var alternative: String
}

/// 2段目の受け皿。**番号しか返せない。**
///
/// 1段目は「必ず何か挙げる」性質があり、誤りの無い本文にも指摘を作る。
/// 実測では5行に対して4件挙げ、当たりは1件だった。
/// 一方、**候補を並べて1つ選ばせる問いには3回とも正解した。**
/// この非対称を使って、挙がったものを1件に絞る。
@available(macOS 26.0, *)
@Generable
struct PlausibilityPick {
    @Guide(description: "最も意味が通らない語の番号。候補に付いている番号をそのまま使う。")
    var number: Int
}

/// Apple Foundation Models に「日本語として意味が通らない語」を指摘させる。
///
/// 照合が拾えるのはエンジン間の不一致だけで、全エンジンが同じ誤り方をした箇所は
/// 素通りする。そこに残っている手掛かりは文脈しかない。
///
/// **モデルは本文を書き換えない。** 指摘した語が本文に無ければ `PlausibilityGate` が捨て、
/// 通っても本文はそのままで候補が横に並ぶだけ。
@available(macOS 26.0, *)
public final class FoundationModelsPlausibility: PlausibilityChecker, @unchecked Sendable {
    public let displayName = "Apple Foundation Models (on-device)"

    /// **短く保つこと。長くすると当たらなくなる。** 実測で確認した:
    ///
    /// | instructions | alternative 要求 | 「気象」を拾えたか |
    /// |---|---|---|
    /// | 長い（手順・例2つ・厳守4項目）| あり | ×（評価/目標/提出）|
    /// | 長い | なし | ×（評価/振り返り/提出）|
    /// | **短い（下記）** | あり | **○**（2回とも）|
    /// | **短い** | なし | **○**（2回とも）|
    ///
    /// 決めているのは instructions の長さで、返させる項目数ではなかった。
    ///
    /// 長い版には「異常→以上」「時事録→議事録」という例を置いていた。
    /// どちらも**2文字熟語の1文字違い**なので、モデルがそのパターンに合う語を
    /// 探すようになり、探索範囲がかえって狭まった。**例は足すほど良くならない。**
    ///
    /// なお、それ以前は例として「気象→期初」という**検証データそのもの**を
    /// 書いていた。答えを教えた上で同じ入力を投げていたので、
    /// 仮に通っても能力の証拠にならなかった。例を置くなら検証データと独立させる。
    /// ここでは例を一切置かないのが最も成績が良かった。
    private let instructions = """
    日本語の音声認識結果から、前後の文脈と意味が合わない語だけを抜き出す。
    抜き出すのは本文にそのまま書かれている語だけ。言い換えてはならない。
    代わりに入るはずの語が思いつけば添える。思いつかなくても語は挙げる。
    """

    private let options: GenerationOptions

    public init(temperature: Double = 0.0) {
        self.options = GenerationOptions(sampling: .greedy,
                                         temperature: temperature,
                                         maximumResponseTokens: 500)
    }

    public func isAvailable() async -> CorrectionAvailability {
        SystemLanguageModel.default.availability.correctionAvailability
    }

    public func check(numberedText: String, lineCount: Int) async throws -> [PlausibilityDraft] {
        guard lineCount > 0 else { return [] }
        let drafts = try await propose(numberedText: numberedText)
        // 1件以下なら絞る必要が無い。無駄な呼び出しをしない。
        guard drafts.count > 1 else { return drafts }
        guard let picked = try await pickMostSuspicious(drafts, numberedText: numberedText) else {
            // 範囲外の番号が返ったときは絞らない。
            // ここで全部捨てると「モデルが答えられなかった」が「指摘なし」に化ける。
            return drafts
        }
        return [picked]
    }

    /// 1段目。文脈から浮いている語を挙げさせる。
    private func propose(numberedText: String) async throws -> [PlausibilityDraft] {
        // 「無ければ空で返してよい」とは書かない。
        // 型（.count(0...4)）と instructions で既に0件を許してあり、
        // プロンプトでも重ねて言うと、空が全ての条件を同時に満たす
        // 最も安全な出力になる。実際にそうなって0件が続いていた。
        let prompt = """
        次は音声認識の結果である。前後の文脈と意味が合わない語を挙げよ。

        \(numberedText)
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt,
                                                 generating: PlausibilityList.self,
                                                 options: options)
        return response.content.items.map {
            PlausibilityDraft(lineNumber: $0.line, surface: $0.surface, alternative: $0.alternative)
        }
    }

    /// 2段目。挙がった語から最も怪しい1つを選ばせる。
    ///
    /// **「どれも問題ない」という逃げ道は用意しない。** 実測で用意しても使わず、
    /// 誤りの無い本文でも別の語を選んだ。使わない選択肢を置くと、
    /// 「none が返らなかった＝誤りが存在する」と読める形になってしまう。
    /// ここでやっているのは有無の判定ではなく**順位付け**だと、呼ぶ側が分かる形にしておく。
    private func pickMostSuspicious(_ drafts: [PlausibilityDraft],
                                    numberedText: String) async throws -> PlausibilityDraft? {
        let choices = drafts.enumerated()
            .map { "\($0.offset + 1). \($0.element.surface)" }
            .joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
        日本語の音声認識結果と、その中の語の候補が与えられる。
        音声認識は音を文字にするだけなので、音は近いが意味の通らない語に化けることがある。
        候補のうち、その文脈で最も意味が通らない語を1つだけ選ぶ。
        """)
        let r = try await session.respond(to: """
        \(numberedText)

        次のうち、文脈で最も意味が通らない語はどれか。番号で1つ選べ。
        \(choices)
        """, generating: PlausibilityPick.self, options: options)

        let n = r.content.number
        guard n >= 1, n <= drafts.count else { return nil }
        return drafts[n - 1]
    }
}
