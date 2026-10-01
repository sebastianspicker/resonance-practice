import Foundation
import XCTest

@testable import ResonanceApp

final class APIClientSyncCommandTests: APIRequestCaptureTestCase {
  // v1-contract-projection:start
  // Generated from contracts/v1-api-contract.json. Do not edit by hand; run
  // node scripts/generate-v1-contract-projection.mjs --write after contract changes.
  private enum V1APIContractProjection {
    static let fingerprint = "a0e7a2b5a019ba08d0a1a6328ac694a34bd2e38472bb3839f85b44098390e78c"
    static let routes: [(String, String)] = [
      ("GET", "/api/v1/courses"),
      ("GET", "/api/v1/courses/:courseId/entries"),
      ("GET", "/api/v1/courses/:courseId/review-queue"),
      ("GET", "/api/v1/entries/:entryId"),
      ("GET", "/api/v1/entries/:entryId/feedback"),
      ("POST", "/api/v1/artifact-sessions"),
      ("POST", "/api/v1/artifact-sessions/:sessionId/complete"),
      ("POST", "/api/v1/artifacts/:artifactId/download-session"),
      ("POST", "/api/v1/sync/commands"),
    ]
    static let commandFields = [
      "operationId",
      "entityId",
      "kind",
      "baseVersion",
      "payload",
    ]
    static let pageFields = [
      "items",
      "nextCursor",
    ]
    static let defaultPageSize = 50
    static let maxPageSize = 200
    static let feedbackOrder = [
      "createdAt:asc",
      "id:asc",
    ]
    static let reviewQueueOmittedFields = [
      "captureMarkers",
    ]
    static let commandKinds = [
      "createEntry",
      "updateEntry",
      "replaceCaptureMarkers",
      "submitEntry",
      "deleteEntry",
      "createFeedback",
    ]
    static let resultFields = [
      "operationId",
      "entityId",
      "kind",
      "status",
      "code",
      "message",
      "currentVersion",
      "resource",
    ]
    static let resultStatuses = [
      "applied",
      "duplicate",
      "conflict",
      "rejected",
      "retryable",
    ]
    static let artifactSessionCreateRequestFields = [
      "operationId",
      "entryId",
      "artifactId",
      "type",
      "durationSeconds",
      "sizeBytes",
      "checksumSha256",
      "baseVersion",
    ]
    static let artifactSessionChecksumEncoding = "padded-base64"
    static let artifactSessionChecksumDecodedByteLength = 32
    static let artifactSessionCreateResponseFields = [
      "sessionId",
      "artifact",
      "uploadUrl",
      "requiredHeaders",
      "expiresInSeconds",
      "currentVersion",
      "completed",
    ]
    static let artifactSessionCompleteResponseFields = [
      "artifact",
      "currentVersion",
    ]
    static let artifactDownloadResponseFields = [
      "downloadUrl",
      "expiresInSeconds",
    ]
    static let errorFields = [
      "code",
      "message",
      "details",
      "requestId",
      "currentVersion",
    ]
  }
  // v1-contract-projection:end

