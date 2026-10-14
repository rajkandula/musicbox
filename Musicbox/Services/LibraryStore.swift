import SwiftUI
import Observation
import UIKit
import os

/// The single source of truth for the music library: tracks found on the device, playlists,
/// linked folders and settings. Everything is persisted as JSON in Application Support.
@MainActor
@Observable
final class LibraryStore {

    // MARK: - State (read-only to UI)

    /// Sorted according to `settings.songSort`.
    private(set) var tracks: [Track] = []
    private(set) var tracksByID: [String: Track] = [:]
    /// Sorted by title (unknown album last).
    private(set) var albums: [AlbumGroup] = []
    /// Sorted by name (unknown artist last).
    private(set) var artists: [ArtistGroup] = []
    /// Sorted by name (case-insensitive).
    private(set) var playlists: [Playlist] = []
    private(set) var folders: [LinkedFolder] = []
    private(set) var isScanning: Bool = false
    private(set) var scanStatus: String? = nil
    private(set) var lastScanDate: Date? = nil
    var lastErrorMessage: String? = nil

    /// Persisted on every change. Changing the sort re-sorts; changing a filter or the Music
    /// library option triggers a rescan.
    var settings: AppSettings {
        get {
            access(keyPath: \.settings)
            return settingsStorage
        }
        set {
            let oldValue = settingsStorage
            guard newValue != oldValue else { return }
            withMutation(keyPath: \.settings) {
                settingsStorage = newValue
            }
            settingsDidChange(from: oldValue, to: newValue)
        }
    }

    // MARK: - Derived (cached; refreshed whenever tracks change)

    private(set) var audioTracks: [Track] = []
    private(set) var videoTracks: [Track] = []
    private(set) var favoriteTracks: [Track] = []
    /// By dateAdded (newest first), max 100.
    private(set) var recentlyAddedTracks: [Track] = []
    /// playCount > 0, most played first, max 100.
    private(set) var mostPlayedTracks: [Track] = []
    private(set) var documentsTrackCount: Int = 0
    private(set) var musicLibraryTrackCount: Int = 0

    /// Called with the IDs of tracks that left the library (scan, folder removal, deletion).
    @ObservationIgnored var onTracksRemoved: ((Set<String>) -> Void)? = nil

    // MARK: - Private state

    @ObservationIgnored private var settingsStorage = AppSettings()
    /// Files that exist but are not in the library (filtered out, unplayable) plus recently vanished
    /// tracks. Keeps user data and avoids re-reading metadata on every scan.
    @ObservationIgnored private var hiddenEntries: [String: LibraryStoreHiddenEntry] = [:]
    /// Resolved, access-started security-scoped folder URLs (kept for the app lifetime).
    @ObservationIgnored private var folderAccess: [UUID: LibraryStoreFolderAccess] = [:]
    @ObservationIgnored private var trackPositions: [String: Int] = [:]
    @ObservationIgnored private var albumPositions: [String: Int] = [:]
    @ObservationIgnored private var artistPositions: [String: Int] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>? = nil
    @ObservationIgnored private var scanRequestedWhileRunning = false
    /// A rescan requested right after a scan ended, run once the debounce window is over.
    @ObservationIgnored private var trailingRescanTask: Task<Void, Never>? = nil
    /// Another pass scheduled because the last one saw files that were still being written.
    @ObservationIgnored private var settleRescanTask: Task<Void, Never>? = nil
    @ObservationIgnored private var settlePassesLeft = LibraryStoreScanWorker.maxSettlePasses
    @ObservationIgnored private var linkedFoldersWatcher: LinkedFoldersWatcher? = nil
    @ObservationIgnored private var watchesLinkedFolders = false
    @ObservationIgnored private var activeImports = 0
    @ObservationIgnored private var deletedDuringScan = Set<String>()
    /// Bumped whenever a newer index (order / albums / artists) supersedes in-flight work.
    @ObservationIgnored private var indexGeneration = 0
    @ObservationIgnored private var partialApplyInFlight = false
    @ObservationIgnored private var librarySaveTask: Task<Void, Never>? = nil
    @ObservationIgnored private var protectedSavesInFlight = 0
    @ObservationIgnored private var saveBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    /// Folders the user removed recently; their songs wait in `hiddenEntries` in case they come back.
    @ObservationIgnored private var removedFolders: [LibraryStoreRemovedFolder] = []
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    private let persistenceQueue = DispatchQueue(label: "com.charanraj.musicbox.library-persistence", qos: .utility)

    // MARK: - Init

    /// Loads library/playlists/folders/settings JSON synchronously.
    init() {
        AppPaths.ensureDirectoriesExist()

        let loadedSettings = JSONStore.load(AppSettings.self, from: LibraryStoreFiles.settings) ?? AppSettings()
        let loadedFolders = (JSONStore.load([LibraryStoreLossy<LinkedFolder>].self, from: LibraryStoreFiles.folders) ?? [])
            .compactMap { $0.value }
        let loadedTracks = (JSONStore.load([LibraryStoreLossy<Track>].self, from: LibraryStoreFiles.library) ?? [])
            .compactMap { $0.value }
        let loadedHidden = (JSONStore.load([String: LibraryStoreLossy<LibraryStoreHiddenEntry>].self, from: LibraryStoreFiles.hidden) ?? [:])
            .compactMapValues { $0.value }
        let loadedPlaylists = (JSONStore.load([LibraryStoreLossy<Playlist>].self, from: LibraryStoreFiles.playlists) ?? [])
            .compactMap { $0.value }
        let loadedRemovedFolders = (JSONStore.load([LibraryStoreLossy<LibraryStoreRemovedFolder>].self, from: LibraryStoreFiles.removedFolders) ?? [])
            .compactMap { $0.value }

        var folderIDs = Set<UUID>()
        let folderList = loadedFolders.filter { folderIDs.insert($0.id).inserted }
        let knownFolderIDs = folderIDs
        var removedIDs = Set<UUID>()
        let removedFolderList = loadedRemovedFolders.filter { record in
            !knownFolderIDs.contains(record.id) && removedIDs.insert(record.id).inserted
        }
        let removedFolderIDs = removedIDs

        // Tracks of folders that no longer exist can never be played again. Songs of a recently
        // removed folder wait (hidden) in case the folder is linked again.
        func belongsToKnownSource(_ location: TrackLocation, includingRemovedFolders: Bool) -> Bool {
            if case .folder(let sourceID, _) = location {
                return knownFolderIDs.contains(sourceID)
                    || (includingRemovedFolders && removedFolderIDs.contains(sourceID))
            }
            return true
        }

        var byID: [String: Track] = [:]
        var ordered: [Track] = []
        byID.reserveCapacity(loadedTracks.count)
        ordered.reserveCapacity(loadedTracks.count)
        for track in loadedTracks where byID[track.id] == nil && belongsToKnownSource(track.location, includingRemovedFolders: false) {
            byID[track.id] = track
            ordered.append(track)
        }
        let hidden = loadedHidden.filter { entry in
            byID[entry.key] == nil && belongsToKnownSource(entry.value.location, includingRemovedFolders: true)
        }

        var playlistIDs = Set<UUID>()
        let playlistList = loadedPlaylists.filter { playlistIDs.insert($0.id).inserted }

        settingsStorage = loadedSettings
        folders = folderList
        removedFolders = removedFolderList
        tracks = ordered
        tracksByID = byID
        hiddenEntries = hidden
        playlists = LibraryStore.sortedPlaylists(playlistList)

        rebuildPositionMaps()
        refreshDerivedLists()
        installLifecycleObservers()
        linkedFoldersWatcher = LinkedFoldersWatcher(
            onChange: { [weak self] in
                Task { @MainActor in await self?.rescan() }
            },
            onPoll: { [weak self] in
                Task { @MainActor in await self?.pollLinkedFolders() }
            }
        )

        // The saved order already matches the saved sort; albums/artists are grouped off the main thread.
        if !ordered.isEmpty {
            rebuildIndex(tracksOnly: false)
        }
    }

    // MARK: - Derived lookups

    func track(id: String) -> Track? {
        tracksByID[id]
    }

    /// Preserves order, skips missing.
    func tracks(ids: [String]) -> [Track] {
        let lookup = tracksByID
        return ids.compactMap { lookup[$0] }
    }

    func tracks(in playlist: Playlist) -> [Track] {
        let current = self.playlist(id: playlist.id) ?? playlist
        return tracks(ids: current.trackIDs)
    }

