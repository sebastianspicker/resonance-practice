import SwiftUI

// Atelier design tokens: cool-tinted workspace neutrals, Resonance violet accent, system-aligned surfaces.

enum AppTheme {
    // MARK: - Accent (Resonance violet)
    static let accent = Color(
        light: Color(red: 0.369, green: 0.247, blue: 0.769), // #5E3FC4
        dark: Color(red: 0.718, green: 0.659, blue: 1.0) // #B7A8FF
    )
    static let accentStrong = Color(
        light: Color(red: 0.310, green: 0.208, blue: 0.678), // #4F35AD
        dark: Color(red: 0.784, green: 0.737, blue: 1.0) // #C8BCFF
    )
    static let selection = Color(
        light: Color(red: 0.941, green: 0.929, blue: 1.0), // #F0EDFF
        dark: Color(red: 0.149, green: 0.129, blue: 0.227) // #26213A
    )

    // MARK: - Workspace (cool violet-adjacent neutrals — not cream/sand)
    static let workspaceBackground = Color(
        light: Color(red: 0.953, green: 0.949, blue: 0.969), // #F3F2F7
        dark: Color(red: 0.047, green: 0.051, blue: 0.071) // #0C0D12
    )
    static let workspaceSidebar = Color(
        light: Color(red: 0.925, green: 0.918, blue: 0.953), // #ECEAF3
        dark: Color(red: 0.059, green: 0.067, blue: 0.090) // #0F1117
    )
    static let workspacePanel = Color(
        light: .white,
        dark: Color(red: 0.071, green: 0.078, blue: 0.102) // #12141A
    )
    static let workspaceRaised = Color(
        light: Color(red: 0.980, green: 0.976, blue: 0.988), // #FAF9FC
        dark: Color(red: 0.086, green: 0.094, blue: 0.129) // #161821
    )
    static let workspaceBorder = Color(
        light: Color(red: 0.078, green: 0.075, blue: 0.102).opacity(0.12),
        dark: Color.white.opacity(0.12)
    )
    static let workspaceBorderStrong = Color(
        light: Color(red: 0.078, green: 0.075, blue: 0.102).opacity(0.16),
        dark: Color.white.opacity(0.16)
    )
    static let workspaceInk = Color(
        light: Color(red: 0.078, green: 0.075, blue: 0.102), // #14131A
        dark: Color(red: 0.949, green: 0.945, blue: 0.969)
    )
    static let workspaceInkSoft = Color(
        light: Color(red: 0.227, green: 0.216, blue: 0.282), // #3A3748
        dark: Color(red: 0.769, green: 0.753, blue: 0.824)
    )
    static let workspaceMuted = Color(
        light: Color(red: 0.420, green: 0.400, blue: 0.478), // #6B667A
        dark: Color(red: 0.561, green: 0.541, blue: 0.620)
    )

    // MARK: - Semantic status (always paired with text labels)
    static let statusDraftFill = Color(light: Color(red: 0.941, green: 0.941, blue: 0.953), dark: Color(white: 0.16))
    static let statusDraftForeground = Color(light: Color(red: 0.227, green: 0.216, blue: 0.282), dark: Color(white: 0.78))

    static let statusLocalFill = Color(
        light: Color(red: 0.933, green: 0.949, blue: 1.0),
        dark: Color(red: 0.102, green: 0.133, blue: 0.251)
    )
    static let statusLocalForeground = Color(
        light: Color(red: 0.208, green: 0.345, blue: 0.780),
        dark: Color(red: 0.541, green: 0.643, blue: 1.0)
    )

    static let statusQueuedFill = Color(
        light: Color(red: 1.0, green: 0.965, blue: 0.878),
        dark: Color(red: 0.180, green: 0.141, blue: 0.063)
    )
    static let statusQueuedForeground = Color(
        light: Color(red: 0.604, green: 0.404, blue: 0.0),
        dark: Color(red: 0.910, green: 0.722, blue: 0.290)
    )

    static let statusSubmittedFill = Color(
        light: Color(red: 0.941, green: 0.929, blue: 1.0),
        dark: Color(red: 0.149, green: 0.129, blue: 0.227)
    )
    static let statusSubmittedForeground = Color(
        light: Color(red: 0.310, green: 0.208, blue: 0.678),
        dark: Color(red: 0.784, green: 0.737, blue: 1.0)
    )

    static let statusReviewedFill = Color(
        light: Color(red: 0.910, green: 0.965, blue: 0.933),
        dark: Color(red: 0.082, green: 0.208, blue: 0.157)
    )
    static let statusReviewedForeground = Color(
        light: Color(red: 0.122, green: 0.478, blue: 0.298),
        dark: Color(red: 0.365, green: 0.792, blue: 0.627)
    )

    static let statusFailedFill = Color(
        light: Color(red: 0.996, green: 0.953, blue: 0.949),
        dark: Color(red: 0.180, green: 0.082, blue: 0.078)
    )
    static let statusFailedForeground = Color(
        light: Color(red: 0.706, green: 0.137, blue: 0.094),
        dark: Color(red: 0.941, green: 0.443, blue: 0.404)
    )

    static let statusOfflineFill = Color(light: Color(red: 0.941, green: 0.941, blue: 0.953), dark: Color(white: 0.16))
    static let statusOfflineForeground = Color(light: Color(red: 0.227, green: 0.216, blue: 0.282), dark: Color(white: 0.78))

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let standard: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 32
    }

    enum Radius {
        static let control: CGFloat = 8
        static let section: CGFloat = 12
        static let stage: CGFloat = 14
    }

    struct Background: View {
        var body: some View {
            AppTheme.workspaceBackground.ignoresSafeArea()
        }
    }

    static let accentVibrant = accent
    static let compactBreakpoint: CGFloat = 1_180
}

// MARK: - Brand mark

/// The Resonance signature: a captured phrase that decays into a quiet echo.
struct ResonanceMark: View {
    private let levels: [CGFloat] = [0.28, 0.48, 0.78, 1, 0.72, 0.46, 0.26]

    var body: some View {
        GeometryReader { proxy in
            let barWidth = proxy.size.width * 0.08
            let spacing = proxy.size.width * 0.055

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule(style: .continuous)
                        .frame(width: barWidth, height: proxy.size.height * level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(AppTheme.accent)
        .accessibilityHidden(true)
    }
}

// MARK: - Workspace chrome

struct WorkspaceDivider: View {
    var body: some View {
        Rectangle().fill(AppTheme.workspaceBorder).frame(width: 1)
    }
}

struct WorkspaceRule: View {
    var body: some View {
        Rectangle().fill(AppTheme.workspaceBorder).frame(height: 1)
    }
}

struct WorkspaceSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(AppTheme.workspaceMuted)
    }
}

private struct GroupedSectionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AppTheme.Spacing.standard)
            .background(AppTheme.workspaceRaised)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.section, style: .continuous)
                    .stroke(AppTheme.workspaceBorder)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.section, style: .continuous))
    }
}

extension View {
    func groupedSection() -> some View { modifier(GroupedSectionModifier()) }

    func workspacePanel() -> some View {
        background(AppTheme.workspacePanel)
    }
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}
