// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MyMacAgent",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MyMacAgent",
            path: "Sources/MyMacAgent",
            resources: [
                .copy("Audio/whisper_transcribe.py"),
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "MyMacAgentTests",
            dependencies: ["MyMacAgent"],
            path: "Tests/MyMacAgentTests"
        ),
    ]
)
