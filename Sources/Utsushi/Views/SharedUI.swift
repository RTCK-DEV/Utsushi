import SwiftUI

/// ラベル・バッジ・タイムスタンプなど、各パネルで繰り返し出る小さい部品。
/// 同じ見た目のコピペを増やさないためにここに集める。

/// 小さい文字を色付きカプセルに入れたバッジ。
struct CapsuleBadge: View {
    private let text: Text
    private let color: Color
    /// 背景と同系色で字も染めたいときに渡す（Summary の種別など）。
    private let foreground: Color?

    /// `label` は翻訳対象なので LocalizedStringKey を受ける。
    init(label: LocalizedStringKey, color: Color, foreground: Color? = nil) {
        text = Text(label); self.color = color; self.foreground = foreground
    }

    /// すでに表示用に組み立て済みの文字列用（既訳テキスト・モデルIDなど翻訳しないもの）。
    init(verbatim: String, color: Color, foreground: Color? = nil) {
        text = Text(verbatim: verbatim); self.color = color; self.foreground = foreground
    }

    var body: some View {
        text
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(foreground ?? .primary)
    }
}

/// セグメントの時刻。monospaced の caption で揃える。
struct TimestampLabel: View {
    let seconds: Double
    var body: some View {
        Text(Exporter.hms(seconds))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

/// 薄い背景を敷いたカード。各行・各項目をまとめる箱。
extension View {
    /// 設定の各タブに共通する見た目。grouped の罫線だけ残して背景は消す。
    func settingsFormStyle() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding()
    }

    func cardBackground() -> some View {
        padding(10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 「名前 … 値」の統計行をまとめて出す箱。
/// AuditPanel と CrossCheckPanel に同じ構造が2系統あったものを1つに。
struct StatRows: View {
    let rows: [(LocalizedStringKey, String)]
    init(_ rows: [(LocalizedStringKey, String)]) { self.rows = rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack {
                    Text(r.0).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(r.1).font(.system(.caption, design: .monospaced))
                }
            }
        }
        .cardBackground()
    }
}
