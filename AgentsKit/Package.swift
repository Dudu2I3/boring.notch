// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentsKit", targets: ["AgentsKit"]),
        .executable(name: "notch-agents-hooks", targets: ["notch-agents-hooks"]),
    ],
    targets: [
        .target(name: "AgentsKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "notch-agents-hooks",
            dependencies: ["AgentsKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentsKitTests",
            dependencies: ["AgentsKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
