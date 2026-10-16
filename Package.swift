// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeNotClose",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeNotClose",
            path: "Sources/ClaudeNotClose",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "ClaudeNotCloseTests",
            dependencies: ["ClaudeNotClose"],
            path: "Tests/ClaudeNotCloseTests"
        ),
    ]
)
