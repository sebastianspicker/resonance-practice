import Foundation
import os
import SwiftData

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "CalendarService")

enum CalendarError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse(Int)
    case invalidCalendarData

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid calendar URL scheme"
        case .invalidResponse(let statusCode): return "Calendar server returned HTTP \(statusCode)"
        case .invalidCalendarData: return "Calendar feed could not be parsed"
        }
    }
}

@MainActor
final class CalendarService: ObservableObject {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func refresh(from url: URL, modelContext: ModelContext) async throws {
        guard Self.isAllowedCalendarURL(url) else {
            throw CalendarError.invalidURL
        }

        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalendarError.invalidResponse(-1)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CalendarError.invalidResponse(httpResponse.statusCode)
        }

        guard let raw = String(data: data, encoding: .utf8) else {
            logger.warning("Calendar data from \(url.absoluteString) could not be decoded as UTF-8")
            throw CalendarError.invalidCalendarData
        }

        guard raw.contains("BEGIN:VCALENDAR"), raw.contains("END:VCALENDAR") else {
            throw CalendarError.invalidCalendarData
        }

        let records = ICalParser.parse(raw).map {
            CalendarEvent(
                id: $0.id,
                summary: $0.summary,
                startDate: $0.startDate,
                endDate: $0.endDate,
                location: $0.location
            )
        }

        let descriptor = FetchDescriptor<CalendarEvent>()
        let existing = try modelContext.fetch(descriptor)
        existing.forEach { modelContext.delete($0) }
        records.forEach { modelContext.insert($0) }
        try modelContext.save()
    }

    private static func isAllowedCalendarURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        if scheme == "https" {
            return true
        }

        guard scheme == "http", let host = url.host?.lowercased() else {
            return false
        }

        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
