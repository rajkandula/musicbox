import Foundation

/// Snapshot of the playback session that survives app launches (queue, position, modes).
struct PlaybackState: Codable, Equatable, Sendable {
    /// Track IDs in the current play order (shuffled order when shuffle is on).
    var queue: [String]
    /// Track IDs in the un-shuffled order, used to restore order when shuffle is turned off.
    var originalQueue: [String]
    /// Index into `queue` of the current track.
    var currentIndex: Int?
    /// Playback position of the current track, in seconds.
    var currentTime: TimeInterval
    var shuffleEnabled: Bool
    var repeatMode: RepeatMode
    var playbackRate: Float

    init(
        queue: [String],
        originalQueue: [String],
        currentIndex: Int?,
        currentTime: TimeInterval,
        shuffleEnabled: Bool,
        repeatMode: RepeatMode,
        playbackRate: Float
    ) {
        self.queue = queue
        self.originalQueue = originalQueue
        self.currentIndex = currentIndex
        self.currentTime = currentTime
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
        self.playbackRate = playbackRate
    }

    private enum CodingKeys: String, CodingKey {
        case queue, originalQueue, currentIndex, currentTime, shuffleEnabled, repeatMode, playbackRate
    }

    /// Tolerant decoding: a missing or malformed field falls back to a sensible default instead of
    /// discarding the whole saved session.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queue = (try? container.decodeIfPresent([String].self, forKey: .queue)) ?? []
        originalQueue = (try? container.decodeIfPresent([String].self, forKey: .originalQueue)) ?? queue
        currentIndex = (try? container.decodeIfPresent(Int.self, forKey: .currentIndex)) ?? nil
        let time = (try? container.decodeIfPresent(Double.self, forKey: .currentTime)) ?? 0
        currentTime = time.isFinite ? max(0, time) : 0
        shuffleEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .shuffleEnabled)) ?? false
        repeatMode = (try? container.decodeIfPresent(RepeatMode.self, forKey: .repeatMode)) ?? .off
        let rate = (try? container.decodeIfPresent(Float.self, forKey: .playbackRate)) ?? 1
        playbackRate = rate.isFinite ? min(max(rate, 0.5), 2.0) : 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(queue, forKey: .queue)
        try container.encode(originalQueue, forKey: .originalQueue)
        try container.encodeIfPresent(currentIndex, forKey: .currentIndex)
        try container.encode(currentTime.isFinite ? max(0, currentTime) : 0, forKey: .currentTime)
        try container.encode(shuffleEnabled, forKey: .shuffleEnabled)
        try container.encode(repeatMode, forKey: .repeatMode)
        try container.encode(playbackRate.isFinite ? playbackRate : 1, forKey: .playbackRate)
    }
}

/// Persists `PlaybackState` as `applicationSupport/playback.json` through `JSONStore`.
@MainActor
enum PlaybackStateStore {
    static let fileName = "playback"

    /// The last saved session, or nil when none exists or the file is unreadable.
    static func load() -> PlaybackState? {
        JSONStore.load(PlaybackState.self, from: fileName)
    }

    static func save(_ state: PlaybackState) {
        JSONStore.save(state, to: fileName)
    }
}
