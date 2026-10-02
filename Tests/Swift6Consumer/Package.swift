// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Swift6Consumer",
    platforms: [.macOS(.v11)],
    dependencies: [.package(name: "MostlyGoodMetrics", path: "../..")],
    targets: [
        .executableTarget(
            name: "Swift6Consumer",
            dependencies: [.product(name: "MostlyGoodMetrics", package: "MostlyGoodMetrics")],
            path: "Sources"
        )
    ]
)
