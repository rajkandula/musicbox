import SwiftUI

/// Automatically maintained playlists shown at the top of the Playlists tab.
enum SmartPlaylistKind: String, CaseIterable, Identifiable {
    case favorites, recentlyAdded, mostPlayed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .recentlyAdded: return "Recently Added"
        case .mostPlayed: return "Most Played"
        }
    }

    var systemImage: String {
        switch self {
        case .favorites: return "heart.fill"
        case .recentlyAdded: return "clock.fill"
        case .mostPlayed: return "flame.fill"
        }
    }

    /// Two-stop gradient used for the row icon tile.
    var gradientColors: [Color] {
        switch self {
        case .favorites: return [Color(red: 1.0, green: 0.36, blue: 0.47), Color(red: 0.86, green: 0.12, blue: 0.33)]
        case .recentlyAdded: return [Color(red: 0.35, green: 0.66, blue: 1.0), Color(red: 0.18, green: 0.38, blue: 0.93)]
        case .mostPlayed: return [Color(red: 1.0, green: 0.68, blue: 0.24), Color(red: 0.96, green: 0.36, blue: 0.13)]
        }
    }

    var emptyTitle: String {
        switch self {
        case .favorites: return "No Favorites Yet"
        case .recentlyAdded: return "Nothing Added Yet"
        case .mostPlayed: return "Nothing Played Yet"
        }
    }

    var emptyMessage: String {
        switch self {
        case .favorites:
            return "No favorites yet — tap ♥ in Now Playing, or use a song’s menu, to add one."
        case .recentlyAdded:
            return "Songs you add to Musicbox will show up here, newest first."
        case .mostPlayed:
            return "Play some music — the songs you listen to most will appear here."
        }
    }
}

/// Track list for a smart playlist (Favorites / Recently Added / Most Played).
struct SmartPlaylistView: View {
    let kind: SmartPlaylistKind

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    init(kind: SmartPlaylistKind) {
        self.kind = kind
    }

    var body: some View {
        let tracks = currentTracks

        Group {
            if tracks.isEmpty {
                ContentUnavailableView {
                    Label(kind.emptyTitle, systemImage: kind.systemImage)
                } description: {
                    Text(kind.emptyMessage)
                }
            } else {
                List {
                    Section {
                        Text(summaryText(for: tracks))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowSeparator(.hidden)

                        PlayShuffleHeader(tracks: tracks)
                            .listRowSeparator(.hidden)
                    }

                    Section {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(track: track)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    player.play(tracks: tracks, startAt: index)
                                }
                                .accessibilityAddTraits(.isButton)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if kind == .favorites {
                                        Button {
                                            library.toggleFavorite(track.id)
                                            router.showToast("Removed from Favorites")
                                        } label: {
                                            Label("Unfavorite", systemImage: "heart.slash")
                                        }
                                        .tint(.gray)
                                    }
                                }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(kind.title)
    }

    private var currentTracks: [Track] {
        switch kind {
        case .favorites: return library.favoriteTracks
        case .recentlyAdded: return library.recentlyAddedTracks
        case .mostPlayed: return library.mostPlayedTracks
        }
    }

    private func summaryText(for tracks: [Track]) -> String {
        let duration = tracks.reduce(0.0) { total, track in
            total + (track.duration.isFinite ? max(track.duration, 0) : 0)
        }
        return PlayerUIText.summary(count: tracks.count, duration: duration)
    }
}
