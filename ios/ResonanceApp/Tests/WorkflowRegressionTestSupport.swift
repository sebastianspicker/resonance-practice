import Foundation
import SwiftData
import XCTest
@testable import ResonanceApp

// Purpose: provides deterministic URL-protocol and fixture support for workflow regression suites.

class TestURLProtocolBase: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
}

class TestRequestURLProtocol: TestURLProtocolBase {
    nonisolated(unsafe) private static var requestHandlers: [ObjectIdentifier: ((URLRequest) throws -> (HTTPURLResponse, Data))] = [:]

    class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { requestHandlers[ObjectIdentifier(self)] }
        set { requestHandlers[ObjectIdentifier(self)] = newValue }
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("TestRequestURLProtocol.requestHandler not set")
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

final class MockURLProtocol: TestRequestURLProtocol {}

final class EntryReconciliationURLProtocol: TestRequestURLProtocol {}

final class ArtifactPlaybackURLProtocol: TestRequestURLProtocol {}

func testRequestBodyData(_ request: URLRequest) -> Data? {
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

final class DeferredArtifactURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((DeferredArtifactURLProtocol, URLRequest) -> Void)?

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("DeferredArtifactURLProtocol.requestHandler not set")
            return
        }
        handler(self, request)
    }

    override func stopLoading() {}

    func respond(statusCode: Int, data: Data = Data()) {
        guard let url = request.url else {
            XCTFail("Deferred artifact request URL is missing")
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

func submitEntryResponseJSON(id: String, status: String) -> Data {
    Data(
        """
        {
            "id": "\(id)",
            "courseId": "course-1",
            "studentId": "student-1",
            "kind": "practice",
            "practiceDate": "2026-02-23T12:00:00Z",
            "goalText": "Submitted only after server success",
            "durationSeconds": null,
            "tags": ["tone"],
            "notes": null,
            "status": "\(status)",
            "consentConfirmedAt": null,
            "consentScope": null,
            "captureProfile": null,
            "captureMarkers": []
        }
        """.utf8
    )
}

func entryResponseWithUploadedArtifact(entryId: String, artifactId: String) -> Data {
    Data(
        """
        {
          "id": "\(entryId)",
          "courseId": "course-1",
          "studentId": "student-1",
          "kind": "practice",
          "practiceDate": "2026-02-23T12:00:00Z",
          "goalText": "Goal",
          "durationSeconds": null,
          "tags": [],
          "notes": null,
          "status": "draft",
          "consentConfirmedAt": null,
          "consentScope": null,
          "captureProfile": null,
          "captureMarkers": [],
          "artifacts": [
            {
              "id": "\(artifactId)",
              "entryId": "\(entryId)",
              "type": "audio",
              "durationSeconds": 30,
              "expectedSizeBytes": 5,
              "uploadState": "uploaded",
              "storageKey": "artifacts/\(entryId)/\(artifactId)",
              "remoteUrl": "https://storage.example.test/\(artifactId)"
            }
          ]
        }
        """.utf8
    )
}

func makeUnexpiredJWT() -> String {
    let header = base64URLString(from: Data("{\"alg\":\"none\"}".utf8))
    let expiry = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
    let payload = base64URLString(from: Data("{\"exp\":\(expiry)}".utf8))
    return "\(header).\(payload).signature"
}

@MainActor
func makeTaskExecutor(for modelContext: ModelContext) -> TaskExecutor {
    TaskExecutor(
        apiClient: APIClient(),
        store: QueueStore(modelContext: modelContext),
        session: .shared
    )
}

@MainActor
func makeDraftPracticeEntry(
    id: String,
    courseId: String = "course-1",
    studentId: String = "student-1",
    goalText: String = "Goal",
    tags: [String] = []
) -> LocalPracticeEntry {
    LocalPracticeEntry(
        id: id,
        courseId: courseId,
        studentId: studentId,
        details: PracticeEntryDetails(
            practiceDate: Date(),
            goalText: goalText,
            durationSeconds: nil,
            tags: tags,
            notes: nil
        ),
        status: .draft
    )
}

func base64URLString(from data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