    func playlist(id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    func tracks(inFolder folderID: UUID) -> [Track] {
        tracks.filter { track in
            if case .folder(let sourceID, _) = track.location { return sourceID == folderID }
            return false
        }
    }

    // MARK: - Playback support

    /// Resolves a playable file URL. For `.folder` locations it uses the resolved, already
    /// access-started security-scoped folder URL. Returns nil if unavailable.
    func url(for track: Track) -> URL? {
        let fileManager = FileManager.default
        switch track.location {
        case .documents(let relativePath):
            let url = AppPaths.documents.appending(path: relativePath, directoryHint: .notDirectory)
            return fileManager.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil

        case .folder(let sourceID, let relativePath):
            guard let root = accessibleRoot(forFolder: sourceID, verifyReachable: false) else { return nil }
            let url = root.appending(path: relativePath, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
            // An iCloud file the system evicted to save space: ask for it so it is back next time.
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return nil

        case .mediaLibrary(_, let assetURL):
            return URL(string: assetURL)
        }
    }

    // MARK: - Scanning

    /// Full scan of Documents + linked folders (+ Music library if enabled); merges; drops missing.
    /// If a scan is already running, this waits for it (and makes sure one more pass follows, so
    /// changes that triggered this call are picked up). While files still look like they are being
    /// copied, a few more passes follow by themselves until they settle.
    func rescan() async {
        settlePassesLeft = LibraryStoreScanWorker.maxSettlePasses
        await startOrJoinScan()
    }

    /// On launch / foreground. Unchanged files take the cheap fast path, so this only debounces
    /// bursts (e.g. active↔inactive flapping from Control Center): within `rescanDebounce` of the
    /// last scan, one pass is scheduled for the end of that window instead (never dropped, so a
    /// change made while the last scan ran is still picked up). A user who copies songs in the Files
    /// app and switches straight back must see them immediately, so there is no long throttle.
    func rescanIfNeeded() async {
        if scanTask != nil {
            await rescan()
            return
        }
        if let last = lastScanDate {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed >= 0 && elapsed < LibraryStore.rescanDebounce {
                scheduleTrailingRescan(after: LibraryStore.rescanDebounce - elapsed)
                return
            }
        }
        await rescan()
    }

    /// Call when the app comes on screen: new songs in linked folders then show up by themselves
    /// (file presenters plus a slow poll). `stopWatchingLinkedFolders()` when it goes to the background.
    func startWatchingLinkedFolders() {
        watchesLinkedFolders = true
        updateLinkedFoldersWatcher()
    }

    func stopWatchingLinkedFolders() {
        watchesLinkedFolders = false
        updateLinkedFoldersWatcher()
    }

    // MARK: - Sources

    /// `url` comes from `.fileImporter([.folder])`. Starts its security scope, bookmarks it,
    /// persists and scans. Problems end up in `lastErrorMessage`.
    func addFolder(_ url: URL) async {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        let name = LibraryStoreScanWorker.displayName(for: url)

        func fail(_ message: String) {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            lastErrorMessage = message
        }

        let newPath = LibraryStoreScanWorker.canonicalPath(of: url)
        let documentsPath = LibraryStoreScanWorker.canonicalPath(of: AppPaths.documents)
        if newPath == documentsPath || newPath.hasPrefix(documentsPath + "/") {
            fail("“\(name)” is already inside Musicbox’s own folder, so its songs are found automatically.")
            return
        }

        for folder in folders {
            guard let root = accessibleRoot(forFolder: folder.id, verifyReachable: false) else { continue }
            let existingPath = LibraryStoreScanWorker.canonicalPath(of: root)
            if existingPath == newPath {
                fail("“\(name)” is already linked. Pull down on your library to check it for new songs.")
                return
            }
            if newPath.hasPrefix(existingPath + "/") {
                fail("“\(name)” is inside “\(folder.displayName)”, which is already linked, so its songs are already in your library.")
                return
            }
        }

        guard LibraryStoreScanWorker.isReadableDirectory(url) else {
            fail("Musicbox can’t open “\(name)”. Make sure the folder is available (and downloaded, if it is in the cloud), then try again.")
            return
        }

        let bookmark: Data
        do {
            bookmark = try FolderBookmarks.makeBookmark(for: url)
        } catch {
            libraryLogger.error("Bookmark failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            fail("Musicbox couldn’t link “\(name)”. Please try again, or choose a different folder.")
            return
        }

        // The same folder removed recently: reuse its ID, so its songs keep their IDs and come back
        // with their playlists, favourites and play counts (they wait in the hidden entries).
        let now = Date()
        let reusable = removedFolders.last { record in
            record.canonicalPath == newPath
                && now.timeIntervalSince(record.removedAt) < LibraryStoreScanWorker.vanishedRetention
                && !folders.contains(where: { $0.id == record.id })
        }
        if let reusable {
            removedFolders.removeAll { $0.id == reusable.id }
            persistRemovedFolders()
        }

        let folder = LinkedFolder(
            id: reusable?.id ?? UUID(),
            displayName: name,
            bookmarkData: bookmark,
            addedAt: now,
            lastScanAt: nil,
            trackCount: 0,
            isAvailable: true,
            canonicalPath: newPath
        )
        folderAccess[folder.id] = LibraryStoreFolderAccess(url: url, isAccessing: didStartAccess)
        folders.append(folder)
        persistFolders()
        await rescan()
    }

    /// Removes the folder and its tracks from the library. Playlists keep the IDs: the songs wait
    /// out of sight (with favourites, play counts and artwork) for `vanishedRetention`, and linking
    /// the same folder again within that time brings them back.
    func removeFolder(_ id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        // Where the folder is, to recognise it when it is linked again (needs its folder entry).
        // An offline folder (drive unplugged, bookmark not resolvable) uses where it was last seen.
        let rootURL = folderAccess[id]?.url ?? accessibleRoot(forFolder: id, verifyReachable: false)
        let canonicalPath = rootURL.map { LibraryStoreScanWorker.canonicalPath(of: $0) }
            ?? folders[index].canonicalPath
            ?? LibraryStoreScanWorker.canonicalPath(fromBookmark: folders[index].bookmarkData)
        let now = Date()

        var updatedFolders = folders
        updatedFolders.remove(at: index)
        folders = updatedFolders

        let removedIDs = Set(tracksByID.values.lazy.filter { LibraryStoreScanWorker.isInFolder($0.location, id) }.map(\.id))
        var hidden = hiddenEntries
        var droppedIDs = Set<String>()
        var records = removedFolders.filter { $0.id != id }

        if let canonicalPath {
            // Keep the folder's songs as recently vanished ones.
            for trackID in removedIDs {
                guard let track = tracksByID[trackID] else { continue }
                hidden[trackID] = LibraryStoreHiddenEntry(
                    location: track.location,
                    fileSize: track.fileSize,
                    modificationDate: track.fileModificationDate,
                    track: track,
                    lastSeen: now,
                    checkedAt: now
                )
            }
            // Already hidden entries stay only if they carry a song's data.
            for (entryID, entry) in hiddenEntries
            where LibraryStoreScanWorker.isInFolder(entry.location, id) && entry.knownTrack == nil {
                hidden.removeValue(forKey: entryID)
                droppedIDs.insert(entryID)
            }
            // An older removal of the same folder can no longer be linked back: forget its songs.
            let superseded = Set(records.lazy.filter { $0.canonicalPath == canonicalPath }.map(\.id))
            if !superseded.isEmpty {
                records.removeAll { superseded.contains($0.id) }
                for (entryID, entry) in hidden where LibraryStoreScanWorker.isInFolder(entry.location, anyOf: superseded) {
                    hidden.removeValue(forKey: entryID)
                    droppedIDs.insert(entryID)
                }
            }
            records.append(LibraryStoreRemovedFolder(id: id, canonicalPath: canonicalPath, removedAt: now))
        } else {
            // The folder can't be located, so it can never be recognised again.
            for (entryID, entry) in hiddenEntries where LibraryStoreScanWorker.isInFolder(entry.location, id) {
                hidden.removeValue(forKey: entryID)
                droppedIDs.insert(entryID)
            }
            droppedIDs.formUnion(removedIDs)
        }

        hiddenEntries = hidden
        removeTracksFromState(removedIDs)
        if records != removedFolders {
            removedFolders = records
            persistRemovedFolders()
        }

        LibraryStoreScanWorker.removeArtworkInBackground(droppedIDs)
        persistFolders()
        persistLibrary()

        if !removedIDs.isEmpty {
            onTracksRemoved?(removedIDs)
        }
        // Stop the security scope only after the player (and the watcher) let go of the folder.
        let access = folderAccess.removeValue(forKey: id)
        updateLinkedFoldersWatcher()
        if let access, access.isAccessing {
            access.url.stopAccessingSecurityScopedResource()
        }
    }

    /// Whether `removeFolder` can keep this folder's songs for a later re-link (it knows where the
    /// folder is or was). If not, its songs and their user data are gone once it is removed.
    /// No side effects (safe to call while a view is being built).
    func canRestoreFolderAfterRemoval(_ id: UUID) -> Bool {
        guard let folder = folders.first(where: { $0.id == id }) else { return false }
        return folderAccess[id] != nil
            || folder.canonicalPath != nil
            || LibraryStoreScanWorker.canonicalPath(fromBookmark: folder.bookmarkData) != nil
    }

    /// Copies files into `AppPaths.musicFolder` via ImportService, then rescans.
    /// Returns the number of files imported.
    func importFiles(_ urls: [URL]) async -> Int {
        let candidates = urls.filter { $0.isFileURL }
        guard !candidates.isEmpty else { return 0 }

        activeImports += 1
        updateBusyState()

        var imported = 0
        var unsupported: [String] = []
        var failed: [String] = []
        for (offset, url) in candidates.enumerated() {
            let name = url.lastPathComponent
            setStatus(candidates.count == 1 ? "Importing “\(name)”…" : "Importing \(offset + 1) of \(candidates.count)…")
            guard SupportedMedia.kind(forExtension: url.pathExtension) != nil else {
                unsupported.append(name)
                continue
            }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try ImportService.importFile(at: url)
                }.value
                imported += 1
            } catch {
                libraryLogger.error("Import failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failed.append(name)
            }
        }

        if let message = LibraryStore.importProblemMessage(unsupported: unsupported, failed: failed) {
            lastErrorMessage = message
        }
        if imported > 0 {
            await rescan()
        }

        activeImports -= 1
        updateBusyState()
        return imported
    }

    /// "Open in" / share-to-app entry point: imports that file, then rescans.
    func handleOpenURL(_ url: URL) async {
        guard url.isFileURL else { return }
        let name = url.lastPathComponent
        guard SupportedMedia.kind(forExtension: url.pathExtension) != nil else {
            // The system copied it into our Inbox to hand it over; nothing else would ever delete it.
            ImportService.discardSystemInboxCopy(at: url)
            lastErrorMessage = "Musicbox can’t play “\(name)” because its file type isn’t supported."
            return
        }
        _ = await importFiles([url])
    }

    /// Only for `.documents` tracks: deletes the file, removes the track and cleans playlists.
    func deleteFromDevice(_ trackID: String) throws {
        guard let track = tracksByID[trackID] else {
            throw LibraryStoreError.trackNotFound
        }
        guard case .documents(let relativePath) = track.location else {
            throw LibraryStoreError.notDeletable(track.title)
        }

        let fileURL = AppPaths.documents.appending(path: relativePath, directoryHint: .notDirectory)
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone; just clean up the library.
        } catch {
            libraryLogger.error("Delete failed for \(relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw LibraryStoreError.deleteFailed(track.title)
        }

        deletedDuringScan.insert(trackID)
        if hiddenEntries[trackID] != nil {
            hiddenEntries.removeValue(forKey: trackID)
        }
        removeTracksFromState([trackID])

        let now = Date()
        var playlistsChanged = false
        let cleanedPlaylists = playlists.map { playlist -> Playlist in
            guard playlist.trackIDs.contains(trackID) else { return playlist }
            var updated = playlist
            updated.trackIDs.removeAll { $0 == trackID }
            updated.updatedAt = now
            playlistsChanged = true
            return updated
        }
        if playlistsChanged {
            playlists = cleanedPlaylists
            persistPlaylists()
        }

        LibraryStoreScanWorker.removeArtworkInBackground([trackID])
        persistLibrary()
        onTracksRemoved?([trackID])
    }

    /// Asks for Music library permission; sets `settings.includeMusicLibrary` on success.
    /// A denial only returns false: the caller explains it (with an Open Settings button).
    func requestMusicLibraryAccessAndEnable() async -> Bool {
        let granted = await MediaLibraryScanner.requestAuthorization()
        if granted {
            if settings.includeMusicLibrary {
                await rescan()
            } else {
                settings.includeMusicLibrary = true   // triggers a rescan
            }
            return true
        }
        if settings.includeMusicLibrary {
            settings.includeMusicLibrary = false
        }
        return false
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(name: String, trackIDs: [String] = []) -> Playlist {
        let now = Date()
        var seen = Set<String>()
        let playlist = Playlist(
            id: UUID(),
            name: LibraryStore.cleanPlaylistName(name) ?? "New Playlist",
            trackIDs: trackIDs.filter { seen.insert($0).inserted },
            createdAt: now,
            updatedAt: now
        )
        var list = playlists
        list.append(playlist)
        playlists = LibraryStore.sortedPlaylists(list)
        persistPlaylists()
        return playlist
    }

    /// A blank name keeps the current name.
    func renamePlaylist(_ id: UUID, to name: String) {
        guard let cleanName = LibraryStore.cleanPlaylistName(name) else { return }
        updatePlaylist(id, resort: true) { playlist in
            guard playlist.name != cleanName else { return false }
            playlist.name = cleanName
            return true
        }
    }

    func deletePlaylist(_ id: UUID) {
        guard playlists.contains(where: { $0.id == id }) else { return }
        playlists = playlists.filter { $0.id != id }
        persistPlaylists()
    }

    /// Appends, skipping duplicates.
    func addTracks(_ trackIDs: [String], to playlistID: UUID) {
        updatePlaylist(playlistID) { playlist in
            var existing = Set(playlist.trackIDs)
            var added = false
            for trackID in trackIDs where existing.insert(trackID).inserted {
                playlist.trackIDs.append(trackID)
                added = true
            }
            return added
        }
    }

    /// `offsets` index into `playlist.trackIDs`.
    func removeTracks(at offsets: IndexSet, from playlistID: UUID) {
        updatePlaylist(playlistID) { playlist in
            let count = playlist.trackIDs.count
            let valid: [Int] = offsets.filter { $0 >= 0 && $0 < count }
            guard !valid.isEmpty else { return false }
            for index in valid.sorted(by: >) {
                playlist.trackIDs.remove(at: index)
            }
            return true
        }
    }

    func removeTrack(_ trackID: String, from playlistID: UUID) {
        updatePlaylist(playlistID) { playlist in
            let before = playlist.trackIDs.count
            playlist.trackIDs.removeAll { $0 == trackID }
            return playlist.trackIDs.count != before
        }
    }

    func moveTracks(in playlistID: UUID, from source: IndexSet, to destination: Int) {
        updatePlaylist(playlistID) { playlist in
            let count = playlist.trackIDs.count
            let validSource = IndexSet(source.filter { $0 >= 0 && $0 < count })
            guard !validSource.isEmpty else { return false }
            let target = min(max(destination, 0), count)
            let before = playlist.trackIDs
            playlist.trackIDs.move(fromOffsets: validSource, toOffset: target)
            return playlist.trackIDs != before
        }
    }

    // MARK: - User data

    func toggleFavorite(_ trackID: String) {
        if mutateTrack(trackID, { $0.isFavorite.toggle() }) {
            saveUserDataChange(debounce: 0.5)
        }
    }

    /// playCount += 1, lastPlayedAt = now (debounced save while the app is on screen).
    func recordPlay(_ trackID: String) {
        if mutateTrack(trackID, { track in
            track.playCount += 1
            track.lastPlayedAt = Date()
        }) {
            saveUserDataChange(debounce: 2)
        }
    }
}

// MARK: - Scanning internals

private extension LibraryStore {

    /// `rescanIfNeeded` calls this soon after a scan ended are folded into one pass.
    static let rescanDebounce: TimeInterval = 2

    /// Starts a scan, or joins the running one and queues one more pass after it.
    func startOrJoinScan() async {
        // Whatever was waiting to run is covered by this pass (or the follow-up pass it queues).
        trailingRescanTask?.cancel()
        trailingRescanTask = nil
        settleRescanTask?.cancel()
        settleRescanTask = nil

        if let running = scanTask {
            scanRequestedWhileRunning = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runScanLoop()
        }
        scanTask = task
        updateBusyState()
        await task.value
    }

    func runScanLoop() async {
        var sawFilesInFlight = false
        repeat {
            scanRequestedWhileRunning = false
            sawFilesInFlight = await performScan()
        } while scanRequestedWhileRunning
        scanTask = nil
        updateBusyState()
        scheduleSettlePassIfNeeded(sawFilesInFlight: sawFilesInFlight)
    }

    /// Called within the debounce window after a scan: one pass right after the window, however
    /// many calls came in.
    func scheduleTrailingRescan(after delay: TimeInterval) {
        guard trailingRescanTask == nil else { return }
        trailingRescanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.trailingRescanTask = nil
            await self.rescan()
        }
    }

    /// A file that is still being copied or downloaded was read (or skipped) half-written, and no
    /// event may tell us when it is complete (only the directory entry raises one). Look again
    /// shortly, until nothing is being written any more (bounded by `maxSettlePasses`).
    func scheduleSettlePassIfNeeded(sawFilesInFlight: Bool) {
        guard sawFilesInFlight, settlePassesLeft > 0, settleRescanTask == nil else { return }
        settlePassesLeft -= 1
        settleRescanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LibraryStoreScanWorker.settleDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.settleRescanTask = nil
            // In the background nobody is looking; the scan on the next foreground catches up.
            guard UIApplication.shared.applicationState != .background else { return }
            await self.startOrJoinScan()
        }
    }

    /// Linked folders whose writers don't coordinate raise no event: check now and then while the
    /// app is on screen, unless a scan just ran anyway.
    func pollLinkedFolders() async {
        guard watchesLinkedFolders, scanTask == nil else { return }
        if let last = lastScanDate, Date().timeIntervalSince(last) < LinkedFoldersWatcher.pollInterval * 0.9 {
            return
        }
        // Not a new request: a file that never stops changing must not keep the settle passes going.
        await startOrJoinScan()
    }

    /// Watches the linked folders that are resolved (access-started) right now, while on screen.
    /// Folders resolve during scans, so this is refreshed after each one.
    func updateLinkedFoldersWatcher() {
        guard let watcher = linkedFoldersWatcher else { return }
        guard watchesLinkedFolders else {
            watcher.stop()
            return
        }
        watcher.watch(folders.compactMap { folderAccess[$0.id]?.url })
    }

    /// Returns true if some files looked like they were still being written.
    func performScan() async -> Bool {
        let scanDate = Date()
        let scanSettings = settings
        deletedDuringScan.removeAll()
        setStatus("Looking for music…")

        // 1. Work out which roots can be scanned.
        var roots = [LibraryStoreScanRoot(sourceID: nil, url: AppPaths.documents, name: LibraryStore.onDeviceName)]
        var scannedFolderIDs = Set<UUID>()
        var unavailableFolderIDs = Set<UUID>()
        for folder in folders {
            if let root = accessibleRoot(forFolder: folder.id, verifyReachable: true) {
                roots.append(LibraryStoreScanRoot(sourceID: folder.id, url: root, name: folder.displayName))
                scannedFolderIDs.insert(folder.id)
            } else {
                unavailableFolderIDs.insert(folder.id)
            }
        }

        // 2. Enumerate files off the main actor.
        var rootScans: [LibraryStoreRootScan] = []
        var filesFound = 0
        for root in roots {
            setStatus(filesFound == 0 ? "Scanning \(root.name)…" : "Scanning \(root.name)… \(filesFound) files")
            let rootURL = root.url
            let sourceID = root.sourceID
            let scan = await Task.detached(priority: .userInitiated) {
                LibraryStoreScanWorker.enumerate(root: rootURL, sourceID: sourceID)
            }.value
            filesFound += scan.files.count
            rootScans.append(scan)
        }

        // 3. Music library (already carries metadata).
        var mediaResults: [LibraryStoreMediaResult] = []
        if scanSettings.includeMusicLibrary && MediaLibraryScanner.isAuthorized {
            setStatus("Scanning Music library…")
            var knownArtwork = Set<String>()
            for track in tracksByID.values where track.hasArtwork {
                if case .mediaLibrary = track.location { knownArtwork.insert(track.id) }
            }
            for (id, entry) in hiddenEntries where entry.track?.hasArtwork == true {
                if case .mediaLibrary = entry.location { knownArtwork.insert(id) }
            }
            let known = knownArtwork
            mediaResults = await Task.detached(priority: .userInitiated) {
                LibraryStoreScanWorker.scanMediaLibrary(knownArtworkIDs: known)
            }.value
        }

        // 4. Decide which files need their metadata (re)read.
        let oldTracks = tracksByID
        let oldHidden = hiddenEntries
        let scansToPlan = rootScans
        let plan = await Task.detached(priority: .userInitiated) {
            LibraryStoreScanWorker.plan(roots: scansToPlan, oldTracks: oldTracks, oldHidden: oldHidden, now: scanDate)
        }.value

        let baseInput = LibraryStoreMergeInput(
            files: plan.files,
            outcomes: [:],
            mediaItems: mediaResults,
            oldTracks: oldTracks,
            oldHidden: oldHidden,
            unavailableFolderIDs: unavailableFolderIDs,
            settings: scanSettings,
            scanDate: scanDate,
            isPartial: true
        )

        // 5. Read metadata with bounded concurrency; long scans show results progressively.
        let outcomes = await readMetadata(plan.toRead, base: baseInput)

        // 6. Merge, group and sort off the main actor, then apply.
        setStatus("Updating library…")
        var finalInput = baseInput
        finalInput.outcomes = outcomes
        finalInput.isPartial = false
        let mergeInput = finalInput
        let output = await Task.detached(priority: .userInitiated) {
            LibraryStoreScanWorker.merge(mergeInput)
        }.value

        applyMergeOutput(output, context: LibraryStoreScanContext(
            scanDate: scanDate,
            scannedFolderIDs: scannedFolderIDs,
            unavailableFolderIDs: unavailableFolderIDs
        ))
        return rootScans.contains { $0.hasFilesInFlight }
    }

    func readMetadata(_ requests: [LibraryStoreReadRequest], base: LibraryStoreMergeInput) async -> [String: LibraryStoreReadOutcome] {
        guard !requests.isEmpty else { return [:] }
        let total = requests.count
        var lastStatusUpdate = Date.distantPast
        var lastPartialApply = Date()
        var partialApplies = 0
        setStatus("Reading 0 of \(total)…")

        return await withTaskGroup(of: LibraryStoreReadOutcome.self, returning: [String: LibraryStoreReadOutcome].self) { group in
            var collected: [String: LibraryStoreReadOutcome] = [:]
            collected.reserveCapacity(total)
            var nextIndex = 0
            var finished = 0

            while nextIndex < min(libraryMaxConcurrentReads, total) {
                let request = requests[nextIndex]
                group.addTask { await LibraryStoreScanWorker.read(request) }
                nextIndex += 1
            }

            while let outcome = await group.next() {
                collected[outcome.id] = outcome
                finished += 1
                if nextIndex < total {
                    let request = requests[nextIndex]
                    group.addTask { await LibraryStoreScanWorker.read(request) }
                    nextIndex += 1
                }

                let now = Date()
                if finished == total || now.timeIntervalSince(lastStatusUpdate) >= 0.2 {
                    lastStatusUpdate = now
                    self.setStatus("Reading \(finished) of \(total)…")
                }

                // Show what has been found so far during long first scans.
                let interval: TimeInterval = partialApplies == 0 ? 2.5 : 6
                if total >= 40, finished < total, !self.partialApplyInFlight,
                   now.timeIntervalSince(lastPartialApply) >= interval {
                    lastPartialApply = now
                    partialApplies += 1
                    var partialInput = base
                    partialInput.outcomes = collected
                    self.schedulePartialApply(partialInput)
                }
            }
            return collected
        }
    }

    func schedulePartialApply(_ input: LibraryStoreMergeInput) {
        partialApplyInFlight = true
        let generation = indexGeneration
        Task { [weak self] in
            let output = await Task.detached(priority: .utility) {
                LibraryStoreScanWorker.merge(input)
            }.value
            guard let self else { return }
            self.partialApplyInFlight = false
            guard generation == self.indexGeneration else { return }
            self.applyMergeOutput(output, context: nil)
        }
    }

    /// Applies a merge result. `context == nil` means an intermediate (partial) result.
    func applyMergeOutput(_ output: LibraryStoreMergeOutput, context: LibraryStoreScanContext?) {
        let liveFolderIDs = Set(folders.map(\.id))
        let removedFolderIDs = Set(removedFolders.map(\.id))
        let deleted = deletedDuringScan
        let currentTracks = tracksByID
        let currentHidden = hiddenEntries

        func isLive(_ id: String, _ location: TrackLocation) -> Bool {
            if deleted.contains(id) { return false }
            if case .folder(let sourceID, _) = location { return liveFolderIDs.contains(sourceID) }
            return true
        }

        /// Songs of a folder removed while the scan ran: kept out of sight, like removeFolder does.
        func isInRemovedFolder(_ id: String, _ location: TrackLocation) -> Bool {
            !deleted.contains(id) && LibraryStoreScanWorker.isInFolder(location, anyOf: removedFolderIDs)
        }

        // User data may have changed while the scan ran (favourites, play counts): current state wins.
        func withLatestUserData(_ track: Track) -> Track {
            guard let latest = currentTracks[track.id] ?? currentHidden[track.id]?.knownTrack else { return track }
            var updated = track
            updated.isFavorite = latest.isFavorite
            updated.playCount = latest.playCount
            updated.lastPlayedAt = latest.lastPlayedAt
            return updated
        }

        var newTracks = [String: Track](minimumCapacity: output.tracks.count)
        var newHidden = [String: LibraryStoreHiddenEntry](minimumCapacity: output.hidden.count)
        for (id, track) in output.tracks {
            if isLive(id, track.location) {
                newTracks[id] = withLatestUserData(track)
            } else if isInRemovedFolder(id, track.location) {
                let latest = withLatestUserData(track)
                newHidden[id] = LibraryStoreHiddenEntry(
                    location: latest.location,
                    fileSize: latest.fileSize,
                    modificationDate: latest.fileModificationDate,
                    track: latest,
                    lastSeen: currentHidden[id]?.lastSeen ?? Date(),
                    checkedAt: currentHidden[id]?.checkedAt ?? Date()
                )
            }
        }
        for (id, entry) in output.hidden where isLive(id, entry.location) || isInRemovedFolder(id, entry.location) {
            var updated = entry
            if let track = entry.track {
                updated.track = withLatestUserData(track)
            }
            if let retained = entry.retainedTrack {
                updated.retainedTrack = withLatestUserData(retained)
            }
            newHidden[id] = updated
        }

        let removedIDs = Set(currentTracks.keys).subtracting(newTracks.keys)
        let tracksChanged = newTracks != currentTracks
        let hiddenChanged = newHidden != currentHidden

        indexGeneration &+= 1
        if tracksChanged { tracksByID = newTracks }
        if hiddenChanged { hiddenEntries = newHidden }
        let orderChanged = applyIndex(output.index)

        if let context {
            var counts: [UUID: Int] = [:]
            for track in newTracks.values {
                if case .folder(let sourceID, _) = track.location { counts[sourceID, default: 0] += 1 }
            }
            var updatedFolders = folders
            for index in updatedFolders.indices {
                let folderID = updatedFolders[index].id
                if context.scannedFolderIDs.contains(folderID) {
                    updatedFolders[index].isAvailable = true
                    updatedFolders[index].lastScanAt = context.scanDate
                    updatedFolders[index].trackCount = counts[folderID] ?? 0
                } else if context.unavailableFolderIDs.contains(folderID) {
                    updatedFolders[index].isAvailable = false
                    updatedFolders[index].trackCount = counts[folderID] ?? 0
                }
            }
            if updatedFolders != folders {
                folders = updatedFolders
                persistFolders()
            }
            lastScanDate = Date()
            // Folders that resolved during this scan (or went away) change what is watched.
            updateLinkedFoldersWatcher()

            let stillReferenced = Set(newTracks.keys).union(newHidden.keys)
            let artworkToRemove = output.artworkToRemove.subtracting(stillReferenced)
            if !artworkToRemove.isEmpty {
                LibraryStoreScanWorker.removeArtworkInBackground(artworkToRemove)
            }
        }

        if tracksChanged || hiddenChanged || orderChanged {
            persistLibrary()
        }
        if !removedIDs.isEmpty {
            onTracksRemoved?(removedIDs)
        }
        if output.sort != settings.songSort {
            rebuildIndex(tracksOnly: true)
        }
        if let context {
            pruneRemovedFolders(now: context.scanDate)
        }
    }

    /// Resolves (lazily) and returns the access-started root URL of a linked folder.
    /// With `verifyReachable`, returns nil when the folder cannot be listed right now.
    func accessibleRoot(forFolder folderID: UUID, verifyReachable: Bool) -> URL? {
        if let cached = folderAccess[folderID] {
            if !verifyReachable || LibraryStoreScanWorker.isReadableDirectory(cached.url) {
                return cached.url
            }
        }

        guard let index = folders.firstIndex(where: { $0.id == folderID }),
              let resolved = FolderBookmarks.resolve(folders[index].bookmarkData) else {
            return nil
        }

        let resolvedURL = resolved.url
        if let cached = folderAccess[folderID],
           LibraryStoreScanWorker.canonicalPath(of: cached.url) == LibraryStoreScanWorker.canonicalPath(of: resolvedURL) {
            // Same place and already being accessed: nothing to restart.
        } else {
            if let cached = folderAccess[folderID], cached.isAccessing {
                cached.url.stopAccessingSecurityScopedResource()
            }
            let started = resolvedURL.startAccessingSecurityScopedResource()
            folderAccess[folderID] = LibraryStoreFolderAccess(url: resolvedURL, isAccessing: started)
        }

        let root = folderAccess[folderID]?.url ?? resolvedURL

        // Remember where the folder is: recognises it on re-link even if it is offline by then.
        var updatedFolder = folders[index]
        if resolved.isStale, let fresh = try? FolderBookmarks.makeBookmark(for: resolvedURL) {
            updatedFolder.bookmarkData = fresh
        }
        if FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) {
            let currentPath = LibraryStoreScanWorker.canonicalPath(of: root)
            if updatedFolder.canonicalPath != currentPath {
                updatedFolder.canonicalPath = currentPath
            }
        }
        if updatedFolder != folders[index] {
            var updatedFolders = folders
            updatedFolders[index] = updatedFolder
            folders = updatedFolders
            persistFolders()
        }

        if verifyReachable && !LibraryStoreScanWorker.isReadableDirectory(root) {
            return nil
        }
        return root
    }

