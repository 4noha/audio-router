import SwiftUI
import AppKit
import AudioRouterCore

@available(macOS 14.4, *)
enum Pane: String, CaseIterable, Identifiable {
    case routing, activity, maintenance
    var id: String { rawValue }
    var label: String {
        switch self {
        case .routing:     return "Routing"
        case .activity:    return "Activity"
        case .maintenance: return "Maintenance"
        }
    }
    var icon: String {
        switch self {
        case .routing:     return "arrow.triangle.branch"
        case .activity:    return "waveform"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

@available(macOS 14.4, *)
struct ContentView: View {
    @StateObject private var ctl = RouterController()
    @State private var pane: Pane? = .routing

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section("Patchbay") { sidebarItem(.routing) }
                Section("Diagnostic") { sidebarItem(.activity) }
                Section("Maintenance") { sidebarItem(.maintenance) }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch pane ?? .routing {
                case .routing:     RoutingView(ctl: ctl)
                case .activity:    ActivityView(ctl: ctl)
                case .maintenance: MaintenanceView(ctl: ctl)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, minHeight: 520)
    }
    private func sidebarItem(_ p: Pane) -> some View {
        Label(p.label, systemImage: p.icon).tag(p as Pane?)
    }
}

struct PaneHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2).bold()
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            Divider().padding(.top, 10)
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
    c().padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
}

/// 稼働中インジケータ：緑の ♻ を 0.5 秒ごとに 45° カクッと回す
/// （補間なしの段階回転）。
@available(macOS 14.4, *)
struct Spinner: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let step = Int(ctx.date.timeIntervalSinceReferenceDate / 0.5) % 8
            Text("♻")
                .foregroundStyle(.green)
                .rotationEffect(.degrees(Double(step) * 45))
        }
    }
}

/// 行に流す波形ストリップ：直近 64 ブロックのピークを左へ流す（~20fps）。
/// リングが進む（音が流れる）と中身が左へ送られて波形が流れて見える。
@available(macOS 14.4, *)
struct WaveStrip: View {
    let provider: () -> (data: [Float], frac: Float)
    var body: some View {
        // .animation はディスプレイのリフレッシュに同期して毎フレーム
        // 確実に再描画する（.periodic の微小 interval は環境により
        // 間引かれ ~1Hz に落ちることがあるため使わない）。push ≈25Hz
        // の合間も frac(0..1, 実測レート補間) ぶん波形全体をサブピクセル
        // 左送りし続け、毎フレーム別の絵になり連続的に流れる。点が
        // 少ないぶんは二次曲線でスムージング。
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let _ = context.date          // 毎フレーム無効化を保証
                let (s, frac) = provider()
                guard s.count > 2 else { return }
                let n = s.count
                let midY = size.height / 2
                let maxA = size.height / 2 - 1
                // off=frac は [0,1]。両端に 1〜2 本ぶん余白を持たせ、新しい
                // 波が右端外から入り古い波が左端外へ抜ける（隙間は出ない）。
                let stepX = size.width / CGFloat(n - 3)
                let off = CGFloat(frac)
                func pt(_ i: Int, up: Bool) -> CGPoint {
                    // 線形スケールだと声の典型ピーク (~0.1) が高さ 10% に
                    // しかならず波形が潰れる。sqrt 圧縮でメーター感の
                    // 視認性を確保 (0.01→10%, 0.1→32%, 0.5→71%, 1.0→100%)。
                    let v = min(max(s[i], 0), 1)
                    let scaled = sqrt(v)
                    let a = max(0.5, CGFloat(scaled) * maxA)
                    return CGPoint(x: (CGFloat(i) - off) * stepX,
                                   y: up ? midY - a : midY + a)
                }
                let top = (0..<n).map { pt($0, up: true) }
                let bot = (0..<n).map { pt($0, up: false) }
                var shape = Path()                       // 上輪郭→下輪郭で閉領域
                shape.move(to: top[0])
                for i in 1..<n {                          // 中点経由の二次曲線
                    let m = CGPoint(x: (top[i - 1].x + top[i].x) / 2,
                                    y: (top[i - 1].y + top[i].y) / 2)
                    shape.addQuadCurve(to: m, control: top[i - 1])
                }
                shape.addLine(to: top[n - 1])
                shape.addLine(to: bot[n - 1])
                for i in stride(from: n - 1, to: 0, by: -1) {
                    let m = CGPoint(x: (bot[i].x + bot[i - 1].x) / 2,
                                    y: (bot[i].y + bot[i - 1].y) / 2)
                    shape.addQuadCurve(to: m, control: bot[i])
                }
                shape.addLine(to: bot[0])
                shape.closeSubpath()
                ctx.fill(shape, with: .color(.green.opacity(0.55)))
            }
        }
        .frame(width: 80, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(Color.black.opacity(0.06)))
        .help("流量波形（右から左へ滑らかに流れる・直近約1.2秒）")
    }
}

