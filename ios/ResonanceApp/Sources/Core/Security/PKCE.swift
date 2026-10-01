import CryptoKit
import Foundation
import Security

enum PKCEError: LocalizedError {
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .randomGenerationFailed(status):
            "Could not generate secure sign-in state (OSStatus \(status))."
        }
    }
}

/// Native-app PKCE using an entropy source provided by the operating system.
enum PKCE {
    static func makeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw PKCEError.randomGenerationFailed(status) }
        return Data(bytes).base64URLEncodedString()
    }

    static func s256Challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
