// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "audio-unit-capture",
    targets: [
        .executableTarget(
            name: "audio-unit-capture",
            path: "Sources/audio-unit-capture"
        )
    ]
)
