// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoSign",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AutoSign", targets: ["AutoSign"])
    ],
    targets: [
        .executableTarget(name: "AutoSign"),
        .testTarget(name: "AutoSignTests", dependencies: ["AutoSign"])
    ]
)
