import SwiftUI
import SwiftData

// Composes the app's shared services, persistence container, and root scene.

@main
struct ResonanceApp: App {
    private let storageState: StorageState

    init() {
#if RESONANCE_SCREENSHOTS
        if ScreenshotScenario.current != nil {
            // Deterministic capture builds must not read device credentials or
            // mutate persistent profile data. DemoDataManager seeds this
            // in-memory container after the validated scenario is selected.
            self.storageState = .available(PersistenceController.createContainer(inMemory: true))
            return
        }
#endif
        switch PersistenceController.shared {
        case .success(let container):
            self.storageState = .available(container)
        case .failure(let error):
            self.storageState = .unavailable(error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch storageState {
            case .available(let container):
                AppRootView(container: container)
            case .unavailable(let message):
                StorageUnavailableView(message: message)
            }
        }
    }
}

private enum StorageState {
    case available(ModelContainer)
    case unavailable(String)
}

private struct AppRootView: View {
    let container: ModelContainer
    @StateObject private var appState: AppState

    init(container: ModelContainer) {
        self.container = container
        _appState = StateObject(wrappedValue: AppState(modelContext: container.mainContext))
    }

    var body: some View {
        ContentView(modelContext: container.mainContext)
            .environmentObject(appState)
            .environmentObject(appState.authManager)
            .environmentObject(appState.syncManager)
            .environmentObject(appState.networkMonitor)
            .modelContainer(container)
    }
}

private struct StorageUnavailableView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.red)
            Text("Storage Unavailable")
                .font(.title2.weight(.semibold))
            Text("Resonance cannot open its local database. Restart the app before creating or syncing entries.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
