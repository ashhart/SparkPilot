import SwiftUI

@MainActor
struct SparkMoreView: View {
    @AppStorage(SparkEngineeringMode.preferenceKey) private var engineeringMode = false
    var hasSparks = true
    var body: some View {
        List {
            ForEach(
                AppleNavigationPlan.visibleSections(
                    AppleNavigationPlan.phoneMoreSections(engineeringMode: engineeringMode),
                    hasSparks: hasSparks,
                    engineeringMode: engineeringMode
                )
            ) { item in
                NavigationLink(value: item) {
                    SparkNavigationLabel(title: item.title, systemImage: item.symbol)
                }
            }
            Section {
                SparkBugFeedbackLink()
                SparkAboutLink()
            } header: {
                Text("Help").foregroundStyle(Color.primary)
            }
            #if DEBUG
                NavigationLink("Family flow preview") { SparkFamilyPreview() }
                if engineeringMode {
                    NavigationLink("Development preview") { SparkDevelopmentPreview() }
                }
            #endif
        }
    }
}

/// Keeps the text's measured bounds independent of its decorative symbol.
@MainActor
struct SparkNavigationLabel: View {
    let title: String
    let systemImage: String
    @ScaledMetric(relativeTo: .body) private var symbolWidth = 24.0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: symbolWidth)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
struct SparkAboutLink: View {
    var body: some View {
        NavigationLink {
            SparkAboutView()
        } label: {
            SparkNavigationLabel(title: String(localized: "About"), systemImage: "info.circle")
        }
    }
}

@MainActor
struct SparkAboutView: View {
    private let bundle = Bundle.main

    var body: some View {
        Form {
            Section("SparkPilot") {
                LabeledContent("Version") {
                    Text(verbatim: metadata("CFBundleShortVersionString"))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("spark.about.version")
                }
                LabeledContent("Build number") {
                    Text(verbatim: metadata("CFBundleVersion"))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("spark.about.build")
                }
            }
            Section("Links") {
                Link(destination: URL(string: "https://sparkpilot.dev")!) {
                    LabeledContent {
                        Text(verbatim: "sparkpilot.dev")
                    } label: {
                        SparkNavigationLabel(
                            title: String(localized: "Website"),
                            systemImage: "globe"
                        )
                    }
                }
                .accessibilityIdentifier("spark.about.website")
                SparkBugFeedbackLink()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }

    private func metadata(_ key: String) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return String(localized: "Not available") }
        return value
    }
}
