import Foundation
import SwiftUI
import CoreAudio
import AudioRouterCore

/// UI ↔ エンジンの仲介。FROM(プロセス)/TO(モニタ出力) 選択と ON/OFF を保持。
@available(macOS 14.4, *)
@MainActor
final class RouterController: ObservableObject {
    @Published var processes: [AudioProcess] = []
    @Published var outputs: [OutputDevice] = []

    @Published var selectedProcessID: AudioProcess.ID?
    @Published var monitorEnabled = false
    @Published var selectedOutputID: OutputDevice.ID?

    @Published var sendHost = "127.0.0.1"
    @Published var sendPort = "7878"

    @Published private(set) var isRunning = false
    @Published var statusText = "停止中"

    private let engine = ProcessTapEngine()

    init() {
        refreshLists()
        selectedOutputID = AudioDeviceEnumerator.defaultOutput()?.id
    }

    func refreshLists() {
        processes = ProcessEnumerator.list(onlyOutput: true)
        outputs = AudioDeviceEnumerator.outputs()
        if let sel = selectedProcessID,
           !processes.contains(where: { $0.id == sel }) {
            selectedProcessID = nil
        }
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    private func start() {
        guard let procID = selectedProcessID,
              let proc = processes.first(where: { $0.id == procID }) else {
            statusText = "FROM（対象アプリ）を選択してください"
            return
        }
        guard let port = UInt16(sendPort) else {
            statusText = "ポート番号が不正です"
            return
        }
        guard let processObject = ProcessEnumerator.processObject(for: proc.pid) else {
            statusText = "プロセス変換に失敗（既に終了？）"
            return
        }
        let monitorDev: AudioObjectID? = monitorEnabled ? selectedOutputID : nil
        do {
            try engine.start(processObject: processObject,
                             sendHost: sendHost, sendPort: port,
                             monitorDevice: monitorDev)
            isRunning = true
            statusText = "送出中: \(proc.name) → udp \(sendHost):\(port)"
                + (monitorEnabled ? " ＋モニタ" : "")
        } catch {
            isRunning = false
            statusText = "開始失敗: \(error)"
        }
    }

    private func stop() {
        engine.stop()
        isRunning = false
        statusText = "停止中"
    }
}
