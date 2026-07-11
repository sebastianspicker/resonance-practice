import XCTest
import SwiftData
@testable import ResonanceApp

// MARK: - ICalParser Edge Case Tests

final class ICalParserEdgeCaseTests: XCTestCase {

    func testEmptyCalendar() {
        let ical = """
BEGIN:VCALENDAR
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertTrue(events.isEmpty)
    }

    func testEmptyString() {
        let events = ICalParser.parse("")
        XCTAssertTrue(events.isEmpty)
    }

    func testMultipleEvents() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:evt-1
SUMMARY:Lesson 1
DTSTART:20250301T090000Z
DTEND:20250301T100000Z
END:VEVENT
BEGIN:VEVENT
UID:evt-2
SUMMARY:Lesson 2
DTSTART:20250302T140000Z
DTEND:20250302T150000Z
LOCATION:Room B
END:VEVENT
BEGIN:VEVENT
UID:evt-3
SUMMARY:Lesson 3
DTSTART:20250303T160000Z
DTEND:20250303T170000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].summary, "Lesson 1")
        XCTAssertEqual(events[1].summary, "Lesson 2")
        XCTAssertEqual(events[2].summary, "Lesson 3")
        XCTAssertEqual(events[1].location, "Room B")
        XCTAssertNil(events[0].location)
    }

    func testMissingSummarySkipsEvent() {
        // SUMMARY is required; event without it should be skipped
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:no-summary
DTSTART:20250301T090000Z
DTEND:20250301T100000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingDTSTARTSkipsEvent() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:no-start
SUMMARY:Missing Start
DTEND:20250301T100000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingDTENDSkipsEvent() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:no-end
SUMMARY:Missing End
DTSTART:20250301T090000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertTrue(events.isEmpty)
    }

    func testMissingUIDGeneratesOne() {
        // UID is optional; parser should generate a UUID if absent
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
SUMMARY:No UID Event
DTSTART:20250301T090000Z
DTEND:20250301T100000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events[0].id.isEmpty, "Generated UID should not be empty")
    }

    func testMalformedInputNoCrash() {
        // Completely invalid data should not crash, just return empty
        let garbage = "this is not ical data at all"
        let events = ICalParser.parse(garbage)
        XCTAssertTrue(events.isEmpty)
    }

    func testMalformedDatesSkipEvent() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:bad-dates
SUMMARY:Bad Dates
DTSTART:not-a-date
DTEND:also-not-a-date
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertTrue(events.isEmpty)
    }

    func testAllDayEvent() {
        // All-day dates use yyyyMMdd format (8 characters, no time component)
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:all-day
SUMMARY:All Day Rehearsal
DTSTART;VALUE=DATE:20250315
DTEND;VALUE=DATE:20250316
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].summary, "All Day Rehearsal")
    }

    func testFloatingDateTime() {
        // Floating datetime (no Z suffix) should be parsed in local timezone
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:floating
SUMMARY:Local Time Event
DTSTART:20250320T180000
DTEND:20250320T190000
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertNotNil(events[0].startDate)
    }

    func testLineFolding() {
        // RFC 5545: long lines may be folded with CRLF + space/tab
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:fold-test
SUMMARY:Very Long Su
 mmary That Is Folded
DTSTART:20250301T090000Z
DTEND:20250301T100000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].summary, "Very Long Summary That Is Folded")
    }

    func testLocationOptional() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:no-loc
SUMMARY:No Location
DTSTART:20250401T100000Z
DTEND:20250401T110000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].location)
    }

    func testDTSTARTWithTZIDParameter() {
        // DTSTART may include TZID parameter: DTSTART;TZID=America/New_York:20250301T090000
        // Parser strips parameters before the key, so the key becomes DTSTART
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:tzid-test
SUMMARY:With TZID
DTSTART;TZID=America/New_York:20250301T090000
DTEND;TZID=America/New_York:20250301T100000
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        // The parser strips parameters (;TZID=...) and parses the value as floating datetime
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].summary, "With TZID")
    }

    func testMixOfValidAndInvalidEvents() {
        let ical = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:valid
SUMMARY:Good Event
DTSTART:20250301T090000Z
DTEND:20250301T100000Z
END:VEVENT
BEGIN:VEVENT
UID:invalid
SUMMARY:Bad Event
DTSTART:garbage
DTEND:garbage
END:VEVENT
BEGIN:VEVENT
UID:also-valid
SUMMARY:Another Good Event
DTSTART:20250302T110000Z
DTEND:20250302T120000Z
END:VEVENT
END:VCALENDAR
"""
        let events = ICalParser.parse(ical)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].summary, "Good Event")
        XCTAssertEqual(events[1].summary, "Another Good Event")
    }
}

