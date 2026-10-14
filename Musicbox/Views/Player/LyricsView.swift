import SwiftUI
import AVFoundation
import Network
import UniformTypeIdentifiers

/// Live lyrics for Now Playing, embedded in place of the artwork (like the inline queue).
///
/// Synced lyrics highlight the current line, follow the song automatically (pausing for 3 s after
/// the user scrolls) and seek when a line is tapped. Unsynced lyrics are shown as scrollable text.
/// The view sits on Now Playing's dark blurred-artwork backdrop, so it uses white text and no
/// opaque backgrounds. Reads `LyricsStore`, `PlayerEngine` and `AppRouter` from the environment.
///
/// "Import .lrc File…" uses the importer of the nearest `lyricsImportHost()` above it (Now Playing
/// puts one on its root, which survives rotation; the lyrics panel itself is rebuilt when the
/// layout changes). Without a host, the view hosts its own.
struct LyricsView: View {
    @Environment(\.lyricsImport) private var importAction

    private let track: Track

    init(track: Track) {
        self.track = track
    }

    var body: some View {
        if importAction != nil {
            LyricsPanel(track: track)
        } else {
            LyricsPanel(track: track)
                .lyricsImportHost()
        }
    }
}

// MARK: - Importing a .lrc file

/// Opens the .lrc importer for a song (see `lyricsImportHost()`).
struct LyricsImportAction {
    fileprivate let open: @MainActor (Track) -> Void

    @MainActor
    func callAsFunction(for track: Track) {
        open(track)
    }
}

extension EnvironmentValues {
    @Entry var lyricsImport: LyricsImportAction? = nil
}

extension View {
    /// Hosts the "Import .lrc File…" picker for every `LyricsView` inside this view. Put it on a
    /// view that stays in place while the lyrics panel may be rebuilt (e.g. on rotation), so an
    /// open picker and the song it was opened for survive. Needs `LyricsStore` and `AppRouter`
    /// in the environment.
    func lyricsImportHost() -> some View {
        modifier(LyricsImportHost())
    }
}

private struct LyricsImportHost: ViewModifier {
    @Environment(LyricsStore.self) private var lyrics
    @Environment(AppRouter.self) private var router

    @State private var isImporting = false
    /// The song the importer was opened for (the current song may change while it is open).
    @State private var target: Track?

    private static let importTypes: [UTType] = [
        UTType(filenameExtension: "lrc") ?? .plainText,
        .plainText,
        .text
    ]

    func body(content: Content) -> some View {
        content
            .environment(\.lyricsImport, LyricsImportAction { track in
                target = track
                isImporting = true
            })
            .fileImporter(isPresented: $isImporting, allowedContentTypes: Self.importTypes) { result in
                let song = target
                target = nil
                guard let song else { return }
                finishImport(result, for: song)
            }
    }

    private func finishImport(_ result: Result<URL, Error>, for target: Track) {
        switch result {
        case .success(let url):
            Task {
                let imported = await lyrics.importLyrics(from: url, for: target)
                guard imported else {
                    router.showToast("That file has no lyrics")
                    return
                }
                if !Self.showsImportedLyrics(lyrics.state(for: target.id)) {
                    await lyrics.load(target, force: true)
                }
                router.showToast("Lyrics imported")
            }
        case .failure(let error):
            if !LyricsText.isUserCancellation(error) {
                router.showToast("Couldn’t open that file")
            }
        }
    }

    private static func showsImportedLyrics(_ state: LyricsState) -> Bool {
        if case .loaded(let current) = state {
            return current.source == .imported
        }
        return false
    }
}

// MARK: - Panel

private struct LyricsPanel: View {
    @Environment(LyricsStore.self) private var lyrics
    @Environment(AppRouter.self) private var router
    @Environment(\.lyricsImport) private var importAction
    @Environment(\.colorSchemeContrast) private var contrast

    let track: Track

    /// The song "Wrong Lyrics" was chosen for (the current song may change while it is asked).
    @State private var wrongLyricsTarget: Track?

