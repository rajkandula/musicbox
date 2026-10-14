import SwiftUI

/// Artist page: round artwork, Play/Shuffle, a horizontal strip of albums and all songs.
struct ArtistDetailView: View {
    let artist: ArtistGroup

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        // Prefer the live artist so favorites / rescans are reflected.
        let live = library.artists.first(where: { $0.id == artist.id })
        let tracks = live?.tracks ?? artist.tracks.compactMap { library.track(id: $0.id) }
        let name = live?.name ?? artist.name
        let artworkTrackID = live?.artworkTrackID ?? tracks.first(where: \.hasArtwork)?.id ?? tracks.first?.id
        let albums = Self.albums(containing: tracks, in: library.albums)

        Group {
            if tracks.isEmpty {
                // Replaces the page (an overlay would sit on top of the header and buttons).
                ContentUnavailableView(
                    "Artist Unavailable",
                    systemImage: "music.mic",
                    description: Text("These songs are no longer in your library.")
                )
            } else {
                List {
                    VStack(spacing: 8) {
                        ArtworkView(trackID: artworkTrackID, size: 160, cornerRadius: 80)
                            .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
                            .padding(.bottom, 8)

                        Text(name)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        Text("\(LibraryFormatting.albumCount(albums.count)) · \(LibraryFormatting.songCount(tracks.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .listRowSeparator(.hidden)
                    .accessibilityElement(children: .combine)

                    PlayShuffleHeader(tracks: tracks)
                        .listRowSeparator(.hidden)

                    if !albums.isEmpty {
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(albums) { album in
                                        NavigationLink(value: album) {
                                            AlbumGridCell(album: album, fixedSize: 140)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        } header: {
                            Text("Albums")
                        }
                    }

                    Section {
                        ForEach(tracks) { track in
                            TrackRow(track: track)
                                .trackRowTapToPlay {
                                    LibraryPlayback.play(track, in: tracks, player: player, router: router)
                                }
                                .trackQueueSwipeActions(trackID: track.id, player: player, router: router)
                        }
                    } header: {
                        Text("Songs")
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(name)
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

    /// Albums that contain at least one of the artist's tracks (covers albums whose album artist
    /// differs, e.g. compilations).
    private static func albums(containing tracks: [Track], in allAlbums: [AlbumGroup]) -> [AlbumGroup] {
        guard !tracks.isEmpty else { return [] }
        let ids = Set(tracks.map(\.id))
        return allAlbums.filter { album in
            album.tracks.contains { ids.contains($0.id) }
        }
    }
}
