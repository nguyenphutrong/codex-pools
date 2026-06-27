// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexPools",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "CodexPoolsCore", targets: ["CodexPoolsCore"]),
        .executable(name: "CodexPools", targets: ["CodexPools"]),
        .executable(name: "codex-pools", targets: ["codex-pools"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .target(
            name: "CodexPoolsCore",
            path: "CodexPoolsCore",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "CodexPools",
            dependencies: [
                "CodexPoolsCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "CodexManager",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "codex-pools",
            dependencies: ["CodexPoolsCore"],
            path: "CodexPoolsCLI"
        ),
        .testTarget(
            name: "CodexPoolsTests",
            dependencies: ["CodexPoolsCore"]
        )
    ]
)
