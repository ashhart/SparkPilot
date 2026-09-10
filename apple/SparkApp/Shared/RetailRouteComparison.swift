import Foundation
import Network
import Observation
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkDesignSystem
import SparkLibrary
import SparkIntents
import SparkSecurity
import SparkTransport
enum RetailRouteComparison {

    static func sameRoute(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.caseInsensitiveCompare(rhs.scheme ?? "") == .orderedSame
            && lhs.host?.caseInsensitiveCompare(rhs.host ?? "") == .orderedSame
            && lhs.port == rhs.port
    }
}
