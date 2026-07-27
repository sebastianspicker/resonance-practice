import Foundation
import SwiftData
import XCTest
@testable import ResonanceApp

// Purpose: verifies owner transitions erase prior local records and media before replacement.

final class LocalProfileReplacementTests: XCTestCase {
    private final class OwnerCapture {
        var value: String?
    }

    private struct LocalProfileFixture {
        let container: ModelContainer
        let context: ModelContext
        let fileURL: URL
    }

    @MainActor
    func testReplaceLocalProfileRemovesPreviousRecordsAndMediaBeforeSettingOwner() async throws {
        try await withLocalProfileFixture { fixture in
            let writtenOwner = OwnerCapture()
            let appState = self.makeProfileAppState(context: fixture.context, owner: writtenOwner) { writtenOwner.value }
            try await appState.replaceLocalProfile(with: "new-user")

            XCTAssertEqual(writtenOwner.value, "new-user")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
            try self.assertNoLocalProfileData(in: fixture.context)
        }
    }

    @MainActor
    func testReplaceLocalProfileDoesNotSetOwnerWhenArtifactFetchFails() async {
        var writtenOwner: String?
        let container = PersistenceController.createContainer(inMemory: true)
        let appState = AppState(
            modelContext: container.mainContext,
            fetchArtifacts: { throw LocalProfileReplacementTestError.fetchFailed },
            removeCalendarSubscription: {},
            setLocalDataOwner: { writtenOwner = $0 }
        )

        await assertReplaceLocalProfileFails(appState, expectedError: .fetchFailed)
        XCTAssertNil(writtenOwner)
    }

    @MainActor
    func testActivateLocalProfileRejectsLegacyDataWithoutAnOwnerMarker() async throws {
        try await withLocalProfileFixture { fixture in
            let writtenOwner = OwnerCapture()
            let appState = self.makeProfileAppState(context: fixture.context, owner: writtenOwner) { nil }

            XCTAssertFalse(try appState.activateLocalProfile(userId: "first-user"))
            XCTAssertNil(writtenOwner.value)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        }
    }

    @MainActor
    func testReplaceLocalProfileDoesNotAdmitAnAccountWhenOwnerWriteFails() async {
        let container = PersistenceController.createContainer(inMemory: true)
        let appState = AppState(
            modelContext: container.mainContext,
            hasStoredMediaFiles: { false },
            removeCalendarSubscription: {},
            localDataOwner: { nil },
            setLocalDataOwner: { _ in throw LocalProfileReplacementTestError.ownerWriteFailed }
        )

        await assertReplaceLocalProfileFails(appState, expectedError: .ownerWriteFailed)
    }

    @MainActor
    func testReplaceLocalProfileDoesNotSetOwnerWhenSaveFails() async {
        var writtenOwner: String?
        let container = PersistenceController.createContainer(inMemory: true)
        let appState = AppState(
            modelContext: container.mainContext,
            saveChanges: { throw LocalProfileReplacementTestError.saveFailed },
            removeCalendarSubscription: {},
            setLocalDataOwner: { writtenOwner = $0 }
        )

        await assertReplaceLocalProfileFails(appState, expectedError: .saveFailed)
        XCTAssertNil(writtenOwner)
    }

    @MainActor
    func testReplaceLocalProfileDoesNotSetOwnerWhenCalendarRemovalFails() async {
        var writtenOwner: String?
        let container = PersistenceController.createContainer(inMemory: true)
        let appState = AppState(
            modelContext: container.mainContext,
            hasStoredMediaFiles: { false },
            removeCalendarSubscription: { throw LocalProfileReplacementTestError.calendarRemovalFailed },
            setLocalDataOwner: { writtenOwner = $0 }
        )

        await assertReplaceLocalProfileFails(appState, expectedError: .calendarRemovalFailed)
        XCTAssertNil(writtenOwner)
    }

