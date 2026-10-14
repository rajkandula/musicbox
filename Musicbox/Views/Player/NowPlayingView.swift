import SwiftUI
import UIKit

/// Full-screen player presented as a sheet by RootView.
///
/// Shows large artwork (or the video when the current track is a video and "Show Video" is on,
/// the inline queue when the queue button is toggled, or live synced lyrics when the lyrics
/// button is toggled), title / artist / favorite, a scrubber,
/// transport controls, AirPlay, and a "…" menu with Add to Playlist, Sleep Timer and Playback Speed.
struct NowPlayingView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var showsQueue = false
    /// Lyrics mode is remembered, like Apple Music: once on, every song opens with its lyrics.
    @AppStorage("nowPlaying.showLyrics") private var showsLyrics = false

    private static let sleepTimerMinutes: [Int] = [5, 10, 15, 30, 45, 60]
    private static let playbackRates: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    init() {}

    var body: some View {
        @Bindable var router = router
        let track = player.currentTrack
        // Same condition as `mainArea` (the queue takes precedence over lyrics).
        let showsLyricsPanel = track != nil && showsLyrics && !showsQueue

        ZStack {
            NowPlayingBackdrop(trackID: track?.id, dimsForLyrics: showsLyricsPanel)

            if let track {
                playerLayout(for: track)
            } else {
                emptyState
            }
        }
        // The .lrc importer lives here, not in LyricsView: rotating switches between the two
        // layouts, which rebuilds the lyrics panel and would take an open file picker with it.
        .lyricsImportHost()
        .overlay(alignment: .top) {
            NowPlayingToastBanner(message: router.toast)
        }
        .environment(\.colorScheme, .dark)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.black)
        .sheet(item: $router.nowPlayingAddToPlaylistRequest) { request in
            AddToPlaylistSheet(trackIDs: request.trackIDs)
                .environment(library)
                .environment(player)
                .environment(router)
        }
        .onAppear {
            presentPlaybackError(player.errorMessage)
        }
        .onChange(of: player.errorMessage) { _, message in
            presentPlaybackError(message)
        }
        .onChange(of: track == nil) { _, isEmpty in
            if isEmpty { showsQueue = false }
        }
    }

    // MARK: - Main layout

    @ViewBuilder
    private func playerLayout(for track: Track) -> some View {
        if verticalSizeClass == .compact {
            compactHeightLayout(for: track)
        } else {
            regularLayout(for: track)
        }
    }

    /// Portrait: header, artwork / video / queue, then the controls stacked below.
    private func regularLayout(for track: Track) -> some View {
        VStack(spacing: 0) {
            header(for: track)
                .padding(.horizontal, 14)
                .padding(.top, 16)

            mainArea(for: track)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 6)

            VStack(spacing: 18) {
                titleRow(for: track)
                NowPlayingScrubber()
                transportControls
                bottomRow(for: track)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
        .foregroundStyle(.primary)
    }

    /// Landscape iPhone: the controls alone are taller than the screen when stacked under the
    /// artwork, so the artwork / video / queue gets the left side and the controls the right.
    private func compactHeightLayout(for track: Track) -> some View {
        GeometryReader { proxy in
            let controlsWidth = min(max(proxy.size.width * 0.45, 330), max(proxy.size.width * 0.6, 0))

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(for: track)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)

                    mainArea(for: track)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    titleRow(for: track)
                    NowPlayingScrubber()
                    transportControls
                    bottomRow(for: track)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(width: controlsWidth)
                .frame(maxHeight: .infinity)
            }
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func mainArea(for track: Track) -> some View {
        if showsQueue {
            QueueView()
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
        } else if showsLyrics {
            LyricsView(track: track)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        } else if track.isVideo && player.showVideo {
            PlayerVideoView(engine: player)
                .aspectRatio(Self.videoAspectRatio(player.videoAspectRatio), contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .accessibilityLabel("Video for \(track.title)")
        } else {
            GeometryReader { proxy in
                let side = Self.artworkSide(for: proxy.size)
                let isShrunk = !player.isPlaying && !reduceMotion

                ArtworkView(trackID: track.id, size: side, cornerRadius: 12, isVideo: track.isVideo)
                    .shadow(
                        color: .black.opacity(isShrunk ? 0.25 : 0.45),
                        radius: isShrunk ? 14 : 28,
                        x: 0,
                        y: isShrunk ? 8 : 16
                    )
                    .scaleEffect(isShrunk ? 0.84 : 1)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.72),
                        value: player.isPlaying
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .transition(.opacity)
        }
    }

    /// Artwork side: min(width - 48, 360), shrunk further on short screens so it never grows past
    /// the space it was given (and never overlaps the header or title).
    private static func artworkSide(for size: CGSize) -> CGFloat {
        let byWidth = size.width - 48
        let byHeight = size.height - 12
        return max(0, min(byWidth, byHeight, 360))
    }

    /// The video's real shape (portrait clips stay portrait); 16:9 until it is known.
    private static func videoAspectRatio(_ ratio: CGFloat?) -> CGFloat {
        guard let ratio, ratio.isFinite, ratio > 0 else { return 16.0 / 9.0 }
        return ratio
    }

    // MARK: - Header

    private func header(for track: Track) -> some View {
        HStack(spacing: 8) {
            closeButton

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(track.isVideo && !player.showVideo ? "Playing Video as Audio" : "Now Playing")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                NowPlayingStatusLine()
            }
            .lineLimit(1)
            .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            moreMenu(for: track)
        }
    }

    private var closeButton: some View {
        Button {
            router.isNowPlayingPresented = false
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(NowPlayingPressButtonStyle())
        .accessibilityLabel("Close Now Playing")
    }

    private func moreMenu(for track: Track) -> some View {
        Menu {
            Button {
                router.addToPlaylist([track.id])
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }

            Button {
                library.toggleFavorite(track.id)
            } label: {
                Label(
                    track.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: track.isFavorite ? "heart.slash" : "heart"
                )
            }

            Divider()

            Menu {
                sleepTimerOptions
            } label: {
                Label("Sleep Timer", systemImage: "moon.zzz")
            }

            Menu {
                playbackSpeedOptions
            } label: {
                Label("Playback Speed", systemImage: "speedometer")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More Options")
    }

    @ViewBuilder
    private var sleepTimerOptions: some View {
        let timerActive = player.sleepTimerEndDate != nil
        let endOfTrack = player.sleepAtEndOfTrack

        Button {
            player.setSleepTimer(minutes: nil)
        } label: {
            if !timerActive && !endOfTrack {
                Label("Off", systemImage: "checkmark")
            } else {
                Text("Off")
            }
        }

        ForEach(Self.sleepTimerMinutes, id: \.self) { minutes in
            Button("\(minutes) Minutes") {
                player.setSleepTimer(minutes: minutes)
            }
        }

        Button {
            player.setSleepAtEndOfTrack()
        } label: {
            if endOfTrack {
                Label("End of Track", systemImage: "checkmark")
            } else {
                Text("End of Track")
            }
        }
    }

    @ViewBuilder
    private var playbackSpeedOptions: some View {
        let currentRate = player.playbackRate

        ForEach(Self.playbackRates, id: \.self) { rate in
            Button {
                player.playbackRate = rate
            } label: {
                if PlayerUIText.sameRate(currentRate, rate) {
                    Label(PlayerUIText.speedLabel(rate), systemImage: "checkmark")
                } else {
                    Text(PlayerUIText.speedLabel(rate))
                }
            }
        }
    }

    // MARK: - Title

    private func titleRow(for track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(PlayerUIText.subtitle(for: track))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button {
                library.toggleFavorite(track.id)
            } label: {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(track.isFavorite ? Color.accentColor : Color.primary)
                    .symbolEffect(.bounce, value: track.isFavorite)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NowPlayingPressButtonStyle())
            .accessibilityLabel(track.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
    }

    // MARK: - Transport

    private var transportControls: some View {
        HStack(spacing: 0) {
            modeButton(
                systemImage: "shuffle",
                isOn: player.shuffleEnabled,
                label: "Shuffle",
                value: player.shuffleEnabled ? "On" : "Off"
            ) {
                player.toggleShuffle()
            }

            Spacer(minLength: 0)

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous Track")

            Spacer(minLength: 0)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color.black)
                    .contentTransition(.symbolEffect(.replace))
                    .offset(x: player.isPlaying ? 0 : 2)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(Color.white))
                    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
                    .contentShape(Circle())
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer(minLength: 0)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next Track")

            Spacer(minLength: 0)

            modeButton(
                systemImage: player.repeatMode.systemImage,
                isOn: player.repeatMode != .off,
                label: "Repeat",
                value: repeatDescription
            ) {
                player.cycleRepeatMode()
            }
        }
        .buttonStyle(NowPlayingPressButtonStyle())
        .animation(.easeInOut(duration: 0.2), value: player.isPlaying)
        .animation(.easeInOut(duration: 0.2), value: player.repeatMode)
        .animation(.easeInOut(duration: 0.2), value: player.shuffleEnabled)
    }

    private var repeatDescription: String {
        switch player.repeatMode {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }

    private func modeButton(
        systemImage: String,
        isOn: Bool,
        label: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(0.75))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.white.opacity(isOn ? 0.16 : 0)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    // MARK: - Bottom row

    private func bottomRow(for track: Track) -> some View {
        HStack(spacing: 0) {
            AirPlayButton(tint: .white)
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay and Bluetooth Devices")

            Spacer(minLength: 8)

            if track.isVideo {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        player.showVideo.toggle()
                        if player.showVideo {
                            showsQueue = false
                            showsLyrics = false
                        }
                    }
                } label: {
                    Label(
                        player.showVideo ? "Audio Only" : "Show Video",
                        systemImage: player.showVideo ? "music.note" : "play.rectangle"
                    )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .contentShape(Capsule())
                }
                .buttonStyle(NowPlayingPressButtonStyle())
                .accessibilityHint(player.showVideo ? "Hides the video and keeps the sound playing" : "Shows the video picture")

                Spacer(minLength: 8)
            }

            HStack(spacing: 6) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        showsLyrics.toggle()
                        if showsLyrics {
                            showsQueue = false
                            player.showVideo = false
                        }
                    }
                } label: {
                    Image(systemName: showsLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(showsLyrics ? Color.accentColor : Color.primary.opacity(0.85))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(showsLyrics ? 0.16 : 0)))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NowPlayingPressButtonStyle())
                .accessibilityLabel(showsLyrics ? "Hide Lyrics" : "Show Lyrics")

                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86)) {
                        showsQueue.toggle()
                        if showsQueue { showsLyrics = false }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(showsQueue ? Color.accentColor : Color.primary.opacity(0.85))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.white.opacity(showsQueue ? 0.16 : 0)))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(NowPlayingPressButtonStyle())
                .accessibilityLabel(showsQueue ? "Hide Queue" : "Show Queue")
            }
        }
        .foregroundStyle(Color.primary.opacity(0.85))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 0) {
            HStack {
                closeButton
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            ContentUnavailableView(
                "Nothing Playing",
                systemImage: "music.note",
                description: Text("Choose a song from your library to start listening.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Errors

    /// Player errors are shown as a toast here (RootView's alert is hidden behind this sheet).
    private func presentPlaybackError(_ message: String?) {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return }
        router.showToast(message)
        player.errorMessage = nil
    }
}

// MARK: - Backdrop

/// Heavily blurred current artwork over a dark scrim, or an accent gradient when there is none.
/// With lyrics on screen the scrim is darker, so white lyrics stay readable over bright artwork.
private struct NowPlayingBackdrop: View {
    let trackID: String?
    var dimsForLyrics = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.35), Color.black],
                startPoint: .topLeading,
                endPoint: .bottom
            )

            if let image {
                Color.black
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 60, opaque: true)
                            .scaleEffect(1.35)
                    }
                    .clipped()
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            }

            LinearGradient(
                colors: [Color.black.opacity(0.28), Color.black.opacity(0.5), Color.black.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )

            // Extra shade while lyrics are shown: together with the scrim above about 55% black at
            // the top, 60% in the middle and 72% at the bottom, which keeps white lyrics at 4.5:1
            // or better even over a white cover.
            LinearGradient(
                colors: [Color.black.opacity(0.38), Color.black.opacity(0.2), Color.black.opacity(0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(dimsForLyrics ? 1 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: dimsForLyrics)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: trackID) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let trackID, !trackID.isEmpty else {
            withAnimation(.easeInOut(duration: 0.4)) { image = nil }
            return
        }
        let loaded = await ArtworkCache.shared.image(for: trackID, maxPixel: 240)
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.5)) {
            image = loaded
        }
    }
}

