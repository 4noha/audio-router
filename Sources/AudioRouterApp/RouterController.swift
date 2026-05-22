import Foundation
import SwiftUI
import CoreAudio
import Darwin
import AudioRouterCore

/// 名前付き内部バスのパッチベイ。1 行 = `source ‐ bus ‐ sink`（source/sink
/// は任意）。行ごとに IN/OUT エンジンを起動停止し、毎秒 per-row 診断。
/// 同名 bus を複数行で共有して分岐(fan-out)。routes.json で永続化。
@available(macOS 14.4, *)
@MainActor
final class RouterController: ObservableObject {
    @Published var rows: [RouteRow] = []
    @Published var processes: [AudioProcess] = []
    @Published var inputs: [InputDevice] = []
    @Published var statusByRow: [UUID: String] = [:]
    /// 行ごとの流量（♻ 回転判定）。in/out 個別。
    @Published var flowByRow: [UUID: RowFlow] = [:]

    /// inFlow/outFlow=♻ 回転、sinkDown=受信側不在で sink に 🚫。
    struct RowFlow: Equatable {
        var inFlow = false; var outFlow = false; var sinkDown = false
    }
    private struct RowEng { var inE: EdgeEngine?; var outE: EdgeEngine? }

    private var engines: [UUID: RowEng] = [:]         // 行ごと IN/OUT
    private var startedAt: [UUID: Date] = [:]         // 受信側 attach 猶予用
    private var buses: [String: AudioBus] = [:]
    // ネットマイク/ネットスピーカー用 UDP/Bonjour ハブ。最初に必要になった
    // 行がアクティベートされた時点で lazy 起動して以降同一を共有。
    private var netServer: NetAudioServer?
    private var netServerError: String?
    // 診断/ status.json は MainActor 非依存の StatusReporter が担う
    // （bare binary / ヘッドレス自動化でも Swift Concurrency main executor
    // 枯渇の影響を受けず、pump と同じく確実に動く）。
    private var reporter: StatusReporter?
    private let storeURL: URL
    private let statusURL: URL          // 機械可読な稼働状況（自動検証用）
    // routes.json ホットリロード判定用（外部編集の検出は StatusReporter の
    // 1 秒 tick が mtime ポーリング＝atomic/in-place/エディタ何でも検出）。
    private var lastRoutesMTime: Date?
    // App Nap 無効化トークン。非フロントやヘッドレス自動化でも
    // pump/診断 DispatchSource を止めない（＝背面でもルーティング継続）。
    private var activityToken: NSObjectProtocol?

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioRouter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("routes.json")
        statusURL = base.appendingPathComponent("status.json")

        // App Nap / 自動タイマ合体を抑止（背面・bare 実行でも継続稼働）。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "AudioRouter realtime audio routing")

        let rep = StatusReporter(url: statusURL, routesURL: storeURL)
        reporter = rep

        refreshLists()
        load()
        for r in rows where r.enabled {
            // 録音は起動時に自動開始しない（不意の録音＝プライバシ/
            // ディスク浪費を防ぐ）。明示的にトグル ON した時だけ開始。
            if r.sink == .recorder {
                if let i = rows.firstIndex(where: { $0.id == r.id }) {
                    rows[i].enabled = false
                }
                continue
            }
            if !activate(r.id),
               let i = rows.firstIndex(where: { $0.id == r.id }) {
                rows[i].enabled = false
            }
        }
        save()
        lastRoutesMTime = routesMTime()

        // NetAudioServer は **常時起動**（行に依存しない）。Bonjour 公開を
        // 起動時から開始し、Android が HELLO を打ったタイミングで auto-add
        // できるようにするため。失敗時は netServerError に残るだけで先へ進む。
        _ = ensureNetServer()

