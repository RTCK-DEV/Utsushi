import Foundation

/// 抽出 → 認識 → 監査 → 自動修復 → 校正 の全体。
/// 各段が何をしたかは AuditReport / CorrectionOutcome に残り、黙って直すことはしない。
public actor TranscriptionPipeline {

    public struct Configuration: Sendable {
        public var language: String = "ja"
        /// どちらの押しかたで走っているか。書き出しに残す。
        public var mode: RunMode = .quality
        public var auditPolicy: HallucinationAuditor.Policy = .init()
        public var gatePolicy: EditGate.Policy = .init()
        public var rules: DeterministicRules = .init()
        public var dictionary: UserDictionary = .empty
        /// 取りこぼし疑い区間をVADなしで自動再認識する
        public var autoRepair: Bool = true
        /// 校正の段を走らせる。**決定論ルールと辞書の適用を含む。**
        public var enableCorrection: Bool = true
        /// 校正の中で LLM を使うか。
        ///
        /// 切っても決定論ルール（フィラー除去など）と辞書は効く。以前はここが
        /// `enableCorrection` と一緒くたで、**LLM を切ると辞書まで止まっていた**。
        /// Apple Intelligence が無効な環境でも同じことが起きていて、
        /// README の「無効でも検証層は全機能動く」と食い違っていた。
        public var useLanguageModel: Bool = true
        /// LLM案は2回一致した場合のみ採用
        public var requireAgreement: Bool = true
        /// 照合に使う別エンジン。空なら照合しない。
        public var crossCheckEngines: [ModelCatalog.Model] = []
        /// 不一致をLLMに判定させる
        public var adjudicateDisagreements: Bool = true
        /// 読みが違う不一致もLLMに判定させるか（既定は切る。SessionSettings の説明を参照）
        public var judgeDifferentReadings: Bool = false
        /// 要約を作る
        public var enableSummary: Bool = false
        public var summaryConfig: Summarizer.Configuration = .init()
        /// 文脈に合わない語をモデルに指摘させるか。
        /// 照合が拾えない「全エンジンが同じ誤り方をした箇所」を埋める。
        /// 本文は書き換えず、候補を横に並べるだけ。
        public var enablePlausibilityCheck: Bool = true
        /// 話者の区別を付ける（Nemotron 3 Diarization）。本文は変えず、
        /// セグメントに話者番号を貼るだけ。失敗しても文字起こし自体は返す。
        public var enableDiarization: Bool = true
        public init() {}
    }

    public enum Stage: Sendable, Equatable {
        case preparing(String)
        case extractingAudio
        case transcribing
        case auditing
        case repairing(Int, Int)
        case crossChecking(String)
        case diarizing
        case adjudicating(Int, Int)
        case correcting
        case summarizing(Int, Int)
        case done
        case failed(String)
        case cancelled
    }

    public struct Progress: Sendable, Equatable {
        public var stage: Stage
        public var fraction: Double
        public var message: String
    }

    private let engine: any ASREngine
    private let diarizer: DiarizationEngine?
    private let corrector: (any CorrectionEngine)?
    private let judge: (any DisagreementJudge)?
    private let summaryEngine: (any SummaryEngine)?
    private let plausibilityChecker: (any PlausibilityChecker)?
    private let config: Configuration
    /// Cコールバックから同期的に読めるキャンセル状態。
    /// ポーリング Task を作ると、その Task がパイプラインとASRエンジンを保持し続け、
    /// 終了時まで whisper_context が解放されないため、共有フラグを直接使う。
    private let cancellation = CancelBox()

    public init(engine: any ASREngine,
                corrector: (any CorrectionEngine)?,
                judge: (any DisagreementJudge)? = nil,
                summaryEngine: (any SummaryEngine)? = nil,
                plausibilityChecker: (any PlausibilityChecker)? = nil,
                diarizer: DiarizationEngine? = nil,
                config: Configuration = Configuration()) {
        self.engine = engine
        self.diarizer = diarizer
        self.corrector = corrector
        self.judge = judge
        self.summaryEngine = summaryEngine
        self.plausibilityChecker = plausibilityChecker
        self.config = config
    }

    /// CancelBox はスレッド安全なので actor の外からも立てられる。
    /// 終了ハンドラなど、await できない場所からキャンセルを伝えるために必要。
    public nonisolated func cancel() { cancellation.set() }
    private func makeCancelCheck() -> @Sendable () -> Bool {
        let cancellation = cancellation
        return { cancellation.value }
    }

    public func run(url: URL, onProgress: @escaping @Sendable (Progress) -> Void) async throws -> Transcript {
        // パイプラインは実行ごとに新規に作られる。ここで reset すると、
        // start 直後〜 run 先頭の間に立ったキャンセルを食い潰して走り始めてしまう。
        let isCancelled = makeCancelCheck()

        let emit: @Sendable (Stage, Double, String) -> Void = { s, f, m in
            onProgress(Progress(stage: s, fraction: f, message: m))
        }

        // 1. 準備
        emit(.preparing(String(localized: "開始")), 0, String(localized: "準備中"))
        try await engine.prepare { msg, p in emit(.preparing(msg), p * 0.10, msg) }
        if isCancelled() { throw ASRError.cancelled }

        // 2. 音声抽出
        emit(.extractingAudio, 0.10, String(localized: "音声を抽出中"))
        let audio = try await AudioExtractor().extract(url: url,
            progress: { p in emit(.extractingAudio, 0.10 + p * 0.08, String(localized: "音声を抽出中")) },
            isCancelled: isCancelled)
        let envelope = AudioEnvelope(values: audio.envelope, hop: audio.envelopeHopSeconds)

        // 3. 認識
        emit(.transcribing, 0.18, String(localized: "認識中"))
        let hintTerms = config.dictionary.hintTerms
        var segments = try await engine.transcribe(
            ASRRequest(samples: audio.samples, language: config.language,
                       useVAD: engine.supportsVAD,
                       vocabularyTerms: engine.supportsVocabularyHint ? hintTerms : []),
            progress: { p in emit(.transcribing, 0.18 + p * 0.52, String(localized: "認識中 \(Int(p * 100))%")) },
            isCancelled: isCancelled)
        segments.sort { $0.start < $1.start }

        // 3.5 話者分離。音声をもう一度モデルに通して「誰がいつ話したか」を切る。
        // 本文とは独立した解析なので、失敗しても文字起こしはそのまま返す
        // （照合と同じ扱い。区間を付けられなかった段は speaker が nil のまま残る）。
        var speakerSpans: [DiarizationEngine.SpeakerSpan] = []
        if config.enableDiarization, let diarizer {
            emit(.diarizing, 0.70, String(localized: "話者を分離中"))
            do {
                try await diarizer.prepare { msg, p in emit(.diarizing, 0.70 + p * 0.01, msg) }
                speakerSpans = try await diarizer.diarize(
                    samples: audio.samples,
                    progress: { p in emit(.diarizing, 0.71 + p * 0.01, String(localized: "話者を分離中 \(Int(p * 100))%")) },
                    isCancelled: isCancelled)
            } catch ASRError.cancelled {
                throw ASRError.cancelled
            } catch is CancellationError {
                throw ASRError.cancelled
            } catch {
                // 話者分離はメタデータの付与であって本文を変えないので、
                // ここで落として文字起こし自体を失わせない。
                NSLog("Utsushi: 話者分離に失敗（話者なしで続行）: \(error.localizedDescription)")
            }
        }

        // 4. 監査
        emit(.auditing, 0.72, String(localized: "検証中"))
        let auditor = HallucinationAuditor(policy: config.auditPolicy)
        var (audited, report) = auditor.audit(segments: segments,
                                              envelope: envelope,
                                              totalDuration: audio.duration,
                                              engineExposesConfidence: engine.exposesConfidence)

        // 5. 自動修復（VADを切って疑わしい区間だけ読み直す）
        if config.autoRepair {
            let plan = auditor.repairPlan(from: report, totalDuration: audio.duration)
            for (i, target) in plan.enumerated() {
                if isCancelled() { throw ASRError.cancelled }
                let range = target.range
                let isLoop = target.kind == .repetitionLoop
                emit(.repairing(i + 1, plan.count), 0.74 + Double(i) / Double(max(plan.count, 1)) * 0.06,
                     (isLoop ? String(localized: "反復ループの区間を読み直し中")
                      : String(localized: "取りこぼし疑い区間を再認識中"))
                     + " (\(i + 1)/\(plan.count))")
                do {
                    // 取りこぼしは VAD を切って拾い直す。反復ループは VAD はそのまま、
                    // **文脈の持ち越しを切る**（持ち越すと同じループに戻る）。
                    // 持ち越しはどちらの読み直しでも要らないので常に切る。
                    let redone = try await engine.transcribe(
                        ASRRequest(samples: audio.samples, language: config.language,
                                   timeRange: range, useVAD: isLoop && engine.supportsVAD,
                                   vocabularyTerms: engine.supportsVocabularyHint ? hintTerms : [],
                                   carryContext: false),
                        progress: { _ in }, isCancelled: isCancelled)
                    let (replaced, changed) = Self.splice(into: audited, range: range,
                                                          with: redone, envelope: envelope,
                                                          policy: config.auditPolicy)
                    // 記録の end は音声の尺を超えることがある（whisper のセグメント end が
                    // 尺より先に出る）ので、区間に入っているかは start で見る。
                    for k in report.findings.indices
                    where report.findings[k].start >= range.lowerBound
                        && report.findings[k].start <= range.upperBound {
                        let f = report.findings[k]
                        if f.kind == .repetitionLoop, f.action == .suppressed {
                            if changed {
                                report.findings[k].action = .repaired
                                report.findings[k].detail += String(localized: "（文脈の持ち越しを切って読み直し、本文を差し替えた）")
                            } else {
                                report.findings[k].detail += String(localized: "（読み直したが本文は得られなかった）")
                            }
                        } else if f.action == .unresolved {
                            if changed {
                                report.findings[k].action = .repaired
                            } else {
                                // 調べた結果なにも無かった、を「未解決」と同じ扱いにしない。
                                // 未解決のまま残すと、確認済みの区間まで人の目を要求してしまう。
                                report.findings[k].action = .marked
                                report.findings[k].detail += String(localized: "（VADなしで再認識したが、追加の発話は検出されなかった）")
                            }
                        }
                    }
                    if changed {
                        audited = replaced
                        report.stats.repairedCount += 1
                    }
                } catch is CancellationError {
                    throw ASRError.cancelled
                } catch {
                    // 再認識に失敗しても元の結果は壊さない。未解決のまま報告に残す。
                    continue
                }
            }
            audited.sort { $0.start < $1.start }
            // 読み直しで本文が変わったので、カバー率も今の本文で出し直す。
            if report.stats.repairedCount > 0 {
                auditor.updateCoverage(&report.stats, segments: audited,
                                       envelope: envelope, totalDuration: audio.duration)
            }
        }

        // 5.5 話者を貼る。修復で差し込まれた区間も含めて最後に一括で割り当てる。
        if !speakerSpans.isEmpty {
            DiarizationEngine.assignSpeakers(to: &audited, spans: speakerSpans)
        }
        // 校正は監査済みの本文だけを見る。照合（別エンジンの再認識）とは
        // 入力も出力も独立しているので並行で走らせる。片方は ASR の CPU/GPU、
        // もう片方は Foundation Models の ANE で、使う演算資源も別。
        let config = self.config  // 並行タスクが actor の self を掴まないよう値で渡す
        let corrector = self.corrector
        let auditedSnapshot = audited
        let correctionEnd = config.enableSummary ? 0.92 : 0.99
        async let correctionResult: ([Segment], CorrectionOutcome) = {
            var stat = CorrectionOutcome()
            var corrected = auditedSnapshot
            if config.enableCorrection {
                emit(.correcting, 0.82, String(localized: "校正中"))
                let gate = EditGate(policy: config.gatePolicy, dictionary: config.dictionary)
                let c = Corrector(engine: config.useLanguageModel ? corrector : nil,
                                  gate: gate, rules: config.rules,
                                  dictionary: config.dictionary, requireAgreement: config.requireAgreement)
                (corrected, stat) = await c.run(on: corrected, progress: { done, total in
                    emit(.correcting, 0.82 + Double(done) / Double(max(total, 1)) * (correctionEnd - 0.82),
                         String(localized: "校正中 \(done)/\(total)"))
                }, isCancelled: isCancelled)
            }
            return (corrected, stat)
        }()

        // 6. 照合（別エンジンで読み直し、食い違いを取り出す）
        var crossCheck = CrossCheckReport()
        if !config.crossCheckEngines.isEmpty {
            crossCheck.engines = [engine.identifier]
            var runs = [TranscriptAlignment.Run(engine: engine.identifier, segments: audited)]
            // 各エンジンの読み直しは互いに独立しているので並列に走らせる。
            // 逐次だと照合段がエンジン数分だけ直列に延びる（5エンジンで5倍）。
            // 全モデルが同時にメモリに載るのが代償（終わったものから shutdown で降りる）。
            let indexed: [(Int, TranscriptAlignment.Run?)] = await withTaskGroup(
                of: (Int, TranscriptAlignment.Run?).self,
                returning: [(Int, TranscriptAlignment.Run?)].self
            ) { group in
                for (i, model) in config.crossCheckEngines.enumerated() {
                    group.addTask {
                        if isCancelled() { return (i, nil) }
                        emit(.crossChecking(model.displayName), 0.80,
                             String(localized: "\(model.displayName) で照合中"))
                        do {
                            // 照合の相手は sherpa 系と OS 内蔵の2種類。
                            // OS 内蔵は取得も解放も要らないので、生成だけ分ける。
                            let secondary: any ASREngine
                            if model.engine == .appleSpeechAnalyzer {
                                guard #available(macOS 26.0, *) else { return (i, nil) }
                                let loc = config.language == "ja" ? "ja-JP" : config.language
                                secondary = SpeechAnalyzerEngine(locale: Locale(identifier: loc))
                            } else {
                                secondary = SherpaEngine(model: model)
                            }
                            // 失敗・キャンセルでも認識器を残さない（OS内蔵は何もしない）
                            defer { (secondary as? SherpaEngine)?.shutdown() }
                            try await secondary.prepare { msg, _ in
                                emit(.crossChecking(model.displayName), 0.80, msg)
                            }
                            let segs = try await secondary.transcribe(
                                ASRRequest(samples: audio.samples, language: config.language,
                                           useVAD: false,
                                           vocabularyTerms: secondary.supportsVocabularyHint ? hintTerms : []),
                                progress: { _ in }, isCancelled: isCancelled)
                            return (i, TranscriptAlignment.Run(engine: model.id, segments: segs))
                        } catch {
                            // 照合は補助機能なので、失敗しても本体の結果は返す
                            return (i, nil)
                        }
                    }
                }
                var collected: [(Int, TranscriptAlignment.Run?)] = []
                for await r in group { collected.append(r) }
                return collected
            }
            // CancelBox だけでなく Task 側のキャンセルでも抜ける
            // （従来は子の CancellationError を伝播させていた）
            if isCancelled() || Task.isCancelled { throw ASRError.cancelled }
            // 表示と判定の再現性のため、エンジンの並びは設定の順序を保つ
            for (_, run) in indexed.sorted(by: { $0.0 < $1.0 }) {
                guard let run else { continue }
                runs.append(run)
                crossCheck.engines.append(run.engine)
            }
            if runs.count >= 2 {
                crossCheck.disagreements = TranscriptAlignment.compare(runs)
                if config.adjudicateDisagreements, !crossCheck.disagreements.isEmpty {
                    let a = Adjudicator(judge: judge,
                                        requireAgreement: config.requireAgreement,
                                        judgeDifferentReadings: config.judgeDifferentReadings)
                    let (adj, stat) = await a.run(on: crossCheck.disagreements,
                                                progress: { done, total in
                        emit(.adjudicating(done, total), 0.81, String(localized: "食い違いを判定中 \(done)/\(total)"))
                    }, isCancelled: isCancelled)
                    crossCheck.adjudications = adj
                    crossCheck.outcome = stat
                }
            }
        }

        // 7. 校正の結果を回収（照合と並行に走っていたもの）
        if isCancelled() { throw ASRError.cancelled }
        let (correctedSegments, correctionStat) = await correctionResult
        audited = correctedSegments
        let outcome = correctionStat
        if isCancelled() { throw ASRError.cancelled }

        // 8. 要約（校正後の本文から引用する）
        var summary = Summary.empty
        if config.enableSummary, summaryEngine != nil {
            if isCancelled() { throw ASRError.cancelled }
            let s = Summarizer(engine: summaryEngine, config: config.summaryConfig)
            summary = await s.run(on: audited, progress: { done, total in
                emit(.summarizing(done, total),
                     correctionEnd + Double(done) / Double(max(total, 1)) * (0.99 - correctionEnd),
                     String(localized: "要約中 \(done)/\(total)"))
            }, isCancelled: isCancelled)
        }

        // 9. 文脈に合わない語の指摘
        //
        // 照合はエンジン間の不一致しか見ないので、**全エンジンが同じ誤り方をした箇所**
        // （「期初」→「気象」）を素通りする。音響からの多数決では原理的に拾えないため、
        // 残っている手掛かりである文脈をモデルに見せる。
        // モデルは本文を書き換えない。指摘した語が本文に無ければ機械的に捨てる。
        var plausibility: [PlausibilityFlag] = []
        if config.enablePlausibilityCheck, plausibilityChecker != nil {
            if isCancelled() { throw ASRError.cancelled }
            emit(.correcting, 0.99, String(localized: "文脈の点検中"))
            let a = PlausibilityAuditor(checker: plausibilityChecker,
                                        requireAgreement: config.requireAgreement)
            let (flags, stat) = await a.run(on: audited.filter { !$0.isSuppressed },
                                          progress: { done, total in
                emit(.correcting, 0.99, String(localized: "文脈の点検中 \(done)/\(total)"))
            }, isCancelled: isCancelled)
            plausibility = flags
            self.lastPlausibilityOutcome = stat
        }

        report.stats.segmentCount = audited.count
        let meta = TranscriptMeta(sourceURL: url, sourceDuration: audio.duration,
                                  engine: engine.displayName,
                                  modelName: engine.identifier,
                                  language: config.language,
                                  mode: config.mode)
        emit(.done, 1.0, String(localized: "完了"))
        // カバー率は監査層が音声を見て出す。ここで尺の合計から上書きしない
        // （それをやっていたせいで、休憩を含む素材が 100% と報告されていた）。
        let transcript = Transcript(meta: meta, segments: audited, audit: report,
                                    crossCheck: crossCheck, summary: summary,
                                    plausibility: plausibility)
        self.lastCorrectionOutcome = outcome
        return transcript
    }

    public private(set) var lastCorrectionOutcome = CorrectionOutcome()
    public private(set) var lastPlausibilityOutcome = PlausibilityAuditor.Outcome()

    /// 再認識結果を元の並びに差し込む。
    /// 再認識側にも幻聴が乗るので、無音区間の本文はここでも捨てる。
    static func splice(into segments: [Segment],
                       range: ClosedRange<Double>,
                       with fresh: [Segment],
                       envelope: AudioEnvelope,
                       policy: HallucinationAuditor.Policy) -> ([Segment], Bool) {
        let cleaned = fresh.filter { seg in
            guard !seg.original.isEmpty else { return false }
            let peak = envelope.peakDBFS(from: seg.start, to: seg.end)
            if peak <= policy.silenceDBFS { return false }
            let t = seg.original.trimmingCharacters(in: .whitespaces)
            if HallucinationAuditor.knownHallucinations.contains(t) { return false }
            return true
        }
        // 元より情報が増えないなら差し替えない（改悪防止）
        let originalChars = segments
            .filter { $0.start < range.upperBound && $0.end > range.lowerBound && !$0.isSuppressed }
            .reduce(0) { $0 + $1.original.count }
        let freshChars = cleaned.reduce(0) { $0 + $1.original.count }
        guard freshChars > originalChars else { return (segments, false) }

        var out = segments.filter { $0.end <= range.lowerBound || $0.start >= range.upperBound }
        for var seg in cleaned {
            seg.flags.insert(.repaired)
            out.append(seg)
        }
        out.sort { $0.start < $1.start }
        return (out, true)
    }
}

/// Cコールバックやテスト用スタブから同期的に読める共有キャンセルフラグ。
/// パイプラインが内部で持つほか、AppModel のキュー実行でも項目ごとに使う。
final class CancelBox: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
