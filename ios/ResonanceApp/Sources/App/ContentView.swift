import SwiftUI
import SwiftData

// Selects the signed-in app shell or login surface from the current authentication state.

struct ContentView: View {
    let modelContext: ModelContext
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var errorReporter: ErrorReporter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.capturePresentation) private var capturePresentation
#if RESONANCE_SCREENSHOTS
    @State private var didPrepareScreenshotData = false
#endif
    @State private var activeLocalProfileUserId: String?
    @State private var conflictingProfileUserId: String?

    var body: some View {
        Group {
            if authManager.session == nil {
                LoginView(universityName: DemoConfiguration.universityName)
            } else if let userId = conflictingProfileUserId {
                LocalProfileConflictView(
                    continueWithAccount: {
                        Task {
                            do {
                                try await appState.replaceLocalProfile(with: userId)
                                conflictingProfileUserId = nil
                                activeLocalProfileUserId = userId
                            } catch {
                                errorReporter.report(error)
                            }
                        }
                    },
                    signOut: {
                        Task { await appState.signOutAndDeleteLocalData() }
                    }
                )
            } else if activeLocalProfileUserId != authManager.session?.userId {
                ProgressView("Preparing local profile…")
            } else {
                MainSplitView(modelContext: modelContext)
            }
        }
        .task {
#if RESONANCE_SCREENSHOTS
            await prepareScreenshotModeIfNeeded()
#endif
            if let userId = authManager.session?.userId {
                prepareLocalProfile(userId: userId)
            }
            if !capturePresentation,
               conflictingProfileUserId == nil,
               activeLocalProfileUserId == authManager.session?.userId {
                await syncManager.processQueue()
            }
        }
        .onChange(of: authManager.session?.userId) { _, userId in
            syncManager.invalidateProcessing()
            if let userId {
                prepareLocalProfile(userId: userId)
            } else {
                activeLocalProfileUserId = nil
                conflictingProfileUserId = nil
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                guard !capturePresentation,
                      conflictingProfileUserId == nil,
                      activeLocalProfileUserId == authManager.session?.userId
                else { return }
                Task { await syncManager.processQueue() }
            }
        }
#if RESONANCE_SCREENSHOTS
        .onReceive(appState.networkMonitor.$isOnline) { isOnline in
            if isOnline, ScreenshotScenario.current?.needsOfflineGuidedPracticeState == true {
                Task { @MainActor in appState.networkMonitor.isOnline = false }
            }
        }
#endif
        .alert("Error", isPresented: $errorReporter.showErrorAlert) {
            Button("OK") { errorReporter.clear() }
        } message: {
            if let message = errorReporter.lastErrorMessage {
                Text(message)
            }
        }
        .tint(AppTheme.accent)
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
            errorReporter.report(error)
        }
    }

#if RESONANCE_SCREENSHOTS
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
                syncManager.invalidateProcessing()
                authManager.signOut()
            }
            return
        }

        do {
            try await authManager.signInForScreenshot(role: scenario.persona)
            try DemoDataManager(modelContext: modelContext).loadMockUniversityData(roleInCourse: scenario.roleInCourse)
            if scenario.isGuidedPracticeScreen {
                try GuidedPracticeScreenshotFixture.prepare(scenario: scenario, modelContext: modelContext)
                if scenario.needsOfflineGuidedPracticeState {
                    appState.networkMonitor.isOnline = false
                }
            }
        } catch {
            errorReporter.report(error)
        }
    }
#endif
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
