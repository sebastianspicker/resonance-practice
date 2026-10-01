import SwiftUI

/// The three intentional stages of a student's private practice flow.
enum PracticeFlowStep: Int {
    case goal = 1
    case record
    case review

    var title: String {
        switch self {
        case .goal: "Goal"
        case .record: "Record"
        case .review: "Review"
        }
    }
}

/// Scoped visual tokens for the guided practice flow.
///
/// This deliberately sits beside `AppTheme`: the editorial treatment applies to
/// practice creation and its guided follow-up, rather than the whole workspace.
enum PracticeFlowTheme {
    static let background = Color(
        light: Color(red: 0.992, green: 0.984, blue: 0.957),
        dark: Color(red: 0.075, green: 0.061, blue: 0.075)
    )
    static let ink = Color(
        light: Color(red: 0.122, green: 0.047, blue: 0.118),
        dark: Color(red: 0.969, green: 0.925, blue: 0.953)
    )
    static let secondary = Color(
        light: Color(red: 0.255, green: 0.224, blue: 0.314),
        dark: Color(red: 0.765, green: 0.710, blue: 0.773)
    )
    static let accent = Color(
        light: Color(red: 0.286, green: 0.086, blue: 0.267),
        dark: Color(red: 0.896, green: 0.596, blue: 0.850)
    )
    static let accentInk = Color(
        light: Color.white,
        dark: Color(red: 0.133, green: 0.043, blue: 0.124)
    )
    static let audioSurface = Color(
        light: Color(red: 0.957, green: 0.925, blue: 0.969),
        dark: Color(red: 0.184, green: 0.133, blue: 0.204)
    )
    static let border = Color(
        light: Color(red: 0.122, green: 0.047, blue: 0.118).opacity(0.18),
        dark: Color.white.opacity(0.20)
    )
    static let recording = Color(
        light: Color(red: 0.925, green: 0.267, blue: 0.251),
        dark: Color(red: 1.0, green: 0.482, blue: 0.455)
    )
    static let warning = Color(
        light: Color(red: 0.638, green: 0.278, blue: 0.078),
        dark: Color(red: 1.0, green: 0.694, blue: 0.369)
    )
}

struct PracticeNavigationTitle: View {
    let courseTitle: String

    var body: some View {
        VStack(spacing: 2) {
            Text("Resonance")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(PracticeFlowTheme.ink)
            Text(courseTitle)
                .font(.caption)
                .foregroundStyle(PracticeFlowTheme.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PracticeFlowHeader: View {
    let courseTitle: String
    let step: PracticeFlowStep

    var body: some View {
        VStack(spacing: 18) {

            ViewThatFits(in: .horizontal) {
                stepRow
                VStack(alignment: .leading, spacing: 8) {
                    ForEach([PracticeFlowStep.goal, .record, .review], id: \.rawValue) { item in
                        stepItem(item)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Guided practice in \(courseTitle), step \(step.rawValue) of 3: \(step.title)")
        }
        .frame(maxWidth: .infinity)
    }

    private var stepRow: some View {
        HStack(spacing: 8) {
            ForEach([PracticeFlowStep.goal, .record, .review], id: \.rawValue) { item in
                stepItem(item)
                if item != .review {
                    Rectangle()
                        .fill(PracticeFlowTheme.border)
                        .frame(minWidth: 8, maxWidth: 24)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func stepItem(_ item: PracticeFlowStep) -> some View {
        HStack(spacing: 7) {
            Text("\(item.rawValue)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(item == step ? PracticeFlowTheme.accentInk : PracticeFlowTheme.secondary)
                .frame(width: 29, height: 29)
                .background(item == step ? PracticeFlowTheme.accent : PracticeFlowTheme.audioSurface)
                .clipShape(Circle())
            Text(item.title)
                .font(.caption.weight(item == step ? .semibold : .regular))
                .foregroundStyle(item == step ? PracticeFlowTheme.ink : PracticeFlowTheme.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct PracticeFlowTitle: View {
    let title: String
    @ScaledMetric(relativeTo: .largeTitle) private var fontSize = 42

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: fontSize, weight: .medium, design: .serif))
            .foregroundStyle(PracticeFlowTheme.ink)
            .lineSpacing(-3)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PracticeFlowButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(primary: Bool = true) { self.primary = primary }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(primary ? PracticeFlowTheme.accentInk : PracticeFlowTheme.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(primary ? PracticeFlowTheme.accent : PracticeFlowTheme.background)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(primary ? PracticeFlowTheme.accent : PracticeFlowTheme.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct PracticeFlowPage<Content: View>: View {
    let scrollResetID: String?
    @ViewBuilder let content: () -> Content

    init(scrollResetID: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.scrollResetID = scrollResetID
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content()
                    .frame(maxWidth: 600, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .id("practice-page-top")
            }
            .onChange(of: scrollResetID) { _, _ in
                proxy.scrollTo("practice-page-top", anchor: .top)
            }
        }
        .background(PracticeFlowTheme.background.ignoresSafeArea())
    }
}

private struct PracticeFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.body)
            .foregroundStyle(PracticeFlowTheme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PracticeFlowTheme.background.opacity(0.5))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PracticeFlowTheme.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension View {
    func practiceField() -> some View {
        modifier(PracticeFieldModifier())
    }
}
