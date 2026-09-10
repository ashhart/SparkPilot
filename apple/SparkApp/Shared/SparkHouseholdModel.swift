import Foundation
import Observation
import SparkAPI

struct SparkHouseholdDraft: Identifiable, Equatable {
    let id: String
    let revision: Int
    var title: String
    var body: String

    init(note: GeneratedAPI.HouseholdNote? = nil) {
        id = note?.id ?? UUID().uuidString
        revision = note?.revision ?? 0
        title = note?.title ?? ""
        body = note?.body ?? ""
    }

    var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.utf8.count <= 240 && body.utf8.count <= 16_384
    }

    func request(delete: Bool = false) -> GeneratedAPI.HouseholdNoteRequest {
        .init(id: id, expectedRevision: revision, title: title, body: body, delete: delete)
    }
}

@MainActor
@Observable
final class SparkHouseholdModel {
    private(set) var snapshot: GeneratedAPI.HouseholdSnapshot?
    private(set) var isLoading = false
    private(set) var isChanging = false
    private(set) var errorMessage: String?
    private let service: any SparkHouseholdProviding
    // Retry an uncertain response with the same key, but never reuse it for different text.
    private var pendingNote: (GeneratedAPI.HouseholdNoteRequest, UUID)?
    private var pendingMember: (GeneratedAPI.HouseholdMemberRequest, UUID)?

    init(service: any SparkHouseholdProviding) { self.service = service }

    func refresh() async {
        guard !isLoading, !isChanging else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await service.snapshot()
            errorMessage = nil
        } catch { handle(error) }
    }

    @discardableResult
    func save(_ draft: SparkHouseholdDraft, delete: Bool = false) async -> Bool {
        guard !isChanging, !isLoading, delete || draft.canSave else { return false }
        isChanging = true
        defer { isChanging = false }
        let request = draft.request(delete: delete)
        let key = pendingNote.flatMap { $0.0 == request ? $0.1 : nil } ?? UUID()
        pendingNote = (request, key)
        do {
            try await service.save(request, key: key)
            pendingNote = nil
            // The mutation succeeded even if refreshing the list fails; do not offer a duplicate save.
            snapshot = nil
            do {
                snapshot = try await service.snapshot()
                errorMessage = nil
            } catch { handle(error) }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func setMember(_ member: GeneratedAPI.HouseholdMember) async {
        guard !isChanging, !isLoading, snapshot?.canManageMembers == true,
            !member.administrator
        else { return }
        isChanging = true
        defer { isChanging = false }
        let request = GeneratedAPI.HouseholdMemberRequest(
            deviceId: member.deviceId,
            joined: !member.joined
        )
        let key = pendingMember.flatMap { $0.0 == request ? $0.1 : nil } ?? UUID()
        pendingMember = (request, key)
        do {
            try await service.setMember(request, key: key)
            pendingMember = nil
            snapshot = nil
            snapshot = try await service.snapshot()
            errorMessage = nil
        } catch { handle(error) }
    }

    /// Copy only the exact revision the person reviewed, after checking that access still exists.
    func attachment(for note: GeneratedAPI.HouseholdNote) async -> SparkSharedFile? {
        guard !isChanging, !isLoading else { return nil }
        isLoading = true
        defer { isLoading = false }
        do {
            let current = try await service.snapshot()
            snapshot = current
            guard let latest = current.notes.first(where: { $0.id == note.id }),
                latest.revision == note.revision, latest.body == note.body,
                latest.title == note.title
            else {
                errorMessage = String(
                    localized:
                        "This note changed or was removed. Read the latest version before adding it to your chat."
                )
                return nil
            }
            errorMessage = nil
            return SparkSharedFile(
                name: "Household note.txt",
                data: Data("\(latest.title)\n\n\(latest.body)".utf8)
            )
        } catch {
            handle(error)
            return nil
        }
    }

    private func handle(_ error: any Error) {
        // Never leave previously fetched household content visible after a failed access check.
        snapshot = nil
        switch (error as? APIError)?.code {
        case "HOUSEHOLD_ACCESS_REQUIRED":
            errorMessage = String(
                localized:
                    "Ask the Spark's owner to add this device to household notes. Sharing a model does not share household notes."
            )
        case "HOUSEHOLD_NOTE_CHANGED":
            errorMessage = String(
                localized:
                    "Someone changed this note. Your draft is still here; copy any changes you want to keep, then reopen the latest note."
            )
        case "HOUSEHOLD_NOTE_READ_ONLY":
            errorMessage = String(
                localized: "Only the author or a household administrator can change this note."
            )
        default:
            if (error as? APIError)?.statusCode == 404 {
                errorMessage = String(
                    localized: "Update the runtime on your Spark to use household notes."
                )
            } else {
                errorMessage = String(
                    localized:
                        "Couldn't reach your household notes. Reconnect to your Spark and try again."
                )
            }
        }
    }
}
