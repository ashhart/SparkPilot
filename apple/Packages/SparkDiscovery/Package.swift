// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkDiscovery",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkDiscovery",
            targets: ["SparkDiscovery"]
        )
    ],
    dependencies: [
        .package(path: "../SparkCore")
    ],
    targets: [
        .target(
            name: "SparkDiscovery",
            dependencies: [.product(name: "SparkCore", package: "SparkCore")]
        ),
        .testTarget(
            name: "SparkDiscoveryTests",
            dependencies: ["SparkDiscovery"]
        ),
    ]
)
