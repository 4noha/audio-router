import Foundation

/// 1 本の音声ルート定義（FROM アプリ → UDP / 任意モニタ）。
/// Karabiner の complex-modification ルールと同様、トグルで個別に
/// 有効化でき、JSON で永続化される。
struct RoutingRule: Identifiable, Codable, Hashable {
    var id = UUID()

    /// 対象アプリ。bundleID は再起動をまたいで安定するためマッチングに使う。
    var sourceBundleID: String
    /// 表示用キャッシュ名（対象アプリ未起動でも一覧に出すため）。
    var sourceName: String

    var sendHost: String = "127.0.0.1"
    var sendPort: String = "7878"

    var monitorEnabled: Bool = false
    /// モニタ出力デバイス UID（空 = 既定出力）。UID は安定識別子。
    var monitorDeviceUID: String = ""

    /// ユーザが意図する有効状態（永続化）。実エンジン状態と一致させる。
    var enabled: Bool = false

    /// 行サブテキスト（"VLC → UDP 127.0.0.1:7878 ＋モニタ"）。
    var displaySummary: String {
        var s = "UDP \(sendHost):\(sendPort)"
        if monitorEnabled { s += " ＋モニタ" }
        return s
    }
}
