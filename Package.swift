// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyMacAgent",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "MyMacAgent",
            path: "Sources/MyMacAgent",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "MyMacAgentTests",
            dependencies: ["MyMacAgent"],
            path: "Tests/MyMacAgentTests"
        ),
    ]
)
