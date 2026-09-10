// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkIntelligence",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkIntelligence",
            targets: ["SparkIntelligence"]
        )
    ],
    dependencies: [
        .package(path: "../SparkCore")
    ],
    targets: [
        .target(
            name: "SparkIntelligence",
            dependencies: ["SparkCore"]
        ),
        .testTarget(
            name: "SparkIntelligenceTests",
            dependencies: ["SparkIntelligence"]
        ),
    ]
)
