import SwiftUI

/// Change status mirrored from the runtime's `changes.status` enum (§42.6).
public enum ChangeStatus: String, Sendable, Equatable {
    case creating
    case planning
    case editing
    case review
    case approved
    case rejected
    case merged
    case failed
}

/// One change in the approval UI: task, status, diff/test summary.
public struct ChangeSummaryState: Equatable, Sendable {
    public let id: String
    public let task: String
    public let status: ChangeStatus
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int
    /// nil = no test summary from the runtime yet.
    public let testPassed: Bool?
    public let branch: String

    public init(
        id: String,
        task: String,
        status: ChangeStatus,
        filesChanged: Int,
        insertions: Int,
        deletions: Int,
        testPassed: Bool?,
        branch: String
    ) {
        self.id = id
        self.task = task
        self.status = status
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
        self.testPassed = testPassed
        self.branch = branch
    }
}

public enum ChangeAction: Equatable, Sendable {
    case approveAndReject
    case none
}

/// Resolved copy + which approval actions are enabled for a status.
public struct ChangePresentation: Equatable, Sendable {
    /// Display the owner's task text verbatim without translating user input.
    public let title: String
    public let statusLabel: LocalizedStringResource
    /// An SF Symbol name, never copy.
    public let statusSymbol: String
    public let summaryLine: LocalizedStringResource
    public let actions: ChangeAction
    public let suggestedRejectCopy: LocalizedStringResource

    public init(
        title: String,
        statusLabel: LocalizedStringResource,
        statusSymbol: String,
        summaryLine: LocalizedStringResource,
        actions: ChangeAction,
        suggestedRejectCopy: LocalizedStringResource
    ) {
        self.title = title
        self.statusLabel = statusLabel
        self.statusSymbol = statusSymbol
        self.summaryLine = summaryLine
        self.actions = actions
        self.suggestedRejectCopy = suggestedRejectCopy
    }
}

public enum ChangePresentationResolver {
    /// Offer approval decisions only during review and keep terminal states read-only (§42.6).
    public static func resolve(_ state: ChangeSummaryState) -> ChangePresentation {
        let label: LocalizedStringResource
        let symbol: String
        let actions: ChangeAction
        switch state.status {
        case .creating:
            label = .changeCreating
            symbol = "hammer"
            actions = ChangeAction.none
        case .planning:
            label = .changePlanning
            symbol = "square.and.pencil"
            actions = ChangeAction.none
        case .editing:
            label = .changeEditing
            symbol = "pencil"
            actions = ChangeAction.none
        case .review:
            label = .changeReviewReady
            symbol = "checkmark.seal"
            actions = .approveAndReject
        case .approved:
            label = .changeApproved
            symbol = "checkmark.circle"
            actions = ChangeAction.none
        case .merged:
            label = .changeMerged
            symbol = "checkmark.circle.fill"
            actions = ChangeAction.none
        case .rejected:
            label = .changeRejected
            symbol = "xmark.circle"
            actions = ChangeAction.none
        case .failed:
            label = .changeFailed
            symbol = "exclamationmark.triangle"
            actions = ChangeAction.none
        }

        // Compose pluralised catalogue parts without concatenating untranslated suffixes.
        let files = String(localized: .changeFilesChanged(state.filesChanged))
        var summary: LocalizedStringResource = .changeFilesOnly(files)
        if state.filesChanged > 0 {
            summary = .changeCounts(
                files: files,
                insertions: state.insertions,
                deletions: state.deletions
            )
        }
        if let testPassed = state.testPassed {
            summary = .changeCountsWithTests(
                files: String(localized: summary),
                tests: String(localized: testPassed ? .changeTestsPassed : .changeTestsFailed)
            )
        }

        return ChangePresentation(
            title: state.task,
            statusLabel: label,
            statusSymbol: symbol,
            summaryLine: summary,
            actions: actions,
            suggestedRejectCopy: .changeRejectCopy
        )
    }
}

/// One parsed unified-diff line.
public struct DiffLine: Equatable, Sendable {
    public enum Prefix: Sendable, Equatable {
        case addition
        case deletion
        case context
        case position  // @@ hunk header
    }

    public let prefix: Prefix
    public let text: String

    public init(prefix: Prefix, text: String) {
        self.prefix = prefix
        self.text = text
    }
}

public enum DiffParser {
    /// Bound parsed diff output by maxLines while preserving additions, deletions, context and hunk headers.
    public static func parse(unifiedDiff: String, maxLines: Int = 1000) -> [DiffLine] {
        guard maxLines > 0 else { return [] }
        var lines: [DiffLine] = []
        for rawLine in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            if rawLine.hasPrefix("\\") { continue }
            if lines.count >= maxLines { break }
            let prefix: DiffLine.Prefix
            let text: String
            if rawLine.hasPrefix("@@") {
                prefix = .position
                text = String(rawLine)
            } else if rawLine.hasPrefix("+") {
                prefix = .addition
                text = String(rawLine.dropFirst())
            } else if rawLine.hasPrefix("-") {
                prefix = .deletion
                text = String(rawLine.dropFirst())
            } else if rawLine.hasPrefix(" ") {
                prefix = .context
                text = String(rawLine.dropFirst())
            } else {
                prefix = .context
                text = String(rawLine)
            }
            lines.append(DiffLine(prefix: prefix, text: text))
        }
        return lines
    }
}

