import XCTest
import SwiftData
@testable import ResonanceApp

// Purpose: verifies deletion and interrupted artifact-upload recovery across sync workflow boundaries.

private struct ArtifactSessionURLs {
    let create: URL
    let upload: URL
    let completion: URL
}

private final class DeferredArtifactScenario {
    let entry: LocalPracticeEntry
    let artifact: LocalArtifact
    let createURL = AppConfig.apiV1URL(path: "artifact-sessions")
    let uploadURL = URL(string: "https://storage.example.test/upload/deferred")!
    let completionURL = AppConfig.apiV1URL(path: "artifact-sessions/session-1/complete")
    let uploadStarted: XCTestExpectation
    var deferredUpload: DeferredArtifactURLProtocol?
    var completionRequestCount = 0

    init(entry: LocalPracticeEntry, artifact: LocalArtifact, uploadStarted: XCTestExpectation) {
        self.entry = entry
        self.artifact = artifact
        self.uploadStarted = uploadStarted
    }
}

final class ArtifactSyncRecoveryTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        DeferredArtifactURLProtocol.requestHandler = nil
        super.tearDown()
    }

    @MainActor
    func testArtifactRetryReconcilesAlreadyUploadedRemoteArtifact() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let localFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-already-uploaded.m4a")
        try Data("audio".utf8).write(to: localFileURL)
        defer { try? FileManager.default.removeItem(at: localFileURL) }
        let (entry, artifact) = makeArtifactRetryFixture(localFileURL: localFileURL)
        entry.serverVersion = 8
        modelContext.insert(entry)
        modelContext.insert(artifact)
        try modelContext.save()

        let createURL = AppConfig.apiV1URL(path: "artifact-sessions")
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, createURL)
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(testRequestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["baseVersion"] as? Int, 7)
            return (
                HTTPURLResponse(url: createURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                self.artifactSessionCreateResponse(
                    entryId: entry.id,
                    artifactId: artifact.id,
                    uploadState: "uploaded",
                    currentVersion: 8,
                    completed: true
                )
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let executor = TaskExecutor(
            apiClient: APIClient(session: URLSession(configuration: configuration)),
            store: QueueStore(modelContext: modelContext),
            session: URLSession(configuration: .ephemeral)
        )
        let item = SyncQueueItem(
            id: "artifact-retry",
            type: SyncTaskType.syncArtifact.rawValue,
            payloadJSON: "{\"artifactId\":\"\(artifact.id)\",\"baseVersion\":7}"
        )

        try await executor.execute(item: item, accessToken: "access-token")

        XCTAssertEqual(artifact.uploadState, .uploaded)
        XCTAssertEqual(artifact.syncPhase, .uploaded)
        XCTAssertEqual(artifact.storageKey, "artifacts/\(entry.id)/\(artifact.id)")
        XCTAssertEqual(artifact.remoteUrl, "https://storage.example.test/\(artifact.id)")
        XCTAssertEqual(entry.serverVersion, 8)
    }

    @MainActor
    func testArtifactSessionCompletionPropagatesServerVersion() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let localFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-session-complete.m4a")
        try Data("audio".utf8).write(to: localFileURL)
        defer { try? FileManager.default.removeItem(at: localFileURL) }
        let (entry, artifact) = makeArtifactRetryFixture(localFileURL: localFileURL)
        entry.serverVersion = 7
        modelContext.insert(entry)
        modelContext.insert(artifact)
        try modelContext.save()

        let urls = ArtifactSessionURLs(
            create: AppConfig.apiV1URL(path: "artifact-sessions"),
            upload: URL(string: "https://storage.example.test/upload/session-1")!,
            completion: AppConfig.apiV1URL(path: "artifact-sessions/session-1/complete")
        )
        var requestedURLs: [URL] = []
        MockURLProtocol.requestHandler = artifactSessionHandler(
            urls: urls,
            entryID: entry.id,
            artifactID: artifact.id,
            onRequest: { requestedURLs.append($0) }
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let executor = TaskExecutor(
            apiClient: APIClient(session: session),
            store: QueueStore(modelContext: modelContext),
            session: session
        )
        let item = SyncQueueItem(
            id: "artifact-complete",
            type: SyncTaskType.syncArtifact.rawValue,
            payloadJSON: "{\"artifactId\":\"\(artifact.id)\"}"
        )

        try await executor.execute(item: item, accessToken: "access-token")

        try assertCompletedArtifactSession(
            requestedURLs: requestedURLs,
            expectedURLs: [urls.create, urls.upload, urls.completion],
            artifact: artifact,
            entry: entry,
            item: item
        )
    }

    @MainActor
    func testSessionInvalidationStopsDeferredArtifactBeforeCompletionOrPostUploadMutation() async throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let context = container.mainContext
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-cancelled.m4a")
        try Data("audio".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (entry, artifact) = makeArtifactRetryFixture(localFileURL: fileURL)
        entry.serverVersion = 7
        context.insert(entry)
        context.insert(artifact)
        try context.save()

        let uploadStarted = expectation(description: "artifact upload started")
        let scenario = DeferredArtifactScenario(entry: entry, artifact: artifact, uploadStarted: uploadStarted)
        configureDeferredArtifactProtocol(scenario)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeferredArtifactURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(session: session)
        let auth = AuthManager(apiClient: client, removeSessionData: {})
        auth.session = AuthSession(
            accessToken: makeUnexpiredJWT(),
            refreshToken: "refresh-token",
            userId: "user-a",
            displayName: "User A",
            globalRole: "student"
        )
        let network = NetworkMonitor()
        network.isOnline = true
        let syncManager = SyncManager(
            modelContext: context,
            authManager: auth,
            apiClient: client,
            networkMonitor: network,
            verifiedOwner: { "user-a" },
            taskSession: session
        )
        syncManager.enqueue(type: .syncArtifact, payload: ["artifactId": artifact.id])

        let processingTask = Task { await syncManager.processQueue() }
        await fulfillment(of: [uploadStarted], timeout: 1)
        syncManager.invalidateProcessing()
        scenario.deferredUpload?.respond(statusCode: 200)
        await processingTask.value

        XCTAssertEqual(scenario.completionRequestCount, 0)
        XCTAssertEqual(artifact.syncPhase, .uploading)
        XCTAssertEqual(artifact.uploadState, .uploading)
        XCTAssertEqual(entry.serverVersion, 8)
        let queueItems = try context.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(queueItems.first?.status, SyncStatus.pending.rawValue)
    }

    private func configureDeferredArtifactProtocol(_ scenario: DeferredArtifactScenario) {
        DeferredArtifactURLProtocol.requestHandler = { requestProtocol, request in
            switch request.url {
            case scenario.createURL:
                let data = self.artifactSessionCreateResponse(
                    entryId: scenario.entry.id,
                    artifactId: scenario.artifact.id,
                    uploadState: "pending",
                    currentVersion: 8,
                    uploadURL: scenario.uploadURL.absoluteString
                )
                requestProtocol.respond(statusCode: 200, data: data)
            case scenario.uploadURL:
                scenario.deferredUpload = requestProtocol
                scenario.uploadStarted.fulfill()
            case scenario.completionURL:
                scenario.completionRequestCount += 1
                requestProtocol.respond(statusCode: 200)
            default:
                requestProtocol.respond(statusCode: 500)
            }
        }
    }

    private func artifactSessionHandler(
        urls: ArtifactSessionURLs,
        entryID: String,
        artifactID: String,
        onRequest: @escaping (URL) -> Void
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let requestURL = try XCTUnwrap(request.url)
            onRequest(requestURL)
            switch requestURL {
            case urls.create:
                XCTAssertEqual(request.httpMethod, "POST")
                let data = self.artifactSessionCreateResponse(
                    entryId: entryID,
                    artifactId: artifactID,
                    uploadState: "pending",
                    currentVersion: 8,
                    uploadURL: urls.upload.absoluteString
                )
                return (HTTPURLResponse(url: urls.create, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            case urls.upload:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/m4a")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "5")
                return (HTTPURLResponse(url: urls.upload, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            case urls.completion:
                XCTAssertEqual(request.httpMethod, "POST")
                let data = self.artifactSessionCompletionResponse(
                    entryId: entryID,
                    artifactId: artifactID,
                    currentVersion: 9
                )
                return (HTTPURLResponse(url: urls.completion, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            default:
                XCTFail("Unexpected request: \(requestURL.absoluteString)")
                return (HTTPURLResponse(url: urls.create, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
    }

    private func assertCompletedArtifactSession(
        requestedURLs: [URL],
        expectedURLs: [URL],
        artifact: LocalArtifact,
        entry: LocalPracticeEntry,
        item: SyncQueueItem
    ) throws {
        XCTAssertEqual(requestedURLs, expectedURLs)
        XCTAssertEqual(artifact.uploadState, .uploaded)
        XCTAssertEqual(artifact.syncPhase, .uploaded)
        XCTAssertEqual(entry.serverVersion, 9)
        let payloadData = Data(item.payloadJSON.utf8)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        XCTAssertEqual(payload["baseVersion"] as? Int, 7)
    }

    private func makeArtifactRetryFixture(localFileURL: URL) -> (LocalPracticeEntry, LocalArtifact) {
        let entry = LocalPracticeEntry(
            id: "entry-artifact-retry",
            courseId: "course-1",
            studentId: "student-1",
            details: PracticeEntryDetails(practiceDate: Date(), goalText: "Goal", durationSeconds: nil, tags: [], notes: nil),
            status: .draft
        )
        let artifact = LocalArtifact(
            id: "artifact-already-uploaded",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 30,
            localPath: localFileURL.path
        )
        entry.artifacts.append(artifact)
        return (entry, artifact)
    }

    private func artifactSessionCreateResponse(
        entryId: String,
        artifactId: String,
        uploadState: String,
        currentVersion: Int,
        uploadURL: String? = nil,
        completed: Bool? = nil
    ) -> Data {
        let uploadURLJSON = uploadURL.map { "\"\($0)\"" } ?? "null"
        let completedJSON = completed.map(String.init) ?? "null"
        let requiredHeadersJSON = completed == true
            ? "null"
            : "{\"Content-Type\":\"audio/m4a\",\"Content-Length\":\"5\"}"
        return Data(
            """
            {
              "sessionId":"session-1",
              "artifact":{
                "id":"\(artifactId)","entryId":"\(entryId)","type":"audio","durationSeconds":30,
                "uploadState":"\(uploadState)","storageKey":"artifacts/\(entryId)/\(artifactId)",
                "remoteUrl":"https://storage.example.test/\(artifactId)"
              },
              "completed":\(completedJSON),
              "uploadUrl":\(uploadURLJSON),
              "requiredHeaders":\(requiredHeadersJSON),
              "expiresInSeconds":900,
              "currentVersion":\(currentVersion)
            }
            """.utf8
        )
    }

    private func artifactSessionCompletionResponse(
        entryId: String,
        artifactId: String,
        currentVersion: Int
    ) -> Data {
        Data(
            """
            {
              "artifact":{
                "id":"\(artifactId)","entryId":"\(entryId)","type":"audio","durationSeconds":30,
                "uploadState":"uploaded","storageKey":"artifacts/\(entryId)/\(artifactId)",
                "remoteUrl":"https://storage.example.test/\(artifactId)"
              },
              "currentVersion":\(currentVersion)
            }
            """.utf8
        )
    }
}

final class CameraPrivacyConfigurationTests: XCTestCase {
    func testInfoPlistDeclaresCameraUsageDescription() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let infoPlistURL = packageRoot.appendingPathComponent("Sources/Resources/Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        let cameraPurpose = try XCTUnwrap(plist["NSCameraUsageDescription"] as? String)
        XCTAssertFalse(cameraPurpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

final class EntryDeletionCoordinatorTests: XCTestCase {
    @MainActor
    func testDeletingUnsyncedEntryCancelsQueuedWorkWithoutRemoteDelete() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeEntry(id: "entry-unsynced")
        let artifactURL = FileManager.default.temporaryDirectory.appendingPathComponent("entry-unsynced-audio.m4a")
        try Data("audio".utf8).write(to: artifactURL)

        let artifact = LocalArtifact(
            id: "artifact-unsynced",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 12,
            localPath: artifactURL.path
        )
        entry.artifacts.append(artifact)
        modelContext.insert(entry)
        modelContext.insert(artifact)
        modelContext.insert(makeQueueItem(id: "create-entry", type: .createEntry, payload: ["entryId": entry.id], status: .failed))
        modelContext.insert(makeQueueItem(id: "sync-artifact", type: .syncArtifact, payload: ["artifactId": artifact.id], status: .processing))
        modelContext.insert(
            makeQueueItem(
                id: "post-feedback",
                type: .postFeedback,
                payload: ["targetId": artifact.id, "targetType": "artifact"],
                status: .pending
            )
        )
        try modelContext.save()

        let remainingQueueItems = try deleteAndAssertEntryRemoved(
            entry: entry,
            artifactURL: artifactURL,
            context: modelContext,
            enqueuedRemoteDelete: false
        )
        XCTAssertTrue(remainingQueueItems.isEmpty)
    }

    @MainActor
    func testDeletingSyncedEntryKeepsOnlyRemoteDeleteQueueItem() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeEntry(id: "entry-synced")
        entry.serverVersion = 3
        let artifactURL = FileManager.default.temporaryDirectory.appendingPathComponent("entry-synced-audio.m4a")
        try Data("audio".utf8).write(to: artifactURL)

        let artifact = LocalArtifact(
            id: "artifact-synced",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 8,
            localPath: artifactURL.path
        )
        entry.artifacts.append(artifact)
        modelContext.insert(entry)
        modelContext.insert(artifact)
        modelContext.insert(makeQueueItem(id: "sync-artifact", type: .syncArtifact, payload: ["artifactId": artifact.id], status: .failed))
        try modelContext.save()

        let remainingQueueItems = try deleteAndAssertEntryRemoved(
            entry: entry,
            artifactURL: artifactURL,
            context: modelContext,
            enqueuedRemoteDelete: true
        )
        XCTAssertEqual(remainingQueueItems.count, 1)
        XCTAssertEqual(remainingQueueItems.first?.type, SyncTaskType.deleteEntry.rawValue)
        let deletePayload = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(remainingQueueItems.first?.payloadJSON.data(using: .utf8))
            ) as? [String: Any]
        )
        XCTAssertEqual(deletePayload["baseVersion"] as? Int, 3)
    }

    @MainActor
    func testMediaDeletionFailureLeavesLocalRecordsAndQueueWorkIntact() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeEntry(id: "entry-media-failure")
        let artifact = LocalArtifact(
            id: "artifact-media-failure",
            entryId: entry.id,
            type: .audio,
            durationSeconds: 8,
            localPath: "/unavailable/media.m4a"
        )
        entry.artifacts.append(artifact)
        modelContext.insert(entry)
        modelContext.insert(artifact)
        modelContext.insert(makeQueueItem(id: "create-entry", type: .createEntry, payload: ["entryId": entry.id], status: .pending))
        try modelContext.save()

        assertMediaDeletionFails(entry: entry, context: modelContext)

        try assertFailedDeletionPreserved(in: modelContext, artifactCount: 1)
    }

    @MainActor
    func testAdditionalOwnedMediaPathIsDeletedOnceWithEntry() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeEntry(id: "entry-extra-media")
        let extraURL = FileManager.default.temporaryDirectory.appendingPathComponent("entry-extra-media.m4a")
        try Data("recording".utf8).write(to: extraURL)
        defer { try? FileManager.default.removeItem(at: extraURL) }
        modelContext.insert(entry)
        try modelContext.save()
        var removedPaths: [String] = []

        _ = try EntryDeletionCoordinator.delete(
            entry: entry,
            modelContext: modelContext,
            ownerId: "owner-1",
            additionalOwnedMediaPaths: [extraURL.path, extraURL.path],
            removeArtifactFile: { path in
                removedPaths.append(path)
                try FileStore.removeFileIfExists(atPath: path)
            }
        )

        XCTAssertEqual(removedPaths, [extraURL.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraURL.path))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
    }

    @MainActor
    func testAdditionalOwnedMediaFailurePreservesPathForSuccessfulRetry() throws {
        let container = PersistenceController.createContainer(inMemory: true)
        let modelContext = container.mainContext
        let entry = makeEntry(id: "entry-extra-media-failure")
        modelContext.insert(entry)
        modelContext.insert(makeQueueItem(id: "create-entry", type: .createEntry, payload: ["entryId": entry.id], status: .pending))
        try modelContext.save()

        assertMediaDeletionFails(
            entry: entry,
            context: modelContext,
            additionalOwnedMediaPaths: ["/unavailable/recorder.m4a"]
        )

        try assertFailedDeletionPreserved(in: modelContext, artifactCount: 0)

        var retriedPaths: [String] = []
        _ = try EntryDeletionCoordinator.delete(
            entry: entry,
            modelContext: modelContext,
            ownerId: "owner-1",
            additionalOwnedMediaPaths: ["/unavailable/recorder.m4a"],
            removeArtifactFile: { retriedPaths.append($0) }
        )

        XCTAssertEqual(retriedPaths, ["/unavailable/recorder.m4a"])
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<SyncQueueItem>()).isEmpty)
    }

    @MainActor
    private func makeEntry(id: String) -> LocalPracticeEntry {
        makeDraftPracticeEntry(id: id)
    }

    @MainActor
    private func deleteAndAssertEntryRemoved(
        entry: LocalPracticeEntry,
        artifactURL: URL,
        context: ModelContext,
        enqueuedRemoteDelete: Bool
    ) throws -> [SyncQueueItem] {
        let result = try EntryDeletionCoordinator.delete(entry: entry, modelContext: context, ownerId: "owner-1")
        XCTAssertEqual(result.enqueuedRemoteDelete, enqueuedRemoteDelete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
        XCTAssertTrue(try context.fetch(FetchDescriptor<LocalPracticeEntry>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<LocalArtifact>()).isEmpty)
        return try context.fetch(FetchDescriptor<SyncQueueItem>())
    }

    @MainActor
    private func assertMediaDeletionFails(
        entry: LocalPracticeEntry,
        context: ModelContext,
        additionalOwnedMediaPaths: [String] = []
    ) {
        XCTAssertThrowsError(
            try EntryDeletionCoordinator.delete(
                entry: entry,
                modelContext: context,
                ownerId: "owner-1",
                additionalOwnedMediaPaths: additionalOwnedMediaPaths,
                removeArtifactFile: { _ in throw EntryDeletionTestError.mediaDeletionFailed }
            )
        )
    }

    @MainActor
    private func assertFailedDeletionPreserved(in context: ModelContext, artifactCount: Int) throws {
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalPracticeEntry>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalArtifact>()).count, artifactCount)
        let queueItems = try context.fetch(FetchDescriptor<SyncQueueItem>())
        XCTAssertEqual(queueItems.count, 1)
        XCTAssertEqual(queueItems.first?.type, SyncTaskType.createEntry.rawValue)
    }

    private func makeQueueItem(
        id: String,
        type: SyncTaskType,
        payload: [String: Any],
        status: SyncStatus
    ) -> SyncQueueItem {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            preconditionFailure("The supplied queue payload must be JSON-serializable")
        }
        guard let payloadJSON = String(bytes: data, encoding: .utf8) else {
            preconditionFailure("A JSON queue payload must be valid UTF-8")
        }
        let item = SyncQueueItem(id: id, type: type.rawValue, payloadJSON: payloadJSON)
        item.status = status.rawValue
        return item
    }
}

private enum EntryDeletionTestError: Error {
    case mediaDeletionFailed
}
