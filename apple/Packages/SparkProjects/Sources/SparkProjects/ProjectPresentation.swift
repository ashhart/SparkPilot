import SparkAPI
import SparkDesignSystem
import SwiftUI

public enum ProjectDiffPresentation {
    public static func visibleLine(_ line: GeneratedAPI.ProjectDiffLine) -> String {
        let marker =
            switch line.kind {
            case .addition: "+"
            case .deletion: "−"
            case .context: " "
            }
        return "\(marker) \(line.content)"
    }

    public static func colour(_ kind: GeneratedAPI.ProjectDiffLineKind) -> Color {
        switch kind {
        case .addition: .green
        case .deletion: .red
        case .context: .primary
        }
    }
}

enum ProjectPresentation {
    static func state(_ state: GeneratedAPI.ProjectState) -> String {
        switch state {
        case .creating: String(localized: "Creating")
        case .ready: String(localized: "Ready")
        case .stopped: String(localized: "Stopped")
        case .failed: String(localized: "Failed")
        case .deleting: String(localized: "Deleting")
        }
    }

    static func changeStatus(_ status: GeneratedAPI.ProjectChangeStatus) -> String {
        switch status {
        case .creating: String(localized: "Creating")
        case .planning: String(localized: "Planning")
        case .editing: String(localized: "Editing")
        case .review: String(localized: "Ready for review")
        case .approved: String(localized: "Approved")
        case .rejected: String(localized: "Changes requested")
        case .merged: String(localized: "Merged")
        case .failed: String(localized: "Failed")
        }
    }

    static func tool(_ tool: GeneratedAPI.ProjectToolEvidenceTool) -> String {
        switch tool {
        case .readFile: String(localized: "Read file")
        case .searchFiles: String(localized: "Search files")
        case .writeFile: String(localized: "Write file")
        case .deleteFile: String(localized: "Delete file")
        case .runCommand: String(localized: "Run command")
        case .git: String(localized: "Git")
        }
    }

    static func outcome(_ outcome: GeneratedAPI.ProjectToolEvidenceOutcome) -> String {
        switch outcome {
        case .ok: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .denied: String(localized: "Denied")
        }
    }
}
