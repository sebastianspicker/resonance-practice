import Foundation

// Provides request construction, HTTP validation, and Codable transport shared by API endpoints.

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
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    if http.statusCode >= 400 {
      if let apiError = try? JSONDecoder.apiDecoder.decode(APIError.self, from: data) {
        throw apiError
      }
      throw URLError(.badServerResponse)
    }
    return (data, http)
  }

  func sendNoContent(url: URL, method: String, accessToken: String?) async throws {
    let request = makeRequest(url: url, method: method, accessToken: accessToken)
    guard try await performResponse(request).response.statusCode == 204 else {
      throw URLError(.badServerResponse)
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
