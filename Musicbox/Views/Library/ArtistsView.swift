import SwiftUI

/// Artists segment: a plain list of artists.
struct ArtistsView: View {
    @Binding var segment: LibraryView.Segment

    @Environment(LibraryStore.self) private var library

    var body: some View {
        let artists = library.artists

        List {
            LibraryHeader(segment: $segment)
                .libraryHeaderListRow()

            if artists.isEmpty {
                ContentUnavailableView(
                    "No Artists",
                    systemImage: "music.mic",
                    description: Text("Artists appear here once your songs have artist information.")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(artists) { artist in
                        NavigationLink(value: artist) {
                            LibraryArtistRow(artist: artist)
                        }
                        .contextMenu {
                            TrackCollectionMenuItems(tracks: artist.tracks)
                        }
                    }
                } footer: {
                    Text(artists.count == 1 ? "1 artist" : "\(artists.count) artists")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        .listStyle(.plain)
    }
}

/// Artist row: round artwork, name, "N albums · M songs".
struct LibraryArtistRow: View {
    let artist: ArtistGroup

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(trackID: artist.artworkTrackID, size: 48, cornerRadius: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.body)
                    .lineLimit(1)
                Text("\(LibraryFormatting.albumCount(artist.albumCount)) · \(LibraryFormatting.songCount(artist.tracks.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Album row used in lists (search results): artwork, title, artist.
struct LibraryAlbumRow: View {
    let album: AlbumGroup

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(trackID: album.artworkTrackID, size: 48, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body)
                    .lineLimit(1)
                Text("\(album.artist) · \(LibraryFormatting.songCount(album.tracks.count))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
