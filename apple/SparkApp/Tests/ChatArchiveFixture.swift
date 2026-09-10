import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import SwiftUI
import Testing
@testable import SparkAppComposition

@MainActor
final class ChatTestChatArchiveMemoryStore: SparkChatStoring {
    var archive = SparkChatArchive()
    var fails = false
    func load() throws -> SparkChatArchive { archive }
    func save(_ archive: SparkChatArchive) throws {
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        self.archive = archive
    }
}
