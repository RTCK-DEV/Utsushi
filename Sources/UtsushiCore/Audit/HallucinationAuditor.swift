import Foundation

/// ASR出力のハルシネーションを検出して処理する層。
///
/// 前提: **whisperは無音・雑音に対して必ず何かを喋る。** これは確率的な事故ではなく
/// 構造的な性質なので、確率的な対策（プロンプト・閾値）ではなく
/// 決定論的な対策（音が無いなら本文を捨てる）で潰す。
public struct HallucinationAuditor: Sendable {

    public struct Policy: Sendable {
        /// この dBFS を超えるピークが区間内に無ければ「無音」と判定する
        public var silenceDBFS: Float = -45
        /// 区間内で有声とみなすフレームの最小割合
        public var minVoicedRatio: Double = 0.03
        /// 同一本文がこの回数以上連続したら反復ループとみなす
        public var repetitionRunThreshold: Int = 3
        /// 尺がこの秒数以上で、かつ文字密度が下限を切ったら取りこぼし疑い
        public var densityMinDuration: Double = 12
        public var densityMinCharsPerSecond: Double = 0.8
        /// 尺がこの秒数以上で、かつ文字密度が上限を超えたら書き過ぎ疑い。
        /// 短いセグメントはタイムスタンプの丸めで密度が跳ねるので別の下限を置く。
        /// 上限は自然な日本語の最速（秒速10文字前後）を大きく超える 25 に置く。
        /// 連結継ぎ目では 70文字/秒 が実測された。
        public var densityExcessMinDuration: Double = 0.5
        public var densityMaxCharsPerSecond: Double = 25
        /// 尤度がこれを下回れば低信頼
        public var minAvgLogprob: Double = -1.0
        /// 無音確率がこれを超えれば無音扱い
        public var maxNoSpeechProb: Double = 0.85
        /// セグメント間のこの秒数を超える空白は取りこぼし候補として報告する
        public var coverageGapSeconds: Double = 3.0
        /// この尺を超えるセグメントだけ end の妥当性を見る（短いものは誤差の範囲）
        public var overrunMinDuration: Double = 8.0
        /// 最後の有声フレームから残す余白
        public var overrunTailMargin: Double = 0.5
        /// 切り詰めても最低これだけは残す
        public var overrunMinKeptDuration: Double = 0.5
        /// これ未満しか削れないなら触らない（記録が無駄に増えるだけ）
        public var overrunMinTrim: Double = 2.0
        /// この秒数以上、閾値を下回り続けたら「発話が無い区間」として扱う
        public var silenceRunSeconds: Double = 20.0
        /// 反復ループがこの秒数以上続いていたら、破棄するだけでなく読み直す。
        /// 短いループ（「はい。」×3）は本文の損失が小さいので触らない。
        /// 実データでは 44 分のループが破棄されたまま残り、利用者には「14分以降が無い」と見えた。
        public var repetitionRepairMinSeconds: Double = 10.0
        public init() {}
    }

    /// 既知の幻聴フレーズ。**無音と判定された区間にだけ**適用する。
    /// 本当に「ご視聴ありがとうございました」と言っている場合を消さないための条件。
    public static let knownHallucinations: Set<String> = [
        "ご視聴ありがとうございました", "ご視聴ありがとうございました。",
        "ご清聴ありがとうございました", "ご清聴ありがとうございました。",
        "おやすみなさい", "おやすみなさい。",
        "チャンネル登録をお願いします", "最後までご視聴いただきありがとうございます",
        "Thank you for watching", "Thanks for watching.",
        "字幕視聴ありがとうございました", "お疲れ様でした", "お疲れ様でした。",
    ]

    public var policy: Policy
    public init(policy: Policy = Policy()) { self.policy = policy }

    /// 検出記録に載せる秒数の表記
    static func seconds(_ x: Double) -> String {
        x >= 60 ? String(format: "%.1f分", x / 60) : String(format: "%.1f秒", x)
    }

