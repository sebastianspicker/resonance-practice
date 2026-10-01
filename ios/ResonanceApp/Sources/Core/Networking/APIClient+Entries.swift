import Foundation

extension APIClient {
  func fetchCourses(accessToken: String) async throws -> [CourseResponse] {
    try await send(
      url: ServiceConfiguration.apiV1URL(path: "courses"), method: "GET", body: Optional<EmptyBody>.none,
      accessToken: accessToken)
  }

  func fetchEntries(accessToken: String, courseId: String, limit: Int = 50, cursor: String? = nil)
    async throws -> PaginatedResponse<EntryResponse> {
    var items = [URLQueryItem(name: "limit", value: String(limit))]
    if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
    let url = try makeURL(
      ServiceConfiguration.apiV1URL(path: "courses/\(courseId)/entries"), queryItems: items)
    return try await send(
      url: url, method: "GET", body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

  func fetchEntry(accessToken: String, entryId: String) async throws -> EntryResponse {
    try await send(
      url: ServiceConfiguration.apiV1URL(path: "entries/\(entryId)"), method: "GET",
      body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

  func fetchArtifactDownloadURL(accessToken: String, artifactId: String) async throws
    -> ArtifactDownloadResponse {
    try await send(
      url: ServiceConfiguration.apiV1URL(path: "artifacts/\(artifactId)/download-session"), method: "POST",
      body: Optional<EmptyBody>.none, accessToken: accessToken)
  }

}
