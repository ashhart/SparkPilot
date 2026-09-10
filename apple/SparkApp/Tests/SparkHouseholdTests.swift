import Foundation
import SparkAPI
import Testing
@testable import SparkAppComposition

private actor HouseholdFixture: SparkHouseholdProviding {
    var value = GeneratedAPI.HouseholdSnapshot(notes: [], members: [], canManageMembers: true)
    var failReads = false
    var failWrites = false
    var saves: [(GeneratedAPI.HouseholdNoteRequest, UUID)] = []

    func configure(
        notes: [GeneratedAPI.HouseholdNote] = [],
        failReads: Bool = false,
        failWrites: Bool = false
    ) {
        value.notes = notes
        self.failReads = failReads
        self.failWrites = failWrites
    }
    func snapshot() throws -> GeneratedAPI.HouseholdSnapshot {
        if failReads {
            throw APIError(.local(message: "Revoked"), code: "HOUSEHOLD_ACCESS_REQUIRED")
        }
        return value
    }
    func save(_ request: GeneratedAPI.HouseholdNoteRequest, key: UUID) throws {
        saves.append((request, key))
        if failWrites { throw URLError(.networkConnectionLost) }
    }
    func setMember(_ request: GeneratedAPI.HouseholdMemberRequest, key: UUID) {}
}

@MainActor
struct SparkHouseholdTests {
    private var note: GeneratedAPI.HouseholdNote {
        .init(
            id: UUID().uuidString,
            title: "Garden",
            body: "Water the pots on Friday.",
            revision: 1,
            authorName: "Pat",
            updatedByName: "Pat",
            createdAt: "2026-09-05T12:00:00Z",
            updatedAt: "2026-09-05T12:00:00Z",
            canEdit: true
        )
    }

    @Test func losingMembershipClearsNotesAndPreventsAddingPreviouslyReadTextToChat() async {
        let fixture = HouseholdFixture()
        let shared = note
        await fixture.configure(notes: [shared])
        let model = SparkHouseholdModel(service: fixture)
        await model.refresh()
        #expect(model.snapshot?.notes == [shared])
        await fixture.configure(failReads: true)
        #expect(await model.attachment(for: shared) == nil)
        #expect(model.snapshot == nil)
        #expect(model.errorMessage?.contains("add this device") == true)
    }

    @Test func addingANoteRequiresReviewingTheLatestRevision() async {
        let fixture = HouseholdFixture()
        let reviewed = note
        var changed = reviewed
        changed.body = "A different plan"
        changed.revision = 2
        await fixture.configure(notes: [changed])
        let model = SparkHouseholdModel(service: fixture)
        #expect(await model.attachment(for: reviewed) == nil)
        let included = await model.attachment(for: changed)
        #expect(
            included.flatMap { String(data: $0.data, encoding: .utf8) }
                == "Garden\n\nA different plan"
        )
    }

    @Test func uncertainSavesReuseTheKeyButAnEditedDraftGetsANewKey() async {
        let fixture = HouseholdFixture()
        await fixture.configure(failWrites: true)
        let model = SparkHouseholdModel(service: fixture)
        var draft = SparkHouseholdDraft(note: note)
        #expect(await model.save(draft) == false)
        #expect(await model.save(draft) == false)
        draft.body = "Water on Saturday."
        #expect(await model.save(draft) == false)
        let saves = await fixture.saves
        #expect(saves.count == 3)
        #expect(saves[0].1 == saves[1].1)
        #expect(saves[1].1 != saves[2].1)
        #expect(saves[2].0.body == draft.body)
    }

    @Test func successfulSaveIsAcknowledgedEvenWhenTheFollowingReadFails() async {
        let fixture = HouseholdFixture()
        await fixture.configure(failReads: true)
        let model = SparkHouseholdModel(service: fixture)
        #expect(await model.save(SparkHouseholdDraft(note: note)))
        #expect(model.snapshot == nil)
        #expect(model.errorMessage != nil)
        #expect(await fixture.saves.count == 1)
    }
}
