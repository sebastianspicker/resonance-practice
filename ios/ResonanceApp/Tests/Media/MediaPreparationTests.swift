import Foundation
import XCTest

@testable import ResonanceApp

final class MediaPreparationTests: XCTestCase {
  func testBackgroundPreparationReturnsStreamingChecksumAndMetadata() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let data = Data(repeating: 0xA5, count: MediaChecksum.chunkSize * 32)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let preparation = try await MediaChecksum.prepare(for: url)

    XCTAssertEqual(preparation.sizeBytes, data.count)
    XCTAssertEqual(preparation.checksumSha256, try MediaChecksum.sha256Base64(for: url))
  }

  @MainActor
  func testChecksumPreparationResponsivenessSmoke() async throws {
    let (url, _) = try makeChecksumFixture()
    defer { try? FileManager.default.removeItem(at: url) }
    let preparation = Task { try await MediaChecksum.prepare(for: url) }
    let heartbeat = expectation(description: "main actor heartbeat")
    Task { @MainActor in heartbeat.fulfill() }

    await fulfillment(of: [heartbeat], timeout: 2)
    let result = try await preparation.value
    XCTAssertEqual(result.sizeBytes, MediaChecksum.chunkSize * 32)
  }

  func testChecksumPreparationPerformance() throws {
    let (url, _) = try makeChecksumFixture()
    defer { try? FileManager.default.removeItem(at: url) }

    measure(metrics: [XCTClockMetric()]) {
      let completed = expectation(description: "checksum preparation")
      Task { @MainActor in
        do {
          let preparation = try await MediaChecksum.prepare(for: url)
          XCTAssertEqual(preparation.sizeBytes, MediaChecksum.chunkSize * 32)
        } catch {
          XCTFail("Checksum preparation failed: \(error)")
        }
        completed.fulfill()
      }
      wait(for: [completed], timeout: 5)
    }
  }

  private func makeChecksumFixture() throws -> (URL, Data) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let data = Data(repeating: 0xA5, count: MediaChecksum.chunkSize * 32)
    try data.write(to: url)
    return (url, data)
  }
}