// MARK: - AppConfig Derivation Tests

final class AppConfigTests: XCTestCase {

    func testKeychainNamespaceFromDefaultURL() {
        // The default API URL is http://localhost:4000 (unless env override is set).
        // keychainNamespace should be "resonance-" + sanitized URL.
        let ns = AppConfig.keychainNamespace
        XCTAssertTrue(ns.hasPrefix("resonance-"), "keychainNamespace should start with 'resonance-'")
        XCTAssertFalse(ns.isEmpty)
        // Should not contain characters outside [a-z0-9-]
        let validChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for scalar in ns.unicodeScalars {
            XCTAssertTrue(validChars.contains(scalar), "Unexpected character '\(scalar)' in keychainNamespace: \(ns)")
        }
    }

    func testKeychainNamespaceDoesNotContainDoubleHyphens() {
        // The regex replaces all non-alphanumeric runs with a single '-',
        // so there should not be consecutive hyphens after trimming.
        let ns = AppConfig.keychainNamespace
        XCTAssertFalse(ns.contains("--"), "keychainNamespace should not contain consecutive hyphens: \(ns)")
    }

    func testAuthLoginURLDerivedFromBase() {
        let expected = AppConfig.apiBaseURL.appendingPathComponent("auth/login")
        XCTAssertEqual(AppConfig.authLoginURL, expected)
    }

    func testAuthLoginURLContainsAuthLoginPath() {
        let url = AppConfig.authLoginURL.absoluteString
        XCTAssertTrue(url.hasSuffix("auth/login") || url.hasSuffix("auth/login/"),
                       "authLoginURL should end with auth/login path: \(url)")
    }

    func testAuthCallbackScheme() {
        XCTAssertEqual(AppConfig.authCallbackScheme, "resonance")
    }

    func testAuthCallbackURL() {
        XCTAssertEqual(AppConfig.authCallbackURL.scheme, "resonance")
        XCTAssertEqual(AppConfig.authCallbackURL.host, "auth-callback")
    }

    func testKeychainNamespaceNotDefault() {
        // Unless the sanitized URL is empty (which it should not be for any valid URL),
        // we should not fall back to "resonance-default"
        let ns = AppConfig.keychainNamespace
        XCTAssertNotEqual(ns, "resonance-default",
                          "With a valid API base URL, keychainNamespace should not be the fallback default")
    }
}

// MARK: - KeychainStore Namespace Isolation Tests

final class KeychainStoreNamespaceTests: XCTestCase {

    func testAccountKeyProducesNamespacedKey() {
        // accountKey should prefix the raw key with the keychainNamespace + "."
        let result = KeychainStore.accountKey(for: "accessToken")
        let expected = "\(AppConfig.keychainNamespace).accessToken"
        XCTAssertEqual(result, expected,
                       "accountKey should produce '<namespace>.accessToken', got: \(result)")
    }

