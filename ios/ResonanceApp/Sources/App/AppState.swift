import Foundation
import SwiftData

// Coordinates app-wide dependencies and profile-bound local-data lifecycle transitions.
@MainActor
final class AppState: ObservableObject {
    let apiClient: APIClient
    let authManager: AuthManager
    let syncManager: SyncManager
    let networkMonitor: NetworkMonitor
    let errorReporter = ErrorReporter()
    private let dependencies: AppStateDependencies

    convenience init(
        modelContext: ModelContext,
        localProfileOverrides: AppStateLocalProfileOverrides = .init(),
        apiClient: APIClient? = nil,
        networkMonitor: NetworkMonitor? = nil
    ) {
        self.init(configuration: .init(
            modelContext: modelContext,
            localProfileOverrides: localProfileOverrides,
            apiClient: apiClient,
            networkMonitor: networkMonitor
        ))
    }

    private init(configuration: AppStateConfiguration) {
        let dependencies = AppStateDependencies(configuration: configuration)
        self.apiClient = dependencies.apiClient
        self.authManager = dependencies.authManager
        self.syncManager = dependencies.syncManager
        self.networkMonitor = dependencies.networkMonitor
        self.dependencies = dependencies
    }

    func activateLocalProfile(userId: String) throws -> Bool {
        try makeLocalProfileLifecycle().activate(userId: userId)
    }

    /// Cancels sync and erases the prior owner's local records before establishing a new owner.
    func replaceLocalProfile(with userId: String) async throws {
        try await makeLocalProfileLifecycle().replace(with: userId)
    }

    /// Performs the destructive sign-out path after in-flight sync work has been quiesced.
    func signOutAndDeleteLocalData() async {
        do {
            try await makeLocalProfileLifecycle().signOutAndDeleteLocalData()
        } catch {
            errorReporter.report(error)
        }
    }

    private func makeLocalProfileLifecycle() -> AppStateLocalProfileLifecycle {
        dependencies.makeLocalProfileLifecycle(syncManager: syncManager)
    }
}
