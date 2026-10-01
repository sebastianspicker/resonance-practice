import Foundation

// Defines stable raw values and errors for durable synchronization work.

/// Sync queue item status values. Raw string values are used for SwiftData compatibility.
enum SyncStatus: String, Codable, Sendable {
    case pending
    case processing
    case failed
}

enum SyncTaskType: String, Codable, Sendable {
    case createEntry
    case updateEntry
    case submitEntry
    case deleteEntry
    case postFeedback
    case syncArtifact
    case syncCaptureProfile
    case syncCaptureMarkers
}

/// Errors that can occur during sync operations.
enum SyncError: LocalizedError {
    case payloadParseError(String)
    case unknownTaskType(String)
    case localFileNotFound(String)
    case invalidPresignUrl(String)
    case localFileMetadataUnavailable(String)
    case localFeedbackNotFound(String)
    case localCaptureMarkersNotFound(String)
    case dependenciesPending(String)
    case invalidCommandBatchSize(Int)
    case serverConflict(entityId: String, currentVersion: Int?)
    case commandRejected(String)
    case commandRetryable(String)
    case missingServerVersion(String)

    var errorDescription: String? {
        switch self {
        case .payloadParseError(let message): return message
        case .unknownTaskType(let message): return message
        case .localFileNotFound(let message): return message
        case .invalidPresignUrl(let message): return message
        case .localFileMetadataUnavailable(let message): return message
        case .localFeedbackNotFound(let message): return message
        case .localCaptureMarkersNotFound(let message): return message
        case .dependenciesPending(let message): return message
        case .invalidCommandBatchSize(let count): return "Sync batches must contain between 1 and 25 commands, got \(count)."
        case let .serverConflict(entityId, currentVersion):
            if let currentVersion {
                return "The server has a newer copy of entry \(entityId) (version \(currentVersion))."
            }
            return "The server has a newer copy of entry \(entityId)."
        case .commandRejected(let message): return message
        case .commandRetryable(let message): return message
        case .missingServerVersion(let entryID): return "Entry \(entryID) must be refreshed before it can be changed."
        }
    }
}
