// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkSecurity",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "SparkSecurity",
            targets: ["SparkSecurity"]
        )
    ],
    targets: [
        .target(
            name: "SparkSecurity"
        ),
        .testTarget(
            name: "SparkSecurityTests",
            dependencies: ["SparkSecurity"]
        ),
    ]
)