    @MainActor
    func testReplaceLocalProfileDoesNotSetOwnerWhenMediaRemovalFails() async throws {
        try await withLocalProfileFixture { fixture in
            let writtenOwner = OwnerCapture()
            let appState = self.makeProfileAppState(
                context: fixture.context,
                owner: writtenOwner,
                removeStoredMediaFiles: { throw LocalProfileReplacementTestError.fileRemovalFailed }
            )

            await self.assertReplaceLocalProfileFails(appState, expectedError: .fileRemovalFailed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
            XCTAssertNil(writtenOwner.value)
        }
    }

    @MainActor
    func testReplaceLocalProfileRemovesOrphanMediaFiles() async throws {
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

        try await appState.replaceLocalProfile(with: "new-user")

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(writtenOwner, "new-user")
    }

    @MainActor
    func testCredentialRemovalFailurePreservesLocalDataAndOwnerDuringSignOut() async throws {
        try await withLocalProfileFixture { fixture in
            var owner: String? = "previous-user"
            let appState = self.makeSignOutAppState(
                context: fixture.context,
                localDataOwner: { owner },
                removeLocalDataOwner: { owner = nil },
                clearLocalCredentials: {
                    throw LocalProfileReplacementTestError.credentialRemovalFailed
                }
            )

            try await self.assertFailedSignOutPreservesLocalFixture(fixture, appState: appState)

            XCTAssertEqual(owner, "previous-user")
        }
    }

    @MainActor
    func testPurgeFailureStillRevokesRemoteSessionAndReportsError() async throws {
        try await withLocalProfileFixture { fixture in
            var owner: String? = "previous-user"
            var revokedSession: AuthSession?
            let signedOutSession = AuthSession(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                userId: "previous-user",
                displayName: "Previous User",
                globalRole: "student"
            )
            let appState = self.makeSignOutAppState(
                context: fixture.context,
                localDataOwner: { owner },
                removeLocalDataOwner: { owner = nil },
                clearLocalCredentials: { signedOutSession },
                removeStoredMediaFiles: {
                    throw LocalProfileReplacementTestError.fileRemovalFailed
                },
                revokeRemoteSession: { revokedSession = $0 }
            )

            try await self.assertFailedSignOutPreservesLocalFixture(fixture, appState: appState)

            XCTAssertEqual(owner, "previous-user")
            XCTAssertEqual(revokedSession?.refreshToken, signedOutSession.refreshToken)
        }
    }

    @MainActor
    private func assertReplaceLocalProfileFails(
        _ appState: AppState,
        expectedError: LocalProfileReplacementTestError
    ) async {
        do {
            try await appState.replaceLocalProfile(with: "new-user")
            XCTFail("Expected local profile replacement to fail")
        } catch let error as LocalProfileReplacementTestError {
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Expected \(expectedError), got \(error)")
        }
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

    @MainActor
    private func makeLocalProfileFixture() throws -> LocalProfileFixture {
        let container = PersistenceController.createContainer(inMemory: true)
        let context = container.mainContext
        let fileURL = try makeProfileMediaFile()
        makeLocalProfileFixture(in: context, fileURL: fileURL)
        return LocalProfileFixture(container: container, context: context, fileURL: fileURL)
    }

    @MainActor
    private func withLocalProfileFixture(
        _ body: @escaping @MainActor (LocalProfileFixture) async throws -> Void
    ) async throws {
        let fixture = try makeLocalProfileFixture()
        defer { cleanUpProfileFixture(fixture) }
        try await body(fixture)
    }

    @MainActor
    private func makeProfileAppState(
        context: ModelContext,
        owner: OwnerCapture,
        localDataOwner: @escaping () -> String? = { nil },
        removeStoredMediaFiles: (() throws -> Void)? = nil
    ) -> AppState {
        if let removeStoredMediaFiles {
            return AppState(
                modelContext: context,
                removeStoredMediaFiles: removeStoredMediaFiles,
                removeCalendarSubscription: {},
                localDataOwner: localDataOwner,
                setLocalDataOwner: { owner.value = $0 }
            )
        }
        return AppState(
            modelContext: context,
            removeCalendarSubscription: {},
            localDataOwner: localDataOwner,
            setLocalDataOwner: { owner.value = $0 }
        )
    }

    @MainActor
    private func makeSignOutAppState(
        context: ModelContext,
        localDataOwner: @escaping () -> String?,
        removeLocalDataOwner: @escaping () -> Void,
        clearLocalCredentials: @escaping () throws -> AuthSession?,
        removeStoredMediaFiles: (() throws -> Void)? = nil,
        revokeRemoteSession: ((AuthSession?) -> Void)? = nil
    ) -> AppState {
        AppState(
            modelContext: context,
            removeStoredMediaFiles: removeStoredMediaFiles,
            removeCalendarSubscription: {},
            localDataOwner: localDataOwner,
            setLocalDataOwner: { _ in },
            removeLocalDataOwner: removeLocalDataOwner,
            clearLocalCredentials: clearLocalCredentials,
            revokeRemoteSession: revokeRemoteSession
        )
    }

    @MainActor
    private func assertFailedSignOutPreservesLocalFixture(
        _ fixture: LocalProfileFixture,
        appState: AppState
    ) async throws {
        await appState.signOutAndDeleteLocalData()

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        try assertLocalProfileDataPreserved(in: fixture.context)
        XCTAssertTrue(appState.showErrorAlert)
        XCTAssertNotNil(appState.lastErrorMessage)
    }

    private func cleanUpProfileFixture(_ fixture: LocalProfileFixture) {
        withExtendedLifetime(fixture.container) {}
        try? FileManager.default.removeItem(at: fixture.fileURL)
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

    private func assertLocalProfileDataPreserved(in context: ModelContext) throws {
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalCourse>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalPracticeEntry>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalArtifact>()).count, 1)
    }
}

private enum LocalProfileReplacementTestError: Error, Equatable {
    case fetchFailed
    case saveFailed
    case fileRemovalFailed
    case ownerWriteFailed
    case calendarRemovalFailed
    case credentialRemovalFailed
}

final class LocalAlphaDataResetTests: XCTestCase {
    @MainActor
    func testResetClearsLocalStateBeforeRecordingGeneration() throws {
        try withResetFixture { context in
        var generation: String? = "pre-alpha"
        var owner: String? = "previous-user"
        var mediaExists = true
        var steps: [String] = []
        let environment = LocalAlphaDataReset.Environment(
            readGeneration: { generation },
            writeGeneration: {
                steps.append("generation")
                generation = $0
            },
            removeStoredMedia: {
                XCTAssertTrue(try self.isEmptyResetFixture(in: context))
                steps.append("media")
                mediaExists = false
            },
            hasStoredMedia: { mediaExists },
            removeCalendarSubscription: { steps.append("calendar") },
            localDataOwner: { owner },
            removeLocalDataOwner: {
                steps.append("owner")
                owner = nil
            },
            removePersistedAuth: { steps.append("auth") }
        )

        try LocalAlphaDataReset.runIfNeeded(modelContext: context, environment: environment)

        XCTAssertEqual(generation, LocalAlphaDataReset.generation)
        XCTAssertNil(owner)
        XCTAssertFalse(mediaExists)
        XCTAssertEqual(steps, ["auth", "media", "calendar", "owner", "generation"])
        XCTAssertTrue(try self.isEmptyResetFixture(in: context))
        }
    }

