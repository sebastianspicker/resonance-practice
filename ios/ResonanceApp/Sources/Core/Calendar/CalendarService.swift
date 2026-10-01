import Foundation
import Network
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

final class CalendarRedirectPolicy: NSObject, URLSessionTaskDelegate {
    static func allowsRedirect(to url: URL) -> Bool {
        CalendarService.isAllowedCalendarURL(url)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url, Self.allowsRedirect(to: redirectURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor
final class CalendarService: ObservableObject {
    static let maxCalendarBytes = 1_048_576
    private static let maxCalendarEvents = 1_000
    private static let maxCalendarLineLength = 10_000
    private let session: URLSession
    private let redirectPolicy: CalendarRedirectPolicy?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            redirectPolicy = nil
        } else {
            let policy = CalendarRedirectPolicy()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
            redirectPolicy = policy
        }
    }

    /// Replaces derived calendar events only after the remote feed passes all size and format checks.
    func refresh(from url: URL, modelContext: ModelContext) async throws {
        guard Self.isAllowedCalendarURL(url) else {
            throw CalendarError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CalendarError.invalidResponse(-1)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CalendarError.invalidResponse(httpResponse.statusCode)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= Self.maxCalendarBytes else {
                throw CalendarError.calendarDataTooLarge
            }
        }

        guard let raw = String(data: data, encoding: .utf8) else {
            logger.warning("Calendar data from \(Self.sanitizedLocation(url), privacy: .public) could not be decoded as UTF-8")
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

    nonisolated static func isAllowedCalendarURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return false
        }

        if scheme == "https" {
            return !isPrivateOrLocalHost(host)
        }

        guard scheme == "http" else {
            return false
        }

        return host == "localhost" || isLoopbackIPAddress(host)
    }

    private nonisolated static func isPrivateOrLocalHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty else { return true }

        if normalizedHost == "localhost" || normalizedHost.hasSuffix(".local") {
            return true
        }

        if let address = IPv4Address(normalizedHost) {
            return isPrivateOrLocalIPv4(Array(address.rawValue))
        }

        if let address = IPv6Address(normalizedHost) {
            let bytes = Array(address.rawValue)
            if let mappedIPv4 = mappedIPv4Address(in: bytes) {
                return isPrivateOrLocalIPv4(mappedIPv4)
            }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            return isLoopback || isUniqueLocal || isLinkLocal
        }

        return false
    }

    private nonisolated static func isLoopbackIPAddress(_ host: String) -> Bool {
        if let address = IPv4Address(host) {
            return Array(address.rawValue).first == 127
        }
        if let address = IPv6Address(host) {
            let bytes = Array(address.rawValue)
            if let mappedIPv4 = mappedIPv4Address(in: bytes) {
                return mappedIPv4.first == 127
            }
            return bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        }
        return false
    }

    private nonisolated static func isPrivateOrLocalIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        return bytes[0] == 127
            || bytes[0] == 10
            || (bytes[0] == 172 && (16...31).contains(bytes[1]))
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 169 && bytes[1] == 254)
    }

    private nonisolated static func mappedIPv4Address(in bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == 16,
              bytes.prefix(10).allSatisfy({ $0 == 0 }),
              bytes[10] == 0xff,
              bytes[11] == 0xff else {
            return nil
        }
        return Array(bytes.suffix(4))
    }

    private static func sanitizedLocation(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = url.path
        return components.string ?? "calendar feed"
    }
}
