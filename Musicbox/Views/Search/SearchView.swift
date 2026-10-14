import SwiftUI

/// Search tab: songs, albums, artists and playlists matching the query (case- and
/// diacritic-insensitive; every word must match).
struct SearchView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    @State private var query = ""
    @State private var results = SearchResultIDs()
    @State private var resultsQuery = ""
    @State private var showsAllSongs = false

    private static let songPreviewLimit = 50

    var body: some View {
        let trimmed = SearchView.normalized(query)

        content(for: trimmed)
            .navigationTitle("Search")
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Songs, albums, artists, playlists"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: SearchTaskKey(
                query: trimmed,
                trackCount: library.tracks.count,
                albumCount: library.albums.count,
                artistCount: library.artists.count,
                lastScan: library.lastScanDate
            )) {
                await updateResults(for: trimmed)
            }
            .onChange(of: trimmed) { _, _ in
                showsAllSongs = false
            }
            .navigationDestination(for: AlbumGroup.self) { album in
                AlbumDetailView(album: album)
            }
            .navigationDestination(for: ArtistGroup.self) { artist in
                ArtistDetailView(artist: artist)
            }
    }

    // MARK: Content

    @ViewBuilder
    private func content(for trimmed: String) -> some View {
        if trimmed.isEmpty {
            if library.tracks.isEmpty {
                ContentUnavailableView(
                    "Nothing to Search Yet",
                    systemImage: "music.note",
                    description: Text("Add music in the Library tab — link a folder or import files.")
                )
            } else {
                ContentUnavailableView(
                    "Search Your Library",
                    systemImage: "magnifyingglass",
                    description: Text("Find songs, albums, artists and playlists on this iPhone.")
                )
            }
        } else {
            let playlists = matchingPlaylists(trimmed)
            let isCurrent = resultsQuery == trimmed

            if isCurrent && results.isEmpty && playlists.isEmpty {
                ContentUnavailableView.search(text: trimmed)
            } else if !isCurrent && results.isEmpty && playlists.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                resultsList(playlists: playlists)
            }
        }
    }

    private func resultsList(playlists: [Playlist]) -> some View {
        let songIDs = results.songIDs
        let visibleSongIDs = showsAllSongs ? songIDs : Array(songIDs.prefix(Self.songPreviewLimit))
        let visibleSongs = library.tracks(ids: visibleSongIDs)
        let albums = lookUpAlbums(results.albumIDs)
        let artists = lookUpArtists(results.artistIDs)

        return List {
            if !visibleSongs.isEmpty {
                Section {
                    ForEach(visibleSongs) { track in
                        TrackRow(track: track)
                            .trackRowTapToPlay {
                                // Play every matching song, starting with the tapped one.
                                let all = library.tracks(ids: songIDs)
                                LibraryPlayback.play(track, in: all, player: player, router: router)
                            }
                            .trackQueueSwipeActions(trackID: track.id, player: player, router: router)
                    }

                    if !showsAllSongs && songIDs.count > Self.songPreviewLimit {
                        Button {
                            showsAllSongs = true
                        } label: {
                            HStack {
                                Text("Show All \(songIDs.count) Songs")
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.footnote.weight(.semibold))
                            }
                            .foregroundStyle(.tint)
                        }
                    }
                } header: {
                    Text("Songs")
                }
            }

            if !albums.isEmpty {
                Section {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            LibraryAlbumRow(album: album)
                        }
                        .contextMenu {
                            TrackCollectionMenuItems(tracks: album.tracks)
                        }
                    }
                } header: {
                    Text("Albums")
                }
            }

            if !artists.isEmpty {
                Section {
                    ForEach(artists) { artist in
                        NavigationLink(value: artist) {
                            LibraryArtistRow(artist: artist)
                        }
                        .contextMenu {
                            TrackCollectionMenuItems(tracks: artist.tracks)
                        }
                    }
                } header: {
                    Text("Artists")
                }
            }

            if !playlists.isEmpty {
                Section {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlistID: playlist.id)
                        } label: {
                            SearchPlaylistRow(playlist: playlist)
                        }
                    }
                } header: {
                    Text("Playlists")
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: Lookups (map result IDs to live library objects)

    private func lookUpAlbums(_ ids: [String]) -> [AlbumGroup] {
        guard !ids.isEmpty else { return [] }
        var byID: [String: AlbumGroup] = [:]
        byID.reserveCapacity(library.albums.count)
        for album in library.albums where byID[album.id] == nil {
            byID[album.id] = album
        }
        return ids.compactMap { byID[$0] }
    }

    private func lookUpArtists(_ ids: [String]) -> [ArtistGroup] {
        guard !ids.isEmpty else { return [] }
        var byID: [String: ArtistGroup] = [:]
        byID.reserveCapacity(library.artists.count)
        for artist in library.artists where byID[artist.id] == nil {
            byID[artist.id] = artist
        }
        return ids.compactMap { byID[$0] }
    }

    /// Playlists are few, so they are matched synchronously (always reflects renames).
    private func matchingPlaylists(_ trimmed: String) -> [Playlist] {
        let terms = LibrarySearchEngine.terms(from: trimmed)
        guard !terms.isEmpty else { return [] }
        return library.playlists.filter { LibrarySearchEngine.matches(terms, fields: [$0.name]) }
    }

    // MARK: Searching

    private func updateResults(for trimmed: String) async {
        guard !trimmed.isEmpty else {
            results = SearchResultIDs()
            resultsQuery = ""
            return
        }
        // Debounce typing.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }

        let tracks = library.tracks
        let albums = library.albums
        let artists = library.artists
        let computed = await Task.detached(priority: .userInitiated) {
            LibrarySearchEngine.search(trimmed, tracks: tracks, albums: albums, artists: artists)
        }.value

        guard !Task.isCancelled else { return }
        results = computed
        resultsQuery = trimmed
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Helpers

private struct SearchTaskKey: Equatable {
    let query: String
    let trackCount: Int
    let albumCount: Int
    let artistCount: Int
    let lastScan: Date?
}

/// IDs only, so rows always render the live library objects.
struct SearchResultIDs: Equatable, Sendable {
    var songIDs: [String] = []
    var albumIDs: [String] = []
    var artistIDs: [String] = []

    var isEmpty: Bool { songIDs.isEmpty && albumIDs.isEmpty && artistIDs.isEmpty }
}

/// Pure, thread-safe matching used off the main actor.
enum LibrarySearchEngine {
    static func terms(from query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Every term must appear (case/diacritic-insensitive) in at least one of the fields.
    static func matches(_ terms: [String], fields: [String]) -> Bool {
        for term in terms {
            var found = false
            for field in fields where field.localizedStandardContains(term) {
                found = true
                break
            }
            if !found { return false }
        }
        return true
    }

    static func search(_ query: String, tracks: [Track], albums: [AlbumGroup], artists: [ArtistGroup]) -> SearchResultIDs {
        let terms = terms(from: query)
        guard !terms.isEmpty else { return SearchResultIDs() }

        // Songs: title prefix matches first, then everything else (library order kept within each).
        var prefixMatches: [String] = []
        var otherMatches: [String] = []
        for track in tracks {
            var fields = [track.title, track.artist, track.album]
            if let albumArtist = track.albumArtist, !albumArtist.isEmpty { fields.append(albumArtist) }
            guard matches(terms, fields: fields) else { continue }
            if titleStarts(track.title, with: query) {
                prefixMatches.append(track.id)
            } else {
                otherMatches.append(track.id)
            }
        }

        let albumIDs = albums
            .filter { matches(terms, fields: [$0.title, $0.artist]) }
            .map(\.id)

        let artistIDs = artists
            .filter { matches(terms, fields: [$0.name]) }
            .map(\.id)

        return SearchResultIDs(
            songIDs: prefixMatches + otherMatches,
            albumIDs: albumIDs,
            artistIDs: artistIDs
        )
    }

    private static func titleStarts(_ title: String, with query: String) -> Bool {
        title.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .anchored]
        ) != nil
    }
}

private struct SearchPlaylistRow: View {
    let playlist: Playlist

    @Environment(LibraryStore.self) private var library

    var body: some View {
        let tracks = library.tracks(in: playlist)
        let artworkTrack = tracks.first(where: \.hasArtwork) ?? tracks.first

        HStack(spacing: 12) {
            ArtworkView(
                trackID: artworkTrack?.id ?? playlist.id.uuidString,
                size: 48,
                cornerRadius: 6,
                isVideo: artworkTrack?.isVideo ?? false
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                    .lineLimit(1)
                Text(LibraryFormatting.songCount(tracks.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
