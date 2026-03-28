// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AnovaBar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "AnovaBar",
            targets: ["AnovaBar"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "AnovaBar",
            path: "Sources/AnovaBar"
        ),
    ]
)
