// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DC",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            from: "0.9.19"
        )
    ],
    targets: [
        .executableTarget(
            name: "DC",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources/DC",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
