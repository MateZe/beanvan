// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Beanvan",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .target(
            name: "CoffeeProtocol"
        ),
        .executableTarget(
            name: "Beanvan",
            dependencies: ["CoffeeProtocol"],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "BeanvanTests",
            dependencies: ["Beanvan"]
        ),
        .testTarget(
            name: "CoffeeProtocolTests",
            dependencies: ["CoffeeProtocol"]
        ),
    ]
)