    var body: some View {
        let state = lyrics.state(for: track.id)
        let display = LyricsDisplay(state: state)

        ZStack {
            content(for: display)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: display.phase)
        .overlay(alignment: .top) {
            LyricsAccessibilityHeader()
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .task(id: track.id) {
            await lyrics.load(track)
        }
        .onChange(of: Self.isIdle(state)) { _, isIdle in
            // Back to "never requested" while on screen ("Clear Saved Lyrics" from another
            // window): ask again instead of showing "Finding lyrics…" with nothing running.
            guard isIdle else { return }
            let target = track
            Task { await lyrics.load(target) }
        }
        .confirmationDialog(
            "Wrong Lyrics?",
            isPresented: Binding(
                get: { wrongLyricsTarget != nil },
                set: { isPresented in
                    if !isPresented { wrongLyricsTarget = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: wrongLyricsTarget
        ) { target in
            Button("Remove These Lyrics", role: .destructive) {
                rejectOnlineLyrics(for: target)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Musicbox won’t show these lyrics for this song again and looks for other lyrics.")
        }
    }

    /// `.lrc` sidecars are read only for songs in Files (not for songs synced from a computer).
    private var supportsSidecar: Bool {
        if case .mediaLibrary = track.location { return false }
        return true
    }

    private var noLyricsTip: String {
        supportsSidecar
            ? "Tip: save a .lrc file with the same name next to the song (Song.mp3 → Song.lrc)"
            : "Tip: use Import .lrc File… to add lyrics for songs from your Music library."
    }

    // MARK: - States

    @ViewBuilder
    private func content(for display: LyricsDisplay) -> some View {
        switch display {
        case .loading:
            LyricsLoadingPanel()

        case .synced(let loaded):
            loadedLayout(loaded, isSynced: true) {
                SyncedLyricsPlayback(lines: loaded.lines, offset: lyrics.offset(for: track.id))
                    .id(track.id)
            }

        case .unsynced(let loaded, let text):
            loadedLayout(loaded, isSynced: false) {
                UnsyncedLyricsText(text: text)
                    .id(track.id)
            }

        case .instrumental(let loaded):
            loadedLayout(loaded, isSynced: false) {
                Text("♪ Instrumental")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Instrumental. This song has no lyrics.")
            }

        case .empty(let loaded):
            loadedLayout(loaded, isSynced: false) {
                LyricsMessagePanel(
                    systemImage: "quote.bubble",
                    title: "No lyrics to show",
                    message: "The lyrics saved for this song are empty."
                ) {
                    EmptyView()
                }
            }

        case .notFound:
            LyricsMessagePanel(
                systemImage: "quote.bubble",
                title: "No lyrics found",
                footnote: noLyricsTip
            ) {
                LyricsCapsuleButton(title: "Search Again", systemImage: "arrow.clockwise") {
                    searchAgain()
                }
                LyricsCapsuleButton(title: "Import .lrc File…", systemImage: "square.and.arrow.down") {
                    beginImport()
                }
            }

        case .offlineDisabled:
            LyricsMessagePanel(
                systemImage: "wifi.slash",
                title: "Online lyrics lookup is off",
                message: "There are no lyrics for this song on your iPhone. Turn on online lookup to search the free LRCLIB library.",
                footnote: noLyricsTip
            ) {
                LyricsCapsuleButton(title: "Turn On", systemImage: "globe", isProminent: true) {
                    turnOnOnlineLookup()
                }
                LyricsCapsuleButton(title: "Import .lrc File…", systemImage: "square.and.arrow.down") {
                    beginImport()
                }
            }

        case .failed(let message):
            LyricsMessagePanel(
                systemImage: "wifi.exclamationmark",
                title: message.isEmpty ? "Couldn’t load lyrics right now." : message
            ) {
                LyricsCapsuleButton(title: "Try Again", systemImage: "arrow.clockwise") {
                    searchAgain()
                }
            }
            .task(id: track.id) {
                await retryWhenBackOnline()
            }
        }
    }

    private func loadedLayout<Content: View>(
        _ loaded: Lyrics,
        isSynced: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer(for: loaded, isSynced: isSynced)
        }
    }

    // MARK: - Footer

    private func footer(for loaded: Lyrics, isSynced: Bool) -> some View {
        let offset = lyrics.offset(for: track.id)
        let isAdjusted = isSynced && LyricsText.isAdjusted(offset)

        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LyricsText.attribution(for: loaded))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(LyricsText.captionOpacity(contrast)))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isAdjusted {
                    Text(LyricsText.timingText(offset))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(LyricsText.captionOpacity(contrast)))
                        .accessibilityLabel(LyricsText.timingAccessibilityText(offset))
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.2), value: isAdjusted)

            optionsMenu(for: loaded, isSynced: isSynced, offset: offset)
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.top, 2)
    }

    private func optionsMenu(for loaded: Lyrics, isSynced: Bool, offset: TimeInterval) -> some View {
        let isAdjusted = LyricsText.isAdjusted(offset)

        return Menu {
            if isSynced {
                Button {
                    lyrics.adjustOffset(for: track.id, by: -0.5)
                } label: {
                    Label("Lyrics Earlier (−0.5 s)", systemImage: "backward")
                }

                Button {
                    lyrics.adjustOffset(for: track.id, by: 0.5)
                } label: {
                    Label("Lyrics Later (+0.5 s)", systemImage: "forward")
                }

                Button {
                    lyrics.resetOffset(for: track.id)
                } label: {
                    Label("Reset Timing", systemImage: "arrow.counterclockwise")
                    if isAdjusted {
                        Text(LyricsText.timingText(offset))
                    }
                }
                .disabled(!isAdjusted)

                Divider()
            }

            Button {
                searchAgain()
            } label: {
                Label("Search Again", systemImage: "arrow.clockwise")
            }

            Button {
                beginImport()
            } label: {
                Label("Import .lrc File…", systemImage: "square.and.arrow.down")
            }

            if loaded.source == .online {
                Button {
                    wrongLyricsTarget = track
                } label: {
                    Label("Wrong Lyrics", systemImage: "hand.thumbsdown")
                }
            }

            if loaded.source == .imported {
                Button(role: .destructive) {
                    removeImportedLyrics()
                } label: {
                    Label("Remove Imported Lyrics", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Lyrics Options")
    }

    // MARK: - Actions

    private func searchAgain() {
        let target = track
        Task {
            await lyrics.load(target, force: true)
        }
    }

    private func turnOnOnlineLookup() {
        lyrics.onlineLookupEnabled = true
        searchAgain()
    }

    private func beginImport() {
        importAction?(for: track)
    }

    private func rejectOnlineLyrics(for target: Track) {
        Task {
            await lyrics.rejectOnlineLyrics(for: target)
            router.showToast("Wrong lyrics removed")
        }
    }

    private func removeImportedLyrics() {
        let target = track
        Task {
            await lyrics.removeImportedLyrics(for: target)
            // Fall back to the other sources right away (the store only removes the override).
            switch lyrics.state(for: target.id) {
            case .idle:
                await lyrics.load(target)
            case .loaded(let current) where current.source == .imported:
                await lyrics.load(target, force: true)
            default:
                break
            }
            router.showToast("Imported lyrics removed")
        }
    }

    /// "No internet connection — lyrics will load when you're online": retries once the network
    /// comes back while this song's lyrics are on screen.
    private func retryWhenBackOnline() async {
        guard await LyricsConnectivity.waitForReconnection() else { return }
        // Give the new connection a moment to settle before asking LRCLIB again.
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        await lyrics.load(track, force: true)
    }

    private static func isIdle(_ state: LyricsState) -> Bool {
        if case .idle = state { return true }
        return false
    }
}

// MARK: - What to show

/// The lyrics state reduced to what the view shows (computed once per body evaluation).
private enum LyricsDisplay {
    case loading
    case synced(Lyrics)
    case unsynced(Lyrics, text: String)
    case instrumental(Lyrics)
    case empty(Lyrics)
    case notFound
    case offlineDisabled
    case failed(String)

    init(state: LyricsState) {
        switch state {
        case .idle, .loading:
            self = .loading
        case .notFound:
            self = .notFound
        case .offlineDisabled:
            self = .offlineDisabled
        case .failed(let message):
            self = .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        case .loaded(let loaded):
            let plain = loaded.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if loaded.isSynced, loaded.lines.contains(where: { !LyricsText.isGap($0.text) }) {
                self = .synced(loaded)
            } else if !plain.isEmpty {
                self = .unsynced(loaded, text: plain)
            } else if loaded.isInstrumental || loaded.isSynced {
                self = .instrumental(loaded)
            } else {
                self = .empty(loaded)
            }
        }
    }

    /// Animation key: changes only when a different kind of content is shown.
    var phase: Int {
        switch self {
        case .loading: return 0
        case .synced: return 1
        case .unsynced: return 2
        case .instrumental: return 3
        case .empty: return 4
        case .notFound: return 5
        case .offlineDisabled: return 6
        case .failed: return 7
        }
    }
}

// MARK: - Synced lyrics: playback clock

/// Owns the playback clock. While playing, a 10 Hz timeline reads the AVPlayer's own clock (the
/// engine's `currentTime` only updates every 0.5 s); while paused it uses the engine's time, which
/// also changes on seeks. The active line is computed once per tick and handed to the (equatable)
/// scroller, so the list itself only re-renders when the active line actually changes.
private struct SyncedLyricsPlayback: View {
    let lines: [LyricLine]
    let offset: TimeInterval

    @Environment(PlayerEngine.self) private var player
    /// Owned here (this view is rebuilt rarely) rather than in the scroller, which is re-created
    /// on every timeline tick.
    @State private var follow = LyricsFollowState()

    var body: some View {
        let isPlaying = player.isPlaying
        let pausedTime = isPlaying ? 0 : LyricsTiming.sanitized(player.currentTime)

        TimelineView(.animation(minimumInterval: 0.1, paused: !isPlaying)) { _ in
            let time = isPlaying ? livePlaybackTime() : pausedTime
            let activeIndex = LyricsStore.activeLineIndex(in: lines, at: time, offset: offset)

            SyncedLyricsScroller(
                lines: lines,
                activeIndex: activeIndex,
                offset: offset,
                isPlaying: isPlaying,
                follow: follow,
                onSeek: seek(to:)
            )
            .equatable()
        }
    }

    private func livePlaybackTime() -> TimeInterval {
        let engineTime = LyricsTiming.sanitized(player.currentTime)
        let avPlayer = player.player
        guard let item = avPlayer.currentItem, item.status == .readyToPlay else { return engineTime }
        let seconds = avPlayer.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return engineTime }
        // The engine publishes a seek target immediately, while the player's clock may still show
        // the old position until the seek lands; normal drift between the two stays under ~1 s.
        if abs(seconds - engineTime) > LyricsTiming.seekDivergence {
            return engineTime
        }
        return seconds
    }

    private func seek(to line: LyricLine) {
        let target = line.time + offset
        player.seek(to: target.isFinite ? max(0, target) : 0)
    }
}

// MARK: - Synced lyrics: list

private struct SyncedLyricsScroller: View, Equatable {
    let lines: [LyricLine]
    let activeIndex: Int?
    let offset: TimeInterval
    let isPlaying: Bool
    /// Auto-scroll bookkeeping, shared across ticks (a plain reference, never observed).
    let follow: LyricsFollowState
    let onSeek: (LyricLine) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The active line sits at 30% of the visible height.
    private static let anchor = UnitPoint(x: 0, y: 0.3)
    private static let resumeDelay: TimeInterval = 3
    /// Longer jumps (seeks) scroll instantly: animating across many lazily built rows stutters.
    private static let maxAnimatedJump = 6

    nonisolated static func == (lhs: SyncedLyricsScroller, rhs: SyncedLyricsScroller) -> Bool {
        lhs.activeIndex == rhs.activeIndex
            && lhs.isPlaying == rhs.isPlaying
            && lhs.offset == rhs.offset
            && lhs.lines == rhs.lines
    }

    var body: some View {
        // Lines sharing the active line's time stamp (an original and its translation, a duet)
        // are all active; the list follows the first of them.
        let activeTime = Self.activeTime(at: activeIndex, in: lines)
        let followID = Self.followID(at: activeIndex, in: lines)

        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Room above the first line so it can sit at 30%.
                    Color.clear
                        .containerRelativeFrame(.vertical) { length, _ in length * 0.3 }
                        .accessibilityHidden(true)

                    ForEach(lines) { line in
                        row(for: line, isActive: Self.isActive(line, activeTime: activeTime), proxy: proxy)
                    }

                    // Room below the last line so it can scroll up to 30%.
                    Color.clear
                        .containerRelativeFrame(.vertical) { length, _ in length * 0.7 }
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .mask(LyricsFadeMask())
            .modifier(UserScrollObserver { event in
                handleUserScroll(event, proxy: proxy)
            })
            .onAppear {
                // `onDisappear` cancels the resume timer; never come back stuck in "paused".
                if follow.isPaused, follow.resumeTask == nil {
                    follow.isPaused = false
                    follow.isInteracting = false
                }
                follow.targetID = followID ?? lines.first?.id
                scrollToTarget(proxy, animated: false)
                // Lazy rows may not be laid out yet on the very first pass.
                DispatchQueue.main.async {
                    scrollToTarget(proxy, animated: false)
                }
            }
            .onChange(of: activeIndex) { oldIndex, newIndex in
                follow.targetID = Self.followID(at: newIndex, in: lines) ?? lines.first?.id
                guard !follow.isPaused else { return }
                let distance = abs((newIndex ?? -1) - (oldIndex ?? -1))
                scrollToTarget(proxy, animated: distance <= Self.maxAnimatedJump)
            }
            .onChange(of: lines) { _, newLines in
                follow.targetID = Self.followID(at: activeIndex, in: newLines) ?? newLines.first?.id
                guard !follow.isPaused else { return }
                scrollToTarget(proxy, animated: false)
            }
            .onDisappear {
                follow.cancelResume()
            }
        }
    }

    private func row(for line: LyricLine, isActive: Bool, proxy: ScrollViewProxy) -> some View {
        let isGap = LyricsText.isGap(line.text)

        return Button {
            select(line, proxy: proxy)
        } label: {
            LyricLineRow(
                text: line.text,
                isGap: isGap,
                isActive: isActive,
                animatesGap: isGap && isActive && isPlaying,
                reduceMotion: reduceMotion
            )
        }
        .buttonStyle(LyricLinePressStyle())
        .id(line.id)
        .accessibilityLabel(isGap ? "Instrumental break" : line.text)
        // Tapping only seeks: it doesn't start playback when the song is paused.
        .accessibilityHint(isPlaying ? "Plays from this line" : "Moves playback to this line")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // MARK: Following the song

    /// Tap: seek there and follow the song again immediately.
    private func select(_ line: LyricLine, proxy: ScrollViewProxy) {
        follow.cancelResume()
        follow.isPaused = false
        follow.isInteracting = false
        follow.targetID = line.id
        Self.scroll(proxy, to: line.id, animated: true)
        onSeek(line)
    }

    private func handleUserScroll(_ event: UserScrollEvent, proxy: ScrollViewProxy) {
        switch event {
        case .began:
            follow.isInteracting = true
            pauseFollowing(proxy)
        case .ended:
            guard follow.isInteracting else { return }
            follow.isInteracting = false
            follow.lastInteraction = Date()
        case .nudged:
            pauseFollowing(proxy)
        }
    }

    /// Stops following the song until the user has left the list alone for 3 s.
    private func pauseFollowing(_ proxy: ScrollViewProxy) {
        let follow = follow
        follow.lastInteraction = Date()
        guard !follow.isPaused else { return }
        follow.isPaused = true
        follow.cancelResume()
        follow.resumeTask = Task { @MainActor in
            while !Task.isCancelled {
                let remaining = Self.resumeDelay - Date().timeIntervalSince(follow.lastInteraction)
                if remaining <= 0, !follow.isInteracting { break }
                try? await Task.sleep(for: .seconds(max(remaining, 0.25)))
            }
            guard !Task.isCancelled, follow.isPaused else { return }
            follow.isPaused = false
            follow.resumeTask = nil
            if let target = follow.targetID {
                Self.scroll(proxy, to: target, animated: true)
            }
        }
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let target = follow.targetID else { return }
        Self.scroll(proxy, to: target, animated: animated)
    }

    private static func scroll(_ proxy: ScrollViewProxy, to id: Int, animated: Bool) {
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(id, anchor: anchor)
            }
        }
    }

    /// Same stamp as the parser's duplicate check (1 ms).
    private static let sameTimeTolerance: TimeInterval = 0.001

    private static func activeTime(at index: Int?, in lines: [LyricLine]) -> TimeInterval? {
        guard let index, lines.indices.contains(index) else { return nil }
        return lines[index].time
    }

    private static func isActive(_ line: LyricLine, activeTime: TimeInterval?) -> Bool {
        guard let activeTime else { return false }
        return abs(line.time - activeTime) < sameTimeTolerance
    }

    /// The first line of the active line's time group (`activeLineIndex` returns the last one).
    private static func followID(at index: Int?, in lines: [LyricLine]) -> Int? {
        guard let index, lines.indices.contains(index) else { return nil }
        let time = lines[index].time
        var first = index
        while first > 0, abs(lines[first - 1].time - time) < sameTimeTolerance {
            first -= 1
        }
        return lines[first].id
    }
}

