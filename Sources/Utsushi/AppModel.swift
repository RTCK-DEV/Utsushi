import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

/// キューの1件。URLは不変、結果は status が done のときに入る。
/// 実行中に別ファイルが追加・選択されても、結果は必ずこの項目に入るので
/// 「Aの結果がBの名前で出る」は起きない。
struct QueueItem: Identifiable {
    let id = UUID()
    let url: URL
    var status: Status = .pending
    var info = ""
    var progress: Double = 0
    var transcript: Transcript?
    var correctionOutcome: CorrectionOutcome?

    enum Status: Equatable {
        case pending, running, done, cancelled
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }
}

@MainActor
final class AppModel: ObservableObject {


    // 入力
    @Published var queue: [QueueItem] = []
    @Published var selection: QueueItem.ID?
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var statusMessage = String(localized: "動画または音声ファイルをドロップ")
    @Published var errorMessage: String?
    /// 実行中の項目が始まった時刻。経過表示用。
    @Published var runStartedAt: Date?
    /// 押しかたは Transcript.meta.mode に残る（書き出しにも載る）。
    /// 画面側はそちらを見るので、こちらに別途持たない。

    // 結果は queue の各項目が持つ。selection が指す項目を経由して読む。
    var selectedItem: QueueItem? { queue.first { $0.id == selection } }
    var sourceURL: URL? { selectedItem?.url }
    var transcript: Transcript? { selectedItem?.transcript }
    var correctionOutcome: CorrectionOutcome? { selectedItem?.correctionOutcome }

    /// 設定はまとめて1つの値にしてある。UI側にばらして持つと
    /// 「画面には出ているがパイプラインに渡し忘れる」が起きるため（実際に起きた）。
    /// 変更のたびに保存し、次回起動で選び直さずに済むようにする。
    @Published var settings = SessionSettings() { didSet { scheduleSettingsSave() } }
    @Published var dictionary = UserDictionary.empty
    @Published var correctionAvailability: CorrectionAvailability = .unavailable(String(localized: "未確認"))

    private var pipeline: TranscriptionPipeline?
    /// 「すべて中止」で立てる。現在の項目を止めたあと、待機分も消化しない。
    private var stopAfterCurrent = false
    /// 項目ごとに新しい CancelBox。前の項目のキャンセルが次の項目に漏れないため。
    /// テスト用 produceTranscript にも渡す（偽物にもキャンセルが伝わるように）。
    private var currentCancel = CancelBox()
    /// テスト用の差し替え点。実パイプラインを立てずキューの進行だけ検証するため。
    /// nil のとき実パイプラインで走る。
    var produceTranscript: ((URL, @Sendable () -> Bool,
                           @escaping @Sendable (TranscriptionPipeline.Progress) -> Void)
                            async throws -> Transcript)?
    /// 実行をまたいで使い回す。モデルの再読み込み（10秒前後）を避けるためと、
    /// 終了時に確実に解放するために参照を持ち続ける。
    private var whisperEngine: WhisperEngine?
    /// 話者分離もモデルを読み直さず使い回す。生成モデルは持たないので軽い。
    private var diarizer = DiarizationEngine()
    /// 通知の解除は行わない。AppModel はアプリと同じ寿命なので、
    /// 解除するタイミングが存在しない（deinit は actor 隔離の外なので触れない）。
    private var terminationObserver: NSObjectProtocol?

