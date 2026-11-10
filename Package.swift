// swift-tools-version: 6.2
// Lets the app's platform-independent mesh code (packets, routing, crypto) be
// unit tested with `swift test`, without a simulator. The app itself is built
// from NoBars.xcodeproj.
import PackageDescription

let package = Package(
    name: "NoBarsCore",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [.library(name: "MeshCore", targets: ["MeshCore"])],
    targets: [
        .target(
            name: "MeshCore",
            path: "NoBars/Models",
            sources: ["MeshRelayPacket.swift", "MeshCrypto.swift"]
        ),
        .testTarget(
            name: "MeshCoreTests",
            dependencies: ["MeshCore"],
            path: "Tests/MeshCoreTests"
        ),
    ]
)
