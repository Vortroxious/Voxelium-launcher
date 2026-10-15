// swift-tools-version:6.0
import PackageDescription

// ZalithCore is the platform-independent launcher core. It builds and tests on
// macOS with only the Command Line Tools, and is linked into the iOS app target
// (App/) once Xcode is available. See docs/ARCHITECTURE.md.
let package = Package(
    name: "ZalithIOS",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [
        .library(name: "ZalithCore", targets: ["ZalithCore"]),
        .executable(name: "zalith-cli", targets: ["zalith-cli"]),
    ],
    targets: [
        .target(name: "ZalithCore"),
        .executableTarget(name: "zalith-cli", dependencies: ["ZalithCore"]),
        .testTarget(
            name: "ZalithCoreTests",
            dependencies: ["ZalithCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
