import Foundation

/// モデルの取得。アプリには同梱せず、初回に Application Support へ落とす。
///
/// whisper は「1モデル＝1ファイル」だが、sherpa-onnx 系は
/// zipformer が encoder/decoder/joiner/tokens の4ファイル、
/// nemo-ctc が model/tokens の2ファイルで、しかも .tar.bz2 で配布される。
/// そのため「モデル＝ファイルの束（バンドル）」として扱う。
public struct ModelCatalog: Sendable {

    /// バンドル内の1ファイル
    public struct Item: Sendable, Equatable {
        /// バンドル内での役割（whisper なら "model"、zipformer なら "encoder" 等）
        public var role: String
        /// 保存時のファイル名
        public var fileName: String
        /// 単体ダウンロードの場合のURL。アーカイブ同梱の場合は nil。
        public var url: URL?
        /// アーカイブ内のパス（アーカイブ配布の場合）
        public var pathInArchive: String?
        /// 期待サイズ。0 なら検証しない（アーカイブ展開物でサイズが公表されていない場合）
        public var sizeBytes: Int64

        public init(role: String, fileName: String, url: URL? = nil,
                    pathInArchive: String? = nil, sizeBytes: Int64 = 0) {
            self.role = role; self.fileName = fileName; self.url = url
            self.pathInArchive = pathInArchive; self.sizeBytes = sizeBytes
        }
    }

    public struct Model: Sendable, Identifiable, Equatable {
        public var id: String
        public var displayName: String
        public var engine: EngineKind
        public var items: [Item]
        /// アーカイブ配布の場合のURL（.tar.bz2）。単体ファイル配布なら nil。
        public var archiveURL: URL?
        public var approximateBytes: Int64
        public var note: String
        /// 再配布・表示に必要な帰属表示（CC-BY 等）。nil なら不要。
        public var attribution: String?
        /// 実測して分かった落とし穴。nil なら特に無い。
        ///
        /// カタログから消してしまうと「なぜ使わないのか」が失われ、
        /// 数か月後に同じモデルをまた試すことになる。使えると分かっているものは
        /// 選べる状態のまま、分かっている欠点を画面に出す。
        public var caveat: String?

        public init(id: String, displayName: String, engine: EngineKind, items: [Item],
                    archiveURL: URL? = nil, approximateBytes: Int64,
                    note: String, attribution: String? = nil, caveat: String? = nil) {
            self.id = id; self.displayName = displayName; self.engine = engine
            self.items = items; self.archiveURL = archiveURL
            self.approximateBytes = approximateBytes; self.note = note
            self.attribution = attribution; self.caveat = caveat
        }
    }

    public enum EngineKind: String, Sendable, Equatable, Codable {
        case whisper
        case sherpaTransducer   // zipformer / RNN-T
        case sherpaNemoCTC      // FastConformer CTC
        case sherpaQwen3ASR     // LLMデコーダ型（生成型）
        case sherpaSenseVoice   // 非自己回帰（作文しない）
        case appleSpeechAnalyzer // OS内蔵。ダウンロード不要
        case sileroVAD
        case nemoSpeechDiar    // NeMo-Speech.cpp（Nemotron 3 Diarization）
    }

    // MARK: - カタログ

    public static let whisperModels: [Model] = [
        Model(id: "ggml-large-v3-turbo", displayName: "large-v3-turbo", engine: .whisper,
              items: [Item(role: "model", fileName: "ggml-large-v3-turbo.bin",
                           url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!,
                           sizeBytes: 1_624_555_275)],
              approximateBytes: 1_624_555_275,
              note: String(localized: "既定。日本語の精度と速度のバランスが最も良い")),
        Model(id: "ggml-large-v3-turbo-q5_0", displayName: String(localized: "large-v3-turbo (q5_0 量子化)"), engine: .whisper,
              items: [Item(role: "model", fileName: "ggml-large-v3-turbo-q5_0.bin",
                           url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
                           sizeBytes: 574_041_195)],
              approximateBytes: 574_041_195,
              note: String(localized: "容量優先。精度はわずかに落ちる")),
        Model(id: "ggml-large-v3", displayName: "large-v3", engine: .whisper,
              items: [Item(role: "model", fileName: "ggml-large-v3.bin",
                           url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!,
                           sizeBytes: 3_095_033_483)],
              approximateBytes: 3_095_033_483,
              note: String(localized: "最高精度だがturboの3〜4倍遅い")),
    ]

