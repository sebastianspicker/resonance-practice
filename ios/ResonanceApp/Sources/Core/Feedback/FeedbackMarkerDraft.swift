import Foundation

// Holds one editable feedback marker and converts its minutes:seconds time text.

struct MarkerDraft: Identifiable, Equatable {
    let id = UUID()
    var time: String
    var text: String

    /// Parses `ss` or `mm:ss` marker text into whole seconds, rejecting negative or out-of-range parts.
    static func parseTime(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 { return Int(parts[0]).flatMap { $0 >= 0 ? $0 : nil } }
        guard parts.count == 2,
              let minutes = Int(parts[0]), let seconds = Int(parts[1]),
              minutes >= 0, (0..<60).contains(seconds) else { return nil }
        return minutes * 60 + seconds
    }

    static func formatTime(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
