// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkProjects",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkProjects",
            targets: ["SparkProjects"]
        )
    ],
    dependencies: [
        .package(path: "../SparkAPI"),
        .package(path: "../SparkDesignSystem"),
        .package(path: "../../Vendor/SwiftTerm"),
    ],
    targets: [
        .target(
            name: "SparkProjects",
            dependencies: [
                "SparkAPI", "SparkDesignSystem", .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "SparkProjectsTests",
            dependencies: ["SparkProjects", "SparkAPI"]
        ),
    ]
)
