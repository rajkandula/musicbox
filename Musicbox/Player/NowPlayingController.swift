import MediaPlayer
import UIKit

/// Owns the system-facing side of playback: the lock screen / Control Center "Now Playing" card
/// (`MPNowPlayingInfoCenter`) and the remote commands sent by the lock screen, Control Center,
/// headphones, Bluetooth accessories and car head units (`MPRemoteCommandCenter`).
///
/// `PlayerEngine` creates one instance, registers its command handlers once and pushes snapshots
/// whenever something the system displays changes (track, play/pause, seek, rate, queue position).
/// Elapsed time is NOT pushed every tick: the system extrapolates it from the playback rate.
@MainActor
final class NowPlayingController {

    /// Actions invoked by remote commands. Each returns `false` when there is nothing to act on
    /// (no current track), which is reported to the system as `.commandFailed`.
    struct Handlers {
        var play: @MainActor @Sendable () -> Bool
        var pause: @MainActor @Sendable () -> Bool
        var togglePlayPause: @MainActor @Sendable () -> Bool
        var stop: @MainActor @Sendable () -> Bool
        var nextTrack: @MainActor @Sendable () -> Bool
        var previousTrack: @MainActor @Sendable () -> Bool
        var changePosition: @MainActor @Sendable (TimeInterval) -> Bool
        var changeRepeatMode: @MainActor @Sendable (RepeatMode) -> Bool
        var changeShuffle: @MainActor @Sendable (Bool) -> Bool
        var changeRate: @MainActor @Sendable (Float) -> Bool
    }

    /// Everything the Now Playing card shows for the current track.
    struct Snapshot {
        var track: Track
        var duration: TimeInterval
        var elapsed: TimeInterval
        /// The user's chosen speed (applied while playing).
        var rate: Float
        var isPlaying: Bool
        var queueIndex: Int
        var queueCount: Int
    }

    /// Speeds offered to the system for `changePlaybackRateCommand`.
    static let supportedPlaybackRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    private struct DisplayedMetadata: Equatable {
        let trackID: String
        let title: String
        let artist: String
        let album: String
        let albumArtist: String?
        let genre: String?
        let hasArtwork: Bool
        let isVideo: Bool
    }

    private let commandCenter: MPRemoteCommandCenter
    private let infoCenter: MPNowPlayingInfoCenter
    private var registrations: [(command: MPRemoteCommand, target: Any)] = []
    private var info: [String: Any] = [:]
    private var displayedMetadata: DisplayedMetadata?
    private var placeholderArtworks: [Bool: MPMediaItemArtwork] = [:]

    init() {
        commandCenter = MPRemoteCommandCenter.shared()
        infoCenter = MPNowPlayingInfoCenter.default()
    }

    // MARK: - Remote commands

    /// Registers targets for every supported command (replacing earlier registrations) and disables
    /// the commands this player does not support, so the lock screen shows previous/next buttons
    /// rather than 15-second skip buttons.
    func registerCommands(_ handlers: Handlers) {
        unregisterCommands()
        let center = commandCenter

        addTarget(center.playCommand) { _ in
            handlers.play() ? .success : .commandFailed
        }
        addTarget(center.pauseCommand) { _ in
            handlers.pause() ? .success : .commandFailed
        }
        addTarget(center.togglePlayPauseCommand) { _ in
            handlers.togglePlayPause() ? .success : .commandFailed
        }
        addTarget(center.stopCommand) { _ in
            handlers.stop() ? .success : .commandFailed
        }
        addTarget(center.nextTrackCommand) { _ in
            handlers.nextTrack() ? .success : .commandFailed
        }
        addTarget(center.previousTrackCommand) { _ in
            handlers.previousTrack() ? .success : .commandFailed
        }
        addTarget(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return handlers.changePosition(event.positionTime) ? .success : .commandFailed
        }
        addTarget(center.changeRepeatModeCommand) { event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            return handlers.changeRepeatMode(NowPlayingController.repeatMode(for: event.repeatType))
                ? .success : .commandFailed
        }
        addTarget(center.changeShuffleModeCommand) { event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            return handlers.changeShuffle(event.shuffleType != .off) ? .success : .commandFailed
        }
        center.changePlaybackRateCommand.supportedPlaybackRates =
            NowPlayingController.supportedPlaybackRates.map { NSNumber(value: $0) }
        addTarget(center.changePlaybackRateCommand) { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            return handlers.changeRate(event.playbackRate) ? .success : .commandFailed
        }

        let unsupported: [MPRemoteCommand] = [
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.seekForwardCommand,
            center.seekBackwardCommand,
            center.ratingCommand,
            center.likeCommand,
            center.dislikeCommand,
            center.bookmarkCommand,
            center.enableLanguageOptionCommand,
            center.disableLanguageOptionCommand,
        ]
        for command in unsupported {
            command.isEnabled = false
        }
    }

