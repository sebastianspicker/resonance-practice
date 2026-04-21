import SwiftUI

// MARK: - 2026 SOTA Theme & Utilities

public enum AppTheme {
    // Elegant vibrant gradients for root backgrounds
    public static let bgGradientTopLeft = Color(red: 0.2, green: 0.1, blue: 0.4)
    public static let bgGradientBottomRight = Color(red: 0.05, green: 0.05, blue: 0.15)
    public static let accentVibrant = Color(red: 0.4, green: 0.2, blue: 1.0)
    
    // Layout constants
    public static let cardCornerRadius: CGFloat = 24
    public static let paddingStandard: CGFloat = 20
    
    // A complex, moving mesh-like background for root views
    public struct PremiumBackground: View {
        public init() {}
        public var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                
                LinearGradient(
                    colors: [bgGradientTopLeft, bgGradientBottomRight, Color(white: 0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .opacity(0.8)
                
                // Subtle moving orb/mesh effect could be added here
                Circle()
                    .fill(accentVibrant)
                    .blur(radius: 120)
                    .frame(width: 400, height: 400)
                    .offset(x: -150, y: -250)
                    .opacity(0.3)
                    
                Circle()
                    .fill(Color(red: 0.8, green: 0.3, blue: 0.5))
                    .blur(radius: 150)
                    .frame(width: 300, height: 300)
                    .offset(x: 200, y: 300)
                    .opacity(0.25)
            }
        }
    }
}

// MARK: - View Modifiers

/// Applies a glassmorphic aesthetic to any container shape.
public struct GlassCardModifier: ViewModifier {
    var material: Material = .ultraThinMaterial
    var blendMode: BlendMode = .normal
    
    public func body(content: Content) -> some View {
        content
            .padding(AppTheme.paddingStandard)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                    .fill(material)
                    .blendMode(blendMode)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
    }
}

public extension View {
    func glassCard(material: Material = .ultraThinMaterial, blendMode: BlendMode = .normal) -> some View {
        self.modifier(GlassCardModifier(material: material, blendMode: blendMode))
    }
}

// MARK: - Button Styles

/// A fluid, bouncing button style for modern interactions
public struct VibrantGlassButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 16)
            .padding(.horizontal, 32)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.accentVibrant.opacity(configuration.isPressed ? 0.6 : 0.8))
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
            .shadow(color: AppTheme.accentVibrant.opacity(0.3), radius: configuration.isPressed ? 5 : 10, y: configuration.isPressed ? 2 : 5)
    }
}

/// For subtle actions
public struct SubtleGlassButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundColor(.white.opacity(0.9))
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.05 : 0.1))
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
