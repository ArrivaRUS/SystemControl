// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SystemControl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SystemControl",
            path: "Sources/SystemControl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
