// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "fixaudio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MeetingRecorder", targets: ["MeetingRecorder"]),
    ],
    targets: [
        // The meeting-recorder menu-bar app. Audio capture + the centered/sources
        // M4A encode. Transcription (FluidAudio) is added in a later step.
        // Swift 5 language mode for now: the recorder pre-dates Swift 6 strict
        // concurrency (AppKit main-actor APIs). FluidAudio still builds in Swift 6.
        .executableTarget(name: "MeetingRecorder", path: "src/MeetingRecorder",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)