// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DisplayMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DisplayMonitor", targets: ["DisplayMonitor"]),
        .executable(name: "DisplayMonitorPhase0Spike", targets: ["DisplayMonitorPhase0Spike"])
    ],
    targets: [
        .target(
            name: "DisplayMonitorCore",
            path: "Sources/DisplayMonitorCore"
        ),
        .target(
            name: "MenuBarVisibilityBridge",
            path: "Sources/MenuBarVisibilityBridge",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fobjc-arc"])
            ],
            linkerSettings: [
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "DisplayMonitor",
            dependencies: ["DisplayMonitorCore", "MenuBarVisibilityBridge"],
            path: "Sources/DisplayMonitor",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "DisplayMonitorPhase0Spike",
            dependencies: ["DisplayMonitorCore"],
            path: "Sources/DisplayMonitorPhase0Spike"
        ),
        .testTarget(
            name: "DisplayMonitorCoreTests",
            dependencies: ["DisplayMonitorCore", "DisplayMonitor"],
            path: "Tests/DisplayMonitorCoreTests"
        )
    ]
)
