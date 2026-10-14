import SwiftUI
import Observation
import CryptoKit
import os

/// Finds, caches and serves lyrics for tracks. Resolution order: imported file → `.lrc` sidecar →
/// lyrics embedded in the media file → LRCLIB (only when `onlineLookupEnabled`).
///
/// All disk, parsing and network work runs off the main actor; this class only publishes results.
@MainActor @Observable
final class LyricsStore {

    // MARK: - Public state

    /// Persisted in UserDefaults key "lyrics.onlineLookup". Off for new installs (privacy): nothing
    /// leaves the device until the user turns it on. A value an existing install saved is kept.
    var onlineLookupEnabled: Bool {
        didSet {
            guard onlineLookupEnabled != oldValue else { return }
            // Read by running resolutions before every request: turning lookup off stops the
            // lookups already under way, not just the next ones.
            onlineGate.isOpen = onlineLookupEnabled
            UserDefaults.standard.set(onlineLookupEnabled, forKey: LyricsStoreConstants.onlineLookupKey)
            if onlineLookupEnabled {
                retryTracksWaitingForOnlineLookup()
            }
        }
    }

    /// Number of tracks with saved lyrics (imported, local or found online).
    private(set) var cachedCount: Int = 0

    // MARK: - Private state

    private var states: [String: LyricsState] = [:]
    private var offsets: [String: TimeInterval] = [:]

    private let library: LibraryStore
    private let disk = LyricsDiskCache()
    /// Thread-safe mirror of `onlineLookupEnabled` for resolutions running off the main actor.
    private let onlineGate: LyricsOnlineGate

    @ObservationIgnored private var flights: [String: LyricsFlight] = [:]
    /// Bumped by `clearCache()`; writes from resolutions started before a clear are dropped.
    @ObservationIgnored private var cacheGeneration = 0
    @ObservationIgnored private var offsetsLoaded = false
    @ObservationIgnored private var offsetsEditedBeforeLoad: Set<String> = []

    // MARK: - Init

    init(library: LibraryStore) {
        self.library = library
        let enabled = UserDefaults.standard.object(forKey: LyricsStoreConstants.onlineLookupKey) as? Bool ?? false
        self.onlineGate = LyricsOnlineGate(isOpen: enabled)
        self.onlineLookupEnabled = enabled

        let disk = self.disk
        Task { [weak self] in
            let initial = await disk.initialState()
            self?.applyInitialState(offsets: initial.offsets, count: initial.count, generation: 0)
        }
    }

    // MARK: - Reading

    func state(for trackID: String) -> LyricsState {
        states[trackID] ?? .idle
    }

    func lyrics(for trackID: String) -> Lyrics? {
        if case .loaded(let lyrics) = states[trackID] {
            return lyrics
        }
        return nil
    }

    // MARK: - Loading

    /// Resolves by the priority order above. Sets state .loading → result. Dedupes concurrent calls
    /// for the same track. Uses the disk cache unless `force`. Local results are cached with a
    /// fingerprint (fileSize + fileModificationDate + sidecar mtime) and re-resolved when it changes.
    /// Online hits cached forever; online "not found" cached 3 days (force bypasses).
    /// Network errors → .failed("No internet connection — lyrics will load when you're online.")
    /// only if nothing local was found (else show local).
    func load(_ track: Track, force: Bool = false) async {
        let id = track.id
        let flight: LyricsFlight
        if let running = flights[id], running.isForced || !force {
            running.isVisible = true
            flight = running
        } else {
            flight = startFlight(for: track, force: force, visible: true)
        }

        switch states[id] ?? .idle {
        case .loading:
            break
        case .failed:
            states[id] = .loading
        case .idle:
            if force {
                states[id] = .loading
            } else {
                // Cached answers arrive within a few milliseconds: only show a spinner if it takes longer.
                scheduleLoadingIndicator(for: id, token: flight.token)
            }
        case .loaded, .notFound, .offlineDisabled:
            // A plain revisit keeps showing the current answer while it is re-validated.
            if force { states[id] = .loading }
        }

        await flight.task.value
    }

    /// Background warm-up for the next song: same as load but never sets .loading/.failed states
    /// visibly for other tracks and never throws. No-op if cached or already loading.
    func prefetch(_ track: Track) {
        let id = track.id
        guard flights[id] == nil else { return }
        switch states[id] ?? .idle {
        case .idle, .failed:
            startFlight(for: track, force: false, visible: false)
        case .loading, .loaded, .notFound, .offlineDisabled:
            return
        }
    }

    // MARK: - Import