    func setStatus(_ text: String) {
        if scanStatus != text { scanStatus = text }
    }

    func updateBusyState() {
        let busy = scanTask != nil || activeImports > 0
        if isScanning != busy { isScanning = busy }
        if !busy && scanStatus != nil { scanStatus = nil }
    }

    static var onDeviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
    }

    static func importProblemMessage(unsupported: [String], failed: [String]) -> String? {
        func list(_ names: [String]) -> String {
            let shown = names.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            return names.count > 3 ? shown + " and \(names.count - 3) more" : shown
        }
        var parts: [String] = []
        if unsupported.count == 1 {
            parts.append("\(list(unsupported)) isn’t an audio or video file Musicbox can play.")
        } else if unsupported.count > 1 {
            parts.append("\(unsupported.count) files aren’t audio or video files Musicbox can play: \(list(unsupported)).")
        }
        if failed.count == 1 {
            parts.append("Couldn’t import \(list(failed)). Make sure the file is downloaded and try again.")
        } else if failed.count > 1 {
            parts.append("Couldn’t import \(failed.count) files: \(list(failed)). Make sure they’re downloaded and try again.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Index maintenance

private extension LibraryStore {

    /// Re-sorts (and optionally regroups) the library off the main actor.
    func rebuildIndex(tracksOnly: Bool) {
        indexGeneration &+= 1
        let generation = indexGeneration
        let snapshot = Array(tracksByID.values)
        let sort = settings.songSort
        Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) {
                LibraryStoreIndexing.build(from: snapshot, sort: sort, includeGroups: !tracksOnly)
            }.value
            guard let self, generation == self.indexGeneration else { return }
            if self.applyIndex(index) {
                self.persistLibrary()
            }
        }
    }

    /// Installs a freshly built index, re-mapped through the current `tracksByID` so edits and
    /// removals made while it was being built are honoured. Returns true if the order changed.
    @discardableResult
    func applyIndex(_ index: LibraryStoreIndex) -> Bool {
        let current = tracksByID
        var ordered: [Track] = []
        ordered.reserveCapacity(current.count)
        var included = Set<String>(minimumCapacity: current.count)
        for track in index.tracks {
            if let latest = current[track.id], included.insert(track.id).inserted {
                ordered.append(latest)
            }
        }
        if ordered.count < current.count {
            for track in current.values where !included.contains(track.id) {
                ordered.append(track)
            }
        }

        let previous = tracks
        let orderChanged = previous.count != ordered.count
            || !zip(previous, ordered).allSatisfy { $0.id == $1.id }
        if previous != ordered { tracks = ordered }

        if let builtAlbums = index.albums {
            let remapped = LibraryStore.remapAlbums(builtAlbums, using: current)
            if remapped != albums { albums = remapped }
        }
        if let builtArtists = index.artists {
            let remapped = LibraryStore.remapArtists(builtArtists, using: current)
            if remapped != artists { artists = remapped }
        }

        rebuildPositionMaps()
        refreshDerivedLists()
        return orderChanged
    }

    static func remapAlbums(_ groups: [AlbumGroup], using current: [String: Track]) -> [AlbumGroup] {
        groups.compactMap { group in
            var changed = false
            var members: [Track] = []
            members.reserveCapacity(group.tracks.count)
            for track in group.tracks {
                guard let latest = current[track.id] else { changed = true; continue }
                if latest != track { changed = true }
                members.append(latest)
            }
            if members.isEmpty { return nil }
            return changed ? AlbumGroup(id: group.id, title: group.title, artist: group.artist, tracks: members) : group
        }
    }

    static func remapArtists(_ groups: [ArtistGroup], using current: [String: Track]) -> [ArtistGroup] {
        groups.compactMap { group in
            var changed = false
            var removedAny = false
            var members: [Track] = []
            members.reserveCapacity(group.tracks.count)
            for track in group.tracks {
                guard let latest = current[track.id] else { changed = true; removedAny = true; continue }
                if latest != track { changed = true }
                members.append(latest)
            }
            if members.isEmpty { return nil }
            guard changed else { return group }
            let albumCount = removedAny ? LibraryStoreIndexing.albumCount(of: members) : group.albumCount
            return ArtistGroup(id: group.id, name: group.name, tracks: members, albumCount: albumCount)
        }
    }

    func rebuildPositionMaps() {
        let allTracks = tracks
        var positions = [String: Int](minimumCapacity: allTracks.count)
        for (index, track) in allTracks.enumerated() { positions[track.id] = index }
        trackPositions = positions

        var albumMap = [String: Int](minimumCapacity: allTracks.count)
        for (index, group) in albums.enumerated() {
            for track in group.tracks { albumMap[track.id] = index }
        }
        albumPositions = albumMap

        var artistMap = [String: Int](minimumCapacity: allTracks.count)
        for (index, group) in artists.enumerated() {
            for track in group.tracks { artistMap[track.id] = index }
        }
        artistPositions = artistMap
    }

    /// `membershipChanged == false` means only user data (favourite / play count) changed, so the
    /// "Recently Added" order is still valid and only its track values need refreshing.
    func refreshDerivedLists(membershipChanged: Bool = true) {
        let allTracks = tracks
        var audio: [Track] = []
        var video: [Track] = []
        var favorites: [Track] = []
        var played: [Track] = []
        audio.reserveCapacity(allTracks.count)
        var documentsCount = 0
        var mediaLibraryCount = 0

        for track in allTracks {
            if track.kind == .video { video.append(track) } else { audio.append(track) }
            if track.isFavorite { favorites.append(track) }
            if track.playCount > 0 { played.append(track) }
            switch track.location {
            case .documents: documentsCount += 1
            case .mediaLibrary: mediaLibraryCount += 1
            case .folder: break
            }
        }
        played.sort(by: LibraryStoreIndexing.mostPlayedOrder)
        let mostPlayed = Array(played.prefix(100))
        let recent: [Track]
        if membershipChanged {
            recent = LibraryStoreIndexing.recentlyAdded(from: allTracks, limit: 100)
        } else {
            let lookup = tracksByID
            recent = recentlyAddedTracks.map { lookup[$0.id] ?? $0 }
        }

        if audioTracks != audio { audioTracks = audio }
        if videoTracks != video { videoTracks = video }
        if favoriteTracks != favorites { favoriteTracks = favorites }
        if recentlyAddedTracks != recent { recentlyAddedTracks = recent }
        if mostPlayedTracks != mostPlayed { mostPlayedTracks = mostPlayed }
        if documentsTrackCount != documentsCount { documentsTrackCount = documentsCount }
        if musicLibraryTrackCount != mediaLibraryCount { musicLibraryTrackCount = mediaLibraryCount }
    }

    /// Applies a user-data change to one track everywhere it is shown. Returns true if it changed.
    func mutateTrack(_ id: String, _ change: (inout Track) -> Void) -> Bool {
        guard let original = tracksByID[id] else { return false }
        var track = original
        change(&track)
        guard track != original else { return false }

        tracksByID[id] = track

        if let index = trackPositions[id], index < tracks.count, tracks[index].id == id {
            tracks[index] = track
        } else if let index = tracks.firstIndex(where: { $0.id == id }) {
            tracks[index] = track
            trackPositions[id] = index
        }

        if let groupIndex = albumPositions[id], groupIndex < albums.count {
            let group = albums[groupIndex]
            if let memberIndex = group.tracks.firstIndex(where: { $0.id == id }) {
                var members = group.tracks
                members[memberIndex] = track
                albums[groupIndex] = AlbumGroup(id: group.id, title: group.title, artist: group.artist, tracks: members)
            }
        }

        if let groupIndex = artistPositions[id], groupIndex < artists.count {
            let group = artists[groupIndex]
            if let memberIndex = group.tracks.firstIndex(where: { $0.id == id }) {
                var members = group.tracks
                members[memberIndex] = track
                artists[groupIndex] = ArtistGroup(id: group.id, name: group.name, tracks: members, albumCount: group.albumCount)
            }
        }

        refreshDerivedLists(membershipChanged: false)
        return true
    }

    /// Removes tracks without re-sorting (removal keeps every list in order).
    func removeTracksFromState(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var remaining = tracksByID
        for id in ids { remaining.removeValue(forKey: id) }
        tracksByID = remaining
        tracks = tracks.filter { !ids.contains($0.id) }
        albums = LibraryStore.remapAlbums(albums, using: remaining)
        artists = LibraryStore.remapArtists(artists, using: remaining)
        rebuildPositionMaps()
        refreshDerivedLists()
    }
}

// MARK: - Settings, playlists & persistence

private extension LibraryStore {

    func settingsDidChange(from oldValue: AppSettings, to newValue: AppSettings) {
        JSONStore.save(newValue, to: LibraryStoreFiles.settings)
        if newValue.songSort != oldValue.songSort {
            rebuildIndex(tracksOnly: true)
        }
        if newValue.includeVideos != oldValue.includeVideos
            || newValue.includeMusicLibrary != oldValue.includeMusicLibrary
            || newValue.minimumDuration != oldValue.minimumDuration {
            Task { [weak self] in
                await self?.rescan()
            }
        }
    }

    /// Runs `change` on a copy; if it reports a change, bumps `updatedAt` and persists.
    func updatePlaylist(_ id: UUID, resort: Bool = false, _ change: (inout Playlist) -> Bool) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        var playlist = playlists[index]
        guard change(&playlist) else { return }
        playlist.updatedAt = Date()
        var list = playlists
        list[index] = playlist
        playlists = resort ? LibraryStore.sortedPlaylists(list) : list
        persistPlaylists()
    }

    static func cleanPlaylistName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sortedPlaylists(_ list: [Playlist]) -> [Playlist] {
        list.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func persistPlaylists() {
        JSONStore.save(playlists, to: LibraryStoreFiles.playlists)
    }

    func persistFolders() {
        JSONStore.save(folders, to: LibraryStoreFiles.folders)
    }

    func persistRemovedFolders() {
        JSONStore.save(removedFolders, to: LibraryStoreFiles.removedFolders)
    }

    /// Forgets folders removed longer than `vanishedRetention` ago, with their waiting songs.
    func pruneRemovedFolders(now: Date) {
        let expired = Set(removedFolders.lazy
            .filter { now.timeIntervalSince($0.removedAt) >= LibraryStoreScanWorker.vanishedRetention }
            .map(\.id))
        guard !expired.isEmpty else { return }
        removedFolders.removeAll { expired.contains($0.id) }
        persistRemovedFolders()

        let orphaned = Set(hiddenEntries.lazy
            .filter { LibraryStoreScanWorker.isInFolder($0.value.location, anyOf: expired) }
            .map(\.key))
        guard !orphaned.isEmpty else { return }
        var hidden = hiddenEntries
        for id in orphaned { hidden.removeValue(forKey: id) }
        hiddenEntries = hidden
        LibraryStoreScanWorker.removeArtworkInBackground(orphaned)
        persistLibrary()
    }

    /// Writes library.json (in sorted order) and the hidden-entry cache on a serial background queue.
    /// `keepingAppAwake` holds a background task until the write is on disk.
    func persistLibrary(synchronously: Bool = false, keepingAppAwake: Bool = false) {
        librarySaveTask?.cancel()
        librarySaveTask = nil
        let snapshot = tracks
        let hidden = hiddenEntries
        let work: @Sendable () -> Void = {
            JSONStore.save(snapshot, to: LibraryStoreFiles.library)
            JSONStore.save(hidden, to: LibraryStoreFiles.hidden)
        }
        if synchronously {
            persistenceQueue.sync { work() }
        } else if keepingAppAwake {
            beginProtectedSave()
            persistenceQueue.async { [weak self] in
                work()
                let store = self
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        store?.finishProtectedSave()
                    }
                }
            }
        } else {
            persistenceQueue.async { work() }
        }
    }

    /// While the app is not on screen a delayed save may never run: once playback stops (end of
    /// the queue, sleep timer) iOS suspends the app and may terminate it later. Save right away then.
    func saveUserDataChange(debounce delay: TimeInterval) {
        if UIApplication.shared.applicationState == .active {
            scheduleLibrarySave(after: delay)
        } else {
            persistLibrary(keepingAppAwake: true)
        }
    }

    func beginProtectedSave() {
        protectedSavesInFlight += 1
        guard saveBackgroundTaskID == .invalid else { return }
        saveBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Musicbox.SaveLibrary") { [weak self] in
            MainActor.assumeIsolated {
                self?.endSaveBackgroundTask()
            }
        }
    }

    func finishProtectedSave() {
        protectedSavesInFlight = max(0, protectedSavesInFlight - 1)
        if protectedSavesInFlight == 0 {
            endSaveBackgroundTask()
        }
    }

    func endSaveBackgroundTask() {
        guard saveBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(saveBackgroundTaskID)
        saveBackgroundTaskID = .invalid
    }

    func scheduleLibrarySave(after delay: TimeInterval) {
        librarySaveTask?.cancel()
        librarySaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.persistLibrary()
        }
    }

    func flushPendingLibrarySave() {
        guard librarySaveTask != nil else { return }
        persistLibrary(synchronously: true)
    }

    func installLifecycleObservers() {
        let names: [Notification.Name] = [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification,
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.flushPendingLibrarySave()
                }
            }
            lifecycleObservers.append(token)
        }
    }
}

