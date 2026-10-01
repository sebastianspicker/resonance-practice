import SwiftUI

// Shows account, privacy, and debug settings; App supplies the sign-out and demo-data actions.

/// Debug-only demo-data hooks supplied by the app composition.
struct SettingsDemoDataActions {
    let load: (_ roleInCourse: String) throws -> Void
    let clear: () throws -> Void
}

struct SettingsView: View {
    let signOutAndDeleteLocalData: () async -> Void
    let demoData: SettingsDemoDataActions?
    @EnvironmentObject var authManager: AuthManager
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
                    Text("Auth URL: \(ServiceConfiguration.apiBaseURL.appendingPathComponent("auth/login").absoluteString)")
                        .font(.caption)
                        .textSelection(.enabled)

                    if let demoData {
                        Button("Load Mock Demo Data") {
                            do {
                                let roleInCourse = authManager.session?.globalRole == "teacher" ? "teacher" : "student"
                                try demoData.load(roleInCourse)
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
                                try demoData.clear()
                                demoStatusMessage = "Cleared mock university demo data."
                            } catch {
                                demoStatusMessage = "Clearing demo data failed: \(error.localizedDescription)"
                            }
                            showDemoStatusAlert = true
                        }
                        .accessibilityLabel("Clear mock demo data")
                        .accessibilityHint("Double-tap to remove all sample data from the app")
                    }
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
                    Task { await signOutAndDeleteLocalData() }
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
