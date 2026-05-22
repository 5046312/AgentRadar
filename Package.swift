// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentRadar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentRadar", targets: ["AgentRadar"])
    ],
    targets: [
        .executableTarget(
            name: "AgentRadar",
            path: "Sources/AgentRadar",
            resources: []
        )
    ]
)
