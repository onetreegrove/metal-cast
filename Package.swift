// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetalCast",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MetalCastCore", targets: ["MetalCastCore"]),
        .library(name: "MetalCastMedia", targets: ["MetalCastMedia"]),
        .executable(name: "metalcast-cli", targets: ["MetalCastCLI"]),
        .executable(name: "MetalCast", targets: ["MetalCastApp"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MetalCastCore",
            dependencies: [],
            path: "Sources/MetalCastCore"
        ),
        .target(
            name: "MetalCastMedia",
            dependencies: ["MetalCastCore"],
            path: "Sources/MetalCastMedia",
            resources: [
                .process("Shaders.metal")
            ]
        ),
        .executableTarget(
            name: "MetalCastCLI",
            dependencies: ["MetalCastCore", "MetalCastMedia"],
            path: "Sources/MetalCastCLI"
        ),
        .executableTarget(
            name: "MetalCastApp",
            dependencies: ["MetalCastCore", "MetalCastMedia"],
            path: "Sources/MetalCastApp"
        ),
        .testTarget(
            name: "MetalCastCoreTests",
            dependencies: ["MetalCastCore"],
            path: "Tests/MetalCastCoreTests"
        )
    ]
)