// MARK: - Supporting types (file-private)

private let libraryLogger = Logger(subsystem: "com.charanraj.musicbox", category: "Library")
private let libraryMaxConcurrentReads = 4

private enum LibraryStoreFiles {
    static let library = "library"
    static let playlists = "playlists"
    static let folders = "folders"
    static let settings = "settings"
    static let hidden = "library-hidden"
    static let removedFolders = "folders-removed"
}

private enum LibraryStoreError: LocalizedError {
    case trackNotFound
    case notDeletable(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .trackNotFound:
            return "This song is no longer in your library."
        case .notDeletable(let title):
            return "“\(title)” isn’t stored in Musicbox’s own folder, so it can’t be deleted from here. Remove it with the Files app instead."
        case .deleteFailed(let title):
            return "Couldn’t delete “\(title)”. Please try again."
        }
    }
}

/// Decodes an element and turns a failure into nil, so one damaged entry never loses the rest.
private struct LibraryStoreLossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

private struct LibraryStoreFolderAccess {
    let url: URL
    let isAccessing: Bool
}

/// A file (or Music library item) that is known but not currently in the library.
///   - `track != nil`: playable but filtered out (videos off, too short) or recently vanished
///     (kept ~30 days with its user data and artwork, e.g. for evicted iCloud files, or songs of
///     a folder the user removed).
///   - `track == nil`: the file could not be played; re-checked after a day or when it changes.
///     If it was a song before (`retainedTrack`), it is re-checked on every scan instead, and its
///     user data is kept for ~30 days, so a temporary read failure never loses it.
private struct LibraryStoreHiddenEntry: Codable, Equatable, Sendable {
    var location: TrackLocation
    var fileSize: Int64
    var modificationDate: Date?
    var track: Track?
    var lastSeen: Date
    var checkedAt: Date
    /// Unplayable entries only: the song as it was before its file stopped reading. Never put back
    /// into the library as is; it only supplies the user data when the file reads again.
    var retainedTrack: Track? = nil
    /// When `retainedTrack` was first kept.
    var retainedSince: Date? = nil