    /// 照合用の独立エンジン。whisper とアーキテクチャが異なるので誤りが相関しにくい。
    public static let sherpaModels: [Model] = [
        Model(id: "sherpa-zipformer-ja-reazonspeech",
              displayName: "ReazonSpeech k2-v2 (zipformer int8)",
              engine: .sherpaTransducer,
              items: [
                Item(role: "encoder", fileName: "encoder.int8.onnx",
                     pathInArchive: "encoder-epoch-99-avg-1.int8.onnx"),
                Item(role: "decoder", fileName: "decoder.onnx",
                     pathInArchive: "decoder-epoch-99-avg-1.onnx"),
                Item(role: "joiner", fileName: "joiner.int8.onnx",
                     pathInArchive: "joiner-epoch-99-avg-1.int8.onnx"),
                Item(role: "tokens", fileName: "tokens.txt",
                     pathInArchive: "tokens.txt"),
              ],
              archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01.tar.bz2")!,
              // アーカイブ実測 713,097,333 bytes。以前は展開後の int8 モデル本体だけを
              // 見ていて160MBと記していたが、ダウンロード表示はアーカイブの実サイズでなければ
              // 進捗が4倍ずれる。
              approximateBytes: 713_097_333,
              note: String(localized: "日本語35,000時間で学習。RNN-T系なのでwhisperと誤りが独立しやすい")),
        // LLMデコーダ型。他の2つと違い、音響から素直に写すのではなく
        // 文脈から補って書く。精度指標では有利に出るが、このアプリでは
        // ゲートより上流で本文が創作されうる点に注意がいる。
        // temperature=0・固定シードで、せめて決定的に動かす。
        Model(id: "sherpa-qwen3-asr-0.6b",
              displayName: "Qwen3-ASR 0.6B (int8)",
              engine: .sherpaQwen3ASR,
              items: [
                Item(role: "conv_frontend", fileName: "conv_frontend.onnx",
                     pathInArchive: "conv_frontend.onnx", sizeBytes: 0),
                Item(role: "encoder", fileName: "encoder.int8.onnx",
                     pathInArchive: "encoder.int8.onnx", sizeBytes: 0),
                Item(role: "decoder", fileName: "decoder.int8.onnx",
                     pathInArchive: "decoder.int8.onnx", sizeBytes: 0),
                // tokenizer はディレクトリを渡す仕様。3ファイルを同じ場所に
                // 展開して、その親ディレクトリを指す。
                Item(role: "vocab", fileName: "vocab.json",
                     pathInArchive: "vocab.json", sizeBytes: 0),
                Item(role: "merges", fileName: "merges.txt",
                     pathInArchive: "merges.txt", sizeBytes: 0),
                Item(role: "tokenizer_config", fileName: "tokenizer_config.json",
                     pathInArchive: "tokenizer_config.json", sizeBytes: 0),
              ],
              archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2")!,
              // アーカイブ実測 878,702,423 bytes
              approximateBytes: 878_702_423,
              note: String(localized: "LLMデコーダ型。文脈から補うので、音響に無い語を書くことがある"),
              attribution: "This product includes Qwen3-ASR by Alibaba, licensed under Apache-2.0.",
              caveat: String(localized: "実行のたびに出力が変わる（同じ音声・同じ設定で 753 / 758 / 759 文字）。同一インスタンス内なら一致するが、プロセスをまたぐと一致しない。temperature=0・seed 固定・スレッド1でも消えず、原因は未特定。照合の相手にすると「前回は決着した箇所が今回は未決」が起き、CER を測っても再現しない。速度も 6.7 倍速と他の 5〜10 分の1。")),
        // 1.7B（非公式ビルド）は外した。
        // 公式リリースに無いので第三者が書き出した ONNX を取る形になり、
        // しかも 0.6B と同じ構造なので**同じ非決定性を引き継ぐ見込みが高い**。
        // 2.4GB 落として確かめるだけの見返りが無いと判断した。
        // 必要になったら git log の db5be56 に定義が残っている。
        // 非自己回帰。1回の前向き計算で全トークンを出すので、
        // 生成型のように「文脈から補って書く」ことがない。
        // 照合の相方としては Qwen3 より筋が良い（作文しない・揺れない）。
        // ITN（数字や単位の正規化）は切る。表記を書き換えられると
        // 照合の食い違いが「認識の違い」ではなく「表記の違い」で埋まる。
        // 2025-09-09 版は使わない。
        //
        // ファイル名が sense-voice-zh-en-ja-ko-yue と続いているので同じ系列に見えるが、
        // onnx のメタデータを読むと `comment=ASLP-lab/WSYue-ASR`、
        // `url=https://huggingface.co/ASLP-lab/WSYue-ASR` で、**広東語向けの別モデル**だった。
        // SenseVoice の構造を流用しているだけで、作者も学習データも違う。
        //
        // 日本語を食わせると、かなが落ちて漢字だけの中国語寄りの出力になる
        // （11分の素材で287文字。whisper は1,064文字）。
        // language を ja / zh / en / 空 のどれにしても出力はほぼ同じで、
        // 「言語指定が効いていない」のではなく**そもそも日本語のモデルではない**。
        //
        // 名前が続いているだけで中身が別物、というのはリリース名からは読み取れない。
        // 新しいモデルを足すときは onnx のメタデータを見ること。
        Model(id: "sherpa-sense-voice-2024-07-17",
              displayName: String(localized: "SenseVoice Small (int8・多言語)"),
              engine: .sherpaSenseVoice,
              items: [
                Item(role: "model", fileName: "model.int8.onnx",
                     pathInArchive: "model.int8.onnx", sizeBytes: 0),
                Item(role: "tokens", fileName: "tokens.txt",
                     pathInArchive: "tokens.txt", sizeBytes: 0),
              ],
              archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2")!,
              approximateBytes: 1_047_870_769,
              note: String(localized: "非自己回帰。作文せず、実行ごとに揺れない（書庫1.0GB／展開後は約240MB）"),
              attribution: "This product includes SenseVoice-Small by Alibaba (FunASR), Apache-2.0."),
        Model(id: "sherpa-parakeet-ja",
              displayName: "NVIDIA Parakeet ja (nemo-ctc int8)",
              engine: .sherpaNemoCTC,
              items: [
                Item(role: "model", fileName: "model.int8.onnx",
                     pathInArchive: "model.int8.onnx"),
                Item(role: "tokens", fileName: "tokens.txt",
                     pathInArchive: "tokens.txt"),
              ],
              archiveURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8.tar.bz2")!,
              // アーカイブ実測 489,389,564 bytes
              approximateBytes: 489_389_564,
              note: String(localized: "FastConformer系。ReazonSpeech v2で学習"),
              attribution: "This product includes NVIDIA parakeet-tdt_ctc-0.6b-ja, licensed under CC BY 4.0."),
    ]

