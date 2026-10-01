import SwiftUI

// Declares the shared services and presentation flags that App injects into feature views.

/// Collects user-facing errors from feature workflows for the app's root alert.
@MainActor
final class ErrorReporter: ObservableObject {
    @Published var lastErrorMessage: String?
    @Published var showErrorAlert: Bool = false

    func report(_ error: Error) {
        if let apiError = error as? APIError {
            lastErrorMessage = apiError.error.message
        } else {
            lastErrorMessage = error.localizedDescription
        }
        showErrorAlert = true
    }

    func clear() {
        lastErrorMessage = nil
        showErrorAlert = false
    }
}

private enum APIClientKey: EnvironmentKey {
    // SwiftUI reads environment values on the main actor; App injects its shared client.
    static var defaultValue: APIClient { MainActor.assumeIsolated { APIClient() } }
}

private enum CapturePresentationKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var apiClient: APIClient {
        get { self[APIClientKey.self] }
        set { self[APIClientKey.self] = newValue }
    }

    /// True only while App renders a deterministic capture scenario with fixed local content.
    var capturePresentation: Bool {
        get { self[CapturePresentationKey.self] }
        set { self[CapturePresentationKey.self] = newValue }
    }
}