    /// Whatever song data this entry carries (a hidden song, or one that could not be read).
    var knownTrack: Track? { track ?? retainedTrack }
}

/// A linked folder the user removed. Its songs stay in the hidden entries (with user data and
/// artwork) for `vanishedRetention`; linking the same folder again within that time reuses the
/// folder's ID, so the songs get their old IDs back and playlists find them again.
private struct LibraryStoreRemovedFolder: Codable, Equatable, Sendable {
    let id: UUID
    let canonicalPath: String
    let removedAt: Date
}

private struct LibraryStoreScanRoot {
    let sourceID: UUID?
    let url: URL
    let name: String
}

private struct LibraryStoreRootScan: Sendable {
    let sourceID: UUID?
    let canonicalRoot: String
    let files: [ScannedFile]
    /// Some media file was modified moments ago or is still empty: probably still being copied.
    let hasFilesInFlight: Bool
}

private struct LibraryStoreReadRequest: Sendable {
    let file: ScannedFile
    let hadArtwork: Bool
}

private struct LibraryStoreReadOutcome: Sendable {
    let id: String
    let file: ScannedFile
    let metadata: TrackMetadata      // artworkData stripped (already stored)
    let hasArtwork: Bool
}

private struct LibraryStoreMediaResult: Sendable {
    let location: TrackLocation
    let metadata: TrackMetadata      // artworkData stripped (already stored)
    let dateAdded: Date
    let hasArtwork: Bool
}