    @MainActor
    func testCredentialRemovalFailurePreservesResetDataAndOwner() throws {
        try withResetFixture { context in
            var generation: String? = "pre-alpha"
            var owner: String? = "previous-user"
            var mediaExists = true
            let environment = LocalAlphaDataReset.Environment(
                readGeneration: { generation },
                writeGeneration: { generation = $0 },
                removeStoredMedia: { mediaExists = false },
                hasStoredMedia: { mediaExists },
                removeCalendarSubscription: {},
                localDataOwner: { owner },
                removeLocalDataOwner: { owner = nil },
                removePersistedAuth: { throw LocalAlphaDataResetTestError.credentialRemovalFailed }
            )

            XCTAssertThrowsError(try LocalAlphaDataReset.runIfNeeded(modelContext: context, environment: environment))

            XCTAssertEqual(generation, "pre-alpha")
            XCTAssertEqual(owner, "previous-user")
            XCTAssertTrue(mediaExists)
            XCTAssertFalse(try self.isEmptyResetFixture(in: context))
        }
    }

    @MainActor
    func testResetFailureDoesNotRecordGenerationAndRetriesOnNextLaunch() throws {
        try withResetFixture { context in
        var generation: String? = "pre-alpha"
        var owner: String? = "previous-user"
        var calendarShouldFail = true
        var authRemovalCount = 0
        let environment = LocalAlphaDataReset.Environment(
            readGeneration: { generation },
            writeGeneration: { generation = $0 },
            removeStoredMedia: {},
            hasStoredMedia: { false },
            removeCalendarSubscription: {
                if calendarShouldFail { throw LocalAlphaDataResetTestError.calendarRemovalFailed }
            },
            localDataOwner: { owner },
            removeLocalDataOwner: { owner = nil },
            removePersistedAuth: { authRemovalCount += 1 }
        )

        XCTAssertThrowsError(
            try LocalAlphaDataReset.runIfNeeded(modelContext: context, environment: environment)
        )
        XCTAssertEqual(generation, "pre-alpha")
        XCTAssertEqual(owner, "previous-user")
        XCTAssertEqual(authRemovalCount, 1)

        calendarShouldFail = false
        try LocalAlphaDataReset.runIfNeeded(modelContext: context, environment: environment)

        XCTAssertEqual(generation, LocalAlphaDataReset.generation)
        XCTAssertNil(owner)
        XCTAssertEqual(authRemovalCount, 2)
        }
    }

