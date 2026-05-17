import Foundation
import SwiftUI
import CoreAudio
import AudioRouterCore

/// ルート一覧の保持・永続化と、ルール 1 本ごとのエンジン起動/停止。
/// kind により appRoute=ProcessTapEngine / babigoeHub=HubEngine を使い分ける。
/// トグル状態 = 実エンジン状態に常に一致させる（起動失敗時は OFF へ矯正）。
@available(macOS 14.4, *)
@MainActor
final class RouterController: ObservableObject {
    @Published var rules: [RoutingRule] = []
    @Published var processes: [AudioProcess] = []
    @Published var outputs: [OutputDevice] = []
    @Published var inputs: [InputDevice] = []
    /// rule.id → 直近の状態テキスト（送出中 / 失敗理由）。
    @Published var statusByRule: [UUID: String] = [:]

    private var engines: [UUID: ProcessTapEngine] = [:]   // appRoute
    private var hubEngines: [UUID: HubEngine] = [:]        // babigoeHub
    private let storeURL: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioRouter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("rules.json")

        refreshLists()
        load()
        // 前回 ON だったルートを復元（失敗時はトグル OFF へ矯正）。
        for rule in rules where rule.enabled {
            if !activate(ruleID: rule.id),
               let idx = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[idx].enabled = false
            }
        }
        save()
    }

    // MARK: - 一覧

    func refreshLists() {
        processes = ProcessEnumerator.list(onlyOutput: true)
        outputs = AudioDeviceEnumerator.outputs()
        inputs = AudioDeviceEnumerator.inputs()
    }

    func active(_ id: UUID) -> Bool {
        engines[id] != nil || hubEngines[id] != nil
    }

    // MARK: - CRUD

    func addRule(_ rule: RoutingRule) {
        var r = rule
        r.enabled = false
        rules.append(r)
        save()
    }

    func updateRule(_ rule: RoutingRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let wasActive = active(rule.id)
        deactivate(ruleID: rule.id)
        rules[idx] = rule
        rules[idx].enabled = false
        if wasActive { setEnabled(rule.id, true) }
        save()
    }

    func deleteRule(_ id: UUID) {
        deactivate(ruleID: id)
        rules.removeAll { $0.id == id }
        statusByRule[id] = nil
        save()
    }

    // MARK: - トグル

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        if on {
            rules[idx].enabled = activate(ruleID: id)
        } else {
            deactivate(ruleID: id)
            rules[idx].enabled = false
            statusByRule[id] = "停止中"
        }
        save()
    }

    func stopAll() {
        for (_, e) in engines { e.stop() }
        for (_, h) in hubEngines { h.stop() }
        engines.removeAll()
        hubEngines.removeAll()
    }

    // MARK: - エンジン起動

    @discardableResult
    private func activate(ruleID: UUID) -> Bool {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return false }
        if active(ruleID) { return true }
        refreshLists()
        switch rule.kind {
        case .appRoute:   return activateApp(rule)
        case .babigoeHub: return activateHub(rule)
        }
    }

    private func activateApp(_ rule: RoutingRule) -> Bool {
        guard !rule.sourceBundleID.isEmpty,
              let proc = processes.first(where: { $0.bundleID == rule.sourceBundleID })
        else {
            statusByRule[rule.id] = "対象アプリ「\(rule.sourceName)」が音声出力していません"
            return false
        }
        guard let port = UInt16(rule.sendPort) else {
            statusByRule[rule.id] = "ポート番号が不正です"
            return false
        }
        guard let processObject = ProcessEnumerator.processObject(for: proc.pid) else {
            statusByRule[rule.id] = "プロセス変換に失敗（既に終了？）"
            return false
        }
        var monitorDev: AudioObjectID?
        if rule.monitorEnabled {
            monitorDev = rule.monitorDeviceUID.isEmpty
                ? AudioDeviceEnumerator.defaultOutput()?.id
                : outputs.first(where: { $0.uid == rule.monitorDeviceUID })?.id
        }
        let engine = ProcessTapEngine()
        do {
            try engine.start(processObject: processObject,
                             sendHost: rule.sendHost, sendPort: port,
                             monitorDevice: monitorDev)
            engines[rule.id] = engine
            statusByRule[rule.id] = "送出中: \(proc.name) → 4ksplitter"
                + (rule.monitorEnabled ? " ＋モニタ" : "")
                + (rule.udpEnabled ? " ＋UDP \(rule.sendHost):\(port)" : "")
            return true
        } catch {
            statusByRule[rule.id] = "開始失敗: \(error)"
            return false
        }
    }

    private func activateHub(_ rule: RoutingRule) -> Bool {
        let micID = rule.micUID.isEmpty
            ? AudioDeviceEnumerator.defaultInput()?.id
            : inputs.first(where: { $0.uid == rule.micUID })?.id
        guard let micID else {
            statusByRule[rule.id] = "マイク「\(rule.micName)」が見つかりません"
            return false
        }
        var monID: AudioObjectID?
        if rule.monitorEnabled {
            monID = rule.monitorDeviceUID.isEmpty
                ? AudioDeviceEnumerator.defaultOutput()?.id
                : outputs.first(where: { $0.uid == rule.monitorDeviceUID })?.id
        }
        var host: String?
        var port: UInt16?
        if rule.udpEnabled {
            guard let p = UInt16(rule.sendPort) else {
                statusByRule[rule.id] = "UDP ポート番号が不正です"
                return false
            }
            host = rule.sendHost; port = p
        }
        let hub = HubEngine(micDeviceID: micID, monitorDeviceID: monID,
                            udpHost: host, udpPort: port)
        do {
            try hub.start()
            hubEngines[rule.id] = hub
            statusByRule[rule.id] = "稼働中: \(rule.displayIn) → babigoe → 4ksplitter"
                + (rule.monitorEnabled ? " ＋モニタ" : "")
                + (rule.udpEnabled ? " ＋UDP" : "")
            return true
        } catch {
            statusByRule[rule.id] = "開始失敗: \(error.localizedDescription)"
            return false
        }
    }

    private func deactivate(ruleID: UUID) {
        if let e = engines[ruleID] { e.stop(); engines[ruleID] = nil }
        if let h = hubEngines[ruleID] { h.stop(); hubEngines[ruleID] = nil }
    }

    // MARK: - 永続化

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([RoutingRule].self, from: data)
        else { return }
        rules = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
