// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkLanguageModel",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkLanguageModel",
            targets: ["SparkLanguageModel"]
        )
    ],
    dependencies: [
        .package(path: "../SparkCore"),
        .package(path: "../SparkAPI"),
    ],
    targets: [
        .target(
            name: "SparkLanguageModel",
            dependencies: ["SparkCore", "SparkAPI"]
        ),
        .testTarget(
            name: "SparkLanguageModelTests",
            dependencies: ["SparkLanguageModel"]
        ),
    ]
)