  func testGeneratedV1ContractProjectionMatchesNetworkingTypes() throws {
    let expectedRoutes: [(String, String)] = [
      ("GET", ServiceConfiguration.apiV1URL(path: "courses").path),
      ("GET", ServiceConfiguration.apiV1URL(path: "courses/course-1/entries").path),
      ("GET", ServiceConfiguration.apiV1URL(path: "courses/course-1/review-queue").path),
      ("GET", ServiceConfiguration.apiV1URL(path: "entries/entry-1").path),
      ("GET", ServiceConfiguration.apiV1URL(path: "entries/entry-1/feedback").path),
      ("POST", ServiceConfiguration.apiV1URL(path: "artifact-sessions").path),
      ("POST", ServiceConfiguration.apiV1URL(path: "artifact-sessions/session-1/complete").path),
      ("POST", ServiceConfiguration.apiV1URL(path: "artifacts/artifact-1/download-session").path),
      ("POST", ServiceConfiguration.apiV1URL(path: "sync/commands").path),
    ]
    let concreteContractRoutes = V1APIContractProjection.routes.map { method, path in
      (method, path
        .replacingOccurrences(of: ":courseId", with: "course-1")
        .replacingOccurrences(of: ":entryId", with: "entry-1")
        .replacingOccurrences(of: ":sessionId", with: "session-1")
        .replacingOccurrences(of: ":artifactId", with: "artifact-1"))
    }
    XCTAssertEqual(
      concreteContractRoutes.map { "\($0.0) \($0.1)" }.sorted(),
      expectedRoutes.map { "\($0.0) \($0.1)" }.sorted())
    XCTAssertEqual(V1APIContractProjection.commandKinds, [
      SyncCommandKind.createEntry.rawValue,
      SyncCommandKind.updateEntry.rawValue,
      SyncCommandKind.replaceCaptureMarkers.rawValue,
      SyncCommandKind.submitEntry.rawValue,
      SyncCommandKind.deleteEntry.rawValue,
      SyncCommandKind.createFeedback.rawValue,
    ])
    XCTAssertEqual(V1APIContractProjection.resultStatuses, [
      SyncCommandResultStatus.applied.rawValue,
      SyncCommandResultStatus.duplicate.rawValue,
      SyncCommandResultStatus.conflict.rawValue,
      SyncCommandResultStatus.rejected.rawValue,
      SyncCommandResultStatus.retryable.rawValue,
    ])
    XCTAssertEqual(V1APIContractProjection.pageFields, ["items", "nextCursor"])
    XCTAssertEqual(V1APIContractProjection.defaultPageSize, 50)
    XCTAssertEqual(V1APIContractProjection.maxPageSize, 200)
    XCTAssertEqual(V1APIContractProjection.feedbackOrder, ["createdAt:asc", "id:asc"])
    XCTAssertEqual(V1APIContractProjection.reviewQueueOmittedFields, ["captureMarkers"])

    let command = SyncCommand(
      operationId: "operation-1", entityId: "entry-1", kind: .updateEntry, baseVersion: 2)
    let encodedCommand = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command))
    let commandObject = try XCTUnwrap(encodedCommand as? [String: Any])
    XCTAssertEqual(Set(commandObject.keys), Set(V1APIContractProjection.commandFields))

    let result = try JSONDecoder().decode(
      SyncCommandResult.self,
      from: Data(
        """
        {"operationId":"operation-1","entityId":"entry-1","kind":"updateEntry",
        "status":"conflict","code":"VERSION_CONFLICT","message":"Entry changed",
        "currentVersion":4,"resource":null}
        """.utf8))
    XCTAssertEqual(result.status.rawValue, "conflict")
    XCTAssertEqual(result.currentVersion, 4)
    XCTAssertEqual(result.code, "VERSION_CONFLICT")
    XCTAssertEqual(Set(V1APIContractProjection.resultFields), [
      "operationId", "entityId", "kind", "status", "code", "message", "currentVersion", "resource",
    ])

    let error = try JSONDecoder().decode(
      APIError.self,
      from: Data(
        """
        {"error":{"code":"VERSION_CONFLICT","message":"Entry changed",
        "details":{"actual":4},"requestId":"request-1","currentVersion":4}}
        """.utf8))
    XCTAssertEqual(error.error.code, "VERSION_CONFLICT")
    XCTAssertEqual(error.error.requestId, "request-1")
    XCTAssertEqual(error.error.currentVersion, 4)
    XCTAssertEqual(error.error.details?["actual"], .integer(4))
    XCTAssertEqual(Set(V1APIContractProjection.errorFields), [
      "code", "message", "details", "requestId", "currentVersion",
    ])
  }

  private static let artifactSessionCreateResponseJSON = Data(
    """
    {
      "sessionId":"session-1",
      "artifact":{"id":"artifact-1","entryId":"entry-1","type":"audio","durationSeconds":30,"uploadState":"uploading"},
      "completed":false,"uploadUrl":"https://storage.example/upload",
      "requiredHeaders":{"Content-Type":"audio/m4a"},"expiresInSeconds":900,"currentVersion":8
    }
    """.utf8)

  @MainActor
  func testSyncCommandsUsesVersionedAbsolutePathAndEncodesOperationMetadata() async throws {
    let expectedURL = ServiceConfiguration.apiV1URL(path: "sync/commands")
    var capturedBody: Data?
    APIClientCaptureURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url, expectedURL)
      XCTAssertEqual(request.httpMethod, "POST")
      capturedBody = try XCTUnwrap(testRequestBodyData(request))
      return (
        HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data(
          "{\"results\":[{\"operationId\":\"op-1\",\"entityId\":\"entry-1\",\"kind\":\"updateEntry\",\"status\":\"applied\",\"currentVersion\":4}]}"
            .utf8)
      )
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [APIClientCaptureURLProtocol.self]
    let response = try await APIClient(session: URLSession(configuration: configuration))
      .sendSyncCommands(
        accessToken: "access-token",
        commands: [
          SyncCommand(
            operationId: "op-1", entityId: "entry-1", kind: .updateEntry, baseVersion: 3,
            payload: .object(["goalText": .string("Scales")]))
        ]
      )

    let body = try XCTUnwrap(capturedBody)
    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let command = try XCTUnwrap((envelope["commands"] as? [[String: Any]])?.first)
    XCTAssertEqual(command["operationId"] as? String, "op-1")
    XCTAssertEqual(command["baseVersion"] as? Int, 3)
    XCTAssertEqual(response.results.first?.currentVersion, 4)
  }

  @MainActor
  func testArtifactSessionUsesVersionedAllocationAndCompletionContracts() async throws {
    let createURL = ServiceConfiguration.apiV1URL(path: "artifact-sessions")
    let completionURL = ServiceConfiguration.apiV1URL(path: "artifact-sessions/session-1/complete")
    let createResponse = Self.artifactSessionCreateResponseJSON
    let completionResponse = Data(
      """
      {
        "artifact":{"id":"artifact-1","entryId":"entry-1","type":"audio",
        "durationSeconds":30,"uploadState":"uploaded",
        "storageKey":"artifacts/final/entry-1/artifact-1"},
        "currentVersion":9
      }
      """.utf8)
    var requestedURLs: [URL] = []
    var createBody: Data?
    APIClientCaptureURLProtocol.requestHandler = { request in
      let url = try XCTUnwrap(request.url)
      requestedURLs.append(url)
      switch url {
      case createURL:
        createBody = try XCTUnwrap(testRequestBodyData(request))
        return (
          HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          createResponse
        )
      case completionURL:
        return (
          HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
          completionResponse
        )
      default:
        throw URLError(.badURL)
      }
    }

    let artifact = LocalArtifact(
      id: "artifact-1", entryId: "entry-1", type: .audio, durationSeconds: 30, localPath: "")
    let client = makeCapturingAPIClient()
    let checksumSha256 = "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="
    let created = try await client.createArtifactSession(
      accessToken: "access-token",
      request: ArtifactSessionRequest(
        operationId: "operation-1", entryId: "entry-1", artifact: artifact, sizeBytes: 4096,
        checksumSha256: checksumSha256,
        baseVersion: 7))
    let completed = try await client.completeArtifactSession(
      accessToken: "access-token", sessionId: created.sessionId)

    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(createBody)) as? [String: Any])
    XCTAssertEqual(payload["artifactId"] as? String, artifact.id)
    XCTAssertEqual(payload["baseVersion"] as? Int, 7)
    XCTAssertEqual(payload["checksumSha256"] as? String, checksumSha256)
    XCTAssertEqual(Set(payload.keys), Set(V1APIContractProjection.artifactSessionCreateRequestFields))
    XCTAssertEqual(V1APIContractProjection.artifactSessionChecksumEncoding, "padded-base64")
    XCTAssertEqual(
      try XCTUnwrap(Data(base64Encoded: checksumSha256)).count,
      V1APIContractProjection.artifactSessionChecksumDecodedByteLength)
    XCTAssertEqual(
      Set(try XCTUnwrap(JSONSerialization.jsonObject(with: createResponse) as? [String: Any]).keys),
      Set(V1APIContractProjection.artifactSessionCreateResponseFields))
    XCTAssertEqual(
      Set(try XCTUnwrap(JSONSerialization.jsonObject(with: completionResponse) as? [String: Any]).keys),
      Set(V1APIContractProjection.artifactSessionCompleteResponseFields))
    XCTAssertEqual(requestedURLs, [createURL, completionURL])
    XCTAssertEqual(created.currentVersion, 8)
    XCTAssertEqual(completed.artifact.uploadState, "uploaded")
    XCTAssertEqual(completed.currentVersion, 9)
  }

  func testArtifactDownloadResponseUsesStableContractFields() throws {
    let responseData = Data(
      """
      {"downloadUrl":"https://storage.example/download","expiresInSeconds":900}
      """.utf8)
    let response = try JSONDecoder().decode(ArtifactDownloadResponse.self, from: responseData)
    let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])

    XCTAssertEqual(Set(responseObject.keys), Set(V1APIContractProjection.artifactDownloadResponseFields))
    XCTAssertEqual(response.downloadUrl.absoluteString, "https://storage.example/download")
    XCTAssertEqual(response.expiresInSeconds, 900)
  }

  func testMediaChecksumUsesStandardPaddedBase64WithoutReadingWholeFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("abc".utf8).write(to: url)

    XCTAssertEqual(
      try MediaChecksum.sha256Base64(for: url),
      "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=")
  }

  func testArtifactAndEntryModelsDecodeProfileAndSessionProjection() throws {
    let entryJSON = Data(
      """
      {
        "id":"entry-1","courseId":"course-1","studentId":"student-1",
        "kind":"teaching_lesson","practiceDate":"2026-01-02T12:00:00.123Z",
        "goalText":"Model","durationSeconds":null,"tags":[],"notes":null,
        "status":"submitted","captureProfile":"ensemble_group","version":7
      }
      """.utf8)
    let entry = try JSONDecoder.apiDecoder.decode(
      EntryResponse.self,
      from: entryJSON)
    let session = try JSONDecoder.apiDecoder.decode(
      ArtifactSessionCreateResponse.self,
      from: Self.artifactSessionCreateResponseJSON)

    XCTAssertEqual(entry.captureProfile, CaptureProfile.ensembleGroup.rawValue)
    XCTAssertEqual(entry.version, 7)
    XCTAssertEqual(session.artifact.id, "artifact-1")
    XCTAssertEqual(session.currentVersion, 8)
  }
}