        // UI(@Published)は best-effort で GCD main 経由更新（headless では
        // 単に未更新になるだけで status.json には影響しない）。
        rep.onSample = { [weak self] flows, stats in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (k, v) in flows where self.flowByRow[k] != v {
                        self.flowByRow[k] = v
                    }
                    for (k, v) in stats { self.statusByRow[k] = v }
                }
            }
        }
        // 外部が routes.json を書換えたら（cp/エディタ/atomic 問わず）
        // reporter の 1 秒 tick が検出→ GCD main + assumeIsolated で
        // reconcile（Task{@MainActor} は headless で枯渇するため不可）。
        rep.onRoutesChanged = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reloadIfChanged() }
            }
        }
        rebuildRefs()
        rep.start()
    }

    /// engines 変化時に StatusReporter へスレッドセーフな行スナップショットを渡す。
    private func rebuildRefs() {
        let refs: [StatusReporter.Ref] = rows.compactMap { r in
            guard let e = engines[r.id] else { return nil }
            return StatusReporter.Ref(
                id: r.id, oneLine: r.oneLine, bus: r.bus,
                source: r.source?.rawValue ?? "", sink: r.sink?.rawValue ?? "",
                enabled: r.enabled, inE: e.inE, outE: e.outE,
                startedAt: startedAt[r.id] ?? Date())
        }
        // 停止中も含めた全行メタ（status.json に出す）。
        let all: [StatusReporter.RowMeta] = rows.map {
            StatusReporter.RowMeta(
                id: $0.id, oneLine: $0.oneLine, bus: $0.bus,
                source: $0.source?.rawValue ?? "",
                sink: $0.sink?.rawValue ?? "", enabled: $0.enabled,
                active: active($0.id))
        }
        reporter?.update(refs: refs, allRows: all, buses: busNames)
    }

    private func routesMTime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: storeURL.path))?[.modificationDate] as? Date
    }

    func refreshLists() {
        processes = ProcessEnumerator.list(onlyOutput: true)
        inputs = AudioDeviceEnumerator.inputs()
    }

    func active(_ id: UUID) -> Bool {
        guard let e = engines[id] else { return false }
        return e.inE != nil || e.outE != nil
    }

    /// 行に流す波形（OUT 優先、無ければ IN）。停止中は空。
    func waveform(_ id: UUID) -> [Float] {
        guard let e = engines[id] else { return [] }
        return (e.outE ?? e.inE)?.waveform ?? []
    }
    /// 波形＋直近 push からの小数位相（描画の滑らか送り用）。
    func wavePhased(_ id: UUID) -> (data: [Float], frac: Float) {
        guard let e = engines[id], let w = e.outE ?? e.inE else { return ([], 0) }
        return (w.waveform, w.waveFrac)
    }

    var busNames: [String] { Array(Set(rows.map { $0.bus })).sorted() }

    // MARK: CRUD

    func addRow(_ r: RouteRow) {
        var x = r; x.enabled = false
        rows.append(x); save(); rebuildRefs()
    }
    func updateRow(_ r: RouteRow) {
        guard let i = rows.firstIndex(where: { $0.id == r.id }) else { return }
        let wasActive = active(r.id)
        deactivate(r.id)
        rows[i] = r; rows[i].enabled = false
        if wasActive { setEnabled(r.id, true) }
        save(); rebuildRefs()
    }
    func deleteRow(_ id: UUID) {
        deactivate(id); rows.removeAll { $0.id == id }
        statusByRow[id] = nil; save(); rebuildRefs()
    }

    // 並び替え（List.onMove の (IndexSet, Int) シグネチャに合わせる）。
    // 行の有効/状態には触れない（save() のみ）— rebuildRefs は順序非依存。
    func moveRows(from offsets: IndexSet, to destination: Int) {
        rows.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if on {
            rows[i].enabled = activate(id)
        } else {
            deactivate(id); rows[i].enabled = false
            statusByRow[id] = "停止中"
        }
        save(); rebuildRefs()
    }

    func stopAll() {
        for (_, e) in engines { e.inE?.stop(); e.outE?.stop() }
        engines.removeAll()
        flowByRow.removeAll(); startedAt.removeAll()
        rebuildRefs()
    }

    private func bus(_ name: String) -> AudioBus {
        if let b = buses[name] { return b }
        let b = AudioBus(); buses[name] = b; return b
    }

    /// NetAudioServer を必要時に 1 度だけ起動。Bonjour で
    /// `_4noha-audio._udp` を公開し UDP リッスン開始。失敗時は
    /// netServerError にメッセージを残し nil。
    /// onSlotPaired コールバックは「Android が HELLO を打って繋がった」
    /// シグナルなので、対応する行が無ければ自動で 1 つ追加して enable する。
    private func ensureNetServer() -> NetAudioServer? {
        if let s = netServer { return s }
        let s = NetAudioServer(slotCount: 4)
        s.onSlotPaired = { [weak self] slot, _ in
            // listenerQ から呼ばれる。MainActor へ hop。
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleWirelessMicPaired(slot: slot) }
            }
        }
        do {
            try s.start()
            netServer = s
            netServerError = nil
            return s
        } catch {
            netServerError = error.localizedDescription
            return nil
        }
    }

    /// 「Android が slot N に HELLO した」ときに呼ばれる。すでに同 slot の
    /// ワイヤレスマイク行があれば何もしない（既存行が稼働中ならそのまま、
    /// 停止中なら enable）。無ければ自動で 1 行追加して enable する。
    /// 追加する行は source=wirelessMic、sink=nil、bus="wifimic\(slot)"。
    /// 後段は user が手動で繋ぐ前提（splitter / babigoeIn / recorder 等）。
    private func handleWirelessMicPaired(slot: Int) {
        if let i = rows.firstIndex(where: {
            $0.source == .wirelessMic && $0.wirelessSlot == slot
        }) {
            if !rows[i].enabled { setEnabled(rows[i].id, true) }
            return
        }
        var r = RouteRow()
        r.bus = "wifimic\(slot)"
        r.source = .wirelessMic
        r.wirelessSlot = slot
        r.sink = nil
        r.enabled = false
        rows.append(r); save(); rebuildRefs()
        setEnabled(r.id, true)
    }

    /// 診断 UI 用: ネットサーバが起動しているか、起動エラー、待受ポート。
    var netServerBoundPort: UInt16 { netServer?.boundPort ?? 0 }
    var netServerErrorMessage: String? { netServerError }
    func netServerSlotDiag(slot: Int) -> NetAudioServer.SlotDiag? {
        return netServer?.diag(slot: slot)
    }

    // MARK: activate（source なら IN、sink なら OUT を同一 bus で）

    @discardableResult
    private func activate(_ id: UUID) -> Bool {
        guard let r = rows.first(where: { $0.id == id }) else { return false }
        if active(id) { return true }
        guard r.source != nil || r.sink != nil else {
            statusByRow[id] = "source か sink を指定してください"; return false
        }
        refreshLists()
        let b = bus(r.bus)
        var inE: EdgeEngine?
        var outE: EdgeEngine?
        do {
            if let src = r.source {
                switch src {
                case .appTap:
                    guard !r.appBundleID.isEmpty,
                          let p = processes.first(where: { $0.bundleID == r.appBundleID })
                    else { statusByRow[id] = "アプリ「\(r.appName)」が音声出力していません"; return false }
                    guard let po = ProcessEnumerator.processObject(for: p.pid)
                    else { statusByRow[id] = "プロセス変換に失敗"; return false }
                    inE = try TapInEdge(processObject: po,
                                        muteSource: r.muteSource, bus: b)
                case .mic:
                    let dev = r.micUID.isEmpty
                        ? AudioDeviceEnumerator.defaultInput()?.id
                        : inputs.first(where: { $0.uid == r.micUID })?.id
                    guard let dev else { statusByRow[id] = "マイクが見つかりません"; return false }
                    inE = try MicInEdge(deviceID: dev,
                                        useDefault: r.micUID.isEmpty, bus: b)
                case .babigoeOut:
                    let s = ShmInEdge(shmName: ShmReader.babigoeOutName(slot: r.babigoeSlot), bus: b)
                    s.start(); inE = s
                case .wirelessMic:
                    guard let server = ensureNetServer() else {
                        statusByRow[id] = "ワイヤレスマイク受信開始失敗"
                            + (netServerError.map { ": \($0)" } ?? "")
                        return false
                    }
                    let s = WirelessMicInEdge(server: server, slot: r.wirelessSlot, bus: b)
                    s.start(); inE = s
                }
            }
            switch r.sink {
            case .splitter:
                let s = ShmOutEdge(shmName: ShmSender.splitterName(slot: r.splitterSlot), bus: b)
                s.start(); outE = s
            case .babigoeIn:
                let s = ShmOutEdge(shmName: ShmSender.babigoeInName(slot: r.babigoeSlot), bus: b)
                s.start(); outE = s
            case .obs:
                let s = ShmOutEdge(
                    shmName: ShmSender.obsName(kind: r.obsKind.rawValue, slot: r.obsSlot),
                    bus: b)
                s.start(); outE = s
            case .recorder:
                let s = RecorderOutEdge(bus: b)
                s.start(); outE = s
            case .netSpeaker:
                guard let server = ensureNetServer() else {
                    inE?.stop()
                    statusByRow[id] = "ネットスピーカー開始失敗"
                        + (netServerError.map { ": \($0)" } ?? "")
                    return false
                }
                let s = try NetSpeakerOutEdge(server: server, bus: b)
                s.start(); outE = s
            case .none:
                break
            }
        } catch {
            inE?.stop(); outE?.stop()
            statusByRow[id] = "開始失敗: \(error.localizedDescription)"
            return false
        }
        engines[id] = RowEng(inE: inE, outE: outE)
        startedAt[id] = Date()
        flowByRow[id] = RowFlow()
        statusByRow[id] = "稼働中"
        rebuildRefs()
        return true
    }

    private func deactivate(_ id: UUID) {
        if let e = engines[id] { e.inE?.stop(); e.outE?.stop() }
        engines[id] = nil
        flowByRow[id] = nil
        startedAt[id] = nil
        rebuildRefs()
    }

    // MARK: 永続化

    private func load() {
        guard let d = try? Data(contentsOf: storeURL),
              let v = try? JSONDecoder().decode([RouteRow].self, from: d)
        else { return }
        rows = v
    }
    private func save() {
        guard let d = try? JSONEncoder().encode(rows) else { return }
        try? d.write(to: storeURL, options: .atomic)
        lastRoutesMTime = routesMTime()   // 自分の書込で reconcile しない
    }

    // MARK: routes.json ホットリロード（外部編集→経路を自動反映）

    /// reporter の mtime ポーリングから GCD main 経由で呼ばれる。
    private func reloadIfChanged() {
        let m = routesMTime()
        if let m, let last = lastRoutesMTime, m == last { return }
        guard let d = try? Data(contentsOf: storeURL),
              let v = try? JSONDecoder().decode([RouteRow].self, from: d)
        else { return }
        lastRoutesMTime = m
        if v == rows { return }                 // 内容差なし（自分の保存等）
        // 差分適用: 全停止→新ルートへ置換→enabled を再アクティベート。
        stopAll()
        rows = v
        for r in rows where r.enabled {
            if !activate(r.id),
               let i = rows.firstIndex(where: { $0.id == r.id }) {
                rows[i].enabled = false
            }
        }
        save()
        lastRoutesMTime = routesMTime()
        rebuildRefs()
    }
}

