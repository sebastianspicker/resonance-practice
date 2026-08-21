import Foundation

enum DemoDataFixtureLoader {
    static func load() throws -> DemoFixture {
        guard let url = Bundle.main.url(forResource: "mock-university", withExtension: "json") else {
            throw DemoDataError.fixtureNotFound
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = fractional.date(from: value) { return date }
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        return try decoder.decode(DemoFixture.self, from: data)
    }
}

enum DemoDataError: LocalizedError {
    case fixtureNotFound

    var errorDescription: String? {
        switch self {
        case .fixtureNotFound:
            return "mock-university.json not found in app bundle."
        }
    }
}

struct DemoFixture: Decodable {
    let users: [DemoUser]
    let courses: [DemoCourse]
    let memberships: [DemoMembership]
    let entries: [DemoEntry]
    let artifacts: [DemoArtifact]
    let feedback: [DemoFeedback]
    let syncQueue: [DemoQueueItem]?
}

struct DemoUser: Decodable {
    let id: String
    let displayName: String
}

struct DemoCourse: Decodable {
    let id: String
    let title: String
}

struct DemoMembership: Decodable {
    let userId: String
    let courseId: String
    let roleInCourse: String
}

struct DemoEntry: Decodable {
    let id: String
    let courseId: String
    let studentId: String
    let createdAt: Date
    let practiceDate: Date
    let goalText: String
    let durationSeconds: Int?
    let tags: [String]
    let notes: String?
    let status: String
    let kind: String?
    let consentConfirmedAt: Date?
    let consentScope: String?
    let captureProfile: String?
}

struct DemoArtifact: Decodable {
    let id: String
    let entryId: String
    let type: String
    let durationSeconds: Int
    let createdAt: Date
    let uploadState: String
    let syncPhase: String
    let storageKey: String?
    let remoteUrl: String?
    let localPath: String
}

struct DemoFeedback: Decodable {
    let id: String
    let targetType: String
    let targetId: String
    let teacherId: String
    let createdAt: Date
    let status: String
    let commentsText: String
    let markers: [DemoMarker]
}

struct DemoMarker: Decodable {
    let id: String
    let timeSeconds: Int
    let text: String
}

struct DemoQueueItem: Decodable {
    let id: String
    let type: String
    let status: String
    let retryCount: Int
    let lastError: String?
    let createdAt: Date
    let nextAttemptAt: Date?
    let payload: [String: String]
}
