// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DC",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Pinned for reproducible release builds. The committed Package.resolved locks the
        // exact revision; .upToNextMinor keeps us on 0.9.x patches but never auto-jumps to 0.10+.
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            .upToNextMinor(from: "0.9.20")
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
                .process("Shaders.metal")
            ]
        ),
        .testTarget(
            name: "DCTests",
            dependencies: ["DC"],
            path: "Tests/DCTests"
        )
    ]
)