    public static let vadModel = Model(
        id: "ggml-silero-v5.1.2", displayName: "Silero VAD v5.1.2", engine: .sileroVAD,
        items: [Item(role: "model", fileName: "ggml-silero-v5.1.2.bin",
                     url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
                     sizeBytes: 885_098)],
        approximateBytes: 885_098,
        note: String(localized: "無音区間の切り出しに使う"))

    /// 話者分離モデル。Nemotron 3 Diarization の公式 q8_0 GGUF をそのまま使う。
    /// VoiceArena Diarization-Bench トップ（DER 14.72%）で、最大8話者・
    /// オーバーラップ（同時発話）にも対応する。非ゲーテッドの単一ファイルなので
    /// 単体ダウンロードで入る。実行は NeMo-Speech.cpp（Apache-2.0）の静的ライブラリで、
    /// whisper とは別系統の ggml を内製している。
    public static let diarModel = Model(
        id: "nvidia-nemotron-3-diarization", displayName: "Nemotron 3 Diarization (q8_0)",
        engine: .nemoSpeechDiar,
        items: [Item(role: "model", fileName: "Nemotron-3-Diarization.q8_0.gguf",
                     url: URL(string: "https://huggingface.co/nvidia/Nemotron-3-Diarization/resolve/main/Nemotron-3-Diarization.q8_0.gguf")!,
                     sizeBytes: 107_012_128)],
        approximateBytes: 107_012_128,
        note: String(localized: "話者の区別を付ける。最大8人・同時発話にも対応（CPU動作）"),
        attribution: "This product uses NVIDIA Nemotron-3-Diarization, licensed under the Open Model Definition (OpenMDW-1.1).",
        caveat: String(localized: "英語中心の評価で高精度（Diarization-Bench 1位）だが、日本語での実測はまだ浅い"))

