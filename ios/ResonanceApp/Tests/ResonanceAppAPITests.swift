import XCTest
import SwiftData
@testable import ResonanceApp

private final class APIClientCaptureURLProtocol: TestRequestURLProtocol {}

private final class RequestBodyCapture {
    var body: Data?
}

// Purpose: verifies API request construction, transport handling, and artifact-session contracts.

private let artifactSessionCreateResponse = Data(
    """
    {"sessionId":"session-1","artifact":{"id":"artifact-1","entryId":"entry-1",
    "type":"audio","durationSeconds":30,"uploadState":"pending","storageKey":null,
    "remoteUrl":null},"uploadUrl":"https://storage.example.test/upload/session-1",
    "requiredHeaders":{"Content-Type":"audio/m4a"},"expiresInSeconds":900,"currentVersion":8}
    """.utf8
)

private let artifactSessionCompletionResponse = Data(
    """
    {"artifact":{"id":"artifact-1","entryId":"entry-1","type":"audio",
    "durationSeconds":30,"uploadState":"uploaded",
    "storageKey":"artifacts/entry-1/artifact-1",
    "remoteUrl":"https://storage.example.test/artifact-1"},"currentVersion":9}
    """.utf8
)

private func teachingEntryResponse(captureProfile: String? = nil) -> Data {
    let captureProfileField = captureProfile.map { ",\n    \"captureProfile\": \"\($0)\"" } ?? ""
    return Data(
        """
        {
            "id": "entry-teaching",
            "courseId": "course-1",
            "studentId": "student-1",
            "kind": "teaching_lesson",
            "practiceDate": "2026-02-23T12:00:00Z",
            "goalText": "Teach rhythm ostinato",
            "durationSeconds": null,
            "tags": ["lehramt"],
            "notes": null,
            "status": "draft",
            "consentConfirmedAt": "2026-02-23T12:01:00Z",
            "consentScope": "private_course_review"\(captureProfileField)
        }
        """.utf8
    )
}

// MARK: - App Configuration Tests

final class AppConfigResolveURLTests: XCTestCase {
    func testValidAbsoluteHTTPBaseURLIsAccepted() {
        let url = AppConfig.resolveAPIBaseURL("https://api.example.edu/resonance")

        XCTAssertEqual(url.absoluteString, "https://api.example.edu/resonance")
    }

    func testMalformedOrRelativeBaseURLFallsBackToLocalDefault() {
        XCTAssertEqual(
            AppConfig.resolveAPIBaseURL("%").absoluteString,
            "http://localhost:4000"
        )
        XCTAssertEqual(
            AppConfig.resolveAPIBaseURL("api.example.edu").absoluteString,
            "http://localhost:4000"
        )
    }

    func testBaseURLRejectsCredentialsQueryAndUnsupportedScheme() {
        for value in [
            "https://user:password@api.example.edu",
            "https://api.example.edu?token=secret",
            "ftp://api.example.edu"
        ] {
            XCTAssertEqual(
                AppConfig.resolveAPIBaseURL(value).absoluteString,
                "http://localhost:4000",
                "Expected invalid API base URL to fall back: \(value)"
            )
        }
    }
}

// MARK: - App Configuration Tests

final class AppConfigResolveURLTests: XCTestCase {
    func testValidAbsoluteHTTPBaseURLIsAccepted() {
        let url = AppConfig.resolveAPIBaseURL("https://api.example.edu/resonance")

        XCTAssertEqual(url.absoluteString, "https://api.example.edu/resonance")
    }

    func testMalformedOrRelativeBaseURLFallsBackToLocalDefault() {
        XCTAssertEqual(
            AppConfig.resolveAPIBaseURL("%").absoluteString,
            "http://localhost:4000"
        )
        XCTAssertEqual(
            AppConfig.resolveAPIBaseURL("api.example.edu").absoluteString,
            "http://localhost:4000"
        )
    }

    func testBaseURLRejectsCredentialsQueryAndUnsupportedScheme() {
        for value in [
            "https://user:password@api.example.edu",
            "https://api.example.edu?token=secret",
            "ftp://api.example.edu"
        ] {
            XCTAssertEqual(
                AppConfig.resolveAPIBaseURL(value).absoluteString,
                "http://localhost:4000",
                "Expected invalid API base URL to fall back: \(value)"
            )
        }
    }
}

// MARK: - APIClient Request Encoding Tests