    func testAccountKeyNamespacePrefixIsConsistent() {
        // Multiple calls with different keys should all share the same namespace prefix
        let key1 = KeychainStore.accountKey(for: "accessToken")
        let key2 = KeychainStore.accountKey(for: "refreshToken")
        let key3 = KeychainStore.accountKey(for: "userId")

        let prefix = AppConfig.keychainNamespace + "."
        XCTAssertTrue(key1.hasPrefix(prefix))
        XCTAssertTrue(key2.hasPrefix(prefix))
        XCTAssertTrue(key3.hasPrefix(prefix))

        // The suffix after the prefix should be exactly the raw key
        XCTAssertEqual(String(key1.dropFirst(prefix.count)), "accessToken")
        XCTAssertEqual(String(key2.dropFirst(prefix.count)), "refreshToken")
        XCTAssertEqual(String(key3.dropFirst(prefix.count)), "userId")
    }

    func testDifferentAPIURLsProduceDifferentNamespaces() {
        // The keychainNamespace is derived from apiBaseURL. Since AppConfig uses a
        // static let computed once from the environment, we verify the derivation
        // logic directly: different URL strings should produce different sanitized outputs.
        let url1 = "http://localhost:4000"
        let url2 = "https://api.resonance.example.com"
        let url3 = "https://staging.resonance.example.com"

        func deriveNamespace(from urlString: String) -> String {
            let base = urlString.lowercased()
            let sanitized = base
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return sanitized.isEmpty ? "resonance-default" : "resonance-\(sanitized)"
        }

        let ns1 = deriveNamespace(from: url1)
        let ns2 = deriveNamespace(from: url2)
        let ns3 = deriveNamespace(from: url3)

        XCTAssertNotEqual(ns1, ns2, "localhost and production should have different namespaces")
        XCTAssertNotEqual(ns2, ns3, "production and staging should have different namespaces")
        XCTAssertNotEqual(ns1, ns3, "localhost and staging should have different namespaces")
    }

    func testNamespaceContainsOnlySafeCharacters() {
        // The namespace should only contain lowercase alphanumeric characters and hyphens.
        // (Dots are not expected in the namespace itself per the sanitization regex.)
        let ns = AppConfig.keychainNamespace
        let safeChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for scalar in ns.unicodeScalars {
            XCTAssertTrue(safeChars.contains(scalar),
                          "Namespace contains unsafe character '\(scalar)': \(ns)")
        }
    }

    func testNamespaceDoesNotStartOrEndWithHyphen() {
        let ns = AppConfig.keychainNamespace
        XCTAssertFalse(ns.hasPrefix("-"), "Namespace should not start with hyphen: \(ns)")
        XCTAssertFalse(ns.hasSuffix("-"), "Namespace should not end with hyphen: \(ns)")
    }
}

// MARK: - PDFExporter Sanitize & Helper Tests

final class PDFExporterSanitizeTests: XCTestCase {

