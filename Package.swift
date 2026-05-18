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
        .target(
            name: "AudioRouterCore",
            dependencies: ["CShmCompat"]
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
