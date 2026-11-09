// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Damper",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .target(name: "AudioRealtime", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "DamperCore", dependencies: ["AudioRealtime"]),
        .executableTarget(name: "Damper", dependencies: ["DamperCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "DamperCoreTests", dependencies: ["DamperCore", "AudioRealtime"])
    ],
    swiftLanguageModes: [.v6]
)
