// swift-tools-version:6.0
import PackageDescription

// VoxeliumCore is the platform-independent launcher core. It builds and tests on
// macOS with only the Command Line Tools, and is linked into the iOS app target
// (App/) once Xcode is available. See docs/ARCHITECTURE.md.
let package = Package(
    name: "Voxelium",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "VoxeliumCore", targets: ["VoxeliumCore"]),
        .executable(name: "voxelium-cli", targets: ["voxelium-cli"]),
    ],
    targets: [
        .target(name: "VoxeliumCore"),
        .executableTarget(name: "voxelium-cli", dependencies: ["VoxeliumCore"]),
        .testTarget(
            name: "VoxeliumCoreTests",
            dependencies: ["VoxeliumCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
