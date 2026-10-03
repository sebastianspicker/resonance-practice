import Foundation

extension APIClient {
  func fetchReviewQueue(
    accessToken: String, courseId: String, limit: Int? = nil, cursor: String? = nil
  ) async throws -> PaginatedResponse<ReviewQueueEntry> {
    try await sendPage(
      accessToken: accessToken, path: "courses/\(courseId)/review-queue", limit: limit, cursor: cursor)
  }

  func fetchFeedback(
    accessToken: String, entryId: String, limit: Int = 50, cursor: String? = nil
  ) async throws -> PaginatedResponse<FeedbackResponse> {
    try await sendPage(
      accessToken: accessToken, path: "entries/\(entryId)/feedback", limit: limit, cursor: cursor)
  }

  func sendSyncCommands(accessToken: String, commands: [SyncCommand]) async throws
    -> SyncCommandsResponse {
    guard !commands.isEmpty, commands.count <= 25 else {
      throw SyncError.invalidCommandBatchSize(commands.count)
    }
    struct Body: Encodable { let commands: [SyncCommand] }
    return try await send(
      url: ServiceConfiguration.apiV1URL(path: "sync/commands"), method: "POST",
      body: Body(commands: commands), accessToken: accessToken)
  }

  /// Opens the server-controlled upload session that binds an artifact to an entry and version.
  func createArtifactSession(
    accessToken: String, request: ArtifactSessionRequest
  ) async throws -> ArtifactSessionCreateResponse {
    struct Body: Encodable {
      let operationId: String
      let entryId: String
      let artifactId: String
      let type: String
      let durationSeconds: Int
      let sizeBytes: Int
      let checksumSha256: String
      let baseVersion: Int
    }
    let body = Body(
      operationId: request.operationId, entryId: request.entryId, artifactId: request.artifact.id,
      type: request.artifact.type.rawValue, durationSeconds: request.artifact.durationSeconds,
      sizeBytes: request.sizeBytes, checksumSha256: request.checksumSha256,
      baseVersion: request.baseVersion)
    return try await send(
      url: ServiceConfiguration.apiV1URL(path: "artifact-sessions"), method: "POST", body: body,
      accessToken: accessToken)
  }

  /// Finalizes a completed upload so the server can publish the resulting artifact state.
  func completeArtifactSession(accessToken: String, sessionId: String) async throws
    -> ArtifactSessionCompletionResponse {
    try await send(
      url: ServiceConfiguration.apiV1URL(path: "artifact-sessions/\(sessionId)/complete"), method: "POST",
      body: Optional<EmptyBody>.none, accessToken: accessToken)
  }
}
