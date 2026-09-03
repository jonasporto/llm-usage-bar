// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LLMUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UsageCore", path: "Sources/UsageCore"),
        .executableTarget(name: "LLMUsageBar",
                          dependencies: ["UsageCore"],
                          path: "Sources/LLMUsageBar"),
        .testTarget(name: "UsageCoreTests",
                    dependencies: ["UsageCore"],
                    path: "Tests/UsageCoreTests")
    ]
)
