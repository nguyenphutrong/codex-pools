// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexManager",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexManager", targets: ["CodexManager"])
    ],
    targets: [
        .executableTarget(
            name: "CodexManager",
            path: "CodexManager",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
