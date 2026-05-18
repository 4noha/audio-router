import Foundation

/// 入力ソース種別（バスへ書く側）。nil = ソース無し。
enum SourceKind: String, Codable, Hashable, CaseIterable {
    case appTap      // VLC 等のアプリ音をタップ
    case mic         // 入力デバイス（マイク）
    case babigoeOut  // babigoe 処理済(/babigoe.out)を読む

    var label: String {
        switch self {
        case .appTap:     return "アプリ"
        case .mic:        return "マイク"
        case .babigoeOut: return "babigoe"
        }
    }
    var icon: String {
        switch self {
        case .appTap:     return "app.fill"
        case .mic:        return "mic.fill"
        case .babigoeOut: return "waveform"
        }
    }
}

/// 出力シンク種別（バスから読む側）。nil = シンク無し。
enum SinkKind: String, Codable, Hashable, CaseIterable {
    case splitter    // 4ksplitter(/4ksp.voice) へ
    case babigoeIn   // babigoe 入力(/babigoe.in) へ
    case recorder    // ファイルへ録音(WAV)

    var label: String {
        switch self {
        case .splitter:  return "4ksplitter"
        case .babigoeIn: return "babigoe"
        case .recorder:  return "録音"
        }
    }
}

/// 1 行のルート。`source ‐ bus ‐ sink` を一行で表現。source/sink は任意で、
/// 片方だけなら `VLC ‐ bus2` / `bus2 ‐ 4ksplitter` のような部分指定になる。
/// 同じ bus 名を複数行で共有して分岐(fan-out)。バスは複数 reader 対応。
struct RouteRow: Identifiable, Codable, Hashable {
    var id = UUID()
    var bus: String = "bus1"
    var source: SourceKind? = nil
    var sink: SinkKind? = nil

    // appTap
    var appBundleID: String = ""
    var appName: String = ""
    var muteSource: Bool = false
    // mic
    var micUID: String = ""        // 空 = 既定入力
    var micName: String = ""

    var enabled: Bool = false

    var icon: String { source?.icon ?? "arrow.right.circle" }

    /// IN ソース表示名（nil = ソース無し）。
    var displaySource: String? {
        switch source {
        case .appTap:     return appName.isEmpty ? "（アプリ未選択）" : appName
        case .mic:        return micName.isEmpty ? "既定マイク" : micName
        case .babigoeOut: return "babigoe"
        case .none:       return nil
        }
    }
    /// OUT シンク表示名（nil = シンク無し）。
    var displaySink: String? { sink?.label }

    var busLabel: String { "［\(bus)］" }

    private var sourceName: String { displaySource ?? "" }
    private var sinkName: String { displaySink ?? "" }

    /// 一行表示: `VLC ‐ bus1 ‐ 4ksplitter` /『VLC ‐ bus2』/『bus2 ‐ 4ksplitter』。
    var oneLine: String {
        var s = ""
        if source != nil {
            s += sourceName
            if source == .appTap && muteSource { s += "🔇" }
            s += " ‐ "
        }
        s += "［\(bus)］"
        if sink != nil { s += " ‐ " + sinkName }
        return s
    }
}
