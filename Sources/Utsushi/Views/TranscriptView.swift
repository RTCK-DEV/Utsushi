import SwiftUI

struct TranscriptView: View {
    @EnvironmentObject var model: AppModel
    let transcript: Transcript
    @State private var tab: Tab = .text
    @State private var renameTarget: Int?
    @State private var renameText = ""

    enum Tab: String, CaseIterable, Identifiable {
        case text = "本文"
        case summary = "要約"
        case corrections = "校正差分"
        case crossCheck = "照合"
        case audit = "検証記録"
        var id: String { rawValue }
        /// rawValue（String）をそのまま Text に渡すと翻訳を通らないので
        /// LocalizedStringKey 経由にする
        var displayName: LocalizedStringKey { LocalizedStringKey(rawValue) }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
        .padding(8)
    }

    var body: some View {
        VStack(spacing: 0) {
            // macOS 27 の TabsPickerStyle — 「タブ切り替え」用の見た目・読み上げになる。
            // segmented は値選択用なので意味が違う。26 では segmented に落とす。
            if #available(macOS 27.0, *) {
                tabPicker.pickerStyle(.tabs)
            } else {
                tabPicker.pickerStyle(.segmented)
            }
            Divider()
            switch tab {
            case .text: textList
            case .summary: SummaryPanel(summary: transcript.summary)
            case .corrections: correctionList
            case .crossCheck: CrossCheckPanel(report: transcript.crossCheck)
            case .audit: AuditPanel(transcript: transcript)
            }
        }
        .alert("話者名を変更", isPresented: .init(get: { renameTarget != nil },
                                                     set: { if !$0 { renameTarget = nil } })) {
            TextField("名前", text: $renameText)
            Button("キャンセル", role: .cancel) { renameTarget = nil }
            Button("決定") {
                if let id = renameTarget { model.renameSpeaker(id, to: renameText) }
                renameTarget = nil
            }
        } message: {
            Text("空欄にすると番号表示に戻ります")
        }
    }

    private func beginRename(_ speaker: Int) {
        renameText = transcript.meta.speakerNames[speaker] ?? ""
        renameTarget = speaker
    }

    private var textList: some View {
        let segs = transcript.visibleSegments
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if !transcript.speakerIDs.isEmpty {
                    SpeakerStrip(transcript: transcript, onRename: beginRename)
                        .padding(.horizontal, 14).padding(.top, 8)
                    SpeakerTimeline(transcript: transcript) { time in
                        guard let target = segs.first(where: { $0.end > time })?.id
                                    ?? segs.last?.id else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    Divider()
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(segs.enumerated()), id: \.element.id) { index, seg in
                            HStack(alignment: .top, spacing: 10) {
                                TimestampLabel(seconds: seg.start)
                                    .frame(width: 68, alignment: .leading)
                                if let speaker = seg.speaker {
                                    SpeakerMenu(speaker: speaker, segment: seg,
                                                transcript: transcript,
                                                isTurnChange: index == 0 || segs[index - 1].speaker != speaker,
                                                onRename: beginRename)
                                }
                                Text(seg.text).textSelection(.enabled)
                                Spacer(minLength: 0)
                                if seg.flags.contains(.lowConfidence) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(.orange).help("尤度が低い区間")
                                }
                                if seg.flags.contains(.repaired) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundStyle(.blue).help("再認識で差し替えた区間")
                                }
                            }
                            .padding(.horizontal, 14)
                            .id(seg.id)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var correctionList: some View {
        let corrected = transcript.segments.filter { $0.correction != nil }
        return Group {
            if corrected.isEmpty {
                ContentUnavailableView("校正による変更はありません", systemImage: "checkmark.seal",
                                       description: Text("すべてのセグメントが原文のままです。"))
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(corrected.count) 件の変更").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("すべて原文に戻す") { model.revertAllCorrections() }
                            .font(.caption)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(corrected) { seg in
                                CorrectionRow(segment: seg)
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
    }
}

/// 話者の色分けバッジ。連続する同一話者の行では色の筋だけ出して、
/// 話が切り替わる区切り（ターン）では名前を出す。
struct SpeakerBadge: View {
    let speaker: Int
    let isTurnChange: Bool
    var name: String? = nil

    /// 話者番号から固定の色を引く。順番に似すぎない色になるよう
    /// 色相環を飛び飛びに回す（最大8話者想定）。
    static func color(for speaker: Int) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink,
                                .teal, .indigo, .brown]
        return palette[(speaker - 1) % palette.count]
    }

    var body: some View {
        let color = Self.color(for: speaker)
        if isTurnChange {
            Text(name ?? "S\(speaker)")
                .font(.system(.caption2, design: .monospaced).bold())
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color, in: Capsule())
                .help(name ?? String(localized: "話者 \(speaker)"))
        } else {
            Capsule()
                .fill(color)
                .frame(width: 18, height: 4)
                .padding(.top, 7)
        }
    }
}

