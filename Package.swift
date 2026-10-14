// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoSign",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AutoSign", targets: ["AutoSign"]),
        .executable(name: "AutoSignDeviceHelper", targets: ["AutoSignDeviceHelper"])
    ],
    targets: [
        .executableTarget(name: "AutoSign"),
        .executableTarget(name: "AutoSignDeviceHelper", linkerSettings: [.linkedFramework("Foundation")]),
        .testTarget(name: "AutoSignTests", dependencies: ["AutoSign"])
    ]
)
