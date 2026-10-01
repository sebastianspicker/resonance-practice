import Foundation

// Parses the supported, deliberately small iCalendar event subset used by calendar subscriptions.
/// A normalized event emitted only for valid VEVENT records in the supported iCalendar subset.
struct ICalEvent {
    let id: String
    let summary: String
    let startDate: Date
    let endDate: Date
    let location: String?
}

/// Keeps subscription parsing intentionally narrow and rejects malformed or unsupported event data.
enum ICalParser {
    /// Extracts valid VEVENT records without attempting to implement the full iCalendar specification.
    static func parse(_ raw: String) -> [ICalEvent] {
        let lines = unfoldLines(raw)
        var events: [ICalEvent] = []
        var current: [String: String] = [:]
        var inEvent = false

        for line in lines {
            if line == "BEGIN:VEVENT" {
                inEvent = true
                current = [:]
                continue
            }
            if line == "END:VEVENT" {
                if let summary = current["SUMMARY"],
                   let dtStart = current["DTSTART"],
                   let dtEnd = current["DTEND"],
                   let startDate = parseDate(dtStart, tzid: current["DTSTART_TZID"]),
                   let endDate = parseDate(dtEnd, tzid: current["DTEND_TZID"]) {
                    let uid = current["UID"] ?? UUID().uuidString
                    let location = current["LOCATION"]
                    events.append(ICalEvent(id: uid, summary: summary, startDate: startDate, endDate: endDate, location: location))
                }
                inEvent = false
                continue
            }
            if inEvent {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    let params = parts[0].split(separator: ";").map(String.init)
                    let key = params.first ?? parts[0]
                    current[key] = parts[1]
                    // Extract TZID parameter if present (e.g. DTSTART;TZID=America/New_York)
                    for param in params.dropFirst() where param.hasPrefix("TZID=") {
                        current[key + "_TZID"] = String(param.dropFirst(5))
                    }
                }
            }
        }

        return events
    }

    private static func unfoldLines(_ raw: String) -> [String] {
        // Normalize line endings: CRLF and bare CR to LF
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var result: [String] = []
        var buffer = ""
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.first == " " || line.first == "\t" {
                buffer += line.dropFirst()
            } else {
                if !buffer.isEmpty {
                    result.append(buffer)
                }
                buffer = String(line)
            }
        }
        if !buffer.isEmpty {
            result.append(buffer)
        }
        return result
    }

    // DateFormatter is expensive to construct; reuse static instances across all parse calls.
    private static let utcDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let allDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static let floatingDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static func parseDate(_ value: String, tzid: String? = nil) -> Date? {
        if value.hasSuffix("Z") {
            // UTC datetime, for example "20250301T120000Z": parse as UTC, not local time.
            return utcDateTimeFormatter.date(from: String(value.dropLast()))
        }
        if value.count == 8 {
            // All-day date, for example "20250301": use local timezone (no clock time).
            return allDayFormatter.date(from: value)
        }
        if value.count >= 15 {
            let dateString = String(value.prefix(15))
            // If a TZID parameter was provided, parse in that timezone.
            if let tzid, let timeZone = TimeZone(identifier: tzid) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd'T'HHmmss"
                formatter.timeZone = timeZone
                return formatter.date(from: dateString)
            }
            // Floating datetime (no timezone indicator): treat as local.
            return floatingDateTimeFormatter.date(from: dateString)
        }
        return nil
    }
}