    /// User-picked .lrc/.txt (from .fileImporter): security scope start/stop, read as UTF-8 (fallback
    /// ISO Latin-1 / UTF-16), LRC → synced else plain. Saved as .imported (survives rescans).
    /// Returns false (and leaves state unchanged) if the file has no usable text.
    @discardableResult
    func importLyrics(from url: URL, for track: Track) async -> Bool {
        let imported = await LyricsIO.run { LyricsLocalFiles.importedLyrics(from: url) }
        guard let imported else { return false }

        let id = track.id
        if let flight = flights.removeValue(forKey: id) {
            flight.task.cancel()
        }
        states[id] = .loaded(imported)

        let entry = LyricsCacheEntry(
            trackID: id,
            kind: .lyrics,
            lyrics: imported,
            fingerprint: "",
            fetchedAt: Date(),
            isImported: true,
            onlineQuery: nil,
            onlineCheckedAt: nil
        )
        // Enqueued before this function suspends, so any later resolution reads the imported entry.
        let disk = self.disk
        let generation = cacheGeneration
        let count = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            disk.save(entry, generation: generation) { continuation.resume(returning: $0) }
        }
        if let count { cachedCount = count }
        return true
    }

    /// Removes an imported override (falls back to other sources on next load).
    func removeImportedLyrics(for track: Track) async {
        let id = track.id
        let disk = self.disk
        let generation = cacheGeneration
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<LyricsRemoval, Never>) in
            disk.removeImportedEntry(for: id, generation: generation) { continuation.resume(returning: $0) }
        }
        cachedCount = outcome.count
        guard outcome.removed else { return }

        if let flight = flights.removeValue(forKey: id) {
            flight.task.cancel()
        }
        states[id] = .loading
        await load(track)
    }

    /// "Wrong Lyrics": the lyrics LRCLIB gave this song belong to a different song. They are
    /// dropped and never chosen for this song again (other songs keep theirs), then the song is
    /// looked up again (local sources first). No-op unless the song shows lyrics from LRCLIB.
    func rejectOnlineLyrics(for track: Track) async {
        let id = track.id
        guard let current = lyrics(for: id), current.source == .online else { return }
        let digest = LyricsDigest.of(current)

        if let flight = flights.removeValue(forKey: id) {
            flight.task.cancel()
        }
        states[id] = .loading

        let disk = self.disk
        let generation = cacheGeneration
        let count = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            disk.rejectOnlineLyrics(digest, for: id, generation: generation) { continuation.resume(returning: $0) }
        }
        if let count, generation == cacheGeneration { cachedCount = count }
        await load(track, force: true)
    }

    // MARK: - Timing offsets

    /// User timing adjustment in seconds for a track (positive = lyrics later). Persisted.
    func offset(for trackID: String) -> TimeInterval {
        offsets[trackID] ?? 0
    }

    func adjustOffset(for trackID: String, by delta: TimeInterval) {
        guard delta.isFinite else { return }
        let limit = LyricsStoreConstants.maximumOffset
        let clamped = min(limit, max(-limit, offset(for: trackID) + delta))
        setOffset((clamped * 10).rounded() / 10, for: trackID)
    }

    func resetOffset(for trackID: String) {
        setOffset(0, for: trackID)
    }

    // MARK: - Cache

    /// Deletes all saved lyrics — imported ones and timing offsets included — and resets every state.
    func clearCache() {
        cacheGeneration += 1
        let generation = cacheGeneration

        for flight in flights.values {
            flight.task.cancel()
        }
        flights.removeAll()
        states.removeAll()
        offsets.removeAll()
        offsetsEditedBeforeLoad.removeAll()
        offsetsLoaded = true
        cachedCount = 0

        disk.removeAll(newGeneration: generation) { [weak self] count in
            Task { @MainActor [weak self] in
                guard let self, self.cacheGeneration == generation else { return }
                self.cachedCount = count
            }
        }
    }

    // MARK: - Sync helper

    /// Index of the line that is active at playback `time` (seconds) with user `offset` applied:
    /// the last line whose (line.time + offset) <= time + 0.05; nil before the first line.
    /// Binary search (O(log n)).
    nonisolated static func activeLineIndex(in lines: [LyricLine], at time: TimeInterval, offset: TimeInterval) -> Int? {
        guard !lines.isEmpty, time.isFinite else { return nil }
        let shift = offset.isFinite ? offset : 0
        let threshold = time + 0.05
        // First index whose shifted start lies after the threshold.
        var low = 0
        var high = lines.count
        while low < high {
            let middle = low + (high - low) / 2
            if lines[middle].time + shift <= threshold {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : low - 1
    }

    // MARK: - Private: resolution flights

    @discardableResult
    private func startFlight(for track: Track, force: Bool, visible: Bool) -> LyricsFlight {
        let id = track.id
        flights[id]?.task.cancel()

        let allowsSidecar: Bool
        if case .mediaLibrary = track.location {
            allowsSidecar = false
        } else {
            allowsSidecar = true
        }
        let request = LyricsResolveRequest(
            track: track,
            audioURL: library.url(for: track),
            allowsSidecar: allowsSidecar,
            onlineGate: onlineGate,
            force: force,
            generation: cacheGeneration
        )
        let token = UUID()
        let disk = self.disk
        let generation = request.generation
        let task = Task(priority: visible ? .userInitiated : .utility) { [weak self] in
            let resolution = await LyricsResolver.resolve(request, disk: disk)
            self?.finishFlight(id: id, token: token, generation: generation, resolution: resolution)
        }
        let flight = LyricsFlight(token: token, task: task, isForced: force, isVisible: visible)
        flights[id] = flight
        return flight
    }

    private func finishFlight(id: String, token: UUID, generation: Int, resolution: LyricsResolution) {
        // A count from before "Clear Saved Lyrics" would bring back the old number.
        if let count = resolution.cachedCount, generation == cacheGeneration {
            cachedCount = count
        }
        guard let flight = flights[id], flight.token == token else { return }
        flights[id] = nil
        // Superseded flights never get here (their token is gone), so a resolution without an
        // answer was interrupted from outside: never leave a spinner up with nothing running.
        let state = resolution.state ?? .failed(LyricsResolver.interruptedMessage)

        if flight.isVisible {
            states[id] = state
        } else {
            switch state {
            case .loaded, .notFound, .offlineDisabled:
                states[id] = state
            case .idle, .loading, .failed:
                break
            }
        }
    }

    private func scheduleLoadingIndicator(for id: String, token: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: LyricsStoreConstants.loadingIndicatorDelay)
            guard let self, let flight = self.flights[id], flight.token == token, flight.isVisible else { return }
            if case .idle = self.state(for: id) {
                self.states[id] = .loading
            }
        }
    }

    /// Tracks that showed "Online lyrics lookup is off" get another chance once it is turned on.
    private func retryTracksWaitingForOnlineLookup() {
        let waiting = states.compactMap { id, state -> String? in
            if case .offlineDisabled = state { return id }
            return nil
        }
        for id in waiting {
            guard flights[id] == nil, let track = library.track(id: id) else { continue }
            states[id] = .loading
            startFlight(for: track, force: false, visible: true)
        }
    }

    // MARK: - Private: offsets

    private func setOffset(_ value: TimeInterval, for trackID: String) {
        let newValue: TimeInterval? = abs(value) < 0.05 ? nil : value
        guard offsets[trackID] != newValue else { return }
        offsets[trackID] = newValue
        if offsetsLoaded {
            disk.saveOffsets(offsets)
        } else {
            offsetsEditedBeforeLoad.insert(trackID)
        }
    }

    private func applyInitialState(offsets loaded: [String: TimeInterval], count: Int, generation: Int) {
        guard cacheGeneration == generation else { return }
        var merged = offsets
        for (trackID, value) in loaded where !offsetsEditedBeforeLoad.contains(trackID) {
            let limit = LyricsStoreConstants.maximumOffset
            guard value.isFinite, abs(value) >= 0.05 else { continue }
            merged[trackID] = min(limit, max(-limit, value))
        }
        if merged != offsets {
            offsets = merged
        }
        offsetsLoaded = true
        if !offsetsEditedBeforeLoad.isEmpty {
            offsetsEditedBeforeLoad.removeAll()
            disk.saveOffsets(offsets)
        }
        cachedCount = count
    }
}

