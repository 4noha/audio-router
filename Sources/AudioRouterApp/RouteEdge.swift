import Foundation

/// エッジの向き。input = ソース→バス、output = バス→シンク。
enum EdgeRole: String, Codable, Hashable { case input, output }

/// エッジ端点の種別。
enum EdgeEndpoint: String, Codable, Hashable {
    // input ソース
    case appTap      // VLC 等のアプリ音をタップ
    case mic         // 入力デバイス（マイク）
    case babigoeOut  // babigoe 処理済(/babigoe.out)を読む
    // output シンク
    case splitter    // 4ksplitter(/4ksp.voice) へ
    case babigoeIn   // babigoe 入力(/babigoe.in) へ

    var label: String {
        switch self {
        case .appTap:     return "アプリ"
        case .mic:        return "マイク"
        case .babigoeOut: return "babigoe"
        case .splitter:   return "4ksplitter"
        case .babigoeIn:  return "babigoe"
        }
    }
    var icon: String {
        switch self {
        case .appTap:     return "app.fill"
        case .mic:        return "mic.fill"
        case .babigoeOut: return "waveform"
        case .splitter:   return "dot.radiowaves.left.and.right"
        case .babigoeIn:  return "waveform"
        }
    }
}

/// 1 本のルーティングエッジ（IN→bus か bus→OUT）。Karabiner 風一覧で
/// 個別トグル。名前付き内部バスで結線（OUT は読むバスを選ぶ）。
struct RouteEdge: Identifiable, Codable, Hashable {
    var id = UUID()
    var role: EdgeRole
    var endpoint: EdgeEndpoint
    var busName: String = "bus1"

    // appTap
    var appBundleID: String = ""
    var appName: String = ""
    var muteSource: Bool = false
    // mic
    var micUID: String = ""        // 空 = 既定入力
    var micName: String = ""

    var enabled: Bool = false

    var icon: String { endpoint.icon }

    private var endpointName: String {
        switch endpoint {
        case .appTap: return appName.isEmpty ? "（アプリ未選択）" : appName
        case .mic:    return micName.isEmpty ? "既定マイク" : micName
        default:      return endpoint.label
        }
    }

    /// 一覧表示: 左 → 右
    var displayLeft: String  { role == .input ? endpointName : "［\(busName)］" }
    var displayRight: String { role == .input ? "［\(busName)］" : endpointName
        + (endpoint == .appTap && muteSource ? " (元ミュート)" : "") }
}
