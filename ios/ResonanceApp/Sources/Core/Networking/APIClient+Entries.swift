import Foundation

extension APIClient {
  func fetchCourses(accessToken: String) async throws -> [CourseResponse] {
    try await send(
      url: ServiceConfiguration.apiV1URL(path: "courses"), method: "GET", body: Optional<EmptyBody>.none,
      accessToken: accessToken)
  }

  func fetchEntries(accessToken: String, courseId: String, limit: Int = 50, cursor: String? = nil)
    async throws -> PaginatedResponse<EntryResponse> {
    try await sendPage(
      accessToken: accessToken, path: "courses/\(courseId)/entries", limit: limit, cursor: cursor)
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
