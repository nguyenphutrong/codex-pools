// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexPools",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexPools", targets: ["CodexPools"])
    ],
    targets: [
        .executableTarget(
            name: "CodexPools",
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