// MARK: - StatusReporter（MainActor 非依存の診断／status.json 出力）

/// engines のスレッドセーフなスナップショット(参照)を 1 秒毎に走査し、
/// 流量/診断を計算して status.json を atomic 書出する。bare binary・
/// ヘッドレスでも確実に動くよう **自前 DispatchSource キューで完結**し、
/// UI(@Published)更新だけ best-effort で GCD main へ委譲する。
/// EdgeEngine の frames/level/diag/consumerAlive は内部ロック済で
/// 任意スレッドから安全に呼べる。
@available(macOS 14.4, *)
final class StatusReporter: @unchecked Sendable {
    struct Ref {
        let id: UUID; let oneLine: String; let bus: String
        let source: String; let sink: String; let enabled: Bool
        let inE: EdgeEngine?; let outE: EdgeEngine?; let startedAt: Date
    }
    struct RowMeta {
        let id: UUID; let oneLine: String; let bus: String
        let source: String; let sink: String; let enabled: Bool
        let active: Bool
    }

    private let url: URL
    private let routesURL: URL
    private let lock = NSLock()
    private var refs: [Ref] = []
    private var allRows: [RowMeta] = []
    private var buses: [String] = []
    private var prev: [UUID: (Int, Int)] = [:]
    private var sinkDownCache: [UUID: Bool] = [:]
    private var tick = 0
    private var timer: DispatchSourceTimer?
    private var lastRoutesM: Date?
    /// UI 反映コールバック（best-effort, GCD main で呼ばれる前提）。
    var onSample: (([UUID: RouterController.RowFlow], [UUID: String]) -> Void)?
    /// routes.json の mtime 変化検出時に呼ぶ（reconcile を依頼）。
    var onRoutesChanged: (() -> Void)?