// MARK: - Routing（1 行 = source ‐ bus ‐ sink）

@available(macOS 14.4, *)
struct RoutingView: View {
    @ObservedObject var ctl: RouterController
    @State private var editing = RouteRow()
    @State private var isNew = false
    @State private var showEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Audio Router — Patchbay",
                       subtitle: "1 行 = source ‐ bus ‐ sink。片側だけ・同名 bus 共有で分岐(fan-out)可")

            HStack(spacing: 10) {
                Button {
                    var r = RouteRow()
                    r.bus = ctl.busNames.first ?? "bus1"
                    // ソース/シンクは初期値なし — ユーザに必ず選んでもらう。
                    r.source = nil; r.sink = nil
                    editing = r; isNew = true
                    ctl.refreshLists(); showEditor = true
                } label: { Label("ルートを追加", systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderedProminent)

                Button { ctl.refreshLists() } label: {
                    Label("一覧更新", systemImage: "arrow.clockwise")
                }.buttonStyle(.bordered)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 18)

            if ctl.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.largeTitle).foregroundStyle(.tertiary)
                    Text("ルートがありません").foregroundStyle(.secondary)
                    Text("「ルートを追加」で source ‐ bus ‐ sink を1行で定義。"
                         + "同じ bus 名を複数行で使うと分岐します。")
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(ctl.rows) { r in
                        row(r)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 5, leading: 24,
                                                      bottom: 5, trailing: 24))
                    }
                    .onMove { from, to in ctl.moveRows(from: from, to: to) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(isPresented: $showEditor) {
            RouteEditorView(ctl: ctl, original: editing, isNew: isNew) { saved in
                if isNew { ctl.addRow(saved) } else { ctl.updateRow(saved) }
            }
        }
    }

    // 設定された app/mic が現在の一覧に見つからない（=使えない）か。
    private func sourceMissing(_ r: RouteRow) -> Bool {
        switch r.source {
        case .appTap:
            return r.appBundleID.isEmpty
                || !ctl.processes.contains { $0.bundleID == r.appBundleID }
        case .mic:
            return r.micUID.isEmpty
                ? ctl.inputs.isEmpty
                : !ctl.inputs.contains { $0.uid == r.micUID }
        case .babigoeOut, .wirelessMic, .none:
            return false
        }
    }

    // IN/OUT のインジケータ: 流れていれば回転♻、稼働中だが無信号は静止♻。
    @ViewBuilder
    private func indicator(active: Bool, flowing: Bool) -> some View {
        if flowing {
            Spinner()                                   // 信号あり→回転
        } else if active {
            Text("♻").foregroundStyle(.secondary)       // 稼働中だが無信号→静止
        }
    }

    private func row(_ r: RouteRow) -> some View {
        let on = ctl.active(r.id)
        let missing = sourceMissing(r)
        let flow = ctl.flowByRow[r.id] ?? RouterController.RowFlow()
        return card {
            HStack(spacing: 6) {
                Image(systemName: r.icon).foregroundStyle(.secondary)
                if let s = r.displaySource {
                    Text(s).font(.body).bold()
                    if missing {
                        Text("🚫").help("デバイス/アプリが見つかりません")
                    } else {
                        indicator(active: on, flowing: flow.inFlow)
                    }
                }
                Text("‐ \(r.busLabel)").font(.body).foregroundStyle(.secondary)
                if let k = r.displaySink {
                    Text("‐").font(.body).foregroundStyle(.secondary)
                    Text(k).font(.body).bold()
                    if flow.sinkDown {
                        Text("🚫").help("受信側(4ksplitter等)が閉じています")
                    } else {
                        indicator(active: on, flowing: flow.outFlow)
                    }
                }
                Spacer()
                if r.sink == .speaker {
                    // インラインフェーダー: 行ごとに live 音量調整。slider 動きは
                    // ライブで SpeakerOutEdge へ反映され、同時に routes.json 永続化。
                    Image(systemName: r.speakerGain == 0 ? "speaker.slash" :
                                       r.speakerGain < 0.34 ? "speaker.wave.1" :
                                       r.speakerGain < 0.67 ? "speaker.wave.2"
                                                            : "speaker.wave.3")
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(r.speakerGain) },
                        set: { ctl.setSpeakerGain(r.id, Float($0)) }),
                           in: 0...1)
                        .frame(width: 90)
                        .help("出力フェーダー (0 = ミュート、100% = ユニティ)")
                    Text("\(Int((r.speakerGain * 100).rounded()))%")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
                if on && r.sink == .recorder { WaveStrip { ctl.wavePhased(r.id) } }
                Toggle("", isOn: Binding(
                    get: { ctl.active(r.id) },
                    set: { ctl.setEnabled(r.id, $0) }))
                    .toggleStyle(.switch).labelsHidden().tint(.blue)
                Button {
                    editing = r; isNew = false; ctl.refreshLists(); showEditor = true
                } label: { Label("編集", systemImage: "pencil") }
                    .buttonStyle(.bordered).disabled(on)
                Button(role: .destructive) { ctl.deleteRow(r.id) } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.bordered).tint(.red)
            }
        }
    }
}