// MARK: - Constants

private enum LyricsStoreConstants {
    static let onlineLookupKey = "lyrics.onlineLookup"
    static let maximumOffset: TimeInterval = 30
    static let loadingIndicatorDelay: UInt64 = 150_000_000
}

private let lyricsStoreLog = Logger(subsystem: "com.charanraj.musicbox", category: "Lyrics")

// MARK: - Online gate

/// Whether online lookup is allowed right now, readable from any thread. Resolutions check it
/// before every LRCLIB request, so turning "Find Lyrics Online" off takes effect immediately.
private final class LyricsOnlineGate: Sendable {
    private let state: OSAllocatedUnfairLock<Bool>

    init(isOpen: Bool) {
        state = OSAllocatedUnfairLock(initialState: isOpen)
    }

    var isOpen: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

// MARK: - Lyrics identity

/// Identifies lyrics by their words only (not timing, source or formatting), so lyrics the user
/// rejected are recognized in any LRCLIB record that carries them.
private enum LyricsDigest {
    static func of(_ lyrics: Lyrics) -> String {
        let text = lyrics.plainText ?? lyrics.lines.map(\.text).joined(separator: "\n")
        var words = ""
        var pendingSpace = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace, !words.isEmpty { words.unicodeScalars.append(" ") }
                pendingSpace = false
                words.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        if words.isEmpty, lyrics.isInstrumental { words = "\u{266A} instrumental" }
        let digest = SHA256.hash(data: Data(words.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Flight (one running resolution per track)

@MainActor
private final class LyricsFlight {
    let token: UUID
    let task: Task<Void, Never>
    let isForced: Bool
    /// True once someone is looking at this track (a `load` call), false for silent prefetches.
    var isVisible: Bool

    init(token: UUID, task: Task<Void, Never>, isForced: Bool, isVisible: Bool) {
        self.token = token
        self.task = task
        self.isForced = isForced
        self.isVisible = isVisible
    }
}

// MARK: - Resolution

private struct LyricsResolveRequest: Sendable {
    let track: Track
    let audioURL: URL?
    let allowsSidecar: Bool
    let onlineGate: LyricsOnlineGate
    let force: Bool
    let generation: Int
}

private struct LyricsResolution: Sendable {
    /// nil when the resolution was cancelled (nothing to publish).
    var state: LyricsState?
    /// New number of saved lyrics when the cache was written.
    var cachedCount: Int?

    static let cancelled = LyricsResolution(state: nil, cachedCount: nil)
}

private enum LyricsResolver {
    static let notFoundLifetime: TimeInterval = 3 * 24 * 60 * 60
    static let offlineMessage = "No internet connection — lyrics will load when you're online."
    static let interruptedMessage = "Couldn’t finish looking for lyrics. Try again."

    /// A sidecar still downloading from iCloud Drive is checked this often, this many times.
    static let pendingSidecarPollInterval: UInt64 = 500_000_000
    static let pendingSidecarPolls = 12

    /// Runs off the main actor.
    static func resolve(_ request: LyricsResolveRequest, disk: LyricsDiskCache) async -> LyricsResolution {
        let track = request.track
        let gate = request.onlineGate
        let cached = await disk.entry(for: track.id)

        // 1) Imported always wins, even over a forced search.
        if let cached, cached.isImported, let lyrics = cached.lyrics {
            return LyricsResolution(state: .loaded(lyrics), cachedCount: nil)
        }
        if Task.isCancelled { return .cancelled }

        let audioURL = request.audioURL

        // The file can't be reached right now (linked drive unplugged, iCloud copy evicted): its
        // sidecar and tags can't be read either, so what was found for it before still stands.
        // Re-resolving would replace saved sidecar/embedded lyrics with an online answer.
        if !request.force, audioURL == nil, let cached, cached.kind == .lyrics,
           let lyrics = cached.lyrics, hasContent(lyrics) {
            return LyricsResolution(state: .loaded(lyrics), cachedCount: nil)
        }

        var sidecar: LyricsLocalFiles.Sidecar?
        if request.allowsSidecar, let audioURL {
            sidecar = await LyricsIO.run { LyricsLocalFiles.findSidecar(nextTo: audioURL) }
        }

        let query = LRCLIBQuery(track: track)
        let queryKey = key(for: query)
        let now = Date()

        if !request.force, let cached,
           cached.fingerprint == fingerprint(for: track, audioURL: audioURL, sidecar: sidecar),
           let answer = cachedAnswer(cached, queryKey: queryKey, onlineEnabled: gate.isOpen, now: now) {
            return LyricsResolution(state: answer, cachedCount: nil)
        }
        if Task.isCancelled { return .cancelled }

        // A sidecar in iCloud Drive that isn't on this device yet: its download was just requested
        // and lyric files are tiny, so give it a few seconds before going on without it. (An answer
        // found without it is saved as "sidecar pending" and re-checked once it has arrived.)
        if sidecar?.isPending == true, let audioURL {
            var polls = 0
            while sidecar?.isPending == true, polls < pendingSidecarPolls {
                try? await Task.sleep(nanoseconds: pendingSidecarPollInterval)
                if Task.isCancelled { return .cancelled }
                sidecar = await LyricsIO.run { LyricsLocalFiles.findSidecar(nextTo: audioURL) }
                polls += 1
            }
        }
        let fingerprint = fingerprint(for: track, audioURL: audioURL, sidecar: sidecar)

        // 2) + 3) Local sources: sidecar first, then embedded; synced beats unsynced.
        var local: Lyrics?
        if let sidecar, !sidecar.isPending {
            local = await LyricsIO.run { LyricsLocalFiles.lyrics(fromSidecar: sidecar) }
        }
        if Task.isCancelled { return .cancelled }
        if !(local.map(isFinal) ?? false), let audioURL {
            if let embedded = await EmbeddedLyricsReader.read(url: audioURL), hasContent(embedded) {
                if local == nil || isFinal(embedded) {
                    local = embedded
                }
            }
            if Task.isCancelled { return .cancelled }
        }

        func store(_ lyrics: Lyrics?, onlineQuery: String?, checkedAt: Date?) async -> Int? {
            let entry = LyricsCacheEntry(
                trackID: track.id,
                kind: lyrics == nil ? .notFound : .lyrics,
                lyrics: lyrics,
                fingerprint: fingerprint,
                fetchedAt: now,
                isImported: false,
                onlineQuery: onlineQuery,
                onlineCheckedAt: checkedAt,
                rejectedLyrics: cached?.rejectedLyrics
            )
            return await disk.save(entry, generation: request.generation)
        }

        if let local, isFinal(local) {
            let count = await store(local, onlineQuery: nil, checkedAt: nil)
            return LyricsResolution(state: .loaded(local), cachedCount: count)
        }

        // What LRCLIB answered earlier for this very query is still good (hits forever, misses 3 days).
        if !request.force, let cached, cached.onlineQuery == queryKey {
            if let online = cached.lyrics, online.source == .online, hasContent(online) {
                let chosen: Lyrics
                if let local, !online.isSynced {
                    chosen = local
                } else {
                    chosen = online
                }
                let count = await store(chosen, onlineQuery: queryKey, checkedAt: cached.onlineCheckedAt ?? now)
                return LyricsResolution(state: .loaded(chosen), cachedCount: count)
            }
            if let checkedAt = cached.onlineCheckedAt, isFresh(checkedAt, now: now) {
                let count = await store(local, onlineQuery: queryKey, checkedAt: checkedAt)
                return LyricsResolution(state: local.map { .loaded($0) } ?? .notFound, cachedCount: count)
            }
        }

        // What LRCLIB gave this song before. Only reachable here on a forced search ("Search
        // Again"): a re-search must never swap it for something worse or for nothing.
        var savedOnline: Lyrics?
        if let cached, cached.onlineQuery == queryKey, let saved = cached.lyrics, saved.source == .online, hasContent(saved) {
            savedOnline = saved
        }

        /// Online lookup is off, or was turned off while this resolution ran.
        func withoutOnlineLookup() async -> LyricsResolution {
            if let savedOnline, savedOnline.isSynced || local == nil {
                return LyricsResolution(state: .loaded(savedOnline), cachedCount: nil)
            }
            if let local {
                let count = await store(local, onlineQuery: nil, checkedAt: nil)
                return LyricsResolution(state: .loaded(local), cachedCount: count)
            }
            return LyricsResolution(state: .offlineDisabled, cachedCount: nil)
        }

        // 4) Online.
        guard gate.isOpen else { return await withoutOnlineLookup() }

        let rejected = Set(cached?.rejectedLyrics ?? [])
        do {
            let hit = try await LRCLIBClient.shared.lookup(
                query,
                isRejected: { rejected.contains(LyricsDigest.of($0)) },
                isAllowed: { gate.isOpen }
            )
            if Task.isCancelled { return .cancelled }
            // Turned off while the last reply was on its way: don't keep what it brought.
            guard gate.isOpen else { return await withoutOnlineLookup() }
            // Synced beats unsynced; local unsynced text beats online unsynced text; a fresh
            // answer beats the saved one of the same kind. Nothing at all → remember the miss 3 days
            // (the client only answers nil when every request it made was answered).
            let chosen: Lyrics?
            if let hit, hit.isSynced {
                chosen = hit
            } else if let savedOnline, savedOnline.isSynced {
                chosen = savedOnline
            } else if let local {
                chosen = local
            } else {
                chosen = hit ?? savedOnline
            }
            let count = await store(chosen, onlineQuery: queryKey, checkedAt: now)
            return LyricsResolution(state: chosen.map { .loaded($0) } ?? .notFound, cachedCount: count)
        } catch {
            if error is CancellationError || Task.isCancelled { return .cancelled }
            if case .disabled? = error as? LRCLIBError { return await withoutOnlineLookup() }
            // A forced search that failed still shows the synced lyrics saved for this song before.
            if let savedOnline, savedOnline.isSynced || local == nil {
                return LyricsResolution(state: .loaded(savedOnline), cachedCount: nil)
            }
            if let local {
                // Saved without an online answer, so LRCLIB is asked again next time.
                let count = await store(local, onlineQuery: nil, checkedAt: nil)
                return LyricsResolution(state: .loaded(local), cachedCount: count)
            }
            lyricsStoreLog.info("LRCLIB lookup failed: \(String(describing: error), privacy: .public)")
            return LyricsResolution(state: .failed(message(for: error)), cachedCount: nil)
        }
    }

    /// "fileSize|fileModificationDate|sidecar": what the local sources looked like when an answer
    /// was saved; a different value re-resolves. The sidecar part is its mtime ("0.0" = none),
    /// "pending" while it is still downloading from iCloud Drive, and "0.0|unreachable" when the
    /// audio file itself can't be reached (nothing local could be checked, so the answer found
    /// meanwhile is re-checked against the sidecar and tags once the file is back).
    private static func fingerprint(for track: Track, audioURL: URL?, sidecar: LyricsLocalFiles.Sidecar?) -> String {
        let base = "\(track.fileSize)|\(track.fileModificationDate?.timeIntervalSince1970 ?? 0)"
        guard audioURL != nil else { return base + "|0.0|unreachable" }
        guard let sidecar else { return base + "|0.0" }
        if sidecar.isPending { return base + "|pending" }
        return base + "|\(sidecar.modificationTime ?? -1)"
    }

    /// The saved answer when it is still valid for the same local files, else nil (re-resolve).
    private static func cachedAnswer(_ entry: LyricsCacheEntry, queryKey: String, onlineEnabled: Bool, now: Date) -> LyricsState? {
        switch entry.kind {
        case .lyrics:
            guard let lyrics = entry.lyrics, hasContent(lyrics) else { return nil }
            switch lyrics.source {
            case .online:
                return entry.onlineQuery == queryKey ? .loaded(lyrics) : nil
            case .imported:
                return .loaded(lyrics)
            case .sidecarFile, .embedded:
                if isFinal(lyrics) || !onlineEnabled {
                    return .loaded(lyrics)
                }
                // Unsynced local text: look online for a synced version unless that was done recently.
                if entry.onlineQuery == queryKey, let checkedAt = entry.onlineCheckedAt, isFresh(checkedAt, now: now) {
                    return .loaded(lyrics)
                }
                return nil
            }
        case .notFound:
            guard entry.onlineQuery == queryKey, let checkedAt = entry.onlineCheckedAt, isFresh(checkedAt, now: now) else {
                return nil
            }
            return .notFound
        }
    }

    private static func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age > -300 && age < notFoundLifetime
    }

    /// Synced or instrumental: nothing better can be found online.
    private static func isFinal(_ lyrics: Lyrics) -> Bool {
        lyrics.isSynced || lyrics.isInstrumental
    }

    private static func hasContent(_ lyrics: Lyrics) -> Bool {
        if lyrics.isSynced || lyrics.isInstrumental { return true }
        guard let text = lyrics.plainText else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Identifies what was asked online, so a retagged song is looked up again.
    private static func key(for query: LRCLIBQuery) -> String {
        let duration = query.duration.map { String(Int($0.rounded())) } ?? ""
        return [query.title, query.artist ?? "", query.album ?? "", duration]
            .map { $0.lowercased() }
            .joined(separator: "|")
    }

    private static func message(for error: Error) -> String {
        switch error as? LRCLIBError {
        case .offline?:
            return offlineMessage
        case .http(429)?:
            return "The lyrics service is busy right now. Try again in a minute."
        case .http?, .decoding?, .unavailable?:
            return "The lyrics service isn't responding right now. Try again later."
        case .disabled?:
            return "Online lyrics lookup is off."
        case nil:
            return offlineMessage
        }
    }
}

// MARK: - Cache entry

private struct LyricsCacheEntry: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case lyrics, notFound
    }

    var trackID: String
    var kind: Kind
    var lyrics: Lyrics?
    /// Local sources at resolution time: "fileSize|fileModificationDate|sidecar mtime".
    var fingerprint: String
    var fetchedAt: Date
    var isImported: Bool
    /// The LRCLIB query this entry's online knowledge belongs to (nil = LRCLIB not consulted).
    var onlineQuery: String?
    /// When LRCLIB last answered for `onlineQuery`.
    var onlineCheckedAt: Date?
    /// `LyricsDigest`s of online lyrics the user marked as wrong for this track ("Wrong Lyrics").
    var rejectedLyrics: [String]? = nil
}

private struct LyricsRemoval: Sendable {
    var removed: Bool
    var count: Int
}

// MARK: - Disk cache

/// All lyrics files live in Application Support/Lyrics. Every access goes through one serial queue,
/// so writes land in the order they were requested and never block the main thread.
private final class LyricsDiskCache: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.charanraj.musicbox.lyrics-cache", qos: .utility)

    // Confined to `queue`.
    private var currentGeneration = 0
    private var index: LyricsCacheIndex?
    private var directoryURL: URL?

    private static let offsetsFileName = "offsets.json"
    /// Rejected lyrics remembered per track (oldest dropped first).
    private static let maximumRejected = 32
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    // MARK: Async API (ordering-insensitive)

    func entry(for trackID: String) async -> LyricsCacheEntry? {
        await perform { $0.readEntry(for: trackID) }
    }

    func save(_ entry: LyricsCacheEntry, generation: Int) async -> Int? {
        await perform { $0.writeEntry(entry, generation: generation) }
    }

    func initialState() async -> (offsets: [String: TimeInterval], count: Int) {
        await perform { cache in
            (cache.readOffsets(), cache.currentIndex().lyrics.count)
        }
    }

    // MARK: Enqueue-now API (keeps the caller's order)

    func save(_ entry: LyricsCacheEntry, generation: Int, completion: @escaping @Sendable (Int?) -> Void) {
        queue.async {
            completion(self.writeEntry(entry, generation: generation))
        }
    }

    func removeImportedEntry(for trackID: String, generation: Int, completion: @escaping @Sendable (LyricsRemoval) -> Void) {
        queue.async {
            var removed = false
            if generation >= self.currentGeneration,
               let entry = self.readEntry(for: trackID), entry.isImported,
               let url = self.entryURL(for: trackID) {
                do {
                    try FileManager.default.removeItem(at: url)
                    var index = self.currentIndex()
                    index.lyrics.remove(url.lastPathComponent)
                    index.imported.remove(url.lastPathComponent)
                    self.index = index
                    removed = true
                } catch {
                    lyricsStoreLog.error("Could not remove imported lyrics: \(error.localizedDescription, privacy: .public)")
                }
            }
            completion(LyricsRemoval(removed: removed, count: self.currentIndex().lyrics.count))
        }
    }

    /// Replaces the track's entry with a "look again" marker that remembers `digest` as rejected
    /// (imported lyrics are left alone). Completion gets the new count, nil when nothing was written.
    func rejectOnlineLyrics(_ digest: String, for trackID: String, generation: Int, completion: @escaping @Sendable (Int?) -> Void) {
        queue.async {
            guard generation >= self.currentGeneration else {
                completion(nil)
                return
            }
            let existing = self.readEntry(for: trackID)
            if existing?.isImported == true {
                completion(nil)
                return
            }
            var rejected = existing?.rejectedLyrics ?? []
            if !rejected.contains(digest) { rejected.append(digest) }
            let entry = LyricsCacheEntry(
                trackID: trackID,
                kind: .notFound,
                lyrics: nil,
                fingerprint: "",            // never matches: the next load resolves again
                fetchedAt: Date(),
                isImported: false,
                onlineQuery: nil,
                onlineCheckedAt: nil,
                rejectedLyrics: rejected
            )
            completion(self.writeEntry(entry, generation: generation))
        }
    }

    func removeAll(newGeneration: Int, completion: @escaping @Sendable (Int) -> Void) {
        queue.async {
            self.currentGeneration = max(self.currentGeneration, newGeneration)
            let fileManager = FileManager.default
            if let directory = self.directory(),
               let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for url in contents {
                    do {
                        try fileManager.removeItem(at: url)
                    } catch {
                        lyricsStoreLog.error("Could not delete \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            self.index = LyricsCacheIndex()
            completion(0)
        }
    }

    func saveOffsets(_ offsets: [String: TimeInterval]) {
        queue.async {
            guard let directory = self.directory() else { return }
            let url = directory.appending(path: LyricsDiskCache.offsetsFileName, directoryHint: .notDirectory)
            do {
                if offsets.isEmpty {
                    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                        try FileManager.default.removeItem(at: url)
                    }
                } else {
                    let data = try JSONEncoder().encode(offsets)
                    try data.write(to: url, options: [.atomic])
                }
            } catch {
                lyricsStoreLog.error("Could not save lyrics offsets: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Queue-confined helpers

    private func perform<T: Sendable>(_ work: @escaping @Sendable (LyricsDiskCache) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work(self))
            }
        }
    }

    private func directory() -> URL? {
        if let directoryURL { return directoryURL }
        let url = AppPaths.applicationSupport.appending(path: "Lyrics", directoryHint: .isDirectory)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) || !isDirectory.boolValue {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                lyricsStoreLog.error("Could not create the lyrics folder: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        directoryURL = url
        return url
    }

    private func fileName(for trackID: String) -> String {
        let digest = SHA256.hash(data: Data(trackID.utf8))
        var characters: [UInt8] = []
        characters.reserveCapacity(SHA256.byteCount * 2 + 5)
        for byte in digest {
            characters.append(LyricsDiskCache.hexDigits[Int(byte >> 4)])
            characters.append(LyricsDiskCache.hexDigits[Int(byte & 0x0F)])
        }
        characters.append(contentsOf: Array(".json".utf8))
        return String(decoding: characters, as: UTF8.self)
    }

    private func entryURL(for trackID: String) -> URL? {
        directory()?.appending(path: fileName(for: trackID), directoryHint: .notDirectory)
    }

    private func readEntry(for trackID: String) -> LyricsCacheEntry? {
        guard let url = entryURL(for: trackID),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let entry = try JSONDecoder().decode(LyricsCacheEntry.self, from: data)
            guard entry.trackID == trackID else { return nil }
            if entry.kind == .lyrics && entry.lyrics == nil { return nil }
            return entry
        } catch {
            lyricsStoreLog.error("Unreadable lyrics cache entry: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Returns the new number of saved lyrics, or nil when the write was skipped or failed.
    /// Stale writes (from before a clear) and writes over an imported entry by anything but another
    /// import are skipped: a resolution that finished just after an import must not replace it.
    private func writeEntry(_ entry: LyricsCacheEntry, generation: Int) -> Int? {
        guard generation >= currentGeneration else { return nil }
        guard let url = entryURL(for: entry.trackID) else { return nil }
        var index = currentIndex()
        let name = url.lastPathComponent
        if !entry.isImported && index.imported.contains(name) { return nil }

        // Lyrics the user rejected stay rejected, even against a resolution that started before
        // the rejection and finishes after it.
        var entry = entry
        if let previous = readEntry(for: entry.trackID)?.rejectedLyrics, !previous.isEmpty {
            var merged = entry.rejectedLyrics ?? []
            for digest in previous where !merged.contains(digest) { merged.append(digest) }
            if merged.count > LyricsDiskCache.maximumRejected {
                merged.removeFirst(merged.count - LyricsDiskCache.maximumRejected)
            }
            entry.rejectedLyrics = merged
        }
        if let rejected = entry.rejectedLyrics, let lyrics = entry.lyrics, lyrics.source == .online,
           rejected.contains(LyricsDigest.of(lyrics)) {
            return nil
        }

        do {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: url, options: [.atomic])
        } catch {
            lyricsStoreLog.error("Could not save lyrics: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        if entry.kind == .lyrics {
            index.lyrics.insert(name)
        } else {
            index.lyrics.remove(name)
        }
        if entry.isImported {
            index.imported.insert(name)
        } else {
            index.imported.remove(name)
        }
        self.index = index
        return index.lyrics.count
    }

    /// Which cache files hold lyrics (not "not found" markers) and which are imports.
    /// Built once from disk, then kept current by every write.
    private func currentIndex() -> LyricsCacheIndex {
        if let index { return index }
        var built = LyricsCacheIndex()
        if let directory = directory(),
           let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let decoder = JSONDecoder()
            for url in contents where url.pathExtension == "json" && url.lastPathComponent != LyricsDiskCache.offsetsFileName {
                guard let data = try? Data(contentsOf: url),
                      let probe = try? decoder.decode(LyricsCacheKindProbe.self, from: data) else { continue }
                if probe.kind == .lyrics { built.lyrics.insert(url.lastPathComponent) }
                if probe.isImported { built.imported.insert(url.lastPathComponent) }
            }
        }
        index = built
        return built
    }

    private func readOffsets() -> [String: TimeInterval] {
        guard let directory = directory() else { return [:] }
        let url = directory.appending(path: LyricsDiskCache.offsetsFileName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              let data = try? Data(contentsOf: url),
              let offsets = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else { return [:] }
        return offsets
    }
}

private struct LyricsCacheKindProbe: Decodable {
    let kind: LyricsCacheEntry.Kind
    let isImported: Bool
}

private struct LyricsCacheIndex {
    var lyrics: Set<String> = []
    var imported: Set<String> = []
}

// MARK: - Blocking I/O off the cooperative pool

private enum LyricsIO {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}

// MARK: - Local lyric files

private enum LyricsLocalFiles {
    struct Sidecar: Sendable {
        let url: URL
        let modificationTime: TimeInterval?
        /// In iCloud Drive but not downloaded to this device yet (its download has been requested):
        /// can't be read now.
        let isPending: Bool
    }

    private static let sidecarKeys: [URLResourceKey] = [
        .isRegularFileKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]
    private static let placeholderSuffix = ".icloud"

    /// Lyric files are small; anything bigger is not a lyric file.
    private static let maximumFileSize = 2 * 1024 * 1024

    /// `Song.mp3` → `Song.lrc` in the same folder (extension case-insensitive). Blocking.
    /// A sidecar that is still in iCloud Drive only (".Song.lrc.icloud" placeholder, or a
    /// not-downloaded item) gets its download requested and comes back `isPending`.
    static func findSidecar(nextTo audioURL: URL) -> Sidecar? {
        let directory = audioURL.deletingLastPathComponent()
        let audioBase = audioURL.deletingPathExtension().lastPathComponent
        guard !audioBase.isEmpty else { return nil }
        let fileManager = FileManager.default

        // Hidden files are listed too: that's how iCloud placeholders show up.
        if let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: sidecarKeys,
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) {
            var exactMatch: URL?
            var looseMatch: URL?
            var placeholder: URL?
            var placeholderIsExact = false
            for url in contents {
                let name = url.lastPathComponent
                let placeholderTarget = realURL(forPlaceholderNamed: name, in: directory)
                if placeholderTarget == nil, name.hasPrefix(".") { continue }
                let candidate = placeholderTarget ?? url
                guard candidate.pathExtension.lowercased() == "lrc" else { continue }
                let base = candidate.deletingPathExtension().lastPathComponent
                let isExact = base == audioBase
                guard isExact || base.caseInsensitiveCompare(audioBase) == .orderedSame else { continue }

                if let placeholderTarget {
                    if placeholder == nil || (isExact && !placeholderIsExact) {
                        placeholder = placeholderTarget
                        placeholderIsExact = isExact
                    }
                } else if isExact {
                    exactMatch = url
                } else if looseMatch == nil {
                    looseMatch = url
                }
            }
            for url in [exactMatch, looseMatch].compactMap({ $0 }) {
                if let sidecar = sidecar(at: url) { return sidecar }
            }
            return placeholder.map(pendingSidecar(at:))
        }

        // The folder can't be listed: try the obvious names directly.
        for fileExtension in ["lrc", "LRC", "Lrc"] {
            let url = directory.appending(path: audioBase + "." + fileExtension, directoryHint: .notDirectory)
            if fileManager.fileExists(atPath: url.path(percentEncoded: false)), let sidecar = sidecar(at: url) {
                return sidecar
            }
            let placeholderURL = directory.appending(
                path: "." + audioBase + "." + fileExtension + placeholderSuffix,
                directoryHint: .notDirectory
            )
            if fileManager.fileExists(atPath: placeholderURL.path(percentEncoded: false)) {
                return pendingSidecar(at: url)
            }
        }
        return nil
    }

    static func lyrics(fromSidecar sidecar: Sidecar) -> Lyrics? {
        guard !sidecar.isPending else { return nil }
        // Coordinated: the file may live in iCloud Drive or another file provider.
        guard let text = readText(at: sidecar.url, coordinated: true) else { return nil }
        return lyrics(fromText: text, source: .sidecarFile, attribution: "From “\(sidecar.url.lastPathComponent)”")
    }

    /// A user-picked `.lrc` / `.txt` file (security-scoped URL from the file importer). Blocking.
    static func importedLyrics(from url: URL) -> Lyrics? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        guard let text = readText(at: url, coordinated: true) else { return nil }
        return lyrics(fromText: text, source: .imported, attribution: "Imported")
    }

    /// LRC → synced lines (+ plain text); anything else → plain text. nil when there is no text.
    static func lyrics(fromText text: String, source: LyricsSource, attribution: String) -> Lyrics? {
        if let parsed = LRCParser.parse(text), !parsed.lines.isEmpty {
            let plain = LRCParser.plainText(fromLRC: text)
            return Lyrics(
                source: source,
                lines: parsed.lines,
                plainText: isBlank(plain) ? nil : plain,
                isInstrumental: false,
                attribution: attribution
            )
        }
        let plain = LRCParser.plainText(fromLRC: text)
        guard !isBlank(plain) else { return nil }
        return Lyrics(source: source, lines: [], plainText: plain, isInstrumental: false, attribution: attribution)
    }

    // MARK: Private

    private static func sidecar(at url: URL) -> Sidecar? {
        let values = try? url.resourceValues(forKeys: Set(sidecarKeys))
        if values?.isRegularFile == false { return nil }
        // Only a stand-in for a file in iCloud Drive: ask for it instead of reading it.
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            return pendingSidecar(at: url)
        }
        return Sidecar(url: url, modificationTime: values?.contentModificationDate?.timeIntervalSince1970, isPending: false)
    }

    /// Requests the download of an iCloud Drive file that isn't on this device yet.
    private static func pendingSidecar(at url: URL) -> Sidecar {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            lyricsStoreLog.info("Could not request lyrics file download: \(error.localizedDescription, privacy: .public)")
        }
        return Sidecar(url: url, modificationTime: nil, isPending: true)
    }

    /// ".Song.lrc.icloud" (iCloud placeholder) → ".../Song.lrc"; nil for any other name.
    private static func realURL(forPlaceholderNamed name: String, in directory: URL) -> URL? {
        guard name.hasPrefix("."), name.count > placeholderSuffix.count + 1,
              name.lowercased().hasSuffix(placeholderSuffix) else { return nil }
        let realName = String(name.dropFirst().dropLast(placeholderSuffix.count))
        guard !realName.isEmpty else { return nil }
        return directory.appending(path: realName, directoryHint: .notDirectory)
    }

    private static func readText(at url: URL, coordinated: Bool) -> String? {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumFileSize {
            return nil
        }
        var data: Data?
        if coordinated {
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
                data = try? Data(contentsOf: readURL, options: [.mappedIfSafe])
            }
        }
        if data == nil {
            data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        }
        guard let data, !data.isEmpty, data.count <= maximumFileSize else { return nil }
        guard let text = decodeText(data), looksLikeText(text) else { return nil }
        return text
    }

    /// UTF-8 (with or without BOM), UTF-16 (BOM or detected), then Windows-1252 / ISO Latin-1.
    private static func decodeText(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let encoding = bomlessUTF16Encoding(bytes), let text = String(data: data, encoding: encoding) {
            return text
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    /// UTF-16 without a BOM shows up as a zero byte in every other position for Latin text.
    private static func bomlessUTF16Encoding(_ bytes: [UInt8]) -> String.Encoding? {
        let sampleCount = min(bytes.count, 4096) & ~1
        guard sampleCount >= 4 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for index in 0..<sampleCount where bytes[index] == 0 {
            if index % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let pairs = sampleCount / 2
        if oddZeros * 10 >= pairs * 3, evenZeros * 20 <= pairs { return .utf16LittleEndian }
        if evenZeros * 10 >= pairs * 3, oddZeros * 20 <= pairs { return .utf16BigEndian }
        return nil
    }

    /// Rejects binary files picked by mistake (lots of control characters).
    private static func looksLikeText(_ text: String) -> Bool {
        var total = 0
        var control = 0
        for scalar in text.unicodeScalars {
            total += 1
            switch scalar.value {
            case 0x09, 0x0A, 0x0D, 0xFEFF:
                continue
            case 0x00...0x1F, 0x7F:
                control += 1
            default:
                continue
            }
        }
        guard total > 0 else { return false }
        return control * 100 <= total
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
