import Foundation

// Implements course, entry, artifact, and capture-marker endpoints for the API client.

extension APIClient {
  private struct EntryBody: Encodable {
    let id: String?
    let kind: String
    let practiceDate: Date
    let goalText: String
    let durationSeconds: Int?
    let tags: [String]
    let notes: String?
    let consentConfirmed: Bool?
    let consentScope: String?
    let captureProfile: String?
  }

  private func entryBody(_ entry: LocalPracticeEntry, includeID: Bool) -> EntryBody {
    EntryBody(
      id: includeID ? entry.id : nil, kind: entry.kind.rawValue, practiceDate: entry.practiceDate,
      goalText: entry.goalText, durationSeconds: entry.durationSeconds, tags: entry.tags,
      notes: entry.notes,
      consentConfirmed: includeID ? (entry.consentConfirmedAt == nil ? nil : true) : entry.consentConfirmedAt != nil,
      consentScope: entry.consentScope?.rawValue, captureProfile: entry.captureProfile?.rawValue)
  }

  func fetchCourses(accessToken: String) async throws -> [CourseResponse] {
    try await send(
      url: AppConfig.apiV1URL(path: "courses"), method: "GET", body: Optional<EmptyBody>.none,
      accessToken: accessToken)
  }

  func fetchEntries(accessToken: String, courseId: String, limit: Int = 50, cursor: String? = nil)
    async throws -> PaginatedResponse<EntryResponse> {
    var items = [URLQueryItem(name: "limit", value: String(limit))]
    if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
    let url = try makeURL(
      AppConfig.apiV1URL(path: "courses/\(courseId)/entries"), queryItems: items)
    return try await send(
      url: url, method: "GET", body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

  func fetchEntry(accessToken: String, entryId: String) async throws -> EntryResponse {
    try await send(
      url: AppConfig.apiV1URL(path: "entries/\(entryId)"), method: "GET",
      body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

  func createEntry(accessToken: String, courseId: String, entry: LocalPracticeEntry) async throws
    -> EntryResponse {
    let body = entryBody(entry, includeID: true)
    return try await send(
      url: AppConfig.apiBaseURL.appendingPathComponent("courses/\(courseId)/entries"),
      method: "POST", body: body, accessToken: accessToken)
  }

  func updateEntryCaptureProfile(
    accessToken: String, entryId: String, captureProfile: CaptureProfile?
  ) async throws -> EntryResponse {
    struct Body: Encodable { let captureProfile: String? }
    return try await send(
      url: AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)"), method: "PATCH",
      body: Body(captureProfile: captureProfile?.rawValue), accessToken: accessToken)
  }

  func updateEntry(accessToken: String, entry: LocalPracticeEntry) async throws -> EntryResponse {
    let body = entryBody(entry, includeID: false)
    return try await send(
      url: AppConfig.apiBaseURL.appendingPathComponent("entries/\(entry.id)"), method: "PATCH",
      body: body, accessToken: accessToken)
  }

  func fetchArtifactDownloadURL(accessToken: String, artifactId: String) async throws
    -> ArtifactDownloadResponse {
    try await send(
      url: AppConfig.apiV1URL(path: "artifacts/\(artifactId)/download-session"), method: "POST",
      body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

  func submitEntry(accessToken: String, entryId: String) async throws -> EntryResponse {
    try await send(
      url: AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)/submit"), method: "POST",
      body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

  func syncCaptureMarkers(accessToken: String, entryId: String, markers: [LocalCaptureMarker])
    async throws -> [CaptureMarkerResponse] {
    struct MarkerBody: Encodable {
      let id: String
      let artifactId: String
      let timeSeconds: Int
      let kind: String
      let note: String?
    }
    struct Body: Encodable { let markers: [MarkerBody] }
    let body = Body(
      markers: markers.map {
        MarkerBody(
          id: $0.id, artifactId: $0.artifactId, timeSeconds: $0.timeSeconds, kind: $0.kind.rawValue,
          note: $0.note)
      })
    return try await send(
      url: AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)/capture-markers"),
      method: "PUT", body: body, accessToken: accessToken)
  }

  /// Requests permanent deletion of the server entry after local work has been coordinated.
  func deleteEntry(accessToken: String, entryId: String) async throws {
    try await sendNoContent(
      url: AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)"), method: "DELETE",
      accessToken: accessToken)
  }
}
