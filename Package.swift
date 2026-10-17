// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KachraClean",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KachraCore", targets: ["KachraCore"]),
        .executable(name: "kachra", targets: ["kachra"]),
    ],
    targets: [
        .target(
            name: "KachraCore",
            resources: [.process("Resources/rules.json")]
        ),
        .executableTarget(
            name: "kachra",
            dependencies: ["KachraCore"]
        ),
        .testTarget(
            name: "KachraCoreTests",
            dependencies: ["KachraCore"]
        ),
    ]
)
