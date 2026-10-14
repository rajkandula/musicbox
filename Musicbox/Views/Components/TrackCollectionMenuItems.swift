import SwiftUI

/// Menu contents for a group of tracks (an album, an artist, …):
/// Play, Shuffle, Play Next, Add to Queue, Add to Playlist….
struct TrackCollectionMenuItems: View {
    private let tracks: [Track]

    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    init(tracks: [Track]) {
        self.tracks = tracks
    }

    var body: some View {
        Section {
            Button {
                player.play(tracks: tracks, startAt: 0)
            } label: {
                Label("Play", systemImage: "play")
            }

            Button {
                player.shuffleAll(tracks)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
        }
        .disabled(tracks.isEmpty)

        Section {
            Button {
                player.playNext(tracks.map(\.id))
                router.showToast("Playing Next")
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                player.addToQueue(tracks.map(\.id))
                router.showToast("Added to Queue")
            } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }

            Button {
                router.addToPlaylist(tracks.map(\.id))
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }
        }
        .disabled(tracks.isEmpty)
    }
}

/// Shared "tap a song in a list" behaviour for the library and search screens.
@MainActor
enum LibraryPlayback {
    /// Plays `list` starting at `track`. Tapping the track that is already current resumes it
    /// (if paused) and opens Now Playing instead of restarting it.
    static func play(_ track: Track, in list: [Track], player: PlayerEngine, router: AppRouter) {
        if player.currentTrack?.id == track.id {
            if !player.isPlaying { player.resume() }
            router.isNowPlayingPresented = true
            return
        }
        guard let index = list.firstIndex(where: { $0.id == track.id }) else {
            player.play(tracks: [track], startAt: 0)
            return
        }
        player.play(tracks: list, startAt: index)
    }
}
