// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LLMarium",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "LLMariumApp", targets: ["LLMariumApp"]),
        .executable(name: "llmarium", targets: ["llmarium"])
    ],
    targets: [
        .target(name: "ModelCore"),
        .executableTarget(name: "llmarium", dependencies: ["ModelCore"]),
        .executableTarget(name: "LLMariumApp", dependencies: ["ModelCore"]),
        .testTarget(name: "ModelCoreTests", dependencies: ["ModelCore"])
    ]
)
