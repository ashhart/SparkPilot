import SwiftUI

@main
struct SparkWatchApp: App {
    @State private var store = SparkWatchStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SparkWatchHome(store: store)
                .modifier(SparkWatchPreviewSettings())
                .redacted(reason: scenePhase == .active ? [] : .privacy)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    store.setActive(phase == .active)
                }
                .task(id: "\(scenePhase)-\(store.connection.reachable)-\(store.targetID)") {
                    guard scenePhase == .active, store.connection.reachable else { return }
                    while !Task.isCancelled {
                        await store.refresh()
                        try? await Task.sleep(for: .seconds(15))
                    }
                }
        }
    }
}
