import XCTest
import SwiftData
@testable import ResonanceApp

// Purpose: verifies decoding and persistence-facing translation of API model payloads.

// MARK: - API Model Decode Tests

final class APIModelDecodeTests: XCTestCase {

    /// Helper: the same decoder configuration used by APIClient in production.
    private var apiDecoder: JSONDecoder {
        JSONDecoder.apiDecoder
    }

    func testTokenResponseDecode() throws {
        let json = Data("""
        {
            "accessToken": "tok_abc",
            "refreshToken": "ref_xyz",
            "user": {
                "id": "user-1",
                "displayName": "Alice",
                "globalRole": "student"
            }
        }
        """.utf8)

        let result = try apiDecoder.decode(TokenResponse.self, from: json)
        XCTAssertEqual(result.accessToken, "tok_abc")
        XCTAssertEqual(result.refreshToken, "ref_xyz")
        XCTAssertEqual(result.user?.id, "user-1")
        XCTAssertEqual(result.user?.displayName, "Alice")
        XCTAssertEqual(result.user?.globalRole, "student")
    }

    func testTokenResponseDecodeWithoutUser() throws {
        let json = Data("""
        {
            "accessToken": "tok_abc",
            "refreshToken": "ref_xyz"
        }
        """.utf8)

        let result = try apiDecoder.decode(TokenResponse.self, from: json)
        XCTAssertEqual(result.accessToken, "tok_abc")
        XCTAssertNil(result.user)
    }

    func testCourseResponseDecode() throws {
        let json = Data("""
        {
            "id": "course-1",
            "title": "Piano 101",
            "roleInCourse": "student"
        }
        """.utf8)

        let result = try apiDecoder.decode(CourseResponse.self, from: json)
        XCTAssertEqual(result.id, "course-1")
        XCTAssertEqual(result.title, "Piano 101")
        XCTAssertEqual(result.roleInCourse, "student")
    }

    func testEntryResponseDecodeWithFractionalSeconds() throws {
        let json = Data("""
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
        """.utf8)

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
        let json = Data("""
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
        """.utf8)

        let result = try apiDecoder.decode(EntryResponse.self, from: json)
        XCTAssertEqual(result.id, "entry-2")
        XCTAssertNil(result.durationSeconds)
        XCTAssertNil(result.notes)
        XCTAssertTrue(result.tags.isEmpty)
        XCTAssertNotNil(result.practiceDate)
    }

    func testArtifactResponseDecode() throws {
        let json = Data("""
        {
            "id": "art-1",
            "entryId": "entry-1",
            "type": "audio",
            "durationSeconds": 120,
            "uploadState": "uploaded",
            "storageKey": "artifacts/art-1.m4a",
            "remoteUrl": "https://cdn.example.com/art-1.m4a"
        }
        """.utf8)

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
        let json = Data("""
        {
            "id": "art-2",
            "entryId": "entry-1",
            "type": "video",
            "durationSeconds": 60,
            "uploadState": "pending",
            "storageKey": null,
            "remoteUrl": null
        }
        """.utf8)

        let result = try apiDecoder.decode(ArtifactResponse.self, from: json)
        XCTAssertEqual(result.type, "video")
        XCTAssertNil(result.storageKey)
        XCTAssertNil(result.remoteUrl)
    }

    func testArtifactSessionCreateResponseDecodesUploadContract() throws {
        let json = Data("""
        {
            "sessionId": "session-1",
            "artifact": {
                "id": "artifact-1", "entryId": "entry-1", "type": "audio",
                "durationSeconds": 30, "uploadState": "pending",
                "storageKey": "artifacts/entry-1/artifact-1", "remoteUrl": null
            },
            "completed": false,
            "uploadUrl": "https://storage.example.test/upload/session-1",
            "requiredHeaders": {"Content-Type": "audio/m4a"},
            "expiresInSeconds": 900,
            "currentVersion": 8
        }
        """.utf8)

        let result = try apiDecoder.decode(ArtifactSessionCreateResponse.self, from: json)
        XCTAssertEqual(result.sessionId, "session-1")
        XCTAssertEqual(result.artifact.id, "artifact-1")
        XCTAssertEqual(result.completed, false)
        XCTAssertEqual(result.uploadUrl, "https://storage.example.test/upload/session-1")
        XCTAssertEqual(result.requiredHeaders?["Content-Type"], "audio/m4a")
        XCTAssertEqual(result.currentVersion, 8)
    }

