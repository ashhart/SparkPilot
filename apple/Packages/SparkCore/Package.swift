// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkCore",
            targets: ["SparkCore"]
        )
    ],
    targets: [
        .target(
            name: "SparkCore"
        ),
        .testTarget(
            name: "SparkCoreTests",
            dependencies: ["SparkCore"]
        ),
    ]
)
