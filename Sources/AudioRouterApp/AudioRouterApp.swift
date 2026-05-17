import SwiftUI

@main
struct AudioRouterApp: App {
    var body: some Scene {
        WindowGroup("Audio Router") {
            RootView()
        }
        .windowResizability(.contentMinSize)
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
