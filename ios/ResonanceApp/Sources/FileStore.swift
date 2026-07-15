import Foundation
import os

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
        let filename = "audio_\(entryId)_\(UUID().uuidString).m4a"
        return mediaDirectory().appendingPathComponent(filename)
    }

    static func createVideoFileURL(entryId: String, fileExtension: String = "mp4") -> URL {
        let safeExtension = fileExtension.isEmpty ? "mp4" : fileExtension
        let filename = "video_\(entryId)_\(UUID().uuidString).\(safeExtension)"
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
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        try FileManager.default.removeItem(atPath: path)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw FileStoreError.fileStillExists(path)
        }
    }

    static func deleteFileIfExists(atPath path: String) {
        do {
            try removeFileIfExists(atPath: path)
        } catch {
            logger.error("Failed to delete file at \(path): \(error.localizedDescription)")
        }
    }
}

enum FileStoreError: LocalizedError {
    case fileStillExists(String)
    case mediaDirectoryNotEmpty(String)

    var errorDescription: String? {
        switch self {
        case let .fileStillExists(path):
            return "Media file could not be removed: \(path)"
        case let .mediaDirectoryNotEmpty(path):
            return "Media directory could not be emptied: \(path)"
        }
    }
}
