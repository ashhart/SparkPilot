import Foundation
import SparkCore
import SwiftUI

/// Distinguish operations requested by this device using its local ID without retaining the full device roster.
public enum OperationOrigin: Equatable, Sendable {
    case thisDevice
    case anotherDevice

    public var label: String {
        switch self {
        case .thisDevice: return String(localized: "Started here")
        case .anotherDevice: return String(localized: "Started on another device")
        }
    }
}

/// View state for one durable operation (§62.3).
public struct OperationCardState: Equatable, Sendable {
    public let id: SparkOperationID
    public let kind: String
    public let state: SparkOperationState
    public let stage: String?
    public let progress: Double?
    public let cancellable: Bool
    public let hasPartialWorkLoss: Bool
    /// Retain the runtime's failure reason for Activity presentation.
    public let errorCode: String?
    /// Which Spark this ran on, for a list that spans more than one.
    public let targetName: String?
    /// When the Spark accepted, began and finished the work.
    public let createdAt: Date?
    public let startedAt: Date?
    public let completedAt: Date?
    /// Where the request came from, when it can be told apart.
    public let origin: OperationOrigin?

    /// Prefer completion, then start, then request time when ordering the timeline (§41.8).
    public var mostRecentInstant: Date? { completedAt ?? startedAt ?? createdAt }

    public init(
        id: SparkOperationID,
        kind: String,
        state: SparkOperationState,
        stage: String?,
        progress: Double?,
        cancellable: Bool,
        hasPartialWorkLoss: Bool = false,
        errorCode: String? = nil,
        targetName: String? = nil,
        createdAt: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        origin: OperationOrigin? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.stage = stage
        self.progress = progress
        self.cancellable = cancellable
        self.hasPartialWorkLoss = hasPartialWorkLoss
        self.errorCode = errorCode
        self.targetName = targetName
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.origin = origin
    }

    /// The instant a card should date itself by.
    public var timestamp: Date? { completedAt ?? startedAt ?? createdAt }

    /// How long a finished operation took, when both ends are known.
    public var duration: TimeInterval? {
        guard let completedAt, let start = startedAt ?? createdAt else { return nil }
        let elapsed = completedAt.timeIntervalSince(start)
        return elapsed >= 0 ? elapsed : nil
    }

    public var isActive: Bool {
        switch state {
        case .requested, .validating, .queued, .running, .waitingForApproval, .cancelling:
            return true
        case .cancelled, .succeeded, .failed:
            return false
        }
    }
}

/// §62.3 presentation: action title, stage copy, safe-cancel wording.
public enum OperationPresentation {
    /// Name known durable operation kinds and humanize unknown stable identifiers.
    public static func title(kind: String) -> String {
        switch kind {
        case "model.install": return String(localized: "Downloading model")
        case "model.load": return String(localized: "Loading model")
        case "model.unload": return String(localized: "Unloading model")
        case "runtime.update": return String(localized: "Updating runtime")
        case "project.agent": return String(localized: "Running agent")
        case "project.create": return String(localized: "Creating project")
        case "project.delete": return String(localized: "Deleting project")
        case "system.software_update_check": return String(localized: "Checking for updates")
        case "system.software_updates": return String(localized: "Installing system updates")
        default: return humanisedKind(kind)
        }
    }

    /// Humanize unknown operation identifiers for fallback display.
    private static func humanisedKind(_ kind: String) -> String {
        let spaced =
            kind
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !spaced.isEmpty else { return String(localized: "Operation") }
        return spaced.prefix(1).localizedUppercase + spaced.dropFirst()
    }

