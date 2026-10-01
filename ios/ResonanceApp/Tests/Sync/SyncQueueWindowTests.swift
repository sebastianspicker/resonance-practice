import Foundation
import SwiftData
import XCTest

@testable import ResonanceApp

final class SyncQueueWindowTests: XCTestCase {
  @MainActor
  func testLargeOutboxFetchesOnlyOwnerReadyFIFOWindowAndCountsInStore() throws {
    let outbox = try makeLargeOutbox()
    let (container, store, now) = (outbox.container, outbox.store, outbox.now)
    defer { withExtendedLifetime(container) {} }

    let ready = try store.fetchReady(now: now, ownerId: "student-1")

    XCTAssertEqual(ready.count, 50)
    XCTAssertEqual(ready.map(\.id), (0..<50).map { String(format: "ready-%04d", $0) })
    XCTAssertEqual(store.counts(ownerId: "student-1").pending, 1_000)
    XCTAssertEqual(store.counts(ownerId: "student-2").pending, 80)
  }

  @MainActor
  func testLargeOutboxReadyWindowPerformance() throws {
    let outbox = try makeLargeOutbox()
    let (container, store, now) = (outbox.container, outbox.store, outbox.now)
    defer { withExtendedLifetime(container) {} }

    measure(metrics: [XCTClockMetric()]) {
      do {
        let ready = try store.fetchReady(now: now, ownerId: "student-1")
        XCTAssertEqual(ready.count, 50)
        XCTAssertEqual(store.counts(ownerId: "student-1").pending, 1_000)
      } catch {
        XCTFail("Fetching the seeded outbox failed: \(error)")
      }
    }
  }

  private struct LargeOutbox {
    let container: ModelContainer
    let store: QueueStore
    let now: Date
  }

  @MainActor
  private func makeLargeOutbox() throws -> LargeOutbox {
    let container = PersistenceController.createContainer(inMemory: true)
    let store = QueueStore(modelContext: container.mainContext)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Future-due work comes first in FIFO order. The ready window must scan
    // past it instead of starving the next ready item.
    for index in 0..<60 {
      let item = SyncQueueItem(
        id: String(format: "future-%04d", index), type: SyncTaskType.updateEntry.rawValue,
        payloadJSON: "{}", ownerId: "student-1")
      item.createdAt = now.addingTimeInterval(TimeInterval(-1_000 + index))
      item.nextAttemptAt = now.addingTimeInterval(60)
      container.mainContext.insert(item)
    }
    for index in 0..<940 {
      let item = SyncQueueItem(
        id: String(format: "ready-%04d", index), type: SyncTaskType.updateEntry.rawValue, payloadJSON: "{}",
        ownerId: "student-1")
      item.createdAt = now.addingTimeInterval(TimeInterval(index))
      container.mainContext.insert(item)
    }
    for index in 0..<80 {
      container.mainContext.insert(
        SyncQueueItem(id: "other-owner-\(index)", type: SyncTaskType.updateEntry.rawValue,
                      payloadJSON: "{}", ownerId: "student-2"))
    }
    try container.mainContext.save()
    return LargeOutbox(container: container, store: store, now: now)
  }
}