final class APIClientRequestEncodingTests: XCTestCase {
    override func tearDown() {
        APIClientCaptureURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    private func makeCapturingAPIClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientCaptureURLProtocol.self]
        return APIClient(session: URLSession(configuration: configuration))
    }

    @MainActor
    private func installRequestBodyCapture(
        expectedURL: URL,
        method: String,
        response: Data,
        expectedContentType: String? = nil
    ) -> RequestBodyCapture {
        let capture = RequestBodyCapture()
        APIClientCaptureURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.httpMethod, method)
            if let expectedContentType {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), expectedContentType)
            }
            capture.body = try XCTUnwrap(testRequestBodyData(request))
            return (
                HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                response
            )
        }
        return capture
    }

    private func decodedJSON(from capture: RequestBodyCapture) throws -> [String: Any] {
        let body = try XCTUnwrap(capture.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @MainActor
    private func makeEntryForEncoding(
        id: String,
        goalText: String,
        tags: [String],
        captureContext: CaptureContext? = nil
    ) -> LocalPracticeEntry {
        LocalPracticeEntry(
            id: id,
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(
                practiceDate: Date(timeIntervalSince1970: 1_771_848_000),
                goalText: goalText,
                durationSeconds: nil,
                tags: tags,
                notes: nil
            ),
            status: .draft,
            captureContext: captureContext ?? .practice
        )
    }

    @MainActor
    private func createEntryAndDecode(
        _ entry: LocalPracticeEntry,
        capture: RequestBodyCapture
    ) async throws -> [String: Any] {
        _ = try await makeCapturingAPIClient().createEntry(
            accessToken: "access-token",
            courseId: "course-1",
            entry: entry
        )
        return try decodedJSON(from: capture)
    }

    @MainActor
    func testCreateEntryWithNilOptionalFieldsEncodesValidJSONAndOmitsKeys() async throws {
        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("courses/course-1/entries")
        let response = Data("""
            {
                "id": "entry-nil-optionals",
                "courseId": "course-1",
                "studentId": "student-1",
                "practiceDate": "2026-02-23T12:00:00Z",
                "goalText": "Goal",
                "durationSeconds": null,
                "tags": ["tone"],
                "notes": null,
                "status": "draft"
            }
            """.utf8)
        let capture = installRequestBodyCapture(
            expectedURL: expectedURL,
            method: "POST",
            response: response,
            expectedContentType: "application/json"
        )

        let entry = makeEntryForEncoding(id: "entry-nil-optionals", goalText: "Goal", tags: ["tone"])
        let json = try await createEntryAndDecode(entry, capture: capture)
        XCTAssertEqual(json["id"] as? String, "entry-nil-optionals")
        XCTAssertEqual(json["goalText"] as? String, "Goal")
        XCTAssertEqual(json["kind"] as? String, "practice")
        XCTAssertEqual(json["tags"] as? [String], ["tone"])
        XCTAssertFalse(json.keys.contains("durationSeconds"))
        XCTAssertFalse(json.keys.contains("notes"))
        XCTAssertFalse(json.keys.contains("consentConfirmed"))
        XCTAssertFalse(json.keys.contains("consentScope"))
        XCTAssertFalse(json.keys.contains("captureProfile"))
    }

    @MainActor
    func testCreateTeachingLessonEntryEncodesConsentMetadata() async throws {
        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("courses/course-1/entries")
        let capture = installRequestBodyCapture(
            expectedURL: expectedURL,
            method: "POST",
            response: teachingEntryResponse()
        )

        let entry = makeEntryForEncoding(
            id: "entry-teaching",
            goalText: "Teach rhythm ostinato",
            tags: ["lehramt"],
            captureContext: CaptureContext(
                kind: .teachingLesson,
                consentConfirmedAt: Date(timeIntervalSince1970: 1_771_848_060),
                consentScope: .privateCourseReview,
                captureProfile: .teacherLearner
            )
        )

        let json = try await createEntryAndDecode(entry, capture: capture)
        XCTAssertEqual(json["kind"] as? String, "teaching_lesson")
        XCTAssertEqual(json["consentConfirmed"] as? Bool, true)
        XCTAssertEqual(json["consentScope"] as? String, "private_course_review")
        XCTAssertEqual(json["captureProfile"] as? String, "teacher_learner")
    }

    @MainActor
    func testUpdateEntryCaptureProfileEncodesPatch() async throws {
        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("entries/entry-teaching")
        let capture = installRequestBodyCapture(
            expectedURL: expectedURL,
            method: "PATCH",
            response: teachingEntryResponse(captureProfile: "ensemble_group")
        )

        let client = makeCapturingAPIClient()

        _ = try await client.updateEntryCaptureProfile(
            accessToken: "access-token",
            entryId: "entry-teaching",
            captureProfile: .ensembleGroup
        )

        let json = try decodedJSON(from: capture)
        XCTAssertEqual(json["captureProfile"] as? String, "ensemble_group")
    }

    @MainActor
    func testCreateArtifactEncodesLocalFileByteSize() async throws {
        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("entries/entry-1/artifacts")
        var capturedBody: Data?
        APIClientCaptureURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.httpMethod, "POST")
            capturedBody = try XCTUnwrap(requestBodyData(request))
            return (
                HTTPURLResponse(url: expectedURL, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data("{\"id\":\"artifact-1\",\"entryId\":\"entry-1\",\"type\":\"audio\",\"durationSeconds\":30,\"uploadState\":\"pending\",\"storageKey\":null,\"remoteUrl\":null}".utf8)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientCaptureURLProtocol.self]
        let artifact = LocalArtifact(
            id: "artifact-1",
            entryId: "entry-1",
            type: .audio,
            durationSeconds: 30,
            localPath: "/tmp/artifact-1.m4a"
        )

        _ = try await APIClient(session: URLSession(configuration: configuration)).createArtifact(
            accessToken: "access-token",
            entryId: "entry-1",
            artifact: artifact,
            sizeBytes: 4_096
        )

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, "artifact-1")
        XCTAssertEqual(json["sizeBytes"] as? Int, 4_096)
    }

    @MainActor
    func testSyncCaptureMarkersEncodesBatchPut() async throws {
        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("entries/entry-teaching/capture-markers")
        let responseData = Data("""
            [
                {
                    "id": "marker-1",
                    "entryId": "entry-teaching",
                    "artifactId": "artifact-video",
                    "studentId": "student-1",
                    "timeSeconds": 12,
                    "kind": "phase_modeling",
                    "note": "Modeling begins.",
                    "createdAt": "2026-04-29T12:00:00Z"
                }
            ]
            """.utf8)
        let capture = installRequestBodyCapture(
            expectedURL: expectedURL,
            method: "PUT",
            response: responseData
        )

        let client = makeCapturingAPIClient()
        let marker = LocalCaptureMarker(
            id: "marker-1",
            entryId: "entry-teaching",
            artifactId: "artifact-video",
            timeSeconds: 12,
            kind: .phaseModeling,
            note: "Modeling begins."
        )

        let response = try await client.syncCaptureMarkers(
            accessToken: "access-token",
            entryId: "entry-teaching",
            markers: [marker]
        )

        let json = try decodedJSON(from: capture)
        let markers = try XCTUnwrap(json["markers"] as? [[String: Any]])
        XCTAssertEqual(markers[0]["id"] as? String, "marker-1")
        XCTAssertEqual(markers[0]["artifactId"] as? String, "artifact-video")
        XCTAssertEqual(markers[0]["timeSeconds"] as? Int, 12)
        XCTAssertEqual(markers[0]["kind"] as? String, "phase_modeling")
        XCTAssertEqual(response[0].kind, "phase_modeling")
    }

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
                    """
                    {"results":[{"operationId":"op-1","entityId":"entry-1","kind":"updateEntry",
                    "status":"applied","currentVersion":4}]}
                    """.utf8
                )
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientCaptureURLProtocol.self]
        let response = try await APIClient(session: URLSession(configuration: configuration)).sendSyncCommands(
            accessToken: "access-token",
            commands: [
                SyncCommand(
                    operationId: "op-1",
                    entityId: "entry-1",
                    kind: .updateEntry,
                    baseVersion: 3,
                    payload: .object(["goalText": .string("Scales")])
                )
            ]
        )
        let body = try XCTUnwrap(capturedBody)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let commands = try XCTUnwrap(envelope["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0]["operationId"] as? String, "op-1")
        XCTAssertEqual(commands[0]["baseVersion"] as? Int, 3)
        XCTAssertEqual(response.results.single?.currentVersion, 4)
    }

    @MainActor
    func testArtifactSessionsUseV1CreateAndCompletionContracts() async throws {
        let createURL = AppConfig.apiV1URL(path: "artifact-sessions")
        let completionURL = AppConfig.apiV1URL(path: "artifact-sessions/session-1/complete")
        var capturedCreateBody: Data?
        var requestedURLs: [URL] = []
        APIClientCaptureURLProtocol.requestHandler = { request in
            requestedURLs.append(try XCTUnwrap(request.url))
            switch request.url {
            case createURL:
                XCTAssertEqual(request.httpMethod, "POST")
                capturedCreateBody = try XCTUnwrap(testRequestBodyData(request))
                return (
                    HTTPURLResponse(url: createURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    artifactSessionCreateResponse
                )
            case completionURL:
                XCTAssertEqual(request.httpMethod, "POST")
                return (
                    HTTPURLResponse(url: completionURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    artifactSessionCompletionResponse
                )
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (HTTPURLResponse(url: createURL, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientCaptureURLProtocol.self]
        let artifact = LocalArtifact(
            id: "artifact-1",
            entryId: "entry-1",
            type: .audio,
            durationSeconds: 30,
            localPath: "/tmp/artifact-1.m4a"
        )
        let client = APIClient(session: URLSession(configuration: configuration))

        let create = try await client.createArtifactSession(
            accessToken: "access-token",
            request: ArtifactSessionRequest(
                operationId: "operation-1",
                entryId: "entry-1",
                artifact: artifact,
                sizeBytes: 4_096,
                baseVersion: 7
            )
        )
        let completion = try await client.completeArtifactSession(accessToken: "access-token", sessionId: create.sessionId)

        let createBody = try XCTUnwrap(capturedCreateBody)
        let createPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: createBody) as? [String: Any])
        XCTAssertEqual(createPayload["operationId"] as? String, "operation-1")
        XCTAssertEqual(createPayload["entryId"] as? String, "entry-1")
        XCTAssertEqual(createPayload["artifactId"] as? String, "artifact-1")
        XCTAssertEqual(createPayload["baseVersion"] as? Int, 7)
        XCTAssertEqual(requestedURLs, [createURL, completionURL])
        XCTAssertEqual(create.currentVersion, 8)
        XCTAssertEqual(completion.currentVersion, 9)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
