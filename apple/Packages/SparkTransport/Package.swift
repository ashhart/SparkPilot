// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkTransport",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkTransport",
            targets: ["SparkTransport"]
        )
    ],
    dependencies: [
        .package(path: "../SparkCore")
    ],
    targets: [
        .target(
            name: "SparkTransport",
            dependencies: [.product(name: "SparkCore", package: "SparkCore")]
        ),
        .testTarget(
            name: "SparkTransportTests",
            dependencies: ["SparkTransport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
