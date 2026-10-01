import Foundation
import XCTest

@testable import ResonanceApp

class TestURLProtocolBase: URLProtocol {
  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
}

class TestRequestURLProtocol: TestURLProtocolBase {
  nonisolated(unsafe) private static var handlers:
    [ObjectIdentifier: ((URLRequest) throws -> (HTTPURLResponse, Data))] = [:]

  class var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
    get { handlers[ObjectIdentifier(self)] }
    set { handlers[ObjectIdentifier(self)] = newValue }
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

final class APIClientCaptureURLProtocol: TestRequestURLProtocol {}

class APIRequestCaptureTestCase: XCTestCase {
  override func tearDown() {
    APIClientCaptureURLProtocol.requestHandler = nil
    super.tearDown()
  }
}

final class RequestBodyCapture {
  var body: Data?
}

func testRequestBodyData(_ request: URLRequest) -> Data? {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return nil }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while true {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 { return nil }
    if count == 0 { return data }
    data.append(buffer, count: count)
  }
}

@MainActor
func makeCapturingAPIClient() -> APIClient {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [APIClientCaptureURLProtocol.self]
  return APIClient(session: URLSession(configuration: configuration))
}

@MainActor
func installRequestBodyCapture(expectedURL: URL, method: String, response: Data)
  -> RequestBodyCapture {
  let capture = RequestBodyCapture()
  APIClientCaptureURLProtocol.requestHandler = { request in
    XCTAssertEqual(request.url, expectedURL)
    XCTAssertEqual(request.httpMethod, method)
    capture.body = try XCTUnwrap(testRequestBodyData(request))
    return (
      HTTPURLResponse(url: expectedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
      response
    )
  }
  return capture
}

func decodedJSON(from capture: RequestBodyCapture) throws -> [String: Any] {
  let body = try XCTUnwrap(capture.body)
  return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
}

func teachingEntryResponse() -> Data {
  Data(
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
      "consentScope": "private_course_review"
    }
    """.utf8)
}
