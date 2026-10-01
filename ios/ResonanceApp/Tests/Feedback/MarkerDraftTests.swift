import Foundation
import XCTest

@testable import ResonanceApp

final class MarkerDraftTests: XCTestCase {
  func testParsesSecondsAndMinutesSecondsText() {
    XCTAssertEqual(MarkerDraft.parseTime("0"), 0)
    XCTAssertEqual(MarkerDraft.parseTime("75"), 75)
    XCTAssertEqual(MarkerDraft.parseTime("1:05"), 65)
    XCTAssertEqual(MarkerDraft.parseTime("01:05"), 65)
    XCTAssertEqual(MarkerDraft.parseTime("0:59"), 59)
    XCTAssertEqual(MarkerDraft.parseTime("90:00"), 5_400)
  }

  func testRejectsNegativeOutOfRangeAndMalformedText() {
    for invalid in ["", " ", "abc", "-1", "-1:00", "1:-1", "1:60", "1:", ":30", "1:2:3", "1.5", "1:5a"] {
      XCTAssertNil(MarkerDraft.parseTime(invalid), "Expected \(invalid.debugDescription) to be rejected")
    }
  }

  func testFormatsWholeSecondsAsZeroPaddedMinutesAndSeconds() {
    XCTAssertEqual(MarkerDraft.formatTime(0), "00:00")
    XCTAssertEqual(MarkerDraft.formatTime(5), "00:05")
    XCTAssertEqual(MarkerDraft.formatTime(65.9), "01:05")
    XCTAssertEqual(MarkerDraft.formatTime(59.999), "00:59")
    XCTAssertEqual(MarkerDraft.formatTime(3_600), "60:00")
  }

  func testFormatClampsNegativeIntervalsToZero() {
    XCTAssertEqual(MarkerDraft.formatTime(-5), "00:00")
  }

  func testFormattedTimesParseBackToTheSameSeconds() {
    for seconds in [0, 1, 59, 60, 61, 599, 3_599, 5_400] {
      let formatted = MarkerDraft.formatTime(TimeInterval(seconds))
      XCTAssertEqual(MarkerDraft.parseTime(formatted), seconds, "Round trip failed for \(formatted)")
    }
  }
}