// MARK: - ルート編集（source 任意 / bus / sink 任意）

@available(macOS 14.4, *)
struct RouteEditorView: View {
    @ObservedObject var ctl: RouterController
    let original: RouteRow
    let isNew: Bool
    let onSave: (RouteRow) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var src: SourceKind? = nil
    @State private var snk: SinkKind? = nil
    @State private var busName = "bus1"
    @State private var appBundleID = ""
    @State private var appName = ""
    @State private var muteSource = false
    @State private var micUID = ""
    @State private var micName = ""
    @State private var splitterSlot: Int = 1   // 1..4。snk==.splitter のときだけ意味を持つ
    @State private var obsKind: ObsKind = .mic // snk==.obs のときの枠種別（mic/video）
    @State private var obsSlot: Int = 1        // 1..maxSlot。snk==.obs のときだけ意味を持つ
    @State private var babigoeSlot: Int = 1    // 1..4。snk==.babigoeIn または src==.babigoeOut のときだけ
    @State private var wirelessSlot: Int = 1   // 1..4。src==.wirelessMic のときだけ意味を持つ
    // snk==.netSpeaker のときの宛先 (0=全端末ブロードキャスト, 1..4=特定 slot)。
    @State private var wirelessTargetSlot: Int = 0
    @State private var wirelessTargetName: String = ""
    @State private var speakerUID: String = "" // snk==.speaker のときの出力デバイス UID
    @State private var speakerName: String = ""
    @State private var speakerGain: Float = 1.0  // 0..1

    private var canSave: Bool {
        guard src != nil || snk != nil else { return false }
        if src == .appTap { return !appBundleID.isEmpty }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "ルートを追加" : "ルートを編集").font(.title3).bold()