/// バッジを押したときの話者操作。`Menu` のカスタム label は macOS で
/// 色・shape・背景を描かないため（Text がそのままボタンタイトルになる）、
/// バッジはただの Button にして中身は popover で出す。
struct SpeakerMenu: View {
    @EnvironmentObject var model: AppModel
    let speaker: Int
    let segment: Segment
    let transcript: Transcript
    let isTurnChange: Bool
    let onRename: (Int) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            SpeakerBadge(speaker: speaker, isTurnChange: isTurnChange,
                         name: transcript.meta.speakerNames[speaker])
                .frame(minWidth: 18, minHeight: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SpeakerActions(speaker: speaker, segment: segment,
                           transcript: transcript, onRename: onRename,
                           dismiss: { open = false })
        }
    }
}

/// 話者チップと行バッジで共用するアクション一覧。
/// `segment` を渡すと1区間の再割り当て項目が出る（話者全体の操作では隠す）。
struct SpeakerActions: View {
    @EnvironmentObject var model: AppModel
    let speaker: Int
    var segment: Segment? = nil
    let transcript: Transcript
    let onRename: (Int) -> Void
    let dismiss: () -> Void

    private var others: [Int] { transcript.speakerIDs.filter { $0 != speaker } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            action(Text("名前を変更…")) { onRename(speaker) }
            if !others.isEmpty {
                Divider().padding(.vertical, 3)
                header(Text("他の話者に統合"))
                ForEach(others, id: \.self) { id in
                    action(Text("\(transcript.speakerName(id))に統合")) {
                        model.mergeSpeakers(from: speaker, into: id)
                    }
                }
            }
            if let seg = segment {
                Divider().padding(.vertical, 3)
                header(Text("この発言を別の話者に"))
                ForEach(others, id: \.self) { id in
                    action(Text(verbatim: transcript.speakerName(id))) {
                        model.setSegmentSpeaker(seg.id, to: id)
                    }
                }
                action(Text("新しい話者")) {
                    model.setSegmentSpeaker(seg.id, to: (transcript.speakerIDs.max() ?? 0) + 1)
                }
                Divider().padding(.vertical, 3)
                action(Text("話者なし")) { model.setSegmentSpeaker(seg.id, to: nil) }
            }
        }
        .padding(8)
        .frame(minWidth: 180)
    }

    private func header(_ label: Text) -> some View {
        label.font(.caption).foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func action(_ label: Text, _ body: @escaping () -> Void) -> some View {
        Button { body(); dismiss() } label: {
            label.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 登場する話者の一覧。名前・発話割合を出し、押すと改名・統合メニュー。
struct SpeakerStrip: View {
    @EnvironmentObject var model: AppModel
    let transcript: Transcript
    let onRename: (Int) -> Void

    var body: some View {
        let durations = transcript.speakerDurations
        let total = durations.values.reduce(0, +)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(transcript.speakerIDs, id: \.self) { id in
                    let share = total > 0 ? durations[id, default: 0] / total : 0
                    speakerChip(id: id, share: share)
                }
            }
        }
    }

    private func speakerChip(id: Int, share: Double) -> some View {
        SpeakerChip(id: id, share: share, transcript: transcript, onRename: onRename)
    }

    /// 色丸＋名前＋発話割合のチップ。Badge と同じく Menu では描画が化けるので
    /// Button+popover にしてある。
    private struct SpeakerChip: View {
        @EnvironmentObject var model: AppModel
        let id: Int
        let share: Double
        let transcript: Transcript
        let onRename: (Int) -> Void
        @State private var open = false

        var body: some View {
            let color = SpeakerBadge.color(for: id)
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(transcript.speakerName(id)).font(.caption).lineLimit(1)
                    Text(verbatim: "\(Int((share * 100).rounded()))%")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(color.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SpeakerActions(speaker: id, transcript: transcript,
                               onRename: onRename, dismiss: { open = false })
            }
        }
    }
}

/// 発話の俯瞰バー。同じ話者の連続区間をまとめた色ブロックを時間順に並べ、
/// タップでその時刻のセグメントへジャンプする。
struct SpeakerTimeline: View {
    let transcript: Transcript
    let onSeek: (Double) -> Void

    /// 表示区間を走り抜けて、連続同一話者の塊と無発話の隙間に分解する。
    private var blocks: [(start: Double, end: Double, speaker: Int?)] {
        var out: [(start: Double, end: Double, speaker: Int?)] = []
        var cursor = 0.0
        for seg in transcript.visibleSegments where seg.end > seg.start {
            if seg.start > cursor + 0.2 {
                out.append((cursor, seg.start, nil))
            }
            if let last = out.last, last.speaker == seg.speaker,
               seg.start - last.end <= 0.2 {
                out[out.count - 1].end = seg.end
            } else {
                out.append((seg.start, seg.end, seg.speaker))
            }
            cursor = max(cursor, seg.end)
        }
        if cursor < transcript.meta.sourceDuration {
            out.append((cursor, transcript.meta.sourceDuration, nil))
        }
        return out
    }

    var body: some View {
        let duration = max(transcript.meta.sourceDuration,
                           transcript.visibleSegments.last?.end ?? 1)
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    Rectangle()
                        .fill(block.speaker.map { SpeakerBadge.color(for: $0) }
                              ?? Color.secondary.opacity(0.15))
                        .frame(width: max(1.5, geo.size.width * CGFloat((block.end - block.start) / duration)))
                }
            }
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .onTapGesture { loc in
                onSeek(min(max(0, loc.x / geo.size.width), 1) * duration)
            }
        }
        .frame(height: 16)
        .accessibilityLabel(Text("発話タイムライン"))
    }
}

struct CorrectionRow: View {
    @EnvironmentObject var model: AppModel
    let segment: Segment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TimestampLabel(seconds: segment.start)
                CapsuleBadge(label: ruleLabel, color: .accentColor)
                Spacer()
                if segment.correction?.accepted == true {
                    Button("原文に戻す") { model.revert(segment) }.font(.caption)
                } else {
                    Button("校正を適用") { model.reapply(segment) }.font(.caption)
                }
            }
            Text(segment.original)
                .foregroundStyle(.secondary).strikethrough(segment.correction?.accepted == true)
                .textSelection(.enabled)
            Text(segment.correction?.after ?? "")
                .foregroundStyle(segment.correction?.accepted == true ? .primary : .secondary)
                .textSelection(.enabled)
        }
        .cardBackground()
    }

    private var ruleLabel: LocalizedStringKey {
        switch segment.correction?.rule {
        case .dictionary: return "辞書"
        case .fillerRemoval: return "フィラー除去"
        case .notation: return "表記統一"
        case .languageModel: return "LLM（ゲート通過）"
        case .none: return "-"
        }
    }
}
