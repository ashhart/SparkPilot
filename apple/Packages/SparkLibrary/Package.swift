// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkLibrary",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkLibrary",
            targets: ["SparkLibrary"]
        )
    ],
    dependencies: [
        .package(path: "../SparkCore"),
        .package(path: "../SparkAPI"),
        // Use the shared SparkTransport route-ordering policy (§13.2).
        .package(path: "../SparkTransport"),
    ],
    targets: [
        .target(
            name: "SparkLibrary",
            dependencies: [
                .product(name: "SparkCore", package: "SparkCore"),
                .product(name: "SparkAPI", package: "SparkAPI"),
                .product(name: "SparkTransport", package: "SparkTransport"),
            ]
        ),
        .testTarget(
            name: "SparkLibraryTests",
            dependencies: [
                "SparkLibrary",
                .product(name: "SparkAPI", package: "SparkAPI"),
                .product(name: "SparkTransport", package: "SparkTransport"),
            ],
            path: "Tests/SparkLibraryTests"
        ),
    ]
)
