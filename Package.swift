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
        .target(
            name: "AudioRouterCore"
        ),
        .executableTarget(
            name: "AudioRouterApp",
            dependencies: ["AudioRouterCore"]
        )
    ]
)
