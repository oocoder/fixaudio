// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "native-transcriber",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "native-transcriber", targets: ["native-transcriber"]),
    ],
    dependencies: [
        // FluidAudio: native Swift, CoreML/ANE, builds on macOS 15 / Swift 6.
        // Provides Parakeet ASR + diarization (Sortformer ≤4 / LS-EEND ≤10 /
        // offline VBx no-cap). Apache-2.0.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "native-transcriber",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)