            GroupBox("IN — source（バスへ書く側・任意）") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("ソース", selection: $src) {
                        Text("なし").tag(SourceKind?.none)
                        Text("アプリ").tag(SourceKind?.some(.appTap))
                        Text("マイク(オーディオ入力デバイス)").tag(SourceKind?.some(.mic))
                        Text("babigoe(出力)").tag(SourceKind?.some(.babigoeOut))
                        Text("ワイヤレスマイク(Android)").tag(SourceKind?.some(.wirelessMic))
                    }
                    if src == .appTap {
                        Picker("アプリ", selection: $appBundleID) {
                            Text("選択してください").tag("")
                            if !appBundleID.isEmpty,
                               !ctl.processes.contains(where: { $0.bundleID == appBundleID }) {
                                Text("\(appName)（未起動）").tag(appBundleID)
                            }
                            ForEach(ctl.processes.filter { !$0.bundleID.isEmpty }) { p in
                                Text(p.name).tag(p.bundleID)
                            }
                        }
                        .onChange(of: appBundleID) { _, v in
                            if let p = ctl.processes.first(where: { $0.bundleID == v }) {
                                appName = p.name
                            }
                        }
                        Toggle("元アプリをミュート（タップ中スピーカーに出さない）",
                               isOn: $muteSource)
                    } else if src == .mic {
                        Picker("マイク", selection: $micUID) {
                            Text("既定の入力").tag("")
                            if !micUID.isEmpty,
                               !ctl.inputs.contains(where: { $0.uid == micUID }) {
                                Text("\(micName)（未接続）").tag(micUID)
                            }
                            ForEach(ctl.inputs) { d in Text(d.name).tag(d.uid) }
                        }
                        .onChange(of: micUID) { _, v in
                            if let d = ctl.inputs.first(where: { $0.uid == v }) {
                                micName = d.name
                            }
                        }
                    } else if src == .babigoeOut {
                        Text("babigoe が書く処理済み音声を bus へ。"
                             + "ch1 = `/babigoe.out3` (元バ美声)、"
                             + "ch2..4 = `/babigoe.out3.<n>` (VST デッキ等)。")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("babigoe チャンネル", selection: $babigoeSlot) {
                            ForEach(1...4, id: \.self) {
                                Text($0 == 1 ? "ch1 (元バ美声)" : "ch\($0)").tag($0)
                            }
                        }
                    } else if src == .wirelessMic {
                        Text("Bonjour `_4noha-audio._udp` で Android アプリが "
                             + "接続→このスロットへ送ったマイク音を bus へ。"
                             + "複数 Android を同時接続するなら別 slot へ。"
                             + "（Android が HELLO で繋ぐとこの行は自動追加もされる）")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("slot", selection: $wirelessSlot) {
                            ForEach(1...4, id: \.self) {
                                Text("slot \($0)").tag($0)
                            }
                        }
                    }
                    Button { ctl.refreshLists() } label: {
                        Label("一覧更新", systemImage: "arrow.clockwise")
                    }
                }.padding(6)
            }

            GroupBox("BUS（同名の行どうしが繋がる／複数行で分岐）") {
                HStack {
                    Text("bus 名")
                    TextField("bus1", text: $busName).frame(width: 160)
                    if !ctl.busNames.isEmpty {
                        Menu("既存") {
                            ForEach(ctl.busNames, id: \.self) { n in
                                Button(n) { busName = n }
                            }
                        }.fixedSize()
                    }
                }.padding(6)
            }

            GroupBox("OUT — sink（バスから読む側・任意）") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("シンク", selection: $snk) {
                        Text("なし").tag(SinkKind?.none)
                        Text("4ksplitter").tag(SinkKind?.some(.splitter))
                        Text("babigoe(入力)").tag(SinkKind?.some(.babigoeIn))
                        Text("OBS").tag(SinkKind?.some(.obs))
                        Text("ネットスピーカー(Android)").tag(SinkKind?.some(.netSpeaker))
                        Text("スピーカー(オーディオ出力デバイス)").tag(SinkKind?.some(.speaker))
                        Text("録音(WAV ファイル)").tag(SinkKind?.some(.recorder))
                    }
                    // 4ksplitter のみモデル枠を選択（複数モデル独立リップシンクへの分岐）。
                    // 枠1は従来の shm 名のままで既存ルートと完全後方互換。
                    if snk == .splitter {
                        Picker("モデル枠", selection: $splitterSlot) {
                            ForEach(1...4, id: \.self) { Text("モデル \($0)").tag($0) }
                        }
                    }
                    // babigoeIn 行きはチャンネル番号を選択（同 shm を複数アプリで取り合わない用）。
                    // ch1 = `/babigoe.in3` (元バ美声向け)、ch2..4 = VST デッキ等。
                    if snk == .babigoeIn {
                        Picker("babigoe チャンネル", selection: $babigoeSlot) {
                            ForEach(1...4, id: \.self) {
                                Text($0 == 1 ? "ch1 (元バ美声)" : "ch\($0)").tag($0)
                            }
                        }
                    }
                    if snk == .netSpeaker {
                        Text("接続中の端末へ Opus(AUDIO mode, 192kbps) で送信。"
                             + "任意 bus を流せるので音楽・効果音含むミックスを "
                             + "端末で聴ける。「全端末」でブロードキャスト、"
                             + "個別端末選択で当該端末のみへ。")
                            .font(.caption).foregroundStyle(.secondary)
                        // 接続中端末: source==wirelessMic の行で deviceName 付き
                        // のものから抽出 (既設の wireless 行が一覧の代わり)。
                        let peers: [(slot: Int, name: String)] = ctl.rows
                            .compactMap {
                                guard $0.source == .wirelessMic,
                                      !$0.wirelessDeviceName.isEmpty else { return nil }
                                return (slot: $0.wirelessSlot,
                                        name: $0.wirelessDeviceName)
                            }
                            .sorted { $0.slot < $1.slot }
                        Picker("宛先端末", selection: $wirelessTargetSlot) {
                            Text("全端末（ブロードキャスト）").tag(0)
                            // 過去保存の宛先 slot が現行 peers にいなくても表示維持。
                            if wirelessTargetSlot != 0,
                               !peers.contains(where: { $0.slot == wirelessTargetSlot }) {
                                let n = wirelessTargetName.isEmpty
                                    ? "slot\(wirelessTargetSlot)"
                                    : wirelessTargetName
                                Text("\(n)（未接続）").tag(wirelessTargetSlot)
                            }
                            ForEach(peers, id: \.slot) { p in
                                Text("\(p.name) (slot \(p.slot))").tag(p.slot)
                            }
                        }
                        .onChange(of: wirelessTargetSlot) { _, v in
                            if v == 0 { wirelessTargetName = "" }
                            else if let p = peers.first(where: { $0.slot == v }) {
                                wirelessTargetName = p.name
                            }
                        }
                    }
                    if snk == .speaker {
                        Picker("出力デバイス", selection: $speakerUID) {
                            Text("既定の出力").tag("")
                            if !speakerUID.isEmpty,
                               !ctl.outputs.contains(where: { $0.uid == speakerUID }) {
                                Text("\(speakerName)（未接続）").tag(speakerUID)
                            }
                            ForEach(ctl.outputs) { d in Text(d.name).tag(d.uid) }
                        }
                        .onChange(of: speakerUID) { _, v in
                            if let d = ctl.outputs.first(where: { $0.uid == v }) {
                                speakerName = d.name
                            } else if v.isEmpty {
                                speakerName = ""
                            }
                        }
                        Text("選んだ出力デバイスで bus の音を再生します（スピーカ/"
                             + "ヘッドホン/USB DAC 等）。既定出力を選ぶと OS の出力切替に追随。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("音量")
                            Slider(value: $speakerGain, in: 0...1)
                            Text("\(Int((speakerGain * 100).rounded()))%")
                                .monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    // OBS は枠種別(mic/video)＋ 枠番号(mic:1..4 / video:1..2)。
                    // 種別を変えると最大枠数が変わるので slot を切り詰める。
                    if snk == .obs {
                        Picker("枠種別", selection: $obsKind) {
                            Text("マイク (4 枠)").tag(ObsKind.mic)
                            Text("映像音 (2 枠)").tag(ObsKind.video)
                        }
                        .onChange(of: obsKind) { _, k in
                            if obsSlot > k.maxSlot { obsSlot = k.maxSlot }
                        }
                        Picker("枠番号", selection: $obsSlot) {
                            ForEach(1...obsKind.maxSlot, id: \.self) {
                                Text("\(obsKind.label) \($0)").tag($0)
                            }
                        }
                    }
                }.padding(6)
            }

            Text("source も sink も無し は不可。片側だけなら部分ルート"
                 + "（例: VLC ‐ bus2 / bus2 ‐ 4ksplitter）。")
                .font(.caption2).foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "追加" : "保存") {
                    var r = original
                    r.source = src; r.sink = snk
                    r.bus = busName.isEmpty ? "bus1" : busName
                    r.appBundleID = appBundleID
                    r.appName = appName.isEmpty ? appBundleID : appName
                    r.muteSource = muteSource
                    r.micUID = micUID
                    r.micName = micName
                    r.splitterSlot = splitterSlot
                    r.obsKind = obsKind
                    r.obsSlot = obsSlot
                    r.babigoeSlot = babigoeSlot
                    r.wirelessSlot = wirelessSlot
                    r.wirelessTargetSlot = wirelessTargetSlot
                    r.wirelessTargetName = wirelessTargetName
                    r.speakerUID = speakerUID
                    r.speakerName = speakerName
                    r.speakerGain = speakerGain
                    onSave(r); dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(22).frame(width: 500)
        .onAppear {
            ctl.refreshLists()
            src = original.source; snk = original.sink
            busName = original.bus
            appBundleID = original.appBundleID
            appName = original.appName
            muteSource = original.muteSource
            micUID = original.micUID
            micName = original.micName
            splitterSlot = original.splitterSlot
            obsKind = original.obsKind
            obsSlot = original.obsSlot
            babigoeSlot = original.babigoeSlot
            wirelessSlot = original.wirelessSlot
            wirelessTargetSlot = original.wirelessTargetSlot
            wirelessTargetName = original.wirelessTargetName
            speakerUID = original.speakerUID
            speakerGain = original.speakerGain
            speakerName = original.speakerName
        }
    }
}

