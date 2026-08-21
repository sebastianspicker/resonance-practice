import Foundation
import SwiftData

// Provides the dependencies shared by command construction and async execution.

@MainActor
final class TaskExecutor {
    let apiClient: APIClient
    let store: QueueStore
    let session: URLSession

    init(apiClient: APIClient, store: QueueStore, session: URLSession) {
        self.apiClient = apiClient
        self.store = store
        self.session = session
    }
}