private struct LibraryStoreScanPlan: Sendable {
    let files: [ScannedFile]
    let toRead: [LibraryStoreReadRequest]
}

private struct LibraryStoreScanContext {
    let scanDate: Date
    let scannedFolderIDs: Set<UUID>
    let unavailableFolderIDs: Set<UUID>
}

private struct LibraryStoreMergeInput: Sendable {
    var files: [ScannedFile]
    var outcomes: [String: LibraryStoreReadOutcome]
    var mediaItems: [LibraryStoreMediaResult]
    var oldTracks: [String: Track]
    var oldHidden: [String: LibraryStoreHiddenEntry]
    var unavailableFolderIDs: Set<UUID>
    var settings: AppSettings
    var scanDate: Date
    /// Partial merges never drop anything; they only add/update what has been read so far.
    var isPartial: Bool
}

private struct LibraryStoreMergeOutput: Sendable {
    let tracks: [String: Track]
    let hidden: [String: LibraryStoreHiddenEntry]
    let artworkToRemove: Set<String>
    let index: LibraryStoreIndex
    let sort: SongSort
}

private struct LibraryStoreIndex: Sendable {
    let tracks: [Track]
    let albums: [AlbumGroup]?
    let artists: [ArtistGroup]?
}

// MARK: - Scan worker (nonisolated, pure where possible)

private enum LibraryStoreScanWorker {
    static let unknownArtist = "Unknown Artist"
    static let unknownAlbum = "Unknown Album"
    /// Vanished tracks keep their user data this long in case they come back.
    static let vanishedRetention: TimeInterval = 30 * 24 * 60 * 60
    /// Unplayable files are re-checked after this long even if unchanged.
    static let unplayableRetryInterval: TimeInterval = 24 * 60 * 60
    /// `lastSeen` of hidden-but-present entries is refreshed at most this often (avoids a write per scan).
    static let lastSeenRefreshInterval: TimeInterval = 24 * 60 * 60
    /// A media file modified this recently (or still empty) is taken to be still arriving.
    static let inFlightWindow: TimeInterval = 6
    /// While files are arriving, the library is scanned again after this long…
    static let settleDelay: TimeInterval = 3
    /// …at most this many times per request (a copy of about a minute and a half).
    static let maxSettlePasses = 20

    // MARK: Paths

    static func canonicalPath(of url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// The path a bookmark points to, read from the bookmark itself (works while the folder is
    /// offline). The folder is not there to resolve symlinks, so the "/private" firmlink prefix is
    /// dropped by hand to match `canonicalPath(of:)` of the folder when it is present.
    static func canonicalPath(fromBookmark data: Data) -> String? {
        guard !data.isEmpty,
              let values = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data),
              let storedPath = values.path, !storedPath.isEmpty else {
            return nil
        }
        var path = canonicalPath(of: URL(filePath: storedPath, directoryHint: .isDirectory))
        if path.hasPrefix("/private/") {
            path.removeFirst("/private".count)
        }
        return path
    }

    static func isReadableDirectory(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let path = url.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return (try? fileManager.contentsOfDirectory(atPath: path)) != nil
    }

    static func displayName(for url: URL) -> String {
        if let localized = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localized.isEmpty {
            return localized
        }
        let name = url.lastPathComponent
        return name.isEmpty ? "Folder" : name
    }

    static func relativePath(of location: TrackLocation) -> String? {
        switch location {
        case .documents(let relativePath), .folder(_, let relativePath):
            return relativePath
        case .mediaLibrary:
            return nil
        }
    }

    static func isInFolder(_ location: TrackLocation, _ folderID: UUID) -> Bool {
        if case .folder(let sourceID, _) = location { return sourceID == folderID }
        return false
    }

    static func isInFolder(_ location: TrackLocation, anyOf folderIDs: Set<UUID>) -> Bool {
        if case .folder(let sourceID, _) = location { return folderIDs.contains(sourceID) }
        return false
    }

    // MARK: Enumeration & planning

    static func enumerate(root: URL, sourceID: UUID?) -> LibraryStoreRootScan {
        let result = FileScanner.scanWithDetails(root: root, sourceID: sourceID)
        let now = Date()
        func isRecent(_ date: Date?) -> Bool {
            guard let date else { return false }
            return abs(now.timeIntervalSince(date)) < inFlightWindow
        }
        let hasFilesInFlight = isRecent(result.newestEmptyFileModificationDate)
            || result.files.contains { isRecent($0.modificationDate) }
        return LibraryStoreRootScan(
            sourceID: sourceID,
            canonicalRoot: canonicalPath(of: root),
            files: result.files,
            hasFilesInFlight: hasFilesInFlight
        )
    }

