import Foundation
import Observation
import SparkAPI
import SparkDesignSystem
import SwiftUI

/// What a guest sees about their own access: their limits, today's use, and why chat is limited.
public struct GuestAccessView: View {
    @Bindable var model: GuestExperienceModel
    let nodeName: String

    public init(model: GuestExperienceModel, nodeName: String) {
        self.model = model
        self.nodeName = nodeName
    }

    public var body: some View {
        List {
            if let experience = model.experience {
                Section {
                    Text(.guestAccessSharedBy(nodeName))
                        .font(.callout)
                    if let reason = experience.unavailableReason {
                        Label(reason, systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("guest.access.reason")
                    }
                }

                Section {
                    Text(.guestAccessBudgetRemaining(experience.remainingToday))
                        .font(.headline)
                    ProgressView(
                        value: Double(min(experience.usedToday, experience.dailyTokenBudget)),
                        total: Double(max(experience.dailyTokenBudget, 1))
                    )
                    if let resets = experience.budgetResetsAt {
                        Text(
                            .guestAccessBudgetResets(
                                resets.formatted(date: .omitted, time: .shortened)
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    }
                    Text(.sharedAccessRequestsToday(experience.requestsToday))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Today")
                } footer: {
                    Text("Your share starts again at midnight where the owner is.")
                }

                Section {
                    if experience.allowedModels.isEmpty {
                        Text("None yet. The owner chooses which models you can use.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(experience.allowedModels, id: \.self) { name in
                            Text(name)
                        }
                    }
                } header: {
                    Text("Models shared with you")
                }

                Section {
                    ForEach(0..<7, id: \.self) { weekday in
                        LabeledContent(
                            GuestAccessWeekday.label(weekday),
                            value: experience.hoursLabel(weekday: weekday)
                        )
                    }
                } header: {
                    Text("When you can use it")
                } footer: {
                    Text(.sharedAccessHoursInZone(experience.timeZone))
                }
            } else if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label(
                        "Nothing is shared with you here",
                        systemImage: "person.crop.circle.badge.xmark"
                    )
                } description: {
                    Text(
                        model.errorMessage
                            ?? String(localized: "This Spark is your own, so nothing is limited.")
                    )
                }
            }
        }
        .navigationTitle(Text("Your access"))
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}

enum GuestAccessWeekday {
    static func label(_ weekday: Int) -> String {
        switch weekday {
        case 0: String(localized: "Monday")
        case 1: String(localized: "Tuesday")
        case 2: String(localized: "Wednesday")
        case 3: String(localized: "Thursday")
        case 4: String(localized: "Friday")
        case 5: String(localized: "Saturday")
        default: String(localized: "Sunday")
        }
    }
}