    /// Removes every target added by `registerCommands`.
    func unregisterCommands() {
        for registration in registrations {
            registration.command.removeTarget(registration.target)
        }
        registrations.removeAll()
    }

    /// Enables/greys out queue-dependent buttons and mirrors repeat/shuffle state to the system UI.
    func updateCommandStates(
        hasTrack: Bool,
        canGoNext: Bool,
        canGoPrevious: Bool,
        repeatMode: RepeatMode,
        shuffleEnabled: Bool
    ) {
        setEnabled(commandCenter.nextTrackCommand, canGoNext)
        setEnabled(commandCenter.previousTrackCommand, canGoPrevious)
        setEnabled(commandCenter.changePlaybackPositionCommand, hasTrack)
        setEnabled(commandCenter.changeRepeatModeCommand, hasTrack)
        setEnabled(commandCenter.changeShuffleModeCommand, hasTrack)
        setEnabled(commandCenter.changePlaybackRateCommand, hasTrack)

        let repeatType = NowPlayingController.repeatType(for: repeatMode)
        if commandCenter.changeRepeatModeCommand.currentRepeatType != repeatType {
            commandCenter.changeRepeatModeCommand.currentRepeatType = repeatType
        }
        let shuffleType: MPShuffleType = shuffleEnabled ? .items : .off
        if commandCenter.changeShuffleModeCommand.currentShuffleType != shuffleType {
            commandCenter.changeShuffleModeCommand.currentShuffleType = shuffleType
        }
    }

    // MARK: - Now Playing info

    /// Publishes the current track and playback position/rate to the lock screen and Control Center.
    /// Metadata and artwork are only rebuilt when they actually change.
    func update(_ snapshot: Snapshot) {
        let track = snapshot.track
        let metadata = DisplayedMetadata(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            albumArtist: track.albumArtist,
            genre: track.genre,
            hasArtwork: track.hasArtwork,
            isVideo: track.isVideo
        )
        if metadata != displayedMetadata {
            let previous = displayedMetadata
            displayedMetadata = metadata
            setInfo(MPMediaItemPropertyTitle, track.title)
            setInfo(MPMediaItemPropertyArtist, track.artist)
            setInfo(MPMediaItemPropertyAlbumTitle, track.album)
            setInfo(MPMediaItemPropertyAlbumArtist, track.albumArtist)
            setInfo(MPMediaItemPropertyGenre, track.genre)
            setInfo(MPNowPlayingInfoPropertyMediaType, NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue))
            setInfo(MPNowPlayingInfoPropertyIsLiveStream, NSNumber(value: false))
            let artworkChanged = previous?.trackID != metadata.trackID
                || previous?.hasArtwork != metadata.hasArtwork
                || previous?.isVideo != metadata.isVideo
            if artworkChanged {
                setInfo(MPMediaItemPropertyArtwork, artwork(for: track))
            }
        }

