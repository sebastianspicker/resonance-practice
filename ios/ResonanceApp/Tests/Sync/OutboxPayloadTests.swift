import XCTest

@testable import ResonanceApp

final class OutboxPayloadTests: XCTestCase {
  func testLegacyEntryPayloadMigratesToVersionedEnvelope() throws {
    let migrated = try OutboxEnvelope.decode(
      payloadJSON: #"{"entryId":"entry-1"}"#,
      taskType: .updateEntry)

    XCTAssertTrue(migrated.migrated)
    XCTAssertEqual(migrated.envelope.payload, .entry(.init(entryId: "entry-1")))

    let persisted = try migrated.envelope.encodedJSON()
    XCTAssertFalse(try OutboxEnvelope.decode(payloadJSON: persisted, taskType: .updateEntry).migrated)
  }
}
