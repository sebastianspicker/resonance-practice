import CryptoKit
import Foundation

/// Computes the upload contract checksum without buffering an entire recording in memory.
enum MediaChecksum {
    static let chunkSize = 64 * 1024

    struct FilePreparation: Sendable {
        let sizeBytes: Int
        let checksumSha256: String
    }

    /// Reads file metadata and hashes on a utility-priority task so preparing an
    /// upload does not hold the main actor while walking a recording.
    static func prepare(for fileURL: URL) async throws -> FilePreparation {
        let work = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw CocoaError(.fileReadUnknown)
            }
            return FilePreparation(
                sizeBytes: size.intValue,
                checksumSha256: try sha256Base64(for: fileURL)
            )
        }
        return try await withTaskCancellationHandler(
            operation: { try await work.value },
            onCancel: { work.cancel() }
        )
    }

    static func sha256Base64(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).base64EncodedString()
    }
}
