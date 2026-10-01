import Foundation

// Centralizes validated runtime endpoints and security identity for Core services.
enum ServiceConfiguration {
    private static let defaultAPIBaseURL = URL(string: "http://localhost:4000")!
    static let apiBaseURL = resolveAPIBaseURL(
        ProcessInfo.processInfo.environment["RESONANCE_API_BASE"]
    )

    /// Accepts a credential-free HTTP(S) origin/path or falls back to the loopback API.
    static func resolveAPIBaseURL(_ value: String?) -> URL {
        guard let value, !value.isEmpty,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return defaultAPIBaseURL
        }
        return url
    }

    static let authCallbackScheme = "resonance"
    static let authCallbackURL = URL(string: "resonance://auth-callback")!

    static func authLoginURL(codeChallenge: String) -> URL {
        var components = URLComponents(url: apiBaseURL.appendingPathComponent("auth/login"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "app_code_challenge", value: codeChallenge)]
        return components?.url ?? apiBaseURL.appendingPathComponent("auth/login")
    }

    static func isExpectedAuthCallback(_ url: URL) -> Bool {
        let expected = authCallbackURL
        return url.scheme?.lowercased() == expected.scheme?.lowercased()
            && url.host?.lowercased() == expected.host?.lowercased()
            && url.port == expected.port
            && url.path == expected.path
            && url.user == nil
            && url.password == nil
    }

    /// Server API routes are versioned at an absolute path. Do not append this
    /// to a configurable base URL because a base such as `/tenant/` would
    /// otherwise produce a different endpoint.
    static func apiV1URL(path: String) -> URL {
        guard var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            return apiBaseURL
        }
        components.path = "/api/v1/\(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))"
        return components.url ?? apiBaseURL
    }
    static let keychainNamespace: String = {
        let base = apiBaseURL.absoluteString.lowercased()
        let sanitized = base
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "resonance-default" : "resonance-\(sanitized)"
    }()
}
