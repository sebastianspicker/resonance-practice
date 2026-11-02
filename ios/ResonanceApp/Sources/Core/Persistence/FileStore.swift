import Foundation
import os

// Manages protected local media files and their cleanup for practice-entry artifacts.

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "FileStore")

enum FileStore {
    private static func mediaDirectoryURL() -> URL {
        if let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent("Media", isDirectory: true)
        }
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return cachesDir.appendingPathComponent("Media", isDirectory: true)
    }

    /// Dedicated folder for generated PDF exports; local-data deletion empties it.
    static func exportDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Exports", isDirectory: true)
    }

    static func mediaDirectory() -> URL {
        if FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first == nil {
            logger.fault("Documents directory unavailable; falling back to Caches directory for media storage.")
        }
        let dir = mediaDirectoryURL()
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                setFileProtection(url: dir)
            } catch {
                logger.error("Failed to create media directory at \(dir.path): \(error.localizedDescription)")
            }
        }
        return dir
    }

    static func hasStoredMediaFiles() throws -> Bool {
        try hasEntries(in: mediaDirectoryURL())
    }

    static func removeAllStoredMediaFiles() throws {
        let directory = mediaDirectoryURL()
        try removeEntries(in: directory)
        guard try !hasStoredMediaFiles() else {
            throw FileStoreError.mediaDirectoryNotEmpty(directory.path)
        }
    }

    static func hasStoredExports() throws -> Bool {
        try hasEntries(in: exportDirectoryURL())
    }

    /// Empties only the dedicated export folder; nothing outside it is touched.
    static func removeAllExports() throws {
        let directory = exportDirectoryURL()
        try removeEntries(in: directory)
        guard try !hasStoredExports() else {
            throw FileStoreError.exportDirectoryNotEmpty(directory.path)
        }
    }

    private static func hasEntries(in directory: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        return try !FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        ).isEmpty
    }

    /// Only called with the app-owned Media and Exports folders above, never with a caller-supplied path.
    private static func removeEntries(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        )
        for entry in entries {
            try FileManager.default.removeItem(at: entry)
        }
    }

    static func createAudioFileURL(entryId: String) -> URL {
        let filename = "audio_\(safeFilenameComponent(entryId))_\(UUID().uuidString).m4a"
        return mediaDirectory().appendingPathComponent(filename)
    }

    static func createVideoFileURL(entryId: String, fileExtension: String = "mp4") -> URL {
        let safeExtension = safeFilenameComponent(fileExtension).isEmpty ? "mp4" : safeFilenameComponent(fileExtension)
        let filename = "video_\(safeFilenameComponent(entryId))_\(UUID().uuidString).\(safeExtension)"
        return mediaDirectory().appendingPathComponent(filename)
    }

    static func setFileProtection(url: URL) {
        // Guard against applying attributes to a path that does not yet exist on disk.
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.warning("Skipping file protection for non-existent path: \(url.path)")
            return
        }

        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var urlCopy = url
            try urlCopy.setResourceValues(values)

            let attributes: [FileAttributeKey: Any] = [
                .protectionKey: FileProtectionType.complete
            ]
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        } catch {
            logger.error("Failed to set data protection for \(url.path): \(error.localizedDescription)")
        }
    }

    static func removeFileIfExists(atPath path: String) throws {
        let url = try containedMediaURL(atPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try FileManager.default.removeItem(at: url)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FileStoreError.fileStillExists(url.path)
        }
    }

    /// Returns a canonical file URL only when it remains beneath the app-owned media root.
    static func containedMediaURL(atPath path: String) throws -> URL {
        let root = mediaDirectoryURL().resolvingSymlinksInPath().standardizedFileURL
        let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw FileStoreError.pathOutsideMediaDirectory(candidate.path)
        }
        return candidate
    }

    /// Returns the current-container path for a stored absolute path that no longer resolves
    /// (the app container path changes across reinstalls/restores), or nil when no repair applies.
    static func relocatedMediaPath(forStoredPath path: String) -> String? {
        guard !path.isEmpty, (try? containedMediaURL(atPath: path)) == nil else { return nil }
        let candidate = mediaDirectoryURL().appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        guard let contained = try? containedMediaURL(atPath: candidate.path),
              FileManager.default.fileExists(atPath: contained.path) else { return nil }
        return candidate.path
    }

    /// Removes a local artifact only when it exists, keeping destructive cleanup idempotent.
    static func deleteFileIfExists(atPath path: String) {
        do {
            try removeFileIfExists(atPath: path)
        } catch {
            logger.error("Failed to delete file at \(path): \(error.localizedDescription)")
        }
    }
}

private extension FileStore {
    static func safeFilenameComponent(_ value: String) -> String {
        value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "-" }.map(String.init).joined()
    }
}

enum FileStoreError: LocalizedError {
    case fileStillExists(String)
    case mediaDirectoryNotEmpty(String)
    case exportDirectoryNotEmpty(String)
    case pathOutsideMediaDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .fileStillExists(path):
            return "Media file could not be removed: \(path)"
        case let .mediaDirectoryNotEmpty(path):
            return "Media directory could not be emptied: \(path)"
        case let .exportDirectoryNotEmpty(path):
            return "Export directory could not be emptied: \(path)"
        case let .pathOutsideMediaDirectory(path):
            return "Refusing to access a file outside the managed media directory: \(path)"
        }
    }
}
