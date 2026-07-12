import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authManager: AuthManager

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "music.note")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Resonance").font(.largeTitle.weight(.bold))
                Text("Practice evidence and feedback")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 16) {
                Text("Sign in with your university account to open your courses and locally saved work.")
                    .multilineTextAlignment(.center)
                Text(AppConfig.demoUniversityName).font(.headline)
                Button("Sign in") { authManager.signIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if let authError = authManager.authError {
                    Label(authError, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel("Sign-in error: \(authError)")
                }
            }
        }
        .padding(32)
        .frame(maxWidth: 520, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
