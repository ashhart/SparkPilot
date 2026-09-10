import Foundation

extension LocalizedStringResource {
    static func householdAuthor(_ author: String) -> Self {
        .init(
            "household.note.author",
            defaultValue: "Added by \(author)",
            comment: "Attribution on a shared household note."
        )
    }

    static func householdEditors(_ author: String, _ editor: String) -> Self {
        .init(
            "household.note.editors",
            defaultValue: "Added by \(author) · Last changed by \(editor)",
            comment: "Original author and latest editor of a shared note."
        )
    }

    static func householdRemoval(_ member: String) -> Self {
        .init(
            "household.member.remove",
            defaultValue:
                "\(member) will lose access to household notes. Copies already added to chats remain on that device.",
            comment: "Explain the limits of revoking household access."
        )
    }

    static func householdInvitation(_ member: String) -> Self {
        .init(
            "household.member.invite",
            defaultValue:
                "\(member) will be able to read all current and future household notes and add their own. Private chats are not shared.",
            comment: "Explain which content becomes visible when adding a household member."
        )
    }
}
