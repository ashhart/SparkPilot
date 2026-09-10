import CryptoKit
import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

// MARK: - The read-only preflight (§10.2 steps 5-7, §11.2 Mode B)

/// Model a foreign listener occupying the runtime port before Spark Runtime is installed.
let installerTestOccupiedPortSurvey = """
    survey=1
    os=DGX OS 7.2
    runtime_package=absent
    listening=22,443,7443
    """
