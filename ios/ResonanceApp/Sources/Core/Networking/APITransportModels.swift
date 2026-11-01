import Foundation

/// Typed server error envelope used instead of exposing arbitrary response bodies.
struct APIError: Error, Decodable {
    let error: APIErrorBody

    struct APIErrorBody: Decodable {
        let code: String
        let message: String
        let details: [String: JSONValue]?
        let requestId: String?
        let currentVersion: Int?

        init(
            code: String,
            message: String,
            details: [String: JSONValue]? = nil,
            requestId: String? = nil,
            currentVersion: Int? = nil
        ) {
            self.code = code
            self.message = message
            self.details = details
            self.requestId = requestId
            self.currentVersion = currentVersion
        }
    }
}

/// Shows the server's message with its code and request ID, so alerts and bug reports
/// identify the failing request instead of "ResonanceApp.APIError error 1".
extension APIError: LocalizedError {
    var errorDescription: String? {
        var reference = "Code: \(error.code)"
        if let requestId = error.requestId { reference += ", request ID: \(requestId)" }
        return "\(error.message) (\(reference))"
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let user: UserResponse?

    struct UserResponse: Decodable {
        let id: String
        let displayName: String
        let globalRole: String
    }
}

struct CourseResponse: Decodable {
    let id: String
    let title: String
    let roleInCourse: String
}

/// Generic paginated response envelope returned by cursor-based pagination endpoints.
struct PaginatedResponse<T: Decodable>: Decodable {
    let items: [T]
    let nextCursor: String?
}
