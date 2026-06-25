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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "CodexPools",
            dependencies: [
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
        .testTarget(
            name: "CodexPoolsTests",
            dependencies: ["CodexPools"]
        )
    ]
)
