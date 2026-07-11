import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "resonance", category: "FileStore")

enum FileStore {
    static func mediaDirectory() -> URL {
        guard let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.fault("Documents directory unavailable; falling back to Caches directory for media storage.")
            let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return cachesDir.appendingPathComponent("Media", isDirectory: true)
        }
        let dir = base.appendingPathComponent("Media", isDirectory: true)
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

    static func deleteFileIfExists(atPath path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            logger.error("Failed to delete file at \(path): \(error.localizedDescription)")
        }
    }
}
