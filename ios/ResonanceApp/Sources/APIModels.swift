import Foundation
import SwiftData

// Defines Codable server payloads and reconciliation support at the API-to-local-model boundary.

/// Typed server error envelope used instead of exposing arbitrary response bodies.
struct APIError: Error, Decodable {
    let error: APIErrorBody

    struct APIErrorBody: Decodable {
        let code: String
        let message: String
        let details: [String: JSONValue]?
        let requestId: String?
        let currentVersion: Int?

        init(
            code: String,
            message: String,
            details: [String: JSONValue]? = nil,
            requestId: String? = nil,
            currentVersion: Int? = nil
        ) {
            self.code = code
            self.message = message
            self.details = details
            self.requestId = requestId
            self.currentVersion = currentVersion
        }
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let user: UserResponse?

    struct UserResponse: Decodable {
        let id: String
        let displayName: String
        let globalRole: String
    }
}

struct CourseResponse: Decodable {
    let id: String
    let title: String
    let roleInCourse: String
}

/// Authoritative server entry projection used to reconcile local SwiftData state.
struct EntryResponse: Decodable {
    let id: String
    let courseId: String
    let studentId: String
    let kind: String?
    let practiceDate: Date
    let goalText: String
    let durationSeconds: Int?
    let tags: [String]
    let notes: String?
    let status: String
    let consentConfirmedAt: Date?
    let consentScope: String?
    let captureProfile: String?
    let captureMarkers: [CaptureMarkerResponse]?
    let artifacts: [ArtifactResponse]?
    let createdAt: Date?
    let updatedAt: Date?
    let version: Int?
}

/// JSON carried by an offline command. Keeping this value typed and Codable
/// prevents command payloads from crossing the persistence/network boundary as
/// `[String: Any]`.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case .null: try container.encodeNil()
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

/// Versioned mutation kinds accepted by the ordered command endpoint.
enum SyncCommandKind: String, Codable, Sendable {
    case createEntry
    case updateEntry
    case replaceCaptureMarkers
    case submitEntry
    case deleteEntry
    case createFeedback
}

struct SyncCommand: Codable, Sendable {
    let operationId: String
    let entityId: String
    let kind: SyncCommandKind
    let baseVersion: Int?
    let payload: JSONValue

    init(
        operationId: String = UUID().uuidString,
        entityId: String,
        kind: SyncCommandKind,
        baseVersion: Int? = nil,
        payload: JSONValue = .object([:])
    ) {
        self.operationId = operationId
        self.entityId = entityId
        self.kind = kind
        self.baseVersion = baseVersion
        self.payload = payload
    }
}

/// A persisted, strongly typed description of work to be sent to the command
/// endpoint. `command` remains the single wire representation.
enum SyncWork: Codable, Sendable {
    case command(SyncCommand)

