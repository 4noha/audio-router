import Foundation
import SwiftUI
import CoreAudio
import AudioRouterCore

/// ルール一覧の保持・永続化と、ルール 1 本ごとの ProcessTapEngine 起動/停止。
/// トグル状態 = 実エンジン状態に常に一致させる（起動失敗時は OFF へ矯正）。
@available(macOS 14.4, *)
@MainActor
final class RouterController: ObservableObject {
    @Published var rules: [RoutingRule] = []
    @Published var processes: [AudioProcess] = []
    @Published var outputs: [OutputDevice] = []
    /// rule.id → 直近の状態テキスト（送出中 / 失敗理由）。
    @Published var statusByRule: [UUID: String] = [:]

    private var engines: [UUID: ProcessTapEngine] = [:]
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
        // 前回 ON だったルートを起動（失敗時はトグル OFF へ矯正）。
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
    }

    func active(_ id: UUID) -> Bool { engines[id] != nil }

    // MARK: - CRUD

    func addRule(_ rule: RoutingRule) {
        var r = rule
        r.enabled = false
        rules.append(r)
        save()
    }

    func updateRule(_ rule: RoutingRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let wasActive = engines[rule.id] != nil
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
        engines.removeAll()
    }

    // MARK: - エンジン

    @discardableResult
    private func activate(ruleID: UUID) -> Bool {
        guard let rule = rules.first(where: { $0.id == ruleID }) else { return false }
        if engines[ruleID] != nil { return true }
        refreshLists()

        guard !rule.sourceBundleID.isEmpty,
              let proc = processes.first(where: { $0.bundleID == rule.sourceBundleID })
        else {
            statusByRule[ruleID] = "対象アプリ「\(rule.sourceName)」が音声出力していません"
            return false
        }
        guard let port = UInt16(rule.sendPort) else {
            statusByRule[ruleID] = "ポート番号が不正です"
            return false
        }
        guard let processObject = ProcessEnumerator.processObject(for: proc.pid) else {
            statusByRule[ruleID] = "プロセス変換に失敗（既に終了？）"
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
            engines[ruleID] = engine
            statusByRule[ruleID] = "送出中: \(proc.name) → udp \(rule.sendHost):\(port)"
                + (rule.monitorEnabled ? " ＋モニタ" : "")
            return true
        } catch {
            statusByRule[ruleID] = "開始失敗: \(error)"
            return false
        }
    }

    private func deactivate(ruleID: UUID) {
        if let engine = engines[ruleID] {
            engine.stop()
            engines[ruleID] = nil
        }
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
