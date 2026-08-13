// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "native-transcriber",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "native-transcriber", targets: ["native-transcriber"]),
    ],
    dependencies: [
        // ⚠️ Toolchain gate: mlx-audio-swift declares swift-tools-version 6.2.
        // It will NOT resolve on Swift 6.1 (Xcode 16.x / macOS 15). Build this
        // with Xcode 26 / Swift 6.2 (macOS 26). See README.md.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "native-transcriber",
            dependencies: [
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
            ]
        ),
    ]
)