// MARK: - Scrubber

/// Custom scrubber with local drag state, so the periodic time updates never fight the finger.
/// After a seek it keeps showing the target time until the engine catches up (no jump-back).
private struct NowPlayingScrubber: View {
    @Environment(PlayerEngine.self) private var player

    /// Gesture state, so a drag the system cancels (call, Siri, alarm) resets on its own.
    @GestureState private var dragFraction: Double?
    @State private var pendingSeekTime: TimeInterval?

    var body: some View {
        let duration = Self.sanitized(player.duration)
        let canSeek = duration > 0
        let rawTime = Self.sanitized(player.currentTime)
        let liveTime = canSeek ? min(rawTime, duration) : rawTime
        let shownTime = displayedTime(duration: duration, liveTime: liveTime)
        let fraction = canSeek ? min(max(shownTime / duration, 0), 1) : 0
        let isDragging = dragFraction != nil

        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                    Capsule()
                        .fill(Color.white.opacity(isDragging ? 1 : 0.82))
                        .frame(width: width * CGFloat(fraction))
                        .animation(isDragging || pendingSeekTime != nil ? nil : .linear(duration: 0.5), value: fraction)
                }
                .frame(height: isDragging ? 11 : 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragFraction) { value, state, _ in
                            guard canSeek else { return }
                            state = Self.clamp(value.location.x / width)
                        }
                        .onEnded { value in
                            guard canSeek else { return }
                            commitSeek(to: Self.clamp(value.location.x / width) * duration)
                        }
                )
            }
            .frame(height: 26)

            HStack {
                Text(shownTime.mmss)
                Spacer()
                Text(canSeek ? "-" + max(duration - shownTime, 0).mmss : "--:--")
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(isDragging ? Color.primary : Color.secondary)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isDragging)
        .onChange(of: player.currentTime) { _, newTime in
            if let target = pendingSeekTime, abs(newTime - target) < 1.5 {
                pendingSeekTime = nil
            }
        }
        .onChange(of: player.currentTrack?.id) { _, _ in
            pendingSeekTime = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback Position")
        .accessibilityValue(canSeek ? "\(shownTime.mmss) of \(duration.mmss)" : shownTime.mmss)
        .accessibilityAdjustableAction { direction in
            guard canSeek else { return }
            switch direction {
            case .increment:
                player.seek(to: min(liveTime + 15, duration))
            case .decrement:
                player.seek(to: max(liveTime - 15, 0))
            @unknown default:
                break
            }
        }
    }

    private func displayedTime(duration: TimeInterval, liveTime: TimeInterval) -> TimeInterval {
        if let dragFraction, duration > 0 {
            return dragFraction * duration
        }
        if let pendingSeekTime {
            return pendingSeekTime
        }
        return liveTime
    }

    private func commitSeek(to time: TimeInterval) {
        pendingSeekTime = time
        player.seek(to: time)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if pendingSeekTime == time {
                pendingSeekTime = nil
            }
        }
    }

    private static func sanitized(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : 0
    }

    private static func clamp(_ value: CGFloat) -> Double {
        guard value.isFinite else { return 0 }
        return Double(min(max(value, 0), 1))
    }
}

