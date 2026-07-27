import Foundation

// Implements feedback, queued-command, and artifact-session endpoints for the API client.

extension APIClient {
  func fetchReviewQueue(
    accessToken: String, courseId: String, limit: Int? = nil, cursor: String? = nil
  ) async throws -> PaginatedResponse<ReviewQueueEntry> {
    var queryItems: [URLQueryItem] = []
    if let limit { queryItems.append(URLQueryItem(name: "limit", value: String(limit))) }
    if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
    let url = try makeURL(
      AppConfig.apiV1URL(path: "courses/\(courseId)/review-queue"), queryItems: queryItems)
    return try await send(
      url: url, method: "GET", body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

  func createFeedback(accessToken: String, submission: FeedbackSubmission) async throws
    -> FeedbackResponse {
    struct MarkerBody: Encodable {
      let timeSeconds: Int
      let text: String
    }
    struct Body: Encodable {
      let id: String?
      let targetType: String
      let targetId: String
      let status: String
      let commentsText: String
      let markers: [MarkerBody]
    }
    let body = Body(
      id: submission.feedbackId, targetType: submission.targetType, targetId: submission.targetId,
      status: submission.status.rawValue, commentsText: submission.commentsText,
      markers: submission.markers.map { MarkerBody(timeSeconds: $0.timeSeconds, text: $0.text) })
    return try await send(
      url: AppConfig.apiBaseURL.appendingPathComponent("feedback"), method: "POST", body: body,
      accessToken: accessToken)
  }

  func fetchFeedback(accessToken: String, entryId: String) async throws -> [FeedbackResponse] {
    try await send(
      url: AppConfig.apiV1URL(path: "entries/\(entryId)/feedback"), method: "GET",
      body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

  func sendSyncCommands(accessToken: String, commands: [SyncCommand]) async throws
    -> SyncCommandsResponse {
    guard !commands.isEmpty, commands.count <= 25 else {
      throw SyncError.invalidCommandBatchSize(commands.count)
    }
    struct Body: Encodable { let commands: [SyncCommand] }
    return try await send(
      url: AppConfig.apiV1URL(path: "sync/commands"), method: "POST",
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
      let baseVersion: Int
    }
    let body = Body(
      operationId: request.operationId, entryId: request.entryId, artifactId: request.artifact.id,
      type: request.artifact.type.rawValue, durationSeconds: request.artifact.durationSeconds,
      sizeBytes: request.sizeBytes, baseVersion: request.baseVersion)
    return try await send(
      url: AppConfig.apiV1URL(path: "artifact-sessions"), method: "POST", body: body,
      accessToken: accessToken)
  }

  /// Finalizes a completed upload so the server can publish the resulting artifact state.
  func completeArtifactSession(accessToken: String, sessionId: String) async throws
    -> ArtifactSessionCompletionResponse {
    try await send(
      url: AppConfig.apiV1URL(path: "artifact-sessions/\(sessionId)/complete"), method: "POST",
      body: Optional<EmptyBody>.none, accessToken: accessToken)
  }
}
