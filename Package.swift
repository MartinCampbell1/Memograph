// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MyMacAgent",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MyMacAgent",
            path: "Sources/MyMacAgent",
            exclude: [
                "Advisory/Bridge/__pycache__"
            ],
            resources: [
                .copy("Audio/whisper_transcribe.py"),
                .copy("Advisory/Bridge/memograph_advisor.py"),
                .copy("Advisory/Bridge/provider_sessions.py"),
            ],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("EventKit"),
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
