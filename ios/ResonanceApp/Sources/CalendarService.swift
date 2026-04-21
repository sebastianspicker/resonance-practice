import Foundation
import os
import SwiftData

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "CalendarService")

enum CalendarError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid calendar URL scheme"
        }
    }
}

@MainActor
final class CalendarService: ObservableObject {
    func refresh(from url: URL, modelContext: ModelContext) async {
        do {
            guard url.scheme == "https" || url.scheme == "http" else {
                throw CalendarError.invalidURL
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let raw = String(data: data, encoding: .utf8) else {
                logger.warning("Calendar data from \(url.absoluteString) could not be decoded as UTF-8")
                return
            }
            let events = ICalParser.parse(raw)

            let descriptor = FetchDescriptor<CalendarEvent>()
            let existing = try modelContext.fetch(descriptor)
            existing.forEach { modelContext.delete($0) }

            for event in events {
                let record = CalendarEvent(id: event.id, summary: event.summary, startDate: event.startDate, endDate: event.endDate, location: event.location)
                modelContext.insert(record)
            }
            try modelContext.save()
        } catch {
            logger.error("Calendar refresh failed: \(error.localizedDescription)")
        }
    }
}
