// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LLMUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LLMUsageBar", targets: ["LLMUsageBar"]),
        .executable(name: "llm-usage", targets: ["LLMUsageCLI"])
    ],
    targets: [
        .target(name: "UsageCore", path: "Sources/UsageCore"),
        .executableTarget(name: "LLMUsageBar",
                          dependencies: ["UsageCore"],
                          path: "Sources/LLMUsageBar"),
        .executableTarget(name: "LLMUsageCLI",
                          dependencies: ["UsageCore"],
                          path: "Sources/LLMUsageCLI"),
        .testTarget(name: "UsageCoreTests",
                    dependencies: ["UsageCore"],
                    path: "Tests/UsageCoreTests")
    ]
)
