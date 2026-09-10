// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkAPI",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkAPI",
            targets: ["SparkAPI"]
        )
    ],
    dependencies: [
        .package(path: "../SparkCore"),
        .package(path: "../SparkTransport"),
        .package(path: "../SparkSecurity"),
    ],
    targets: [
        .target(
            name: "SparkAPI",
            dependencies: [
                .product(name: "SparkCore", package: "SparkCore"),
                .product(name: "SparkTransport", package: "SparkTransport"),
                .product(name: "SparkSecurity", package: "SparkSecurity"),
            ]
        ),
        .testTarget(
            name: "SparkAPITests",
            dependencies: ["SparkAPI"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
