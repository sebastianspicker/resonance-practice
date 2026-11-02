import Foundation

// Mirrors the server's input limits so the app refuses work the server would reject for good.

/// Source of truth: `limits` in server/src/platform/config.ts. Change both together.
enum ServerLimits {
    /// Largest artifact the server accepts in one upload (100 MiB).
    static let maxUploadSizeBytes: Int64 = 104_857_600
    /// Most markers one feedback item or one lesson capture may carry.
    static let maxMarkers = 50
    /// Longest marker note, counted in UTF-16 code units like the server.
    static let maxMarkerTextLength = 1_000
    /// Latest marker time in seconds (8 hours).
    static let maxMarkerTimeSeconds = 28_800
}
