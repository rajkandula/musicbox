import Foundation
import os

/// Well-known locations inside the app container. Safe to use from any thread.
enum AppPaths {
    /// The app's Documents folder (shown in the Files app as On My iPhone › Musicbox).
    static var documents: URL {
        URL.documentsDirectory
    }

    /// documents/"Music" — the default import target (created on demand).
    static var musicFolder: URL {
        ensureDirectory(documents.appending(path: "Music", directoryHint: .isDirectory))
    }

    /// Application Support (created on demand). Holds the JSON stores.
    static var applicationSupport: URL {
        ensureDirectory(URL.applicationSupportDirectory)
    }

    /// Caches (created on demand).
    static var caches: URL {
        ensureDirectory(URL.cachesDirectory)
    }

    /// caches/"Artwork" (created on demand).
    static var artworkCache: URL {
        ensureDirectory(caches.appending(path: "Artwork", directoryHint: .isDirectory))
    }

    /// Creates musicFolder, applicationSupport and artworkCache if they are missing.
    static func ensureDirectoriesExist() {
        _ = musicFolder
        _ = applicationSupport
        _ = artworkCache
    }

    // MARK: - Private

    private static let logger = Logger(subsystem: "com.charanraj.musicbox", category: "AppPaths")

    @discardableResult
    private static func ensureDirectory(_ url: URL) -> URL {
        let fileManager = FileManager.default
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                logger.error("Expected a folder but found a file at \(path, privacy: .public)")
            }
            return url
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            // Another thread may have created it in the meantime; only report real failures.
            if !fileManager.fileExists(atPath: path) {
                logger.error("Could not create \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return url
    }
}
