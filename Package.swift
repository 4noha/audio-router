// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioRouter",
    platforms: [
        // Process-tap API requires macOS 14.4+ at runtime.
        // SPM platform granularity is .v14; 14.4 is enforced via Info.plist
        // (LSMinimumSystemVersion) and runtime #available checks.
        .macOS(.v14)
    ],
    targets: [
        // shm_open(O_CREAT) を正しい C 可変長で呼ぶための C シム。
        .target(
            name: "CShmCompat"
        ),
        // Homebrew インストールの libopus を Swift から使う systemLibrary。
        // 開発機に `brew install opus pkg-config` が必要（pkgConfig "opus"
        // が opus.pc を見つけて自動で -I / -L / -lopus を解決）。.app には
        // libopus.dylib への動的リンクが残るので、配布する場合は別途
        // libopus を同梱するか static link 化する必要がある（個人利用の
        // 範囲では brew パスに依存して問題ない）。
        .systemLibrary(
            name: "COpus",
            pkgConfig: "opus",
            providers: [.brew(["opus"])]
        ),
        .target(
            name: "AudioRouterCore",
            dependencies: ["CShmCompat", "COpus"]
        ),
        .executableTarget(
            name: "AudioRouterApp",
            dependencies: ["AudioRouterCore"]
        ),
        // 動作検証用 CLI: 任意 ARPS shm を attach し JSON でヘッダ/流量出力。
        .executableTarget(
            name: "arps-probe",
            dependencies: ["CShmCompat"]
        ),
        // E2E 合成音源 CLI: 指定 shm を作成し正弦波を書き込み続ける。
        .executableTarget(
            name: "arps-feed",
            dependencies: ["CShmCompat"]
        )
    ]
)
