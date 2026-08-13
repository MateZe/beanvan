// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CuppaJoe",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "CuppaJoe",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