    static func datesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return abs(l.timeIntervalSince(r)) < 0.001
        default:
            return false
        }
    }

    static func isSameFile(size: Int64, date: Date?, as file: ScannedFile) -> Bool {
        size == file.fileSize && datesMatch(date, file.modificationDate)
    }

    /// Dedupes files that are reachable through more than one root (Documents wins, then folders
    /// in link order) and picks the ones whose metadata must be (re)read.
    static func plan(
        roots: [LibraryStoreRootScan],
        oldTracks: [String: Track],
        oldHidden: [String: LibraryStoreHiddenEntry],
        now: Date
    ) -> LibraryStoreScanPlan {
        let verifyArtwork = artworkCacheLooksIncomplete(oldTracks: oldTracks)
        var seenPaths = Set<String>()
        var seenIDs = Set<String>()
        var files: [ScannedFile] = []
        var toRead: [LibraryStoreReadRequest] = []

        for root in roots {
            for file in root.files {
                if let path = relativePath(of: file.location) {
                    guard seenPaths.insert(root.canonicalRoot + "/" + path).inserted else { continue }
                }
                let id = file.location.stableID
                guard seenIDs.insert(id).inserted else { continue }
                files.append(file)

                if let old = oldTracks[id], isSameFile(size: old.fileSize, date: old.fileModificationDate, as: file) {
                    if verifyArtwork && old.hasArtwork && !ArtworkCache.shared.hasArtwork(for: id) {
                        toRead.append(LibraryStoreReadRequest(file: file, hadArtwork: true))
                    }
                    continue
                }
                if let entry = oldHidden[id], isSameFile(size: entry.fileSize, date: entry.modificationDate, as: file) {
                    if let hiddenTrack = entry.track {
                        if verifyArtwork && hiddenTrack.hasArtwork && !ArtworkCache.shared.hasArtwork(for: id) {
                            toRead.append(LibraryStoreReadRequest(file: file, hadArtwork: true))
                        }
                        continue
                    }
                    // A song that stopped reading is retried on every scan (the failure is often
                    // temporary: drive or share dropped, file busy); other files once a day.
                    if entry.retainedTrack == nil, now.timeIntervalSince(entry.checkedAt) < unplayableRetryInterval {
                        continue
                    }
                }
                let previous = oldTracks[id] ?? oldHidden[id]?.knownTrack
                toRead.append(LibraryStoreReadRequest(file: file, hadArtwork: previous?.hasArtwork ?? false))
            }
        }
        return LibraryStoreScanPlan(files: files, toRead: toRead)
    }

    /// The artwork cache lives in Caches, which iOS may purge. Spot-check a sample of tracks that
    /// should have artwork; if any is missing, the plan re-reads every track whose artwork is gone.
    static func artworkCacheLooksIncomplete(oldTracks: [String: Track]) -> Bool {
        var sample: [String] = []
        for (id, track) in oldTracks where track.hasArtwork {
            if case .mediaLibrary = track.location { continue }
            sample.append(id)
            if sample.count >= 240 { break }
        }
        guard !sample.isEmpty else { return false }
        let step = max(1, sample.count / 12)
        var index = 0
        while index < sample.count {
            if !ArtworkCache.shared.hasArtwork(for: sample[index]) { return true }
            index += step
        }
        return false
    }

    // MARK: Reading

    static func read(_ request: LibraryStoreReadRequest) async -> LibraryStoreReadOutcome {
        let file = request.file
        let id = file.location.stableID
        var metadata = await MetadataReader.read(url: file.url)
        var hasArtwork = false
        if metadata.hasAudio || metadata.hasVideo, let data = metadata.artworkData, !data.isEmpty {
            ArtworkCache.shared.store(data, for: id)
            hasArtwork = true
        } else if request.hadArtwork {
            ArtworkCache.shared.remove(for: id)
        }
        metadata.artworkData = nil
        return LibraryStoreReadOutcome(id: id, file: file, metadata: metadata, hasArtwork: hasArtwork)
    }

    static func scanMediaLibrary(knownArtworkIDs: Set<String>) -> [LibraryStoreMediaResult] {
        // Artwork that is already cached is not rendered again (a JPEG per album on every scan).
        var cachedArtworkIDs = Set<String>()
        let items = MediaLibraryScanner.scan(needsArtwork: { id in
            if knownArtworkIDs.contains(id) && ArtworkCache.shared.hasArtwork(for: id) {
                cachedArtworkIDs.insert(id)
                return false
            }
            return true
        })
        var results: [LibraryStoreMediaResult] = []
        results.reserveCapacity(items.count)
        for item in items {
            let id = item.location.stableID
            var metadata = item.metadata
            var hasArtwork = cachedArtworkIDs.contains(id)
            if !hasArtwork, let data = metadata.artworkData, !data.isEmpty {
                ArtworkCache.shared.store(data, for: id)
                hasArtwork = true
            }
            metadata.artworkData = nil
            results.append(LibraryStoreMediaResult(
                location: item.location,
                metadata: metadata,
                dateAdded: item.dateAdded,
                hasArtwork: hasArtwork
            ))
        }
        return results
    }

    static func removeArtworkInBackground(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        Task.detached(priority: .utility) {
            for id in ids {
                ArtworkCache.shared.remove(for: id)
            }
        }
    }

    // MARK: Track building

    static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func sanitizedDuration(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : 0
    }

    static func fileTitle(of file: ScannedFile) -> String {
        let title = file.url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    static func makeTrack(file: ScannedFile, outcome: LibraryStoreReadOutcome, previous: Track?, scanDate: Date) -> Track {
        let metadata = outcome.metadata
        // An .mp4/.mov that only carries sound is music, not a video.
        let kind: MediaKind = file.kind == .video && !metadata.hasVideo ? .audio : file.kind
        let fileExtension = file.fileExtension.isEmpty
            ? file.url.pathExtension.lowercased()
            : file.fileExtension.lowercased()
        return Track(
            id: file.location.stableID,
            location: file.location,
            title: cleaned(metadata.title) ?? fileTitle(of: file),
            artist: cleaned(metadata.artist) ?? unknownArtist,
            album: cleaned(metadata.album) ?? unknownAlbum,
            albumArtist: cleaned(metadata.albumArtist),
            genre: cleaned(metadata.genre),
            trackNumber: metadata.trackNumber.flatMap { $0 > 0 ? $0 : nil },
            duration: sanitizedDuration(metadata.duration),
            kind: kind,
            fileExtension: fileExtension,
            fileSize: file.fileSize,
            fileModificationDate: file.modificationDate,
            dateAdded: previous?.dateAdded ?? scanDate,
            hasArtwork: outcome.hasArtwork,
            isFavorite: previous?.isFavorite ?? false,
            playCount: previous?.playCount ?? 0,
            lastPlayedAt: previous?.lastPlayedAt
        )
    }

    static func makeTrack(media item: LibraryStoreMediaResult, previous: Track?) -> Track {
        let metadata = item.metadata
        var fileExtension = "m4a"
        if case .mediaLibrary(_, let assetURL) = item.location,
           let url = URL(string: assetURL), !url.pathExtension.isEmpty {
            fileExtension = url.pathExtension.lowercased()
        }
        return Track(
            id: item.location.stableID,
            location: item.location,
            title: cleaned(metadata.title) ?? "Unknown Title",
            artist: cleaned(metadata.artist) ?? unknownArtist,
            album: cleaned(metadata.album) ?? unknownAlbum,
            albumArtist: cleaned(metadata.albumArtist),
            genre: cleaned(metadata.genre),
            trackNumber: metadata.trackNumber.flatMap { $0 > 0 ? $0 : nil },
            duration: sanitizedDuration(metadata.duration),
            kind: metadata.hasVideo ? .video : .audio,
            fileExtension: fileExtension,
            fileSize: 0,
            fileModificationDate: nil,
            dateAdded: previous?.dateAdded ?? item.dateAdded,
            hasArtwork: item.hasArtwork,
            isFavorite: previous?.isFavorite ?? false,
            playCount: previous?.playCount ?? 0,
            lastPlayedAt: previous?.lastPlayedAt
        )
    }

    static func passesFilters(_ track: Track, _ settings: AppSettings) -> Bool {
        if track.kind == .video && !settings.includeVideos { return false }
        if settings.minimumDuration > 0 && track.duration > 0 && track.duration < settings.minimumDuration {
            return false
        }
        return true
    }

    // MARK: Merge

    /// Implements the rescan merge rules. Pure: reads only its input.
    static func merge(_ input: LibraryStoreMergeInput) -> LibraryStoreMergeOutput {
        let settings = input.settings
        let now = input.scanDate
        var tracks = [String: Track](minimumCapacity: input.files.count + input.mediaItems.count)
        var hidden: [String: LibraryStoreHiddenEntry] = [:]
        var seen = Set<String>(minimumCapacity: input.files.count + input.mediaItems.count)

        func refreshedLastSeen(_ previous: LibraryStoreHiddenEntry?) -> Date {
            guard let previous else { return now }
            return now.timeIntervalSince(previous.lastSeen) > lastSeenRefreshInterval ? now : previous.lastSeen
        }

        func place(_ track: Track, previousEntry: LibraryStoreHiddenEntry?, checkedAt: Date) {
            if passesFilters(track, settings) {
                tracks[track.id] = track
            } else {
                hidden[track.id] = LibraryStoreHiddenEntry(
                    location: track.location,
                    fileSize: track.fileSize,
                    modificationDate: track.fileModificationDate,
                    track: track,
                    lastSeen: refreshedLastSeen(previousEntry),
                    checkedAt: checkedAt
                )
            }
        }

        // Files on disk.
        for file in input.files {
            let id = file.location.stableID
            seen.insert(id)
            let oldTrack = input.oldTracks[id]
            let oldEntry = input.oldHidden[id]

            if let outcome = input.outcomes[id] {
                if outcome.metadata.hasAudio || outcome.metadata.hasVideo {
                    let previous = oldTrack ?? oldEntry?.knownTrack
                    let track = makeTrack(file: file, outcome: outcome, previous: previous, scanDate: now)
                    place(track, previousEntry: nil, checkedAt: now)
                } else if let oldTrack, isSameFile(size: oldTrack.fileSize, date: oldTrack.fileModificationDate, as: file) {
                    // The very file that played before could not be read this time (only its
                    // artwork was being re-checked): a temporary problem, so keep the song as it was.
                    place(oldTrack, previousEntry: nil, checkedAt: now)
                } else if let oldEntry, let hiddenTrack = oldEntry.track,
                          isSameFile(size: oldEntry.fileSize, date: oldEntry.modificationDate, as: file) {
                    place(hiddenTrack, previousEntry: oldEntry, checkedAt: oldEntry.checkedAt)
                } else {
                    // Unplayable now. A song keeps its user data (favourite, play count, date
                    // added) for a while, so it comes back intact once the file reads again.
                    var retained: Track? = oldTrack ?? oldEntry?.track
                    var retainedSince: Date? = retained == nil ? nil : now
                    if retained == nil, let carried = oldEntry?.retainedTrack {
                        let since = oldEntry?.retainedSince ?? now
                        if now.timeIntervalSince(since) < vanishedRetention {
                            retained = carried
                            retainedSince = since
                        }
                    }
                    if let oldEntry, retained != nil, oldEntry.track == nil,
                       oldEntry.retainedTrack == retained, oldEntry.retainedSince == retainedSince,
                       isSameFile(size: oldEntry.fileSize, date: oldEntry.modificationDate, as: file) {
                        // The same song failed to read again (it is retried on every scan): nothing
                        // changed, so the entry stays equal and the library is not rewritten.
                        var entry = oldEntry
                        entry.lastSeen = refreshedLastSeen(oldEntry)
                        hidden[id] = entry
                    } else {
                        hidden[id] = LibraryStoreHiddenEntry(
                            location: file.location,
                            fileSize: file.fileSize,
                            modificationDate: file.modificationDate,
                            track: nil,
                            lastSeen: now,
                            checkedAt: now,
                            retainedTrack: retained,
                            retainedSince: retainedSince
                        )
                    }
                }
            } else if let oldTrack, isSameFile(size: oldTrack.fileSize, date: oldTrack.fileModificationDate, as: file) {
                place(oldTrack, previousEntry: nil, checkedAt: now)
            } else if let oldEntry, isSameFile(size: oldEntry.fileSize, date: oldEntry.modificationDate, as: file) {
                if let hiddenTrack = oldEntry.track {
                    place(hiddenTrack, previousEntry: oldEntry, checkedAt: oldEntry.checkedAt)
                } else {
                    var entry = oldEntry
                    entry.lastSeen = refreshedLastSeen(oldEntry)
                    hidden[id] = entry
                }
            } else if let oldTrack {
                // Changed but not read yet (partial merge): keep the previous version for now.
                tracks[id] = oldTrack
            } else if let oldEntry {
                hidden[id] = oldEntry
            }
        }

        // Music library items.
        for item in input.mediaItems {
            let id = item.location.stableID
            guard seen.insert(id).inserted else { continue }
            let previousEntry = input.oldHidden[id]
            let previous = input.oldTracks[id] ?? previousEntry?.track
            // Filtered-out items keep their entry's dates, so an unchanged one compares equal.
            place(makeTrack(media: item, previous: previous), previousEntry: previousEntry, checkedAt: previousEntry?.checkedAt ?? now)
        }

        // Tracks that were not found this time.
        var artworkToRemove = Set<String>()
        for (id, oldTrack) in input.oldTracks where !seen.contains(id) {
            if input.isPartial || isInFolder(oldTrack.location, anyOf: input.unavailableFolderIDs) {
                // Offline folders keep their tracks; partial merges never drop anything.
                tracks[id] = oldTrack
                continue
            }
            hidden[id] = LibraryStoreHiddenEntry(
                location: oldTrack.location,
                fileSize: oldTrack.fileSize,
                modificationDate: oldTrack.fileModificationDate,
                track: oldTrack,
                lastSeen: now,
                checkedAt: now
            )
        }
        for (id, entry) in input.oldHidden where !seen.contains(id) && tracks[id] == nil && hidden[id] == nil {
            if input.isPartial || isInFolder(entry.location, anyOf: input.unavailableFolderIDs) {
                hidden[id] = entry
                continue
            }
            if entry.knownTrack != nil && now.timeIntervalSince(entry.lastSeen) < vanishedRetention {
                hidden[id] = entry
            } else {
                artworkToRemove.insert(id)
            }
        }

        let index = LibraryStoreIndexing.build(from: Array(tracks.values), sort: settings.songSort, includeGroups: true)
        return LibraryStoreMergeOutput(
            tracks: tracks,
            hidden: hidden,
            artworkToRemove: artworkToRemove,
            index: index,
            sort: settings.songSort
        )
    }
}

