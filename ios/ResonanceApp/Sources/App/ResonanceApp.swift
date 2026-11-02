import SwiftUI
import SwiftData

// Composes the app's shared services, persistence container, and root scene.

@main
struct ResonanceApp: App {
    @State private var storageState: StorageState

    init() {
#if RESONANCE_SCREENSHOTS
        if ScreenshotScenario.current != nil {
            // Deterministic capture builds must not read device credentials or
            // mutate persistent profile data. DemoDataManager seeds this
            // in-memory container after the validated scenario is selected.
            _storageState = State(initialValue: .available(PersistenceController.createContainer(inMemory: true)))
            return
        }
#endif
        switch PersistenceController.shared {
        case .success(let container):
            _storageState = State(initialValue: .available(container))
        case .failure(let error):
            _storageState = State(initialValue: .unavailable(error))
        }
    }

    var body: some Scene {
        WindowGroup {
            switch storageState {
            case .available(let container):
                AppRootView(container: container)
            case .unavailable(let error):
                StorageUnavailableView(error: error) { container in
                    storageState = .available(container)
                }
            }
        }
    }
}

private enum StorageState {
    case available(ModelContainer)
    case unavailable(Error)
}

private struct AppRootView: View {
    let container: ModelContainer
    @StateObject private var appState: AppState

    init(container: ModelContainer) {
        self.container = container
        _appState = StateObject(wrappedValue: AppState(modelContext: container.mainContext))
    }

    private var isCapturePresentation: Bool {
#if RESONANCE_SCREENSHOTS
        ScreenshotScenario.current != nil
#else
        false
#endif
    }

    var body: some View {
        ContentView(modelContext: container.mainContext)
            .environmentObject(appState)
            .environmentObject(appState.authManager)
            .environmentObject(appState.syncManager)
            .environmentObject(appState.networkMonitor)
            .environmentObject(appState.errorReporter)
            .environment(\.apiClient, appState.apiClient)
            .environment(\.capturePresentation, isCapturePresentation)
            .modelContainer(container)
    }
}

private struct StorageUnavailableView: View {
    let error: Error
    let onRecovered: (ModelContainer) -> Void
    @State private var recoveryError: Error?

    private var displayedError: Error { recoveryError ?? error }

    private var isLeftoverSignIn: Bool {
        (error as? LocalAlphaDataResetError) == .leftoverSignInOnly
    }

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
            Text(displayedError.localizedDescription)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if isLeftoverSignIn {
                Text("A sign-in from an earlier installation was found, but no entries or recordings are stored on this device.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Clear old sign-in and continue") {
                    switch PersistenceController.createPersistentContainerClearingLeftoverSignIn() {
                    case .success(let container):
                        onRecovered(container)
                    case .failure(let failure):
                        recoveryError = failure
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