        let duration = snapshot.duration.isFinite ? max(0, snapshot.duration) : 0
        var elapsed = snapshot.elapsed.isFinite ? max(0, snapshot.elapsed) : 0
        if duration > 0 {
            elapsed = min(elapsed, duration)
        }
        let rate = snapshot.rate.isFinite && snapshot.rate > 0 ? Double(snapshot.rate) : 1
        setInfo(MPMediaItemPropertyPlaybackDuration, NSNumber(value: duration))
        setInfo(MPNowPlayingInfoPropertyElapsedPlaybackTime, NSNumber(value: elapsed))
        setInfo(MPNowPlayingInfoPropertyPlaybackRate, NSNumber(value: snapshot.isPlaying ? rate : 0))
        setInfo(MPNowPlayingInfoPropertyDefaultPlaybackRate, NSNumber(value: rate))
        setInfo(MPNowPlayingInfoPropertyPlaybackQueueIndex, NSNumber(value: max(0, snapshot.queueIndex)))
        setInfo(MPNowPlayingInfoPropertyPlaybackQueueCount, NSNumber(value: max(0, snapshot.queueCount)))

        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = snapshot.isPlaying ? .playing : .paused
    }

    /// Removes the Now Playing card (queue cleared / nothing to play).
    func clear() {
        let hadInfo = !info.isEmpty || displayedMetadata != nil
        info.removeAll()
        displayedMetadata = nil
        if hadInfo || infoCenter.nowPlayingInfo != nil {
            infoCenter.nowPlayingInfo = nil
        }
        infoCenter.playbackState = .stopped
    }

    // MARK: - Private helpers

    private func setInfo(_ key: String, _ value: Any?) {
        if let value {
            info[key] = value
        } else {
            info.removeValue(forKey: key)
        }
    }

    private func setEnabled(_ command: MPRemoteCommand, _ enabled: Bool) {
        if command.isEnabled != enabled {
            command.isEnabled = enabled
        }
    }

    private func addTarget(
        _ command: MPRemoteCommand,
        _ body: @escaping @MainActor @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let target = command.addTarget(handler: NowPlayingController.makeHandler(body))
        registrations.append((command: command, target: target))
    }

    /// Wraps a main-actor handler so it is safe whichever thread MediaPlayer calls it on.
    /// Built in a nonisolated context so the returned closure carries no actor isolation.
    nonisolated private static func makeHandler(
        _ body: @escaping @MainActor @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        return { event in
            let box = EventBox(event: event)
            if Thread.isMainThread {
                return MainActor.assumeIsolated { body(box.event) }
            }
            // MediaPlayer delivers commands on the main thread; this path is purely defensive.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = body(box.event) }
            }
            return .success
        }
    }

    /// Carries a command event to the main queue. The event is only read there, never mutated.
    private struct EventBox: @unchecked Sendable {
        let event: MPRemoteCommandEvent
    }

    private func artwork(for track: Track) -> MPMediaItemArtwork {
        if let image = ArtworkCache.shared.image(for: track.id) {
            return NowPlayingController.makeArtwork(image)
        }
        return placeholderArtwork(isVideo: track.isVideo)
    }

    private func placeholderArtwork(isVideo: Bool) -> MPMediaItemArtwork {
        if let cached = placeholderArtworks[isVideo] {
            return cached
        }
        let artwork = NowPlayingController.makeArtwork(NowPlayingController.makePlaceholderImage(isVideo: isVideo))
        placeholderArtworks[isVideo] = artwork
        return artwork
    }

    /// The request handler may be called on a background thread, so it only captures the
    /// (immutable) image and touches no actor-isolated state.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// Accent gradient with a white music note (or film glyph for videos), 600×600.
    nonisolated private static func makePlaceholderImage(isVideo: Bool) -> UIImage {
        let size = CGSize(width: 600, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let accent = (UIColor(named: "AccentColor") ?? UIColor.systemPink)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let topColor = adjusted(accent, brightness: 1.08, saturation: 0.9)
        let bottomColor = adjusted(accent, brightness: 0.55, saturation: 1.05)

        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setFillColor(bottomColor.cgColor)
            cgContext.fill(CGRect(origin: .zero, size: size))
            let colors = [topColor.cgColor, bottomColor.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }

            let configuration = UIImage.SymbolConfiguration(pointSize: 230, weight: .medium)
            let symbolName = isVideo ? "film" : "music.note"
            if let symbol = UIImage(systemName: symbolName, withConfiguration: configuration)?
                .withTintColor(UIColor.white.withAlphaComponent(0.92), renderingMode: .alwaysOriginal) {
                let symbolSize = symbol.size
                let rect = CGRect(
                    x: (size.width - symbolSize.width) / 2,
                    y: (size.height - symbolSize.height) / 2,
                    width: symbolSize.width,
                    height: symbolSize.height
                )
                symbol.draw(in: rect)
            }
        }
    }

    nonisolated private static func adjusted(_ color: UIColor, brightness: CGFloat, saturation: CGFloat) -> UIColor {
        var hue: CGFloat = 0
        var sat: CGFloat = 0
        var bri: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) else {
            return color
        }
        return UIColor(
            hue: hue,
            saturation: min(max(sat * saturation, 0), 1),
            brightness: min(max(bri * brightness, 0), 1),
            alpha: 1
        )
    }

    // MARK: - Mode mapping

    nonisolated static func repeatMode(for type: MPRepeatType) -> RepeatMode {
        switch type {
        case .off: return .off
        case .one: return .one
        case .all: return .all
        @unknown default: return .off
        }
    }

    nonisolated static func repeatType(for mode: RepeatMode) -> MPRepeatType {
        switch mode {
        case .off: return .off
        case .one: return .one
        case .all: return .all
        }
    }
}
