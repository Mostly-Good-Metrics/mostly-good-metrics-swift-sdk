// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MostlyGoodMetrics",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14),
        .watchOS(.v7)
    ],
    products: [
        .library(
            name: "MostlyGoodMetrics",
            targets: ["MostlyGoodMetrics"]
        ),
    ],
    targets: [
        .target(
            name: "MostlyGoodMetrics",
            dependencies: [],
            path: "Sources/MostlyGoodMetrics"
        ),
        .testTarget(
            name: "MostlyGoodMetricsTests",
            dependencies: ["MostlyGoodMetrics"],
            path: "Tests/MostlyGoodMetricsTests"
        ),
    ]
)