// MARK: - Status line

/// "3 of 24 · 1.5× · Sleep in 12:03" under the "Now Playing" caption.
private struct NowPlayingStatusLine: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        HStack(spacing: 8) {
            if let index = player.currentIndex, player.queue.count > 1 {
                Text("\(index + 1) of \(player.queue.count)")
            }

            if !PlayerUIText.sameRate(player.playbackRate, 1) {
                Text(PlayerUIText.speedLabel(player.playbackRate))
            }

            if let endDate = player.sleepTimerEndDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, endDate.timeIntervalSince(context.date)).rounded(.up)
                    Label("Sleep in \(remaining.mmss)", systemImage: "moon.zzz.fill")
                }
            } else if player.sleepAtEndOfTrack {
                Label("Sleep at End of Track", systemImage: "moon.zzz.fill")
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

// MARK: - Toast

/// Toast capsule for `router.toast` (RootView's toast is hidden behind this sheet).
private struct NowPlayingToastBanner: View {
    let message: String?

    var body: some View {
        ZStack {
            if let message {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
                    .padding(.horizontal, 24)
                    .id(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
                    .onAppear {
                        UIAccessibility.post(notification: .announcement, argument: message)
                    }
            }
        }
        .padding(.top, 64)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: message)
        .allowsHitTesting(false)
    }
}

// MARK: - Button style

private struct NowPlayingPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
