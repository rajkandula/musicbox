import AVFoundation
import MediaPlayer
import Observation
import UIKit
import os

// MARK: - Repeat mode

enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one

    var systemImage: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

// MARK: - File-private helpers

private let playerLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Musicbox", category: "PlayerEngine")

/// Runs `work` on the main actor. Synchronous when already on the main thread (the usual case for
/// callbacks registered with `queue: .main`), otherwise hops to the main queue. Safe to call from
/// any KVO / NotificationCenter / AVFoundation callback.
private func performOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }
}

/// Finite, non-negative seconds for a CMTime, or nil for invalid/indefinite times.
private func finiteSeconds(_ time: CMTime) -> TimeInterval? {
    guard time.isValid, time.isNumeric else { return nil }
    let value = time.seconds
    guard value.isFinite, value >= 0 else { return nil }
    return value
}

/// One slot in the play queue. `uid` is unique per slot so the same song can appear twice and the
/// shuffled and original orders can be matched exactly.
private struct QueueEntry: Hashable {
    let uid: Int
    let trackID: String
}

// MARK: - PlayerEngine

/// The app's single playback engine: one AVPlayer, a play queue with shuffle/repeat, background
/// audio with lock-screen / Control Center / headphone controls, video files played as audio,
/// a sleep timer and session restoration.
@MainActor @Observable
final class PlayerEngine {

    // MARK: State

    /// Single AVPlayer. Replaced only when it dies (media services reset / failed player); video
    /// layers are re-pointed by the engine, so views never hold on to it.
    @ObservationIgnored private(set) var player: AVPlayer
    /// Track IDs in current play order.
    private(set) var queue: [String] = []
    /// Index into `queue`.
    private(set) var currentIndex: Int?
    /// True while playing or about to play (waiting to play at the requested rate).
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var shuffleEnabled: Bool = false
    private(set) var repeatMode: RepeatMode = .off
    /// 0.5…2.0, default 1.0.
    var playbackRate: Float = 1.0 {
        didSet { applyPlaybackRate() }
    }
    private(set) var sleepTimerEndDate: Date?
    private(set) var sleepAtEndOfTrack: Bool = false
    /// Transient user-facing error; the UI shows and clears it.
    var errorMessage: String?
    /// Show the picture of video tracks (Now Playing toggle). Default false: audio only.
    var showVideo: Bool = false {
        didSet {
            if showVideo != oldValue {
                applyVideoPresentation(refreshFrame: true)
            }
        }
    }
    /// Width / height of the current video as displayed (rotation applied); nil while unknown or
    /// for audio. Always finite and > 0 when set.
    private(set) var videoAspectRatio: CGFloat?

    var currentTrack: Track? {
        guard let index = currentIndex, queue.indices.contains(index) else { return nil }
        return library.track(id: queue[index])
    }

    var upNext: [Track] {
        guard let index = currentIndex, index + 1 < queue.count else { return [] }
        return library.tracks(ids: Array(queue[(index + 1)...]))
    }

    var hasActiveSession: Bool { currentTrack != nil }

    // MARK: Private state

    private let library: LibraryStore
    private let nowPlaying: NowPlayingController
    /// Weak references to the AVPlayerLayers currently on screen (PlayerVideoView).
    private let videoLayers = NSHashTable<AVPlayerLayer>.weakObjects()

    /// Source of truth for the play order; `queue` mirrors it for observers.
    @ObservationIgnored private var entries: [QueueEntry] = [] {
        didSet { queue = entries.map(\.trackID) }
    }
    /// Un-shuffled order. Always equal to `entries` while shuffle is off.
    @ObservationIgnored private var originalEntries: [QueueEntry] = []
    @ObservationIgnored private var nextEntryUID = 0
    /// Queue slot whose file is loaded into `player`.
    @ObservationIgnored private var loadedEntry: QueueEntry?
    /// False for the paused item prepared at launch: failures then wait for the user to press play.
    @ObservationIgnored private var loadedItemReportsErrors = true
    /// What the user asked for (play vs pause), independent of transient buffering states.
    @ObservationIgnored private var wantsToPlay = false
    @ObservationIgnored private var pendingSeekTime: TimeInterval?
    @ObservationIgnored private var seeksInFlight = 0
    @ObservationIgnored private var readyItemID: ObjectIdentifier?
    @ObservationIgnored private var failedItemHandled = false
    @ObservationIgnored private var listenedSeconds: TimeInterval = 0
    @ObservationIgnored private var lastTickPosition: TimeInterval?
    @ObservationIgnored private var playRecorded = false
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var failureSkipTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var isInForeground = true
    @ObservationIgnored private var lastSaveDate = Date.distantPast
    @ObservationIgnored private var lastSavedState: PlaybackState?
    @ObservationIgnored private var timeObserverToken: Any?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var playerStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var lastPlayerRebuildDate = Date.distantPast
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemPresentationSizeObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObserverTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var systemObserverTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private static let maxConsecutiveFailures = 5
    private static let periodicSaveInterval: TimeInterval = 15
    /// The sleep timer task re-checks its deadline at least this often.
    private static let sleepTimerCheckInterval: TimeInterval = 30
    /// A sleep timer task that wakes up this long after its deadline was not running at the
    /// deadline: the app was suspended, which iOS only does while nothing is playing.
    private static let sleepTimerLateWakeTolerance: TimeInterval = sleepTimerCheckInterval + 5

    // MARK: - Init

    init(library: LibraryStore) {
        self.library = library
        self.player = PlayerEngine.makePlayer()
        self.nowPlaying = NowPlayingController()
        self.isInForeground = UIApplication.shared.applicationState != .background

        configureAudioSession()
        installPlayerObservers()
        installSystemObservers()
        registerRemoteCommands()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        library.onTracksRemoved = { [weak self] removedIDs in
            self?.handleTracksRemoved(removedIDs)
        }
        restoreState()
        refreshRemoteCommandStates()
    }

    // MARK: - Commands

    func play(tracks: [Track], startAt index: Int = 0, shuffle: Bool = false) {
        play(trackIDs: tracks.map(\.id), startAt: index, shuffle: shuffle)
    }

