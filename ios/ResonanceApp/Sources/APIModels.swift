import Foundation

struct APIError: Error, Decodable {
    let error: APIErrorBody

    struct APIErrorBody: Decodable {
        let code: String
        let message: String
        let details: [String: String]?
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

struct EntryResponse: Decodable {
    let id: String
    let courseId: String
    let studentId: String
    let practiceDate: Date
    let goalText: String
    let durationSeconds: Int?
    let tags: [String]
    let notes: String?
    let status: String
}

/// Generic paginated response envelope returned by cursor-based pagination endpoints.
/// BREAKING CHANGE (v0.2): The review-queue endpoint now returns `{ items, nextCursor }`
/// instead of a bare array.
struct PaginatedResponse<T: Decodable>: Decodable {
    let items: [T]
    let nextCursor: String?
}

struct ReviewQueueEntry: Decodable {
    let id: String
    let courseId: String
    let studentId: String
    let studentName: String
    let practiceDate: Date
    let goalText: String
    let notes: String?
    let artifacts: [ArtifactResponse]
}

struct ArtifactResponse: Decodable {
    let id: String
    let entryId: String
    let type: String
    let durationSeconds: Int
    let uploadState: String
    let storageKey: String?
    let remoteUrl: String?
}

struct PresignResponse: Decodable {
    let uploadUrl: String
    let storageKey: String
    let expiresInSeconds: Int
    let requiredHeaders: [String: String]?
}

struct FeedbackResponse: Decodable {
    let id: String
    let targetType: String
    let targetId: String
    let teacherName: String
    let createdAt: Date
    let status: String
    let commentsText: String
    let markers: [MarkerResponse]
}

struct MarkerResponse: Decodable {
    let id: String
    let timeSeconds: Int
    let text: String
}