/// Auto-scroll bookkeeping. A plain reference (not observed): changing it never re-renders the list.
@MainActor
private final class LyricsFollowState {
    /// Line the list should show when following the song.
    var targetID: Int?
    /// True while auto-scroll is paused because the user scrolled.
    var isPaused = false
    /// True while a finger is on the list or it is still coasting (iOS 18+ scroll phases).
    var isInteracting = false
    var lastInteraction = Date.distantPast
    var resumeTask: Task<Void, Never>?

    func cancelResume() {
        resumeTask?.cancel()
        resumeTask = nil
    }
}

private enum UserScrollEvent {
    /// The user started scrolling (held until `.ended`).
    case began
    /// The user's scroll came to rest.
    case ended
    /// Momentary drag activity (iOS 17 drag gesture, which may never report its end).
    case nudged
}

/// Reports user-driven scrolling (programmatic scrolls are ignored). iOS 18+ uses scroll phases,
/// which also cover momentum; iOS 17 uses a simultaneous drag gesture on the list.
private struct UserScrollObserver: ViewModifier {
    let onEvent: (UserScrollEvent) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { oldPhase, newPhase in
                // Any move out of a user-driven phase ends it: to .idle, but also to .animating
                // (bounce-back / an interrupting programmatic scroll) or .tracking (a finger that
                // stopped the coasting). Missing one would keep auto-scroll paused for good.
                if Self.isUserDriven(newPhase) {
                    onEvent(.began)
                } else if Self.isUserDriven(oldPhase) {
                    onEvent(.ended)
                }
            }
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { _ in onEvent(.nudged) }
                    .onEnded { _ in onEvent(.nudged) }
            )
        }
    }

    @available(iOS 18.0, *)
    private static func isUserDriven(_ phase: ScrollPhase) -> Bool {
        switch phase {
        case .interacting, .decelerating:
            return true
        default:
            return false
        }
    }
}

