// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkBootstrap",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "SparkBootstrap", targets: ["SparkBootstrap"])],
    dependencies: [
        .package(path: "../SparkCore"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
        .package(path: "../SparkSecurity"),
        .package(path: "../SparkDiscovery"),
        .package(path: "../SparkAPI"),
        .package(path: "../SparkTransport"),
        // Pin the SSH dependency graph exactly and verify it against source-lock.json before administrator credentials cross the wire.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
    ],
    targets: [
        .target(
            name: "SparkBootstrap",
            dependencies: [
                .product(name: "SparkCore", package: "SparkCore"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "SparkSecurity", package: "SparkSecurity"),
                .product(name: "SparkDiscovery", package: "SparkDiscovery"),
                .product(name: "SparkAPI", package: "SparkAPI"),
                .product(name: "SparkTransport", package: "SparkTransport"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
            ]
        ),
        .testTarget(
            name: "SparkBootstrapTests",
            dependencies: ["SparkBootstrap"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
