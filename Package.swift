// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoSign",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AutoSign", targets: ["AutoSign"]),
        .executable(name: "AutoSignDeviceHelper", targets: ["AutoSignDeviceHelper"]),
        .executable(name: "AutoSignRemoteHelper", targets: ["AutoSignRemoteHelper"])
    ],
    targets: [
        .executableTarget(name: "AutoSign"),
        .executableTarget(name: "AutoSignDeviceHelper", linkerSettings: [.linkedFramework("Foundation")]),
        .executableTarget(name: "AutoSignRemoteHelper"),
        .testTarget(name: "AutoSignTests", dependencies: ["AutoSign", "AutoSignRemoteHelper"])
    ]
)
