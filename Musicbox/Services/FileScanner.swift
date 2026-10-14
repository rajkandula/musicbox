import Foundation

/// One playable file found on disk by `FileScanner`.
struct ScannedFile: Sendable, Hashable {
    let location: TrackLocation
    let url: URL
    let fileExtension: String       // lowercased
    let kind: MediaKind
    let fileSize: Int64
    let modificationDate: Date?
}

/// What one enumeration of a folder found.
struct FileScanResult: Sendable {
    /// Playable candidates (see `FileScanner.scan`).
    let files: [ScannedFile]
    /// Newest modification date of the empty media files that were skipped (a copy or download
    /// that has only just started); nil if there were none.
    let newestEmptyFileModificationDate: Date?
}

/// Recursively finds playable media files below a folder.
///
/// Everything here is nonisolated and synchronous: callers run it off the main actor
/// (e.g. inside `Task.detached`).
enum FileScanner {
    /// Recursively enumerates `root` (nonisolated, synchronous — call off the main actor).
    /// - Includes only SupportedMedia extensions; skips hidden files, package contents, `.Trash`,
    ///   and symlink loops.
    /// - `sourceID == nil` => locations are `.documents(relativePath:)` (path relative to root),
    ///   otherwise `.folder(sourceID:relativePath:)`.
    /// - iCloud placeholders (`.<name>.icloud` or not-downloaded ubiquitous items) trigger
    ///   `FileManager.startDownloadingUbiquitousItem(at:)` and are NOT returned this pass.
    /// - relativePath uses "/" separators, no leading slash, standardized.
    static func scan(root: URL, sourceID: UUID?) -> [ScannedFile] {
        scanWithDetails(root: root, sourceID: sourceID).files
    }

    /// Same as `scan`, plus what the caller needs to notice files that are still being written.
    static func scanWithDetails(root: URL, sourceID: UUID?) -> FileScanResult {
        let fileManager = FileManager.default
        let enumerationRoot = resolvedEnumerationRoot(for: root)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: enumerationRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return FileScanResult(files: [], newestEmptyFileModificationDate: nil)
        }