    /// 検出と一次処理（破棄・印付け）。再認識は `repairPlan` が返す区間について呼び出し側が行う。
    public func audit(segments: [Segment],
                      envelope: AudioEnvelope,
                      totalDuration: Double,
                      engineExposesConfidence: Bool) -> (segments: [Segment], report: AuditReport) {
        var out = segments
        var findings: [AuditReport.Finding] = []
        var stats = AuditReport.Stats()
        stats.segmentCount = segments.count

        // 0. 無音をまたいだ end を切り詰める。
        //
        // whisper の VAD は音声を詰めてから認識するので、時刻を戻すときに
        // 「無音の手前のセグメント」に「無音の向こう側の end」が付くことがある。
        // 実測では「はい、では一旦休憩挟みます。」の end が8分先まで伸び、
        // その結果カバー率が 100% と誤報された。
        // 尺は密度異常の判定にもカバー率にも使うので、ここを最初に正す。
        //
        // 先頭側も同じことが起きる（無音の**向こう**のセグメントに無音の手前の start が付く）。
        // 実機では実行のたびにこの形が出たり出なかったりして、認識内容は同じなのに
        // カバー率が 73.5% と 95.1% の間で揺れた。両端を同じ計算で切る。
        for i in out.indices {
            let seg = out[i]
            guard seg.duration > policy.overrunMinDuration else { continue }
            guard let voiced = envelope.voicedSpan(from: seg.start, to: seg.end,
                                                   threshold: policy.silenceDBFS) else {
                // 区間全体が無音。尺は触らず、無音ゲートの判断に委ねる。
                continue
            }
            let trimmedEnd = min(seg.end, max(voiced.upperBound + policy.overrunTailMargin,
                                              seg.start + policy.overrunMinKeptDuration))
            let removedTail = seg.end - trimmedEnd
            if removedTail >= policy.overrunMinTrim { out[i].end = trimmedEnd }

            let trimmedStart = max(seg.start, min(voiced.lowerBound - policy.overrunTailMargin,
                                                  out[i].end - policy.overrunMinKeptDuration))
            let removedHead = trimmedStart - seg.start
            if removedHead >= policy.overrunMinTrim { out[i].start = trimmedStart }

            // これ未満しか削れないなら触らない（記録が無駄に増えるだけ）
            let cuts: [(removed: Double, range: ClosedRange<Double>, where: String)] = [
                (removedTail, trimmedEnd...seg.end,
                 String(localized: "発話の終わりから \(Self.seconds(removedTail)) 先まで")),
                (removedHead, seg.start...trimmedStart,
                 String(localized: "発話の始まりより \(Self.seconds(removedHead)) 手前から")),
            ].filter { $0.removed >= policy.overrunMinTrim }
            guard !cuts.isEmpty else { continue }
            stats.overrunTrimmedCount += 1   // セグメント数。両端を削っても1本は1本
            for cut in cuts {
                stats.overrunTrimmedSeconds += cut.removed
                findings.append(.init(kind: .segmentOverrun,
                                      start: cut.range.lowerBound, end: cut.range.upperBound,
                                      detail: String(localized: "\(cut.where)尺が伸びていたため切り詰めた（この区間に音は無い）"),
                                      action: .repaired))
            }
        }

        // 1. 音圧を全区間に付ける
        for i in out.indices {
            out[i].rmsDBFS = Double(envelope.peakDBFS(from: out[i].start, to: out[i].end))
        }

        // 2. 無音ゲート（決定論。これが幻聴対策の主軸）
        for i in out.indices {
            guard !out[i].original.isEmpty else { continue }
            let peak = envelope.peakDBFS(from: out[i].start, to: out[i].end)
            let voiced = envelope.voicedRatio(from: out[i].start, to: out[i].end,
                                              threshold: policy.silenceDBFS)
            let noSpeech = out[i].noSpeechProb ?? 0
            let silentByAudio = peak <= policy.silenceDBFS || voiced < policy.minVoicedRatio
            let silentByModel = engineExposesConfidence && noSpeech > policy.maxNoSpeechProb

            if silentByAudio || silentByModel {
                out[i].flags.insert(.silenceSuppressed)
                out[i].corrected = ""
                stats.suppressedCount += 1
                findings.append(.init(kind: .silentHallucination,
                                      start: out[i].start, end: out[i].end,
                                      // Substring を localized 補間に渡すと %@ の
                                      // フォーマット経路で落ちるので String にしておく
                                      detail: String(localized: "音圧 \(String(format: "%.1f", peak))dBFS / 有声率 \(String(format: "%.2f", voiced)) の区間に「\(String(segments[i].original.prefix(24)))」が出力された"),
                                      action: .suppressed))
            }
        }

        // 3. 反復ループ検出
        var runStart = 0
        var run = 1
        func closeRun(_ endIndex: Int) {
            if run >= policy.repetitionRunThreshold {
                stats.maxRepetitionRun = max(stats.maxRepetitionRun, run)
                for k in runStart...endIndex where !out[k].isSuppressed {
                    out[k].flags.insert(.repetitionLoop)
                    out[k].corrected = ""
                    stats.suppressedCount += 1
                }
                findings.append(.init(kind: .repetitionLoop,
                                      start: out[runStart].start, end: out[endIndex].end,
                                      detail: String(localized: "「\(String(out[runStart].original.prefix(20)))」が \(run) 回連続した"),
                                      action: .suppressed))
            }
            run = 1
        }
        for i in 1..<max(out.count, 1) {
            let a = out[i-1].original.trimmingCharacters(in: .whitespaces)
            let b = out[i].original.trimmingCharacters(in: .whitespaces)
            if !a.isEmpty && a == b { if run == 1 { runStart = i - 1 }; run += 1 }
            else { closeRun(i - 1) }
        }
        if out.count > 1 { closeRun(out.count - 1) }

        // 4. 既知の幻聴フレーズ（無音区間限定）
        for i in out.indices where out[i].flags.contains(.silenceSuppressed) == false {
            let t = out[i].original.trimmingCharacters(in: .whitespaces)
            guard Self.knownHallucinations.contains(t) else { continue }
            let peak = envelope.peakDBFS(from: out[i].start, to: out[i].end)
            if peak <= policy.silenceDBFS + 6 {
                out[i].flags.insert(.silenceSuppressed)
                out[i].corrected = ""
                stats.suppressedCount += 1
                findings.append(.init(kind: .silentHallucination,
                                      start: out[i].start, end: out[i].end,
                                      detail: String(localized: "既知の幻聴フレーズ「\(t)」が低音圧区間に出力された"),
                                      action: .suppressed))
            }
        }

        // 5. 低尤度
        if engineExposesConfidence {
            for i in out.indices where !out[i].isSuppressed {
                if let lp = out[i].avgLogprob, lp < policy.minAvgLogprob {
                    out[i].flags.insert(.lowConfidence)
                    findings.append(.init(kind: .lowConfidence,
                                          start: out[i].start, end: out[i].end,
                                          detail: String(localized: "平均対数尤度 \(String(format: "%.2f", lp))"),
                                          action: .marked))
                }
            }
        }

        // 6. 文字密度異常（取りこぼし検出）
        for i in out.indices where !out[i].isSuppressed {
            let d = out[i].duration
            guard d >= policy.densityMinDuration else { continue }
            let density = Double(out[i].original.count) / d
            guard density < policy.densityMinCharsPerSecond else { continue }
            let voiced = envelope.voicedRatio(from: out[i].start, to: out[i].end,
                                              threshold: policy.silenceDBFS)
            // 実際に音がある区間だけを疑う。休憩の無音を疑っても意味がない。
            let voicedSeconds = voiced * d
            guard voicedSeconds >= 5 else { continue }
            out[i].flags.insert(.densityAnomaly)
            findings.append(.init(kind: .densityAnomaly,
                                  start: out[i].start, end: out[i].end,
                                  detail: String(localized: "\(String(format: "%.0f", d))秒に \(out[i].original.count) 文字。うち約\(String(format: "%.0f", voicedSeconds))秒は有声"),
                                  action: .unresolved))
        }

        // 6b. 文字密度異常（書き過ぎ）。ブロック境界を跨いだセグメントや連結素材の
        // 継ぎ目では、ありえない速さの本文が出る（実測 70文字/秒）。
        // 取りこぼし側と違い尺の下限を小さく取る。壊れるのは短いセグメントの方。
        for i in out.indices where !out[i].isSuppressed {
            let d = out[i].duration
            guard d >= policy.densityExcessMinDuration else { continue }
            let density = Double(out[i].original.count) / d
            guard density > policy.densityMaxCharsPerSecond else { continue }
            out[i].flags.insert(.densityExcess)
            findings.append(.init(kind: .densityExcess,
                                  start: out[i].start, end: out[i].end,
                                  detail: String(localized: "\(String(format: "%.1f", d))秒に \(out[i].original.count) 文字（\(String(format: "%.0f", density))文字/秒）"),
                                  action: .unresolved))
        }

        // 7. カバレッジの穴
        let ordered = out.sorted { $0.start < $1.start }
        for i in 1..<max(ordered.count, 1) {
            let gap = ordered[i].start - ordered[i-1].end
            guard gap > policy.coverageGapSeconds else { continue }
            let voiced = envelope.voicedRatio(from: ordered[i-1].end, to: ordered[i].start,
                                              threshold: policy.silenceDBFS)
            guard voiced * gap >= 2.0 else { continue }
            findings.append(.init(kind: .coverageGap,
                                  start: ordered[i-1].end, end: ordered[i].start,
                                  detail: String(localized: "\(String(format: "%.1f", gap))秒の空白のうち約\(String(format: "%.1f", voiced * gap))秒に音がある"),
                                  action: .unresolved))
        }

        updateCoverage(&stats, segments: out, envelope: envelope, totalDuration: totalDuration)
        return (out, AuditReport(findings: findings, stats: stats))
    }

