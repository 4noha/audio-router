import SwiftUI
import AudioRouterCore

@available(macOS 14.4, *)
struct ContentView: View {
    @StateObject private var ctl = RouterController()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // FROM: 対象アプリ
            GroupBox("FROM — 対象アプリ（音声を出している実行中プロセス）") {
                VStack(alignment: .leading, spacing: 8) {
                    List(selection: $ctl.selectedProcessID) {
                        ForEach(ctl.processes) { p in
                            HStack {
                                Text(p.name)
                                Spacer()
                                Text(p.bundleID.isEmpty ? "pid \(p.pid)" : p.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(p.id as AudioProcess.ID?)
                        }
                    }
                    .frame(height: 130)
                    Button {
                        ctl.refreshLists()
                    } label: {
                        Label("一覧を更新", systemImage: "arrow.clockwise")
                    }
                    .disabled(ctl.isRunning)
                }
                .padding(6)
            }

            // TO: 4ksplitter(UDP) + 任意モニタ
            GroupBox("TO — 送出先") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("4ksplitter (UDP)")
                        TextField("host", text: $ctl.sendHost)
                            .frame(width: 120)
                        Text(":")
                        TextField("port", text: $ctl.sendPort)
                            .frame(width: 70)
                    }
                    .disabled(ctl.isRunning)

                    Toggle("モニタ出力（別デバイスへ流して聴く）", isOn: $ctl.monitorEnabled)
                        .disabled(ctl.isRunning)
                    Picker("出力デバイス", selection: $ctl.selectedOutputID) {
                        ForEach(ctl.outputs) { d in
                            Text(d.name).tag(d.id as OutputDevice.ID?)
                        }
                    }
                    .disabled(ctl.isRunning || !ctl.monitorEnabled)

                    Text("モニタ ON：元アプリ出力をミュートし選んだデバイスへ一本化"
                         + "（二重再生なし）。OFF：元アプリの音はそのまま、UDP のみ送出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            // ON/OFF
            HStack {
                Button {
                    ctl.toggle()
                } label: {
                    Label(ctl.isRunning ? "停止" : "開始",
                          systemImage: ctl.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .tint(ctl.isRunning ? .red : .accentColor)
            }

            Text(ctl.statusText)
                .font(.callout)
                .foregroundStyle(ctl.isRunning ? .green : .secondary)
        }
        .padding(18)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Audio Router")
                .font(.title2).bold()
            Text("per-app 音声を捕捉して 4ksplitter へ。UI 操作はすべてこのアプリ側。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
