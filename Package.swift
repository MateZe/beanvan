// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CuppaJoe",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .target(
            name: "CoffeeProtocol"
        ),
        .executableTarget(
            name: "CuppaJoe",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "CuppaJoeTests",
            dependencies: ["CuppaJoe"]
        ),
        .testTarget(
            name: "CoffeeProtocolTests",
            dependencies: ["CoffeeProtocol"]
        ),
    ]
)