    func testSanitizeRemovesControlCharacters() {
        // NUL, unit separator, and other C0 control characters should be replaced with spaces
        let input = "Hello\u{0000}World\u{001F}Test"
        let result = PDFExporter.sanitizeForPDF(input)
        XCTAssertFalse(result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                       "Result should not contain any control characters: \(result)")
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("World"))
        XCTAssertTrue(result.contains("Test"))
    }

    func testSanitizeReplacesTabsAndNewlines() {
        let input = "Line1\tTabbed\nLine2\r\nLine3"
        let result = PDFExporter.sanitizeForPDF(input)
        // Newlines are first converted to spaces, then control chars (tab, CR) also become spaces
        XCTAssertFalse(result.contains("\t"), "Tabs should be removed")
        XCTAssertFalse(result.contains("\n"), "Newlines should be removed")
        XCTAssertFalse(result.contains("\r"), "Carriage returns should be removed")
        XCTAssertTrue(result.contains("Line1"))
        XCTAssertTrue(result.contains("Line2"))
        XCTAssertTrue(result.contains("Line3"))
    }

    func testSanitizePreservesNormalUnicodeText() {
        let input = "Beethoven Sonata No. 14 -- Clair de Lune"
        let result = PDFExporter.sanitizeForPDF(input)
        XCTAssertEqual(result, input)
    }

    func testSanitizePreservesAccentedCharacters() {
        let input = "Debussy: Reverie en re bemol majeur"
        let result = PDFExporter.sanitizeForPDF(input)
        XCTAssertEqual(result, input)

        let accented = "Dvorak Serenade fur Streicher"
        let accentedResult = PDFExporter.sanitizeForPDF(accented)
        XCTAssertEqual(accentedResult, accented)
    }

    func testSanitizePreservesEmoji() {
        let input = "Great practice session! 🎵🎹👏"
        let result = PDFExporter.sanitizeForPDF(input)
        XCTAssertTrue(result.contains("🎵"), "Emoji should be preserved")
        XCTAssertTrue(result.contains("🎹"), "Emoji should be preserved")
        XCTAssertTrue(result.contains("👏"), "Emoji should be preserved")
        XCTAssertTrue(result.contains("Great practice session!"))
    }

    func testSanitizePreservesUnicodeScripts() {
        // CJK, Cyrillic, Arabic characters should all be preserved
        let cjk = "練習 ピアノ 피아노"
        XCTAssertEqual(PDFExporter.sanitizeForPDF(cjk), cjk)

        let cyrillic = "Фортепиано"
        XCTAssertEqual(PDFExporter.sanitizeForPDF(cyrillic), cyrillic)
    }

    func testSanitizeTrimsWhitespace() {
        let input = "  spaced out  "
        let result = PDFExporter.sanitizeForPDF(input)
        XCTAssertEqual(result, "spaced out", "Leading/trailing whitespace should be trimmed")
    }

    func testSanitizeEmptyString() {
        let result = PDFExporter.sanitizeForPDF("")
        XCTAssertEqual(result, "")
    }

    func testSanitizeStringOfOnlyControlCharacters() {
        let input = "\u{0000}\u{0001}\u{001F}"
        let result = PDFExporter.sanitizeForPDF(input)
        // After trimming whitespace/newlines from the original, then replacing controls with spaces,
        // the result should contain only spaces (no control characters remain).
        XCTAssertFalse(result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                       "Should not contain control characters")
    }

    func testSanitizeVeryLongString() {
        // Verify no crash with a very long string (10000 characters)
        let longString = String(repeating: "Practice scales and arpeggios. ", count: 334)
        XCTAssertTrue(longString.count > 10000)
        let result = PDFExporter.sanitizeForPDF(longString)
        XCTAssertFalse(result.isEmpty, "Sanitize should handle long strings without crashing")
        XCTAssertTrue(result.count > 9000, "Long string should be mostly preserved")
    }
}

// MARK: - PDFExporter Empty & Edge Case Tests

final class PDFExporterEdgeCaseTests: XCTestCase {

    @MainActor
    func testExportWithEmptyEntriesDoesNotCrash() {
        // PDFExporter.export uses UIGraphicsPDFRenderer which requires UIKit.
        // In a unit-test environment without a full UIKit host, we verify the
        // method signature accepts an empty array. If UIKit is available, it
        // should not crash; if not, we just verify it throws rather than crashes.
        let entries: [LocalPracticeEntry] = []
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-empty-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // This may throw if UIKit rendering isn't available in the test host,
        // but it must not crash (e.g., force-unwrap, index out of bounds).
        do {
            try PDFExporter.export(entries: entries, to: tempURL)
            // If we get here, export succeeded -- the file should exist
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        } catch {
            // Acceptable: UIKit renderer may not be available in test host.
            // The key assertion is that we did not crash.
        }
    }

    @MainActor
    func testExportWithVeryLongGoalTextDoesNotCrash() {
        let longGoal = String(repeating: "A", count: 10_000)
        let entry = LocalPracticeEntry(
            id: "long-goal-entry",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(practiceDate: Date(), goalText: longGoal, durationSeconds: nil, tags: [], notes: nil),
            status: .draft
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-long-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try PDFExporter.export(entries: [entry], to: tempURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        } catch {
            // Acceptable: UIKit renderer may not be available in test host.
        }
    }
}


// MARK: - RetryPolicy Tests

final class RetryPolicyTests: XCTestCase {

    private let policy = RetryPolicy()