    init(url: URL, routesURL: URL) { self.url = url; self.routesURL = routesURL }

    private func routesMTime() -> Date? {
        (try? FileManager.default.attributesOfItem(
            atPath: routesURL.path))?[.modificationDate] as? Date
    }

    func update(refs: [Ref], allRows: [RowMeta], buses: [String]) {
        lock.lock()
        self.refs = refs; self.allRows = allRows; self.buses = buses
        lock.unlock()
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "audio-router.status"))
        t.schedule(deadline: .now() + 1.0, repeating: 1.0,
                   leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
        sample()                                  // 起動直後に 1 回
    }
    func stop() { timer?.cancel(); timer = nil }

    private func sample() {
        // routes.json mtime ポーリング（atomic/in-place/エディタ問わず検出）。
        let rm = routesMTime()
        if let rm {
            if let last = lastRoutesM {
                if rm != last { lastRoutesM = rm; onRoutesChanged?() }
            } else { lastRoutesM = rm }
        }

        lock.lock()
        let rs = refs, all = allRows, bs = buses
        lock.unlock()

        tick &+= 1
        let checkPid = tick % 5 == 0
        let lvlEPS: Float = 0.003
        var flows: [UUID: RouterController.RowFlow] = [:]
        var stats: [UUID: String] = [:]

        for r in rs {
            let ci = r.inE?.frames ?? 0
            let co = r.outE?.frames ?? 0
            let p = prev[r.id] ?? (0, 0)
            let inFlow = r.inE != nil && ci > p.0
                && (r.inE?.level ?? 0) > lvlEPS
            let outFlow = r.outE != nil && co > p.1
                && (r.outE?.level ?? 0) > lvlEPS
            prev[r.id] = (ci, co)
            var sd = sinkDownCache[r.id] ?? false
            if checkPid, let so = r.outE as? ShmOutEdge {
                let age = Date().timeIntervalSince(r.startedAt)
                sd = age >= 6 && !so.consumerAlive
            }
            sinkDownCache[r.id] = sd
            flows[r.id] = RouterController.RowFlow(
                inFlow: inFlow, outFlow: outFlow, sinkDown: sd)
            let d = [r.inE?.diag, r.outE?.diag]
                .compactMap { $0 }.joined(separator: " / ")
            stats[r.id] = "稼働中  \(r.oneLine)  \(d)"
        }

        var arr: [[String: Any]] = []
        for m in all {
            let f = flows[m.id]
            let pf = prev[m.id] ?? (0, 0)
            arr.append([
                "id": m.id.uuidString, "bus": m.bus,
                "source": m.source, "sink": m.sink,
                "oneLine": m.oneLine, "enabled": m.enabled,
                "active": m.active,
                "inFlow": f?.inFlow ?? false,
                "outFlow": f?.outFlow ?? false,
                "sinkDown": f?.sinkDown ?? false,
                "inFrames": pf.0, "outFrames": pf.1,
                "status": stats[m.id] ?? (m.active ? "稼働中" : "停止中")
            ])
        }
        let doc: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "activeCount": rs.count, "buses": bs, "rows": arr
        ]
        if let d = try? JSONSerialization.data(
            withJSONObject: doc, options: [.sortedKeys]) {
            try? d.write(to: url, options: .atomic)
        }
        if let cb = onSample { cb(flows, stats) }
    }
}
