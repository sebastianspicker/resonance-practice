import Foundation

extension LocalFeedback {
    /// SwiftData relationships do not preserve insertion order, so feedback markers
    /// cross transport boundaries in a stable chronological order.
    var chronologicallyOrderedMarkers: [LocalMarker] {
        markers.sorted {
            ($0.timeSeconds, $0.id) < ($1.timeSeconds, $1.id)
        }
    }
}