// MARK: - Synced lyrics: rows

private struct LyricLineRow: View {
    let text: String
    let isGap: Bool
    let isActive: Bool
    let animatesGap: Bool
    let reduceMotion: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if isGap {
                LyricsGapIndicator(isAnimating: animatesGap, reduceMotion: reduceMotion)
            } else {
                Text(text)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isActive ? 1 : (contrast == .increased ? 0.5 : 0.32))
        .scaleEffect(isActive || reduceMotion ? 1 : 0.96, anchor: .leading)
        .animation(
            reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.8),
            value: isActive
        )
        .contentShape(Rectangle())
    }
}

/// "♪ ♪ ♪" for an instrumental gap; the notes pulse one after another while it is the active line.
private struct LyricsGapIndicator: View {
    let isAnimating: Bool
    let reduceMotion: Bool

    /// Index of the lit note; 3 = a short rest with none lit.
    private static let phases = [0, 1, 2, 3]

    var body: some View {
        if isAnimating {
            PhaseAnimator(Self.phases) { phase in
                notes(lit: phase)
            } animation: { _ in
                .easeInOut(duration: reduceMotion ? 0.5 : 0.35)
            }
        } else {
            notes(lit: nil)
        }
    }

    private func notes(lit: Int?) -> some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                let isLit = lit == index
                Text("♪")
                    .opacity(lit == nil || isLit ? 1 : 0.45)
                    .scaleEffect(isLit && !reduceMotion ? 1.25 : 1, anchor: .bottom)
            }
        }
        .font(.title2.weight(.bold))
    }
}