    private static let dictURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Utsushi/dictionary.json")
    }()

    private static let settingsURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Utsushi/settings.json")
    }()

    /// 起動直後の代入で保存が走るのを防ぐ
    private var settingsLoaded = false
    private var settingsSaveTask: Task<Void, Never>?

    init() {
        loadDictionary()
        loadSettings()
        settingsLoaded = true
        Task { await refreshCorrectionAvailability() }
        // ggml の静的デストラクタが Metal デバイスを片付ける前に whisper_context を解放する。
        // これをしないと、一度でも認識を走らせたあとの終了で ggml_abort により
        // SIGABRT で落ち、毎回クラッシュダイアログが出る（実際に出た）。
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 遅延保存が残っていると終了で消えるので、ここで確定させる
                self?.settingsSaveTask?.cancel()
                self?.saveSettings()
                // 走っている whisper_full が abort_callback で止まるよう先にキャンセルする。
                // 立てないまま context を free すると実行中の認識が解放済みメモリを読む。
                // 現在の項目だけでなくキューの続行も止める。
                // ここで残しを消化しようとすると shutdown 済みのエンジンを触る。
                self?.stopAfterCurrent = true
                self?.currentCancel.set()
                self?.pipeline?.cancel()
                self?.whisperEngine?.shutdown()
                self?.diarizer.shutdown()
            }
        }
    }

    func refreshCorrectionAvailability() async {
        if #available(macOS 26.0, *) {
            correctionAvailability = await FoundationModelsCorrector().isAvailable()
        } else {
            correctionAvailability = .unavailable(String(localized: "macOS 26 以降が必要"))
        }
    }

    // MARK: - 入力

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { accept(urls: panel.urls) }
    }

    /// ファイルをキューに積む。実行中でも追加でき、走っているキューが拾う。
    /// 待機/実行中の同じ URL の重複登録だけは防ぐ（完了・失敗・中止済みは再投入可）。
    func accept(urls: [URL]) {
        var active = Set(queue.filter {
            $0.status == .pending || $0.status == .running
        }.map { $0.url })
        var added: [QueueItem.ID] = []
        for url in urls where !active.contains(url) {
            queue.append(QueueItem(url: url))
            active.insert(url)
            added.append(queue[queue.count - 1].id)
        }
        guard let last = added.last else { return }
        errorMessage = nil
        // 新しいドロップは結果画面の上に積む。実行中・待機中を見ているときは
        // 選択を奪わない（画面が勝手に切り替わると何を見ていたか分からなくなる）。
        let selDone = selectedItem.map {
            switch $0.status { case .done, .failed, .cancelled: return true; default: return false }
        } ?? true
        if selDone {
            selection = last
            // 選択が新しい待機項目に切り替わるので「完了」のまま残さない
            if !isRunning { statusMessage = String(localized: "読み込み中…") }
        }
        for id in added {
            let url = queue.first(where: { $0.id == id })!.url
            Task { [weak self] in
                let info = await Self.describe(url)
                guard let self,
                      let i = self.queue.firstIndex(where: { $0.id == id }) else { return }
                self.queue[i].info = info
                // 選択中の項目のサブタイトルに尺を出す（旧 sourceURL と同じ見え方）
                if self.selection == id, !self.isRunning { self.statusMessage = info }
            }
        }
    }

    /// 行の✕。実行中の行は止めない（中止はキャンセル経路一本）。
    func removeFromQueue(_ id: QueueItem.ID) {
        guard let i = queue.firstIndex(where: { $0.id == id }),
              queue[i].status != .running else { return }
        queue.remove(at: i)
        if selection == id { selection = queue.first?.id }
        if queue.isEmpty {
            statusMessage = String(localized: "動画または音声ファイルをドロップ")
        }
    }

    /// 失敗・中止・完了済みの項目を待機に戻す。
    func requeue(_ id: QueueItem.ID) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].status = .pending
        queue[i].progress = 0
        queue[i].transcript = nil
        queue[i].correctionOutcome = nil
    }

    /// ファイルの尺・サイズ・音声トラックの有無を1行にまとめる
    private static func describe(_ url: URL) async -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }
        let sizeText = size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "-"
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else {
                return String(localized: "音声トラックが無い（\(sizeText)）")
            }
            return String(localized: "\(Exporter.hms(duration))・\(sizeText)・音声トラック \(tracks.count)")
        } catch {
            return String(localized: "読み込めない: \(error.localizedDescription)")
        }
    }

    // MARK: - 実行

    /// 押しかたで構成が決まる。設定でエンジンを切り替える形はやめた。
    /// 「今どちらで走っているか」が画面から消えないようにするため。
    /// 待機分が無いときは選択中の項目をキューに戻して走る（結果を見て回し直す用途）。
    func start(mode: RunMode = .quality) {
        guard !isRunning, !queue.isEmpty else { return }
        if !queue.contains(where: { $0.status == .pending }) {
            guard let sel = selection else { return }
            requeue(sel)
        }
        errorMessage = nil
        isRunning = true
        stopAfterCurrent = false
        statusMessage = String(localized: "準備中")
        Task { await drainQueue(mode: mode) }
    }

    /// 待機中の項目を先頭から順に処理する。実行中に追加された項目も拾う。
    /// 「キャンセル」は現在の項目だけ止めて次へ進む。「すべて中止」は
    /// stopAfterCurrent で残りも止める。
    private func drainQueue(mode: RunMode) async {
        // 終了メッセージは今回の消化分だけを見る。前の実行で残った中止・失敗の
        // 項目がキューにいても、今回の結果としては数えない。
        var sawFailed = false, sawCancelled = false
        while !stopAfterCurrent,
              let idx = queue.firstIndex(where: { $0.status == .pending }) {
            let st = await runItem(at: idx, mode: mode)
            sawFailed = sawFailed || st.isFailure
            sawCancelled = sawCancelled || st == .cancelled
        }
        isRunning = false
        progress = 1
        runStartedAt = nil
        stopAfterCurrent = false
        if sawFailed {
            statusMessage = String(localized: "中断")
        } else if sawCancelled {
            statusMessage = String(localized: "キャンセルした")
        } else {
            statusMessage = String(localized: "完了")
        }
    }

    private func runItem(at idx: Int, mode: RunMode) async -> QueueItem.Status {
        let id = queue[idx].id
        let url = queue[idx].url
        queue[idx].status = .running
        queue[idx].progress = 0
        progress = 0
        runStartedAt = Date()
        // この項目専用のキャンセル箱。前の項目の中止が漏れないよう毎回新しい。
        let box = CancelBox()
        currentCancel = box
        let isCancelled: @Sendable () -> Bool = { box.value }

        // キュー位置は進捗のたびに現在値から計算する。実行中の追加・除去で
        // 件数が動くため、開始時に固定すると「3/2」のような値が出る。
        let updateProgress: @Sendable (TranscriptionPipeline.Progress) -> Void = { [weak self] prog in
            Task { @MainActor in
                guard let self,
                      let i = self.queue.firstIndex(where: { $0.id == id }) else { return }
                self.queue[i].progress = prog.fraction
                self.progress = prog.fraction
                let total = self.queue.count
                self.statusMessage = total > 1
                    ? "\(i + 1)/\(total) \(prog.message)" : prog.message
            }
        }
        updateProgress(.init(stage: .preparing(""), fraction: 0,
                             message: String(localized: "準備中")))

        do {
            let result: Transcript
            if let produce = produceTranscript {
                result = try await produce(url, isCancelled, updateProgress)
            } else {
                result = try await runRealPipeline(url: url, mode: mode,
                                                   onProgress: updateProgress)
            }
            guard let i = queue.firstIndex(where: { $0.id == id }) else { return .cancelled }
            queue[i].transcript = result
            // produceTranscript 経路では pipeline は別項目の古いものが残る。触らない。
            queue[i].correctionOutcome = produceTranscript == nil
                ? await pipeline?.lastCorrectionOutcome : nil
            queue[i].status = .done
            queue[i].progress = 1
            return .done
        } catch {
            guard let i = queue.firstIndex(where: { $0.id == id }) else { return .cancelled }
            if let asr = error as? ASRError, case .cancelled = asr {
                queue[i].status = .cancelled
            } else {
                queue[i].status = .failed(error.localizedDescription)
                // 単発なら従来どおりアラートも出す。バッチ中は行内表示に留める
                // （失敗ごとにモーダルを積むと後始末が操作になってしまう）。
                if queue.count == 1 { errorMessage = error.localizedDescription }
            }
            return queue[i].status
        }
    }

    /// 実パイプラインを組み立てて1ファイル走らせる部分。
    private func runRealPipeline(url: URL, mode: RunMode,
                                 onProgress: @escaping @Sendable (TranscriptionPipeline.Progress) -> Void) async throws -> Transcript {
        let engine: any ASREngine
        switch mode {
        case .quality:
            let model = settings.whisperModel
            // モデルが同じなら読み込み済みのエンジンを使い回す
            if let existing = whisperEngine, existing.modelIdentifier == model.id {
                engine = existing
            } else {
                whisperEngine?.shutdown()
                let fresh = WhisperEngine(model: model)
                whisperEngine = fresh
                engine = fresh
            }
        case .fast:
            if #available(macOS 26.0, *) {
                let loc = settings.language == "ja" ? "ja-JP" : settings.language
                engine = SpeechAnalyzerEngine(locale: Locale(identifier: loc))
            } else {
                // OS内蔵エンジンが無い環境では速い方も whisper で走る。
                // 黙って標準と同じ構成にはしない（LLM段は落としたまま）。
                engine = WhisperEngine(model: settings.whisperModel)
            }
        }

        var corrector: (any CorrectionEngine)? = nil
        var judge: (any DisagreementJudge)? = nil
        var summarizer: (any SummaryEngine)? = nil
        var plausibility: (any PlausibilityChecker)? = nil
        // 高速では LLM を一切用意しない。用意してから設定で落とすと、
        // モデルの読み込みだけ走って時間を食う。
        if mode == .quality, #available(macOS 26.0, *), correctionAvailability.isAvailable {
            if settings.enableCorrection { corrector = FoundationModelsCorrector() }
            if settings.adjudicateDisagreements { judge = FoundationModelsJudge() }
            if settings.enableSummary { summarizer = FoundationModelsSummarizer() }
            if settings.enablePlausibilityCheck { plausibility = FoundationModelsPlausibility() }
        }

        let config = settings.makeConfiguration(dictionary: dictionary,
                                                hasCorrector: corrector != nil,
                                                hasJudge: judge != nil,
                                                hasSummarizer: summarizer != nil,
                                                hasPlausibilityChecker: plausibility != nil,
                                                mode: mode)
        let p = TranscriptionPipeline(engine: engine, corrector: corrector, judge: judge,
                                      summaryEngine: summarizer,
                                      plausibilityChecker: plausibility,
                                      diarizer: diarizer, config: config)
        pipeline = p
        return try await p.run(url: url, onProgress: onProgress)
    }

    /// 実行中の項目を止める。残りの待機分はそのまま次へ進む。
    func cancel() {
        // nonisolated なのでその場で立てられる。Task 経由だと1ランラン遅れる
        currentCancel.set()
        pipeline?.cancel()
        statusMessage = String(localized: "キャンセル中")
    }

    /// 実行中の項目に加えて、待機分の消化も止める。
    func cancelAll() {
        stopAfterCurrent = true
        cancel()
    }

    // MARK: - 校正の採否

    /// 選択中項目の transcript を書き換える共通経路。
    private func editTranscript(_ f: (inout Transcript) -> Void) {
        guard let i = queue.firstIndex(where: { $0.id == selection }),
              queue[i].transcript != nil else { return }
        f(&queue[i].transcript!)
    }

    func revert(_ segment: Segment) {
        editTranscript { t in
            guard let idx = t.segments.firstIndex(where: { $0.id == segment.id }) else { return }
            t.segments[idx].corrected = t.segments[idx].original
            t.segments[idx].correction?.accepted = false
        }
    }

    func reapply(_ segment: Segment) {
        editTranscript { t in
            guard let idx = t.segments.firstIndex(where: { $0.id == segment.id }),
                  let c = t.segments[idx].correction else { return }
            t.segments[idx].corrected = c.after
            t.segments[idx].correction?.accepted = true
        }
    }

    func revertAllCorrections() {
        editTranscript { t in
            for i in t.segments.indices where t.segments[i].correction != nil {
                t.segments[i].corrected = t.segments[i].original
                t.segments[i].correction?.accepted = false
            }
        }
    }

    // MARK: - 話者

    func renameSpeaker(_ id: Int, to name: String) {
        editTranscript { $0.renameSpeaker(id, to: name) }
    }

    /// 誤分離の統合: from の全区間を into に付け替える。
    func mergeSpeakers(from: Int, into: Int) {
        editTranscript { $0.mergeSpeakers(from: from, into: into) }
    }

    /// 1区間の話者を付け替える。nil で話者なしに戻す。
    func setSegmentSpeaker(_ segmentID: UUID, to id: Int?) {
        editTranscript { $0.setSpeaker(of: segmentID, to: id) }
    }

    // MARK: - 書き出し

    func export(_ format: ExportFormat) {
        guard let t = transcript else { return }
        let panel = NSSavePanel()
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "transcript"
        panel.nameFieldStringValue = String(localized: "\(base)_文字起こし.\(format.fileExtension)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Exporter().render(t, as: format)
            try data.write(to: url)
        } catch {
            errorMessage = String(localized: "書き出しに失敗: \(error.localizedDescription)")
        }
    }

    func exportAll() {
        guard let t = transcript else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "このフォルダに書き出す")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "transcript"
        let nameTemplate = String(localized: "%@_文字起こし.%@")
        do {
            try writeAllFormats(t, base: base, to: dir, template: nameTemplate)
        } catch {
            errorMessage = String(localized: "書き出しに失敗: \(error.localizedDescription)")
        }
    }

    /// キューで完了した全項目を1フォルダに書き出す。
    func exportAllDone() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "このフォルダに書き出す")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let nameTemplate = String(localized: "%@_文字起こし.%@")
        do {
            for item in queue where item.status == .done {
                guard let t = item.transcript else { continue }
                try writeAllFormats(
                    t, base: item.url.deletingPathExtension().lastPathComponent,
                    to: dir, template: nameTemplate)
            }
        } catch {
            errorMessage = String(localized: "書き出しに失敗: \(error.localizedDescription)")
        }
    }

    private func writeAllFormats(_ t: Transcript, base: String,
                                 to dir: URL, template: String) throws {
        for f in ExportFormat.allCases {
            let data = try Exporter().render(t, as: f)
            try data.write(to: dir.appendingPathComponent(
                String(format: template, base, f.fileExtension)))
        }
    }

    // MARK: - 辞書

    func loadDictionary() {
        guard let d = Self.loadJSON(UserDictionary.self, from: Self.dictURL) else { return }
        dictionary = d
    }

    func saveDictionary() {
        do {
            try Self.writeJSON(dictionary, to: Self.dictURL)
        } catch {
            errorMessage = String(localized: "辞書の保存に失敗: \(error.localizedDescription)")
        }
    }

    func addDictionaryEntry() {
        dictionary.entries.append(.init(surface: "", reading: "", misspellings: []))
    }

    // MARK: - 設定の保存

    /// スライダーの操作中は毎フレーム didSet が走るので、最後の値だけ書く。
    private func scheduleSettingsSave() {
        guard settingsLoaded else { return }
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveSettings()
        }
    }

    func saveSettings() {
        do {
            try Self.writeJSON(settings, to: Self.settingsURL)
        } catch {
            // 設定が保存できなくても認識は行える。作業を止めるほどではないので本文の邪魔をしない。
            NSLog("Utsushi: 設定の保存に失敗 %@", error.localizedDescription)
        }
    }

    func loadSettings() {
        guard var s = Self.loadJSON(SessionSettings.self, from: Self.settingsURL) else { return }
        s.dropUnknownModels()
        settings = s
    }

    // MARK: - JSON 永続化

    private static func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url)
    }
}