/// Announce diff file, hunk and change counts with spoken prefixes and glyphs independent of colour (§51.1).
public enum DiffAccessibility {
    /// Additions, removals and hunks in one parsed diff.
    public struct Counts: Equatable, Sendable {
        public let additions: Int
        public let removals: Int
        public let hunks: Int

        public init(additions: Int, removals: Int, hunks: Int) {
            self.additions = additions
            self.removals = removals
            self.hunks = hunks
        }
    }

    public static func counts(_ lines: [DiffLine]) -> Counts {
        Counts(
            additions: lines.filter { $0.prefix == .addition }.count,
            removals: lines.filter { $0.prefix == .deletion }.count,
            hunks: lines.filter { $0.prefix == .position }.count
        )
    }

    /// Pluralise each diff count independently and include the file path only when known.
    public static func summary(file: String?, lines: [DiffLine]) -> LocalizedStringResource {
        let counted = counts(lines)
        let additions = String(localized: .diffAdditions(counted.additions))
        let removals = String(localized: .diffRemovals(counted.removals))
        let hunks = String(localized: .diffHunks(counted.hunks))
        guard let file, !file.isEmpty else {
            return .diffSummary(additions: additions, removals: removals, hunks: hunks)
        }
        return .diffSummaryForFile(
            file: file,
            additions: additions,
            removals: removals,
            hunks: hunks
        )
    }

    /// Announce whether a diff line adds or removes text independently of its contents.
    public static func lineLabel(_ line: DiffLine) -> LocalizedStringResource {
        switch line.prefix {
        case .addition: .diffAddedLine(line.text)
        case .deletion: .diffRemovedLine(line.text)
        case .position: .diffHunkLine(line.text)
        case .context: .diffContextLine(line.text)
        }
    }

    /// The glyph shown beside a line, so the state is not colour alone.
    public static func glyph(_ prefix: DiffLine.Prefix) -> String {
        switch prefix {
        case .addition: "+"
        case .deletion: "-"
        case .position: "@"
        case .context: " "
        }
    }
}

/// Expose diff changes through glyphs and accessibility labels as well as colour.
public struct MiniDiffView: View {
    public let lines: [DiffLine]
    public let file: String?

    public init(lines: [DiffLine], file: String? = nil) {
        self.lines = lines
        self.file = file
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: DiffAccessibility.glyph(line.prefix))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(foreground(line.prefix))
                            .accessibilityHidden(true)
                        Text(verbatim: line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(foreground(line.prefix))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(background(line.prefix))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(DiffAccessibility.lineLabel(line)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .accessibilityLabel(Text(DiffAccessibility.summary(file: file, lines: lines)))
    }

    private func foreground(_ prefix: DiffLine.Prefix) -> Color {
        switch prefix {
        case .addition: .green
        case .deletion: .red
        case .position: .secondary
        case .context: .primary
        }
    }

    private func background(_ prefix: DiffLine.Prefix) -> Color {
        switch prefix {
        case .addition: .green.opacity(0.12)
        case .deletion: .red.opacity(0.12)
        case .position, .context: .clear
        }
    }
}

/// Approval surface for one change: summary + diff + Approve/Reject bar.
public struct ApprovalCardView: View {
    public let state: ChangeSummaryState
    public let diff: [DiffLine]
    public var approve: () -> Void
    public var reject: () -> Void

    public init(
        state: ChangeSummaryState,
        diff: [DiffLine] = [],
        approve: @escaping () -> Void = {},
        reject: @escaping () -> Void = {}
    ) {
        self.state = state
        self.diff = diff
        self.approve = approve
        self.reject = reject
    }

    public var body: some View {
        let presentation = ChangePresentationResolver.resolve(state)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: presentation.statusSymbol)
                Text(ChangePresentationResolver.resolve(state).title)
                    .font(.headline)
                Spacer()
                Text(ChangePresentationResolver.resolve(state).statusLabel)
                    .font(.caption.weight(.semibold))
            }
            Text(presentation.summaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !diff.isEmpty {
                MiniDiffView(lines: diff)
                    .frame(maxHeight: 180)
            }
            if presentation.actions == .approveAndReject {
                HStack {
                    Button("Reject", role: .destructive, action: reject)
                    Spacer()
                    Button("Approve & merge", action: approve)
                        .buttonStyle(.borderedProminent)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}
