import Foundation

/// whisper.cpp を静的リンクして直接呼ぶ。サブプロセスもPythonも挟まない。
///
/// 静的リンクなので Hardened Runtime 下で未署名 dylib を読み込む問題が起きない
/// （`disable-library-validation` を付けずに済む）。
public actor WhisperEngine: ASREngine {
    public nonisolated let identifier = "whisper.cpp"
    public nonisolated var displayName: String { "whisper.cpp (\(model.displayName))" }
    public nonisolated let supportsVAD = true
    public nonisolated let exposesConfidence = true
    public nonisolated let supportsVocabularyHint = true

    public struct Options: Sendable {
        public var threads: Int32 = 8
        public var beamSize: Int32 = 5
        public var bestOf: Int32 = 5
        public var vadThreshold: Float = 0.5
        public var vadMinSpeechMs: Int32 = 250
        public var vadMinSilenceMs: Int32 = 100
        public var vadMaxSpeechSec: Float = 30
        public var vadSpeechPadMs: Int32 = 100
        public var noSpeechThreshold: Float = 0.6
        public var entropyThreshold: Float = 2.4
        public var logprobThreshold: Float = -1.0
        /// 直前の窓の認識結果をどれだけ次の窓の prompt に持ち越すか（トークン数）。
        /// nil なら whisper.cpp の既定（16384）。**0 にすると持ち越さない。**
        /// 反復ループの調査用に外から触れるようにしてある。
        public var maxTextContext: Int32? = nil
        public init() {}
    }

    private let model: ModelCatalog.Model
    private let options: Options
    /// actor 隔離の外からも解放できるようにロック付きの箱で持つ。
    /// アプリ終了時、ggml の静的デストラクタが Metal デバイスを片付ける前に
    /// whisper_context を解放しておかないと ggml_abort で落ちる（実際に落ちた）。
    private nonisolated let context = NativeObjectBox(destroy: { whisper_free($0) })
    private var vadPath: String?

    public init(model: ModelCatalog.Model = ModelCatalog.whisperModels[0], options: Options = Options()) {
        self.model = model
        self.options = options
    }

    /// 明示的な解放。アプリ終了時に必ず呼ぶこと。
    /// actor の外（NSApplication の終了通知など）からも呼べるよう nonisolated にしてある。
    public nonisolated func shutdown() { context.free() }

    public nonisolated var isLoaded: Bool { context.pointer != nil }
    public nonisolated var modelIdentifier: String { model.id }

    public func prepare(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress(String(localized: "モデルを確認中"), 0)
        // 未導入なら実際にはここで数分のダウンロードが走る。
        // 「確認中」のまま止まって見えないよう、開始前にラベルを切り替える。
        let needsDownload = !ModelCatalog.isInstalled(model)
        let label = needsDownload
            ? String(localized: "音声認識モデルをダウンロード中（\(ModelCatalog.sizeText(model.approximateBytes))・初回のみ）")
            : String(localized: "モデルを確認中")
        if needsDownload { progress(label, 0.01) }
        _ = try await ModelCatalog.install(model) { p in progress(label, max(0.01, p * 0.95)) }
        _ = try await ModelCatalog.install(ModelCatalog.vadModel) { _ in }

        guard let modelPath = ModelCatalog.localURL(for: model, role: "model")?.path,
              let vad = ModelCatalog.localURL(for: ModelCatalog.vadModel, role: "model")?.path else {
            throw ASRError.modelUnavailable("モデルファイルの場所を解決できない")
        }
        vadPath = vad

        if context.pointer == nil {
            progress(String(localized: "モデルを読み込み中"), 0.97)
            var cparams = whisper_context_default_params()
            cparams.use_gpu = true
            cparams.flash_attn = true
            // 状態は whisper_context に持たせたまま使う（`_no_state` + 認識ごとの whisper_init_state は使わない）。
            // whisper.cpp v1.9.1 の VAD 経路は渡した state ではなく `ctx->state->vad_segments` に書くので、
            // `_no_state` で作ると null 経由の書き込みになる。実際に turbo の出力が
            // 22セグメント/1083文字 → 105セグメント/1800文字に化けた。
            guard let c = whisper_init_from_file_with_params(modelPath, cparams) else {
                throw ASRError.modelUnavailable("whisper_init_from_file_with_params が nil を返した")
            }
            context.set(c)
        }
        progress(String(localized: "準備完了"), 1.0)
    }

    public func transcribe(_ request: ASRRequest,
                           progress: @escaping @Sendable (Double) -> Void,
                           isCancelled: @escaping @Sendable () -> Bool) async throws -> [Segment] {
        // acquire した間は終了ハンドラの shutdown() が context を free しない。
        // whisper_full と結果の回収（collect）の両方をこの区間に入れる。
        guard let ctx = context.acquire() else { throw ASRError.engineFailed("prepare() が呼ばれていない") }
        defer { context.release() }
        guard !request.samples.isEmpty else { return [] }

        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = options.threads
        params.beam_search.beam_size = options.beamSize
        params.greedy.best_of = options.bestOf
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_speech_thold = options.noSpeechThreshold
        params.entropy_thold = options.entropyThreshold
        params.logprob_thold = options.logprobThreshold
        if let ctx = options.maxTextContext { params.n_max_text_ctx = ctx }
        // whisper.cpp v1.9.1 では `no_context` は開始時に履歴を消すだけで、
        // 窓をまたぐ持ち越し（prompt_past1）は毎回組み直される。持ち越しを本当に切れるのは
        // n_max_text_ctx だけ。ただし 0 にすると語彙ヒント（initial_prompt）まで消える。
        // prompt の予算は「ヒント（prompt_past0）を先に取り、残りを持ち越し（prompt_past1）」なので、
        // 予算をヒントのトークン数 + 1 にすると、ヒントだけ残して持ち越しが 0 になる。
        if !request.carryContext {
            if let hint = UserDictionary.promptHint(terms: request.vocabularyTerms) {
                params.n_max_text_ctx = max(1, whisper_token_count(ctx, hint)) + 1
            } else {
                params.n_max_text_ctx = 0
            }
        }

        // 部分認識は offset_ms / duration_ms ではなく、サンプルを自分で切り出して渡す。
        //
        // whisper.cpp は VAD を有効にすると、まず全体から発話部分だけを詰めた音声を作り、
        // offset_ms はその**詰めた後の時間軸**に掛かる。元の時刻で区間を指定すると
        // 別の場所を認識し、結果の時刻も元に戻らない（実データでループ区間の読み直しが
        // 空振りした: カバー率が変わらなかった）。切り出してから渡せば VAD と区間を併用できる。
        let sliceStart: Int
        let samples: ArraySlice<Float>
        let timeOffset: Double
        if let range = request.timeRange {
            let rate = AudioExtractor.sampleRate
            sliceStart = min(request.samples.count, max(0, Int(range.lowerBound * rate)))
            let sliceEnd = min(request.samples.count, max(sliceStart, Int(range.upperBound * rate)))
            samples = request.samples[sliceStart..<sliceEnd]
            timeOffset = Double(sliceStart) / rate
        } else {
            sliceStart = 0
            samples = request.samples[...]
            timeOffset = 0
        }
        guard !samples.isEmpty else { return [] }

        let box = CallbackBox(progress: progress, isCancelled: isCancelled)
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        params.progress_callback = { _, _, p, user in
            guard let user else { return }
            Unmanaged<CallbackBox>.fromOpaque(user).takeUnretainedValue().progress(Double(p) / 100.0)
        }
        params.progress_callback_user_data = boxPtr
        params.abort_callback = { user in
            guard let user else { return false }
            return Unmanaged<CallbackBox>.fromOpaque(user).takeUnretainedValue().isCancelled()
        }
        params.abort_callback_user_data = boxPtr

        // C の const char * は呼び出しの間だけ生きていればよいので、
        // withCString をネストして params に載せる（Swift の String をそのまま渡すと解放済みポインタになる）。
        let segments: [Segment] = try request.language.withCString { langPtr in
            params.language = langPtr
            params.detect_language = false

            let run: () throws -> [Segment] = {
                let rc = samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
                if isCancelled() { throw ASRError.cancelled }
                guard rc == 0 else { throw ASRError.engineFailed("whisper_full rc=\(rc)") }
                return Self.collect(ctx: ctx, timeOffset: timeOffset)
            }

            let withVAD: () throws -> [Segment] = { [self] in
                if request.useVAD, let vadPath {
                    return try vadPath.withCString { vadPtr -> [Segment] in
                        params.vad = true
                        params.vad_model_path = vadPtr
                        var vp = whisper_vad_default_params()
                        vp.threshold = options.vadThreshold
                        vp.min_speech_duration_ms = options.vadMinSpeechMs
                        vp.min_silence_duration_ms = options.vadMinSilenceMs
                        vp.max_speech_duration_s = options.vadMaxSpeechSec
                        vp.speech_pad_ms = options.vadSpeechPadMs
                        params.vad_params = vp
                        return try run()
                    }
                } else {
                    params.vad = false
                    return try run()
                }
            }

            // 語彙ヒント。carry_initial_prompt を立てないと先頭30秒にしか効かない。
            if let hint = UserDictionary.promptHint(terms: request.vocabularyTerms) {
                return try hint.withCString { hintPtr -> [Segment] in
                    params.initial_prompt = hintPtr
                    params.carry_initial_prompt = true
                    return try withVAD()
                }
            }
            return try withVAD()
        }
        progress(1.0)
        return segments
    }

    private static func collect(ctx: OpaquePointer, timeOffset: Double) -> [Segment] {
        let n = whisper_full_n_segments(ctx)
        var out: [Segment] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            guard let cText = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            let t0 = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0 + timeOffset
            let t1 = Double(whisper_full_get_segment_t1(ctx, i)) / 100.0 + timeOffset

            // トークン確率の対数平均を尤度の代理指標にする
            let nTok = whisper_full_n_tokens(ctx, i)
            var logSum = 0.0
            var counted = 0
            for j in 0..<nTok {
                let p = Double(whisper_full_get_token_p(ctx, i, j))
                if p > 0 { logSum += log(p); counted += 1 }
            }
            let avgLogprob = counted > 0 ? logSum / Double(counted) : nil
            let noSpeech = Double(whisper_full_get_segment_no_speech_prob(ctx, i))

            out.append(Segment(start: t0, end: t1, original: text,
                               avgLogprob: avgLogprob, noSpeechProb: noSpeech))
        }
        return out
    }
}

/// whisper_context の所有者は NativeObjectBox（ASR層共通）。
/// 終了時は AppModel が pipeline.cancel() を立ててから shutdown() を呼ぶ。
/// ただし abort_callback が効いて whisper_full が戻るまでには間があるので、
/// 解放側は使用中カウントが 0 になるのを待つ。待たないと実行中の C 呼び出しが
/// 解放済みの context を読んで終了時に落ちる。

/// C コールバックに渡すための箱。actor をまたぐのでクラスにする。
private final class CallbackBox: @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    let isCancelled: @Sendable () -> Bool
    init(progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool) {
        self.progress = progress; self.isCancelled = isCancelled
    }
}
