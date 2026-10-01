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
        let directory = mediaDirectoryURL()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return false
        }
        return try !FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).isEmpty
    }

    static func removeAllStoredMediaFiles() throws {
        let directory = mediaDirectoryURL()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        let mediaFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for file in mediaFiles {
            try FileManager.default.removeItem(at: file)
        }
        guard try !hasStoredMediaFiles() else {
            throw FileStoreError.mediaDirectoryNotEmpty(directory.path)
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
    case pathOutsideMediaDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .fileStillExists(path):
            return "Media file could not be removed: \(path)"
        case let .mediaDirectoryNotEmpty(path):
            return "Media directory could not be emptied: \(path)"
        case let .pathOutsideMediaDirectory(path):
            return "Refusing to access a file outside the managed media directory: \(path)"
        }
    }
}
