import Foundation
import SwiftData

@MainActor
final class AppState: ObservableObject {
    let apiClient: APIClient
    let authManager: AuthManager
    let syncManager: SyncManager
    let networkMonitor: NetworkMonitor

    @Published var lastErrorMessage: String?
    @Published var showErrorAlert: Bool = false

    init(modelContext: ModelContext) {
        let client = APIClient()
        self.apiClient = client
        let auth = AuthManager(apiClient: client)
        self.authManager = auth
        let net = NetworkMonitor()
        self.networkMonitor = net
        self.syncManager = SyncManager(modelContext: modelContext, authManager: auth, apiClient: client, networkMonitor: net)
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