    var command: SyncCommand {
        switch self {
        case let .command(command): return command
        }
    }
}

enum SyncCommandResultStatus: String, Codable, Sendable {
    case applied
    case duplicate
    case conflict
    case rejected
    case retryable
}

/// Per-command outcome; conflicts carry the server version/resource for recovery.
struct SyncCommandResult: Decodable, Sendable {
    let operationId: String
    let entityId: String
    let kind: SyncCommandKind
    let status: SyncCommandResultStatus
    let code: String?
    let message: String?
    let currentVersion: Int?
    let resource: EntryResponse?
}

struct SyncCommandsResponse: Decodable, Sendable {
    let results: [SyncCommandResult]
}

/// Server-issued upload-session details that must be completed before the artifact becomes available.
struct ArtifactSessionCreateResponse: Decodable, Sendable {
    let sessionId: String
    let artifact: ArtifactResponse
    /// Idempotent creation can return the already-completed result without a
    /// presigned upload URL or completion call.
    let completed: Bool?
    let uploadUrl: String?
    let requiredHeaders: [String: String]?
    let expiresInSeconds: Int?
    let currentVersion: Int
}

struct ArtifactSessionRequest {
    let operationId: String
    let entryId: String
    let artifact: LocalArtifact
    let sizeBytes: Int
    let baseVersion: Int
}

/// Final artifact state returned after the server validates an upload session.
struct ArtifactSessionCompletionResponse: Decodable, Sendable {
    let artifact: ArtifactResponse
    let currentVersion: Int
}

/// Generic paginated response envelope returned by cursor-based pagination endpoints.
struct PaginatedResponse<T: Decodable>: Decodable {
    let items: [T]
    let nextCursor: String?
}

struct ReviewQueueEntry: Decodable {
    let id: String
    let courseId: String
    let studentId: String
    let studentName: String
    let kind: String?
    let practiceDate: Date
    let goalText: String
    let notes: String?
    let consentConfirmedAt: Date?
    let consentScope: String?
    let captureProfile: String?
    let captureMarkerCount: Int?
    let artifacts: [ArtifactResponse]
}

struct ArtifactResponse: Decodable {
    let id: String
    let entryId: String
    let type: String
    let durationSeconds: Int
    let expectedSizeBytes: Int?
    let uploadState: String
    let storageKey: String?
    let remoteUrl: String?
}

struct ArtifactDownloadResponse: Decodable {
    let downloadUrl: URL
    let expiresInSeconds: Int
}

struct FeedbackResponse: Decodable {
    let id: String
    let targetType: String
    let targetId: String
    let teacherName: String
    let createdAt: Date
    let status: String
    let commentsText: String
    let markers: [MarkerResponse]
}

struct MarkerResponse: Decodable {
    let id: String
    let timeSeconds: Int
    let text: String
}

struct CaptureMarkerResponse: Decodable {
    let id: String
    let entryId: String
    let artifactId: String
    let studentId: String
    let timeSeconds: Int
    let kind: String
    let note: String?
    let createdAt: Date
}

@MainActor
/// Applies remote-wins course snapshots while preserving entries with pending local commands.
final class EntryReconciliationService {
    private let modelContext: ModelContext
    private let apiClient: APIClient

    init(modelContext: ModelContext, apiClient: APIClient) {
        self.modelContext = modelContext
        self.apiClient = apiClient
    }

