// swift-tools-version: 6.0
import PackageDescription
import Foundation

let authBuildRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".build")

let package = Package(
    name: "AutoSign",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AutoSign", targets: ["AutoSign"]),
        .executable(name: "AutoSignDeviceHelper", targets: ["AutoSignDeviceHelper"]),
        .executable(name: "AutoSignRemoteHelper", targets: ["AutoSignRemoteHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/rileytestut/AltSign.git", revision: "832d9cec339ea6ef6891011833dbb7227b028a29"),
        .package(url: "https://github.com/altstoreio/AnisetteKit.git", revision: "1f5a7e36553cc865b873f222b87a6486c0bcc7bf")
    ],
    targets: [
        .executableTarget(name: "AutoSign", dependencies: [
            .product(name: "AltSign-Static", package: "AltSign"),
            .product(name: "AnisetteKit", package: "AnisetteKit")
        ], linkerSettings: [.unsafeFlags([
            "-L", authBuildRoot.appendingPathComponent("native-auth/Release").path, "-lcorecrypto_static",
            "-F", authBuildRoot.appendingPathComponent("checkouts/AltSign/Dependencies/OpenSSL/Frameworks/OpenSSL.xcframework/macos-arm64_x86_64").path,
            "-framework", "OpenSSL", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"
        ])]),
        .executableTarget(name: "AutoSignDeviceHelper", linkerSettings: [.linkedFramework("Foundation")]),
        .executableTarget(name: "AutoSignRemoteHelper"),
        .testTarget(name: "AutoSignTests", dependencies: ["AutoSign", "AutoSignRemoteHelper"])
    ]
)
