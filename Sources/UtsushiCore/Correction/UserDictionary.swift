import Foundation

/// 固有名詞のユーザー辞書。
///
/// 読み一致ゲートは「読みが変わる書き換え」を必ず落とすので、
/// 社名・人名のような **読みごと違う誤認識** はLLMでは直せない。直す唯一の経路がここ。
/// これは制約ではなく設計意図で、モデルに固有名詞を推測させないための線引き。
public struct UserDictionary: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable, Identifiable {
        public var id: UUID
        /// 正しい表記
        public var surface: String
        /// 読み（ひらがな/カタカナ）。ASR出力とのマッチングに使う。
        public var reading: String
        /// ASRが出しがちな誤り表記。空でもよい。
        public var misspellings: [String]
        public init(id: UUID = UUID(), surface: String, reading: String, misspellings: [String] = []) {
            self.id = id; self.surface = surface; self.reading = reading; self.misspellings = misspellings
        }
    }

    public var entries: [Entry]
    public static let empty = UserDictionary(entries: [])
    public init(entries: [Entry]) { self.entries = entries }

    /// 決定論的な置換。LLMを一切通さない。
    public func apply(to text: String) -> (String, Bool) {
        var out = text
        var changed = false
        for e in entries {
            for m in e.misspellings where !m.isEmpty && out.contains(m) {
                out = out.replacingOccurrences(of: m, with: e.surface)
                changed = true
            }
        }
        return (out, changed)
    }

    /// 読みが変わる書き換えを辞書が説明できるか（登録語への置換のみ許可）
    public func explains(original: String, proposed: String) -> Bool {
        for e in entries where proposed.contains(e.surface) {
            if e.misspellings.contains(where: { original.contains($0) }) { return true }
        }
        return false
    }

    /// 辞書の表記の生リスト。エンジンに流す語彙ヒントの素。
    /// whisper には `promptHint` で整形して、sherpa にはそのまま hotwords に渡す。
    public var hintTerms: [String] {
        entries.map(\.surface)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// whisper の initial_prompt に流す語彙ヒント。
    ///
    /// initial_prompt は n_text_ctx/2（=224トークン）で切られるため、詰め込みすぎると
    /// 後ろが黙って捨てられる。日本語は約1.2文字/トークンなので文字数で上限を掛ける。
    public func promptHint(maxCharacters: Int = 200) -> String? {
        Self.promptHint(terms: hintTerms, maxCharacters: maxCharacters)
    }

    /// 語リストを whisper の initial_prompt 形式に整形する。
    /// `ASRRequest.vocabularyTerms` を受け取ったエンジン側から呼ぶ。
    public static func promptHint(terms: [String], maxCharacters: Int = 200) -> String? {
        guard !terms.isEmpty else { return nil }

        var picked: [String] = []
        var used = 0
        let prefix = "固有名詞: "
        for t in terms {
            let cost = t.count + 1
            if used + cost > maxCharacters - prefix.count { break }
            picked.append(t)
            used += cost
        }
        guard !picked.isEmpty else { return nil }
        return prefix + picked.joined(separator: "、") + "。"
    }

    public func entry(matchingReading reading: String) -> Entry? {
        let key = Reading.key(reading)
        return entries.first { Reading.key($0.reading) == key }
    }
}
