import SwiftUI

/// Playlists tab root (RootView wraps it in a NavigationStack).
/// "New Playlist…", smart playlists, then the user's playlists with swipe / context actions.
struct PlaylistsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    @State private var isCreating = false
    @State private var newPlaylistName = ""

    @State private var renameTarget: Playlist?
    @State private var isRenaming = false
    @State private var renameText = ""

    @State private var deleteTarget: Playlist?
    @State private var pickerTarget: PlaylistsPickerTarget?

    init() {}

    var body: some View {
        List {
            Section {
                Button(action: beginCreate) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 56, height: 56)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        Text("New Playlist…")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Playlist")
            }

            Section {
                ForEach(SmartPlaylistKind.allCases) { kind in
                    NavigationLink(value: kind) {
                        SmartPlaylistKindRow(kind: kind, count: smartCount(for: kind))
                    }
                }
            } header: {
                Text("Smart Playlists")
            }

            Section {
                if library.playlists.isEmpty {
                    ContentUnavailableView {
                        Label("No Playlists Yet", systemImage: "music.note.list")
                    } description: {
                        Text("Create a playlist to group songs and videos however you like.")
                    } actions: {
                        Button("New Playlist", action: beginCreate)
                            .buttonStyle(.borderedProminent)
                    }
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(library.playlists) { playlist in
                        NavigationLink(value: playlist.id) {
                            PlaylistsScreenRow(playlist: playlist, songCount: existingCount(of: playlist))
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                deleteTarget = playlist
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)

                            Button {
                                beginRename(playlist)
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.gray)
                        }
                        .contextMenu {
                            contextMenuItems(for: playlist)
                        }
                    }
                }
            } header: {
                Text("My Playlists")
            }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists")
        .navigationDestination(for: UUID.self) { playlistID in
            PlaylistDetailView(playlistID: playlistID)
        }
        .navigationDestination(for: SmartPlaylistKind.self) { kind in
            SmartPlaylistView(kind: kind)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: beginCreate) {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New Playlist")
            }
        }
        .alert("New Playlist", isPresented: $isCreating) {
            TextField("Playlist Name", text: $newPlaylistName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Create", action: createPlaylist)
        } message: {
            Text("Enter a name for this playlist.")
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Playlist Name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
            Button("Save", action: commitRename)
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { playlist in
            Button("Delete Playlist", role: .destructive) {
                library.deletePlaylist(playlist.id)
                router.showToast("Deleted “\(playlist.name)”")
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The songs stay in your library.")
        }
        .sheet(item: $pickerTarget) { target in
            TrackPickerSheet(playlistID: target.id)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenuItems(for playlist: Playlist) -> some View {
        Button {
            play(playlist, shuffled: false)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button {
            play(playlist, shuffled: true)
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }
        Button {
            pickerTarget = PlaylistsPickerTarget(id: playlist.id)
        } label: {
            Label("Add Songs…", systemImage: "plus")
        }
        Divider()
        Button {
            beginRename(playlist)
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button(role: .destructive) {
            deleteTarget = playlist
        } label: {
            Label("Delete Playlist", systemImage: "trash")
        }
    }

    // MARK: Helpers

    private func smartCount(for kind: SmartPlaylistKind) -> Int {
        switch kind {
        case .favorites: return library.favoriteTracks.count
        case .recentlyAdded: return library.recentlyAddedTracks.count
        case .mostPlayed: return library.mostPlayedTracks.count
        }
    }

    /// Songs that still exist in the library (missing IDs are skipped everywhere in the UI).
    private func existingCount(of playlist: Playlist) -> Int {
        playlist.trackIDs.reduce(into: 0) { count, trackID in
            if library.track(id: trackID) != nil { count += 1 }
        }
    }

    private var deleteDialogTitle: String {
        guard let deleteTarget else { return "Delete Playlist?" }
        return "Delete “\(deleteTarget.name)”?"
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { isPresented in
                if !isPresented { deleteTarget = nil }
            }
        )
    }

    // MARK: Actions

    private func beginCreate() {
        newPlaylistName = ""
        isCreating = true
    }

    private func createPlaylist() {
        let name = PlayerUIText.cleanedName(newPlaylistName)
            ?? PlayerUIText.uniqueName("New Playlist", existing: library.playlists)
        let playlist = library.createPlaylist(name: name)
        newPlaylistName = ""

        guard !library.tracks.isEmpty else {
            router.showToast("Created “\(playlist.name)”")
            return
        }
        // Offer to fill the new playlist right away. Wait for the alert to finish dismissing
        // before presenting the picker sheet.
        let playlistID = playlist.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard library.playlist(id: playlistID) != nil else { return }
            pickerTarget = PlaylistsPickerTarget(id: playlistID)
        }
    }

    private func beginRename(_ playlist: Playlist) {
        renameTarget = playlist
        renameText = playlist.name
        isRenaming = true
    }

    private func commitRename() {
        defer { renameTarget = nil }
        guard let target = renameTarget,
              let name = PlayerUIText.cleanedName(renameText),
              name != target.name else { return }
        library.renamePlaylist(target.id, to: name)
    }

    private func play(_ playlist: Playlist, shuffled: Bool) {
        let tracks = library.tracks(in: playlist)
        guard !tracks.isEmpty else {
            router.showToast("“\(playlist.name)” is empty")
            return
        }
        if shuffled {
            player.shuffleAll(tracks)
        } else {
            player.play(tracks: tracks, startAt: 0)
        }
    }
}

// MARK: - Sheet target

private struct PlaylistsPickerTarget: Identifiable {
    let id: UUID
}

// MARK: - Rows

private struct SmartPlaylistKindRow: View {
    let kind: SmartPlaylistKind
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: kind.gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: kind.systemImage)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.white)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(PlayerUIText.songCount(count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct PlaylistsScreenRow: View {
    let playlist: Playlist
    let songCount: Int

    var body: some View {
        HStack(spacing: 12) {
            PlaylistArtworkMosaic(trackIDs: playlist.trackIDs, size: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(PlayerUIText.songCount(songCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