    /// 音声を基準にしたカバー率を計算して stats に書く。
    ///
    /// `audit` の最後で一度呼ぶが、**再認識で本文が差し替わったあとにも呼び直す**こと。
    /// 以前は監査時の値が残ったままで、44分ぶん読み直しても 58% と表示され続けた。
    public func updateCoverage(_ stats: inout AuditReport.Stats,
                               segments: [Segment],
                               envelope: AudioEnvelope,
                               totalDuration: Double) {
        // 音声側の無音・有声を先に出す。セグメントの尺ではなく音を基準にする。
        let silent = envelope.silentRanges(minimumSeconds: policy.silenceRunSeconds,
                                           threshold: policy.silenceDBFS,
                                           totalDuration: totalDuration)
        stats.silentRanges = silent.map { .init(start: $0.lowerBound, end: $0.upperBound) }
        let silentSeconds = silent.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        let voicedSeconds = max(0, totalDuration - silentSeconds)
        stats.voicedSeconds = voicedSeconds
        stats.silentSeconds = silentSeconds

        // 有声時間のうち、破棄されていないセグメントが覆っている秒数。
        // セグメントは無音をまたぐことがあるので、またいだ分は数えない。
        var transcribed = 0.0
        for seg in segments where !seg.isSuppressed {
            var overlapWithSilence = 0.0
            for r in silent {
                let lo = max(seg.start, r.lowerBound), hi = min(seg.end, r.upperBound)
                if hi > lo { overlapWithSilence += hi - lo }
            }
            transcribed += max(0, seg.duration - overlapWithSilence)
        }
        stats.transcribedVoicedSeconds = min(transcribed, voicedSeconds)
        stats.coverageRatio = voicedSeconds > 0 ? stats.transcribedVoicedSeconds / voicedSeconds : 0
    }

