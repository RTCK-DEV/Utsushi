import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // 2件以上のときだけキューストリップを出す。単発時は従来どおり
            // タイトルバーのファイル名だけで十分で、帯を増やすほどではない。
            if model.queue.count > 1 {
                queueStrip
                Divider()
            }
            detail
        }
        // ドロップの受け口は窓全体。ドラッグ中だけ枠が出れば、
        // 待っている間に巨大な点線枠を並べる必要はない。
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            // 複数ドロップ対応。loadObject は完了順が不定なので、添字付きで
            // 集めてドロップ順を復元する。全部揃った時点で一度だけ accept する。
            let collected = DropCollector(total: providers.count)
            for (i, provider) in providers.enumerated() {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let urls = collected.add(i, url) {
                        Task { @MainActor in model.accept(urls: urls) }
                    }
                }
            }
            return true
        }
        .overlay {
            if isTargeted {
                ZStack {
                    Color.accentColor.opacity(0.08)
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                        .foregroundStyle(Color.accentColor)
                        .padding(16)
                }
                .allowsHitTesting(false)
            }
        }
        // タイトルバーにファイル名・サブタイトルに状態を載せ、操作はツールバーへ。
        // 自作ヘッダーだと macOS 27 の uniform toolbar（Liquid Glass）にならない。
        .navigationTitle(model.sourceURL?.lastPathComponent ?? "Utsushi")
        .navigationSubtitle(Text(verbatim: model.statusMessage))
        .toolbar { controls }
        .alert("エラー", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("閉じる", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// NSItemProvider.loadObject の完了順が不定なので、添字付きで集めて
    /// 最後の1件が揃った時点でドロップ順のURL配列を返す。
    private final class DropCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [(Int, URL)] = []
        private var remaining: Int

        init(total: Int) { remaining = total }

        /// 揃ったらドロップ順の配列、まだなら nil。
        func add(_ index: Int, _ url: URL?) -> [URL]? {
            lock.lock()
            defer { lock.unlock() }
            if let url { results.append((index, url)) }
            remaining -= 1
            guard remaining == 0 else { return nil }
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    // MARK: - キューストリップ

    /// 各ファイルの状態を一目で見る帯。行をタップで詳細に切り替える。
    private var queueStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.queue) { item in
                    queueChip(item)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private func queueChip(_ item: QueueItem) -> some View {
        let isSelected = model.selection == item.id
        // タップで詳細切り替え。ジェスチャでなく Button にして AX から押せるようにする。
        return HStack(spacing: 6) {
            Button { model.selection = item.id } label: {
                HStack(spacing: 6) {
                    statusIcon(item)
                    Text(item.url.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(isSelected ? Color.accentColor.opacity(0.16)
                                       : Color.secondary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if item.status != .running {
                // 実行中の行には✕を出さない（止める経路はキャンセル一本）
                Button { model.removeFromQueue(item.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("キューから外す")
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ item: QueueItem) -> some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "stop.circle").font(.caption2).foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
        }
    }

    // MARK: - 詳細領域

    /// 選択中の項目に応じて中身を切り替える。実行中は進行画面にして
    /// 「今何をしているか・どう止めるか」を主画面に出す。
    @ViewBuilder
    private var detail: some View {
        if let item = model.selectedItem {
            switch item.status {
            case .running:
                runningView(item)
            case .pending:
                pendingView(item)
            case .done:
                if let t = item.transcript {
                    VStack(spacing: 0) {
                        TranscriptView(transcript: t)
                        Divider()
                        footer(t)
                    }
                } else {
                    pendingView(item)
                }
            case .cancelled:
                stoppedView(item, title: "キャンセルした",
                            icon: "stop.circle", tint: .orange, message: nil)
            case .failed(let message):
                stoppedView(item, title: "失敗",
                            icon: "exclamationmark.triangle", tint: .red,
                            message: message)
            }
        } else {
            emptyState
        }
    }

    /// 実行中の専用画面。以前は空状態の上にツールバーの進捗だけが
    /// 乗っていて「どう止めるか」が分からなかった。
    private func runningView(_ item: QueueItem) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 30)).foregroundStyle(.secondary)
            Text(item.url.lastPathComponent).font(.headline)
            Text(verbatim: model.statusMessage)
                .font(.callout).foregroundStyle(.secondary)
            ProgressView(value: model.progress)
                .frame(width: 320)
            if let started = model.runStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(Exporter.hms(Date().timeIntervalSince(started))) 経過")
                        .font(.caption).foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            HStack(spacing: 16) {
                // Esc でも止められる。.cancelAction は Esc に割り当たる。
                Button("キャンセル", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .help("このファイルだけ中止する（残りは続く）")
                if model.queue.contains(where: { $0.status == .pending }) {
                    Button("すべて中止", role: .destructive) { model.cancelAll() }
                        .help("待機中の残りも中止する")
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 待機中。エンジン設定を編集できるのは実行前のこのとき。
    private func pendingView(_ item: QueueItem) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "doc").font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.url.lastPathComponent).font(.headline)
                        Text(verbatim: item.info.isEmpty ? item.url.path : item.info)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        // 実行中は実行ボタンがツールバーから消えるので、
                        // 「ボタンを押せ」とは言わない。
                        Text(model.isRunning
                             ? String(localized: "実行中の項目が終わると処理します")
                             : String(localized: "「高速」または「標準」を押すとキューを処理します"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("ファイルを追加…") { model.presentOpenPanel() }
                }
                capabilityBadges
            }
            .padding(12)
            Divider()
            EngineSettingsForm()
        }
    }

    /// 中止・失敗の共通表示。再投入ボタンを置く。
    private func stoppedView(_ item: QueueItem, title: LocalizedStringKey,
                             icon: String, tint: Color, message: String?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(tint)
            Text(title).font(.headline)
            Text(item.url.lastPathComponent).font(.callout).foregroundStyle(.secondary)
            if let message {
                Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
            }
            Button("キューに戻す") { model.requeue(item.id) }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ツールバー右側の操作。実行状態で中身が変わる。
    @ToolbarContentBuilder
    private var controls: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isRunning {
                ProgressView(value: model.progress).frame(width: 180)
                Button(role: .cancel) { model.cancel() } label: {
                    Label("キャンセル", systemImage: "stop.circle")
                }
                .help("実行中のファイルを中止（Esc）")
            } else if model.queue.isEmpty {
                // ファイルが無いときは唯一の操作が「選ぶ」だけ。
                // CTA はドロップゾーン中央の1つに絞る（ツールバーにも置くと2個になる）。
                SettingsLink { Image(systemName: "gearshape") }
                    .help("設定（⌘,）")
            } else {
                SettingsLink { Image(systemName: "gearshape") }
                    .help("設定（⌘,）")
                Button("別のファイル…") { model.presentOpenPanel() }
                // 押しかたで構成が決まる。**設定を開かずに速さと確からしさを選べる**ようにした。
                // 設定に埋めると「今どちらで走っているか」が画面から消える。
                Button("高速") { model.start(mode: .fast) }
                    .help("OS内蔵エンジンで下書き。照合も校正もしない。57分の録音で30秒ほど。"
                          + "固有名詞は崩れやすい")
                Button("標準") { model.start(mode: .quality) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .help("whisper で認識し、設定した照合を掛ける。57分の録音で5〜10分")
            }
        }
    }

    /// ファイル未選択の空状態。ドロップは窓のどこでも受けるので、
    /// 上は案内と入口のボタンに絞り、残りは「この設定で実行される」
    /// 中身（エンジン設定フォーム）をそのまま出す。
    private var emptyState: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 24)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("動画・音声ファイルをどこにでもドロップ").font(.headline)
                        Text("mov / mp4 / m4a / mp3 / wav など、AVFoundation が読める形式に対応しています。複数まとめてドロップできます")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("音声はこの Mac の中だけで処理されます。外部に送信されることはありません。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // ドロップだけだと「ドロップ以外の道が無い」ように見える。
                    Button("ファイルを選ぶ…") { model.presentOpenPanel() }
                }
                capabilityBadges
            }
            .padding(12)
            Divider()
            EngineSettingsForm()
        }
    }

    /// いまの設定で、まだ手元に無いモデル。
    /// 「開始」を押してから10分待たされて初めてダウンロードだと気づく、
    /// という状態にしないために先に出す。
    private var pendingDownload: (count: Int, bytes: Int64) {
        var wanted: [ModelCatalog.Model] = []
        // 「標準」で使う whisper は取得が要る。「高速」の OS内蔵エンジンは要らない。
        if let m = ModelCatalog.whisperModels.first(where: { $0.id == model.settings.whisperModelID }) {
            wanted.append(m)
        }
        wanted += ModelCatalog.sherpaModels.filter { model.settings.crossCheckModelIDs.contains($0.id) }
        let missing = wanted.filter { !ModelCatalog.isInstalled($0) }
        return (missing.count, missing.reduce(0) { $0 + $1.approximateBytes })
    }

    private var capabilityBadges: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // 「押しかた」バッジは置かない — この画面が出るのは結果が無いときで、
                // 前回のモードを見せても次の実行には影響しない。
                if model.settings.crossCheckModelIDs.isEmpty {
                    badge("照合", String(localized: "なし"), .secondary)
                } else {
                    badge("照合", String(localized: "\(model.settings.crossCheckModelIDs.count) エンジン"), .blue)
                }
                switch model.correctionAvailability {
                case .available:
                    badge("校正LLM", String(localized: "利用可能"), .green)
                case .unavailable(let reason):
                    badge("校正LLM", reason, .orange)
                }
            }
            let pending = pendingDownload
            if pending.bytes > 0 {
                // 連結すると翻訳が引かれない。1つの文字列リテラルに保つこと。
                // 「高速」はモデルの取得が要らないので、落ちるのは「標準」だけと明記する。
                Label("「標準」には初回だけ \(ModelCatalog.sizeText(pending.bytes)) のダウンロードが入る（モデル \(pending.count) 件）",
                      systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.top, 6)
    }

    /// `title` は翻訳対象のラベル、`value` は**すでに表示用に組み立て済み**の値。
    /// `Text` に `String` を渡すと verbatim になり翻訳が引かれないので、
    /// ラベルは `LocalizedStringKey` で受ける。値は呼び出し側で訳しておく。
    private func badge(_ title: LocalizedStringKey, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(verbatim: value).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }

    /// 結果が出ているときだけ表示する（統計と書き出し）。
    private func footer(_ t: Transcript) -> some View {
        HStack(spacing: 10) {
            // どちらの押しかたで作った結果かは本文と同じ場所に置く。
            if let mode = t.meta.mode {
                CapsuleBadge(verbatim: mode.displayName,
                             color: mode == .fast ? .orange : .blue)
                    .help(Text(verbatim: mode.note))
            }
            Text("\(t.visibleSegments.count) セグメント / \(t.totalCharacters) 文字 / カバー率 \(String(format: "%.1f%%", t.audit.stats.coverageRatio * 100))")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu("書き出し") {
                ForEach(ExportFormat.allCases) { f in
                    Button(f.displayName) { model.export(f) }
                }
                Divider()
                Button("全形式をフォルダに書き出す") { model.exportAll() }
                if model.queue.filter({ $0.status == .done }).count > 1 {
                    // キューで複数処理した分を1件ずつ書き出す手間を省く
                    Button("完了分をすべてフォルダに書き出す") { model.exportAllDone() }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
