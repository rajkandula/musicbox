import Foundation

/// Watches the app's own folders (Documents, Documents/Music and their subfolders — the places the
/// Files app, Finder file sharing and "Open in" drop songs) while the app is in the foreground, and
/// calls `onChange` (debounced) when something is added, removed or renamed there. This makes songs
/// appear live, e.g. with the Files app side by side on iPad, without pulling to refresh.
///
/// A directory event only reports entries appearing or going, never a file's data being written.
/// Files that are still being copied when the scan runs are caught by the library itself: it scans
/// again while it sees recently modified or empty files (see `LibraryStore` settle passes).
@MainActor
final class DocumentsWatcher {
    /// Deeper folders (and folders beyond the cap) are still scanned; only their live events are
    /// not watched, so adding a song there shows up on the next scan.
    nonisolated private static let maxDepth = 3
    nonisolated private static let maxWatchedFolders = 64

    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var isStarted = false
    private var debounceTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    var isRunning: Bool { isStarted }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        AppPaths.ensureDirectoriesExist()
        // The two well-known folders right away; their subfolders are listed off the main thread.
        applyWatchedFolders(DocumentsWatcher.fixedFolders(documents: AppPaths.documents, music: AppPaths.musicFolder))
        refreshWatchedFolders()
    }

    func stop() {
        isStarted = false
        debounceTask?.cancel()
        debounceTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshAgain = false
        sources.values.forEach { $0.cancel() }
        sources.removeAll()
    }

    // MARK: - Private

    private func folderDidChange() {
        scheduleChange()
        // A new subfolder (e.g. an album dragged in whole) gets its own source, so the songs being
        // copied into it keep the debounce going and are seen too.
        refreshWatchedFolders()
    }

    /// Copies arrive as a burst of directory events; scan once it has been quiet for a moment.
    private func scheduleChange() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.onChange()
        }
    }

    /// Re-lists the folders to watch off the main thread; bursts are coalesced into one more pass.
    private func refreshWatchedFolders() {
        guard isStarted else { return }
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        let documents = AppPaths.documents
        let music = AppPaths.musicFolder
        refreshTask = Task { @MainActor [weak self] in
            let folders = await Task.detached(priority: .utility) {
                DocumentsWatcher.foldersToWatch(documents: documents, music: music)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            self.applyWatchedFolders(folders)
            if self.refreshAgain {
                self.refreshAgain = false
                self.refreshWatchedFolders()
            }
        }
    }

    /// Opens a source for every new folder and closes the ones for folders that are gone.
    private func applyWatchedFolders(_ folders: [String]) {
        guard isStarted else { return }
        let wanted = Set(folders)
        for path in sources.keys.filter({ !wanted.contains($0) }) {
            sources.removeValue(forKey: path)?.cancel()
        }
        for path in folders where sources[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .link],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.folderDidChange() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources[path] = source
        }
    }

    nonisolated private static func fixedFolders(documents: URL, music: URL) -> [String] {
        [key(for: documents), key(for: music)]
    }

    /// Documents and Documents/Music first, then subfolders level by level (hidden folders and
    /// packages skipped), up to `maxDepth` levels and `maxWatchedFolders` folders.
    nonisolated private static func foldersToWatch(documents: URL, music: URL) -> [String] {
        var result = fixedFolders(documents: documents, music: music)
        var included = Set(result)
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var level = [documents]
        for _ in 0..<maxDepth {
            var next: [URL] = []
            for folder in level {
                guard let children = try? fileManager.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for child in children {
                    guard let values = try? child.resourceValues(forKeys: Set(keys)),
                          values.isDirectory == true,
                          values.isSymbolicLink != true,
                          values.isPackage != true else { continue }
                    next.append(child)
                }
            }
            next.sort { $0.path < $1.path }
            for folder in next {
                let path = key(for: folder)
                guard included.insert(path).inserted else { continue }
                guard result.count < maxWatchedFolders else { return result }
                result.append(path)
            }
            level = next
        }
        return result
    }

    nonisolated private static func key(for url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