    /// OS内蔵の SpeechTranscriber。**ダウンロードするファイルが無いので `items` は空**。
    /// 言語モデルの取得は `SpeechAnalyzerEngine.prepare` が OS の API 経由で行う。
    ///
    /// 照合の相手として置いている。実測（57分・作手小学校）では:
    ///   - 30秒（115倍速）で完走。反復ループ 0%。whisper large-v3 の10倍速い
    ///   - 本文の一致率は whisper 0.655 / sherpa平均 0.622 と、どちらにも偏らない
    ///   - ただし固有名詞が崩れやすく（「頂上の手前」→「長女の手前」）、
    ///     語彙ヒントに非対応なので辞書で補正できない。一次認識より照合に向く
    public static let appleModel = Model(
        id: "apple.speechanalyzer",
        displayName: String(localized: "Apple SpeechTranscriber (OS内蔵)"),
        engine: .appleSpeechAnalyzer,
        items: [],
        approximateBytes: 0,
        note: String(localized: "OS内蔵。取得不要で30秒（57分素材）。反復ループが出ない"),
        caveat: String(localized: "固有名詞が崩れやすい。語彙ヒント（辞書）と尤度に非対応なので一次認識には向かない"))

    /// **ダウンロード定義を持つ**モデル。取得・容量計算・配布定義の検証はこれを使う。
    /// OS内蔵の `appleModel` は含まない（落とすファイルが無いため）。
    public static var allModels: [Model] { whisperModels + sherpaModels + [vadModel, diarModel] }

    /// 照合に選べるエンジン。系統が違うものだけを並べる。
    public static var crossCheckCandidates: [Model] { sherpaModels + [appleModel] }

    // MARK: - 配置

