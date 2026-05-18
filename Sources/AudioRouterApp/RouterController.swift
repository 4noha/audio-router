import Foundation
import SwiftUI
import CoreAudio
import AudioRouterCore

/// 名前付き内部バスのパッチベイ。エッジ(IN: source→bus / OUT: bus→sink)を
/// 個別トグルで起動停止し、毎秒 per-edge 診断を出す。edges.json で永続化。
@available(macOS 14.4, *)
@MainActor
final class RouterController: ObservableObject {
    @Published var edges: [RouteEdge] = []
    @Published var processes: [AudioProcess] = []
    @Published var inputs: [InputDevice] = []
    @Published var statusByEdge: [UUID: String] = [:]

    private var engines: [UUID: EdgeEngine] = [:]
    private var buses: [String: AudioBus] = [:]
    private var statusTimer: Timer?
    private let storeURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioRouter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("edges.json")

        refreshLists()
        load()
        for e in edges where e.enabled {
            if !activate(e.id),
               let i = edges.firstIndex(where: { $0.id == e.id }) {
                edges[i].enabled = false
            }
        }
        save()
    }

    func refreshLists() {
        processes = ProcessEnumerator.list(onlyOutput: true)
        inputs = AudioDeviceEnumerator.inputs()
    }

    func active(_ id: UUID) -> Bool { engines[id] != nil }

    var busNames: [String] {
        Array(Set(edges.map { $0.busName })).sorted()
    }

    // MARK: CRUD

    func addEdge(_ e: RouteEdge) {
        var x = e; x.enabled = false
        edges.append(x); save()
    }
    func updateEdge(_ e: RouteEdge) {
        guard let i = edges.firstIndex(where: { $0.id == e.id }) else { return }
        let wasActive = active(e.id)
        deactivate(e.id)
        edges[i] = e; edges[i].enabled = false
        if wasActive { setEnabled(e.id, true) }
        save()
    }
    func deleteEdge(_ id: UUID) {
        deactivate(id); edges.removeAll { $0.id == id }
        statusByEdge[id] = nil; save()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = edges.firstIndex(where: { $0.id == id }) else { return }
        if on {
            edges[i].enabled = activate(id)
        } else {
            deactivate(id); edges[i].enabled = false
            statusByEdge[id] = "停止中"
        }
        save()
    }

    func stopAll() {
        for (_, e) in engines { e.stop() }
        engines.removeAll()
        maybeStopTimer()
    }

    private func bus(_ name: String) -> AudioBus {
        if let b = buses[name] { return b }
        let b = AudioBus()
        buses[name] = b
        return b
    }

    // MARK: activate

    @discardableResult
    private func activate(_ id: UUID) -> Bool {
        guard let e = edges.first(where: { $0.id == id }) else { return false }
        if active(id) { return true }
        refreshLists()
        let b = bus(e.busName)
        do {
            switch (e.role, e.endpoint) {
            case (.input, .appTap):
                guard !e.appBundleID.isEmpty,
                      let p = processes.first(where: { $0.bundleID == e.appBundleID })
                else { statusByEdge[id] = "アプリ「\(e.appName)」が音声出力していません"; return false }
                guard let po = ProcessEnumerator.processObject(for: p.pid)
                else { statusByEdge[id] = "プロセス変換に失敗"; return false }
                engines[id] = try TapInEdge(processObject: po,
                                            muteSource: e.muteSource, bus: b)

            case (.input, .mic):
                let dev = e.micUID.isEmpty
                    ? AudioDeviceEnumerator.defaultInput()?.id
                    : inputs.first(where: { $0.uid == e.micUID })?.id
                guard let dev else { statusByEdge[id] = "マイクが見つかりません"; return false }
                engines[id] = try MicInEdge(deviceID: dev,
                                            useDefault: e.micUID.isEmpty, bus: b)

            case (.input, .babigoeOut):
                let s = ShmInEdge(shmName: ShmReader.nameBabigoeOut, bus: b)
                s.start(); engines[id] = s

            case (.output, .splitter):
                let s = ShmOutEdge(shmName: ShmSender.nameToSplitter, bus: b)
                s.start(); engines[id] = s

            case (.output, .babigoeIn):
                let s = ShmOutEdge(shmName: ShmSender.nameBabigoeIn, bus: b)
                s.start(); engines[id] = s

            default:
                statusByEdge[id] = "未対応のエッジ"; return false
            }
        } catch {
            statusByEdge[id] = "開始失敗: \(error.localizedDescription)"
            return false
        }
        statusByEdge[id] = "稼働中"
        ensureTimer()
        return true
    }

    private func deactivate(_ id: UUID) {
        if let e = engines[id] { e.stop(); engines[id] = nil }
        maybeStopTimer()
    }

    // MARK: 診断タイマー（毎秒 per-edge）

    private func ensureTimer() {
        guard statusTimer == nil else { return }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0,
                                           repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for (id, eng) in self.engines {
                    if let e = self.edges.first(where: { $0.id == id }) {
                        self.statusByEdge[id] =
                            "稼働中  \(e.displayLeft)→\(e.displayRight)  \(eng.diag)"
                    }
                }
            }
        }
    }
    private func maybeStopTimer() {
        if engines.isEmpty { statusTimer?.invalidate(); statusTimer = nil }
    }

    // MARK: 永続化

    private func load() {
        guard let d = try? Data(contentsOf: storeURL),
              let v = try? JSONDecoder().decode([RouteEdge].self, from: d)
        else { return }
        edges = v
    }
    private func save() {
        guard let d = try? JSONEncoder().encode(edges) else { return }
        try? d.write(to: storeURL, options: .atomic)
    }
}