private struct LyricLinePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Unsynced lyrics

private struct UnsyncedLyricsText: View {
    let text: String

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Label("These lyrics aren’t time-synced", systemImage: "text.alignleft")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(LyricsText.captionOpacity(contrast)))

                Text(text)
                    .font(.title3.weight(.semibold))
                    .lineSpacing(6)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .mask(LyricsFadeMask())
    }
}

// MARK: - Shared pieces

/// Soft top & bottom edges so lines fade in and out instead of being cut off.
private struct LyricsFadeMask: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.1),
                .init(color: .black, location: 0.86),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// "Lyrics" heading for VoiceOver only (nothing is drawn).
private struct LyricsAccessibilityHeader: View {
    var body: some View {
        Text("Lyrics")
            .font(.caption2)
            .foregroundStyle(.clear)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isHeader)
            .accessibilitySortPriority(1)
    }
}

/// "Finding lyrics…", faded in after a moment so quick cache hits don't flash a spinner.
private struct LyricsLoadingPanel: View {
    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Finding lyrics…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isVisible ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Finding lyrics")
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                isVisible = true
            }
        }
    }
}

/// Centered icon, title, optional message, buttons and footnote. Scrolls when it doesn't fit
/// (landscape, large Dynamic Type).
private struct LyricsMessagePanel<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    var footnote: String?
    @ViewBuilder let actions: Actions

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ViewThatFits(in: .vertical) {
            panel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView(.vertical) {
                panel
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var panel: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(spacing: 10) { actions }
            }
            .padding(.top, 4)

            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(LyricsText.captionOpacity(contrast)))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
    }
}