    func play(trackIDs: [String], startAt index: Int = 0, shuffle: Bool = false) {
        guard !trackIDs.isEmpty else { return }
        expireStaleSleepTimer()
        let start = min(max(index, 0), trackIDs.count - 1)
        consecutiveFailures = 0
        let newEntries = trackIDs.map { makeEntry($0) }
        originalEntries = newEntries
        if shuffle {
            var rest = newEntries
            let first = rest.remove(at: start)
            rest.shuffle()
            entries = [first] + rest
            currentIndex = 0
        } else {
            entries = newEntries
            currentIndex = start
        }
        shuffleEnabled = shuffle
        loadCurrentEntry(autoPlay: true)
    }

    func shuffleAll(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        play(tracks: tracks, startAt: Int.random(in: 0..<tracks.count), shuffle: true)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard !entries.isEmpty else { return }
        expireStaleSleepTimer()
        consecutiveFailures = 0
        guard let index = currentIndex, entries.indices.contains(index) else {
            currentIndex = 0
            loadCurrentEntry(autoPlay: true)
            return
        }
        let item = player.currentItem
        let needsReload = item == nil
            || item?.status == .failed
            || loadedEntry?.uid != entries[index].uid
        if needsReload {
            loadCurrentEntry(autoPlay: true, startAt: currentTime)
        } else {
            startPlayback()
            publishNowPlaying()
        }
    }

    func pause() {
        wantsToPlay = false
        wasPlayingBeforeInterruption = false
        player.pause()
        currentTime = currentPlaybackTime()
        if isPlaying { isPlaying = false }
        publishNowPlaying()
        saveState()
    }

    /// User "next": honours repeat/shuffle. At the end of the queue with repeat off playback stops
    /// (paused, last track, time 0).
    func next() {
        guard !entries.isEmpty else { return }
        consecutiveFailures = 0
        advance(userInitiated: true)
    }

    /// Restarts the track when more than 3 s in, otherwise goes to the previous track
    /// (wrapping to the last one when repeat is on).
    func previous() {
        guard !entries.isEmpty else { return }
        consecutiveFailures = 0
        let continuePlaying = isPlaying || wantsToPlay
        guard let index = currentIndex, entries.indices.contains(index) else {
            currentIndex = 0
            loadCurrentEntry(autoPlay: continuePlaying)
            return
        }
        if currentPlaybackTime() > 3 {
            restartCurrentTrack(play: continuePlaying)
        } else if index > 0 {
            currentIndex = index - 1
            loadCurrentEntry(autoPlay: continuePlaying)
        } else if repeatMode != .off, entries.count > 1 {
            currentIndex = entries.count - 1
            loadCurrentEntry(autoPlay: continuePlaying)
        } else {
            restartCurrentTrack(play: continuePlaying)
        }
    }

    func seek(to seconds: TimeInterval) {
        guard currentEntry != nil else { return }
        guard player.currentItem != nil else {
            // No item loaded (e.g. the restored file is temporarily unavailable): remember the
            // position so it is used when the item is loaded on play.
            var target = seconds.isFinite ? max(0, seconds) : 0
            if duration > 0 { target = min(target, duration) }
            currentTime = target
            return
        }
        performSeek(to: seconds)
    }

    func skip(by seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        seek(to: currentPlaybackTime() + seconds)
    }

