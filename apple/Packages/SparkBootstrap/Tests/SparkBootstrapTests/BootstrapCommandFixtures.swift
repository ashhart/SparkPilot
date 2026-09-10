import CryptoKit
import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

// MARK: - What runs before the package exists

/// Inspect rendered command order so installer binaries cannot be invoked before the package installs them.
func installerTestRenderedLines(_ commands: [BootstrapCommand]) throws -> [String] {
    let parameters = try BootstrapCommand.Parameters(
        operationID: UUID(uuidString: "8ADF6E19-1E1F-4A2C-9A62-4B3E9E2E0C11")!,
        artifactName: "spark-runtime_0.1.0-1_arm64.deb",
        sha256: String(repeating: "a", count: 64),
        size: 4096
    )
    return commands.map { $0.line(parameters) }
}

let installerTestInstallerPath = "/usr/lib/spark-runtime/spark-installer"
