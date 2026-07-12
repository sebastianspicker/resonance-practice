import SwiftUI

enum AppTheme {
    static let accent = Color(light: Color(red: 0.37, green: 0.25, blue: 0.77), dark: Color(red: 0.72, green: 0.66, blue: 1.0))
    static let selection = Color(light: Color(red: 0.94, green: 0.93, blue: 1.0), dark: Color(red: 0.15, green: 0.13, blue: 0.23))

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let standard: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 32
    }

    struct Background: View {
        var body: some View {
            Color(uiColor: .systemBackground).ignoresSafeArea()
        }
    }

    static let accentVibrant = accent
}

private struct GroupedSectionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AppTheme.Spacing.standard)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func groupedSection() -> some View { modifier(GroupedSectionModifier()) }

}

private extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}