        guard let enumerator = fileManager.enumerator(
            at: enumerationRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }   // unreadable sub-folders must not abort the scan
        ) else {
            return FileScanResult(files: [], newestEmptyFileModificationDate: nil)
        }

        let rootCanonicalPath = canonicalPath(of: enumerationRoot)
        let rootPrefix = rootCanonicalPath.hasSuffix("/") ? rootCanonicalPath : rootCanonicalPath + "/"

        // Ubiquity lookups are ~10x more expensive than plain attributes, so they are only done
        // for media candidates in places that can hold cloud items (linked folders / iCloud roots).
        // The app's own Documents folder is never ubiquitous.
        let rootIsUbiquitous = (try? enumerationRoot.resourceValues(forKeys: [.isUbiquitousItemKey]))?
            .isUbiquitousItem ?? false
        let checksUbiquity = sourceID != nil || rootIsUbiquitous

        var context = ScanContext(rootPrefix: rootPrefix, sourceID: sourceID, checksUbiquity: checksUbiquity)

        while let object = enumerator.nextObject() {
            guard let fileURL = object as? URL else { continue }
            autoreleasepool {
                process(fileURL, enumerator: enumerator, context: &context)
            }
        }

        context.results.sort { $0.relativePath < $1.relativePath }
        return FileScanResult(
            files: context.results.map(\.file),
            newestEmptyFileModificationDate: context.newestEmptyFileModificationDate
        )
    }

    // MARK: - Private

    /// Prefetched by the enumerator for every entry (cheap attributes only).
    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isDirectoryKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .isHiddenKey,
        .isSymbolicLinkKey,
    ]

    private static let resourceKeySet = Set(resourceKeys)

    /// Fetched lazily, only for media candidates when `checksUbiquity` is on.
    private static let ubiquityKeySet: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemDownloadRequestedKey,
    ]

    private static let iCloudPlaceholderSuffix = ".icloud"

    private struct ScanContext {
        let rootPrefix: String
        let sourceID: UUID?
        let checksUbiquity: Bool
        var results: [(relativePath: String, file: ScannedFile)] = []
        var newestEmptyFileModificationDate: Date?
        var seenRelativePaths = Set<String>()
        /// Raw parent-directory path -> canonical parent-directory path (avoids one realpath per file).
        var canonicalParents: [String: String] = [:]

        init(rootPrefix: String, sourceID: UUID?, checksUbiquity: Bool) {
            self.rootPrefix = rootPrefix
            self.sourceID = sourceID
            self.checksUbiquity = checksUbiquity
        }
    }

    private static func process(
        _ fileURL: URL,
        enumerator: FileManager.DirectoryEnumerator,
        context: inout ScanContext
    ) {
        let name = fileURL.lastPathComponent
        guard !name.isEmpty else { return }

        guard let values = try? fileURL.resourceValues(forKeys: resourceKeySet) else {
            // Unreadable entry: never descend into something we cannot inspect.
            enumerator.skipDescendants()
            return
        }

        let isHidden = name.hasPrefix(".") || (values.isHidden ?? false)

        if values.isDirectory == true {
            // Hidden folders (".Trash", ".git", app caches…) are never scanned.
            if isHidden { enumerator.skipDescendants() }
            return
        }

        if isHidden {
            if name.hasPrefix("."), name.hasSuffix(iCloudPlaceholderSuffix) {
                requestDownloadForPlaceholder(named: name, at: fileURL)
            }
            return
        }

        let fileExtension = fileURL.pathExtension.lowercased()
        guard let kind = SupportedMedia.kind(forExtension: fileExtension) else { return }

        var fileSize = values.fileSize
        var modificationDate = values.contentModificationDate

        if values.isSymbolicLink == true {
            // The enumerator never follows symlinks, so directory links (potential loops) are
            // simply ignored. Links to regular media files are accepted with the target's attributes.
            let target = fileURL.resolvingSymlinksInPath()
            guard target.path != fileURL.path,
                  let targetValues = try? target.resourceValues(forKeys: [
                      .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                  ]),
                  targetValues.isRegularFile == true else {
                return
            }
            fileSize = targetValues.fileSize
            modificationDate = targetValues.contentModificationDate
        } else if values.isRegularFile != true {
            return
        }

        // Cloud file that has not been downloaded yet: ask for it (once) and pick it up next scan.
        if context.checksUbiquity,
           let cloudValues = try? fileURL.resourceValues(forKeys: ubiquityKeySet),
           cloudValues.isUbiquitousItem == true,
           let status = cloudValues.ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            if cloudValues.ubiquitousItemDownloadRequested != true {
                try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
            }
            return
        }

        let size = Int64(fileSize ?? 0)
        // Empty files are unplayable (usually a download still being written).
        guard size > 0 else {
            if let modificationDate,
               context.newestEmptyFileModificationDate.map({ modificationDate > $0 }) ?? true {
                context.newestEmptyFileModificationDate = modificationDate
            }
            return
        }

        guard let relativePath = relativePath(
            for: fileURL,
            name: name,
            level: enumerator.level,
            context: &context
        ) else { return }

        // Duplicate IDs would corrupt the library; the first occurrence wins.
        guard context.seenRelativePaths.insert(relativePath).inserted else { return }

        let location: TrackLocation
        if let sourceID = context.sourceID {
            location = .folder(sourceID: sourceID, relativePath: relativePath)
        } else {
            location = .documents(relativePath: relativePath)
        }

        let scanned = ScannedFile(
            location: location,
            url: fileURL,
            fileExtension: fileExtension,
            kind: kind,
            fileSize: size,
            modificationDate: modificationDate
        )
        context.results.append((relativePath, scanned))
    }

    /// ".Song.mp3.icloud" -> starts downloading "Song.mp3" (only for playable extensions).
    private static func requestDownloadForPlaceholder(named name: String, at placeholderURL: URL) {
        var realName = String(name.dropFirst())
        guard realName.hasSuffix(iCloudPlaceholderSuffix) else { return }
        realName.removeLast(iCloudPlaceholderSuffix.count)
        guard !realName.isEmpty,
              SupportedMedia.kind(forExtension: (realName as NSString).pathExtension) != nil else {
            return
        }
        let realURL = placeholderURL
            .deletingLastPathComponent()
            .appendingPathComponent(realName, isDirectory: false)
        try? FileManager.default.startDownloadingUbiquitousItem(at: realURL)
    }

    /// Path of `fileURL` relative to the scan root, "/"-separated with no leading slash.
    ///
    /// Primary strategy: compare canonical paths (symlinks resolved, "/private" stripped) so that
    /// "/private/var/…" vs "/var/…" differences between the root URL and enumerated URLs do not
    /// matter. Fallback: the last `level` path components reported by the enumerator.
    private static func relativePath(
        for fileURL: URL,
        name: String,
        level: Int,
        context: inout ScanContext
    ) -> String? {
        let parentURL = fileURL.deletingLastPathComponent()
        let parentKey = parentURL.path

        let canonicalParent: String
        if let cached = context.canonicalParents[parentKey] {
            canonicalParent = cached
        } else {
            canonicalParent = canonicalPath(of: parentURL)
            context.canonicalParents[parentKey] = canonicalParent
        }

        let canonicalFile = canonicalParent.hasSuffix("/")
            ? canonicalParent + name
            : canonicalParent + "/" + name

        var relative: String?
        if canonicalFile.hasPrefix(context.rootPrefix) {
            relative = String(canonicalFile.dropFirst(context.rootPrefix.count))
        } else {
            let components = fileURL.pathComponents
            if level > 0, components.count > level {
                relative = components.suffix(level).joined(separator: "/")
            }
        }

        guard var result = relative else { return nil }
        while result.hasPrefix("/") { result.removeFirst() }
        while result.hasSuffix("/") { result.removeLast() }
        return result.isEmpty ? nil : result
    }

    /// If the root itself is a symbolic link, enumerate its destination (the enumerator does not
    /// descend through a symlinked starting point reliably).
    private static func resolvedEnumerationRoot(for root: URL) -> URL {
        let standardized = root.standardizedFileURL
        if let values = try? standardized.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            return standardized.resolvingSymlinksInPath()
        }
        return standardized
    }

    /// Symlink-resolved, standardized absolute path with the "/private" firmlink prefix removed
    /// and no trailing slash.
    private static func canonicalPath(of url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let privatePrefix = "/private/"
        if path.hasPrefix(privatePrefix) {
            path.removeFirst(privatePrefix.count - 1)   // keep the leading "/"
        }
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
