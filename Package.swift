// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UsageCore", path: "Sources/UsageCore"),
        .executableTarget(name: "ClaudeUsageBar",
                          dependencies: ["UsageCore"],
                          path: "Sources/ClaudeUsageBar"),
        .testTarget(name: "UsageCoreTests",
                    dependencies: ["UsageCore"],
                    path: "Tests/UsageCoreTests")
    ]
)
