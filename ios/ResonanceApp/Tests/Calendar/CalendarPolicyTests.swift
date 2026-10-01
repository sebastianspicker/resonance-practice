import Foundation
import XCTest

@testable import ResonanceApp

final class CalendarPolicyTests: XCTestCase {
  func testCalendarPolicyRequiresHTTPSExceptLocalDevelopmentHosts() {
    XCTAssertTrue(CalendarService.isAllowedCalendarURL(URL(string: "https://calendar.example.edu/feed?token=secret")!))
    XCTAssertTrue(CalendarService.isAllowedCalendarURL(URL(string: "http://localhost:4000/feed")!))
    XCTAssertTrue(CalendarService.isAllowedCalendarURL(URL(string: "http://127.0.0.2:4000/feed")!))
    XCTAssertFalse(CalendarService.isAllowedCalendarURL(URL(string: "http://calendar.example.edu/feed")!))
    XCTAssertFalse(CalendarService.isAllowedCalendarURL(URL(string: "file:///tmp/calendar.ics")!))
  }

  func testCalendarPolicyRejectsHTTPSPrivateAndLocalDestinations() {
    [
      "https://localhost/feed",
      "https://calendar.local/feed",
      "https://127.0.0.1/feed",
      "https://10.0.0.1/feed",
      "https://172.16.0.1/feed",
      "https://192.168.0.1/feed",
      "https://169.254.1.1/feed",
      "https://[::1]/feed",
      "https://[fc00::1]/feed",
      "https://[fe80::1]/feed",
      "https://[::ffff:127.0.0.1]/feed",
      "https://[::ffff:10.0.0.1]/feed",
      "https://[::ffff:169.254.1.1]/feed"
    ].forEach { value in
      XCTAssertFalse(CalendarService.isAllowedCalendarURL(URL(string: value)!))
    }
  }

  func testCalendarRedirectPolicyRejectsMappedIPv4Destinations() {
    [
      "https://[::ffff:127.0.0.1]/feed",
      "https://[::ffff:192.168.0.1]/feed"
    ].forEach { value in
      XCTAssertFalse(CalendarRedirectPolicy.allowsRedirect(to: URL(string: value)!))
    }
  }
}
