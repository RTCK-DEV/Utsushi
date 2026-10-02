import Foundation

public enum ExportFormat: String, Sendable, CaseIterable, Identifiable {
    case markdown, srt, vtt, plainText, json
    public var id: String { rawValue }
    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .plainText: return "txt"
        case .json: return "json"
        }
    }
    public var displayName: String {
        switch self {
        case .markdown: return String(localized: "Markdown（タイムスタンプ付き）")
        case .srt: return String(localized: "SRT 字幕")
        case .vtt: return "WebVTT"
        case .plainText: return String(localized: "プレーンテキスト")
        case .json: return String(localized: "JSON（監査記録込み）")
        }
    }
}

public struct Exporter: Sendable {
    public init() {}

    public func render(_ t: Transcript, as format: ExportFormat) throws -> Data {
        let s: String
        switch format {
        case .markdown:  s = markdown(t)
        case .srt:       s = srt(t)
        case .vtt:       s = vtt(t)
        case .plainText: s = plain(t)
        case .json:      return try jsonData(t)
        }
        guard let d = s.data(using: .utf8) else {
            throw NSError(domain: "Utsushi", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "UTF-8への変換に失敗"])
        }
        return d
    }

    // MARK: -

    /// 話者タグ。分離が動いていて区間に番号が付いているときだけ出す。
    /// 名付け済みならその名、さもなければ `話者1:` の形。書き出しは文書なので
    /// 文書の言語（日本語）で固定する。
    static func speakerPrefix(_ seg: Segment, in t: Transcript) -> String {
        guard let s = seg.speaker else { return "" }
        return "\(t.speakerName(s)): "
    }

    /// 話者分離が効いていたか（1区間でも番号が付いていれば true）
    static func hasSpeakers(_ t: Transcript) -> Bool {
        t.segments.contains { $0.speaker != nil }
    }

    public func markdown(_ t: Transcript) -> String {
        var out: [String] = []
        let name = t.meta.sourceURL?.lastPathComponent ?? "(不明)"
        out.append("# 文字起こし — \(name)\n")
        out.append("| 項目 | 内容 |")
        out.append("|---|---|")
        out.append("| 元ファイル | `\(name)` |")
        out.append("| 収録長 | \(Self.hms(t.meta.sourceDuration)) |")
        out.append("| エンジン | \(t.meta.engine) |")
        out.append("| 言語 | \(t.meta.language) |")
        out.append("| セグメント数 | \(t.visibleSegments.count) |")
        out.append("| 総文字数 | \(t.totalCharacters) |")
        out.append("| 発話カバー率 | \(String(format: "%.1f%%", t.audit.stats.coverageRatio * 100))"
                   + "（発話 \(Self.hms(t.audit.stats.voicedSeconds))"
                   + " / 無音 \(Self.hms(t.audit.stats.silentSeconds))）|")
        out.append("| 作成 | \(Self.stamp(t.meta.createdAt)) |")
        // どのビルドの出力かを本文と同じ場所に残す。検証記録の解釈が版で変わるため
        // （例: 0.4.1 より前は反復ループの区間を破棄するだけで読み直していない）。
        out.append("| 作成ツール | \(AppInfo.credit) |")
        // どの押しかたで作ったかを本文と同じ場所に置く。
        // 「高速」は照合も校正もしていないので、**その前提を知らずに読むと危ない**。
        if let mode = t.meta.mode {
            out.append("| 押しかた | \(mode.documentName)（\(mode.documentNote)）|")
        }
        out.append("")

        // この書き出しは人だけでなく LLM に渡されることを前提にしている。
        // LLM は本文を確定した事実として読むので、**どこが確かでどこが怪しいかを
        // 本文と同じ場所に書いておかないと、怪しい箇所を根拠に自信を持って間違える。**
        // 検証記録を後ろの節に置くだけでは、読み手が突き合わせてくれる保証がない。
        out.append("## この文書の読み方\n")
        out.append("""
                   > 音声認識の出力であり、**誤りが残っている前提で読むこと。**
                   >
                   > - `[00:00:00]` は発話の開始時刻。本文は認識結果そのままで、書き換えていない
                   > - `⚠︎` が付いた行は、エンジンが自信を持てなかった箇所
                   > - `—— 発話なし ——` は実際に音が無い区間。話が省略されているのではない
                   > - `↳ 別エンジンの候補:` は複数のエンジンで結果が割れた箇所。\
                   **そこに書かれている語は当てにならない**ので、断定の根拠にしない
                   > - `⚠︎ 文脈から浮いて見える語:` は、その区間で**最も文脈に合わないと\
                   判定された語**。**本文は書き換えていない**ので、上の行はそのまま残っている。\
                   ただし**これは有無の判定ではなく順位付けである**——誤りが無い区間でも\
                   1件は出る。「指摘がある＝誤りがある」ではない
                   > - 「要約」の見出しだけはモデルが書いた文で、その下の引用は本文そのまま
                   >
                   > 既知の弱点:
                   >
                   > - **同音異義語と固有名詞を取り違える**（「期初」→「気象」のように、\
                   文脈に合わない語が自信満々に出る）。意味が通らない語は誤認識を疑う
                   """)
        if Self.hasSpeakers(t) {
            out.append("""
                       > - `話者1:` などは、その区間を話したと推定された話者の番号。\
                       **音だけを見た推定**で、誰の名前かは分からず、\
                       別の録音の「話者1」と同じ人とは限らない。短い発話や声の似た話者は\
                       取り違えやすいので、発言の帰属を断定する根拠にしない
                       > - 数値・固有名詞・日付は、この文書だけを根拠に確定しない\n
                       """)
        } else {
            out.append("""
                       > - **話者の区別をしていない。** 発言が誰のものかは書かれていないので、\
                       複数人の会話でも1人の連続した発話に見える
                       > - 数値・固有名詞・日付は、この文書だけを根拠に確定しない\n
                       """)
        }

        if !t.summary.isEmpty {
            out.append("## 要約\n")
            out.append("> 見出しはモデルが書き、本文は文字起こしからの引用そのまま。")
            out.append("> 引用に無い数値・英数字・カタカナ語を含む見出しは機械的に落としてある。\n")
            for p in t.summary.points {
                let tag = p.headlineSource == .extracted ? "（見出しはモデル案が棄却されたため原文から抜粋）" : ""
                out.append("- **[\(p.kind.documentName)]** `\(Self.hms(p.start))` \(p.headline)\(tag)")
                for q in p.quotes { out.append("  > \(q)") }
            }
            out.append("")
        }

        // 無音区間はセグメントとして持たないので、ここで並びから割り出して明示する。
        // 何も書かないと、休憩をはさんだ発話が地続きに見えてしまう。
        let gaps = t.gaps()
        var chunk = -1
        var emittedGaps = 0
        var previousEnd: Double? = nil
        // 「発話なし」区間の1行。同じ整形が2箇所（途中と末尾）にあるので1つに閉じる。
        func emitGap(_ g: ClosedRange<Double>) {
            let minutes = Int((g.upperBound - g.lowerBound) / 60)
            let span = minutes >= 1 ? "約\(minutes)分" : "\(Int(g.upperBound - g.lowerBound))秒"
            out.append("\n> —— 発話なし \(Self.hms(g.lowerBound)) – \(Self.hms(g.upperBound))"
                       + "（\(span)）——\n")
            emittedGaps += 1
        }
        for seg in t.visibleSegments {
            // 無音区間は音声から出しているので、セグメント境界には一致しない。
            // 「まだ出していない無音のうち、このセグメントより前に始まるもの」を出す。
            while emittedGaps < gaps.count, gaps[emittedGaps].lowerBound < seg.start {
                emitGap(gaps[emittedGaps])
            }
            _ = previousEnd
            let c = Int(seg.start / 600)
            if c != chunk {
                chunk = c
                out.append("\n## \(Self.hms(Double(c * 600))) – \(Self.hms(min(Double((c + 1) * 600), t.meta.sourceDuration)))\n")
            }
            let mark = seg.flags.contains(.lowConfidence) ? " ⚠︎" : ""
            out.append("`[\(Self.hms(seg.start))]`\(mark) \(Self.speakerPrefix(seg, in: t))\(seg.text)")
            for line in Self.plausibilityNotes(for: seg, in: t) { out.append(line) }
            for line in Self.uncertaintyNotes(for: seg, in: t) { out.append(line) }
            out.append("")
            previousEnd = seg.end
        }
        // 末尾の無音（収録の最後が無音で終わる場合）も出す
        while emittedGaps < gaps.count { emitGap(gaps[emittedGaps]) }

        out.append("\n---\n")
        out.append("""
                   > ここから下は検証の記録で、話された内容ではない。\
                   本文として引用しないこと。\n
                   """)
        out.append("## 検証記録\n")
        out.append("| 種別 | 件数 |")
        out.append("|---|---|")
        let byKind = Dictionary(grouping: t.audit.findings, by: \.kind)
        for kind in [AuditReport.Finding.Kind.silentHallucination, .repetitionLoop,
                     .densityAnomaly, .coverageGap, .lowConfidence, .segmentOverrun] {
            out.append("| \(Self.label(kind)) | \(byKind[kind]?.count ?? 0) |")
        }
        out.append("| 本文を破棄した区間 | \(t.audit.stats.suppressedCount) |")
        out.append("| 再認識で差し替えた区間 | \(t.audit.stats.repairedCount) |")
        out.append("| 文脈から浮いて見える語 | \(t.plausibility.count) |")
        out.append("")

        // 破棄した本文そのものはここに出さない。
        // 幻聴が成果物に混ざらないことを ExporterTests が固定しており、
        // 中身の確認は JSON 書き出し（監査記録込み）と検証記録タブが担う。
        // stats は監査段が埋めるので、監査を通していない Transcript では 0 のままになる。
        // 案内の有無が「破棄があったか」とずれるので、データ側から判定する。
        if !t.suppressedSegments.isEmpty {
            out.append("> 破棄した本文そのものは、混入を避けるためここには載せない。"
                       + "中身はアプリの検証記録タブか JSON 書き出しで確認する。\n")
        }

        let unresolved = t.audit.findings.filter { $0.action == .unresolved }
        if !unresolved.isEmpty {
            out.append("### 未解決（人の目で確認すべき箇所）\n")
            for f in unresolved.prefix(50) {
                out.append("- `\(Self.hms(f.start))–\(Self.hms(f.end))` \(Self.label(f.kind))：\(f.detail)")
            }
            out.append("")
        }
        if t.crossCheck.engines.count >= 2 {
            out.append("### 別エンジンとの照合\n")
            out.append("照合エンジン: \(t.crossCheck.engines.joined(separator: " / "))\n")
            let o = t.crossCheck.outcome
            out.append("| 項目 | 件数 |")
            out.append("|---|---|")
            func kindCount(_ k: TranscriptAlignment.Kind) -> Int {
                t.crossCheck.disagreements.filter { $0.kind == k }.count
            }
            // 中身の違い以外の ID。一覧から外す対象。
            let foldedIDs = Set(t.crossCheck.disagreements
                .filter { !$0.kind.needsHumanReview }.map(\.id))
            out.append("| 食い違い（全件）| \(t.crossCheck.disagreements.count) |")
            out.append("| 　中身の違い | \(kindCount(.substantive)) |")
            out.append("| 　整列のずれ（本文は両方にある）| \(kindCount(.alignment)) |")
            out.append("| 　語尾・助詞のゆれ（と / って）| \(kindCount(.inflection)) |")
            out.append("| 　表記だけの違い（三月 / 3月）| \(kindCount(.notation)) |")
            out.append("| 判定できた | \(o.decided) |")
            out.append("| 　うち読みが一致（同音異義語）| \(o.decidedWithMatchingReadings) |")
            out.append("| 　うち読みが不一致（音響情報を無視した推定）| \(o.decidedWithDifferentReadings) |")
            out.append("| 人の目が要る | \(max(0, o.undecided - o.skipped)) |")
            out.append("| 2回の判定が割れた | \(o.disagreedBetweenSamples) |")
            out.append("")
            // 中身の違い以外は一覧から外す。認識の誤りではないものが並ぶと、
            // 本当に見るべき箇所が埋もれる。件数は上の表に残してある。
            let unresolved = t.crossCheck.adjudications
                .filter { $0.chosenText == nil && !foldedIDs.contains($0.disagreementID) }
            if !unresolved.isEmpty {
                // 以前は先頭50件で打ち切っていた。件数が多いと読めないから、という
                // 理由だったが、**打ち切ったことが書き出しのどこにも出ていなかった**。
                // 51件目以降が存在しないのと区別がつかない状態だったので、全件出す。
                out.append("#### 判定できなかった食い違い（人の目で確認）— \(unresolved.count)件\n")
                for a in unresolved {
                    let cands = a.candidates.map { "\($0.engine)「\($0.text)」" }.joined(separator: " / ")
                    out.append("- `\(Self.hms(a.start))` \(cands)")
                }
                out.append("")
            }
            // 使用したモデルのライセンス表示義務を成果物にも載せる
            let attributions = ModelCatalog.sherpaModels
                .filter { t.crossCheck.engines.contains($0.id) }
                .compactMap { $0.attribution }
            if !attributions.isEmpty {
                out.append("#### ライセンス表記\n")
                for a in attributions { out.append("- \(a)") }
                out.append("")
            }
        }

        let corrected = t.segments.filter { $0.correction != nil }
        if !corrected.isEmpty {
            out.append("### 校正で変更した箇所（\(corrected.count)件）\n")
            for seg in corrected.prefix(200) {
                guard let c = seg.correction else { continue }
                out.append("- `\(Self.hms(seg.start))` [\(c.rule.rawValue)] ~~\(c.before)~~ → \(c.after)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    public func srt(_ t: Transcript) -> String {
        var out: [String] = []
        for (i, seg) in t.visibleSegments.enumerated() {
            out.append("\(i + 1)")
            out.append("\(Self.timecode(seg.start, sep: ",")) --> \(Self.timecode(max(seg.end, seg.start + 0.2), sep: ","))")
            out.append(Self.speakerPrefix(seg, in: t) + seg.text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    public func vtt(_ t: Transcript) -> String {
        var out = ["WEBVTT", ""]
        for seg in t.visibleSegments {
            out.append("\(Self.timecode(seg.start, sep: ".")) --> \(Self.timecode(max(seg.end, seg.start + 0.2), sep: "."))")
            out.append(Self.speakerPrefix(seg, in: t) + seg.text)
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    public func plain(_ t: Transcript) -> String {
        var paragraphs: [String] = []
        var current = ""
        var prevEnd: Double? = nil
        var prevSpeaker: Int? = nil
        for seg in t.visibleSegments {
            // 話が切り替わったところで段落を切る。同一話者の連続は時差でもまとめる。
            let turnChanged = seg.speaker != nil && seg.speaker != prevSpeaker
            if (turnChanged || (prevEnd.map { seg.start - $0 > 1.2 } ?? false))
                && !current.isEmpty {
                paragraphs.append(current); current = ""
            }
            if turnChanged { current += "【\(t.speakerName(seg.speaker!))】" }
            current += seg.text
            if current.count >= 90 { paragraphs.append(current); current = "" }
            prevEnd = seg.end
            prevSpeaker = seg.speaker
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    public func jsonData(_ t: Transcript) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(t)
    }

    // MARK: -

    /// 文脈に合わない語の指摘を本文の直下に添える。
    ///
    /// 照合（`↳ 別エンジンの候補`）はエンジン間の不一致しか見ないので、
    /// **全エンジンが同じ間違え方をした箇所には無力**。そこを埋めるのがこれ。
    /// 本文は書き換えていない。`PlausibilityGate` が「その語が本文に実在すること」を
    /// 検証済みなので、ここに出る語は必ず上の行に含まれている。
    static func plausibilityNotes(for segment: Segment, in t: Transcript) -> [String] {
        let flags = t.plausibility.filter {
            abs($0.start - segment.start) < 0.001 && segment.text.contains($0.surface)
        }
        guard !flags.isEmpty else { return [] }
        // 候補の有無で書き分ける。
        // モデルは「どの語が浮いているか」は当てられるが「その語が本来何か」は
        // 当てられない（実測）。読みの近さを通らなかった候補は捨ててあるので、
        // ここで候補が無いものは「怪しいことは分かるが、正解は分からない」を意味する。
        // **無い候補を埋めない。** 埋めると読み手はそれを正解として読む。
        let body = flags.map { "「\($0.surface)」\($0.alternativeNote)" }.joined(separator: " / ")
        return ["> ⚠︎ 文脈から浮いて見える語: \(body)"]
    }

    /// そのセグメントの区間で、他エンジンと結果が割れた語を本文の直下に添える。
    ///
    /// **これを本文と同じ場所に置くことが目的。** 検証記録は文書の後ろにあり、
    /// 読み手（特に LLM）が時刻で突き合わせてくれる保証がない。
    /// 突き合わせが起きなければ、怪しい語が確定した事実として読まれる。
    ///
    /// 出す条件を絞ってあるのは、全部出すと本文が読めなくなるため:
    /// - 中身の違いだけ（整列のずれ・語尾のゆれ・表記差は読み手の判断に影響しない）
    /// - 両側に本文がある（片側が空は「取りこぼしたかもしれない」であって、
    ///   代わりの語を示せないので、ここに書いても読み手にできることが無い）
    /// - どちらかに漢字・カタカナ・英数字がある（内容語。ひらがなだけの差は語尾のゆれの残り）
    static func uncertaintyNotes(for segment: Segment, in t: Transcript,
                                 limit: Int = 6) -> [String] {
        let related = t.crossCheck.disagreements.filter { d in
            guard d.kind == .substantive,
                  d.start < segment.end, d.end > segment.start,
                  let reference = d.candidates.first?.text,
                  d.candidates.allSatisfy({ !$0.text.isEmpty }),
                  d.candidates.contains(where: { hasContentCharacter($0.text) })
            else { return false }

            // **その語が実際にこの行にあること。**
            // 食い違いの時刻は10秒の窓なので、そのまま重なりで拾うと
            // 隣の行にも同じ注記が付く。実際そうなり、
            // 「コンピ」の注記が「コンピ」を含まない行にも出ていた。
            guard segment.text.contains(reference) else { return false }

            // 長さが釣り合っていること。
            // 「、自己評価と上長評価をそれぞれ人事の方」→「まずで実際」のような
            // 極端に不均衡な組は、語の取り違えではなく整列のずれの残り。
            // 候補として読み手に見せると、節まるごとが別物かのように読める。
            let lengths = d.candidates.map(\.text.count)
            guard let shortest = lengths.min(), let longest = lengths.max(),
                  longest <= 10, longest <= shortest * 2 else { return false }
            return true
        }
        guard !related.isEmpty else { return [] }

        // 同じ語の組み合わせは1回にまとめる。エンジンが3本あると同じ箇所が3回出る。
        var seen = Set<String>()
        var pairs: [String] = []
        for d in related {
            let texts = d.candidates.map(\.text)
            guard let head = texts.first else { continue }
            let others = texts.dropFirst().filter { $0 != head }
            guard !others.isEmpty else { continue }
            let phrase = "「\(head)」→「\(others.joined(separator: "」「"))」"
            if seen.insert(phrase).inserted { pairs.append(phrase) }
        }
        guard !pairs.isEmpty else { return [] }

        // 打ち切るときは打ち切ったと書く。黙って切ると「これで全部」と読まれる。
        let shown = pairs.prefix(limit)
        let rest = pairs.count - shown.count
        let tail = rest > 0 ? "（ほか\(rest)件）" : ""
        return ["> ↳ 別エンジンの候補: \(shown.joined(separator: " / "))\(tail)"]
    }

    /// 内容語らしい文字を含むか。ひらがなと約物だけの差は語尾のゆれの残りなので除く。
    static func hasContentCharacter(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)         // 漢字
                || (0x3400...0x4DBF).contains($0.value)
                || (0x30A0...0x30FF).contains($0.value)  // カタカナ
                || (0x0041...0x005A).contains($0.value)  // A-Z
                || (0x0061...0x007A).contains($0.value)  // a-z
                || (0x0030...0x0039).contains($0.value)  // 0-9
        }
    }

    static func label(_ k: AuditReport.Finding.Kind) -> String {
        switch k {
        case .silentHallucination: return "無音区間の幻聴"
        case .repetitionLoop: return "反復ループ"
        case .densityAnomaly: return "取りこぼし疑い"
        case .densityExcess: return "書き過ぎ疑い"
        case .lowConfidence: return "低信頼"
        case .coverageGap: return "カバレッジの穴"
        case .segmentOverrun: return "尺が発話より長い"
        }
    }
    public static func hms(_ x: Double) -> String {
        let v = max(0, x)
        return String(format: "%02d:%02d:%02d", Int(v) / 3600, (Int(v) % 3600) / 60, Int(v) % 60)
    }
    public static func timecode(_ x: Double, sep: String) -> String {
        let v = max(0, x)
        let h = Int(v) / 3600, m = (Int(v) % 3600) / 60
        let s = v - Double(h * 3600 + m * 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s).replacingOccurrences(of: ".", with: sep)
    }
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
