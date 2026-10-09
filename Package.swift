// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalModelLauncher",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "LocalModelLauncher", targets: ["LocalModelLauncher"]),
        .executable(name: "lml", targets: ["lml"])
    ],
    targets: [
        .target(name: "ModelCore"),
        .executableTarget(name: "lml", dependencies: ["ModelCore"]),
        .executableTarget(name: "LocalModelLauncher", dependencies: ["ModelCore"]),
        .testTarget(name: "ModelCoreTests", dependencies: ["ModelCore"])
    ]
)
