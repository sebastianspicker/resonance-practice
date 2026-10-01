import Foundation

/// Versioned, durable payloads for offline synchronization work.
///
/// Installed-alpha persisted-data migration boundary: queue rows from earlier releases stored an untyped JSON object. `decode`
/// accepts those rows and callers persist the returned envelope immediately,
/// so interrupted upgrades retain the original work while subsequent reads are
/// strongly typed.
struct OutboxEnvelope: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let taskType: SyncTaskType
    var payload: OutboxPayload

    init(taskType: SyncTaskType, payload: OutboxPayload) {
        self.version = Self.currentVersion
        self.taskType = taskType
        self.payload = payload
    }

    static func decode(payloadJSON: String, taskType: SyncTaskType) throws -> (envelope: Self, migrated: Bool) {
        guard let data = payloadJSON.data(using: .utf8) else {
            throw SyncError.payloadParseError("Sync payload is not valid UTF-8")
        }
        if let envelope = try? JSONDecoder().decode(Self.self, from: data) {
            guard envelope.version == currentVersion, envelope.taskType == taskType else {
                throw SyncError.payloadParseError("Sync payload envelope is incompatible with its task type")
            }
            guard envelope.payload.isCompatible(with: taskType) else {
                throw SyncError.payloadParseError("Sync payload does not match its task type")
            }
            return (envelope, false)
        }
        return (Self(taskType: taskType, payload: try OutboxPayload.decodeLegacy(data, for: taskType)), true)
    }

    func encodedJSON() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SyncError.payloadParseError("Sync payload could not be encoded as UTF-8")
        }
        return json
    }
}

enum OutboxPayload: Codable, Equatable {
    case entry(EntryPayload)
    case deletion(DeleteEntryPayload)
    case artifact(ArtifactPayload)
    case feedback(FeedbackPayload)

    struct EntryPayload: Codable, Equatable {
        let entryId: String
    }

    struct DeleteEntryPayload: Codable, Equatable {
        let entryId: String
        let baseVersion: Int
    }

    struct ArtifactPayload: Codable, Equatable {
        let artifactId: String
        var baseVersion: Int?
    }

    struct FeedbackPayload: Codable, Equatable {
        let feedbackId: String
        let targetType: String
        let targetId: String
    }

    var entryID: String? {
        switch self {
        case let .entry(payload): payload.entryId
        case let .deletion(payload): payload.entryId
        case .artifact: nil
        case let .feedback(payload): payload.targetType == "entry" ? payload.targetId : nil
        }
    }

    var artifactID: String? {
        switch self {
        case let .artifact(payload): payload.artifactId
        case .entry, .deletion, .feedback: nil
        }
    }

    var feedbackID: String? {
        switch self {
        case let .feedback(payload): payload.feedbackId
        case .entry, .deletion, .artifact: nil
        }
    }

    var targetID: String? {
        switch self {
        case let .feedback(payload): payload.targetId
        case .entry, .deletion, .artifact: nil
        }
    }

    func isCompatible(with taskType: SyncTaskType) -> Bool {
        switch (taskType, self) {
        case (.createEntry, .entry), (.updateEntry, .entry), (.submitEntry, .entry),
             (.syncCaptureProfile, .entry), (.syncCaptureMarkers, .entry),
             (.deleteEntry, .deletion), (.syncArtifact, .artifact), (.postFeedback, .feedback):
            true
        default:
            false
        }
    }

    static func decodeLegacy(_ data: Data, for taskType: SyncTaskType) throws -> Self {
        let decoder = JSONDecoder()
        switch taskType {
        case .createEntry, .updateEntry, .submitEntry, .syncCaptureProfile, .syncCaptureMarkers:
            return .entry(try decoder.decode(EntryPayload.self, from: data))
        case .deleteEntry:
            return .deletion(try decoder.decode(DeleteEntryPayload.self, from: data))
        case .syncArtifact:
            return .artifact(try decoder.decode(ArtifactPayload.self, from: data))
        case .postFeedback:
            return .feedback(try decoder.decode(FeedbackPayload.self, from: data))
        }
    }
}
