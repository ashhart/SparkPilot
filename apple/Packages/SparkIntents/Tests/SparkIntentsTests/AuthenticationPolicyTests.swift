import AppIntents
import Testing
@testable import SparkIntents

@Test func mutationsAndPrivateResultsRequireDeviceAuthentication() {
    #expect(LoadSparkModelIntent.authenticationPolicy == .requiresAuthentication)
    #expect(UnloadActiveModelIntent.authenticationPolicy == .requiresAuthentication)
    #expect(GetSparkAnalysisIntent.authenticationPolicy == .requiresAuthentication)
}
