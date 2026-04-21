import SwiftUI

/// A reusable empty state view with icon, title, description, and optional action button.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.4))

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text(description)
                .font(.body)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(VibrantGlassButtonStyle())
                    .padding(.top, 8)
                    .accessibilityLabel(actionLabel)
                    .accessibilityHint("Double-tap to \(actionLabel.lowercased())")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
