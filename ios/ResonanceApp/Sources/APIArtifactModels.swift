import Foundation

// Defines artifact projections and upload-session payloads.

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
