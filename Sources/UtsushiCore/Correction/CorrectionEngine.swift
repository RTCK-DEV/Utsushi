import Foundation
import FoundationModels

/// 校正エンジンの抽象。LLMを差し替えても検証層は動く。
public protocol CorrectionEngine: Sendable {
    var displayName: String { get }
    func isAvailable() async -> CorrectionAvailability
    /// 1セグメントぶんの書き換え案を返す。**採否は判断しない**（判断はEditGateの仕事）。
    /// 返り値 nil は「変更提案なし」。
    func propose(segment: String, context: CorrectionContext) async throws -> String?
}

public enum CorrectionAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
    public var isAvailable: Bool { self == .available }
    public var reason: String? { if case .unavailable(let r) = self { return r }; return nil }
}

/// `SystemLanguageModel` の可用性をアプリの表現に写す唯一の場所。
/// 校正・判定・要約・文脈点検の4箇所が同じ switch を持っていた。
@available(macOS 26.0, *)
public extension SystemLanguageModel.Availability {
    var correctionAvailability: CorrectionAvailability {
        switch self {
        case .available: return .available
        case .unavailable(let reason): return .unavailable(reason.displayMessage)
        @unknown default: return .unavailable(String(localized: "未知の理由でモデルが利用できない"))
        }
    }
}

@available(macOS 26.0, *)
private extension SystemLanguageModel.Availability.UnavailableReason {
    var displayMessage: String {
        switch self {
        case .deviceNotEligible: return String(localized: "このMacはApple Intelligenceに対応していない")
        case .appleIntelligenceNotEnabled: return String(localized: "システム設定でApple Intelligenceが有効になっていない")
        case .modelNotReady: return String(localized: "モデルのダウンロード/準備が完了していない")
        @unknown default: return String(localized: "モデルが利用できない")
        }
    }
}

public struct CorrectionContext: Sendable {
    /// 直前の確定本文（読み取り専用。書き換え対象ではない）
    public var precedingText: String
    /// 辞書に載っている固有名詞（プロンプトに載せて誤変換を減らす）
    public var vocabulary: [String]
    public var language: String
    public init(precedingText: String = "", vocabulary: [String] = [], language: String = "ja") {
        self.precedingText = precedingText; self.vocabulary = vocabulary; self.language = language
    }
}

/// 校正の実行結果。何を通し何を落としたかを全部残す。
public struct CorrectionOutcome: Sendable, Codable, Equatable {
    public var proposed: Int = 0
    public var accepted: Int = 0
    public var rejected: [String: Int] = [:]   // Rejection.rawValue -> count
    public var deterministic: Int = 0
    public var dictionary: Int = 0
    public var engineErrors: Int = 0
    public init() {}
}

/// 校正の司令塔。決定論 → 辞書 → LLM+ゲート の順で、後段ほど権限が弱い。
public struct Corrector: Sendable {
    public var engine: (any CorrectionEngine)?
    public var gate: EditGate
    public var rules: DeterministicRules
    public var dictionary: UserDictionary
    /// 2回サンプリングして一致した場合のみLLM案を採る
    public var requireAgreement: Bool

    public init(engine: (any CorrectionEngine)?,
                gate: EditGate = EditGate(),
                rules: DeterministicRules = DeterministicRules(),
                dictionary: UserDictionary = .empty,
                requireAgreement: Bool = true) {
        self.engine = engine
        self.gate = gate
        self.rules = rules
        self.dictionary = dictionary
        self.requireAgreement = requireAgreement
    }

    public func run(on segments: [Segment],
                    progress: (@Sendable (Int, Int) -> Void)? = nil,
                    isCancelled: @Sendable () -> Bool = { false }) async -> ([Segment], CorrectionOutcome) {
        var out = segments
        var stat = CorrectionOutcome()
        var preceding = ""

        for i in out.indices {
            if isCancelled() { break }
            progress?(i, out.count)
            let seg = out[i]
            guard !seg.isSuppressed, !seg.original.isEmpty else { continue }

            var text = seg.original
            var appliedRule: CorrectionRule? = nil

            // 1. 辞書（決定論・最優先）
            let (dictApplied, dictChanged) = dictionary.apply(to: text)
            if dictChanged { text = dictApplied; appliedRule = .dictionary; stat.dictionary += 1 }

            // 2. 決定論ルール
            let (ruled, rule) = rules.apply(text)
            if let rule { text = ruled; appliedRule = appliedRule ?? rule; stat.deterministic += 1 }

            // 3. LLM提案 + ゲート
            if let engine {
                let ctx = CorrectionContext(precedingText: preceding,
                                            vocabulary: dictionary.entries.map(\.surface))
                do {
                    // 同意確認の2回目は毎回新しいセッションを作るので、
                    // 1回目と並行に投げられる。first が nil でも打ち上げてしまうが、
                    // その場合は直列のとき1回しか投げなかった分だけ無駄になるだけで
                    // 意味は変わらない。
                    let proposalText = text
                    async let secondP: String? = {
                        guard requireAgreement else { return nil }
                        return try await engine.propose(segment: proposalText, context: ctx)
                    }()
                    if let first = try await engine.propose(segment: text, context: ctx) {
                        stat.proposed += 1
                        var candidate: String? = first
                        if requireAgreement {
                            let second = try await secondP
                            if (second ?? text) != first { candidate = nil }
                        }
                        if let candidate {
                            switch gate.evaluate(original: text, proposed: candidate) {
                            case .accept:
                                if candidate != text {
                                    text = candidate
                                    appliedRule = .languageModel
                                    stat.accepted += 1
                                }
                            case .reject(let r):
                                stat.rejected[r.rawValue, default: 0] += 1
                            }
                        } else {
                            stat.rejected["disagreement", default: 0] += 1
                        }
                    }
                } catch {
                    stat.engineErrors += 1
                }
            }

            if text != seg.original, let appliedRule {
                out[i].corrected = text
                out[i].correction = AppliedCorrection(before: seg.original, after: text,
                                                      rule: appliedRule, accepted: true)
            }
            preceding = String((preceding + out[i].corrected).suffix(160))
        }
        progress?(out.count, out.count)
        return (out, stat)
    }
}
