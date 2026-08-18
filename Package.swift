// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "fixaudio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MeetingRecorder", targets: ["MeetingRecorder"]),
    ],
    dependencies: [
        // Native on-device ASR + diarization (Parakeet CoreML/ANE + offline VBx).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        // The meeting-recorder menu-bar app: audio capture + centered/sources
        // M4A encode + in-app per-source transcription (FluidAudio).
        // Swift 5 language mode for now: the recorder pre-dates Swift 6 strict
        // concurrency (AppKit main-actor APIs). FluidAudio builds in Swift 6.
        .executableTarget(name: "MeetingRecorder",
                          dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                          path: "src/MeetingRecorder",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MeetingRecorderTests",
                    dependencies: ["MeetingRecorder"],
                    path: "Tests/MeetingRecorderTests"),
    ]
)
