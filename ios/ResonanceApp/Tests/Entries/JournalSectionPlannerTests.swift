import Foundation
import XCTest

@testable import ResonanceApp

final class JournalSectionPlannerTests: XCTestCase {
  func testLargeJournalIndexKeepsEntriesGroupedAndNewestDayFirst() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let calendar = Calendar(identifier: .gregorian)
    let index = (0..<1_000).map { offset in
      JournalEntryIndex(
        id: "entry-\(offset)",
        day: calendar.startOfDay(for: start.addingTimeInterval(TimeInterval(offset % 20) * 86_400)))
    }

    let days = JournalSectionPlanner.makeDays(from: index)

    XCTAssertEqual(days.count, 20)
    XCTAssertEqual(days.flatMap(\.entryIDs).count, index.count)
    XCTAssertEqual(days, days.sorted { $0.date > $1.date })
  }
}
