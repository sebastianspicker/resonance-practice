import Foundation
import XCTest

@testable import ResonanceApp

final class APIClientTransportSecurityTests: APIRequestCaptureTestCase {
  @MainActor
  func testTransportAcceptsResponseAtExactByteLimit() async throws {
    let url = URL(string: "https://example.test/exact")!
    APIClientCaptureURLProtocol.requestHandler = { request in
      XCTAssertEqual(request.url, url)
      return (
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data("12345678".utf8)
      )
    }

    let client = makeCapturingAPIClient(maxResponseBytes: 8)
    let data = try await client.perform(URLRequest(url: url))
    XCTAssertEqual(data, Data("12345678".utf8))
  }

  @MainActor
  func testTransportRejectsChunkedResponseBeyondByteLimit() async throws {
    let url = URL(string: "https://example.test/oversized")!
    APIClientCaptureURLProtocol.requestHandler = { _ in
      (
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
        Data("123456789".utf8)
      )
    }

    let client = makeCapturingAPIClient(maxResponseBytes: 8)
    do {
      _ = try await client.perform(URLRequest(url: url))
      XCTFail("Expected the response limit to reject the ninth byte")
    } catch let error as URLError {
      XCTAssertEqual(error.code, .dataLengthExceedsMaximum)
    }
  }

  func testPaginationRetryReducesRequestedAndDefaultLimits() {
    XCTAssertEqual(smallerPageLimit(after: 50), 25)
    XCTAssertEqual(smallerPageLimit(after: nil), 25)
    XCTAssertEqual(smallerPageLimit(after: 3), 1)
    XCTAssertNil(smallerPageLimit(after: 1))
  }
}
