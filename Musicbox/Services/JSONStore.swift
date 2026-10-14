import Foundation
import os

/// Tiny JSON persistence for app state in Application Support. Never throws and never crashes:
/// problems are logged, a missing or unreadable file simply loads as `nil`.
///
/// Dates use the encoder's default representation (a Double of seconds), which round-trips
/// exactly — the library scan relies on unchanged file-modification dates comparing equal.
enum JSONStore {
    /// Loads `T` from applicationSupport/<name>.json. Returns nil if missing/corrupt (never crashes).
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = fileURL(for: name)
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("Could not read \(name, privacy: .public).json: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("Could not decode \(name, privacy: .public).json: \(String(describing: error), privacy: .public)")
            preserveUnreadableFile(at: url, name: name)
            return nil
        }
    }

    /// Atomically writes to applicationSupport/<name>.json. Errors are logged, not thrown.
    static func save<T: Encodable>(_ value: T, to name: String) {
        let url = fileURL(for: name)
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            logger.error("Could not save \(name, privacy: .public).json: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private static let logger = Logger(subsystem: "com.charanraj.musicbox", category: "JSONStore")

    private static func fileURL(for name: String) -> URL {
        AppPaths.applicationSupport.appending(path: name + ".json", directoryHint: .notDirectory)
    }

    /// Keeps a copy of a file that failed to decode (it is about to be overwritten by the next save),
    /// so user data is never silently destroyed.
    private static func preserveUnreadableFile(at url: URL, name: String) {
        let backup = AppPaths.applicationSupport.appending(path: name + ".unreadable.json", directoryHint: .notDirectory)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: backup)
        do {
            try fileManager.copyItem(at: url, to: backup)
        } catch {
            logger.error("Could not back up \(name, privacy: .public).json: \(error.localizedDescription, privacy: .public)")
        }
    }
}
