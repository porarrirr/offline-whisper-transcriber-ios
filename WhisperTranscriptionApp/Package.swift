// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhisperTranscriptionApp",
    platforms: [.iOS(.v17)],
    products: [
        .library(
            name: "WhisperTranscriptionApp",
            targets: ["WhisperTranscriptionApp"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WhisperTranscriptionApp",
            dependencies: [],
            path: "Sources/WhisperTranscriptionApp",
            exclude: [],
            swiftSettings: [
                .enableExperimentalFeature("SwiftData")
            ]
        )
    ]
)
