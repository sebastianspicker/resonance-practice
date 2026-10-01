import Foundation

/// Server-issued upload-session details that must be completed before the artifact becomes available.
struct ArtifactSessionCreateResponse: Decodable, Sendable {
    let sessionId: String
    let artifact: ArtifactResponse
    /// Idempotent creation can return the already-completed result without a
    /// presigned upload URL or completion call.
    let completed: Bool?
    let uploadUrl: String?
    let requiredHeaders: [String: String]?
    // swiftlint:disable:next unused_declaration
    let expiresInSeconds: Int? // Decoded wire field (v1 contract).
    let currentVersion: Int
}

struct ArtifactSessionRequest {
    let operationId: String
    let entryId: String
    let artifact: LocalArtifact
    let sizeBytes: Int
    /// Standard padded Base64 SHA-256 of the managed local media bytes.
    let checksumSha256: String
    let baseVersion: Int
}

/// Final artifact state returned after the server validates an upload session.
struct ArtifactSessionCompletionResponse: Decodable, Sendable {
    // swiftlint:disable:next unused_declaration
    let artifact: ArtifactResponse // Decoded wire field (v1 contract).
    let currentVersion: Int
}

struct ArtifactResponse: Decodable {
    let id: String
    // swiftlint:disable:next unused_declaration
    let entryId: String // Decoded server field, validated on decode.
    let type: String
    let durationSeconds: Int
    // swiftlint:disable:next unused_declaration
    let expectedSizeBytes: Int? // Decoded server field (optional).
    let uploadState: String
}

struct ArtifactDownloadResponse: Decodable {
    let downloadUrl: URL
    // swiftlint:disable:next unused_declaration
    let expiresInSeconds: Int // Decoded wire field (v1 contract).
}
