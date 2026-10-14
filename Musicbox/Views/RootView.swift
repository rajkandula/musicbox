import SwiftUI
import UIKit

struct RootView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(LyricsStore.self) private var lyrics
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selectedTab) {
            NavigationStack { LibraryView() }
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerInset }
                .tabItem { Label("Library", systemImage: "square.stack") }
                .tag(AppTab.library)

            NavigationStack { PlaylistsView() }
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerInset }
                .tabItem { Label("Playlists", systemImage: "music.note.list") }
                .tag(AppTab.playlists)

            NavigationStack { SearchView() }
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerInset }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)

            NavigationStack { SettingsView() }
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerInset }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .sheet(isPresented: $router.isNowPlayingPresented) {
            NowPlayingView()
                .environment(library)
                .environment(player)
                .environment(lyrics)
                .environment(router)
        }
        // Warm up lyrics for the song that's playing and the next one, so they're ready the
        // moment Now Playing opens (cached after the first lookup; no-op when already known).
        .onChange(of: player.currentTrack?.id, initial: true) { _, _ in
            if let current = player.currentTrack { lyrics.prefetch(current) }
            if let next = player.upNext.first { lyrics.prefetch(next) }
        }
        .sheet(item: $router.addToPlaylistRequest) { request in
            AddToPlaylistSheet(trackIDs: request.trackIDs)
                .environment(library)
                .environment(player)
                .environment(router)
        }
        .overlay(alignment: .top) {
            RootToastOverlay()
        }
        .alert(
            alertInfo?.title ?? "",
            isPresented: alertBinding,
            presenting: alertInfo
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { info in
            Text(info.message)
        }
    }

    // MARK: Mini player

    @ViewBuilder
    private var miniPlayerInset: some View {
        if player.hasActiveSession {
            MiniPlayerView()
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Error alerts

    private enum AlertSource { case library, player }

    private struct AlertInfo {
        let source: AlertSource
        let title: String
        let message: String
    }

    /// Library errors take priority; player errors are shown here only while Now Playing is not
    /// on screen (NowPlayingView displays them itself). Nothing is shown while one of our sheets is
    /// up, so the alert appears as soon as the sheet goes away instead of being lost.
    private var alertInfo: AlertInfo? {
        guard !router.isNowPlayingPresented, router.addToPlaylistRequest == nil else { return nil }
        if let message = library.lastErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return AlertInfo(source: .library, title: "Library", message: message)
        }
        if let message = player.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return AlertInfo(source: .player, title: "Can’t Play", message: message)
        }
        return nil
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertInfo != nil },
            set: { isPresented in
                guard !isPresented else { return }
                switch alertInfo?.source {
                case .library?:
                    library.lastErrorMessage = nil
                case .player?:
                    player.errorMessage = nil
                case nil:
                    break
                }
            }
        )
    }
}

// MARK: - Toast

/// Reads `router.toast` in its own body so toast changes don't re-render the whole tab hierarchy.
private struct RootToastOverlay: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        ZStack {
            if let text = router.toast, !router.isNowPlayingPresented {
                RootToastCapsule(text: text)
                    .id(text)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: router.toast)
    }
}

private struct RootToastCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 24)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isStaticText)
            .onAppear {
                UIAccessibility.post(notification: .announcement, argument: text)
            }
    }
}
