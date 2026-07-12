import Foundation
import SwiftData

@MainActor
final class AppState: ObservableObject {
    let apiClient: APIClient
    let authManager: AuthManager
    let syncManager: SyncManager
    let networkMonitor: NetworkMonitor
    private let modelContext: ModelContext

    @Published var lastErrorMessage: String?
    @Published var showErrorAlert: Bool = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        let client = APIClient()
        self.apiClient = client
        let auth = AuthManager(apiClient: client)
        self.authManager = auth
        let net = NetworkMonitor()
        self.networkMonitor = net
        self.syncManager = SyncManager(modelContext: modelContext, authManager: auth, apiClient: client, networkMonitor: net)
    }

    func activateLocalProfile(userId: String) -> Bool {
        let ownerKey = "localDataOwnerId"
        if let previousOwner = KeychainStore.get(ownerKey), previousOwner != userId {
            return false
        }
        KeychainStore.set(userId, for: ownerKey)
        return true
    }

    func replaceLocalProfile(with userId: String) {
        purgeLocalUserData()
        KeychainStore.set(userId, for: "localDataOwnerId")
    }

    func signOutAndDeleteLocalData() {
        purgeLocalUserData()
        KeychainStore.remove("localDataOwnerId")
        authManager.signOut()
    }

    private func purgeLocalUserData() {
        let artifacts = (try? modelContext.fetch(FetchDescriptor<LocalArtifact>())) ?? []
        for artifact in artifacts where !artifact.localPath.isEmpty {
            FileStore.deleteFileIfExists(atPath: artifact.localPath)
        }
        deleteAll(CalendarEvent.self)
        deleteAll(SyncQueueItem.self)
        deleteAll(LocalCaptureMarker.self)
        deleteAll(LocalMarker.self)
        deleteAll(LocalFeedback.self)
        deleteAll(LocalArtifact.self)
        deleteAll(LocalPracticeEntry.self)
        deleteAll(LocalCourse.self)
        CalendarSubscriptionStore.save("")
        try? modelContext.save()
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type) {
        guard let models = try? modelContext.fetch(FetchDescriptor<T>()) else { return }
        for model in models { modelContext.delete(model) }
    }

    func reportError(_ error: Error) {
        if let apiError = error as? APIError {
            lastErrorMessage = apiError.error.message
        } else {
            lastErrorMessage = error.localizedDescription
        }
        showErrorAlert = true
    }

    func clearError() {
        lastErrorMessage = nil
        showErrorAlert = false
    }
}
