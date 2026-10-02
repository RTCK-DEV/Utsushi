import XCTest

final class HallucinationAuditorTests: XCTestCase {

    /// 100msホップのエンベロープを作る補助。dbfs は区間ごとの値。
    private func envelope(_ spans: [(Double, Double, Float)], total: Double) -> AudioEnvelope {
        let hop = 0.1
        var values = [Float](repeating: -120, count: Int(total / hop) + 1)
        for (s, e, db) in spans {
            let i0 = max(0, Int(s / hop)), i1 = min(values.count, Int(e / hop))
            guard i0 < i1 else { continue }
            for i in i0..<i1 { values[i] = db }
        }
        return AudioEnvelope(values: values, hop: hop)
    }

    func testSuppressesTextOnSilence() {
        // 実際に今日の録画で起きた事象: 無音の休憩に「ご視聴ありがとうございました」が出る
        let segs = [
            Segment(start: 0, end: 5, original: "本編の発話です"),
            Segment(start: 10, end: 40, original: "ご視聴ありがとうございました"),
        ]
        let env = envelope([(0, 5, -20)], total: 60)
        let (out, report) = HallucinationAuditor().audit(segments: segs, envelope: env,
                                                        totalDuration: 60, engineExposesConfidence: true)
        XCTAssertEqual(out[0].text, "本編の発話です")
        XCTAssertTrue(out[1].isSuppressed)
        XCTAssertEqual(out[1].text, "")
        XCTAssertTrue(report.findings.contains { $0.kind == .silentHallucination })
    }

    func testKeepsRealThanksWhenAudioPresent() {
        // 本当に「ご視聴ありがとうございました」と言っている場合は消さない
        let segs = [Segment(start: 0, end: 3, original: "ご視聴ありがとうございました")]
        let env = envelope([(0, 3, -18)], total: 10)
        let (out, _) = HallucinationAuditor().audit(segments: segs, envelope: env,
                                                   totalDuration: 10, engineExposesConfidence: true)
        XCTAssertFalse(out[0].isSuppressed)
        XCTAssertEqual(out[0].text, "ご視聴ありがとうございました")
    }

    func testDetectsRepetitionLoop() {
        let segs = (0..<5).map { i in
            Segment(start: Double(i) * 30, end: Double(i) * 30 + 30, original: "ご視聴ありがとうございました")
        }
        let env = envelope([(0, 150, -18)], total: 150)   // 音はあるが同じ文が続く
        let (out, report) = HallucinationAuditor().audit(segments: segs, envelope: env,
                                                        totalDuration: 150, engineExposesConfidence: true)
        XCTAssertTrue(out.allSatisfy { $0.isSuppressed })
        XCTAssertTrue(report.findings.contains { $0.kind == .repetitionLoop })
        XCTAssertGreaterThanOrEqual(report.stats.maxRepetitionRun, 5)
    }

    func testDetectsDensityAnomaly() {
        // 今日の 00:00:28–00:01:54 と同じ形: 音があるのに1行しか出ていない
        let segs = [Segment(start: 28, end: 114, original: "おはようございます よろしくお願いします")]
        let env = envelope([(28, 50, -20), (85, 114, -20)], total: 120)
        let (out, report) = HallucinationAuditor().audit(segments: segs, envelope: env,
                                                        totalDuration: 120, engineExposesConfidence: true)
        XCTAssertTrue(out[0].flags.contains(.densityAnomaly))
        let plan = HallucinationAuditor().repairPlan(from: report, totalDuration: 120)
        XCTAssertFalse(plan.isEmpty, "取りこぼし疑いは再認識計画に載るべき")
    }

    func testDetectsDensityExcess() {
        // 連結継ぎ目で実測された形: 1秒に70文字のような、人が喋れない密度
        let segs = [
            Segment(start: 0, end: 2, original: String(repeating: "あ", count: 140)),
            Segment(start: 5, end: 20, original: "これは普通の速さの発話です"),
        ]
        let env = envelope([(0, 20, -20)], total: 20)
        let (out, report) = HallucinationAuditor().audit(segments: segs, envelope: env,
                                                        totalDuration: 20, engineExposesConfidence: true)
        XCTAssertTrue(out[0].flags.contains(.densityExcess))
        XCTAssertFalse(out[1].flags.contains(.densityExcess),
                       "普通の速さの発話を過多と誤検出してはいけない")
        let plan = HallucinationAuditor().repairPlan(from: report, totalDuration: 20)
        XCTAssertTrue(plan.contains { $0.kind == .densityExcess },
                      "書き過ぎ疑いも再認識計画に載るべき")
    }

    func testNoDensityExcessOnFastSpeech() {
        // 早口（10文字/秒級）の本物の発話を弾かない
        let segs = [Segment(start: 0, end: 10, original: String(repeating: "あ", count: 100))]
        let env = envelope([(0, 10, -20)], total: 10)
        let (out, _) = HallucinationAuditor().audit(segments: segs, envelope: env,
                                                   totalDuration: 10, engineExposesConfidence: true)
        XCTAssertFalse(out[0].flags.contains(.densityExcess))
    }

    func testNoDensityAnomalyOnSilentSpan() {
        // 休憩の無音を取りこぼしと誤検出してはいけない
        let segs = [Segment(start: 100, end: 340, original: "では一旦休憩挟みます")]
        let env = envelope([(100, 103, -20)], total: 400)
        let (out, _) = HallucinationAuditor().audit(segments: segs, envelope: env,
                                                   totalDuration: 400, engineExposesConfidence: true)
        XCTAssertFalse(out[0].flags.contains(.densityAnomaly))
    }

    func testSpliceRefusesToLoseInformation() {
        let existing = [Segment(start: 10, end: 20, original: "元の長い発話がここにあります")]
        let fresh = [Segment(start: 12, end: 14, original: "短い")]
        let env = envelope([(10, 20, -20)], total: 30)
        let (out, changed) = TranscriptionPipeline.splice(into: existing, range: 10...20,
                                                         with: fresh, envelope: env,
                                                         policy: .init())
        XCTAssertFalse(changed, "情報が減る差し替えは行わない")
        XCTAssertEqual(out, existing)
    }

    func testSpliceReplacesWhenRicher() {
        let existing = [Segment(start: 10, end: 20, original: "短い")]
        let fresh = [
            Segment(start: 11, end: 15, original: "こちらのほうが情報量が多い発話"),
            Segment(start: 15, end: 19, original: "さらに続きがあります"),
        ]
        let env = envelope([(10, 20, -20)], total: 30)
        let (out, changed) = TranscriptionPipeline.splice(into: existing, range: 10...20,
                                                         with: fresh, envelope: env,
                                                         policy: .init())
        XCTAssertTrue(changed)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.allSatisfy { $0.flags.contains(.repaired) })
    }

    func testSpliceDropsHallucinationInFreshResult() {
        // 再認識側にも幻聴は乗る。差し込む前に落とす。
        let existing = [Segment(start: 10, end: 40, original: "短い")]
        let fresh = [
            Segment(start: 11, end: 30, original: "ご視聴ありがとうございました"),
            Segment(start: 30, end: 39, original: "実際に喋っている中身です"),
        ]
        let env = envelope([(28, 40, -20)], total: 50)
        let (out, changed) = TranscriptionPipeline.splice(into: existing, range: 10...40,
                                                         with: fresh, envelope: env,
                                                         policy: .init())
        XCTAssertTrue(changed)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].original, "実際に喋っている中身です")
    }
}
