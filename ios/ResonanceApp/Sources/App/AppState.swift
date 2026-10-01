import Foundation
import SwiftData

// Composes app-wide services and forwards profile-bound local-data lifecycle transitions.
@MainActor
final class AppState: ObservableObject {
    let apiClient: APIClient
    let authManager: AuthManager
    let syncManager: SyncManager
    let networkMonitor: NetworkMonitor
    let errorReporter = ErrorReporter()
    private let localProfileLifecycle: LocalProfileLifecycle

    init(modelContext: ModelContext) {
        let client = APIClient()
        let auth = AppDemoDependencyFactory.makeAuthManager(client: client)
        let ownerStore = AppDemoDependencyFactory.makeLocalDataOwnerStore()
        let network = NetworkMonitor()
        let sync = SyncManager(
            modelContext: modelContext,
            authManager: auth,
            apiClient: client,
            networkMonitor: network,
            verifiedOwner: ownerStore.read
        )
        self.apiClient = client
        self.authManager = auth
        self.syncManager = sync
        self.networkMonitor = network
        self.localProfileLifecycle = .live(
            modelContext: modelContext,
            ownerStore: ownerStore,
            authManager: auth,
            syncManager: sync
        )
    }

    func activateLocalProfile(userId: String) throws -> Bool {
        try localProfileLifecycle.activate(userId: userId)
    }

    /// Cancels sync and erases the prior owner's local records before establishing a new owner.
    func replaceLocalProfile(with userId: String) async throws {
        try await localProfileLifecycle.replace(with: userId)
    }

    /// Performs the destructive sign-out path after in-flight sync work has been quiesced.
    func signOutAndDeleteLocalData() async {
        do {
            try await localProfileLifecycle.signOutAndDeleteLocalData()
        } catch {
            errorReporter.report(error)
        }
    }
}