    /// Use catalogue fallback copy for unknown operation stages rather than displaying untranslated wire tokens.
    public static func stageLabel(_ stage: String?) -> String {
        switch stage {
        // Install and materialisation.
        case "validating", "validation": return String(localized: "Validating")
        case "disk_preflight": return String(localized: "Checking storage")
        case "downloading": return String(localized: "Downloading")
        case "verifying": return String(localized: "Verifying integrity")
        case "materialising", "materialise": return String(localized: "Finalising")
        // Model load, including replacing a running model.
        case "pending": return String(localized: "Preparing")
        case "draining_previous": return String(localized: "Finishing current requests")
        case "stopping_previous": return String(localized: "Stopping the running model")
        case "preparing_engine_image": return String(localized: "Preparing vLLM engine")
        case "starting": return String(localized: "Starting vLLM service")
        case "loading": return String(localized: "Loading model")
        case "health_check": return String(localized: "Health check")
        case "serving_probe": return String(localized: "Checking the model responds")
        case "ready": return String(localized: "Ready")
        case "restoring_previous_engine": return String(localized: "Restoring the previous model")
        // Model unload.
        case "draining": return String(localized: "Draining")
        case "stopping": return String(localized: "Stopping the model")
        case "verifying_memory_recovery": return String(localized: "Verifying memory was released")
        case "unloaded": return String(localized: "Stopped")
        // Runtime update.
        case "system_update_installing": return String(localized: "Installing OS updates")
        case "runtime_update_scheduling": return String(localized: "Scheduling the update")
        case "runtime_update_restarting": return String(localized: "Restarting Spark Runtime")
        case "running": return String(localized: "Running")
        default: return String(localized: "Working")
        }
    }

    /// Show indeterminate activity when work continues without measurable progress.
    public static func showsIndeterminateActivity(_ state: OperationCardState) -> Bool {
        state.isActive && state.progress == nil
    }

    /// Express every operation state in words as well as colour (§51.1).
    public static func stateLabel(_ state: SparkOperationState) -> String {
        switch state {
        case .succeeded: return String(localized: "Completed")
        case .failed: return String(localized: "Failed. View details.")
        case .cancelled: return String(localized: "Cancelled")
        default: return String(localized: "In progress")
        }
    }

    /// §62.3 requires the card to say what happens if the app closes.
    public static func closingCopy(_ state: OperationCardState) -> String? {
        guard state.isActive else { return nil }
        return String(
            localized: "This continues on the Spark if you close SparkPilot."
        )
    }

    public static func cancelCopy(_ state: OperationCardState) -> String {
        if state.hasPartialWorkLoss {
            return String(localized: "Cancelling will discard the partial download.")
        }
        return String(localized: "Cancel this operation?")
    }

    /// Announce operation percentage together with its current stage (§51.1).
    public static func progressAccessibilityLabel(
        _ state: OperationCardState
    ) -> LocalizedStringResource {
        let name = title(kind: state.kind)
        let stage = stageLabel(state.stage)
        guard let progress = state.progress, state.isActive else {
            // Announce the current stage when measurable progress is unavailable.
            return .operationProgress(title: name, stage: stage)
        }
        return .operationProgressPercent(
            title: name,
            percent: Int((progress * 100).rounded()),
            stage: stage
        )
    }

    public static func prefersStackedHeader(usesAccessibilityTextSize: Bool) -> Bool {
        usesAccessibilityTextSize
    }