// MARK: - Sorting & grouping (nonisolated)

private enum LibraryStoreIndexing {
    static let unknownArtist = LibraryStoreScanWorker.unknownArtist
    static let unknownAlbum = LibraryStoreScanWorker.unknownAlbum

    static func build(from tracks: [Track], sort: SongSort, includeGroups: Bool) -> LibraryStoreIndex {
        LibraryStoreIndex(
            tracks: sorted(tracks, by: sort),
            albums: includeGroups ? albums(from: tracks) : nil,
            artists: includeGroups ? artists(from: tracks) : nil
        )
    }

    /// Sorts with `localizedStandardCompare` on pre-bridged strings (one bridge per track, not per comparison).
    static func sorted(_ tracks: [Track], by sort: SongSort) -> [Track] {
        guard tracks.count > 1 else { return tracks }
        let titles = tracks.map { NSString(string: $0.title) }
        let artistNames = tracks.map { NSString(string: $0.artist) }
        let albumNames = tracks.map { NSString(string: $0.album) }
        var order = Array(0..<tracks.count)

        func compare(_ keys: [NSString], _ i: Int, _ j: Int) -> ComparisonResult {
            keys[i].localizedStandardCompare(keys[j] as String)
        }

        switch sort {
        case .title:
            order.sort { i, j in
                let byTitle = compare(titles, i, j)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                let byArtist = compare(artistNames, i, j)
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                return tracks[i].id < tracks[j].id
            }
        case .artist:
            order.sort { i, j in
                let unknownI = tracks[i].artist == unknownArtist
                let unknownJ = tracks[j].artist == unknownArtist
                if unknownI != unknownJ { return !unknownI }
                let byArtist = compare(artistNames, i, j)
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                let byAlbum = compare(albumNames, i, j)
                if byAlbum != .orderedSame { return byAlbum == .orderedAscending }
                let numberI = tracks[i].trackNumber ?? Int.max
                let numberJ = tracks[j].trackNumber ?? Int.max
                if numberI != numberJ { return numberI < numberJ }
                let byTitle = compare(titles, i, j)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return tracks[i].id < tracks[j].id
            }
        case .album:
            order.sort { i, j in
                let unknownI = tracks[i].album == unknownAlbum
                let unknownJ = tracks[j].album == unknownAlbum
                if unknownI != unknownJ { return !unknownI }
                let byAlbum = compare(albumNames, i, j)
                if byAlbum != .orderedSame { return byAlbum == .orderedAscending }
                let byArtist = compare(artistNames, i, j)
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                let numberI = tracks[i].trackNumber ?? Int.max
                let numberJ = tracks[j].trackNumber ?? Int.max
                if numberI != numberJ { return numberI < numberJ }
                let byTitle = compare(titles, i, j)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return tracks[i].id < tracks[j].id
            }
        case .dateAdded:
            order.sort { i, j in
                if tracks[i].dateAdded != tracks[j].dateAdded { return tracks[i].dateAdded > tracks[j].dateAdded }
                let modifiedI = tracks[i].fileModificationDate ?? .distantPast
                let modifiedJ = tracks[j].fileModificationDate ?? .distantPast
                if modifiedI != modifiedJ { return modifiedI > modifiedJ }
                let byTitle = compare(titles, i, j)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return tracks[i].id < tracks[j].id
            }
        case .duration:
            order.sort { i, j in
                if tracks[i].duration != tracks[j].duration { return tracks[i].duration > tracks[j].duration }
                let byTitle = compare(titles, i, j)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return tracks[i].id < tracks[j].id
            }
        }
        return order.map { tracks[$0] }
    }

    /// The `limit` most recently added tracks (sorts indices, not whole tracks).
    static func recentlyAdded(from tracks: [Track], limit: Int) -> [Track] {
        var order = Array(tracks.indices)
        order.sort { recentlyAddedOrder(tracks[$0], tracks[$1]) }
        return order.prefix(limit).map { tracks[$0] }
    }

    /// Newest first; files added in the same scan fall back to their modification date.
    static func recentlyAddedOrder(_ a: Track, _ b: Track) -> Bool {
        if a.dateAdded != b.dateAdded { return a.dateAdded > b.dateAdded }
        let modifiedA = a.fileModificationDate ?? .distantPast
        let modifiedB = b.fileModificationDate ?? .distantPast
        if modifiedA != modifiedB { return modifiedA > modifiedB }
        let byTitle = a.title.localizedStandardCompare(b.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.id < b.id
    }

    static func mostPlayedOrder(_ a: Track, _ b: Track) -> Bool {
        if a.playCount != b.playCount { return a.playCount > b.playCount }
        let playedA = a.lastPlayedAt ?? .distantPast
        let playedB = b.lastPlayedAt ?? .distantPast
        if playedA != playedB { return playedA > playedB }
        let byTitle = a.title.localizedStandardCompare(b.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.id < b.id
    }

    static func albumArtistOrArtist(_ track: Track) -> String {
        if let albumArtist = track.albumArtist, !albumArtist.isEmpty { return albumArtist }
        return track.artist
    }

    static func albumTrackOrder(_ a: Track, _ b: Track) -> Bool {
        let numberA = a.trackNumber ?? Int.max
        let numberB = b.trackNumber ?? Int.max
        if numberA != numberB { return numberA < numberB }
        let byTitle = a.title.localizedStandardCompare(b.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.id < b.id
    }

    static func artistTrackOrder(_ a: Track, _ b: Track) -> Bool {
        let unknownA = a.album == unknownAlbum
        let unknownB = b.album == unknownAlbum
        if unknownA != unknownB { return !unknownA }
        let byAlbum = a.album.localizedStandardCompare(b.album)
        if byAlbum != .orderedSame { return byAlbum == .orderedAscending }
        return albumTrackOrder(a, b)
    }

    static func albumCount(of tracks: [Track]) -> Int {
        Set(tracks.map { $0.album.lowercased() }).count
    }

    static func albums(from tracks: [Track]) -> [AlbumGroup] {
        var buckets: [String: [Track]] = [:]
        for track in tracks {
            let key = (track.album + "|" + albumArtistOrArtist(track)).lowercased()
            buckets[key, default: []].append(track)
        }
        var groups: [AlbumGroup] = []
        groups.reserveCapacity(buckets.count)
        for (key, members) in buckets {
            let ordered = members.sorted(by: albumTrackOrder)
            guard let first = ordered.first else { continue }
            groups.append(AlbumGroup(id: key, title: first.album, artist: albumArtistOrArtist(first), tracks: ordered))
        }
        groups.sort { a, b in
            let unknownA = a.title == unknownAlbum
            let unknownB = b.title == unknownAlbum
            if unknownA != unknownB { return !unknownA }
            let byTitle = a.title.localizedStandardCompare(b.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            let byArtist = a.artist.localizedStandardCompare(b.artist)
            if byArtist != .orderedSame { return byArtist == .orderedAscending }
            return a.id < b.id
        }
        return groups
    }

    static func artists(from tracks: [Track]) -> [ArtistGroup] {
        var buckets: [String: [Track]] = [:]
        for track in tracks {
            buckets[track.artist.lowercased(), default: []].append(track)
        }
        var groups: [ArtistGroup] = []
        groups.reserveCapacity(buckets.count)
        for (key, members) in buckets {
            let ordered = members.sorted(by: artistTrackOrder)
            guard let first = ordered.first else { continue }
            groups.append(ArtistGroup(id: key, name: first.artist, tracks: ordered, albumCount: albumCount(of: ordered)))
        }
        groups.sort { a, b in
            let unknownA = a.name == unknownArtist
            let unknownB = b.name == unknownArtist
            if unknownA != unknownB { return !unknownA }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id < b.id
        }
        return groups
    }
}
