import XCTest

/// 語彙注入（initial_prompt）が実際に効くかのA/B測定。
///
/// 「効くはず」で終わらせないための実測。同一のエンジンインスタンスで
/// 辞書なし → 辞書ありの順に回すので、モデル読み込みコストと熱条件を共有する。
///
/// 同時にプロンプト汚染（initial_prompt の文字列が本文に混入する whisper の既知の failure mode）
/// も検査する。これは効果とは無関係に**通ってはいけない**ので assert する。
final class VocabularyHintEffectTests: XCTestCase {

    private static let clipURL: URL = {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("fixtures/testclip.m4a")
    }()

    /// 実測で誤認識が出た語。辞書に入れたら拾えるようになるかを見る。
    private static let targets = [
        "コンピテンシー", "上長評価", "ラウンドテーブル", "一気通貫", "Teams", "水分補給",
    ]

    func testVocabularyHintChangesRecognition() async throws {
        guard FileManager.default.fileExists(atPath: Self.clipURL.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        guard ModelCatalog.isInstalled(ModelCatalog.whisperModels[0]) else {
            throw XCTSkip("whisperモデルが未導入")
        }

        let engine = WhisperEngine()
        let t0 = Date()
        try await engine.prepare { _, _ in }
        let loadSec = Date().timeIntervalSince(t0)

        let audio = try await AudioExtractor().extract(url: Self.clipURL)

        func run(terms: [String]) async throws -> (segments: [Segment], seconds: Double) {
            let t = Date()
            let segs = try await engine.transcribe(
                ASRRequest(samples: audio.samples, language: "ja",
                           useVAD: true, vocabularyTerms: terms),
                progress: { _ in }, isCancelled: { false })
            return (segs, Date().timeIntervalSince(t))
        }

        let dict = UserDictionary(entries: Self.targets.map {
            UserDictionary.Entry(surface: $0, reading: "")
        })
        let hint = dict.promptHint()
        XCTAssertNotNil(hint)

        let base = try await run(terms: [])
        let hinted = try await run(terms: dict.hintTerms)

        let baseText = base.segments.map(\.original).joined()
        let hintedText = hinted.segments.map(\.original).joined()

        print("=== 語彙注入 A/B（音声660秒・モデル読込 \(String(format: "%.1f", loadSec))s）===")
        print("prompt: \(hint ?? "-")")
        print("辞書なし: \(String(format: "%.1f", base.seconds))s / \(base.segments.count)セグ / \(baseText.count)文字")
        print("辞書あり: \(String(format: "%.1f", hinted.seconds))s / \(hinted.segments.count)セグ / \(hintedText.count)文字")
        print("--- 対象語の出現 ---")
        var gained = 0, lost = 0
        for t in Self.targets {
            let b = baseText.contains(t), h = hintedText.contains(t)
            let mark = (b == h) ? "  " : (h ? "＋" : "－")
            if !b && h { gained += 1 }
            if b && !h { lost += 1 }
            print("\(mark) \(t): 辞書なし=\(b ? "○" : "✕") 辞書あり=\(h ? "○" : "✕")")
        }
        print("改善 \(gained) 件 / 悪化 \(lost) 件")

        // プロンプト汚染: initial_prompt の文字列そのものが本文に出てはいけない
        XCTAssertFalse(hintedText.contains("固有名詞:"), "プロンプトが本文に漏れている")
        XCTAssertFalse(hintedText.contains("固有名詞："), "プロンプトが本文に漏れている")

        // 本文が壊れていないこと（極端に短く/長くなっていない）
        let ratio = Double(hintedText.count) / Double(max(baseText.count, 1))
        XCTAssertTrue((0.8...1.3).contains(ratio),
                      "語彙注入で本文量が大きく変わった: \(String(format: "%.2f", ratio))倍")

        // 差分の実物を見る
        print("--- 辞書ありで変わった行 ---")
        let baseLines = base.segments.map(\.original)
        let hintedLines = hinted.segments.map(\.original)
        for (i, h) in hintedLines.enumerated() where i < baseLines.count && baseLines[i] != h {
            print("  \(Exporter.hms(hinted.segments[i].start))")
            print("    - \(baseLines[i])")
            print("    + \(h)")
        }
        engine.shutdown()
    }
}
