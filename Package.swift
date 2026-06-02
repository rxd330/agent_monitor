// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentMonitor", targets: ["AgentMonitor"]),
    ],
    targets: [
        .executableTarget(
            name: "AgentMonitor",
            path: "Sources/AgentMonitor"
        ),
        .testTarget(
            name: "AgentMonitorTests",
            dependencies: ["AgentMonitor"],
            path: "Tests/AgentMonitorTests"
        ),
    ]
)
