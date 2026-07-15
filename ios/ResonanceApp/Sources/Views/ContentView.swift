import SwiftUI
import SwiftData

struct ContentView: View {
    let modelContext: ModelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var syncManager: SyncManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var didPrepareScreenshotData = false
    @State private var activeLocalProfileUserId: String?
    @State private var conflictingProfileUserId: String?

    var body: some View {
        Group {
            if authManager.session == nil {
                LoginView()
            } else if let userId = conflictingProfileUserId {
                LocalProfileConflictView(
                    continueWithAccount: {
                        do {
                            try appState.replaceLocalProfile(with: userId)
                            conflictingProfileUserId = nil
                            activeLocalProfileUserId = userId
                        } catch {
                            appState.reportError(error)
                        }
                    },
                    signOut: { authManager.signOut() }
                )
            } else if activeLocalProfileUserId != authManager.session?.userId {
                ProgressView("Preparing local profile…")
            } else {
                MainSplitView(modelContext: modelContext)
            }
        }
        .task {
            await prepareScreenshotModeIfNeeded()
            if let userId = authManager.session?.userId {
                prepareLocalProfile(userId: userId)
            }
            if ScreenshotScenario.current == nil {
                await syncManager.processQueue()
            }
        }
        .onChange(of: authManager.session?.userId) { _, userId in
            if let userId {
                prepareLocalProfile(userId: userId)
            } else {
                activeLocalProfileUserId = nil
                conflictingProfileUserId = nil
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                guard ScreenshotScenario.current == nil else { return }
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

    private func prepareLocalProfile(userId: String) {
        do {
            if try appState.activateLocalProfile(userId: userId) {
                activeLocalProfileUserId = userId
                conflictingProfileUserId = nil
            } else {
                activeLocalProfileUserId = nil
                conflictingProfileUserId = userId
            }
        } catch {
            activeLocalProfileUserId = nil
            conflictingProfileUserId = userId
            appState.reportError(error)
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

private struct LocalProfileConflictView: View {
    let continueWithAccount: () -> Void
    let signOut: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Local data belongs to another account", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text("To prevent accounts from sharing cached courses or media, delete the previous local profile before continuing.")
        } actions: {
            Button("Delete local data and continue", role: .destructive, action: continueWithAccount)
            Button("Sign out", action: signOut)
        }
    }
}
