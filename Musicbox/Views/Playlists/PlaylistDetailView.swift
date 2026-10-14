import SwiftUI

/// A user playlist: header mosaic, name, song count + total duration, Play / Shuffle,
/// "Add Songs", and the editable track list (swipe to delete, Edit to reorder).
struct PlaylistDetailView: View {
    let playlistID: UUID

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var editMode: EditMode = .inactive
    @State private var showsTrackPicker = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var confirmsDelete = false

    init(playlistID: UUID) {
        self.playlistID = playlistID
    }

    var body: some View {
        if let playlist = library.playlist(id: playlistID) {
            content(for: playlist)
        } else {
            ContentUnavailableView(
                "Playlist Unavailable",
                systemImage: "music.note.list",
                description: Text("This playlist has been deleted.")
            )
            .task {
                dismiss()
            }
        }
    }

    // MARK: Content

    private func content(for playlist: Playlist) -> some View {
        let entries = makeEntries(for: playlist)
        let tracks = entries.map(\.track)
        let totalDuration = tracks.reduce(0.0) { total, track in
            total + (track.duration.isFinite ? max(track.duration, 0) : 0)
        }

        return List {
            Section {
                header(for: playlist, count: tracks.count, totalDuration: totalDuration)
                    .listRowSeparator(.hidden)

                if !tracks.isEmpty {
                    PlayShuffleHeader(tracks: tracks)
                        .listRowSeparator(.hidden)
                }

                Button {
                    showsTrackPicker = true
                } label: {
                    Label("Add Songs", systemImage: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(Color.accentColor)
                .listRowSeparator(.hidden)
                .disabled(editMode.isEditing)
            }

            Section {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Songs Yet", systemImage: "music.note")
                    } description: {
                        Text("Tap Add Songs to start filling this playlist.")
                    }
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(entries) { entry in
                        TrackRow(track: entry.track, playlistID: playlistID)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !editMode.isEditing else { return }
                                player.play(tracks: tracks, startAt: entry.position)
                            }
                            .accessibilityAddTraits(.isButton)
                    }
                    .onDelete { offsets in
                        removeEntries(at: offsets, from: entries)
                    }
                    .onMove { source, destination in
                        moveEntries(from: source, to: destination, in: entries)
                    }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !entries.isEmpty {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }
                    .fontWeight(editMode.isEditing ? .semibold : .regular)
                }

                Menu {
                    Button {
                        showsTrackPicker = true
                    } label: {
                        Label("Add Songs…", systemImage: "plus")
                    }
                    Button {
                        renameText = playlist.name
                        isRenaming = true
                    } label: {
                        Label("Rename…", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmsDelete = true
                    } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Playlist Options")
            }
        }
        .sheet(isPresented: $showsTrackPicker) {
            TrackPickerSheet(playlistID: playlistID)
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Playlist Name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                commitRename(currentName: playlist.name)
            }
        }
        .confirmationDialog(
            "Delete “\(playlist.name)”?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                let name = playlist.name
                // The view then shows its "unavailable" state, which dismisses it.
                library.deletePlaylist(playlistID)
                router.showToast("Deleted “\(name)”")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The songs stay in your library.")
        }
        .onChange(of: entries.isEmpty) { _, isEmpty in
            if isEmpty { editMode = .inactive }
        }
    }

    private func header(for playlist: Playlist, count: Int, totalDuration: TimeInterval) -> some View {
        VStack(spacing: 10) {
            PlaylistArtworkMosaic(trackIDs: playlist.trackIDs, size: 200)
                .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
                .padding(.top, 8)

            Text(playlist.name)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)

            Text(PlayerUIText.summary(count: count, duration: totalDuration))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    /// Playlist entries that still resolve to a library track, remembering their index in
    /// `playlist.trackIDs` so deletes / moves hit the right items even when some IDs are missing.
    private func makeEntries(for playlist: Playlist) -> [PlaylistTrackEntry] {
        var entries: [PlaylistTrackEntry] = []
        entries.reserveCapacity(playlist.trackIDs.count)
        var seen: [String: Int] = [:]

        for (index, trackID) in playlist.trackIDs.enumerated() {
            guard let track = library.track(id: trackID) else { continue }
            let occurrence = seen[trackID, default: 0]
            seen[trackID] = occurrence + 1
            let id = occurrence == 0 ? trackID : "\(trackID)#\(occurrence)"
            entries.append(PlaylistTrackEntry(id: id, playlistIndex: index, position: entries.count, track: track))
        }
        return entries
    }

    // MARK: Actions

    private func removeEntries(at offsets: IndexSet, from entries: [PlaylistTrackEntry]) {
        let indices = IndexSet(offsets.compactMap { offset in
            entries.indices.contains(offset) ? entries[offset].playlistIndex : nil
        })
        guard !indices.isEmpty else { return }
        library.removeTracks(at: indices, from: playlistID)
    }

    private func moveEntries(from source: IndexSet, to destination: Int, in entries: [PlaylistTrackEntry]) {
        let mappedSource = IndexSet(source.compactMap { offset in
            entries.indices.contains(offset) ? entries[offset].playlistIndex : nil
        })
        guard !mappedSource.isEmpty else { return }

        let mappedDestination: Int
        if destination >= 0, destination < entries.count {
            mappedDestination = entries[destination].playlistIndex
        } else {
            mappedDestination = library.playlist(id: playlistID)?.trackIDs.count ?? 0
        }
        library.moveTracks(in: playlistID, from: mappedSource, to: mappedDestination)
    }

    private func commitRename(currentName: String) {
        guard let name = PlayerUIText.cleanedName(renameText), name != currentName else { return }
        library.renamePlaylist(playlistID, to: name)
    }
}

// MARK: - Row model

private struct PlaylistTrackEntry: Identifiable {
    let id: String
    /// Index into `playlist.trackIDs`.
    let playlistIndex: Int
    /// Index among the displayed (existing) tracks, used to start playback.
    let position: Int
    let track: Track
}
