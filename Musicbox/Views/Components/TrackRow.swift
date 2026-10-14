import SwiftUI

/// Standard song row: artwork, title (accent + animated waveform when it is the current track),
/// subtitle, a "VIDEO" badge for videos, duration and a trailing "…" menu.
/// Tapping the row is handled by the caller (see `trackRowTapToPlay(_:)`).
struct TrackRow: View {
    private let track: Track
    private let playlistID: UUID?
    private let showsArtwork: Bool

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @State private var isConfirmingDelete = false

    init(track: Track, playlistID: UUID? = nil, showsArtwork: Bool = true) {
        self.track = track
        self.playlistID = playlistID
        self.showsArtwork = showsArtwork
    }

    var body: some View {
        let isCurrent = player.currentTrack?.id == track.id

        HStack(spacing: 12) {
            HStack(spacing: 12) {
                if showsArtwork {
                    ArtworkView(trackID: track.id, size: 48, cornerRadius: 6, isVideo: track.isVideo)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isCurrent {
                            TrackRowPlayingIndicator()
                        }
                        Text(track.title)
                            .font(.body)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        if track.isVideo {
                            Text("VIDEO")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 0.8)
                                }
                        }
                        if track.isFavorite {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                        Text(track.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if track.duration > 0 {
                    Text(track.duration.mmss)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription(isCurrent: isCurrent))

            Menu {
                TrackMenuItems(track: track, playlistID: playlistID, onDeleteRequest: deleteHandler)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options for \(track.title)")
        }
        .contentShape(Rectangle())
        .contextMenu {
            TrackMenuItems(track: track, playlistID: playlistID, onDeleteRequest: deleteHandler)
        }
        .confirmationDialog(
            "Delete “\(track.title)” from this iPhone?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete from iPhone", role: .destructive) {
                deleteFromDevice()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file will be removed from On My iPhone › Musicbox. This can’t be undone.")
        }
    }

    // MARK: Helpers

    /// Only files stored inside the app's own Documents folder can be deleted from the device.
    private var deleteHandler: (() -> Void)? {
        guard case .documents = track.location else { return nil }
        return { isConfirmingDelete = true }
    }

    private func deleteFromDevice() {
        let title = track.title
        do {
            try library.deleteFromDevice(track.id)
            router.showToast("Deleted “\(title)”")
        } catch {
            router.showToast("Couldn’t delete: \(error.localizedDescription)")
        }
    }

    private func accessibilityDescription(isCurrent: Bool) -> String {
        var parts: [String] = []
        if isCurrent { parts.append("Now playing") }
        parts.append(track.title)
        parts.append(track.subtitle)
        if track.isVideo { parts.append("Video") }
        if track.isFavorite { parts.append("Favorite") }
        if track.duration > 0 { parts.append(track.duration.mmss) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Animated "waveform" shown next to the current track's title. It reads `player.isPlaying`
/// in its own body so play/pause only re-renders this small view, not every row.
private struct TrackRowPlayingIndicator: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Image(systemName: "waveform")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
            .accessibilityHidden(true)
    }
}

/// Contents for a track's "…" menu and context menu.
struct TrackMenuItems: View {
    private let track: Track
    private let playlistID: UUID?
    private let onDeleteRequest: (() -> Void)?

    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    init(track: Track, playlistID: UUID? = nil, onDeleteRequest: (() -> Void)? = nil) {
        self.track = track
        self.playlistID = playlistID
        self.onDeleteRequest = onDeleteRequest
    }

    var body: some View {
        let isFavorite = library.track(id: track.id)?.isFavorite ?? track.isFavorite

        Section {
            Button {
                player.playNext([track.id])
                router.showToast("Playing Next")
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                player.addToQueue([track.id])
                router.showToast("Added to Queue")
            } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }

        Section {
            Button {
                router.addToPlaylist([track.id])
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }

            Button {
                library.toggleFavorite(track.id)
                router.showToast(isFavorite ? "Removed from Favorites" : "Added to Favorites")
            } label: {
                Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart")
            }
        }

        if playlistID != nil || (isInDocuments && onDeleteRequest != nil) {
            Section {
                if let playlistID {
                    Button(role: .destructive) {
                        library.removeTrack(track.id, from: playlistID)
                        router.showToast("Removed from Playlist")
                    } label: {
                        Label("Remove from Playlist", systemImage: "minus.circle")
                    }
                }

                if isInDocuments, let onDeleteRequest {
                    Button(role: .destructive) {
                        onDeleteRequest()
                    } label: {
                        Label("Delete from iPhone", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var isInDocuments: Bool {
        if case .documents = track.location { return true }
        return false
    }
}

// MARK: - Row helpers used by the library / search screens

extension View {
    /// Makes a track row tappable (e.g. to start playback) without stealing taps from its "…" menu.
    @MainActor func trackRowTapToPlay(_ action: @escaping () -> Void) -> some View {
        self
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }

    /// Leading swipe actions: Play Next / Add to Queue (Apple Music style).
    @MainActor func trackQueueSwipeActions(
        trackID: String,
        player: PlayerEngine,
        router: AppRouter
    ) -> some View {
        self.swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                player.playNext([trackID])
                router.showToast("Playing Next")
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.indigo)

            Button {
                player.addToQueue([trackID])
                router.showToast("Added to Queue")
            } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .tint(.orange)
        }
    }
}
