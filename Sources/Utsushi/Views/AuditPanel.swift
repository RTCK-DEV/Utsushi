import SwiftUI

struct AuditPanel: View {
    @EnvironmentObject var model: AppModel
    let transcript: Transcript

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                if let o = model.correctionOutcome { correctionStats(o) }
                plausibility
                findings
                discarded
            }
            .padding(14)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ASR検証").font(.headline)
            StatRows([
                ("セグメント数", "\(transcript.audit.stats.segmentCount)"),
                ("本文を破棄した区間", "\(transcript.audit.stats.suppressedCount)"),
                ("再認識で差し替え", "\(transcript.audit.stats.repairedCount)"),
                ("発話カバー率", String(format: "%.1f%%", transcript.audit.stats.coverageRatio * 100)),
                ("　発話のある時間", Exporter.hms(transcript.audit.stats.voicedSeconds)),
                ("　無音の時間", Exporter.hms(transcript.audit.stats.silentSeconds)),
                ("最大反復連続数", "\(transcript.audit.stats.maxRepetitionRun)"),
            ])
        }
    }

    /// 文脈から浮いて見える語。**書き出しにしか出ていなかったので画面にも出す。**
    ///
    /// 出し方に注意が要る。この仕組みがやっているのは有無の判定ではなく順位付けで、
    /// **誤りの無い区間でも1件は出る**（実測。「どれも問題ない」という逃げ道を
    /// 与えても使わなかった）。「指摘された＝誤り」と読める見せ方にすると、
    /// 正しい本文に疑いを持たせることになる。
    @ViewBuilder
    private var plausibility: some View {
        let flags = transcript.plausibility
        if !flags.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("文脈から浮いて見える語（\(flags.count)件）").font(.headline)
                // 文字列を + で連結すると String になり、SwiftUI は Markdown を解釈しない
                // （LocalizedStringKey にならない）。強調記法は使わずに1本の文字列で書く。
                Text("区間ごとに、最も文脈に合わない語を1つ選んでいます。誤りのない区間でも1件は出るため、誤りの証拠ではなく確認の手掛かりとしてご覧ください。本文は書き換えていません。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(flags) { f in
                    HStack(alignment: .top, spacing: 8) {
                        TimestampLabel(seconds: f.start)
                            .frame(width: 68, alignment: .leading)
                        Text("「\(f.surface)」")
                            .font(.caption).textSelection(.enabled)
                        // 文言は PlausibilityFlag.alternativeNote が持つ（書き出しと同じもの）。
                        Text(f.alternativeNote)
                            .font(f.alternative != nil ? .caption : .caption2)
                            .foregroundStyle(f.alternative != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// 破棄した本文をそのまま見せる。
    /// 件数だけ出しても、ゲートが正しく効いたのか誤爆したのか区別が付かない。
    @ViewBuilder
    private var discarded: some View {
        let items = transcript.suppressedSegments
        let gaps = transcript.gaps()
        if !items.isEmpty || !gaps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("破棄した本文（\(items.count)件）").font(.headline)
                if items.isEmpty {
                    Text("なし").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("無音または反復として本文を捨てた区間です。誤って捨てていないかを、ここで確認できます。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(items) { seg in
                        HStack(alignment: .top, spacing: 8) {
                            TimestampLabel(seconds: seg.start)
                                .frame(width: 68, alignment: .leading)
                            Text(seg.original)
                                .font(.caption).foregroundStyle(.secondary)
                                .strikethrough()
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            CapsuleBadge(
                                label: seg.flags.contains(.repetitionLoop)
                                    ? LocalizedStringKey("反復") : LocalizedStringKey("無音"),
                                color: .red)
                        }
                    }
                }
                if !gaps.isEmpty {
                    Text("発話の無い区間（\(gaps.count)件）").font(.subheadline).padding(.top, 6)
                    ForEach(Array(gaps.enumerated()), id: \.offset) { _, g in
                        // 端数は切り上げる。35秒の穴を「0分」と書くと誤解される。
                        // 連結すると翻訳が引かれないので1つのリテラルに保つ
                        Text("\(Exporter.hms(g.lowerBound)) – \(Exporter.hms(g.upperBound))（\(Int(((g.upperBound - g.lowerBound) / 60).rounded(.up)))分）")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func correctionStats(_ o: CorrectionOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("校正ゲート").font(.headline)
            StatRows([
                ("辞書による置換", "\(o.dictionary)"),
                ("決定論ルール適用", "\(o.deterministic)"),
                ("LLM提案", "\(o.proposed)"),
                ("ゲート通過して採用", "\(o.accepted)"),
                ("エンジンエラー", "\(o.engineErrors)"),
            ])
            if !o.rejected.isEmpty {
                Text("棄却された提案").font(.subheadline).padding(.top, 4)
                StatRows(o.rejected.sorted { $0.value > $1.value }.map { (Self.rejectionLabel($0.key), "\($0.value)") })
            }
        }
    }

    private var findings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("検出項目（\(transcript.audit.findings.count)件）").font(.headline)
            if transcript.audit.findings.isEmpty {
                Text("検出なし").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(transcript.audit.findings) { f in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(f.action)).foregroundStyle(color(f.action))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Exporter.hms(f.start)) – \(Exporter.hms(f.end))　\(Self.kindLabel(f.kind))")
                            .font(.system(.caption, design: .monospaced))
                        Text(f.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    CapsuleBadge(label: actionLabel(f.action), color: color(f.action))
                }
                .cardBackground()
            }
        }
    }

    private func icon(_ a: AuditReport.Finding.Action) -> String {
        switch a {
        case .suppressed: return "trash"
        case .repaired: return "arrow.triangle.2.circlepath"
        case .marked: return "flag"
        case .unresolved: return "exclamationmark.triangle"
        }
    }
    private func color(_ a: AuditReport.Finding.Action) -> Color {
        switch a {
        case .suppressed: return .red
        case .repaired: return .blue
        case .marked: return .orange
        case .unresolved: return .yellow
        }
    }
    private func actionLabel(_ a: AuditReport.Finding.Action) -> LocalizedStringKey {
        switch a {
        case .suppressed: return "破棄"
        case .repaired: return "再認識で修復"
        case .marked: return "印付け"
        case .unresolved: return "未解決"
        }
    }
    /// 書き出し側の `Exporter.label` と同じ区分を、画面の言語で出す。
    /// 書き出しは作った時点の文書として残るので、ここだけ表示言語に追従させる。
    static func kindLabel(_ k: AuditReport.Finding.Kind) -> String {
        switch k {
        case .silentHallucination: return String(localized: "無音区間の幻聴")
        case .repetitionLoop: return String(localized: "反復ループ")
        case .densityAnomaly: return String(localized: "取りこぼし疑い")
        case .densityExcess: return String(localized: "書き過ぎ疑い")
        case .lowConfidence: return String(localized: "低信頼")
        case .coverageGap: return String(localized: "カバレッジの穴")
        case .segmentOverrun: return String(localized: "尺が発話より長い")
        }
    }
    static func rejectionLabel(_ raw: String) -> LocalizedStringKey {
        switch raw {
        case "readingChanged": return "読みが変わる書き換え"
        case "lengthOutOfRange": return "長さが許容外"
        case "editDistanceTooLarge": return "変更量が大きすぎる"
        case "readingUnavailable": return "読みを取得できず検証不能"
        case "emptyResult": return "空文字にされた"
        case "newLatinToken": return "原文に無い英数字が出現"
        case "disagreement": return "2回の提案が不一致"
        // 未知の棄却理由は機械キーをそのまま見せる（以前と同じ見え方）
        default: return LocalizedStringKey(raw)
        }
    }
}
