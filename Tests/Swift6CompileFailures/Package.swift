// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Swift6CompileFailures",
    platforms: [.macOS(.v11)],
    dependencies: [.package(name: "MostlyGoodMetrics", path: "../..")],
    targets: [
        .executableTarget(
            name: "CustomActorFlush",
            dependencies: [.product(name: "MostlyGoodMetrics", package: "MostlyGoodMetrics")],
            path: "Sources"
        )
    ]
)
