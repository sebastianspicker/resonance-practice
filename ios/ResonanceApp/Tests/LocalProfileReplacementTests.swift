import Foundation
import SwiftData
import XCTest
@testable import ResonanceApp

final class LocalProfileReplacementTests: XCTestCase {
    @MainActor
    func testReplaceLocalProfileRemovesPreviousRecordsAndMediaBeforeSettingOwner() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let context = container.mainContext
        let fileURL = try makeProfileMediaFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        makeLocalProfileFixture(in: context, fileURL: fileURL)

        var writtenOwner: String?
        let appState = AppState(
            modelContext: context,
            removeCalendarSubscription: {},
            localDataOwner: { writtenOwner },
            setLocalDataOwner: { writtenOwner = $0 }
        )
        try appState.replaceLocalProfile(with: "new-user")

        XCTAssertEqual(writtenOwner, "new-user")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        try assertNoLocalProfileData(in: context)
    }

    @MainActor
    func testReplaceLocalProfileDoesNotSetOwnerWhenArtifactFetchFails() {
        var writtenOwner: String?
        let container = PersistenceController.createContainer(inMemory: true)
        let appState = AppState(
            modelContext: container.mainContext,
            fetchArtifacts: { throw LocalProfileReplacementTestError.fetchFailed },
            removeCalendarSubscription: {},
            setLocalDataOwner: { writtenOwner = $0 }
        )

        XCTAssertThrowsError(try appState.replaceLocalProfile(with: "new-user"))
        XCTAssertNil(writtenOwner)
    }

    @MainActor
    func testActivateLocalProfileRejectsLegacyDataWithoutAnOwnerMarker() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let context = container.mainContext
        let fileURL = try makeProfileMediaFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        makeLocalProfileFixture(in: context, fileURL: fileURL)

        var writtenOwner: String?
        let appState = AppState(
            modelContext: context,
            removeCalendarSubscription: {},
            localDataOwner: { nil },
            setLocalDataOwner: { writtenOwner = $0 }
        )

        XCTAssertFalse(try appState.activateLocalProfile(userId: "first-user"))
        XCTAssertNil(writtenOwner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testReplaceLocalProfileDoesNotAdmitAnAccountWhenOwnerWriteFails() {
        let container = PersistenceController.createContainer(inMemory: true)
        let appState = AppState(
            modelContext: container.mainContext,
            hasStoredMediaFiles: { false },
            removeCalendarSubscription: {},
            localDataOwner: { nil },
            setLocalDataOwner: { _ in throw LocalProfileReplacementTestError.ownerWriteFailed }
        )

        XCTAssertThrowsError(try appState.replaceLocalProfile(with: "new-user"))
    }

    @MainActor
    func testReplaceLocalProfileDoesNotSetOwnerWhenSaveFails() {
        var writtenOwner: String?
        let container = PersistenceController.createContainer(inMemory: true)
        let appState = AppState(
            modelContext: container.mainContext,
            saveChanges: { throw LocalProfileReplacementTestError.saveFailed },
            removeCalendarSubscription: {},
            setLocalDataOwner: { writtenOwner = $0 }
        )

        XCTAssertThrowsError(try appState.replaceLocalProfile(with: "new-user"))
        XCTAssertNil(writtenOwner)
    }

    @MainActor
    func testReplaceLocalProfileDoesNotSetOwnerWhenCalendarRemovalFails() {
        var writtenOwner: String?
        let container = PersistenceController.createContainer(inMemory: true)
        let appState = AppState(
            modelContext: container.mainContext,
            hasStoredMediaFiles: { false },
            removeCalendarSubscription: { throw LocalProfileReplacementTestError.calendarRemovalFailed },
            setLocalDataOwner: { writtenOwner = $0 }
        )

        XCTAssertThrowsError(try appState.replaceLocalProfile(with: "new-user"))
        XCTAssertNil(writtenOwner)
    }

    @MainActor
    func testReplaceLocalProfileDoesNotSetOwnerWhenMediaRemovalFails() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let context = container.mainContext
        let fileURL = try makeProfileMediaFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        makeLocalProfileFixture(in: context, fileURL: fileURL)

        var writtenOwner: String?
        let appState = AppState(
            modelContext: context,
            removeStoredMediaFiles: { throw LocalProfileReplacementTestError.fileRemovalFailed },
            removeCalendarSubscription: {},
            setLocalDataOwner: { writtenOwner = $0 }
        )

        XCTAssertThrowsError(try appState.replaceLocalProfile(with: "new-user"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(writtenOwner)
    }

    @MainActor
    func testReplaceLocalProfileRemovesOrphanMediaFiles() throws {
        let fileURL = try makeProfileMediaFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        var writtenOwner: String?
        let container = PersistenceController.createContainer(inMemory: true)
        let appState = AppState(
            modelContext: container.mainContext,
            removeCalendarSubscription: {},
            localDataOwner: { writtenOwner },
            setLocalDataOwner: { writtenOwner = $0 }
        )

        try appState.replaceLocalProfile(with: "new-user")

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(writtenOwner, "new-user")
    }

    @MainActor
    private func makeLocalProfileFixture(in context: ModelContext, fileURL: URL) {
        let course = LocalCourse(id: "previous-course", title: "Previous course", roleInCourse: "student")
        let entry = LocalPracticeEntry(
            id: "previous-entry",
            courseId: course.id,
            studentId: "previous-user",
            details: PracticeEntryDetails(practiceDate: Date(), goalText: "Previous goal", durationSeconds: nil, tags: [], notes: nil),
            status: .draft
        )
        let artifact = LocalArtifact(
            id: "previous-artifact",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 30,
            localPath: fileURL.path
        )
        entry.artifacts.append(artifact)
        context.insert(course)
        context.insert(entry)
        context.insert(artifact)
        try? context.save()
    }

    private func makeProfileMediaFile() throws -> URL {
        let url = FileStore.mediaDirectory().appendingPathComponent("local-profile-media-\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: url)
        return url
    }

    private func assertNoLocalProfileData(in context: ModelContext) throws {
        XCTAssertTrue(try context.fetch(FetchDescriptor<LocalCourse>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<LocalArtifact>()).isEmpty)
    }
}

private enum LocalProfileReplacementTestError: Error {
    case fetchFailed
    case saveFailed
    case fileRemovalFailed
    case ownerWriteFailed
    case calendarRemovalFailed
}