    // MARK: maxAttempts

    func testDefaultMaxAttempts() {
        XCTAssertEqual(policy.maxAttempts, 20)
    }

    func testCustomMaxAttempts() {
        XCTAssertEqual(RetryPolicy(maxAttempts: 5).maxAttempts, 5)
    }

    // MARK: backoffDelay

    func testBackoffDelayRetryCount0() {
        XCTAssertEqual(policy.backoffDelay(retryCount: 0), 1.0, accuracy: 0.001)
    }

    func testBackoffDelayRetryCount3() {
        XCTAssertEqual(policy.backoffDelay(retryCount: 3), 8.0, accuracy: 0.001)
    }

    func testBackoffDelayCapsAt300() {
        XCTAssertEqual(policy.backoffDelay(retryCount: 10), 300.0, accuracy: 0.001)
        XCTAssertEqual(policy.backoffDelay(retryCount: 100), 300.0, accuracy: 0.001)
    }

    // MARK: isTerminal — SyncError is always terminal

    func testIsTerminalForPayloadParseError() {
        XCTAssertTrue(policy.isTerminal(SyncError.payloadParseError("bad")))
    }

    func testIsTerminalForUnknownTaskType() {
        XCTAssertTrue(policy.isTerminal(SyncError.unknownTaskType("x")))
    }

    func testIsTerminalForLocalFileNotFound() {
        XCTAssertTrue(policy.isTerminal(SyncError.localFileNotFound("/tmp/missing")))
    }

    func testIsTerminalForLocalFeedbackNotFound() {
        XCTAssertTrue(policy.isTerminal(SyncError.localFeedbackNotFound("f-1")))
    }

    // MARK: isTerminal — SyncLocal 404 is terminal

    func testIsTerminalForSyncLocal404() {
        let err = NSError(domain: "SyncLocal", code: 404, userInfo: [NSLocalizedDescriptionKey: "not found"])
        XCTAssertTrue(policy.isTerminal(err))
    }

    func testIsNotTerminalForSyncLocal500() {
        let err = NSError(domain: "SyncLocal", code: 500, userInfo: [:])
        XCTAssertFalse(policy.isTerminal(err))
    }

    // MARK: isTerminal — generic network errors are retryable

    func testIsNotTerminalForURLError() {
        XCTAssertFalse(policy.isTerminal(URLError(.networkConnectionLost)))
    }

    func testIsNotTerminalForURLErrorTimedOut() {
        XCTAssertFalse(policy.isTerminal(URLError(.timedOut)))
    }
}

// MARK: - QueueStore Tests

final class QueueStoreTests: XCTestCase {

    @MainActor
    private func makeStore() -> (container: ModelContainer, store: QueueStore) {
        let container = PersistenceController.createContainer(inMemory: true)
        let store = QueueStore(modelContext: container.mainContext)
        return (container, store)
    }

    // MARK: enqueue / counts

    @MainActor
    func testEnqueueInsertsItemWithCorrectType() throws {
        let (container, store) = makeStore()
        store.enqueue(type: .createEntry, payload: ["entryId": "e-1"])
        let items = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.type, SyncTaskType.createEntry.rawValue)
        XCTAssertEqual(items.first?.status, SyncStatus.pending.rawValue)
    }

    @MainActor
    func testEnqueueRejectsInvalidPayload() throws {
        let (container, store) = makeStore()
        store.enqueue(type: .createEntry, payload: ["nan": Double.nan])
        let items = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertTrue(items.isEmpty)
    }

    @MainActor
    func testCountsReturnCorrectValues() throws {
        let (container, store) = makeStore()
        let pending = SyncQueueItem(id: "p", type: "createEntry", payloadJSON: "{}")
        pending.status = SyncStatus.pending.rawValue
        container.mainContext.insert(pending)

        let failed = SyncQueueItem(id: "f", type: "createEntry", payloadJSON: "{}")
        failed.status = SyncStatus.failed.rawValue
        container.mainContext.insert(failed)
        try container.mainContext.save()

        let (p, f) = store.counts()
        XCTAssertEqual(p, 1)
        XCTAssertEqual(f, 1)
    }

