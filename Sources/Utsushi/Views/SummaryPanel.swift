import SwiftUI

/// 要約。見出しと、その根拠になった引用をそのまま並べる。
///
/// 引用を畳んで隠さないのは、要約だけを読んで判断されると
/// 「モデルが選び間違えた」ことに気づけないため。
struct SummaryPanel: View {
    let summary: Summary
    @State private var kinds: Set<Summary.PointKind> = Set(Summary.PointKind.allCases)

    private var visible: [Summary.Point] {
        summary.points.filter { kinds.contains($0.kind) }
    }

    var body: some View {
        if summary.isEmpty {
            ContentUnavailableView("要約はありません", systemImage: "text.append",
                                   description: Text("設定の「校正」タブで要約を有効にすると、\n次回の実行から要点を抜き出します。"))
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visible) { point in
                            row(point)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Summary.PointKind.allCases, id: \.self) { k in
                    let on = kinds.contains(k)
                    Button {
                        if on { kinds.remove(k) } else { kinds.insert(k) }
                    } label: {
                        Text("\(k.displayName) \(summary.points.filter { $0.kind == k }.count)")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? .accentColor : .secondary)
                }
                Spacer()
            }
            let rejected = summary.stats.rejectedHeadlineCount
            let invalid = summary.stats.invalidReferenceCount
            let failed = summary.stats.failedChunkCount
            // 連結すると String になり翻訳が引かれない。各部分を先に訳してから足す。
            Text(String(localized: "要点 \(summary.points.count)件・モデルの見出しが通った割合 \(Int(summary.modelHeadlineRatio * 100))%")
                 + (rejected > 0 ? String(localized: "・見出し棄却 \(rejected)件") : "")
                 + (invalid > 0 ? String(localized: "・存在しない行の参照 \(invalid)件") : "")
                 + (failed > 0 ? String(localized: "・要約に失敗した塊 \(failed)件") : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func row(_ p: Summary.Point) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CapsuleBadge(verbatim: p.kind.displayName, color: color(p.kind), foreground: color(p.kind))
                TimestampLabel(seconds: p.start)
                Text(p.headline).font(.headline).textSelection(.enabled)
                if p.headlineSource == .extracted {
                    Image(systemName: "text.quote")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("モデルの見出しが検証で落ちたため、原文から機械的に抜き出したもの")
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(p.quotes.enumerated()), id: \.offset) { _, q in
                Text(q)
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ k: Summary.PointKind) -> Color {
        switch k {
        case .topic: return .blue
        case .decision: return .green
        case .action: return .orange
        case .number: return .purple
        case .question: return .pink
        }
    }
}
