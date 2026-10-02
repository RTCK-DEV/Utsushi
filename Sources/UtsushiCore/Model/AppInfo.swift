import Foundation

/// アプリの名前・版・作者。**source of truth は Info.plist ひとつ。**
///
/// ソースに定数で持つと Info.plist と二重管理になり、片方だけ古い値が残る。
/// 版はビルド設定から来るものなので、実行時にバンドルから読む。
public enum AppInfo {
    public static let name = "Utsushi"
    public static let author = "RTCK"

    /// `0.4.2` のような表示用の版。取れなければ nil。
    ///
    /// テストから実行するとバンドルはテストランナーのものになるので、
    /// アプリの版が取れないことがある。**その場合は「不明」と書かずに省く。**
    /// 嘘の版が書き出しに載ると、どのビルドの出力か追えなくなる。
    public static var version: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    public static var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// 書き出しに載せる1行。版が取れないときは名前と作者だけになる。
    public static var credit: String {
        if let v = version {
            return "\(name) \(v) — © 2026 \(author)"
        }
        return "\(name) — © 2026 \(author)"
    }

    /// 画面に出す版表記。
    public static var displayVersion: String {
        guard let v = version else { return String(localized: "版は不明") }
        if let b = build { return String(localized: "\(v)（build \(b)）") }
        return v
    }
}