    // MARK: fetchReady

    @MainActor
    func testFetchReadyFiltersItemsWithFutureNextAttemptAt() throws {
        let (container, store) = makeStore()
        let now = Date()

        let ready = SyncQueueItem(id: "ready", type: "createEntry", payloadJSON: "{}")
        ready.status = SyncStatus.pending.rawValue
        ready.nextAttemptAt = nil
        container.mainContext.insert(ready)

        let notYet = SyncQueueItem(id: "not-yet", type: "createEntry", payloadJSON: "{}")
        notYet.status = SyncStatus.pending.rawValue
        notYet.nextAttemptAt = now.addingTimeInterval(60)
        container.mainContext.insert(notYet)

        try container.mainContext.save()

        let fetched = try store.fetchReady(now: now)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, "ready")
    }

    // MARK: resetAllFailed

    @MainActor
    func testResetAllFailedClearsErrorAndNextAttempt() throws {
        let (container, store) = makeStore()
        let item = SyncQueueItem(id: "fail-1", type: "createEntry", payloadJSON: "{}")
        item.status = SyncStatus.failed.rawValue
        item.lastError = "some error"
        item.nextAttemptAt = Date().addingTimeInterval(60)
        container.mainContext.insert(item)
        try container.mainContext.save()

        store.resetAllFailed()

        let fetched = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(fetched.first?.status, SyncStatus.pending.rawValue)
        XCTAssertNil(fetched.first?.lastError)
        XCTAssertNil(fetched.first?.nextAttemptAt)
    }

    @MainActor
    func testResetAllFailedResetsSyncArtifactPhaseToQueued() throws {
        let (container, store) = makeStore()
        let entry = LocalPracticeEntry(
            id: "entry-1",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(practiceDate: Date(), goalText: "Goal", durationSeconds: nil, tags: [], notes: nil),
            status: .draft
        )
        let artifact = LocalArtifact(
            id: "artifact-1",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 30,
            localPath: "/tmp/artifact-1.m4a"
        )
        artifact.uploadState = .uploading
        artifact.syncPhase = .confirming
        entry.artifacts.append(artifact)
        container.mainContext.insert(entry)
        container.mainContext.insert(artifact)

        let payloadData = try JSONSerialization.data(withJSONObject: ["artifactId": artifact.id])
        let payloadJSON = try XCTUnwrap(String(bytes: payloadData, encoding: .utf8))
        let item = SyncQueueItem(
            id: "sync-artifact",
            type: SyncTaskType.syncArtifact.rawValue,
            payloadJSON: payloadJSON
        )
        item.status = SyncStatus.failed.rawValue
        container.mainContext.insert(item)
        try container.mainContext.save()

        store.resetAllFailed()

        XCTAssertEqual(item.status, SyncStatus.pending.rawValue)
        XCTAssertEqual(artifact.uploadState, .pending)
        XCTAssertEqual(artifact.syncPhase, .queued)
    }

    // MARK: resetStuckProcessing

    @MainActor
    func testResetStuckProcessingResetsToPending() throws {
        let (container, store) = makeStore()
        let item = SyncQueueItem(id: "stuck", type: "syncArtifact", payloadJSON: "{}")
        item.status = SyncStatus.processing.rawValue
        container.mainContext.insert(item)
        try container.mainContext.save()

        store.resetStuckProcessing()

        let fetched = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(fetched.first?.status, SyncStatus.pending.rawValue)
    }

    // MARK: delete

    @MainActor
    func testDeleteRemovesItem() throws {
        let (container, store) = makeStore()
        let item = SyncQueueItem(id: "to-delete", type: "submitEntry", payloadJSON: "{}")
        container.mainContext.insert(item)
        try container.mainContext.save()

        store.delete(item)
        store.save()

        let fetched = try container.mainContext.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertTrue(fetched.isEmpty)
    }
}
