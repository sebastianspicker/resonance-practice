import Foundation
import SwiftData

// Constructs the queue, retry, and transport collaborators while preserving the public injection seam.
@MainActor
struct SyncManagerComposition {
    let authManager: AuthManager
    let apiClient: APIClient
    let networkMonitor: NetworkMonitor
    let store: QueueStore
    let retryPolicy: RetryPolicy
    let taskExecutor: TaskExecutor

    static func make(
        modelContext: ModelContext,
        authManager: AuthManager,
        apiClient: APIClient,
        networkMonitor: NetworkMonitor?,
        taskSession: URLSession?
    ) -> SyncManagerComposition {
        let resolvedNetworkMonitor = networkMonitor ?? NetworkMonitor()
        let store = QueueStore(modelContext: modelContext)
        let retryPolicy = RetryPolicy()
        // Background URLSession does not support async upload(for:fromFile:).
        // Extended execution is managed by SyncManager's application lifecycle.
        let session = taskSession ?? makeTaskSession()
        return SyncManagerComposition(
            authManager: authManager,
            apiClient: apiClient,
            networkMonitor: resolvedNetworkMonitor,
            store: store,
            retryPolicy: retryPolicy,
            taskExecutor: TaskExecutor(apiClient: apiClient, store: store, session: session)
        )
    }

    private static func makeTaskSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }
}

@MainActor
extension SyncManager {
    convenience init(
        modelContext: ModelContext,
        authManager: AuthManager,
        apiClient: APIClient,
        networkMonitor: NetworkMonitor? = nil,
        verifiedOwner: @escaping () throws -> String? = {
            try KeychainStore.read("localDataOwnerId")
        },
        taskSession: URLSession? = nil,
        processItemOverride: (@MainActor (SyncQueueItem, String) async throws -> Void)? = nil
    ) {
        self.init(
            composition: SyncManagerComposition.make(
                modelContext: modelContext,
                authManager: authManager,
                apiClient: apiClient,
                networkMonitor: networkMonitor,
                taskSession: taskSession
            ),
            verifiedOwner: verifiedOwner,
            processItemOverride: processItemOverride
        )
    }
}
