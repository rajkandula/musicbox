import Foundation

/// Brings a single picked / opened file into the app's own library folder.
enum ImportService {
    enum ImportError: LocalizedError {
        case unsupportedFileType(fileName: String)
        case notAFile(fileName: String)
        case fileNotFound(fileName: String)
        case readFailed(fileName: String, reason: String)
        case writeFailed(fileName: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFileType(let fileName):
                return "“\(fileName)” can't be imported because Musicbox can't play this file type."
            case .notAFile(let fileName):
                return "“\(fileName)” is a folder, not a music or video file."
            case .fileNotFound(let fileName):
                return "“\(fileName)” could not be found. It may have been moved or deleted."
            case .readFailed(let fileName, let reason):
                return "“\(fileName)” could not be read. \(reason)"
            case .writeFailed(let fileName, let reason):
                return "“\(fileName)” could not be saved to Musicbox. \(reason)"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .unsupportedFileType:
                let audio = SupportedMedia.audioExtensions.sorted().joined(separator: ", ")
                let video = SupportedMedia.videoExtensions.sorted().joined(separator: ", ")
                return "Supported audio: \(audio). Supported video: \(video)."
            case .notAFile:
                return "To add a whole folder, use “Link a Folder…” instead."
            case .fileNotFound, .readFailed:
                return "If the file is stored in the cloud, make sure it is downloaded and try again."
            case .writeFailed:
                return "Check that your iPhone has enough free storage and try again."
            }
        }
    }

    /// Copies a picked/opened file into `destinationFolder` (default AppPaths.musicFolder),
    /// handling security scope (start/stop), coordinated reading (NSFileCoordinator) for
    /// iCloud/File Provider files, and name collisions ("Song 2.mp3"). If the file is already inside
    /// AppPaths.documents (e.g. Documents/Inbox from "Open in"), it is MOVED instead of copied
    /// (Inbox items moved into musicFolder). Returns the destination URL.
    static func importFile(at url: URL, into destinationFolder: URL = AppPaths.musicFolder) throws -> URL {
        let sourceName = url.lastPathComponent
        guard SupportedMedia.kind(forExtension: url.pathExtension) != nil else {
            throw ImportError.unsupportedFileType(fileName: sourceName)
        }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true {
            throw ImportError.notAFile(fileName: sourceName)
        }

        do {
            try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        } catch {
            throw ImportError.writeFailed(fileName: sourceName, reason: error.localizedDescription)
        }

        let preferredName = sanitizedFileName(sourceName)
        let sourcePath = canonicalPath(of: url)
        let documentsPath = canonicalPath(of: AppPaths.documents)

        // Already in our Documents folder.
        if isPath(sourcePath, inside: documentsPath) {
            guard fileManager.fileExists(atPath: url.path) else {
                throw ImportError.fileNotFound(fileName: sourceName)
            }
            // "Open in…" copies land in Documents/Inbox: move them into the library folder.
            if isPath(sourcePath, inside: documentsPath + "/Inbox") {
                return try moveItem(at: url, preferredName: preferredName, into: destinationFolder)
            }
            // Anywhere else in Documents it is already part of the library.
            return url
        }

        // A temporary copy the system made for us (share sheet / document picker import mode):
        // it is ours and will be purged anyway, so moving avoids a second copy of the data.
        let temporaryPath = canonicalPath(of: fileManager.temporaryDirectory)
        if isPath(sourcePath, inside: temporaryPath),
           fileManager.fileExists(atPath: url.path),
           let moved = try? moveItem(at: url, preferredName: preferredName, into: destinationFolder) {
            return moved
        }

        return try coordinatedCopy(from: url, preferredName: preferredName, into: destinationFolder)
    }

    /// Deletes a copy the system made to hand a file over to Musicbox ("Open in" / Share: it lands in
    /// Documents/Inbox, or in tmp/<bundle id>-Inbox). Used for files Musicbox can't take, which would
    /// otherwise stay there forever. Anything else (an opened-in-place URL is the user's own file) is
    /// never touched. Returns true if the copy was removed.
    @discardableResult
    static func discardSystemInboxCopy(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let path = canonicalPath(of: url)
        let inboxPath = canonicalPath(of: AppPaths.documents) + "/Inbox"
        let temporaryPath = canonicalPath(of: FileManager.default.temporaryDirectory)

        var isSystemCopy = isPath(path, inside: inboxPath)
        if !isSystemCopy, isPath(path, inside: temporaryPath) {
            let relative = path.dropFirst(temporaryPath.count).drop { $0 == "/" }
            let components = relative.split(separator: "/")
            isSystemCopy = components.count >= 2 && components[0].hasSuffix("-Inbox")
        }
        guard isSystemCopy else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Copy / move

    /// Reads the file through NSFileCoordinator so iCloud Drive / File Provider items are
    /// downloaded (or materialized) before copying.
    private static func coordinatedCopy(from url: URL, preferredName: String, into folder: URL) throws -> URL {
        let sourceName = url.lastPathComponent
        var coordinatorError: NSError?
        var copyResult: Result<URL, Error>?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { readableURL in
            copyResult = Result {
                try copyItem(at: readableURL, preferredName: preferredName, into: folder)
            }
        }

        if let copyResult {
            switch copyResult {
            case .success(let destination):
                return destination
            case .failure(let error):
                if let importError = error as? ImportError { throw importError }
                if isMissingFileError(error) {
                    throw ImportError.fileNotFound(fileName: sourceName)
                }
                throw ImportError.writeFailed(fileName: sourceName, reason: error.localizedDescription)
            }
        }

        if let coordinatorError {
            if isMissingFileError(coordinatorError) {
                throw ImportError.fileNotFound(fileName: sourceName)
            }
            throw ImportError.readFailed(fileName: sourceName, reason: coordinatorError.localizedDescription)
        }
        throw ImportError.readFailed(fileName: sourceName, reason: "The file is not available right now.")
    }

    private static func copyItem(at source: URL, preferredName: String, into folder: URL) throws -> URL {
        try placeUniquely(preferredName: preferredName, in: folder) { destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private static func moveItem(at source: URL, preferredName: String, into folder: URL) throws -> URL {
        let sourceName = source.lastPathComponent
        do {
            return try placeUniquely(preferredName: preferredName, in: folder) { destination in
                do {
                    try FileManager.default.moveItem(at: source, to: destination)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    throw error
                } catch {
                    // Moving can fail for read-only Inbox items; fall back to copy + best-effort cleanup.
                    try FileManager.default.copyItem(at: source, to: destination)
                    try? FileManager.default.removeItem(at: source)
                }
            }
        } catch {
            if isMissingFileError(error) {
                throw ImportError.fileNotFound(fileName: sourceName)
            }
            throw ImportError.writeFailed(fileName: sourceName, reason: error.localizedDescription)
        }
    }

    /// Picks "Song.mp3", "Song 2.mp3", "Song 3.mp3"… and runs `place` with the first free name,
    /// retrying with the next name if another writer grabbed it in the meantime.
    private static func placeUniquely(
        preferredName: String,
        in folder: URL,
        place: (URL) throws -> Void
    ) throws -> URL {
        var attempt = 0
        while true {
            let destination = uniqueDestination(for: preferredName, in: folder)
            do {
                try place(destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists && attempt < 20 {
                attempt += 1
                continue
            }
        }
    }

    private static func uniqueDestination(for fileName: String, in folder: URL) -> URL {
        let fileManager = FileManager.default
        let baseName = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension

        var candidate = folder.appendingPathComponent(fileName, isDirectory: false)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = fileExtension.isEmpty
                ? "\(baseName) \(counter)"
                : "\(baseName) \(counter).\(fileExtension)"
            candidate = folder.appendingPathComponent(name, isDirectory: false)
            counter += 1
        }
        return candidate
    }

    // MARK: - Helpers

    /// Leading dots would make the imported file hidden (and therefore invisible to the scanner).
    private static func sanitizedFileName(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        let fileExtension = (result as NSString).pathExtension
        if (result as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces).isEmpty {
            result = fileExtension.isEmpty ? "Imported File" : "Imported File.\(fileExtension)"
        }
        return result
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == CocoaError.fileNoSuchFile.rawValue
                || nsError.code == CocoaError.fileReadNoSuchFile.rawValue
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT)
        }
        return false
    }

    private static func isPath(_ path: String, inside folder: String) -> Bool {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix)
    }

    /// Symlink-resolved, standardized path with the "/private" prefix removed (so /private/var and
    /// /var compare equal) and no trailing slash.
    private static func canonicalPath(of url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let privatePrefix = "/private/"
        if path.hasPrefix(privatePrefix) {
            path.removeFirst(privatePrefix.count - 1)
        }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
