import SwiftUI
import SwiftData

// Presents account and local-data controls, including explicit destructive sign-out choices.

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var syncManager: SyncManager
    @State private var demoStatusMessage: String?
    @State private var showDemoStatusAlert = false
    @State private var showSignOutOptions = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let session = authManager.session {
                        LabeledContent("Signed in as", value: session.displayName)
                    }
                    Button("Sign Out") {
                        showSignOutOptions = true
                    }
                    .foregroundStyle(.red)
                    .accessibilityLabel("Sign out")
                    .accessibilityHint("Double-tap to sign out of your account")
                }

#if DEBUG
                Section("Debug") {
                    Text("Auth URL: \(AppConfig.authLoginURL.absoluteString)")
                        .font(.caption)
                        .textSelection(.enabled)

                    Button("Load Mock Demo Data") {
                        do {
                            let roleInCourse = authManager.session?.globalRole == "teacher" ? "teacher" : "student"
                            try DemoDataManager(modelContext: modelContext).loadMockUniversityData(roleInCourse: roleInCourse)
                            demoStatusMessage = "Loaded mock university demo data."
                        } catch {
                            demoStatusMessage = "Loading demo data failed: \(error.localizedDescription)"
                        }
                        showDemoStatusAlert = true
                    }
                    .accessibilityLabel("Load mock demo data")
                    .accessibilityHint("Double-tap to populate the app with sample university data")

                    Button("Clear Mock Demo Data") {
                        do {
                            try DemoDataManager(modelContext: modelContext).clearMockUniversityData()
                            demoStatusMessage = "Cleared mock university demo data."
                        } catch {
                            demoStatusMessage = "Clearing demo data failed: \(error.localizedDescription)"
                        }
                        showDemoStatusAlert = true
                    }
                    .accessibilityLabel("Clear mock demo data")
                    .accessibilityHint("Double-tap to remove all sample data from the app")
                }
#endif

                Section("Privacy") {
                    Text("No analytics are collected by default. Media stays local until you submit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.workspaceBackground)
            .navigationTitle("Settings")
            .confirmationDialog(
                "Sign out and delete local data?",
                isPresented: $showSignOutOptions,
                titleVisibility: .visible
            ) {
                if syncManager.pendingQueueCount > 0 || syncManager.failedQueueCount > 0 {
                    Button("Sync now") {
                        Task { await syncManager.processQueue() }
                    }
                }
                Button("Sign out and delete local data", role: .destructive) {
                    Task { await appState.signOutAndDeleteLocalData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "\(syncManager.pendingQueueCount) pending and \(syncManager.failedQueueCount) failed " +
                        "changes will be deleted from this device."
                )
            }
            .alert("Demo Data", isPresented: $showDemoStatusAlert) {
                Button("OK") { demoStatusMessage = nil }
            } message: {
                Text(demoStatusMessage ?? "No status available.")
            }
        }
    }
}
