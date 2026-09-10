import Foundation

struct ChatScrollPosition: Equatable {
    let offset: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    var nearBottom: Bool { offset + viewportHeight >= contentHeight + bottomInset - 80 }

    func hasSameViewport(as other: Self) -> Bool {
        viewportHeight == other.viewportHeight && topInset == other.topInset
            && bottomInset == other.bottomInset
    }
}

/// Track unread output separately from scroll-following so inspecting an old reply does not announce a new response.
struct SparkChatScrollState {
    private(set) var followsLatest = true
    private var nearBottom = true
    private var isUserScrolling = false
    private var hasUnseenOutput = false

    var showsLatestResponse: Bool { hasUnseenOutput && !followsLatest && !nearBottom }

    mutating func pauseFollowing() {
        if nearBottom { hasUnseenOutput = false }
        followsLatest = false
    }

    mutating func resumeFollowing() {
        followsLatest = true
        isUserScrolling = false
        hasUnseenOutput = false
    }

    mutating func userScrollBegan() {
        isUserScrolling = true
        pauseFollowing()
    }

    mutating func userScrollEnded() {
        if isUserScrolling, nearBottom { resumeFollowing() }
        isUserScrolling = false
    }

    mutating func positionChanged(
        from previous: ChatScrollPosition,
        to current: ChatScrollPosition,
        isPositionedByUser: Bool = true
    ) {
        nearBottom = current.nearBottom
        if nearBottom { hasUnseenOutput = false }
        // Pause following only for user-positioned offsets under stable geometry, including accessibility and mouse-wheel scrolling.
        guard isPositionedByUser, current.hasSameViewport(as: previous),
            current.contentHeight == previous.contentHeight
        else { return }
        if current.offset < previous.offset - 2 {
            // Output that fitted on screen before scrolling is already read.
            if previous.nearBottom { hasUnseenOutput = false }
            followsLatest = false
        } else if nearBottom, !isUserScrolling, current.offset > previous.offset + 2 {
            resumeFollowing()
        }
    }

    mutating func messagesChanged(from previous: [SparkChatMessage], to current: [SparkChatMessage])
    {
        guard !current.isEmpty else {
            resumeFollowing()
            return
        }
        // Reveal owner-submitted text and voice messages without coupling the composer to scroll position.
        if let latestUser = current.last(where: { $0.role == .user }),
            latestUser.id != previous.last(where: { $0.role == .user })?.id
        {
            resumeFollowing()
        }
        guard !followsLatest, let latest = current.last, latest.role == .assistant,
            latest.hasAnswer || latest.hasReasoning
        else { return }
        let earlier = previous.last { $0.id == latest.id }
        // Empty placeholders and status/timer changes are not new output.
        if latest.content != earlier?.content || latest.reasoning != earlier?.reasoning {
            hasUnseenOutput = true
        }
    }
}
