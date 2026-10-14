import SwiftUI

/// Albums segment: an adaptive two-column grid of album artwork.
struct AlbumsView: View {
    @Binding var segment: LibraryView.Segment

    @Environment(LibraryStore.self) private var library

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]

    var body: some View {
        let albums = library.albums

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LibraryHeader(segment: $segment)

                if albums.isEmpty {
                    ContentUnavailableView(
                        "No Albums",
                        systemImage: "square.stack",
                        description: Text("Albums appear here once your songs have album information.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                AlbumGridCell(album: album)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text(LibraryFormatting.albumCount(albums.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }
}

/// Album artwork with title and artist underneath. With `fixedSize` nil the artwork fills the
/// available width (grid); otherwise it is exactly `fixedSize` points wide (horizontal strips).
struct AlbumGridCell: View {
    let album: AlbumGroup
    var fixedSize: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork

            VStack(alignment: .leading, spacing: 1) {
                Text(album.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(album.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: fixedSize, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            TrackCollectionMenuItems(tracks: album.tracks)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.title), \(album.artist), \(LibraryFormatting.songCount(album.tracks.count))")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var artwork: some View {
        if let fixedSize {
            ArtworkView(trackID: album.artworkTrackID, size: fixedSize, cornerRadius: 8, isVideo: artworkIsVideo)
        } else {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        ArtworkView(
                            trackID: album.artworkTrackID,
                            size: proxy.size.width,
                            cornerRadius: 8,
                            isVideo: artworkIsVideo
                        )
                    }
                }
        }
    }

    private var artworkIsVideo: Bool {
        guard let artworkID = album.artworkTrackID else { return false }
        return album.tracks.first(where: { $0.id == artworkID })?.isVideo ?? false
    }
}
