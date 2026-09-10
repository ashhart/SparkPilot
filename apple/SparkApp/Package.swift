// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SparkAppComposition",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .watchOS(.v26),
    ],
    products: [
        .library(name: "SparkWatchSupport", targets: ["SparkWatchSupport"]),
        .library(name: "SparkAppComposition", targets: ["SparkAppComposition"]),
        .library(name: "SparkWidgetSupport", targets: ["SparkWidgetSupport"]),
    ],
    dependencies: [
        .package(path: "../Packages/SparkCore"),
        .package(path: "../Packages/SparkDiscovery"),
        .package(path: "../Packages/SparkDesignSystem"),
        .package(path: "../Packages/SparkAPI"),
        .package(path: "../Packages/SparkTransport"),
        .package(path: "../Packages/SparkSecurity"),
        .package(path: "../Packages/SparkLibrary"),
        .package(path: "../Packages/SparkBootstrap"),
        .package(path: "../Packages/SparkLanguageModel"),
        .package(path: "../Packages/SparkIntelligence"),
        .package(path: "../Packages/SparkIntents"),
        .package(path: "../Packages/SparkProjects"),
    ],
    targets: [
        .target(name: "SparkWatchSupport", path: "WatchShared"),
        .testTarget(
            name: "SparkWatchSupportTests",
            dependencies: ["SparkWatchSupport"],
            path: "WatchTests"
        ),
        .target(name: "SparkWidgetSupport", path: "WidgetShared"),
        .target(
            name: "SparkAppComposition",
            dependencies: [
                "SparkWidgetSupport", "SparkWatchSupport",
                "SparkCore", "SparkDiscovery", "SparkDesignSystem", "SparkAPI", "SparkSecurity",
                "SparkLibrary", "SparkBootstrap", "SparkTransport", "SparkLanguageModel",
                "SparkIntelligence",
                "SparkIntents",
                "SparkProjects",
            ],
            path: "Shared",
            exclude: [
                "Info.plist", "SparkApp.entitlements", "SparkApp.CarPlay.entitlements",
                "Assets.xcassets",
            ],
            resources: [
                .process("Resources/release-keys.json"), .process("Resources/model-presets.json"),
                .copy("Resources/RuntimeRelease"),
            ]
        ),
        .testTarget(
            name: "SparkAppCompositionTests",
            dependencies: [
                "SparkAppComposition", "SparkAPI", "SparkIntents", "SparkWidgetSupport",
            ],
            path: "Tests",
            resources: [.process("Fixtures")]
        ),
    ]
)
