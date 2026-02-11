// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Siftly",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Siftly", targets: ["Siftly"]),
        .executable(name: "SiftlyHelper", targets: ["SiftlyHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "SiftlyShared",
            path: "Sources/SiftlyShared"
        ),
        .executableTarget(
            name: "Siftly",
            dependencies: ["Yams", "SiftlyShared"],
            path: "Sources/Siftly"
        ),
        .executableTarget(
            name: "SiftlyHelper",
            dependencies: ["SiftlyShared"],
            path: "Sources/SiftlyHelper"
        )
    ]
)
