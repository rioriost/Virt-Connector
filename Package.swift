// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VirtConnector",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "virt-connector", targets: ["VirtConnectorCLI"]),
        .executable(name: "virt-connectord", targets: ["VirtConnectorDaemon"])
    ],
    targets: [
        .target(name: "VirtConnectorCore"),
        .executableTarget(
            name: "VirtConnectorCLI",
            dependencies: ["VirtConnectorCore"]
        ),
        .executableTarget(
            name: "VirtConnectorDaemon",
            dependencies: ["VirtConnectorCore"]
        ),
        .testTarget(
            name: "VirtConnectorCoreTests",
            dependencies: ["VirtConnectorCore"]
        )
    ]
)
