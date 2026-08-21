import Foundation

// Defines strongly typed durable commands and their ordered-sync outcomes.

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
