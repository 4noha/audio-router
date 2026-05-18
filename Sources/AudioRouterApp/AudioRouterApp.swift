import SwiftUI
import AppKit

@main
struct AudioRouterApp: App {
    init() { Self.handleAutomationArgs() }

    var body: some Scene {
        WindowGroup("Audio Router") {
            RootView()
        }
        .windowResizability(.contentMinSize)
    }

    /// 自動オペレーション用起動引数:
    ///   --apply <routes.json>  RouterController 読込前に routes.json を差替
    ///   --quit-after <sec>     指定秒後に自動終了（E2E テストの後始末）
    static func handleAutomationArgs() {
        let a = CommandLine.arguments
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioRouter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)

        if let i = a.firstIndex(of: "--apply"), i + 1 < a.count {
            let src = URL(fileURLWithPath: a[i + 1])
            let dst = base.appendingPathComponent("routes.json")
            if let d = try? Data(contentsOf: src) {
                try? d.write(to: dst, options: .atomic)
            }
        }
        if let i = a.firstIndex(of: "--quit-after"), i + 1 < a.count,
           let sec = Double(a[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

/// macOS 14.4 未満では機能不可（プロセスタップ API 非対応）の明示。
struct RootView: View {
    var body: some View {
        if #available(macOS 14.4, *) {
            ContentView()
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text("macOS 14.4 以上が必要です")
                    .font(.headline)
                Text("プロセスタップ API（per-app 音声捕捉）は macOS 14.4 で導入されました。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
        }
    }
}
