// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkDesignSystem",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkDesignSystem",
            targets: ["SparkDesignSystem"]
        )
    ],
    dependencies: [
        .package(path: "../SparkCore")
    ],
    targets: [
        .target(
            name: "SparkDesignSystem",
            dependencies: [.product(name: "SparkCore", package: "SparkCore")],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SparkDesignSystemTests",
            dependencies: ["SparkDesignSystem"]
        ),
    ]
)
