import Foundation

/// Notices changes inside the linked folders (Downloads, iCloud Drive, external drives…) while the
/// app is in the foreground, so new songs there show up without leaving the app or pulling to
/// refresh (e.g. a Safari download finishing while Musicbox is on screen, or side by side on iPad).
///
///   - A file presenter per folder hears about every coordinated change inside it: the Files app,
///     File Provider storage (iCloud Drive, On My iPhone › Downloads, cloud services) and iCloud
///     items that finish downloading. `onChange` is called shortly after (at most every
///     `minimumSpacing` seconds while changes keep coming, e.g. during a long download).
///   - Not every writer coordinates (some external drives do not), so while folders are linked a
///     slow poll calls `onPoll` as well. Unchanged files take the scan's cheap fast path.
@MainActor
final class LinkedFoldersWatcher {
    private static let quietDelay: TimeInterval = 1.5
    /// Changes that keep coming (a long download, a big copy) scan at most this often.
    private static let minimumSpacing: TimeInterval = 10
    static let pollInterval: TimeInterval = 60

    private var presenters: [String: LinkedFolderPresenter] = [:]
    private var changeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastChangeFired: Date?
    private let onChange: @MainActor () -> Void
    private let onPoll: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void, onPoll: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        self.onPoll = onPoll
    }

    /// Watches exactly `roots` (already resolved, access-started folder URLs). An empty list stops.
    func watch(_ roots: [URL]) {
        var wanted: [String: URL] = [:]
        for root in roots {
            wanted[LinkedFoldersWatcher.key(for: root)] = root
        }
        for path in presenters.keys.filter({ wanted[$0] == nil }) {
            if let presenter = presenters.removeValue(forKey: path) {
                NSFileCoordinator.removeFilePresenter(presenter)
            }
        }
        for (path, url) in wanted where presenters[path] == nil {
            let presenter = LinkedFolderPresenter(url: url) { [weak self] in
                Task { @MainActor in self?.scheduleChange() }
            }
            NSFileCoordinator.addFilePresenter(presenter)
            presenters[path] = presenter
        }

        if presenters.isEmpty {
            pollTask?.cancel()
            pollTask = nil
            changeTask?.cancel()
            changeTask = nil
        } else if pollTask == nil {
            startPolling()
        }
    }

    func stop() {
        watch([])
    }

    // MARK: - Private

    /// One pending pass covers every change made before it runs; it waits a moment for the burst to
    /// finish, and keeps `minimumSpacing` from the previous one.
    private func scheduleChange() {
        guard !presenters.isEmpty, changeTask == nil else { return }
        var delay = LinkedFoldersWatcher.quietDelay
        if let last = lastChangeFired {
            delay = max(delay, LinkedFoldersWatcher.minimumSpacing - Date().timeIntervalSince(last))
        }
        changeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.changeTask = nil
            self.lastChangeFired = Date()
            self.onChange()
        }
    }

    private func startPolling() {
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(LinkedFoldersWatcher.pollInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.onPoll()
            }
        }
    }

    nonisolated private static func key(for url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

/// Receives the coordinated-change messages for one linked folder (and everything inside it).
private final class LinkedFolderPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = url
        let queue = OperationQueue()
        queue.name = "com.charanraj.musicbox.linked-folder-presenter"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        presentedItemOperationQueue = queue
        self.onChange = onChange
        super.init()
    }

    func presentedItemDidChange() {
        onChange()
    }

    func presentedItemDidMove(to newURL: URL) {
        onChange()
    }

    func presentedSubitemDidAppear(at url: URL) {
        onChange()
    }

    func presentedSubitemDidChange(at url: URL) {
        onChange()
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        onChange()
    }

    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        // Nothing to save or close first; rescan once the deletion is done.
        completionHandler(nil)
        onChange()
    }
}
