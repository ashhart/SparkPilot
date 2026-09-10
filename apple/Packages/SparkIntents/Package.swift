// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkIntents",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkIntents",
            targets: ["SparkIntents"]
        )
    ],
    targets: [
        .target(
            name: "SparkIntents"
        ),
        .testTarget(
            name: "SparkIntentsTests",
            dependencies: ["SparkIntents"]
        ),
    ]
)
