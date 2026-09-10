// swift-tools-version: 6.0
import PackageDescription

// Library-only distribution of upstream SwiftTerm 1.20.0; see UPSTREAM.md.
let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [.target(
        name: "SwiftTerm",
        exclude: ["Mac/README.md"],
        resources: [.process("Apple/Metal/Shaders.metal")]
    )],
    swiftLanguageModes: [.v5]
)
