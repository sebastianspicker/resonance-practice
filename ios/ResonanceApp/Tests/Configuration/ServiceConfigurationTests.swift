import XCTest

@testable import ResonanceApp

final class AppConfigurationTests: XCTestCase {
  func testOnlyCredentialFreeHTTPOriginsBecomeAPIBaseURLs() {
    XCTAssertEqual(
      ServiceConfiguration.resolveAPIBaseURL("https://api.example.edu/tenant").absoluteString,
      "https://api.example.edu/tenant")
    for invalid in ["api.example.edu", "https://user:secret@api.example.edu", "ftp://api.example.edu"] {
      XCTAssertEqual(ServiceConfiguration.resolveAPIBaseURL(invalid).absoluteString, "http://localhost:4000")
    }
  }

  func testVersionedAPIPathsRemainAbsoluteAcrossBaseURLPaths() {
    XCTAssertEqual(ServiceConfiguration.apiV1URL(path: "/sync/commands/").path, "/api/v1/sync/commands")
  }
}
