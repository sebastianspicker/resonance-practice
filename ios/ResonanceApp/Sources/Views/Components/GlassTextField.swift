import SwiftUI

/// A text field styled with the glass morphism theme.
/// Replaces the repeated pattern of `.textFieldStyle(.plain).padding().background(...).clipShape(...)`.
struct GlassTextField: View {
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int>? = nil
    var keyboardType: UIKeyboardType = .default
    var cornerRadius: CGFloat = 12
    var width: CGFloat? = nil

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .keyboardType(keyboardType)
            .textFieldStyle(.plain)
            .padding()
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .foregroundStyle(.white)
            .ifLet(lineLimit) { view, range in
                view.lineLimit(range)
            }
            .ifLet(width) { view, w in
                view.frame(width: w)
            }
    }
}

private extension View {
    @ViewBuilder
    func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}
