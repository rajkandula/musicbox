import SwiftUI

/// Playlist cover: a 2x2 grid of distinct artworks from the first tracks that still exist,
/// a single artwork when there are fewer than four distinct covers, or a gradient with a
/// "music.note.list" symbol for an empty playlist.
struct PlaylistArtworkMosaic: View {
    let trackIDs: [String]
    let size: CGFloat

    @Environment(LibraryStore.self) private var library

    /// Upper bound on how many playlist entries are inspected to find cover tracks,
    /// so huge playlists stay cheap to render.
    private static let scanLimit = 80

    init(trackIDs: [String], size: CGFloat) {
        self.trackIDs = trackIDs
        self.size = size
    }

    var body: some View {
        let side = max(size, 0)
        let tiles = coverTracks()
        let radius = Self.cornerRadius(for: side)

        ZStack {
            if tiles.count >= 4 {
                let half = side / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(tiles[0], side: half)
                        tile(tiles[1], side: half)
                    }
                    HStack(spacing: 0) {
                        tile(tiles[2], side: half)
                        tile(tiles[3], side: half)
                    }
                }
            } else if let first = tiles.first {
                tile(first, side: side)
            } else {
                placeholder(side: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    // MARK: Pieces

    private func tile(_ track: Track, side: CGFloat) -> some View {
        ArtworkView(trackID: track.id, size: side, cornerRadius: 0, isVideo: track.isVideo)
    }

    private func placeholder(side: CGFloat) -> some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "music.note.list")
                .font(.system(size: max(side * 0.36, 8), weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
        }
    }

    private static func cornerRadius(for side: CGFloat) -> CGFloat {
        min(max(side * 0.07, 4), 14)
    }

    // MARK: Cover selection

    /// Returns 4 tracks for a grid, 1 track for a single cover, or none for the placeholder.
    private func coverTracks() -> [Track] {
        var distinct: [Track] = []
        var seenKeys = Set<String>()
        var firstWithArtwork: Track?
        var firstExisting: Track?
        var inspected = 0

        for trackID in trackIDs {
            if inspected >= Self.scanLimit || distinct.count == 4 { break }
            inspected += 1
            guard let track = library.track(id: trackID) else { continue }
            if firstExisting == nil { firstExisting = track }
            if firstWithArtwork == nil, track.hasArtwork { firstWithArtwork = track }
            if seenKeys.insert(Self.coverKey(for: track)).inserted {
                distinct.append(track)
            }
        }

        if distinct.count >= 4 {
            return Array(distinct.prefix(4))
        }
        if let single = firstWithArtwork ?? firstExisting {
            return [single]
        }
        return []
    }

    /// Tracks sharing an album cover collapse to one key so the grid never repeats a cover.
    private static func coverKey(for track: Track) -> String {
        guard track.hasArtwork, !track.isVideo else { return "t:" + track.id }
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !album.isEmpty, album != "unknown album" else { return "t:" + track.id }
        let artist = (track.albumArtist ?? track.artist).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "a:" + album + "|" + artist
    }
}
