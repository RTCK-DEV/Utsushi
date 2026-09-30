import SwiftUI

@main
struct UtsushiApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Utsushi") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // キュー制なので実行中の追加も安全（差し替えではなく積み上げ）。
                Button("ファイルを開く…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
