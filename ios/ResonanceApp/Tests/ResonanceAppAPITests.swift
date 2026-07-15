import XCTest
import SwiftData
@testable import ResonanceApp

// MARK: - API Model Decode Tests

final class APIModelDecodeTests: XCTestCase {

    /// Helper: the same decoder configuration used by APIClient in production.
    private var apiDecoder: JSONDecoder {
        JSONDecoder.apiDecoder
    }

    func testTokenResponseDecode() throws {
        let json = """
        {
            "accessToken": "tok_abc",
            "refreshToken": "ref_xyz",
            "user": {
                "id": "user-1",
                "displayName": "Alice",
                "globalRole": "student"
            }
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(TokenResponse.self, from: json)
        XCTAssertEqual(result.accessToken, "tok_abc")
        XCTAssertEqual(result.refreshToken, "ref_xyz")
        XCTAssertEqual(result.user?.id, "user-1")
        XCTAssertEqual(result.user?.displayName, "Alice")
        XCTAssertEqual(result.user?.globalRole, "student")
    }

    func testTokenResponseDecodeWithoutUser() throws {
        let json = """
        {
            "accessToken": "tok_abc",
            "refreshToken": "ref_xyz"
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(TokenResponse.self, from: json)
        XCTAssertEqual(result.accessToken, "tok_abc")
        XCTAssertNil(result.user)
    }

    func testCourseResponseDecode() throws {
        let json = """
        {
            "id": "course-1",
            "title": "Piano 101",
            "roleInCourse": "student"
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(CourseResponse.self, from: json)
        XCTAssertEqual(result.id, "course-1")
        XCTAssertEqual(result.title, "Piano 101")
        XCTAssertEqual(result.roleInCourse, "student")
    }

    func testEntryResponseDecodeWithFractionalSeconds() throws {
        let json = """
        {
            "id": "entry-1",
            "courseId": "course-1",
            "studentId": "student-1",
            "practiceDate": "2025-03-15T10:30:00.123Z",
            "goalText": "Scales",
            "durationSeconds": 1800,
            "tags": ["warmup", "technique"],
            "notes": "Went well",
            "status": "submitted"
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(EntryResponse.self, from: json)
        XCTAssertEqual(result.id, "entry-1")
        XCTAssertEqual(result.courseId, "course-1")
        XCTAssertEqual(result.studentId, "student-1")
        XCTAssertEqual(result.goalText, "Scales")
        XCTAssertEqual(result.durationSeconds, 1800)
        XCTAssertEqual(result.tags, ["warmup", "technique"])
        XCTAssertEqual(result.notes, "Went well")
        XCTAssertEqual(result.status, "submitted")
        // Date should have decoded successfully (not nil/crash)
        XCTAssertNotNil(result.practiceDate)
    }

    func testEntryResponseDecodeWithoutFractionalSeconds() throws {
        let json = """
        {
            "id": "entry-2",
            "courseId": "course-1",
            "studentId": "student-1",
            "practiceDate": "2025-03-15T10:30:00Z",
            "goalText": "Arpeggios",
            "durationSeconds": null,
            "tags": [],
            "notes": null,
            "status": "draft"
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(EntryResponse.self, from: json)
        XCTAssertEqual(result.id, "entry-2")
        XCTAssertNil(result.durationSeconds)
        XCTAssertNil(result.notes)
        XCTAssertTrue(result.tags.isEmpty)
        XCTAssertNotNil(result.practiceDate)
    }

    func testArtifactResponseDecode() throws {
        let json = """
        {
            "id": "art-1",
            "entryId": "entry-1",
            "type": "audio",
            "durationSeconds": 120,
            "uploadState": "uploaded",
            "storageKey": "artifacts/art-1.m4a",
            "remoteUrl": "https://cdn.example.com/art-1.m4a"
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(ArtifactResponse.self, from: json)
        XCTAssertEqual(result.id, "art-1")
        XCTAssertEqual(result.entryId, "entry-1")
        XCTAssertEqual(result.type, "audio")
        XCTAssertEqual(result.durationSeconds, 120)
        XCTAssertEqual(result.uploadState, "uploaded")
        XCTAssertEqual(result.storageKey, "artifacts/art-1.m4a")
        XCTAssertEqual(result.remoteUrl, "https://cdn.example.com/art-1.m4a")
    }

    func testArtifactResponseDecodeNullOptionals() throws {
        let json = """
        {
            "id": "art-2",
            "entryId": "entry-1",
            "type": "video",
            "durationSeconds": 60,
            "uploadState": "pending",
            "storageKey": null,
            "remoteUrl": null
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(ArtifactResponse.self, from: json)
        XCTAssertEqual(result.type, "video")
        XCTAssertNil(result.storageKey)
        XCTAssertNil(result.remoteUrl)
    }

    func testFeedbackResponseDecodeWithFractionalSeconds() throws {
        let json = """
        {
            "id": "fb-1",
            "targetType": "entry",
            "targetId": "entry-1",
            "teacherName": "Prof. Smith",
            "createdAt": "2025-04-01T14:00:00.456Z",
            "status": "needs_revision",
            "commentsText": "Work on dynamics",
            "markers": [
                {"id": "m-1", "timeSeconds": 30, "text": "Too fast here"},
                {"id": "m-2", "timeSeconds": 90, "text": "Good tone"}
            ]
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(FeedbackResponse.self, from: json)
        XCTAssertEqual(result.id, "fb-1")
        XCTAssertEqual(result.targetType, "entry")
        XCTAssertEqual(result.targetId, "entry-1")
        XCTAssertEqual(result.teacherName, "Prof. Smith")
        XCTAssertEqual(result.status, "needs_revision")
        XCTAssertEqual(result.commentsText, "Work on dynamics")
        XCTAssertNotNil(result.createdAt)
        XCTAssertEqual(result.markers.count, 2)
        XCTAssertEqual(result.markers[0].id, "m-1")
        XCTAssertEqual(result.markers[0].timeSeconds, 30)
        XCTAssertEqual(result.markers[0].text, "Too fast here")
        XCTAssertEqual(result.markers[1].timeSeconds, 90)
    }

    func testFeedbackResponseDecodeWithoutFractionalSeconds() throws {
        let json = """
        {
            "id": "fb-2",
            "targetType": "artifact",
            "targetId": "art-1",
            "teacherName": "Prof. Jones",
            "createdAt": "2025-04-01T14:00:00Z",
            "status": "ok",
            "commentsText": "Well done",
            "markers": []
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(FeedbackResponse.self, from: json)
        XCTAssertEqual(result.id, "fb-2")
        XCTAssertEqual(result.status, "ok")
        XCTAssertTrue(result.markers.isEmpty)
        XCTAssertNotNil(result.createdAt)
    }

    func testPresignResponseDecode() throws {
        let json = """
        {
            "uploadUrl": "https://storage.example.com/presigned",
            "storageKey": "artifacts/abc123.m4a",
            "expiresInSeconds": 3600,
            "requiredHeaders": {"x-amz-acl": "private"}
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(PresignResponse.self, from: json)
        XCTAssertEqual(result.uploadUrl, "https://storage.example.com/presigned")
        XCTAssertEqual(result.storageKey, "artifacts/abc123.m4a")
        XCTAssertEqual(result.expiresInSeconds, 3600)
        XCTAssertEqual(result.requiredHeaders?["x-amz-acl"], "private")
    }

    func testPresignResponseDecodeNullHeaders() throws {
        let json = """
        {
            "uploadUrl": "https://storage.example.com/presigned",
            "storageKey": "key",
            "expiresInSeconds": 600,
            "requiredHeaders": null
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(PresignResponse.self, from: json)
        XCTAssertNil(result.requiredHeaders)
    }

    func testArtifactDownloadResponseDecode() throws {
        let json = """
        {
            "downloadUrl": "https://storage.example.com/private-evidence",
            "expiresInSeconds": 900
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(ArtifactDownloadResponse.self, from: json)
        XCTAssertEqual(result.expiresInSeconds, 900)
        XCTAssertEqual(result.downloadUrl.host, "storage.example.com")
    }

    func testAPIErrorDecode() throws {
        let json = """
        {
            "error": {
                "code": "AUTH_TOKEN_EXPIRED",
                "message": "Token has expired",
                "details": {"hint": "Re-authenticate"}
            }
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(APIError.self, from: json)
        XCTAssertEqual(result.error.code, "AUTH_TOKEN_EXPIRED")
        XCTAssertEqual(result.error.message, "Token has expired")
        XCTAssertEqual(result.error.details?["hint"], "Re-authenticate")
    }

    func testAPIErrorDecodeNullDetails() throws {
        let json = """
        {
            "error": {
                "code": "NOT_FOUND",
                "message": "Resource not found",
                "details": null
            }
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(APIError.self, from: json)
        XCTAssertEqual(result.error.code, "NOT_FOUND")
        XCTAssertNil(result.error.details)
    }

    func testReviewQueueEntryDecode() throws {
        let json = """
        {
            "id": "entry-99",
            "courseId": "course-1",
            "studentId": "student-5",
            "studentName": "Bob",
            "practiceDate": "2025-05-10T08:00:00.000Z",
            "goalText": "Sight reading",
            "notes": null,
            "artifacts": [
                {
                    "id": "art-10",
                    "entryId": "entry-99",
                    "type": "audio",
                    "durationSeconds": 45,
                    "uploadState": "uploaded",
                    "storageKey": "key",
                    "remoteUrl": "https://cdn.example.com/a.m4a"
                }
            ]
        }
        """.data(using: .utf8)!

        let result = try apiDecoder.decode(ReviewQueueEntry.self, from: json)
        XCTAssertEqual(result.id, "entry-99")
        XCTAssertEqual(result.studentName, "Bob")
        XCTAssertNil(result.notes)
        XCTAssertEqual(result.artifacts.count, 1)
        XCTAssertEqual(result.artifacts[0].id, "art-10")
    }

    /// Ensure date decoding fails for an invalid date string.
    func testDateDecodingRejectsGarbage() {
        let json = """
        {
            "id": "entry-bad",
            "courseId": "c",
            "studentId": "s",
            "practiceDate": "not-a-date",
            "goalText": "G",
            "durationSeconds": null,
            "tags": [],
            "notes": null,
            "status": "draft"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try apiDecoder.decode(EntryResponse.self, from: json))
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
    func testCreateEntryWithNilOptionalFieldsEncodesValidJSONAndOmitsKeys() async throws {
        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("courses/course-1/entries")
        var capturedBody: Data?
        APIClientCaptureURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            capturedBody = try XCTUnwrap(requestBodyData(request))

            let response = """
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
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                response
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientCaptureURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let entry = LocalPracticeEntry(
            id: "entry-nil-optionals",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(practiceDate: Date(timeIntervalSince1970: 1_771_848_000), goalText: "Goal", durationSeconds: nil, tags: ["tone"], notes: nil),
            status: .draft
        )

        _ = try await client.createEntry(accessToken: "access-token", courseId: "course-1", entry: entry)

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
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
        var capturedBody: Data?
        APIClientCaptureURLProtocol.requestHandler = { request in
            capturedBody = try XCTUnwrap(requestBodyData(request))

            let response = """
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
                "consentScope": "private_course_review"
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                response
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientCaptureURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
        let entry = LocalPracticeEntry(
            id: "entry-teaching",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(practiceDate: Date(timeIntervalSince1970: 1_771_848_000), goalText: "Teach rhythm ostinato", durationSeconds: nil, tags: ["lehramt"], notes: nil),
            status: .draft,
            captureContext: CaptureContext(kind: .teachingLesson, consentConfirmedAt: Date(timeIntervalSince1970: 1_771_848_060), consentScope: .privateCourseReview, captureProfile: .teacherLearner)
        )

        _ = try await client.createEntry(accessToken: "access-token", courseId: "course-1", entry: entry)

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "teaching_lesson")
        XCTAssertEqual(json["consentConfirmed"] as? Bool, true)
        XCTAssertEqual(json["consentScope"] as? String, "private_course_review")
        XCTAssertEqual(json["captureProfile"] as? String, "teacher_learner")
    }

    @MainActor
    func testUpdateEntryCaptureProfileEncodesPatch() async throws {
        let expectedURL = AppConfig.apiBaseURL.appendingPathComponent("entries/entry-teaching")
        var capturedBody: Data?
        APIClientCaptureURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.httpMethod, "PATCH")
            capturedBody = try XCTUnwrap(requestBodyData(request))

            let response = """
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
                "consentScope": "private_course_review",
                "captureProfile": "ensemble_group"
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                response
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientCaptureURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))

        _ = try await client.updateEntryCaptureProfile(
            accessToken: "access-token",
            entryId: "entry-teaching",
            captureProfile: .ensembleGroup
        )

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
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
        var capturedBody: Data?
        APIClientCaptureURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, expectedURL)
            XCTAssertEqual(request.httpMethod, "PUT")
            capturedBody = try XCTUnwrap(requestBodyData(request))

            let response = """
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
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                response
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientCaptureURLProtocol.self]
        let client = APIClient(session: URLSession(configuration: configuration))
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

        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let markers = try XCTUnwrap(json["markers"] as? [[String: Any]])
        XCTAssertEqual(markers[0]["id"] as? String, "marker-1")
        XCTAssertEqual(markers[0]["artifactId"] as? String, "artifact-video")
        XCTAssertEqual(markers[0]["timeSeconds"] as? Int, 12)
        XCTAssertEqual(markers[0]["kind"] as? String, "phase_modeling")
        XCTAssertEqual(response[0].kind, "phase_modeling")
    }
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            return nil
        }
        if count == 0 {
            return data
        }
        data.append(buffer, count: count)
    }
}

private final class APIClientCaptureURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("APIClientCaptureURLProtocol.requestHandler not set")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
