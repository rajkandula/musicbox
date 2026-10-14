import SwiftUI

/// Album page: big artwork, title, artist, "N songs · 42 min", Play/Shuffle and the songs.
struct AlbumDetailView: View {
    let album: AlbumGroup

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        // Prefer the live album so favorites / rescans are reflected; fall back to the snapshot
        // (minus tracks that have since left the library) if the album disappeared.
        let live = library.albums.first(where: { $0.id == album.id })
        let tracks = live?.tracks ?? album.tracks.compactMap { library.track(id: $0.id) }
        let title = live?.title ?? album.title
        let artist = live?.artist ?? album.artist
        let artworkTrackID = live?.artworkTrackID ?? tracks.first(where: \.hasArtwork)?.id ?? tracks.first?.id
        let totalDuration = tracks.reduce(0.0) { $0 + ($1.duration.isFinite ? Swift.max($1.duration, 0) : 0) }
        // The catch-all "Unknown Album" group mixes unrelated files, so it keeps per-song artwork.
        let showsRowArtwork: Bool = title == "Unknown Album" || title.isEmpty

        Group {
            if tracks.isEmpty {
                // Replaces the page (an overlay would sit on top of the header and buttons).
                ContentUnavailableView(
                    "Album Unavailable",
                    systemImage: "square.stack",
                    description: Text("These songs are no longer in your library.")
                )
            } else {
                List {
                    VStack(spacing: 8) {
                        ArtworkView(
                            trackID: artworkTrackID,
                            size: 240,
                            cornerRadius: 12,
                            isVideo: tracks.first(where: { $0.id == artworkTrackID })?.isVideo ?? false
                        )
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                        .padding(.bottom, 8)

                        Text(title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        Text(artist)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .multilineTextAlignment(.center)

                        Text(LibraryFormatting.songsAndDuration(count: tracks.count, duration: totalDuration))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .listRowSeparator(.hidden)
                    .accessibilityElement(children: .combine)

                    PlayShuffleHeader(tracks: tracks)
                        .listRowSeparator(.hidden)

                    ForEach(tracks) { track in
                        TrackRow(track: track, showsArtwork: showsRowArtwork)
                            .trackRowTapToPlay {
                                LibraryPlayback.play(track, in: tracks, player: player, router: router)
                            }
                            .trackQueueSwipeActions(trackID: track.id, player: player, router: router)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    TrackCollectionMenuItems(tracks: tracks)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .disabled(tracks.isEmpty)
            }
        }
    }
}