    /// 読み直す区間とその理由。
    public struct RepairTarget: Sendable, Equatable {
        public var range: ClosedRange<Double>
        public var kind: AuditReport.Finding.Kind
    }

    /// 再認識すべき区間。
    ///
    /// - 取りこぼし疑い・カバレッジの穴: VAD を切って読み直し、VAD が潰した発話を拾い直す
    /// - 長い反復ループ: whisper が同じ句を繰り返し続けた区間。破棄するだけでは本文が消えるので、
    ///   文脈の持ち越しを切って読み直す（持ち越したまま読み直すと同じループに戻る）
    public func repairPlan(from report: AuditReport, padding: Double = 3.0,
                           totalDuration: Double) -> [RepairTarget] {
        let targets = report.findings.filter {
            switch $0.kind {
            case .densityAnomaly, .densityExcess, .coverageGap:
                return $0.action == .unresolved
            case .repetitionLoop: return ($0.end - $0.start) >= policy.repetitionRepairMinSeconds
            default: return false
            }
        }
        var ranges: [RepairTarget] = targets.map {
            RepairTarget(range: max(0, $0.start - padding)...min(totalDuration, $0.end + padding),
                         kind: $0.kind)
        }
        ranges.sort { $0.range.lowerBound < $1.range.lowerBound }
        // 重なる区間はまとめる。理由が混ざったら「反復ループ」を優先する
        // （ループの読み直しは持ち越しを切る必要があり、そちらの方が制約が強い）。
        var merged: [RepairTarget] = []
        for r in ranges {
            if let last = merged.last, r.range.lowerBound <= last.range.upperBound {
                let kind: AuditReport.Finding.Kind =
                    (last.kind == .repetitionLoop || r.kind == .repetitionLoop) ? .repetitionLoop : last.kind
                merged[merged.count - 1] = RepairTarget(
                    range: last.range.lowerBound...max(last.range.upperBound, r.range.upperBound),
                    kind: kind)
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}