    func testArtifactSessionCompletionResponseDecodesCompletionContract() throws {
        let json = Data("""
        {
            "artifact": {
                "id": "artifact-1", "entryId": "entry-1", "type": "audio",
                "durationSeconds": 30, "uploadState": "uploaded",
                "storageKey": "artifacts/entry-1/artifact-1",
                "remoteUrl": "https://storage.example.test/artifact-1"
            },
            "currentVersion": 9
        }
        """.utf8)

        let result = try apiDecoder.decode(ArtifactSessionCompletionResponse.self, from: json)
        XCTAssertEqual(result.artifact.uploadState, "uploaded")
        XCTAssertEqual(result.currentVersion, 9)
    }

    func testFeedbackResponseDecodeWithFractionalSeconds() throws {
        let json = Data("""
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
        """.utf8)

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
        let json = Data("""
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
        """.utf8)

        let result = try apiDecoder.decode(FeedbackResponse.self, from: json)
        XCTAssertEqual(result.id, "fb-2")
        XCTAssertEqual(result.status, "ok")
        XCTAssertTrue(result.markers.isEmpty)
        XCTAssertNotNil(result.createdAt)
    }

    func testArtifactDownloadResponseDecode() throws {
        let json = Data("""
        {
            "downloadUrl": "https://storage.example.com/private-evidence",
            "expiresInSeconds": 900
        }
        """.utf8)

        let result = try apiDecoder.decode(ArtifactDownloadResponse.self, from: json)
        XCTAssertEqual(result.expiresInSeconds, 900)
        XCTAssertEqual(result.downloadUrl.host, "storage.example.com")
    }

    func testAPIErrorDecode() throws {
        let json = Data("""
        {
            "error": {
                "code": "AUTH_TOKEN_EXPIRED",
                "message": "Token has expired",
                "details": {"hint": "Re-authenticate"}
            }
        }
        """.utf8)

        let result = try apiDecoder.decode(APIError.self, from: json)
        XCTAssertEqual(result.error.code, "AUTH_TOKEN_EXPIRED")
        XCTAssertEqual(result.error.message, "Token has expired")
        XCTAssertEqual(result.error.details?["hint"], .string("Re-authenticate"))
        XCTAssertNil(result.error.requestId)
        XCTAssertNil(result.error.currentVersion)
    }

    func testAPIErrorDecodeNullDetails() throws {
        let json = Data("""
        {
            "error": {
                "code": "NOT_FOUND",
                "message": "Resource not found",
                "details": null
            }
        }
        """.utf8)

        let result = try apiDecoder.decode(APIError.self, from: json)
        XCTAssertEqual(result.error.code, "NOT_FOUND")
        XCTAssertNil(result.error.details)
    }

    func testAPIErrorDecodePreservesNumericConflictDetails() throws {
        let json = Data("""
        {
            "error": {
                "code": "VERSION_CONFLICT",
                "message": "Entry has changed",
                "details": {"expected": 3, "actual": 4},
                "requestId": "request-123",
                "currentVersion": 4
            }
        }
        """.utf8)

        let result = try apiDecoder.decode(APIError.self, from: json)
        XCTAssertEqual(result.error.details?["expected"], .integer(3))
        XCTAssertEqual(result.error.details?["actual"], .integer(4))
        XCTAssertEqual(result.error.requestId, "request-123")
        XCTAssertEqual(result.error.currentVersion, 4)
    }

    func testReviewQueueEntryDecode() throws {
        let json = Data("""
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
        """.utf8)

        let result = try apiDecoder.decode(ReviewQueueEntry.self, from: json)
        XCTAssertEqual(result.id, "entry-99")
        XCTAssertEqual(result.studentName, "Bob")
        XCTAssertNil(result.notes)
        XCTAssertEqual(result.artifacts.count, 1)
        XCTAssertEqual(result.artifacts[0].id, "art-10")
    }

    /// Ensure date decoding fails for an invalid date string.
    func testDateDecodingRejectsGarbage() {
        let json = Data("""
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
        """.utf8)

        XCTAssertThrowsError(try apiDecoder.decode(EntryResponse.self, from: json))
    }
}