    /// Fetches all cursor pages, upserts authoritative rows, and removes only safe stale rows.
    func refresh(courseId: String, accessToken: String) async throws {
        let responses = try await fetchAllEntries(courseId: courseId, accessToken: accessToken)
        let localEntries = try modelContext.fetch(
            FetchDescriptor<LocalPracticeEntry>(predicate: #Predicate { $0.courseId == courseId })
        )
        let localById = Dictionary(uniqueKeysWithValues: localEntries.map { ($0.id, $0) })
        let remoteIds = Set(responses.map(\.id))
        let queuedEntryIds = pendingEntryIds()

        for response in responses {
            upsert(
                response,
                existing: localById[response.id],
                preserveLocalChanges: queuedEntryIds.contains(response.id)
            )
        }

        for local in localEntries where local.remoteUpdatedAt != nil &&
            !remoteIds.contains(local.id) && !queuedEntryIds.contains(local.id) {
            modelContext.delete(local)
        }
        try modelContext.save()
    }

    private func fetchAllEntries(courseId: String, accessToken: String) async throws -> [EntryResponse] {
        var responses: [EntryResponse] = []
        var cursor: String?
        var seen = Set<String>()

        repeat {
            let page = try await apiClient.fetchEntries(
                accessToken: accessToken,
                courseId: courseId,
                cursor: cursor
            )
            responses.append(contentsOf: page.items)
            guard let next = page.nextCursor, !next.isEmpty, seen.insert(next).inserted else {
                cursor = nil
                break
            }
            cursor = next
        } while cursor != nil

        return responses
    }

    private func upsert(
        _ response: EntryResponse,
        existing local: LocalPracticeEntry?,
        preserveLocalChanges: Bool
    ) {
        guard let local else {
            let details = PracticeEntryDetails(
                practiceDate: response.practiceDate,
                goalText: response.goalText,
                durationSeconds: response.durationSeconds,
                tags: response.tags,
                notes: response.notes
            )
            let context = CaptureContext(
                kind: EntryKind(rawValue: response.kind ?? "practice") ?? .practice,
                consentConfirmedAt: response.consentConfirmedAt,
                consentScope: response.consentScope.flatMap(ConsentScope.init(rawValue:)),
                captureProfile: response.captureProfile.flatMap(CaptureProfile.init(rawValue:))
            )
            let inserted = LocalPracticeEntry(
                id: response.id,
                courseId: response.courseId,
                studentId: response.studentId,
                details: details,
                status: EntryStatus(rawValue: response.status) ?? .draft,
                captureContext: context
            )
            let remoteDate = response.updatedAt ?? response.createdAt ?? Date()
            inserted.remoteUpdatedAt = remoteDate
            inserted.updatedAt = remoteDate
            inserted.serverVersion = response.version
            modelContext.insert(inserted)
            mergeArtifacts(response.artifacts ?? [], into: inserted)
            return
        }
        merge(response, into: local, preserveLocalChanges: preserveLocalChanges)
    }

    private func merge(
        _ response: EntryResponse,
        into local: LocalPracticeEntry,
        preserveLocalChanges: Bool
    ) {
        let remoteDate = response.updatedAt ?? response.createdAt ?? Date()
        if preserveLocalChanges || local.remoteUpdatedAt.map({ local.updatedAt > $0 }) == true {
            local.status = EntryStatus(rawValue: response.status) ?? local.status
            local.remoteUpdatedAt = remoteDate
            local.serverVersion = response.version
            mergeArtifacts(response.artifacts ?? [], into: local)
            return
        }
        local.studentId = response.studentId
        local.kind = EntryKind(rawValue: response.kind ?? "practice") ?? .practice
        local.practiceDate = response.practiceDate
        local.goalText = response.goalText
        local.durationSeconds = response.durationSeconds
        local.tags = response.tags
        local.notes = response.notes
        local.status = EntryStatus(rawValue: response.status) ?? .draft
        local.consentConfirmedAt = response.consentConfirmedAt
        local.consentScope = response.consentScope.flatMap(ConsentScope.init(rawValue:))
        local.captureProfile = response.captureProfile.flatMap(CaptureProfile.init(rawValue:))
        local.remoteUpdatedAt = remoteDate
        local.updatedAt = remoteDate
        local.serverVersion = response.version
        mergeArtifacts(response.artifacts ?? [], into: local)
    }

    private func mergeArtifacts(_ responses: [ArtifactResponse], into entry: LocalPracticeEntry) {
        let localById = Dictionary(uniqueKeysWithValues: entry.artifacts.map { ($0.id, $0) })
        for response in responses {
            if let local = localById[response.id] {
                local.durationSeconds = response.durationSeconds
                local.uploadState = UploadState(rawValue: response.uploadState) ?? local.uploadState
                local.storageKey = response.storageKey
                local.remoteUrl = response.remoteUrl
            } else {
                let artifact = LocalArtifact(
                    id: response.id,
                    entryId: entry.id,
                    type: ArtifactType(rawValue: response.type) ?? .audio,
                    durationSeconds: response.durationSeconds,
                    localPath: ""
                )
                artifact.uploadState = UploadState(rawValue: response.uploadState) ?? .uploaded
                artifact.syncPhase = artifact.uploadState == .uploaded ? .uploaded : .queued
                artifact.storageKey = response.storageKey
                artifact.remoteUrl = response.remoteUrl
                entry.artifacts.append(artifact)
                modelContext.insert(artifact)
            }
        }
    }

    private func pendingEntryIds() -> Set<String> {
        let queue = (try? modelContext.fetch(FetchDescriptor<SyncQueueItem>())) ?? []
        return Set(queue.compactMap { item in
            guard let data = item.payloadJSON.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return payload["entryId"] as? String
        })
    }
}
