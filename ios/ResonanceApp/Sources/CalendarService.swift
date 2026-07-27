import Foundation
import os
import SwiftData

// Downloads validated calendar subscriptions and replaces their locally derived events.

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "CalendarService")

enum CalendarError: LocalizedError, Equatable {
    case invalidURL
    case invalidResponse(Int)
    case invalidCalendarData
    case calendarDataTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid calendar URL scheme"
        case .invalidResponse(let statusCode): return "Calendar server returned HTTP \(statusCode)"
        case .invalidCalendarData: return "Calendar feed could not be parsed"
        case .calendarDataTooLarge: return "Calendar feed is too large"
        }
    }
}

@MainActor
final class CalendarService: ObservableObject {
    private static let maxCalendarBytes = 1_048_576
    private static let maxCalendarEvents = 1_000
    private static let maxCalendarLineLength = 10_000
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Replaces derived calendar events only after the remote feed passes all size and format checks.
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
        guard data.count <= Self.maxCalendarBytes else {
            throw CalendarError.calendarDataTooLarge
        }

        guard let raw = String(data: data, encoding: .utf8) else {
            logger.warning("Calendar data from \(url.absoluteString) could not be decoded as UTF-8")
            throw CalendarError.invalidCalendarData
        }
        guard Self.isWithinCalendarBounds(raw) else {
            throw CalendarError.calendarDataTooLarge
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

    private static func isWithinCalendarBounds(_ raw: String) -> Bool {
        var eventCount = 0
        for line in raw.split(whereSeparator: \.isNewline) {
            if line.count > maxCalendarLineLength {
                return false
            }
            if line == "BEGIN:VEVENT" {
                eventCount += 1
                if eventCount > maxCalendarEvents {
                    return false
                }
            }
        }
        return true
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
