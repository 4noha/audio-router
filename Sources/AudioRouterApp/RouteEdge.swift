import Foundation

/// 入力ソース種別（バスへ書く側）。nil = ソース無し。
enum SourceKind: String, Codable, Hashable, CaseIterable {
    case appTap       // VLC 等のアプリ音をタップ
    case mic          // 入力デバイス（マイク）
    case babigoeOut   // babigoe 処理済(/babigoe.out)を読む
    case wirelessMic  // Android アプリ等から UDP で送られたマイク音 (slot 1..4)

    var label: String {
        switch self {
        case .appTap:      return "アプリ"
        case .mic:         return "マイク"
        case .babigoeOut:  return "babigoe"
        case .wirelessMic: return "ワイヤレスマイク"
        }
    }
    var icon: String {
        switch self {
        case .appTap:      return "app.fill"
        case .mic:         return "mic.fill"
        case .babigoeOut:  return "waveform"
        case .wirelessMic: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// 出力シンク種別（バスから読む側）。nil = シンク無し。
enum SinkKind: String, Codable, Hashable, CaseIterable {
    case splitter     // 4ksplitter(/4ksp.voice) へ
    case babigoeIn    // babigoe 入力(/babigoe.in) へ
    case recorder     // ファイルへ録音(WAV)
    case obs          // OBS(obs-audio-router-shm)へ /obs.mic*/.video*
    case netSpeaker   // 接続中の全 Android アプリへ Opus で送る (戻し)

    var label: String {
        switch self {
        case .splitter:    return "4ksplitter"
        case .babigoeIn:   return "babigoe"
        case .recorder:    return "録音"
        case .obs:         return "OBS"
        case .netSpeaker:  return "ネットスピーカー"
        }
    }
}

/// OBS sink の枠種別。mic=4 枠/video=2 枠。raw 値は shm 名構築に使う
/// （ShmSender.obsName(kind:slot:)）。
enum ObsKind: String, Codable, Hashable, CaseIterable {
    case mic
    case video

    var label: String {
        switch self {
        case .mic:   return "マイク"
        case .video: return "映像音"
        }
    }
    var maxSlot: Int {
        switch self {
        case .mic:   return 4
        case .video: return 2
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
    // 4ksplitter 行きの「モデル枠」(1..4)。1 = レガシー名 /4ksp.voice3、
    // 2..4 = /4ksp.voice3.<n>。sink == .splitter のときだけ意味を持つ。
    // 既存 routes.json には未存在＝下の明示 init で 1 既定。
    var splitterSlot: Int = 1
    // OBS sink 行きの枠種別と番号。sink == .obs のときだけ意味を持つ。
    // mic は 1..4、video は 1..2（ObsKind.maxSlot に従う）。
    var obsKind: ObsKind = .mic
    var obsSlot: Int = 1
    // ワイヤレスマイク slot 番号 (1..4)。source == .wirelessMic のときだけ意味を持つ。
    // netSpeaker sink は全 slot ブロードキャストなので参照しない。
    var wirelessSlot: Int = 1
    // babigoe 行きの枠 (1..4)。1 = レガシー /babigoe.in3 と /babigoe.out3、
    // 2..4 = .<n> 接尾辞。babigoe-kai 側の元バ美声=1、VST デッキ=2 想定。
    // sink == .babigoeIn または source == .babigoeOut のときだけ意味を持つ。
    var babigoeSlot: Int = 1

    var icon: String { source?.icon ?? "arrow.right.circle" }

    // 旧 routes.json (splitterSlot/obsKind/obsSlot 未保存) が decode で全 throw
    // しないよう明示 init(from:) を実装し全キー decodeIfPresent ?? 既定値。
    // encode は合成のまま。
    enum CodingKeys: String, CodingKey {
        case id, bus, source, sink
        case appBundleID, appName, muteSource
        case micUID, micName
        case enabled, splitterSlot, obsKind, obsSlot, babigoeSlot, wirelessSlot
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        bus = (try c.decodeIfPresent(String.self, forKey: .bus)) ?? "bus1"
        source = try c.decodeIfPresent(SourceKind.self, forKey: .source)
        sink = try c.decodeIfPresent(SinkKind.self, forKey: .sink)
        appBundleID = (try c.decodeIfPresent(String.self, forKey: .appBundleID)) ?? ""
        appName = (try c.decodeIfPresent(String.self, forKey: .appName)) ?? ""
        muteSource = (try c.decodeIfPresent(Bool.self, forKey: .muteSource)) ?? false
        micUID = (try c.decodeIfPresent(String.self, forKey: .micUID)) ?? ""
        micName = (try c.decodeIfPresent(String.self, forKey: .micName)) ?? ""
        enabled = (try c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        splitterSlot = (try c.decodeIfPresent(Int.self, forKey: .splitterSlot)) ?? 1
        if splitterSlot < 1 { splitterSlot = 1 }
        if splitterSlot > 4 { splitterSlot = 4 }
        obsKind = (try c.decodeIfPresent(ObsKind.self, forKey: .obsKind)) ?? .mic
        obsSlot = (try c.decodeIfPresent(Int.self, forKey: .obsSlot)) ?? 1
        if obsSlot < 1 { obsSlot = 1 }
        if obsSlot > obsKind.maxSlot { obsSlot = obsKind.maxSlot }
        babigoeSlot = (try c.decodeIfPresent(Int.self, forKey: .babigoeSlot)) ?? 1
        if babigoeSlot < 1 { babigoeSlot = 1 }
        if babigoeSlot > 4 { babigoeSlot = 4 }
        wirelessSlot = (try c.decodeIfPresent(Int.self, forKey: .wirelessSlot)) ?? 1
        if wirelessSlot < 1 { wirelessSlot = 1 }
        if wirelessSlot > 4 { wirelessSlot = 4 }
    }

    /// IN ソース表示名（nil = ソース無し）。
    var displaySource: String? {
        switch source {
        case .appTap:     return appName.isEmpty ? "（アプリ未選択）" : appName
        case .mic:        return micName.isEmpty ? "既定マイク" : micName
        case .babigoeOut: return babigoeSlot > 1 ? "babigoe#\(babigoeSlot)" : "babigoe"
        case .wirelessMic: return wirelessSlot > 1 ? "ワイヤレスマイク#\(wirelessSlot)" : "ワイヤレスマイク"
        case .none:       return nil
        }
    }
    /// OUT シンク表示名（nil = シンク無し）。
    /// splitter かつ枠>1 のとき "4ksplitter#N"、obs は "OBS マイク[#N]"/"OBS 映像音[#N]"。
    var displaySink: String? {
        guard let s = sink else { return nil }
        if s == .splitter && splitterSlot > 1 { return "\(s.label)#\(splitterSlot)" }
        if s == .babigoeIn && babigoeSlot > 1 { return "\(s.label)#\(babigoeSlot)" }
        if s == .obs {
            let suffix = obsSlot > 1 ? "#\(obsSlot)" : ""
            return "\(s.label) \(obsKind.label)\(suffix)"
        }
        return s.label
    }

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
