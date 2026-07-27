import SwiftUI

// Presents the sign-in state, browser-launch action, and debug screenshot authentication controls.

struct LoginView: View {
    @EnvironmentObject private var authManager: AuthManager

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: AppTheme.Spacing.xLarge) {
                    VStack(spacing: AppTheme.Spacing.standard) {
                        ResonanceMark()
                            .frame(width: 96, height: 64)
                        VStack(spacing: AppTheme.Spacing.small) {
                            Text("Resonance")
                                .font(.largeTitle.weight(.bold))
                            Text("Practice, reflect, respond.")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(spacing: AppTheme.Spacing.standard) {
                        Text("Keep practice evidence, teaching reflection, and feedback together, even when you are offline.")
                            .multilineTextAlignment(.center)
                        Text(AppConfig.demoUniversityName)
                            .font(.headline)
                        Button("Sign in with university account") {
                            authManager.signIn()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(authManager.isAuthenticating)
                        .accessibilityHint(
                            authManager.isAuthenticating
                                ? "Sign-in is already in progress"
                                : "Opens your university sign-in page"
                        )

                        Label("Private to you and your courses", systemImage: "lock")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if let authError = authManager.authError {
                            Label(authError, systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .accessibilityLabel("Sign-in error: \(authError)")
                        }
                    }
                }
                .padding(AppTheme.Spacing.xLarge)
                .frame(maxWidth: 520, minHeight: proxy.size.height)
                .frame(maxWidth: .infinity)
            }
        }
        .background(AppTheme.workspaceBackground)
    }
}
