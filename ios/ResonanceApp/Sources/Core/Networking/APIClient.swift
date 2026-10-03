import Foundation

/// Shared authenticated API transport whose endpoint groups use the same URL session.
@MainActor
final class APIClient {
  static let defaultMaxResponseBytes = 8 * 1024 * 1024

  let session: URLSession
  let maxResponseBytes: Int

  init(session: URLSession = .shared, maxResponseBytes: Int = APIClient.defaultMaxResponseBytes) {
    precondition(maxResponseBytes > 0)
    self.session = session
    self.maxResponseBytes = maxResponseBytes
  }
}
