import Foundation

public struct ASRRequest: Sendable {
    public var samples: [Float]
    public var language: String
    /// 部分再認識用。nil なら全体。
    public var timeRange: ClosedRange<Double>?
    /// VADを使うか。取りこぼし検証のために意図的に切ることがある。
    public var useVAD: Bool
    /// 認識を語彙側から誘導するための語表（辞書の表記の生リスト）。
    /// 固有名詞・専門語の誤認識は「モデルがその語を知らない」ことが原因なので、
    /// エンジンを増やすより先にここで効かせる。
    /// 各エンジンが自分のAPI向けに整形する（whisper は initial_prompt、
    /// sherpa は hotwords）。
    public var vocabularyTerms: [String]
    /// 直前の窓の認識結果を次の窓の prompt に持ち越すか。
    ///
    /// 既定は持ち越す（文脈が効いて精度が上がる）。ただし whisper は一度反復ループに入ると、
    /// 持ち越した本文がそのまま次の窓の prompt になるので、音声の終わりまで抜けない
    /// （実データで 44 分ぶん消えた）。ループ区間の読み直しでは切る。
    public var carryContext: Bool

    public init(samples: [Float], language: String = "ja",
                timeRange: ClosedRange<Double>? = nil, useVAD: Bool = true,
                vocabularyTerms: [String] = [], carryContext: Bool = true) {
        self.samples = samples; self.language = language
        self.timeRange = timeRange; self.useVAD = useVAD
        self.vocabularyTerms = vocabularyTerms
        self.carryContext = carryContext
    }
}

public protocol ASREngine: Sendable {
    var identifier: String { get }
    var displayName: String { get }
    var supportsVAD: Bool { get }
    var exposesConfidence: Bool { get }
    /// 語彙ヒント（initial_prompt / hotwords 相当）を受け付けるか
    var supportsVocabularyHint: Bool { get }
    func prepare(progress: @escaping @Sendable (String, Double) -> Void) async throws
    func transcribe(_ request: ASRRequest,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> [Segment]
}

public enum ASRError: LocalizedError {
    case modelUnavailable(String)
    case engineFailed(String)
    case cancelled
    case localeUnsupported(String)
    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let m): return String(localized: "モデルを用意できない: \(m)")
        case .engineFailed(let m): return String(localized: "認識に失敗: \(m)")
        case .cancelled: return String(localized: "キャンセルされた")
        case .localeUnsupported(let l): return String(localized: "この言語には対応していない: \(l)")
        }
    }
}