    /// Use deterministic product-owned relative-time wording.
    public static func relativeTime(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        // Treat timestamps within one minute of device time as now to tolerate small clock skew.
        guard elapsed >= 60 else { return String(localized: "just now") }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return String(localized: .elapsedMinutesAgo(minutes)) }
        let hours = minutes / 60
        if hours < 24 { return String(localized: .elapsedHoursAgo(hours)) }
        let days = hours / 24
        if days < 7 { return String(localized: .elapsedDaysAgo(days)) }
        let weeks = days / 7
        if weeks < 5 { return String(localized: .elapsedWeeksAgo(weeks)) }
        let months = days / 30
        if months < 12 { return String(localized: .elapsedMonthsAgo(months)) }
        return String(localized: .elapsedYearsAgo(days / 365))
    }

    /// How long a job took, for a card that has finished.
    public static func durationText(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return String(localized: .durationSeconds(max(whole, 1))) }
        let minutes = whole / 60
        let remainder = whole % 60
        if minutes < 60 {
            return remainder == 0
                ? String(localized: .durationMinutes(minutes))
                : String(localized: .durationMinutesSeconds(minutes: minutes, seconds: remainder))
        }
        let hours = minutes / 60
        let leftoverMinutes = minutes % 60
        return leftoverMinutes == 0
            ? String(localized: .durationHours(hours))
            : String(localized: .durationHoursMinutes(hours: hours, minutes: leftoverMinutes))
    }

    /// Omit unavailable timing or origin details and hide an entirely empty footnote.
    public static func provenanceText(_ state: OperationCardState, now: Date) -> String? {
        var parts: [String] = []
        if let timestamp = state.timestamp {
            let when = relativeTime(timestamp, now: now)
            switch state.state {
            case .succeeded: parts.append(String(localized: .activityCompletedWhen(when)))
            case .failed: parts.append(String(localized: .activityFailedWhen(when)))
            case .cancelled: parts.append(String(localized: .activityCancelledWhen(when)))
            default: parts.append(String(localized: .activityStartedWhen(when)))
            }
        }
        if !state.isActive, let duration = state.duration {
            parts.append(String(localized: .activityTook(durationText(duration))))
        }
        if let origin = state.origin {
            // "Started here" reads oddly after "Completed 3 minutes ago".
            parts.append(state.timestamp == nil ? origin.label : originSuffix(origin))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func originSuffix(_ origin: OperationOrigin) -> String {
        switch origin {
        case .thisDevice: return String(localized: "from here")
        case .anotherDevice: return String(localized: "from another device")
        }
    }

    /// Name known failure codes and humanize unfamiliar stable identifiers.
    public static func failureText(_ code: String) -> String {
        switch code {
        case "MODEL_INSUFFICIENT_MEMORY":
            return String(localized: "the profile did not fit in memory")
        case "MEMORY_PRESSURE_ACTIVE":
            return String(localized: "the Spark was short of memory")
        case "MEMORY_GUARD_STOP_FAILED":
            return String(localized: "the memory guard could not stop the model")
        case "MODEL_PROFILE_UNSAFE":
            return String(localized: "the profile is disabled after a memory event")
        case "RUNTIME_UPDATE_ROLLED_BACK":
            return String(localized: "the update was rolled back")
        case "RUNTIME_UPDATE_STATUS_TIMEOUT", "SYSTEM_UPDATE_STATUS_TIMEOUT":
            return String(localized: "the Spark was still working when the app stopped waiting")
        case "SYSTEM_UPDATE_FAILED":
            return String(localized: "an OS update step failed")
        case "UPDATE_SYSTEM_WORKER_LOST":
            return String(localized: "the update worker stopped without reporting")
        case "OPERATION_CANCELLED":
            return String(localized: "it was cancelled")
        case "backend_error":
            return String(localized: "the Spark's privileged helper refused it")
        default:
            return String(localized: .operationReported(code))
        }
    }
}

/// The Activity screen (§41.8): a unified operations timeline.
public struct ActivityListView: View {
    public let operations: [OperationCardState]
    /// Share one list clock so relative-time labels advance without new operation data.
    @State private var now = Date()

    public init(operations: [OperationCardState]) {
        self.operations = operations
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                if operations.isEmpty {
                    ContentUnavailableView(
                        "No Activity",
                        systemImage: "clock",
                        description: Text("Durable jobs and downloads appear here.")
                    )
                    .padding(.top, 80)
                } else {
                    ForEach(operations, id: \.id.rawValue) { operation in
                        OperationCardView(state: operation, now: now)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Activity")
        .task {
            // Refresh minute-granularity labels every thirty seconds.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// Present each operation's stage, measurable progress and permitted cancellation action.
public struct OperationCardView: View {
    public let state: OperationCardState
    /// Inject a shared reference instant so every card uses the same testable list clock.
    public let now: Date
    /// §62.3's safe cancellation; absent where the surface cannot cancel.
    public let onCancel: (@MainActor () -> Void)?
    /// §62.3's relevant recovery action for a failed job.
    public let onRecover: (@MainActor () -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var confirmingCancel = false
    @State private var copiedOperationID = false

    public init(
        state: OperationCardState,
        now: Date = Date(),
        onCancel: (@MainActor () -> Void)? = nil,
        onRecover: (@MainActor () -> Void)? = nil
    ) {
        self.state = state
        self.now = now
        self.onCancel = onCancel
        self.onRecover = onRecover
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if OperationPresentation.prefersStackedHeader(
                usesAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
            ) {
                stackedHeader
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalHeader
                    stackedHeader
                }
            }
            if state.isActive, let stage = state.stage {
                Text(OperationPresentation.stageLabel(stage))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(terminalCopy)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let closing = OperationPresentation.closingCopy(state) {
                Text(closing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let provenance = OperationPresentation.provenanceText(state, now: now) {
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            technicalDetails
            actions
        }
        .padding(SparkSpacing.regular)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: SparkRadius.compact, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .confirmationDialog(
            Text(verbatim: OperationPresentation.cancelCopy(state)),
            isPresented: $confirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel This Job", role: .destructive) { onCancel?() }
            Button("Keep Running", role: .cancel) {}
        }
    }

    /// §62.3's technical-details disclosure, including a copyable operation ID.
    private var technicalDetails: some View {
        DisclosureGroup {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: state.id.rawValue.uuidString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: SparkSpacing.small)
                Button {
                    SparkPasteboard.copy(state.id.rawValue.uuidString)
                    copiedOperationID = true
                } label: {
                    Label(
                        copiedOperationID ? "Copied" : "Copy Job ID",
                        systemImage: copiedOperationID ? "checkmark" : "doc.on.doc"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy this job's identifier")
            }
            if let code = state.errorCode, !code.isEmpty {
                Text(verbatim: code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } label: {
            Text("Technical details")
        }
        .font(.caption)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: SparkSpacing.compact) {
            if state.isActive, state.cancellable, onCancel != nil {
                Button("Cancel", systemImage: "xmark.circle") { confirmingCancel = true }
                    .buttonStyle(.bordered)
            }
            if state.state == .failed, onRecover != nil {
                Button("Try Again", systemImage: "arrow.clockwise") { onRecover?() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(minHeight: state.isActive || state.state == .failed ? nil : 0)
    }

    private var horizontalHeader: some View {
        HStack {
            operationTitle
            Spacer(minLength: 12)
            operationProgress
        }
    }

    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            operationTitle
            operationProgress
        }
    }

    private var operationTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(OperationPresentation.title(kind: state.kind))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let targetName = state.targetName {
                Text(targetName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var operationProgress: some View {
        if let progress = state.progress, state.isActive {
            ProgressView(value: progress)
                .frame(maxWidth: 180)
                .accessibilityLabel(
                    Text(OperationPresentation.progressAccessibilityLabel(state))
                )
        } else if OperationPresentation.showsIndeterminateActivity(state) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(
                    Text(OperationPresentation.progressAccessibilityLabel(state))
                )
        }
    }

    private var terminalCopy: String {
        switch state.state {
        case .succeeded: return String(localized: "Completed")
        case .failed:
            guard let code = state.errorCode, !code.isEmpty else {
                return String(localized: "Failed. The Spark gave no reason.")
            }
            let reason = OperationPresentation.failureText(code)
            return String(localized: .operationFailed(reason))
        case .cancelled: return String(localized: "Cancelled")
        default: return String(localized: "In progress")
        }
    }

    private var accessibilitySummary: String {
        let title = OperationPresentation.title(kind: state.kind)
        let stage = state.stage.map(OperationPresentation.stageLabel) ?? terminalCopy
        var parts = [title]
        if let targetName = state.targetName { parts.append(targetName) }
        parts.append(stage)
        if let progress = state.progress, state.isActive {
            parts.append(String(localized: .percentComplete(SparkPercent.string(progress))))
        }
        if let provenance = OperationPresentation.provenanceText(state, now: now) {
            parts.append(provenance.replacingOccurrences(of: " · ", with: ", "))
        }
        return parts.joined(separator: ", ")
    }
}
