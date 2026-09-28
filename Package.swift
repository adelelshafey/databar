// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacNetworkMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "NetworkMonitorCore", targets: ["NetworkMonitorCore"]),
        .executable(name: "MacNetworkMonitor", targets: ["MacNetworkMonitor"])
    ],
    targets: [
        .target(
            name: "NetworkMonitorCore",
            path: "Sources/NetworkMonitorCore"
        ),
        .executableTarget(
            name: "MacNetworkMonitor",
            dependencies: ["NetworkMonitorCore"],
            path: "Sources/MacNetworkMonitor",
            linkerSettings: [.linkedFramework("ServiceManagement")]
        ),
        .testTarget(
            name: "NetworkMonitorCoreTests",
            dependencies: ["NetworkMonitorCore"],
            path: "Tests/NetworkMonitorCoreTests"
        )
    ]
)