// MARK: - Activity

@available(macOS 14.4, *)
struct ActivityView: View {
    @ObservedObject var ctl: RouterController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Activity", subtitle: "各ルートの稼働と流量（毎秒更新）")
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(ctl.rows) { r in
                        card {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(ctl.active(r.id) ? Color.green : Color.gray)
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.oneLine).bold()
                                    Text(ctl.statusByRow[r.id]
                                         ?? (ctl.active(r.id) ? "稼働中" : "停止中"))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                    }
                    if ctl.rows.isEmpty {
                        Text("ルートがありません").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }.padding(24)
            }
        }
    }
}

// MARK: - Maintenance

@available(macOS 14.4, *)
struct MaintenanceView: View {
    @ObservedObject var ctl: RouterController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Maintenance", subtitle: "一覧更新・終了")
            VStack(alignment: .leading, spacing: 14) {
                Button { ctl.refreshLists() } label: {
                    Label("プロセス／デバイス一覧を更新", systemImage: "arrow.clockwise")
                }.buttonStyle(.bordered)
                Button(role: .destructive) {
                    ctl.stopAll(); NSApplication.shared.terminate(nil)
                } label: {
                    Label("全エッジ停止して終了", systemImage: "power")
                }.buttonStyle(.bordered).tint(.red)
            }.padding(24)
            Spacer()
        }
    }
}
