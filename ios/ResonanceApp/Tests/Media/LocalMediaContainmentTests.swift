import XCTest

@testable import ResonanceApp

final class LocalMediaContainmentTests: XCTestCase {
  func testRejectsPathsOutsideManagedMediaDirectory() {
    XCTAssertThrowsError(try FileStore.containedMediaURL(atPath: "/tmp/untrusted.m4a")) { error in
      guard case FileStoreError.pathOutsideMediaDirectory = error else {
        return XCTFail("Expected path containment error, got \(error)")
      }
    }
  }
}
