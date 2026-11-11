// swift-tools-version:6.0
import PackageDescription

// 外部パッケージには依存しない（Apple のフレームワークだけを使う）。
// 依存を増やすとサプライチェーン経由の通信・改ざんの余地が増えるため。
let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageBar", targets: ["UsageBar"]),
        .executable(name: "usagebar-bridge", targets: ["UsageBarBridge"]),
    ],
    targets: [
        .target(
            name: "UsageCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "UsageBar",
            dependencies: ["UsageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "UsageBarBridge",
            dependencies: ["UsageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
