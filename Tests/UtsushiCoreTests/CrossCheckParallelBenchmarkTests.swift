import XCTest

/// 照合エンジンの並列化が「速くなるだけで結果を変えない」ことを実音声で確かめる。
/// 逐次実行と並列実行の両方を同じ素材で回し、所要時間と各エンジンの出力一致を比較する。
final class CrossCheckParallelBenchmarkTests: XCTestCase {

    private static func fixtureURL(_ name: String) -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("fixtures/\(name)")
    }

    private nonisolated static var installedCrossChecks: [ModelCatalog.Model] {
        ModelCatalog.crossCheckCandidates.filter { ModelCatalog.isInstalled($0) }
    }

    private nonisolated static func makeEngine(_ model: ModelCatalog.Model) -> (any ASREngine)? {
        if model.engine == .appleSpeechAnalyzer {
            guard #available(macOS 26.0, *) else { return nil }
            return SpeechAnalyzerEngine(locale: Locale(identifier: "ja-JP"))
        }
        return SherpaEngine(model: model)
    }

    /// 1エンジン分の prepare + transcribe。パイプラインの子タスクと同じ形にしてある。
    private nonisolated static func runOne(_ model: ModelCatalog.Model,
                                           samples: [Float]) async -> (Int, [Segment])? {
        guard let engine = makeEngine(model) else { return nil }
        defer { (engine as? SherpaEngine)?.shutdown() }
        do {
            try await engine.prepare { _, _ in }
            let segs = try await engine.transcribe(
                ASRRequest(samples: samples, language: "ja", useVAD: false),
                progress: { _ in }, isCancelled: { false })
            return (segs.count, segs)
        } catch {
            print("  \(model.id): 失敗 \(error)")
            return nil
        }
    }

    private nonisolated static func fmt(_ t: TimeInterval) -> String { String(format: "%6.1f", t) }

    /// 11分フィクスチャでの逐次 vs 並列。
    func testCrossCheckSerialVsParallelOnClip() async throws {
        let models = Self.installedCrossChecks
        guard !models.isEmpty else { throw XCTSkip("照合モデルが未取得") }
        let url = Self.fixtureURL("testclip.m4a")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("検証用クリップが無い")
        }
        try await Self.measure(on: url, models: models)
    }

    /// 43分の実録音。並列化の効果がより出るはず。
    /// テストプロセスのサンドボックスで Desktop は読めないので /tmp 経由。
    func testCrossCheckSerialVsParallelOnLongRecording() async throws {
        let url = URL(fileURLWithPath: "/tmp/utsushi-bench-long.m4a")
        let models = Self.installedCrossChecks
        guard !models.isEmpty else { throw XCTSkip("照合モデルが未取得") }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("実録音が無い: \(url.lastPathComponent)")
        }
        try await Self.measure(on: url, models: models)
    }

    /// 112分の雑談配信（RVC-WebUI の voicesample 由来、/tmp 経由）。
    /// 講義音声とは違うジャンル（カジュアル会話・言い淀み多め）で効くかも見る。
    func testCrossCheckSerialVsParallelOnConversation() async throws {
        let url = URL(fileURLWithPath: "/tmp/utsushi-bench-chat.wav")
        let models = Self.installedCrossChecks
        guard !models.isEmpty else { throw XCTSkip("照合モデルが未取得") }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("雑談素材が無い: \(url.lastPathComponent)")
        }
        try await Self.measure(on: url, models: models)
    }

    private nonisolated static func measure(on url: URL, models: [ModelCatalog.Model]) async throws {
        let t0 = Date()
        let audio = try await AudioExtractor().extract(url: url)
        print("=== \(url.lastPathComponent)  音声 \(String(format: "%.0f", audio.duration))s / 抽出 \(fmt(Date().timeIntervalSince(t0)))s ===")
        print("照合エンジン: \(models.map(\.id).joined(separator: ", "))")

        // 逐次 — 並列化前のパイプラインと同じ形
        var serialRuns: [String: [Segment]] = [:]
        var serialTotal: TimeInterval = 0
        for m in models {
            let t = Date()
            if let (_, segs) = await runOne(m, samples: audio.samples) {
                serialRuns[m.id] = segs
            }
            let dt = Date().timeIntervalSince(t)
            serialTotal += dt
            print("  逐次 \(m.id): \(fmt(dt))s")
        }

        // 並列 — 現在のパイプラインと同じ形
        let tp = Date()
        let parallelRuns: [String: [Segment]] = await withTaskGroup(
            of: (String, [Segment]?).self
        ) { group in
            for m in models {
                group.addTask {
                    let r = await runOne(m, samples: audio.samples)
                    return (m.id, r?.1)
                }
            }
            var out: [String: [Segment]] = [:]
            for await (id, segs) in group { if let segs { out[id] = segs } }
            return out
        }
        let parallelTotal = Date().timeIntervalSince(tp)

        print("--- 結果 ---")
        print("逐次合計: \(fmt(serialTotal))s / 並列: \(fmt(parallelTotal))s / 短縮 \(fmt(serialTotal - parallelTotal))s（x\(String(format: "%.2f", serialTotal / max(parallelTotal, 0.001)))）")

        // 品質が変わっていないことの実証: 各エンジンの出力が逐次と並列で一致する
        for m in models {
            let a = serialRuns[m.id], b = parallelRuns[m.id]
            switch (a, b) {
            case (nil, nil):
                continue
            case let (a?, b?):
                XCTAssertEqual(a.count, b.count, "\(m.id): セグメント数が違う")
                for (x, y) in zip(a, b) {
                    XCTAssertEqual(x.original, y.original, "\(m.id): 本文が違う")
                    XCTAssertEqual(x.start, y.start, accuracy: 0.001, "\(m.id): 時刻が違う")
                }
                print("  \(m.id): \(a.count)セグメント 逐次=並列 一致")
            default:
                XCTFail("\(m.id): 逐次と並列で成功/失敗が違う")
            }
        }
    }
}
