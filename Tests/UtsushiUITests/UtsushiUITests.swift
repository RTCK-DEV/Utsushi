import XCTest
import AppKit

/// 実機 UI テスト。
///
/// ユニットテストがパイプラインの中身を保証するのに対し、こちらは
/// 「画面のボタンが実際に機能するか」「ファイルを開いて結果と書き出しまで辿れるか」
/// を保証する。AX 構造に依存するため、失敗時は `app.debugDescription` の出力を読む。
///
/// 実行環境のシステム言語は en-JP のため UI は英語で出るが、
/// 一部の文言は Localizable.xcstrings にエントリがなく日本語のまま出る
/// （例: 「書き出し」メニュー、タブ名）。両方を順に探す。
///
/// NSOpenPanel / NSSavePanel は com.apple.appkit.xpc.openAndSavePanelService が
/// 別プロセスで描く。アプリ側の AX ツリーには出ないので、サービス側を別に掴む。
final class UtsushiUITests: XCTestCase {

    private var app: XCUIApplication!
    /// NSOpenPanel / NSSavePanel は openAndSavePanelService のリモートビューだが、
    /// AX はアプリ側にブリッジされ app.dialogs["open-panel" 等] にぶら下がる。
    /// app.buttons 直下を探すと Touch Bar プロキシに誤マッチするので、必ず dialog 内を探す。
    private var panel: XCUIElement { app.dialogs.firstMatch }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UtsushiUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }
    /// プロジェクト内の検証素材（11分・実音声）
    private static var fixtureURL: URL {
        repoRoot.appendingPathComponent("fixtures/testclip.m4a")
    }
    /// 開発者の実録音。あれば高速実行の入力に使う（無ければ fixture に逃がす）
    private static var realAudioURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/Aichi Sangyo University 2.m4a")
    }
    private static let exportDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("utsushi-ui-export")
    private static let fakeFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("utsushi-fake.m4a")

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "メインウィンドウが出ない\n" + app.debugDescription)
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: - 初期状態

    func test00_probeAXTree() throws {
        sleep(1)
        button(["Choose a file…", "ファイルを選ぶ…"]).click()
        sleep(2)
        print("===DIALOGS=== \(app.dialogs.count) sheets=\(app.sheets.count) windows=\(app.windows.count)")
        print("===PANELDUMP===\n\(panel.debugDescription)\n===END===")
        app.typeKey(.escape, modifierFlags: [])
    }

    func test01_initialState() throws {
        XCTAssertTrue(button(["Choose a file…", "ファイルを選ぶ…"]).waitForExistence(timeout: 5),
                      "ファイル選択ボタンが無い")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS 'Drop a video' OR value CONTAINS 'Drop a video'"))
                .firstMatch.exists,
                      "ドロップ案内が無い\n" + app.debugDescription)
        XCTAssertFalse(button(["Fast", "高速"]).exists, "ファイル未選択なのに実行ボタンが出ている")
        XCTAssertFalse(button(["Standard", "標準"]).exists)
        XCTAssertFalse(button(["Cancel", "キャンセル"]).exists)
    }

    // MARK: - ファイルを開く

    func test02_openFileViaPanelShowsRunButtons() throws {
        openFileViaPanel(Self.fixtureURL)

        XCTAssertTrue(text("testclip.m4a").waitForExistence(timeout: 10),
                      "ヘッダにファイル名が出ない\n" + app.debugDescription)
        XCTAssertTrue(button(["Fast", "高速"]).exists && button(["Standard", "標準"]).exists,
                      "実行ボタンが出ない")
        XCTAssertTrue(button(["Another file…", "別のファイル…"]).exists)
        // 尺・サイズ・音声トラックの有無が出ること（describe の完了）
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
                format: "value CONTAINS[c] 'audio track' OR value CONTAINS '音声トラック'"))
                .firstMatch.waitForExistence(timeout: 10),
                      "音声情報の表示が出ない\n" + app.debugDescription)

        // 「別のファイル…」がパネルを開くこと。Esc で閉じても状態が保たれること。
        button(["Another file…", "別のファイル…"]).click()
        XCTAssertTrue(panel.waitForExistence(timeout: 5),
                      "別のファイルボタンがパネルを開かない")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(button(["Fast", "高速"]).waitForExistence(timeout: 5),
                      "パネルを閉じたあと実行ボタンが戻らない")
    }

    // MARK: - エラー表示

    func test03_unreadableFileShowsErrorAlert() throws {
        try Data([0x00, 0x11, 0x22, 0x33]).write(to: Self.fakeFile)
        openFileViaPanel(Self.fakeFile)

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
                format: "value CONTAINS 'Cannot read' OR value CONTAINS '読み込めない'"))
                .firstMatch.waitForExistence(timeout: 10),
                      "読み込めない旨のステータスが出ない\n" + app.debugDescription)

        button(["Fast", "高速"]).click()
        // SwiftUI の .alert は macOS では Dialog ではなく Sheet として出る
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30),
                      "エラーアラートが出ない\n" + app.debugDescription)
        let closeBtn = alert.buttons["Close"].exists ? alert.buttons["Close"]
                                                   : alert.buttons["閉じる"]
        XCTAssertTrue(closeBtn.exists, "アラートに閉じるボタンが無い\n" + alert.debugDescription)
        closeBtn.click()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "アラートが閉じない")
        XCTAssertTrue(button(["Fast", "高速"]).exists, "エラー後に実行ボタンが戻っていない")
    }

    // MARK: - 高速実行 → 完了 → タブ → 書き出し

    func test04_fastRunToCompletionAndExport() throws {
        let input = FileManager.default.fileExists(atPath: Self.realAudioURL.path)
            ? Self.realAudioURL : Self.fixtureURL
        openFileViaPanel(input)

        button(["Fast", "高速"]).click()
        XCTAssertTrue(button(["Cancel", "キャンセル"]).waitForExistence(timeout: 15),
                      "実行中にキャンセルボタンが出ない")

        XCTAssertTrue(eventually(900) {
            self.text("Done").exists || self.text("完了").exists
        }, "高速実行が完了しない\n" + app.debugDescription)
        XCTAssertTrue(app.staticTexts
                        .matching(NSPredicate(format: "value CONTAINS[c] 'segment' OR value CONTAINS 'セグメント'"))
                        .firstMatch.waitForExistence(timeout: 10),
                      "フッタのセグメント数が出ない")

        // タブの切り替え（本文以外にも全タブが開けること）
        for tab in [["Summary", "要約"], ["Corrections", "校正差分"],
                    ["Cross-check", "照合"], ["Audit", "Audit log", "検証記録"], ["Transcript", "本文"]] {
            selectTab(tab)
        }

        // 書き出しメニュー → 全形式書き出し → フォルダ選択 → 実ファイル検証
        try? FileManager.default.removeItem(at: Self.exportDir)
        try? FileManager.default.createDirectory(at: Self.exportDir, withIntermediateDirectories: true)

        menuButton(["Export", "書き出し"]).click()
        var allItem = app.menuItems["Export every format to a folder"].firstMatch
        if !allItem.waitForExistence(timeout: 3) {
            allItem = app.menuItems["全形式をフォルダに書き出す"].firstMatch
        }
        XCTAssertTrue(allItem.exists, "書き出しメニューが開かない\n" + app.debugDescription)
        allItem.click()
        pickFolderInPanel(Self.exportDir.path)

        // 5形式が書かれており、中身があること
        var written: [String] = []
        XCTAssertTrue(eventually(30) {
            written = (try? FileManager.default.contentsOfDirectory(atPath: Self.exportDir.path)) ?? []
            return written.count >= 5
        }, "書き出しファイルが揃わない: \(written)")
        for f in written {
            let size = (try? FileManager.default
                .attributesOfItem(atPath: Self.exportDir.appendingPathComponent(f).path)[.size])
                as? Int ?? 0
            XCTAssertGreaterThan(size, 100, "\(f) が空")
        }
    }

    // MARK: - 標準実行: キャンセル → 本実行 → 校正ボタン

    func test05_standardRunCancelThenComplete() throws {
        openFileViaPanel(Self.fixtureURL)

        // キャンセルが効くこと（実行ボタンが戻るのがキャンセル完了の証明）
        button(["Standard", "標準"]).click()
        XCTAssertTrue(button(["Cancel", "キャンセル"]).waitForExistence(timeout: 15))
        button(["Cancel", "キャンセル"]).click()
        XCTAssertTrue(button(["Standard", "標準"]).waitForExistence(timeout: 240),
                      "キャンセル後に実行ボタンが戻らない\n" + app.debugDescription)

        // 本実行（ユーザーの実設定: whisper + 照合 + 校正/要約）
        button(["Standard", "標準"]).click()
        XCTAssertTrue(button(["Cancel", "キャンセル"]).waitForExistence(timeout: 15),
                      "2回目の実行が始まらない")
        XCTAssertTrue(eventually(1800) {
            self.text("Done").exists || self.text("完了").exists
        }, "標準実行が完了しない\n" + app.debugDescription)

        // 本文タブにセグメント行があること
        selectTab(["Transcript", "本文"])
        XCTAssertTrue(app.staticTexts
                        .matching(NSPredicate(format: "value MATCHES %@", "[0-9]{2}:[0-9]{2}:[0-9]{2}"))
                        .firstMatch.waitForExistence(timeout: 10),
                      "本文にタイムスタンプ行が無い")

        // 校正差分: 変更があれば「すべて原文に戻す」と行ボタンを実際に押す
        selectTab(["Corrections", "校正差分"])
        if button(["Revert all", "すべて原文に戻す"]).waitForExistence(timeout: 5) {
            let revertRow = app.buttons["Revert"].firstMatch.exists
                ? app.buttons["Revert"].firstMatch : app.buttons["原文に戻す"].firstMatch
            let applyRow = app.buttons["Apply"].firstMatch.exists
                ? app.buttons["Apply"].firstMatch : app.buttons["校正を適用"].firstMatch
            if revertRow.exists { revertRow.click() }
            if applyRow.waitForExistence(timeout: 3) { applyRow.click() }
            button(["Revert all", "すべて原文に戻す"]).click()
        }
        // 変更が無い場合もタブが開ければ良い

        // 要約・照合・検証記録・本文と全タブが開けること
        selectTab(["Summary", "要約"])
        selectTab(["Cross-check", "照合"])
        selectTab(["Audit", "Audit log", "検証記録"])
        selectTab(["Transcript", "本文"])
    }

    // MARK: - 設定ウィンドウ

    func test06_settingsWindowControls() throws {
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(eventually(10) { self.app.windows.count > 1 },
                      "設定ウィンドウが開かない\n" + app.debugDescription)

        // 校正タブの「状態を再確認」は副作用なしで押せる
        selectSettingsTab(["Proofreading", "校正"])
        let recheck = button(["Check again", "状態を再確認"])
        XCTAssertTrue(recheck.waitForExistence(timeout: 5),
                      "状態を再確認が無い\n" + app.debugDescription)
        recheck.click()

        // 辞書タブ: 追加→削除→保存（元データを汚さない往復）
        selectSettingsTab(["Dictionary", "辞書"])
        XCTAssertTrue(button(["Add", "追加"]).waitForExistence(timeout: 5),
                      "辞書タブの追加ボタンが無い\n" + app.debugDescription)
        button(["Add", "追加"]).click()
        button(["Delete", "削除"]).click()
        button(["Save", "保存"]).click()

        // 情報タブにバージョンが出ていること
        selectSettingsTab(["About", "情報"])
        XCTAssertTrue(app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS '0.6' OR label CONTAINS '0.6'"))
                .firstMatch.waitForExistence(timeout: 5),
                      "バージョン表示が無い\n"
                        + app.windows.element(boundBy: 1).debugDescription)

        // 閉じる
        let settingsWindow = app.windows.element(boundBy: 1)
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(eventually(5) { self.app.windows.count == 1 },
                      "設定ウィンドウが閉じない")
    }

    // MARK: - 複数ファイルキュー

    /// 2件を連続で追加 → 高速で順に処理 → 両方の結果が切り替えて見られること。
    /// 2件目は fixture の複製（同名ファイルは重複登録されないので別名にする）。
    func test08_twoFileQueueRunsBoth() throws {
        let second = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("utsushi-queue-2.m4a")
        try? FileManager.default.removeItem(at: second)
        try FileManager.default.copyItem(at: Self.fixtureURL, to: second)

        openFileViaPanel(Self.fixtureURL)
        // 2件目は「別のファイル…」から追加（キューに積まれる）
        openFileViaPanel(second)

        // 2件でキューストリップが出る（ファイル名のボタンが2つ）
        let chip1 = button(["testclip.m4a"])
        let chip2 = button(["utsushi-queue-2.m4a"])
        XCTAssertTrue(chip1.waitForExistence(timeout: 5)
                        && chip2.waitForExistence(timeout: 5),
                      "キューの2行が出ない\n" + app.debugDescription)

        button(["Fast", "高速"]).click()
        XCTAssertTrue(button(["Cancel", "キャンセル"]).waitForExistence(timeout: 15),
                      "実行中にキャンセルボタンが出ない")

        // 2件とも終わるまで待つ（高速はOS内蔵なので fixture 11分で数十秒）
        XCTAssertTrue(eventually(600) {
            self.text("Done").exists || self.text("完了").exists
        }, "キューが完了しない\n" + app.debugDescription)

        // 両方の結果が切り替えて見られる（フッタのセグメント数が出る）
        chip2.click()
        XCTAssertTrue(app.staticTexts
                        .matching(NSPredicate(format: "value CONTAINS[c] 'segment' OR value CONTAINS 'セグメント'"))
                        .firstMatch.waitForExistence(timeout: 10),
                      "2件目の結果が表示されない")
        chip1.click()
        XCTAssertTrue(app.staticTexts
                        .matching(NSPredicate(format: "value CONTAINS[c] 'segment' OR value CONTAINS 'セグメント'"))
                        .firstMatch.waitForExistence(timeout: 10),
                      "1件目の結果に切り替わらない")
    }

    // MARK: - メニューバー

    func test07_menuBarOpenItem() throws {
        var fileMenu = app.menuBars.firstMatch.menuBarItems["File"].firstMatch
        if !fileMenu.waitForExistence(timeout: 3) {
            fileMenu = app.menuBars.firstMatch.menuBarItems["ファイル"].firstMatch
        }
        XCTAssertTrue(fileMenu.exists, "ファイルメニューが無い\n" + app.debugDescription)
        fileMenu.click()
        var item = app.menuItems["Open a file…"].firstMatch
        if !item.waitForExistence(timeout: 3) {
            item = app.menuItems["ファイルを開く…"].firstMatch
        }
        XCTAssertTrue(item.exists, "メニュー項目が無い")
        item.click()
        // パネルが開く → Esc で閉じる
        XCTAssertTrue(panel.waitForExistence(timeout: 5),
                      "メニュー項目がパネルを開かない")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(button(["Choose a file…", "ファイルを選ぶ…"]).waitForExistence(timeout: 5)
                        || button(["Another file…", "別のファイル…"]).exists,
                      "パネルを閉じたあと元の画面に戻らない")
    }

    // MARK: - helpers

    /// 英語 / 日本語どちらのラベルでも押せるようにする（未翻訳箇所対策）
    private func button(_ titles: [String]) -> XCUIElement {
        for t in titles {
            let e = app.buttons[t].firstMatch
            if e.exists { return e }
        }
        return app.buttons[titles[0]].firstMatch
    }
    private func text(_ title: String) -> XCUIElement { app.staticTexts[title].firstMatch }
    private func menuButton(_ titles: [String]) -> XCUIElement {
        for t in titles {
            for kind in [app.menuButtons[t], app.popUpButtons[t], app.buttons[t]] {
                if kind.firstMatch.exists { return kind.firstMatch }
            }
        }
        return app.menuButtons[titles[0]].firstMatch
    }

    /// セグメント/タブピッカーのタブ。macOS 27 の .tabs スタイルは
    /// TabGroup+Tab として出る。版によって AX 形状が違うため複数経路で探す。
    private func selectTab(_ titles: [String]) {
        for title in titles {
            let candidates: [XCUIElement] = [
                app.tabGroups.firstMatch.tabs[title],
                app.tabs[title],
                app.segmentedControls.firstMatch.buttons[title],
                app.radioGroups.firstMatch.radioButtons[title],
                app.radioButtons[title],
                app.checkBoxes[title],
            ]
            for c in candidates where c.exists { c.click(); return }
        }
        XCTFail("タブ \(titles) が見つからない\n" + app.debugDescription)
    }

    private func selectSettingsTab(_ titles: [String]) {
        for title in titles {
            let candidates: [XCUIElement] = [
                app.radioButtons[title],
                app.buttons[title],
                app.checkBoxes[title],
            ]
            for c in candidates where c.exists { c.click(); return }
        }
        XCTFail("設定タブ \(titles) が見つからない\n" + app.debugDescription)
    }

    /// NSOpenPanel を「フォルダへ移動」シート経由で目的ファイルまで運ぶ。
    private func openFileViaPanel(_ url: URL) {
        let open = button(["Choose a file…", "ファイルを選ぶ…"]).exists
            ? button(["Choose a file…", "ファイルを選ぶ…"])
            : button(["Another file…", "別のファイル…"])
        XCTAssertTrue(open.waitForExistence(timeout: 10), "ファイル選択ボタンが無い")
        open.click()
        typePathInPanel(url.path)
        confirmPanel()
    }

    /// exportAll のフォルダ選択パネル
    private func pickFolderInPanel(_ path: String) {
        typePathInPanel(path)
        confirmPanel()
    }

    /// パネルの確定ボタンを押す。OKButton / CancelButton は AppKit 由来の
    /// identifier で安定しており、表示ラベルはロケールで変わる。
    private func confirmPanel() {
        guard panel.exists else { return }
        let ok = panel.buttons["OKButton"].firstMatch
        if ok.waitForExistence(timeout: 4), ok.isEnabled { ok.click(); return }
        for title in ["Open", "Choose", "開く", "選択", "このフォルダに書き出す"] {
            let b = panel.buttons[title].firstMatch
            if b.exists, b.isEnabled { b.click(); return }
        }
        // すでに閉じている（パス直接指定で開いた）場合は何もしない
    }

    /// Goシートのパス入力欄。identifier は PathTextField で安定している。
    /// （ファイル一覧のファイル名セルも TextField なので firstMatch では誤認する）
    private var goField: XCUIElement { panel.textFields["PathTextField"].firstMatch }

    private func typePathInPanel(_ path: String) {
        XCTAssertTrue(panel.waitForExistence(timeout: 10),
                      "ファイルパネルが出ない\n" + app.debugDescription)

        // typeText は1文字ずつのキー入力で、Goシートのオートコンプリートが
        // 直近履歴（/tmp 等）の候補を挟み、Return で入力パスではなく
        // 補完候補が確定される事故があった（実際に /tmp に着陸した）。
        // 対策: パスはクリップボード貼り付けで一括入力し、確定はシート側の
        // 「移動」ボタンを直接押す。Return は補完候補の確定に奪われるため使わない。
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)

        for _ in 0..<4 {
            let field = goField
            if !field.exists {
                app.typeKey(XCUIKeyboardKey("g"), modifierFlags: [.command, .shift])
                XCTAssertTrue(field.waitForExistence(timeout: 5),
                              "「フォルダへ移動」シートが出ない\n" + panel.debugDescription)
            }
            field.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey("v", modifierFlags: .command)
            usleep(300_000)

            let go = panel.buttons.matching(NSPredicate(
                format: "identifier CONTAINS[c] 'go' OR label == 'Go' OR label == '移動'"))
                .firstMatch
            if go.exists, go.isEnabled { go.click() } else {
                app.typeKey(.return, modifierFlags: [])
            }

            // シートが閉じてファイル選択→パネル確定ボタンが効くまで待つ
            for _ in 0..<8 {
                usleep(500_000)
                if !panel.exists { return }
                let ok = panel.buttons["OKButton"].firstMatch
                if ok.exists, ok.isEnabled { ok.click(); return }
            }
            // 別フォルダに着陸した可能性。シートが残っていたら畳んでやり直す。
            if goField.exists { app.typeKey(.escape, modifierFlags: []); usleep(300_000) }
        }
        // ここまで残っていたら入力が受理されなかった。画面とAX状態を残す。
        try? Process.run(URL(fileURLWithPath: "/usr/sbin/screencapture"),
                         arguments: ["-x", "/tmp/utsushi-panel-stuck.png"])
        print("===PANEL STUCK===\n\(app.debugDescription)\n===END STUCK===")
        app.typeKey(.escape, modifierFlags: [])
    }

    private func eventually(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            usleep(300_000)
        }
        return false
    }
}
