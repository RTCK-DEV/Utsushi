import SwiftUI

/// 別エンジンとの食い違いと、その判定結果。
struct CrossCheckPanel: View {
    let report: CrossCheckReport
    /// 中身の違い以外も一覧に混ぜるか。
    /// 既定では畳む。ただし件数は常に出し、開けば全部見られるようにしておく
    /// ——分類はどれも機械的な近似で外すことがあるので、見えなくしてはいけない。
    @State private var showsAll = false

    private var substantive: [TranscriptAlignment.Disagreement] {
        report.disagreements.filter { $0.kind == .substantive }
    }
    private func count(_ kind: TranscriptAlignment.Kind) -> Int {
        report.disagreements.filter { $0.kind == kind }.count
    }
    private var foldedCount: Int { report.disagreements.count - substantive.count }
    private var listed: [TranscriptAlignment.Disagreement] {
        showsAll ? report.disagreements : substantive
    }

    var body: some View {
        if report.engines.count < 2 {
            ContentUnavailableView("照合していません", systemImage: "arrow.triangle.branch",
                                   description: Text("設定の「照合」タブで別エンジンを有効にすると、\n食い違う箇所を洗い出せます。"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    list
                }
                .padding(14)
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("照合エンジン").font(.headline)
            Text(report.engines.joined(separator: " / "))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)

            let o = report.outcome
            StatRows([
                ("食い違い（全件）", "\(report.disagreements.count)"),
                ("　中身の違い", "\(substantive.count)"),
                ("　整列のずれ（本文は両方にある）", "\(count(.alignment))"),
                ("　語尾・助詞のゆれ（と / って）", "\(count(.inflection))"),
                ("　表記だけの違い（三月 / 3月）", "\(count(.notation))"),
            ])
            StatRows([
                ("判定できた", "\(o.decided)"),
                ("　うち読みが一致（同音異義語）", "\(o.decidedWithMatchingReadings)"),
                ("　うち読みが不一致（音響情報を無視した推定）", "\(o.decidedWithDifferentReadings)"),
                ("人の目が要る", "\(max(0, o.undecided - o.skipped))"),
                ("2回の判定が割れた", "\(o.disagreedBetweenSamples)"),
                ("判定エラー", "\(o.errors)"),
            ])

            if o.decidedWithDifferentReadings > 0 {
                Label("読みが違う判定は音響情報を使っていないため、確度が落ちます。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    static func kindLabel(_ kind: TranscriptAlignment.Kind) -> LocalizedStringKey? {
        switch kind {
        case .substantive: return nil
        case .notation:    return "表記だけ"
        case .alignment:   return "整列のずれ"
        case .inflection:  return "語尾のゆれ"
        }
    }

    private func candidateText(_ text: String) -> Text {
        text.isEmpty ? Text("（なし）") : Text(text)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("食い違い（\(listed.count)件）").font(.headline)
                Spacer()
                if foldedCount > 0 {
                    Toggle("整列・語尾・表記の違い \(foldedCount)件も表示", isOn: $showsAll)
                        .toggleStyle(.checkbox).font(.caption)
                }
            }
            if report.disagreements.isEmpty {
                Text("すべてのエンジンの出力が一致しました。").font(.caption).foregroundStyle(.secondary)
            } else if listed.isEmpty {
                Text("中身の違いはありません。残りは、整列・語尾・表記の違いです。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(listed) { d in
                let verdict = report.adjudications.first { $0.disagreementID == d.id }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        TimestampLabel(seconds: d.start)
                        CapsuleBadge(
                            label: d.readingsMatch
                                ? LocalizedStringKey("読み一致") : LocalizedStringKey("読み不一致"),
                            color: d.readingsMatch ? .blue : .orange)
                        if let label = Self.kindLabel(d.kind) {
                            CapsuleBadge(label: label, color: .secondary)
                        }
                        Spacer()
                        if !d.kind.needsHumanReview {
                            Label("判定対象外", systemImage: "minus.circle")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else if let v = verdict, v.chosenText != nil {
                            Label("判定済み", systemImage: "checkmark.circle")
                                .font(.caption2).foregroundStyle(.green)
                        } else {
                            Label("未判定", systemImage: "questionmark.circle")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(d.candidates.enumerated()), id: \.offset) { _, c in
                        HStack(alignment: .top, spacing: 6) {
                            Text(c.engine)
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(width: 130, alignment: .leading)
                            // c.text は認識本文なので verbatim。空のときだけ訳した置き場を出す。
                            candidateText(c.text)
                                .fontWeight(verdict?.chosenText == c.text ? .semibold : .regular)
                                .textSelection(.enabled)
                        }
                    }
                    if !d.context.isEmpty {
                        Text(d.context)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .cardBackground()
            }
        }
    }
}
