// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyMacAgent",
    platforms: [.macOS(.v13)],
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
