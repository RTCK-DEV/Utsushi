import Foundation

/// sherpa-onnx を静的リンクして呼ぶエンジン。
///
/// ReazonSpeech-k2-v2 (zipformer transducer) と parakeet-tdt_ctc-0.6b-ja (NeMo CTC) の
/// 両方を同じ C API で扱う。whisper とはアーキテクチャも学習データも違うので、
/// 照合相手として誤りが相関しにくい。
///
/// 制約: 静的 onnxruntime では CoreML EP が使えないため **CPU 実行のみ**。
public actor SherpaEngine: ASREngine {
    public nonisolated var identifier: String { model.id }
    public nonisolated var displayName: String { "sherpa-onnx (\(model.displayName))" }
    public nonisolated let supportsVAD = false
    public nonisolated let exposesConfidence = false
    /// hotwords が効くのは transducer（modified_beam_search）だけ。
    /// CTC/SenseVoice/Qwen3 では捨てられるので受け付けないと申告する。
    public nonisolated var supportsVocabularyHint: Bool { model.engine == .sherpaTransducer }

    public struct Options: Sendable {
        public var threads: Int32 = 6
        /// 1回のデコードに渡す最大秒数。長すぎるとメモリと遅延が跳ねる。
        public var maxChunkSeconds: Double = 20
        /// チャンク境界を探す際に無音とみなす相対エネルギー閾値
        public var silenceRatio: Float = 0.02
        /// SenseVoice に渡す言語。空文字で自動判定。
        public var senseVoiceLanguage: String = "ja"
        public init() {}
    }

    private let model: ModelCatalog.Model
    private let options: Options
    private nonisolated let holder = NativeObjectBox(destroy: { SherpaOnnxDestroyOfflineRecognizer($0) })

    public init(model: ModelCatalog.Model, options: Options = Options()) {
        self.model = model
        self.options = options
    }

    public nonisolated func shutdown() { holder.free() }
    public nonisolated var isLoaded: Bool { holder.pointer != nil }

    public func prepare(progress: @escaping @Sendable (String, Double) -> Void) async throws {
        progress(String(localized: "モデルを確認中"), 0)
        let needsDownload = !ModelCatalog.isInstalled(model)
        let label = needsDownload
            ? String(localized: "\(model.displayName) をダウンロード中（\(ModelCatalog.sizeText(model.approximateBytes))・初回のみ）")
            : String(localized: "モデルを確認中")
        if needsDownload { progress(label, 0.01) }
        _ = try await ModelCatalog.install(model) { p in progress(label, max(0.01, p * 0.95)) }

        guard holder.pointer == nil else { progress(String(localized: "準備完了"), 1.0); return }
        progress(String(localized: "モデルを読み込み中"), 0.96)

        // Qwen3-ASR は tokens.txt を使わず tokenizer ディレクトリを取る。
        // 他のエンジンでは従来どおり必須。
        let tokens: String
        if model.engine == .sherpaQwen3ASR {
            tokens = ""
        } else if let t = ModelCatalog.localURL(for: model, role: "tokens")?.path {
            tokens = t
        } else {
            throw ASRError.modelUnavailable("tokens.txt が見つからない")
        }

        // hotwords は transducer の modified_beam_search でしか掛からないので、
        // transducer だけデコード法を切り替える。語彙ヒントが来ない実行でも
        // modified_beam_search は決定的で、出力が大きく変わることは無い。
        let method = model.engine == .sherpaTransducer ? "modified_beam_search" : "greedy_search"
        let recognizer: OpaquePointer? = try tokens.withCString { tokensPtr in
            try "cpu".withCString { providerPtr in
                try method.withCString { methodPtr in
                    var config = SherpaOnnxOfflineRecognizerConfig()
                    config.feat_config.sample_rate = Int32(AudioExtractor.sampleRate)
                    config.feat_config.feature_dim = 80
                    config.model_config.tokens = tokensPtr
                    config.model_config.num_threads = options.threads
                    config.model_config.debug = 0
                    config.model_config.provider = providerPtr
                    config.decoding_method = methodPtr
                    config.max_active_paths = 4
                    // hotwords を採用したとき1トークンあたりに足すボーナス。
                    config.hotwords_score = 1.5

                    switch model.engine {
                    case .sherpaTransducer:
                        guard let enc = ModelCatalog.localURL(for: model, role: "encoder")?.path,
                              let dec = ModelCatalog.localURL(for: model, role: "decoder")?.path,
                              let joi = ModelCatalog.localURL(for: model, role: "joiner")?.path else {
                            throw ASRError.modelUnavailable("transducer の3ファイルが揃っていない")
                        }
                        return enc.withCString { e in
                            dec.withCString { d in
                                joi.withCString { j in
                                    config.model_config.transducer.encoder = e
                                    config.model_config.transducer.decoder = d
                                    config.model_config.transducer.joiner = j
                                    return SherpaOnnxCreateOfflineRecognizer(&config)
                                }
                            }
                        }
                    case .sherpaNemoCTC:
                        guard let m = ModelCatalog.localURL(for: model, role: "model")?.path else {
                            throw ASRError.modelUnavailable("nemo-ctc のモデルが無い")
                        }
                        return m.withCString { mp in
                            config.model_config.nemo_ctc.model = mp
                            return SherpaOnnxCreateOfflineRecognizer(&config)
                        }
                    case .sherpaSenseVoice:
                        guard let m = ModelCatalog.localURL(for: model, role: "model")?.path else {
                            throw ASRError.modelUnavailable("sense-voice のモデルが無い")
                        }
                        // recognizer は prepare 時に作るので、ここに ASRRequest は無い。
                        // 言語は Options で持つ（既定 "ja"）。空文字にすると自動判定になるが、
                        // 判定を外したときの誤りが読み取りにくいので明示する方を既定にしている。
                        return m.withCString { mp in
                            options.senseVoiceLanguage.withCString { lang in
                                config.model_config.sense_voice.model = mp
                                config.model_config.sense_voice.language = lang
                                // ITN は切る。数字や単位を書き換えられると、
                                // 照合の食い違いが表記の違いで埋まる。
                                config.model_config.sense_voice.use_itn = 0
                                return SherpaOnnxCreateOfflineRecognizer(&config)
                            }
                        }
                    case .sherpaQwen3ASR:
                        guard let cf = ModelCatalog.localURL(for: model, role: "conv_frontend")?.path,
                              let enc = ModelCatalog.localURL(for: model, role: "encoder")?.path,
                              let dec = ModelCatalog.localURL(for: model, role: "decoder")?.path,
                              let vocab = ModelCatalog.localURL(for: model, role: "vocab") else {
                            throw ASRError.modelUnavailable("qwen3-asr のファイルが揃っていない")
                        }
                        // tokenizer は vocab.json などを含むディレクトリを指す
                        let tokenizerDir = vocab.deletingLastPathComponent().path
                        return cf.withCString { c in
                            enc.withCString { e in
                                dec.withCString { d in
                                    tokenizerDir.withCString { t in
                                        config.model_config.qwen3_asr.conv_frontend = c
                                        config.model_config.qwen3_asr.encoder = e
                                        config.model_config.qwen3_asr.decoder = d
                                        config.model_config.qwen3_asr.tokenizer = t
                                        // 生成型なので、決定的に動かす。
                                        // 温度を上げると同じ音声から違う本文が出る＝
                                        // 照合にも計測にも使えなくなる。
                                        config.model_config.qwen3_asr.temperature = 0
                                        config.model_config.qwen3_asr.top_p = 1
                                        // シードは固定してあるが、**これでは再現性は得られない**。
                                        //
                                        // 実測（フィクスチャ冒頭2分・同一設定）:
                                        //   プロセス内: 4本とも完全一致（インスタンスを作り直しても同じ）
                                        //   プロセス間: 753 / 758 / 759文字 と毎回変わる
                                        //   threads=1 でも seed=42 でも、プロセス間の食い違いは消えない
                                        //
                                        // 原因は未特定。並列リダクション順とシードは潰したので、
                                        // 残るのは onnxruntime のプロセス単位の最適化あたりだが確認していない。
                                        // **この状態では CER 計測にも照合にも使えない**（実行のたびに数字が変わる）。
                                        config.model_config.qwen3_asr.seed = 42
                                        config.model_config.qwen3_asr.max_total_len = 32768
                                        config.model_config.qwen3_asr.max_new_tokens = 512
                                        return SherpaOnnxCreateOfflineRecognizer(&config)
                                    }
                                }
                            }
                        }
                    default:
                        throw ASRError.modelUnavailable("SherpaEngine が扱えないモデル種別: \(model.engine.rawValue)")
                    }
                }
            }
        }
        guard let recognizer else {
            throw ASRError.modelUnavailable("SherpaOnnxCreateOfflineRecognizer が nil を返した")
        }
        holder.set(recognizer)
        progress(String(localized: "準備完了"), 1.0)
    }

    public func transcribe(_ request: ASRRequest,
                           progress: @escaping @Sendable (Double) -> Void,
                           isCancelled: @escaping @Sendable () -> Bool) async throws -> [Segment] {
        // デコード中に shutdown() が recognizer を destroy しないよう使用中にする
        guard let recognizer = holder.acquire() else {
            throw ASRError.engineFailed("prepare() が呼ばれていない")
        }
        defer { holder.release() }
        let sr = AudioExtractor.sampleRate
        let all = request.samples
        guard !all.isEmpty else { return [] }

        // 対象区間を切り出す
        let offset = request.timeRange?.lowerBound ?? 0
        let i0 = max(0, Int(offset * sr))
        let i1 = min(all.count, Int((request.timeRange?.upperBound ?? Double(all.count) / sr) * sr))
        guard i0 < i1 else { return [] }
        let samples = Array(all[i0..<i1])

        // オフライン認識器は波形をまとめて食うので、長尺は自前で切る。
        // 無音の谷を優先して切ることで、単語の途中で切れるのを避ける。
        let chunks = Self.chunk(samples, sampleRate: sr,
                                maxSeconds: options.maxChunkSeconds,
                                silenceRatio: options.silenceRatio)
        // sherpa の hotwords は1行1語（任意で「 :スコア」）のテキスト。
        // WithHotwords は transducer 以外だと SHERPA_ONNX_EXIT でプロセスごと
        // 落ちるのでここでも弾く（パイプライン側も supportsVocabularyHint で
        // 弾いているが防御）。語の中の改行や「/」はフォーマットを壊すので潰す。
        let terms = request.vocabularyTerms.map {
            $0.replacingOccurrences(of: "/", with: "／")
              .replacingOccurrences(of: "\n", with: " ")
              .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        let hotwords = model.engine == .sherpaTransducer && !terms.isEmpty
            ? terms.joined(separator: "\n") : nil
        var out: [Segment] = []
        for (index, chunk) in chunks.enumerated() {
            if isCancelled() { throw ASRError.cancelled }
            let chunkStart = offset + Double(chunk.start) / sr
            let segs = try Self.decode(recognizer: recognizer,
                                       samples: Array(samples[chunk.start..<chunk.end]),
                                       sampleRate: Int32(sr),
                                       startOffset: chunkStart,
                                       hotwords: hotwords)
            out.append(contentsOf: segs)
            progress(Double(index + 1) / Double(max(chunks.count, 1)))
        }
        progress(1.0)
        return out.sorted { $0.start < $1.start }
    }

    // MARK: - デコード

    private static func decode(recognizer: OpaquePointer, samples: [Float],
                               sampleRate: Int32, startOffset: Double,
                               hotwords: String? = nil) throws -> [Segment] {
        let stream: OpaquePointer?
        if let hotwords, !hotwords.isEmpty {
            stream = hotwords.withCString {
                SherpaOnnxCreateOfflineStreamWithHotwords(recognizer, $0)
            }
        } else {
            stream = SherpaOnnxCreateOfflineStream(recognizer)
        }
        guard let stream else {
            throw ASRError.engineFailed("SherpaOnnxCreateOfflineStream が nil を返した")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(stream, sampleRate, buf.baseAddress, Int32(buf.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return [] }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        let text = String(cString: result.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let end = startOffset + Double(samples.count) / AudioExtractor.sampleRate

        // トークン単位のタイムスタンプがあれば、それを使って発話単位に組み直す。
        let count = Int(result.pointee.count)
        if count > 0, let stamps = result.pointee.timestamps, let arr = result.pointee.tokens_arr {
            var tokens: [(String, Double)] = []
            tokens.reserveCapacity(count)
            for i in 0..<count {
                guard let cs = arr[i] else { continue }
                let t = String(cString: cs)
                tokens.append((t, Double(stamps[i]) + startOffset))
            }
            let grouped = groupTokens(tokens, fallbackEnd: end)
            let rebuilt = grouped.map(\.text).joined()

            debugLog("tokens=\(count) text=\(text.count)文字 rebuilt=\(rebuilt.count)文字 "
                     + "segments=\(grouped.count) 先頭token=\(tokens.prefix(6).map(\.0)) "
                     + "先頭stamp=\(tokens.prefix(6).map { String(format: "%.2f", $0.1) })")

            // **組み直した本文がエンジンの本文より短ければ、組み直しは信用しない。**
            //
            // SenseVoice は発話単位でしか結果を出さないモデルで、
            // tokens_arr / timestamps が本文と対応していない。それに気づかず
            // 組み直した結果、1,000文字あるはずの音声から287文字しか出ていなかった。
            // しかも「日本語が返っている」ことは確認していたので気づけなかった。
            //
            // エンジン種別で分岐せず、長さの比較という機械的な条件で弾く。
            // 新しいモデルを足したときに同じ穴に落ちないため。
            if !grouped.isEmpty, comparableCount(rebuilt) * 20 >= comparableCount(text) * 19 {
                return grouped
            }
            if !grouped.isEmpty {
                debugLog("トークン再構成が本文を取りこぼしたので破棄した"
                         + "（\(comparableCount(rebuilt))/\(comparableCount(text))）")
            }
        }

        // タイムスタンプが取れない、または取りこぼしている場合は
        // チャンク全体を1セグメントにする。時間分解能は落ちるが本文は落ちない。
        return [Segment(start: startOffset, end: end, original: text)]
    }

    /// 長さ比較用の文字数。空白と約物は数えない。
    /// エンジンによって句読点の入れ方が違うため、そのままだと比較にならない。
    private static func comparableCount(_ s: String) -> Int {
        s.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
        }.count
    }

    /// `UTSUSHI_ASR_DEBUG=1` のときだけ出す。
    /// 通常利用で標準出力を汚さず、調査のときは何が起きたか見える状態にしておく。
    private static func debugLog(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["UTSUSHI_ASR_DEBUG"] == "1" else { return }
        print("[sherpa] " + message())
    }

    /// トークン列を発話単位にまとめる。文末記号か一定以上の間で区切る。
    static func groupTokens(_ tokens: [(text: String, start: Double)],
                            gapSeconds: Double = 0.6,
                            maxCharacters: Int = 140,
                            fallbackEnd: Double) -> [Segment] {
        guard !tokens.isEmpty else { return [] }
        let terminators: Set<Character> = ["。", "．", ".", "！", "!", "？", "?"]
        var out: [Segment] = []
        var buffer = ""
        var bufferStart = tokens[0].start
        var previous = tokens[0].start

        func flush(end: Double) {
            let t = buffer.replacingOccurrences(of: "▁", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                out.append(Segment(start: bufferStart, end: max(end, bufferStart + 0.1), original: t))
            }
            buffer = ""
        }

        for token in tokens {
            if !buffer.isEmpty {
                let gap = token.start - previous
                let endsSentence = buffer.last.map { terminators.contains($0) } ?? false
                if endsSentence || gap > gapSeconds || buffer.count > maxCharacters {
                    flush(end: previous)
                    bufferStart = token.start
                }
            } else {
                bufferStart = token.start
            }
            buffer += token.text
            previous = token.start
        }
        flush(end: fallbackEnd)
        return out
    }

    // MARK: - チャンク分割

    struct Chunk: Equatable { var start: Int; var end: Int }

    /// 最大長を超えない範囲で、なるべく静かなところで切る。
    static func chunk(_ samples: [Float], sampleRate: Double,
                      maxSeconds: Double, silenceRatio: Float) -> [Chunk] {
        let maxLen = Int(maxSeconds * sampleRate)
        guard samples.count > maxLen else {
            return samples.isEmpty ? [] : [Chunk(start: 0, end: samples.count)]
        }
        // 100ms 粒度のエネルギー
        let hop = Int(sampleRate / 10)
        var energy: [Float] = []
        energy.reserveCapacity(samples.count / hop + 1)
        var i = 0
        while i < samples.count {
            let j = min(i + hop, samples.count)
            var sum: Float = 0
            for k in i..<j { sum += abs(samples[k]) }
            energy.append(sum / Float(j - i))
            i = j
        }
        let peak = energy.max() ?? 1
        let threshold = peak * silenceRatio

        var chunks: [Chunk] = []
        var start = 0
        while start < samples.count {
            let hardEnd = min(start + maxLen, samples.count)
            if hardEnd == samples.count { chunks.append(Chunk(start: start, end: hardEnd)); break }
            // 後ろ 1/3 の範囲で最も静かなフレームを探す
            let searchFrom = start + maxLen * 2 / 3
            var best = hardEnd
            var bestEnergy = Float.greatestFiniteMagnitude
            var f = searchFrom / hop
            let fEnd = min(hardEnd / hop, energy.count - 1)
            while f <= fEnd {
                if energy[f] < bestEnergy { bestEnergy = energy[f]; best = f * hop }
                f += 1
            }
            let end = (bestEnergy <= threshold && best > start) ? best : hardEnd
            chunks.append(Chunk(start: start, end: end))
            start = end
        }
        return chunks
    }
}

/// recognizer の所有者は NativeObjectBox（ASR層共通）。
/// デコード中に destroy されないよう、解放側は使用中カウントが 0 になるまで待つ。
