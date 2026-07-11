import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var authManager: AuthManager
    @State private var demoStatusMessage: String?
    @State private var showDemoStatusAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section("API") {
                    Text("Base URL: \(AppConfig.apiBaseURL.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Active host: \(AppConfig.apiBaseURL.host() ?? AppConfig.apiBaseURL.absoluteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Sign Out") {
                        authManager.signOut()
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
            .navigationTitle("Settings")
            .alert("Demo Data", isPresented: $showDemoStatusAlert) {
                Button("OK") { demoStatusMessage = nil }
            } message: {
                Text(demoStatusMessage ?? "No status available.")
            }
        }
    }
}