    public static var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Utsushi/Models", isDirectory: true)
    }

    /// モデルごとにディレクトリを切る。1ファイルのモデルもディレクトリを持つ（扱いを揃えるため）。
    public static func directory(for model: Model) -> URL {
        storageDirectory.appendingPathComponent(model.id, isDirectory: true)
    }

    /// 以前は Models/<filename> にフラットに置いていた。
    /// ディレクトリ構成に変えたあとも、既に落としてあるモデルを再ダウンロードさせないよう、
    /// 旧配置も有効な場所として認める（移動はしない。移動中に落ちると壊れるため）。
    static func legacyURL(for item: Item) -> URL {
        storageDirectory.appendingPathComponent(item.fileName)
    }

    public static func localURL(for model: Model, role: String) -> URL? {
        guard let item = model.items.first(where: { $0.role == role }) else { return nil }
        let current = directory(for: model).appendingPathComponent(item.fileName)
        if isValid(current, expected: item.sizeBytes) { return current }
        let legacy = legacyURL(for: item)
        if isValid(legacy, expected: item.sizeBytes) { return legacy }
        return current
    }

    static func isValid(_ url: URL, expected: Int64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 0 else { return false }
        // 途中で切れたダウンロードを「入っている」と誤認しないよう、
        // 期待サイズが分かっているものは厳密に比較する。
        if expected > 0 && size != expected { return false }
        return true
    }

    public static func isInstalled(_ model: Model) -> Bool {
        // OS内蔵エンジンは取得が要らない。言語モデルが未取得でも prepare が
        // OS 経由で入れるので、ここでは常に「使える」と答える。
        if model.engine == .appleSpeechAnalyzer { return true }
        guard !model.items.isEmpty else { return false }
        for item in model.items {
            let current = directory(for: model).appendingPathComponent(item.fileName)
            if isValid(current, expected: item.sizeBytes) { continue }
            if isValid(legacyURL(for: item), expected: item.sizeBytes) { continue }
            return false
        }
        return true
    }

    public static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 取得

    public static func install(_ model: Model,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dir = directory(for: model)
        if isInstalled(model) { progress(1.0); return dir }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let archiveURL = model.archiveURL {
            try await installFromArchive(model, archiveURL: archiveURL, into: dir, progress: progress)
        } else {
            try await installIndividualFiles(model, into: dir, progress: progress)
        }
        guard isInstalled(model) else {
            throw ASRError.modelUnavailable("展開後に必要なファイルが揃っていない: \(model.id)")
        }
        progress(1.0)
        return dir
    }

    private static func installIndividualFiles(_ model: Model, into dir: URL,
                                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let total = max(model.items.count, 1)
        for (i, item) in model.items.enumerated() {
            guard let url = item.url else {
                throw ASRError.modelUnavailable("\(item.role) のURLが無い")
            }
            let base = Double(i) / Double(total)
            let span = 1.0 / Double(total)
            let reporter = DownloadProgressReporter(expected: item.sizeBytes) { p in
                progress(base + p * span)
            }
            let (tempURL, response) = try await URLSession.shared.download(from: url, delegate: reporter)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ASRError.modelUnavailable("HTTP \(http.statusCode) (\(item.role))")
            }
            let size = (try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int64) ?? 0
            if item.sizeBytes > 0 && size != item.sizeBytes {
                throw ASRError.modelUnavailable("サイズ不一致 \(item.role) (期待 \(item.sizeBytes) / 実際 \(size))")
            }
            let dest = dir.appendingPathComponent(item.fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
        }
    }

    /// .tar.bz2 を落として展開し、必要なファイルだけを取り出して配置する。
    /// 展開は /usr/bin/tar に任せる（サンドボックス内でも実行できる）。
    private static func installFromArchive(_ model: Model, archiveURL: URL, into dir: URL,
                                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let reporter = DownloadProgressReporter(expected: model.approximateBytes) { p in
            progress(p * 0.85)
        }
        let (tempURL, response) = try await URLSession.shared.download(from: archiveURL, delegate: reporter)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ASRError.modelUnavailable("HTTP \(http.statusCode)")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("utsushi-extract-\(model.id)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appendingPathComponent("bundle.tar.bz2")
        try FileManager.default.moveItem(at: tempURL, to: archive)
        progress(0.88)

        try extract(archive: archive, into: work)
        progress(0.95)

        // アーカイブ内のディレクトリ構成に依存しないよう、ファイル名で探す
        for item in model.items {
            guard let want = item.pathInArchive else {
                throw ASRError.modelUnavailable("\(item.role) の pathInArchive が無い")
            }
            guard let found = findFile(named: want, under: work) else {
                throw ASRError.modelUnavailable("アーカイブに \(want) が無い")
            }
            let dest = dir.appendingPathComponent(item.fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: found, to: dest)
        }
    }

    static func extract(archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ASRError.modelUnavailable("展開に失敗 (tar \(process.terminationStatus)): \(msg.prefix(200))")
        }
    }

    static func findFile(named name: String, under root: URL) -> URL? {
        let target = (name as NSString).lastPathComponent
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in e where url.lastPathComponent == target {
            return url
        }
        return nil
    }
}

/// ダウンロードのバイト進捗を拾うためのデリゲート。
final class DownloadProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expected: Int64
    private let onProgress: @Sendable (Double) -> Void
    init(expected: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.onProgress = onProgress
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        guard total > 0 else { return }
        onProgress(min(1.0, Double(totalBytesWritten) / Double(total)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
