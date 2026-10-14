import SwiftUI

/// Big "Play" / "Shuffle" capsule buttons used at the top of song lists, albums and playlists.
/// Safe to place inside a List row: each button handles its own taps.
struct PlayShuffleHeader: View {
    private let tracks: [Track]

    @Environment(PlayerEngine.self) private var player

    init(tracks: [Track]) {
        self.tracks = tracks
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard !tracks.isEmpty else { return }
                player.play(tracks: tracks, startAt: 0)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityHint("Plays all songs in order")

            Button {
                guard !tracks.isEmpty else { return }
                player.shuffleAll(tracks)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityHint("Plays all songs in random order")
        }
        .font(.headline)
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.accentColor)
        .disabled(tracks.isEmpty)
        .padding(.vertical, 4)
    }
}