    /// Turning shuffle on keeps the current track playing (moved to the top of the queue) and
    /// shuffles every other track into Up Next. Turning it off restores the original order.
    func toggleShuffle() {
        if shuffleEnabled {
            let currentUID = currentEntry?.uid
            shuffleEnabled = false
            if originalEntries.count == entries.count {
                entries = originalEntries
            } else {
                originalEntries = entries
            }
            if let currentUID, let index = entries.firstIndex(where: { $0.uid == currentUID }) {
                currentIndex = index
            } else {
                currentIndex = entries.isEmpty ? nil : 0
            }
        } else {
            shuffleEnabled = true
            originalEntries = entries
            if let index = currentIndex, entries.indices.contains(index) {
                var rest = entries
                let current = rest.remove(at: index)
                rest.shuffle()
                entries = [current] + rest
                currentIndex = 0
            } else if !entries.isEmpty {
                entries.shuffle()
                currentIndex = 0
            }
        }
        refreshRemoteCommandStates()
        publishNowPlaying()
        saveState()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: setRepeatMode(.all)
        case .all: setRepeatMode(.one)
        case .one: setRepeatMode(.off)
        }
    }

    /// Inserts right after the current track (starts playing if the queue is empty).
    func playNext(_ trackIDs: [String]) {
        guard !trackIDs.isEmpty else { return }
        guard let index = currentIndex, entries.indices.contains(index) else {
            play(trackIDs: trackIDs)
            return
        }
        let newEntries = trackIDs.map { makeEntry($0) }
        let current = entries[index]
        entries.insert(contentsOf: newEntries, at: index + 1)
        if shuffleEnabled {
            if let originalIndex = originalEntries.firstIndex(where: { $0.uid == current.uid }) {
                originalEntries.insert(contentsOf: newEntries, at: originalIndex + 1)
            } else {
                originalEntries.append(contentsOf: newEntries)
            }
        } else {
            originalEntries = entries
        }
        queueDidChange()
    }

    /// Appends to the end of the queue (starts playing if the queue is empty).
    func addToQueue(_ trackIDs: [String]) {
        guard !trackIDs.isEmpty else { return }
        guard let index = currentIndex, entries.indices.contains(index) else {
            play(trackIDs: trackIDs)
            return
        }
        let newEntries = trackIDs.map { makeEntry($0) }
        entries.append(contentsOf: newEntries)
        if shuffleEnabled {
            originalEntries.append(contentsOf: newEntries)
        } else {
            originalEntries = entries
        }
        queueDidChange()
    }

    /// Offsets index into `queue`. The current track cannot be removed (ignored).
    func removeFromQueue(at offsets: IndexSet) {
        guard let index = currentIndex, entries.indices.contains(index) else { return }
        let removable = offsets.filter { $0 != index && entries.indices.contains($0) }
        guard !removable.isEmpty else { return }
        let removedUIDs = Set(removable.map { entries[$0].uid })
        let removedBefore = removable.filter { $0 < index }.count
        entries.removeAll { removedUIDs.contains($0.uid) }
        originalEntries.removeAll { removedUIDs.contains($0.uid) }
        currentIndex = index - removedBefore
        queueDidChange()
    }

    /// Indices into `queue` with SwiftUI `onMove` semantics; the current track keeps playing.
    func moveInQueue(from source: IndexSet, to destination: Int) {
        let valid = source.filter { entries.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let currentUID = currentEntry?.uid
        let validSet = Set(valid)
        let destinationIndex = min(max(destination, 0), entries.count)

        let moving = valid.map { entries[$0] }
        var remaining: [QueueEntry] = []
        remaining.reserveCapacity(entries.count)
        for (offset, entry) in entries.enumerated() where !validSet.contains(offset) {
            remaining.append(entry)
        }
        let insertionIndex = min(
            max(destinationIndex - valid.filter { $0 < destinationIndex }.count, 0),
            remaining.count
        )
        remaining.insert(contentsOf: moving, at: insertionIndex)
        guard remaining != entries else { return }

        entries = remaining
        if let currentUID {
            currentIndex = entries.firstIndex { $0.uid == currentUID }
        }
        if !shuffleEnabled {
            originalEntries = entries
        }
        queueDidChange()
    }

    func jump(to queueIndex: Int) {
        guard entries.indices.contains(queueIndex) else { return }
        expireStaleSleepTimer()
        consecutiveFailures = 0
        currentIndex = queueIndex
        loadCurrentEntry(autoPlay: true)
    }

    /// nil cancels (also clears "end of track"). Otherwise fades out and pauses when time is up.
    func setSleepTimer(minutes: Int?) {
        cancelSleepTimer()
        sleepAtEndOfTrack = false
        guard let minutes, minutes > 0 else { return }
        let endDate = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        sleepTimerEndDate = endDate
        sleepTimerTask = Task { [weak self] in
            while true {
                let remaining = endDate.timeIntervalSinceNow
                if remaining <= 0 { break }
                let chunk = min(remaining, PlayerEngine.sleepTimerCheckInterval)
                try? await Task.sleep(nanoseconds: UInt64(chunk * 1_000_000_000))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            if -endDate.timeIntervalSinceNow > PlayerEngine.sleepTimerLateWakeTolerance {
                // Woken long after the deadline: the app was suspended then, so nothing was
                // playing. The timer is spent; it must not fade out playback started since, nor
                // let the end of an interruption restart the music.
                self.cancelSleepTimer()
                self.wasPlayingBeforeInterruption = false
                return
            }
            await self.fadeOutForSleepTimer()
        }
    }

    /// Pauses when the current track finishes.
    func setSleepAtEndOfTrack() {
        cancelSleepTimer()
        sleepAtEndOfTrack = true
    }

    /// Stops playback, empties the queue and removes the lock-screen card.
    func clearQueue() {
        cancelFailureSkip()
        cancelSleepTimer()
        sleepAtEndOfTrack = false
        removeItemObservers()
        wantsToPlay = false
        wasPlayingBeforeInterruption = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedEntry = nil
        if videoAspectRatio != nil { videoAspectRatio = nil }
        pendingSeekTime = nil
        seeksInFlight = 0
        readyItemID = nil
        failedItemHandled = false
        listenedSeconds = 0
        lastTickPosition = nil
        playRecorded = false
        consecutiveFailures = 0
        originalEntries = []
        entries = []
        currentIndex = nil
        currentTime = 0
        duration = 0
        if isPlaying { isPlaying = false }
        applyVideoPresentation(refreshFrame: false)
        nowPlaying.clear()
        refreshRemoteCommandStates()
        saveState()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            playerLog.debug("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persists queue, index, position, shuffle, repeat and speed.
    func saveState() {
        lastSaveDate = Date()
        let position = currentPlaybackTime()
        let state = PlaybackState(
            queue: queue,
            originalQueue: shuffleEnabled ? originalEntries.map(\.trackID) : queue,
            currentIndex: currentIndex,
            currentTime: position.isFinite ? max(0, position) : 0,
            shuffleEnabled: shuffleEnabled,
            repeatMode: repeatMode,
            playbackRate: effectiveRate
        )
        guard state != lastSavedState else { return }
        lastSavedState = state
        PlaybackStateStore.save(state)
    }

    func attachVideoLayer(_ layer: AVPlayerLayer) {
        videoLayers.add(layer)
        applyVideoPresentation(refreshFrame: true)
    }

    func detachVideoLayer(_ layer: AVPlayerLayer) {
        if layer.player === player {
            layer.player = nil
        }
        videoLayers.remove(layer)
        applyVideoPresentation(refreshFrame: false)
    }

    // MARK: - Queue helpers

    private var currentEntry: QueueEntry? {
        guard let index = currentIndex, entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    private var effectiveRate: Float {
        guard playbackRate.isFinite else { return 1 }
        return min(max(playbackRate, 0.5), 2.0)
    }

    private func makeEntry(_ trackID: String) -> QueueEntry {
        nextEntryUID &+= 1
        return QueueEntry(uid: nextEntryUID, trackID: trackID)
    }

    /// Common bookkeeping after a queue edit that keeps the current track.
    private func queueDidChange() {
        refreshRemoteCommandStates()
        publishNowPlaying()
        saveState()
    }

    private func setRepeatMode(_ mode: RepeatMode) {
        if repeatMode != mode {
            repeatMode = mode
        }
        refreshRemoteCommandStates()
        saveState()
    }

    // MARK: - Loading items

    /// Loads the file for `entries[currentIndex]` into the player.
    /// - Parameters:
    ///   - autoPlay: start playing as soon as possible.
    ///   - startAt: position to seek to once the item is ready.
    ///   - reportErrors: false for the session restored at launch (no alerts, no auto-skip).
    private func loadCurrentEntry(autoPlay: Bool, startAt: TimeInterval = 0, reportErrors: Bool = true) {
        cancelFailureSkip()
        removeItemObservers()
        // Reloading the same song keeps its known video shape (no flicker); anything else resets it.
        if videoAspectRatio != nil, currentEntry?.trackID != loadedEntry?.trackID {
            videoAspectRatio = nil
        }
        pendingSeekTime = nil
        seeksInFlight = 0
        readyItemID = nil
        failedItemHandled = false
        listenedSeconds = 0
        lastTickPosition = nil
        playRecorded = false
        loadedItemReportsErrors = reportErrors
        wantsToPlay = autoPlay
        if !autoPlay, player.rate != 0 {
            // A non-zero rate would make the replacement item start on its own.
            player.pause()
        }

        guard let entry = currentEntry else {
            loadedEntry = nil
            player.replaceCurrentItem(with: nil)
            currentTime = 0
            duration = 0
            if isPlaying { isPlaying = false }
            refreshRemoteCommandStates()
            publishNowPlaying()
            return
        }

        guard let track = library.track(id: entry.trackID) else {
            // The song disappeared from the library (deleted / folder unlinked) without a removal
            // callback: drop every missing entry and continue with the next available one.
            dropMissingEntries(autoPlay: autoPlay)
            return
        }

        loadedEntry = entry
        let safeStart = startAt.isFinite ? max(0, startAt) : 0
        currentTime = safeStart
        duration = track.duration.isFinite ? max(0, track.duration) : 0

        guard let url = library.url(for: track) else {
            player.replaceCurrentItem(with: nil)
            refreshRemoteCommandStates()
            publishNowPlaying()
            handlePlaybackFailure(title: track.title)
            return
        }

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.audioTimePitchAlgorithm = .spectral
        installItemObservers(for: item)
        player.replaceCurrentItem(with: item)

        if safeStart > 0.5, duration <= 0 || safeStart < duration - 1 {
            pendingSeekTime = safeStart
        } else {
            currentTime = 0
        }

        applyVideoPresentation(refreshFrame: false)
        refreshRemoteCommandStates()
        if autoPlay {
            startPlayback()
        }
        publishNowPlaying()
        if reportErrors {
            saveState()
        }
    }

    private func dropMissingEntries(autoPlay: Bool) {
        var missing = Set<String>()
        for entry in entries where library.track(id: entry.trackID) == nil {
            missing.insert(entry.trackID)
        }
        guard !missing.isEmpty else { return }
        removeEntries(withTrackIDs: missing, autoPlayReplacement: autoPlay)
    }

    private func installItemObservers(for item: AVPlayerItem) {
        let itemID = ObjectIdentifier(item)
        itemStatusObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
            let engine = self
            performOnMain { engine?.handleItemStatusChange(itemID: itemID) }
        }
        itemPresentationSizeObservation = item.observe(\.presentationSize, options: [.new]) { @Sendable [weak self] _, _ in
            let engine = self
            performOnMain { engine?.handlePresentationSizeChange(itemID: itemID) }
        }

        let center = NotificationCenter.default
        let endToken = center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { @Sendable [weak self] _ in
            let engine = self
            performOnMain { engine?.handleItemDidPlayToEnd(itemID: itemID) }
        }
        let failToken = center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { @Sendable [weak self] note in
            let engine = self
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            performOnMain { engine?.handleItemFailedToPlayToEnd(itemID: itemID, message: message) }
        }
        itemObserverTokens = [endToken, failToken]
    }

    private func removeItemObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        itemPresentationSizeObservation?.invalidate()
        itemPresentationSizeObservation = nil
        let center = NotificationCenter.default
        for token in itemObserverTokens {
            center.removeObserver(token)
        }
        itemObserverTokens.removeAll()
    }

    private func isCurrentItem(_ itemID: ObjectIdentifier) -> Bool {
        guard let item = player.currentItem else { return false }
        return ObjectIdentifier(item) == itemID
    }

    private func handleItemStatusChange(itemID: ObjectIdentifier) {
        guard let item = player.currentItem, ObjectIdentifier(item) == itemID else { return }
        switch item.status {
        case .readyToPlay:
            guard readyItemID != itemID else { return }
            readyItemID = itemID
            handleItemReady(item)
        case .failed:
            handleItemFailure(message: item.error?.localizedDescription)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleItemReady(_ item: AVPlayerItem) {
        consecutiveFailures = 0
        if let itemDuration = finiteSeconds(item.duration), itemDuration > 0 {
            duration = itemDuration
        }
        if loadedEntry.flatMap({ library.track(id: $0.trackID) })?.isVideo == true {
            loadVideoAspectRatio(of: item)
        }
        applyVideoPresentation(refreshFrame: false)
        if let target = pendingSeekTime {
            pendingSeekTime = nil
            performSeek(to: target) { [weak self] in
                guard let self, self.wantsToPlay else { return }
                self.startPlayback()
            }
        } else if wantsToPlay, player.rate == 0 {
            startPlayback()
        }
        publishNowPlaying()
    }

    private func handleItemFailedToPlayToEnd(itemID: ObjectIdentifier, message: String?) {
        guard isCurrentItem(itemID) else { return }
        handleItemFailure(message: message)
    }

    private func handleItemFailure(message: String?) {
        guard !failedItemHandled else { return }
        failedItemHandled = true
        let title = loadedEntry.flatMap { library.track(id: $0.trackID) }?.title
        playerLog.error("Playback failed for \(title ?? "unknown", privacy: .private): \(message ?? "unknown error", privacy: .public)")
        handlePlaybackFailure(title: title)
    }

    /// Reports the failure and skips to the next track after ~0.5 s; stops after 5 failures in a row.
    private func handlePlaybackFailure(title: String?) {
        cancelFailureSkip()
        // The paused session restored at launch never auto-skips or alerts: its file may simply not
        // be reachable yet. It is reloaded when the user presses play.
        guard loadedItemReportsErrors || wantsToPlay else {
            if isPlaying { isPlaying = false }
            return
        }
        let displayName = title ?? "this song"
        consecutiveFailures += 1
        if consecutiveFailures >= PlayerEngine.maxConsecutiveFailures {
            consecutiveFailures = 0
            wantsToPlay = false
            player.pause()
            if isPlaying { isPlaying = false }
            errorMessage = "Couldn't play “\(displayName)”. Playback stopped because several songs in a row couldn't be played."
            refreshRemoteCommandStates()
            publishNowPlaying()
            saveState()
            return
        }
        errorMessage = "Couldn't play “\(displayName)”. Skipping."
        beginBackgroundTask()
        failureSkipTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.failureSkipTask = nil
            self.skipAfterFailure()
            self.endBackgroundTask()
        }
    }

    private func skipAfterFailure() {
        guard let index = currentIndex, !entries.isEmpty else { return }
        let continuePlaying = wantsToPlay
        if index + 1 < entries.count {
            currentIndex = index + 1
            loadCurrentEntry(autoPlay: continuePlaying)
        } else if repeatMode != .off, entries.count > 1 {
            currentIndex = 0
            loadCurrentEntry(autoPlay: continuePlaying)
        } else {
            wantsToPlay = false
            player.pause()
            if isPlaying { isPlaying = false }
            refreshRemoteCommandStates()
            publishNowPlaying()
            saveState()
        }
    }

    private func cancelFailureSkip() {
        failureSkipTask?.cancel()
        failureSkipTask = nil
        endBackgroundTask()
    }

    // MARK: - Playback flow

    private func startPlayback() {
        wantsToPlay = true
        activateAudioSession()
        player.defaultRate = effectiveRate
        guard player.currentItem != nil, pendingSeekTime == nil else { return }
        player.play()
    }

    private func advance(userInitiated: Bool) {
        guard !entries.isEmpty else { return }
        // A natural track end means we were playing; a user skip keeps the current play/pause state.
        let continuePlaying = userInitiated ? (isPlaying || wantsToPlay) : true
        guard let index = currentIndex, entries.indices.contains(index) else {
            currentIndex = 0
            loadCurrentEntry(autoPlay: continuePlaying)
            return
        }
        if index + 1 < entries.count {
            currentIndex = index + 1
            loadCurrentEntry(autoPlay: continuePlaying)
        } else if repeatMode == .all || (userInitiated && repeatMode == .one) {
            if entries.count == 1 {
                restartCurrentTrack(play: continuePlaying)
            } else {
                currentIndex = 0
                loadCurrentEntry(autoPlay: continuePlaying)
            }
        } else {
            stopAtEndOfQueue()
        }
    }

    private func restartCurrentTrack(play: Bool) {
        listenedSeconds = 0
        lastTickPosition = nil
        playRecorded = false
        guard let item = player.currentItem, item.status != .failed else {
            loadCurrentEntry(autoPlay: play)
            return
        }
        if play {
            wantsToPlay = true
        }
        performSeek(to: 0) { [weak self] in
            guard let self, self.wantsToPlay else { return }
            self.startPlayback()
        }
        saveState()
    }

    /// End of queue with repeat off: paused on the last track, rewound to 0.
    private func stopAtEndOfQueue() {
        wantsToPlay = false
        player.pause()
        listenedSeconds = 0
        lastTickPosition = nil
        playRecorded = false
        if player.currentItem != nil {
            performSeek(to: 0)
        }
        currentTime = 0
        if isPlaying { isPlaying = false }
        refreshRemoteCommandStates()
        publishNowPlaying()
        saveState()
    }

    private func handleItemDidPlayToEnd(itemID: ObjectIdentifier) {
        guard isCurrentItem(itemID) else { return }
        recordPlayIfNeeded(force: true)

        if sleepAtEndOfTrack {
            sleepAtEndOfTrack = false
            wantsToPlay = false
            player.pause()
            if repeatMode != .one, let index = currentIndex, index + 1 < entries.count {
                currentIndex = index + 1
                loadCurrentEntry(autoPlay: false)
            } else if repeatMode == .all, entries.count > 1 {
                currentIndex = 0
                loadCurrentEntry(autoPlay: false)
            } else {
                stopAtEndOfQueue()
            }
            if isPlaying { isPlaying = false }
            publishNowPlaying()
            return
        }

        if repeatMode == .one {
            restartCurrentTrack(play: true)
            return
        }
        advance(userInitiated: false)
    }

    /// Seeks precisely; before the item is ready the seek is deferred until it is.
    private func performSeek(to seconds: TimeInterval, completion: (@MainActor @Sendable () -> Void)? = nil) {
        var target = seconds.isFinite ? max(0, seconds) : 0
        if duration > 0 {
            target = min(target, duration)
        }
        currentTime = target
        lastTickPosition = nil
        guard let item = player.currentItem else {
            completion?()
            return
        }
        guard item.status == .readyToPlay else {
            // Applied (and playback started if wanted) by handleItemReady.
            pendingSeekTime = target
            return
        }
        seeksInFlight += 1
        let time = CMTime(seconds: target, preferredTimescale: 1000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { @Sendable [weak self] _ in
            let engine = self
            performOnMain {
                guard let engine else { return }
                engine.seeksInFlight = max(0, engine.seeksInFlight - 1)
                completion?()
                engine.publishNowPlaying()
            }
        }
        publishNowPlaying()
    }

    /// Best current position: pending/in-flight seek target, else the player's clock.
    private func currentPlaybackTime() -> TimeInterval {
        if let pending = pendingSeekTime {
            return pending
        }
        if seeksInFlight > 0 {
            return currentTime
        }
        if let item = player.currentItem, item.status == .readyToPlay,
           let seconds = finiteSeconds(player.currentTime()) {
            return seconds
        }
        return currentTime
    }

    private func applyPlaybackRate() {
        let rate = effectiveRate
        player.defaultRate = rate
        if player.rate != 0 {
            player.rate = rate
        }
        publishNowPlaying()
    }

    private func recordPlayIfNeeded(force: Bool) {
        guard !playRecorded, let trackID = loadedEntry?.trackID else { return }
        let total = duration > 0 ? duration : (library.track(id: trackID)?.duration ?? 0)
        let threshold = total > 0 ? total * 0.5 : 30
        guard force || listenedSeconds >= threshold else { return }
        playRecorded = true
        library.recordPlay(trackID)
    }

    // MARK: - Player observation

    private static func makePlayer() -> AVPlayer {
        let player = AVPlayer()
        player.actionAtItemEnd = .pause
        player.allowsExternalPlayback = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.preventsDisplaySleepDuringVideoPlayback = false
        return player
    }

    private func installPlayerObservers() {
        let interval = CMTime(value: 1, timescale: 2)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { @Sendable [weak self] time in
            let engine = self
            performOnMain { engine?.handleTick(time) }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
            let engine = self
            performOnMain { engine?.handleTimeControlStatusChange() }
        }
        let playerID = ObjectIdentifier(player)
        playerStatusObservation = player.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
            let engine = self
            performOnMain { engine?.handlePlayerStatusChange(playerID: playerID) }
        }
    }

    /// A failed AVPlayer can never play anything again (typically after the media services were
    /// reset), so it is replaced.
    private func handlePlayerStatusChange(playerID: ObjectIdentifier) {
        guard ObjectIdentifier(player) == playerID, player.status == .failed else { return }
        playerLog.error("AVPlayer failed: \(self.player.error?.localizedDescription ?? "unknown error", privacy: .public)")
        // A replacement that fails straight away waits for the media services reset notification
        // instead of being rebuilt in a tight loop.
        guard Date().timeIntervalSince(lastPlayerRebuildDate) > 1 else { return }
        recoverPlayer()
    }

    /// Replaces the dead player and reloads the current song paused at the same position, without
    /// alerts or auto-skipping.
    private func recoverPlayer() {
        let position = pendingSeekTime ?? currentTime
        rebuildPlayer()
        if currentEntry != nil {
            loadCurrentEntry(autoPlay: false, startAt: position, reportErrors: false)
        }
        refreshRemoteCommandStates()
        publishNowPlaying()
    }

    private func rebuildPlayer() {
        removeItemObservers()
        let old = player
        if let token = timeObserverToken {
            old.removeTimeObserver(token)
            timeObserverToken = nil
        }
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
        old.pause()
        old.replaceCurrentItem(with: nil)

        player = PlayerEngine.makePlayer()
        lastPlayerRebuildDate = Date()
        installPlayerObservers()
        wantsToPlay = false
        loadedEntry = nil
        pendingSeekTime = nil
        seeksInFlight = 0
        readyItemID = nil
        if isPlaying { isPlaying = false }
        // Re-points every attached AVPlayerLayer at the new player.
        applyVideoPresentation(refreshFrame: false)
    }

    private func handleTick(_ time: CMTime) {
        guard let item = player.currentItem, seeksInFlight == 0, pendingSeekTime == nil else { return }
        guard let position = finiteSeconds(time) else { return }
        if abs(position - currentTime) >= 0.05 {
            currentTime = position
        }
        if let itemDuration = finiteSeconds(item.duration), itemDuration > 0, abs(itemDuration - duration) > 0.5 {
            duration = itemDuration
            publishNowPlaying()
        }
        if isPlaying, let last = lastTickPosition {
            let delta = position - last
            if delta > 0, delta <= 2.5 {
                listenedSeconds += delta
            }
        }
        lastTickPosition = position
        recordPlayIfNeeded(force: false)
        if isPlaying, Date().timeIntervalSince(lastSaveDate) >= PlayerEngine.periodicSaveInterval {
            saveState()
        }
    }

    private func handleTimeControlStatusChange() {
        var playing: Bool
        switch player.timeControlStatus {
        case .playing:
            playing = true
        case .waitingToPlayAtSpecifiedRate:
            playing = player.currentItem != nil && player.reasonForWaitingToPlay != .noItemToPlay
        case .paused:
            playing = false
        @unknown default:
            playing = false
        }
        // At the end of an item the player pauses for a moment before the next one starts;
        // keep showing "playing" so buttons don't flicker. The end handler decides what happens.
        if !playing, wantsToPlay, currentItemReachedEnd() {
            playing = true
        }
        if isPlaying != playing {
            isPlaying = playing
        }
        if !playing {
            currentTime = currentPlaybackTime()
        }
        publishNowPlaying()
    }

    private func currentItemReachedEnd() -> Bool {
        guard let item = player.currentItem,
              let total = finiteSeconds(item.duration), total > 0,
              let position = finiteSeconds(item.currentTime()) else { return false }
        return position >= total - 0.3
    }

    // MARK: - Audio session & system events

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        } catch {
            playerLog.error("Long-form audio category failed: \(error.localizedDescription, privacy: .public)")
            do {
                try session.setCategory(.playback, mode: .default, options: [])
            } catch {
                playerLog.error("Playback category failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            playerLog.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func installSystemObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        systemObserverTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { @Sendable [weak self] note in
            let engine = self
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            performOnMain { engine?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw) }
        })

        systemObserverTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { @Sendable [weak self] note in
            let engine = self
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            performOnMain { engine?.handleRouteChange(reasonRaw: reasonRaw) }
        })

        addSystemObserver(AVAudioSession.mediaServicesWereResetNotification, object: session) { engine in
            engine.handleMediaServicesReset()
        }
        addSystemObserver(UIApplication.didEnterBackgroundNotification) { engine in
            engine.handleDidEnterBackground()
        }
        addSystemObserver(UIApplication.willEnterForegroundNotification) { engine in
            engine.handleWillEnterForeground()
        }
        addSystemObserver(UIApplication.didBecomeActiveNotification) { engine in
            engine.handleWillEnterForeground()
        }
        addSystemObserver(UIApplication.willTerminateNotification) { engine in
            engine.saveState()
        }
    }

    private func addSystemObserver(
        _ name: Notification.Name,
        object: AnyObject? = nil,
        _ action: @escaping @MainActor @Sendable (PlayerEngine) -> Void
    ) {
        let token = NotificationCenter.default.addObserver(
            forName: name,
            object: object,
            queue: .main
        ) { @Sendable [weak self] _ in
            let engine = self
            performOnMain {
                if let engine {
                    action(engine)
                }
            }
        }
        systemObserverTokens.append(token)
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying || wantsToPlay
            wantsToPlay = false
            currentTime = currentPlaybackTime()
            if isPlaying { isPlaying = false }
            publishNowPlaying()
            saveState()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            let shouldResume = options.contains(.shouldResume) && wasPlayingBeforeInterruption
            wasPlayingBeforeInterruption = false
            if let endDate = sleepTimerEndDate, endDate <= Date() {
                // The sleep timer ran out during the interruption: stay paused.
                cancelSleepTimer()
                return
            }
            if shouldResume {
                resume()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonRaw, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        // Headphones unplugged / Bluetooth or car disconnected: pause instead of blasting the speaker.
        // This also applies during an interruption (e.g. a call): the end of the call must not
        // restart the music on the speaker.
        if reason == .oldDeviceUnavailable {
            wasPlayingBeforeInterruption = false
            if isPlaying || wantsToPlay {
                pause()
            }
        }
    }

    private func handleMediaServicesReset() {
        playerLog.notice("Media services were reset; rebuilding audio session, player and item")
        configureAudioSession()
        nowPlaying.unregisterCommands()
        registerRemoteCommands()
        // Every AVFoundation object created before the reset is dead, the player included.
        recoverPlayer()
    }

    private func handleDidEnterBackground() {
        isInForeground = false
        applyVideoPresentation(refreshFrame: false)
        saveState()
    }

    private func handleWillEnterForeground() {
        if !(isPlaying || wantsToPlay) {
            // A deadline that passed while suspended: don't show "Sleep in 0:00" until the task wakes.
            expireStaleSleepTimer()
        }
        guard !isInForeground else { return }
        isInForeground = true
        applyVideoPresentation(refreshFrame: true)
    }

    // MARK: - Video presentation (Apple QA1668)

    /// Video tracks are decoded only when the user asked for the picture, the app is in the
    /// foreground and a video layer is on screen. In the background every layer is detached so the
    /// audio keeps playing.
    private func applyVideoPresentation(refreshFrame: Bool) {
        let layers = videoLayers.allObjects
        let desiredPlayer: AVPlayer? = isInForeground ? player : nil
        for layer in layers where layer.player !== desiredPlayer {
            layer.player = desiredPlayer
        }

        let isVideoTrack = loadedEntry.flatMap { library.track(id: $0.trackID) }?.isVideo ?? false
        let wantsVisual = showVideo && isInForeground && !layers.isEmpty && isVideoTrack
        if player.preventsDisplaySleepDuringVideoPlayback != wantsVisual {
            player.preventsDisplaySleepDuringVideoPlayback = wantsVisual
        }

        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        var enabledVisualTrack = false
        for itemTrack in item.tracks {
            guard let assetTrack = itemTrack.assetTrack, assetTrack.mediaType == .video else { continue }
            if itemTrack.isEnabled != wantsVisual {
                itemTrack.isEnabled = wantsVisual
                if wantsVisual {
                    enabledVisualTrack = true
                }
            }
        }
        // A paused player shows nothing until it decodes a frame; nudge it to the current position.
        if enabledVisualTrack, refreshFrame, !isPlaying, seeksInFlight == 0, pendingSeekTime == nil {
            performSeek(to: currentPlaybackTime())
        }
    }

    /// Reads the video's display size from the file, so its shape is known before the picture is
    /// first shown (the item's `presentationSize` may stay zero while its video track is disabled).
    private func loadVideoAspectRatio(of item: AVPlayerItem) {
        let itemID = ObjectIdentifier(item)
        let asset = item.asset
        Task { [weak self] in
            guard let size = await PlayerEngine.displaySize(ofVideoIn: asset) else { return }
            guard let self, self.isCurrentItem(itemID) else { return }
            self.updateVideoAspectRatio(size)
        }
    }

    nonisolated private static func displaySize(ofVideoIn asset: AVAsset) async -> CGSize? {
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let geometry = try? await videoTrack.load(.naturalSize, .preferredTransform) else {
            return nil
        }
        return CGRect(origin: .zero, size: geometry.0).applying(geometry.1).size
    }

    private func handlePresentationSizeChange(itemID: ObjectIdentifier) {
        guard let item = player.currentItem, ObjectIdentifier(item) == itemID else { return }
        updateVideoAspectRatio(item.presentationSize)
    }

    /// Ignores empty / invalid sizes (e.g. while the video track is disabled), keeping the last shape.
    private func updateVideoAspectRatio(_ size: CGSize) {
        let width = abs(size.width)
        let height = abs(size.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return }
        let ratio = width / height
        guard ratio.isFinite, ratio > 0 else { return }
        if let current = videoAspectRatio, abs(current - ratio) < 0.001 { return }
        videoAspectRatio = ratio
    }

    // MARK: - Library changes

    private func handleTracksRemoved(_ ids: Set<String>) {
        guard !ids.isEmpty, entries.contains(where: { ids.contains($0.trackID) }) else { return }
        removeEntries(withTrackIDs: ids, autoPlayReplacement: false)
    }

    /// Removes every queue slot for `ids`. If the current track goes, playback stops and the next
    /// remaining track is prepared (paused unless `autoPlayReplacement`).
    private func removeEntries(withTrackIDs ids: Set<String>, autoPlayReplacement: Bool) {
        let oldIndex = currentIndex ?? 0
        let currentRemoved = currentEntry.map { ids.contains($0.trackID) } ?? true
        var removedBefore = 0
        for entry in entries.prefix(oldIndex) where ids.contains(entry.trackID) {
            removedBefore += 1
        }
        originalEntries.removeAll { ids.contains($0.trackID) }
        entries.removeAll { ids.contains($0.trackID) }
        guard !entries.isEmpty else {
            clearQueue()
            return
        }
        currentIndex = min(max(0, oldIndex - removedBefore), entries.count - 1)
        if currentRemoved {
            if !autoPlayReplacement {
                player.pause()
            }
            loadCurrentEntry(autoPlay: autoPlayReplacement)
        } else {
            queueDidChange()
        }
    }

    // MARK: - Restoration

    private func restoreState() {
        guard let state = PlaybackStateStore.load(), !state.queue.isEmpty else { return }
        let savedIndex = state.currentIndex.flatMap { state.queue.indices.contains($0) ? $0 : nil } ?? 0

        var restored: [QueueEntry] = []
        restored.reserveCapacity(state.queue.count)
        var restoredIndex: Int?
        var currentSurvived = false
        for (offset, trackID) in state.queue.enumerated() where library.track(id: trackID) != nil {
            if restoredIndex == nil, offset >= savedIndex {
                restoredIndex = restored.count
                currentSurvived = offset == savedIndex
            }
            restored.append(makeEntry(trackID))
        }
        guard !restored.isEmpty else { return }

        var original: [QueueEntry] = []
        if state.shuffleEnabled {
            // Match each original-order ID to a restored slot (occurrence by occurrence).
            var pool: [String: [QueueEntry]] = [:]
            for entry in restored {
                pool[entry.trackID, default: []].append(entry)
            }
            original.reserveCapacity(restored.count)
            for trackID in state.originalQueue {
                guard var candidates = pool[trackID], !candidates.isEmpty else { continue }
                original.append(candidates.removeFirst())
                pool[trackID] = candidates
            }
            if original.count < restored.count {
                let used = Set(original.map(\.uid))
                original.append(contentsOf: restored.filter { !used.contains($0.uid) })
            }
        } else {
            original = restored
        }

        originalEntries = original
        entries = restored
        currentIndex = min(restoredIndex ?? (restored.count - 1), restored.count - 1)
        shuffleEnabled = state.shuffleEnabled
        repeatMode = state.repeatMode
        playbackRate = state.playbackRate.isFinite ? min(max(state.playbackRate, 0.5), 2.0) : 1
        let resumeAt = currentSurvived ? state.currentTime : 0
        loadCurrentEntry(autoPlay: false, startAt: resumeAt, reportErrors: false)
    }

    // MARK: - Now Playing & remote commands

    private func registerRemoteCommands() {
        nowPlaying.registerCommands(NowPlayingController.Handlers(
            play: { [weak self] in
                guard let self, self.currentEntry != nil else { return false }
                self.resume()
                return true
            },
            pause: { [weak self] in
                guard let self, self.currentEntry != nil else { return false }
                self.pause()
                return true
            },
            togglePlayPause: { [weak self] in
                guard let self, self.currentEntry != nil else { return false }
                self.togglePlayPause()
                return true
            },
            stop: { [weak self] in
                guard let self, self.currentEntry != nil else { return false }
                self.pause()
                return true
            },
            nextTrack: { [weak self] in
                guard let self, self.currentEntry != nil else { return false }
                self.next()
                return true
            },
            previousTrack: { [weak self] in
                guard let self, self.currentEntry != nil else { return false }
                self.previous()
                return true
            },
            changePosition: { [weak self] position in
                guard let self, self.currentEntry != nil, position.isFinite else { return false }
                self.seek(to: position)
                return true
            },
            changeRepeatMode: { [weak self] mode in
                guard let self, self.currentEntry != nil else { return false }
                self.setRepeatMode(mode)
                return true
            },
            changeShuffle: { [weak self] enabled in
                guard let self, self.currentEntry != nil else { return false }
                if self.shuffleEnabled != enabled {
                    self.toggleShuffle()
                }
                return true
            },
            changeRate: { [weak self] rate in
                guard let self, self.currentEntry != nil, rate.isFinite, rate > 0 else { return false }
                self.playbackRate = min(max(rate, 0.5), 2.0)
                return true
            }
        ))
    }

    private func refreshRemoteCommandStates() {
        let hasTrack = currentEntry != nil
        let index = currentIndex ?? 0
        let canGoNext = hasTrack && (index + 1 < entries.count || repeatMode != .off)
        nowPlaying.updateCommandStates(
            hasTrack: hasTrack,
            canGoNext: canGoNext,
            canGoPrevious: hasTrack,
            repeatMode: repeatMode,
            shuffleEnabled: shuffleEnabled
        )
    }

    private func publishNowPlaying() {
        guard let index = currentIndex,
              let entry = currentEntry,
              let track = library.track(id: entry.trackID) else {
            nowPlaying.clear()
            return
        }
        nowPlaying.update(NowPlayingController.Snapshot(
            track: track,
            duration: duration > 0 ? duration : track.duration,
            elapsed: currentPlaybackTime(),
            rate: effectiveRate,
            isPlaying: isPlaying,
            queueIndex: index,
            queueCount: entries.count
        ))
    }

    // MARK: - Sleep timer

    private func cancelSleepTimer() {
        let hadTimer = sleepTimerTask != nil || sleepTimerEndDate != nil
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        if sleepTimerEndDate != nil {
            sleepTimerEndDate = nil
        }
        if hadTimer {
            player.volume = 1
        }
    }

    /// A deadline in the past means the timer ran out while nothing was playing (the app is usually
    /// suspended then, so its task could not run): it has nothing left to stop. Clears it so it can
    /// never fade out playback started later, nor let an interruption end restart the music.
    /// Not used while the timer's own fade-out runs, except when the user starts playback.
    private func expireStaleSleepTimer() {
        guard let endDate = sleepTimerEndDate, endDate <= Date() else { return }
        cancelSleepTimer()
        wasPlayingBeforeInterruption = false
    }

    /// Fades the volume out over ~3 s, pauses, then restores the volume for next time.
    private func fadeOutForSleepTimer() async {
        if isPlaying || wantsToPlay {
            let steps = 30
            for step in 1...steps {
                if Task.isCancelled {
                    player.volume = 1
                    return
                }
                player.volume = max(0, 1 - Float(step) / Float(steps))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if Task.isCancelled {
                player.volume = 1
                return
            }
            pause()
        } else {
            // Nothing playing (e.g. during a call): the time is up, so the end of the
            // interruption must not start the music again.
            wasPlayingBeforeInterruption = false
        }
        player.volume = 1
        sleepTimerEndDate = nil
        sleepTimerTask = nil
    }

    // MARK: - Background task (keeps the app alive while skipping a broken file in background)

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Musicbox.PlaybackRecovery") { [weak self] in
            let engine = self
            performOnMain { engine?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
}
