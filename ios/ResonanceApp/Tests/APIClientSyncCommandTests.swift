import Foundation
import XCTest

@testable import ResonanceApp

final class APIClientSyncCommandTests: APIRequestCaptureTestCase {
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
    let expectedURL = AppConfig.apiV1URL(path: "sync/commands")
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
    let createURL = AppConfig.apiV1URL(path: "artifact-sessions")
    let completionURL = AppConfig.apiV1URL(path: "artifact-sessions/session-1/complete")
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
    let created = try await client.createArtifactSession(
      accessToken: "access-token",
      request: ArtifactSessionRequest(
        operationId: "operation-1", entryId: "entry-1", artifact: artifact, sizeBytes: 4096,
        baseVersion: 7))
    let completed = try await client.completeArtifactSession(
      accessToken: "access-token", sessionId: created.sessionId)

    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(createBody)) as? [String: Any])
    XCTAssertEqual(payload["artifactId"] as? String, artifact.id)
    XCTAssertEqual(payload["baseVersion"] as? Int, 7)
    XCTAssertEqual(requestedURLs, [createURL, completionURL])
    XCTAssertEqual(created.currentVersion, 8)
    XCTAssertEqual(completed.artifact.uploadState, "uploaded")
    XCTAssertEqual(completed.currentVersion, 9)
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
