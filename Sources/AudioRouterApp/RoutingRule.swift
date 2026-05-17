import Foundation

/// ルートの種別。
/// - appRoute  : アプリ音声を捕捉 → 4ksplitter(共有メモリ) / 任意 UDP・モニタ
/// - babigoeHub: マイク → babigoe(声質変換) → 回収 → 4ksplitter(＋任意モニタ/UDP)
enum RuleKind: String, Codable, Hashable {
    case appRoute, babigoeHub
}

/// 1 本のルーティング定義（IN → OUT）。Karabiner 風に一覧へ並べ、
/// 行トグルで個別に有効化。JSON で永続化される。
struct RoutingRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: RuleKind = .appRoute

    // appRoute: 対象アプリ（bundleID は再起動をまたいで安定）
    var sourceBundleID: String = ""
    var sourceName: String = ""

    // 送出（appRoute は任意 UDP、babigoeHub は任意 UDP 追加経路）
    var sendHost: String = "127.0.0.1"
    var sendPort: String = "7878"
    var udpEnabled: Bool = false

    // モニタ（自分の声/音を別デバイスで聴く）
    var monitorEnabled: Bool = false
    var monitorDeviceUID: String = ""   // 空 = 既定出力

    // babigoeHub: 入力マイク
    var micUID: String = ""             // 空 = 既定入力
    var micName: String = ""

    /// ユーザ意図の有効状態（永続化）。実エンジン状態と一致させる。
    var enabled: Bool = false

    // MARK: - 一覧表示（IN → OUT）

    var inIcon: String {
        kind == .babigoeHub ? "mic.fill" : "app.fill"
    }

    var displayIn: String {
        switch kind {
        case .appRoute:
            return sourceName.isEmpty ? "（アプリ未選択）" : sourceName
        case .babigoeHub:
            return micName.isEmpty ? "既定マイク" : micName
        }
    }

    var displayOut: String {
        var s: String
        switch kind {
        case .appRoute:   s = "4ksplitter"
        case .babigoeHub: s = "babigoe → 4ksplitter"
        }
        if monitorEnabled { s += " ＋モニタ" }
        if udpEnabled { s += " ＋UDP \(sendHost):\(sendPort)" }
        return s
    }
}