/// Capsule button matching Now Playing's "Show Video" pill; `isProminent` = white fill.
private struct LyricsCapsuleButton: View {
    let title: String
    let systemImage: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isProminent ? Color.black : Color.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.white.opacity(isProminent ? 1 : 0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(LyricsPressButtonStyle())
    }
}

private struct LyricsPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(
                reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

// MARK: - Helpers

private enum LyricsTiming {
    /// Above this gap between the player's clock and the engine's time, a seek is still landing.
    static let seekDivergence: TimeInterval = 2

    static func sanitized(_ value: TimeInterval) -> TimeInterval {
        value.isFinite && value > 0 ? value : 0
    }
}

private enum LyricsText {
    private static let gapCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "♪♫♬♩🎵🎶"))

    /// Blank lines (and lines made only of music notes) are instrumental gaps.
    static func isGap(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { gapCharacters.contains($0) }
    }

    /// Captions over the artwork backdrop; brighter when the user asked for more contrast.
    static func captionOpacity(_ contrast: ColorSchemeContrast) -> Double {
        contrast == .increased ? 0.8 : 0.6
    }

    static func isAdjusted(_ offset: TimeInterval) -> Bool {
        offset.isFinite && abs(offset) >= 0.05
    }

    /// "Timing +1.0 s", "Timing −0.5 s".
    static func timingText(_ offset: TimeInterval) -> String {
        let rounded = roundedOffset(offset)
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "−" : "")
        return "Timing \(sign)\(formatted(abs(rounded))) s"
    }

    /// "Lyrics shifted 1.0 seconds later".
    static func timingAccessibilityText(_ offset: TimeInterval) -> String {
        let rounded = roundedOffset(offset)
        let direction = rounded > 0 ? "later" : "earlier"
        return "Lyrics shifted \(formatted(abs(rounded))) seconds \(direction)"
    }

    static func attribution(for lyrics: Lyrics) -> String {
        let text = lyrics.attribution.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        switch lyrics.source {
        case .imported: return "Imported"
        case .sidecarFile: return "From a .lrc file"
        case .embedded: return "Embedded in file"
        case .online: return "Lyrics from LRCLIB"
        }
    }

    static func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private static func roundedOffset(_ offset: TimeInterval) -> TimeInterval {
        guard offset.isFinite else { return 0 }
        return (offset * 10).rounded() / 10
    }

    private static func formatted(_ value: TimeInterval) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

/// Waits for the network to come back after being unavailable.
private enum LyricsConnectivity {
    /// Returns true once the device goes from offline back to online; false if the task is
    /// cancelled first. A connection that is already up does not count (no retry loops when the
    /// failure had another cause).
    static func waitForReconnection() async -> Bool {
        let updates = AsyncStream<Bool> { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue(label: "Musicbox.LyricsView.connectivity", qos: .utility))
        }

        var sawOffline = false
        for await isOnline in updates {
            if !isOnline {
                sawOffline = true
            } else if sawOffline {
                return !Task.isCancelled
            }
        }
        return false
    }
}
