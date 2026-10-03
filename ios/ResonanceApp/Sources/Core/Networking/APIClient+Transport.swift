import Foundation

func smallerPageLimit(after attemptedLimit: Int?) -> Int? {
  let attemptedLimit = attemptedLimit ?? 50
  return attemptedLimit > 1 ? max(1, attemptedLimit / 2) : nil
}

extension APIClient {
  struct EmptyBody: Encodable {}

  func makeURL(_ url: URL, queryItems: [URLQueryItem]) throws -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw URLError(.badURL)
    }
    if !queryItems.isEmpty { components.queryItems = queryItems }
    guard let url = components.url else { throw URLError(.badURL) }
    return url
  }

  /// Executes a request and converts all HTTP failures into typed API or transport errors.
  func perform(_ request: URLRequest) async throws -> Data {
    try await performResponse(request).data
  }

  private func performResponse(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    if http.expectedContentLength > maxResponseBytes {
      bytes.task.cancel()
      throw URLError(.dataLengthExceedsMaximum)
    }

    var data = Data()
    if http.expectedContentLength > 0 {
      data.reserveCapacity(min(Int(http.expectedContentLength), maxResponseBytes))
    }
    for try await byte in bytes {
      if data.count == maxResponseBytes {
        bytes.task.cancel()
        throw URLError(.dataLengthExceedsMaximum)
      }
      data.append(byte)
    }

    if http.statusCode >= 400 {
      if let apiError = try? JSONDecoder.apiDecoder.decode(APIError.self, from: data) {
        throw apiError
      }
      throw URLError(.badServerResponse)
    }
    return (data, http)
  }

  func sendPage<Response: Decodable>(
    accessToken: String,
    path: String,
    limit requestedLimit: Int?,
    cursor: String?
  ) async throws -> PaginatedResponse<Response> {
    var limit = requestedLimit
    while true {
      var queryItems: [URLQueryItem] = []
      if let limit { queryItems.append(URLQueryItem(name: "limit", value: String(limit))) }
      if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
      let url = try makeURL(ServiceConfiguration.apiV1URL(path: path), queryItems: queryItems)
      do {
        return try await send(
          url: url, method: "GET", body: Optional<EmptyBody>.none, accessToken: accessToken)
      } catch let error as URLError where error.code == .dataLengthExceedsMaximum {
        guard let retryLimit = smallerPageLimit(after: limit) else { throw error }
        limit = retryLimit
      }
    }
  }

  func send<Response: Decodable, Body: Encodable>(
    url: URL,
    method: String,
    body: Body?,
    accessToken: String?
  ) async throws -> Response {
    var request = makeRequest(url: url, method: method, accessToken: accessToken)
    if let body { request.httpBody = try JSONEncoder.apiEncoder.encode(body) }
    return try JSONDecoder.apiDecoder.decode(Response.self, from: try await perform(request))
  }

  private func makeRequest(url: URL, method: String, accessToken: String?) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let accessToken {
      request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    }
    if method != "GET" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    return request
  }
}
