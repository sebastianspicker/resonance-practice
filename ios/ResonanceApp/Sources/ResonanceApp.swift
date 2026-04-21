import SwiftUI
import SwiftData

@main
struct ResonanceApp: App {
    private let container: ModelContainer
    @StateObject private var appState: AppState

    init() {
        let container = PersistenceController.shared
        self.container = container
        _appState = StateObject(wrappedValue: AppState(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(modelContext: container.mainContext)
                .environmentObject(appState)
                .environmentObject(appState.authManager)
                .environmentObject(appState.syncManager)
                .environmentObject(appState.networkMonitor)
        }
        .modelContainer(container)
    }
}
