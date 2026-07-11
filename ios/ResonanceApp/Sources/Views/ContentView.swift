import SwiftUI
import SwiftData

struct ContentView: View {
    let modelContext: ModelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var didPrepareScreenshotData = false

    var body: some View {
        Group {
            if authManager.session == nil {
                LoginView()
            } else {
                MainSplitView(modelContext: modelContext)
            }
        }
        .dynamicTypeSize(.xSmall ... .xxxLarge)
        .task {
            await prepareScreenshotModeIfNeeded()
            await syncManager.processQueue()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await syncManager.processQueue() }
            }
        }
        .alert("Error", isPresented: $appState.showErrorAlert) {
            Button("OK") { appState.clearError() }
        } message: {
            if let message = appState.lastErrorMessage {
                Text(message)
            }
        }
    }

    private func prepareScreenshotModeIfNeeded() async {
        guard let scenario = ScreenshotScenario.current else {
            return
        }
        guard !didPrepareScreenshotData else {
            return
        }
        didPrepareScreenshotData = true

        if !scenario.requiresAuthenticatedSession {
            if authManager.session != nil {
                authManager.signOut()
            }
            return
        }

        do {
            try await authManager.signInForScreenshot(role: scenario.persona)
            try DemoDataManager(modelContext: modelContext).loadMockUniversityData(roleInCourse: scenario.roleInCourse)
        } catch {
            appState.reportError(error)
        }
    }
}
