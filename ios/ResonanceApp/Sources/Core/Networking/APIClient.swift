import Foundation

/// Shared authenticated API transport whose endpoint groups use the same URL session.
@MainActor
final class APIClient {
  let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }
}
