import Foundation

/// Shared authenticated API transport whose endpoint groups use the same URL session.
@MainActor
final class APIClient {
  let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }
}

/// Feedback payload whose optional local ID becomes the server idempotency key.
struct FeedbackSubmission {
  let feedbackId: String?
  let targetType: String
  let targetId: String
  let status: FeedbackStatus
  let commentsText: String
  let markers: [LocalMarker]
}

extension JSONEncoder {
  static let apiEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  static func apiEncoderDateString(_ date: Date) -> String {
    let encoder = JSONEncoder.apiEncoder
    guard let json = try? encoder.encode(date),
      let value = String(data: json, encoding: .utf8)
    else { return "" }
    return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  }
}

extension JSONDecoder {
  static let apiDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let dateString = try container.decode(String.self)
      let formatterWithFractional = ISO8601DateFormatter()
      formatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatterWithFractional.date(from: dateString) { return date }
      let formatterWithoutFractional = ISO8601DateFormatter()
      formatterWithoutFractional.formatOptions = [.withInternetDateTime]
      if let date = formatterWithoutFractional.date(from: dateString) { return date }
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Cannot decode date: \(dateString)")
    }
    return decoder
  }()
}

extension Date {
  var iso8601String: String {
    ISO8601DateFormatter().string(from: self)
  }
}
