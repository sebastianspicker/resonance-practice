import SwiftUI

// TODO: Localization — All user-facing strings in this view should be wrapped with
// LocalizedStringKey / NSLocalizedString for i18n support.
struct LoginView: View {
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        ZStack {
            AppTheme.PremiumBackground()
            
            VStack(spacing: 32) {
                // Logo or Icon placeholder
                Image(systemName: "music.mic.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundStyle(.white)
                    // optional glow
                    .shadow(color: AppTheme.accentVibrant.opacity(0.8), radius: 20)
                
                VStack(spacing: 12) {
                    Text("Resonance")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                    
                    Text("Practice & Feedback")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                
                VStack(spacing: 16) {
                    Text("Sign in with your university account")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text(AppConfig.demoUniversityName)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Button("Sign In") {
                        authManager.signIn()
                    }
                    .buttonStyle(VibrantGlassButtonStyle())
                    .padding(.top, 8)
                    .accessibilityLabel("Sign in to your account")
                    .accessibilityHint("Double-tap to sign in with your university credentials")
                    
                    Text("Environment: \(AppConfig.apiBaseURL.host() ?? AppConfig.apiBaseURL.absoluteString)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.top, 16)
                        .accessibilityLabel("Connected to environment \(AppConfig.apiBaseURL.host() ?? AppConfig.apiBaseURL.absoluteString)")
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .glassCard(material: .ultraThinMaterial, blendMode: .luminosity)
            .padding(40) // Responsive padding from screen edge
        }
        .preferredColorScheme(.dark)
    }
}
