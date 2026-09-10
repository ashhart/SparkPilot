import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers

public enum SparkDashboardFreshness: Sendable, Equatable {
    case notLoaded
    case current(refreshedAt: Date)
    case cached(refreshedAt: Date)
    case unavailable
}

public struct CatalogueRefreshConfirmation: Identifiable, Sendable, Equatable {
    public let idempotencyKey: UUID
    public let fileName: String
    public let candidateJSON: String
    public let preview: GeneratedAPI.ModelActionPreview

    public init(
        idempotencyKey: UUID,
        fileName: String,
        candidateJSON: String,
        preview: GeneratedAPI.ModelActionPreview
    ) {
        self.idempotencyKey = idempotencyKey
        self.fileName = fileName
        self.candidateJSON = candidateJSON
        self.preview = preview
    }

    public var id: UUID { idempotencyKey }
    public var canApply: Bool { preview.blockers.isEmpty }
}

public struct ProfileReenableConfirmation: Identifiable, Sendable, Equatable {
    public let idempotencyKey: UUID
    public let modelID: String
    public let modelName: String
    public let profileID: String
    public let profileName: String
    public let preview: GeneratedAPI.ModelActionPreview

    public init(
        idempotencyKey: UUID,
        modelID: String,
        modelName: String,
        profileID: String,
        profileName: String,
        preview: GeneratedAPI.ModelActionPreview
    ) {
        self.idempotencyKey = idempotencyKey
        self.modelID = modelID
        self.modelName = modelName
        self.profileID = profileID
        self.profileName = profileName
        self.preview = preview
    }

    public var id: UUID { idempotencyKey }
    public var canApply: Bool { preview.blockers.isEmpty }
}

extension SparkAPI.Operation.OperationState {
    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }
}
