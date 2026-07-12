import Foundation

final class APIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func exchangeCodeForTokens(code: String) async throws -> AuthSession {
        let url = AppConfig.apiBaseURL.appendingPathComponent("auth/session")
        let body: [String: String] = [
            "code": code,
            "redirectUri": AppConfig.authCallbackURL.absoluteString
        ]
        let response: TokenResponse = try await send(url: url, method: "POST", body: body, accessToken: nil)
        guard let user = response.user else {
            throw URLError(.badServerResponse)
        }
        return AuthSession(accessToken: response.accessToken, refreshToken: response.refreshToken, userId: user.id, displayName: user.displayName, globalRole: user.globalRole)
    }

    func issueDevCode(role: String, userId: String? = nil) async throws -> String {
        let url = AppConfig.apiBaseURL.appendingPathComponent("dev/issue")
        struct Body: Encodable {
            let role: String
            let userId: String?
        }
        struct Response: Decodable {
            let code: String
        }
        let response: Response = try await send(
            url: url,
            method: "POST",
            body: Body(role: role, userId: userId),
            accessToken: nil
        )
        return response.code
    }

    func refreshTokens(refreshToken: String) async throws -> (accessToken: String, refreshToken: String) {
        let url = AppConfig.apiBaseURL.appendingPathComponent("auth/refresh")
        let body = ["refreshToken": refreshToken]
        let response: TokenResponse = try await send(url: url, method: "POST", body: body, accessToken: nil)
        return (response.accessToken, response.refreshToken)
    }

    func logout(accessToken: String) async throws {
        let url = AppConfig.apiBaseURL.appendingPathComponent("auth/logout")
        struct LogoutResponse: Decodable {
            let success: Bool
        }
        let _: LogoutResponse = try await send(url: url, method: "POST", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    func revokeRefreshToken(_ refreshToken: String) async throws {
        let url = AppConfig.apiBaseURL.appendingPathComponent("auth/logout")
        struct Body: Encodable { let refreshToken: String }
        struct LogoutResponse: Decodable { let success: Bool }
        let _: LogoutResponse = try await send(url: url, method: "POST", body: Body(refreshToken: refreshToken), accessToken: nil)
    }

    func fetchCourses(accessToken: String) async throws -> [CourseResponse] {
        let url = AppConfig.apiBaseURL.appendingPathComponent("courses")
        return try await send(url: url, method: "GET", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    func fetchEntries(accessToken: String, courseId: String, limit: Int = 50, cursor: String? = nil) async throws -> PaginatedResponse<EntryResponse> {
        var components = URLComponents(url: AppConfig.apiBaseURL.appendingPathComponent("courses/\(courseId)/entries"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items
        return try await send(url: components.url!, method: "GET", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    func fetchEntry(accessToken: String, entryId: String) async throws -> EntryResponse {
        let url = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)")
        return try await send(url: url, method: "GET", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    func createEntry(accessToken: String, courseId: String, entry: LocalPracticeEntry) async throws -> EntryResponse {
        let url = AppConfig.apiBaseURL.appendingPathComponent("courses/\(courseId)/entries")
        struct Body: Encodable {
            let id: String
            let kind: String
            let practiceDate: Date
            let goalText: String
            let durationSeconds: Int?
            let tags: [String]
            let notes: String?
            let consentConfirmed: Bool?
            let consentScope: String?
            let captureProfile: String?
        }
        let body = Body(
            id: entry.id,
            kind: entry.kind.rawValue,
            practiceDate: entry.practiceDate,
            goalText: entry.goalText,
            durationSeconds: entry.durationSeconds,
            tags: entry.tags,
            notes: entry.notes,
            consentConfirmed: entry.consentConfirmedAt == nil ? nil : true,
            consentScope: entry.consentScope?.rawValue,
            captureProfile: entry.captureProfile?.rawValue
        )
        return try await send(url: url, method: "POST", body: body, accessToken: accessToken)
    }

    func updateEntryCaptureProfile(accessToken: String, entryId: String, captureProfile: CaptureProfile?) async throws -> EntryResponse {
        let url = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)")
        struct Body: Encodable {
            let captureProfile: String?
        }
        return try await send(
            url: url,
            method: "PATCH",
            body: Body(captureProfile: captureProfile?.rawValue),
            accessToken: accessToken
        )
    }

    func updateEntry(accessToken: String, entry: LocalPracticeEntry) async throws -> EntryResponse {
        let url = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entry.id)")
        struct Body: Encodable {
            let kind: String
            let practiceDate: Date
            let goalText: String
            let durationSeconds: Int?
            let tags: [String]
            let notes: String?
            let consentConfirmed: Bool
            let consentScope: String?
            let captureProfile: String?
        }
        let body = Body(
            kind: entry.kind.rawValue,
            practiceDate: entry.practiceDate,
            goalText: entry.goalText,
            durationSeconds: entry.durationSeconds,
            tags: entry.tags,
            notes: entry.notes,
            consentConfirmed: entry.consentConfirmedAt != nil,
            consentScope: entry.consentScope?.rawValue,
            captureProfile: entry.captureProfile?.rawValue
        )
        return try await send(url: url, method: "PATCH", body: body, accessToken: accessToken)
    }

    func createArtifact(accessToken: String, entryId: String, artifact: LocalArtifact) async throws -> ArtifactResponse {
        let url = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)/artifacts")
        struct Body: Encodable {
            let id: String
            let type: String
            let durationSeconds: Int
        }
        let body = Body(
            id: artifact.id,
            type: artifact.type.rawValue,
            durationSeconds: artifact.durationSeconds
        )
        return try await send(url: url, method: "POST", body: body, accessToken: accessToken)
    }

    func presignArtifact(accessToken: String, artifactId: String) async throws -> PresignResponse {
        let url = AppConfig.apiBaseURL.appendingPathComponent("artifacts/\(artifactId)/presign")
        return try await send(url: url, method: "POST", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    func confirmArtifact(accessToken: String, artifactId: String) async throws -> ArtifactResponse {
        let url = AppConfig.apiBaseURL.appendingPathComponent("artifacts/\(artifactId)/confirm")
        return try await send(url: url, method: "POST", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    func fetchArtifactDownloadURL(accessToken: String, artifactId: String) async throws -> ArtifactDownloadResponse {
        let url = AppConfig.apiBaseURL.appendingPathComponent("artifacts/\(artifactId)/download")
        return try await send(url: url, method: "GET", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    func submitEntry(accessToken: String, entryId: String) async throws -> EntryResponse {
        let url = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)/submit")
        return try await send(url: url, method: "POST", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    func syncCaptureMarkers(accessToken: String, entryId: String, markers: [LocalCaptureMarker]) async throws -> [CaptureMarkerResponse] {
        let url = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)/capture-markers")
        struct MarkerBody: Encodable {
            let id: String
            let artifactId: String
            let timeSeconds: Int
            let kind: String
            let note: String?
        }
        struct Body: Encodable {
            let markers: [MarkerBody]
        }
        let body = Body(
            markers: markers.map {
                MarkerBody(
                    id: $0.id,
                    artifactId: $0.artifactId,
                    timeSeconds: $0.timeSeconds,
                    kind: $0.kind.rawValue,
                    note: $0.note
                )
            }
        )
        return try await send(url: url, method: "PUT", body: body, accessToken: accessToken)
    }

    func deleteEntry(accessToken: String, entryId: String) async throws {
        let url = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)")
        try await sendNoContent(url: url, method: "DELETE", accessToken: accessToken)
    }

    /// Fetch the teacher review queue using the API's cursor-paginated envelope.
    func fetchReviewQueue(accessToken: String, courseId: String, limit: Int? = nil, cursor: String? = nil) async throws -> PaginatedResponse<ReviewQueueEntry> {
        var components = URLComponents(url: AppConfig.apiBaseURL.appendingPathComponent("courses/\(courseId)/review-queue"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let limit { queryItems.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let cursor { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        let url = components.url!
        return try await send(url: url, method: "GET", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    func createFeedback(accessToken: String, submission: FeedbackSubmission) async throws -> FeedbackResponse {
        let url = AppConfig.apiBaseURL.appendingPathComponent("feedback")
        struct MarkerBody: Encodable {
            let timeSeconds: Int
            let text: String
        }
        struct Body: Encodable {
            let id: String?
            let targetType: String
            let targetId: String
            let status: String
            let commentsText: String
            let markers: [MarkerBody]
        }
        let body = Body(
            id: submission.feedbackId,
            targetType: submission.targetType,
            targetId: submission.targetId,
            status: submission.status.rawValue,
            commentsText: submission.commentsText,
            markers: submission.markers.map { MarkerBody(timeSeconds: $0.timeSeconds, text: $0.text) }
        )
        return try await send(url: url, method: "POST", body: body, accessToken: accessToken)
    }

    func fetchFeedback(accessToken: String, entryId: String) async throws -> [FeedbackResponse] {
        let url = AppConfig.apiBaseURL.appendingPathComponent("entries/\(entryId)/feedback")
        return try await send(url: url, method: "GET", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    private struct EmptyBody: Encodable {}

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode >= 400 {
            if let apiError = try? JSONDecoder.apiDecoder.decode(APIError.self, from: data) {
                throw apiError
            }
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func sendNoContent(url: URL, method: String, accessToken: String?) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if httpResponse.statusCode == 204 {
            return
        }
        if httpResponse.statusCode >= 400 {
            if let apiError = try? JSONDecoder.apiDecoder.decode(APIError.self, from: data) {
                throw apiError
            }
            throw URLError(.badServerResponse)
        }
    }

    private func send<Response: Decodable, Body: Encodable>(url: URL, method: String, body: Body?, accessToken: String?) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let body = body {
            request.httpBody = try JSONEncoder.apiEncoder.encode(body)
        }
        let data = try await perform(request)
        return try JSONDecoder.apiDecoder.decode(Response.self, from: data)
    }
}

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
}

extension JSONDecoder {
    static let apiDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Hoist formatters outside the closure so they are created once, not on every decode call.
        let formatterWithFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let formatterWithoutFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f
        }()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            if let date = formatterWithFractional.date(from: dateString) {
                return date
            }
            if let date = formatterWithoutFractional.date(from: dateString) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
        return decoder
    }()
}

extension Date {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    var iso8601String: String {
        Date.iso8601Formatter.string(from: self)
    }
}