    @MainActor
    func testRecordedGenerationSkipsReset() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let context = container.mainContext
        let course = LocalCourse(id: "keep-course", title: "Keep", roleInCourse: "student")
        context.insert(course)
        try context.save()
        var calls = 0
        let environment = LocalAlphaDataReset.Environment(
            readGeneration: { LocalAlphaDataReset.generation },
            writeGeneration: { _ in calls += 1 },
            removeStoredMedia: { calls += 1 },
            hasStoredMedia: { false },
            removeCalendarSubscription: { calls += 1 },
            localDataOwner: { nil },
            removeLocalDataOwner: { calls += 1 },
            removePersistedAuth: { calls += 1 }
        )

        try LocalAlphaDataReset.runIfNeeded(modelContext: context, environment: environment)

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalCourse>()).map(\.id), ["keep-course"])
    }

    @MainActor
    func testMissingGenerationWithExistingDataRequiresRecoveryInsteadOfWiping() throws {
        try withResetFixture { context in
        let cleanupCounter = CleanupCallCounter()
        let environment = self.makeAmbiguousResetEnvironment(generation: nil, cleanupCounter: cleanupCounter)

        try self.assertAmbiguousExistingData(in: context, environment: environment, cleanupCounter: cleanupCounter)
        XCTAssertFalse(try self.isEmptyResetFixture(in: context))
        }
    }

    @MainActor
    func testMissingGenerationWithExistingMediaRequiresRecoveryInsteadOfWiping() throws {
        try assertMissingGenerationRequiresRecovery(hasStoredMedia: true, owner: nil)
    }

    @MainActor
    func testMissingGenerationWithExistingOwnerRequiresRecoveryInsteadOfWiping() throws {
        try assertMissingGenerationRequiresRecovery(hasStoredMedia: false, owner: "existing-user")
    }

    @MainActor
    private func assertMissingGenerationRequiresRecovery(
        hasStoredMedia: Bool,
        owner: String?
    ) throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let context = container.mainContext
        let cleanupCounter = CleanupCallCounter()
        let environment = LocalAlphaDataReset.Environment(
            readGeneration: { nil },
            writeGeneration: { _ in cleanupCounter.calls += 1 },
            removeStoredMedia: { cleanupCounter.calls += 1 },
            hasStoredMedia: { hasStoredMedia },
            removeCalendarSubscription: { cleanupCounter.calls += 1 },
            localDataOwner: { owner },
            removeLocalDataOwner: { cleanupCounter.calls += 1 },
            removePersistedAuth: { cleanupCounter.calls += 1 }
        )

        try assertAmbiguousExistingData(in: context, environment: environment, cleanupCounter: cleanupCounter)
        withExtendedLifetime(container) {}
    }

    @MainActor
    func testUnknownGenerationRequiresRecoveryInsteadOfWiping() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let cleanupCounter = CleanupCallCounter()
        let environment = makeAmbiguousResetEnvironment(
            generation: "0.2.0-beta.1",
            cleanupCounter: cleanupCounter
        )

        try assertAmbiguousExistingData(
            in: container.mainContext,
            environment: environment,
            cleanupCounter: cleanupCounter
        )
    }

    @MainActor
    func testCorruptGenerationRequiresRecoveryInsteadOfWiping() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let cleanupCounter = CleanupCallCounter()
        let environment = makeAmbiguousResetEnvironment(
            generation: "not-a-generation",
            cleanupCounter: cleanupCounter
        )

        try assertAmbiguousExistingData(
            in: container.mainContext,
            environment: environment,
            cleanupCounter: cleanupCounter
        )
    }

    @MainActor
    func testInMemoryContainerDoesNotRunLiveReset() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let context = container.mainContext
        let course = LocalCourse(id: "in-memory-course", title: "Test", roleInCourse: "student")
        context.insert(course)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalCourse>()).map(\.id), ["in-memory-course"])
    }

    @MainActor
    private func insertResetFixture(into context: ModelContext) {
        let course = LocalCourse(id: "reset-course", title: "Reset", roleInCourse: "student")
        let entry = LocalPracticeEntry(
            id: "reset-entry",
            courseId: course.id,
            studentId: "previous-user",
            details: PracticeEntryDetails(practiceDate: Date(), goalText: "Reset", durationSeconds: nil, tags: [], notes: nil),
            status: .draft
        )
        let artifact = LocalArtifact(
            id: "reset-artifact",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 1,
            localPath: "/tmp/reset-artifact.m4a"
        )
        context.insert(course)
        context.insert(entry)
        context.insert(artifact)
        context.insert(SyncQueueItem(id: "reset-queue", type: SyncTaskType.createEntry.rawValue, payloadJSON: "{}"))
        context.insert(CalendarEvent(id: "reset-event", summary: "Reset", startDate: Date(), endDate: Date(), location: nil))
        try? context.save()
    }

    @MainActor
    private func withResetFixture(_ body: (ModelContext) throws -> Void) throws {
        let container = PersistenceController.createContainer(inMemory: true)
        insertResetFixture(into: container.mainContext)
        defer { withExtendedLifetime(container) {} }
        try body(container.mainContext)
    }

    @MainActor
    private func isEmptyResetFixture(in context: ModelContext) throws -> Bool {
        try context.fetch(FetchDescriptor<LocalCourse>()).isEmpty &&
            context.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty &&
            context.fetch(FetchDescriptor<LocalArtifact>()).isEmpty &&
            context.fetch(FetchDescriptor<SyncQueueItem>()).isEmpty &&
            context.fetch(FetchDescriptor<CalendarEvent>()).isEmpty
    }

    @MainActor
    private func makeAmbiguousResetEnvironment(
        generation: String?,
        cleanupCounter: CleanupCallCounter
    ) -> LocalAlphaDataReset.Environment {
        LocalAlphaDataReset.Environment(
            readGeneration: { generation },
            writeGeneration: { _ in cleanupCounter.calls += 1 },
            removeStoredMedia: { cleanupCounter.calls += 1 },
            hasStoredMedia: { false },
            removeCalendarSubscription: { cleanupCounter.calls += 1 },
            localDataOwner: { nil },
            removeLocalDataOwner: { cleanupCounter.calls += 1 },
            removePersistedAuth: { cleanupCounter.calls += 1 }
        )
    }

    @MainActor
    private func assertAmbiguousExistingData(
        in context: ModelContext,
        environment: LocalAlphaDataReset.Environment,
        cleanupCounter: CleanupCallCounter
    ) throws {
        XCTAssertThrowsError(
            try LocalAlphaDataReset.runIfNeeded(modelContext: context, environment: environment)
        ) { error in
            XCTAssertEqual(error as? LocalAlphaDataResetError, .ambiguousExistingData)
        }
        XCTAssertEqual(cleanupCounter.calls, 0)
    }
}

private final class CleanupCallCounter {
    var calls = 0
}

private enum LocalAlphaDataResetTestError: Error {
    case calendarRemovalFailed
    case credentialRemovalFailed
}
