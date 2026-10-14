import SwiftUI

/// "Add to Playlist" chooser: create a new playlist with these tracks, or append them to an
/// existing one. Playlists that already contain every track are shown as "Added".
struct AddToPlaylistSheet: View {
    let trackIDs: [String]

    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var isCreating = false
    @State private var newPlaylistName = ""

    init(trackIDs: [String]) {
        self.trackIDs = trackIDs
    }

    var body: some View {
        let ids = uniqueExistingTrackIDs
        let wanted = Set(ids)

        NavigationStack {
            Group {
                if ids.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Add",
                        systemImage: "music.note",
                        description: Text("These songs are no longer in your library.")
                    )
                } else {
                    List {
                        Section {
                            Button {
                                newPlaylistName = ""
                                isCreating = true
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.14))
                                        .frame(width: 48, height: 48)
                                        .overlay {
                                            Image(systemName: "plus")
                                                .font(.title3.weight(.semibold))
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
                        } header: {
                            Text(headerText(for: ids))
                                .textCase(nil)
                                .lineLimit(2)
                        }

                        if !library.playlists.isEmpty {
                            Section {
                                ForEach(library.playlists) { playlist in
                                    let isAdded = wanted.isSubset(of: playlist.trackIDs)

                                    Button {
                                        add(ids, to: playlist)
                                    } label: {
                                        AddToPlaylistRowLabel(
                                            playlist: playlist,
                                            songCount: existingCount(of: playlist),
                                            isAdded: isAdded
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isAdded)
                                    .accessibilityHint(isAdded ? "Already contains these songs" : "Adds to this playlist")
                                }
                            } header: {
                                Text("Your Playlists")
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("New Playlist", isPresented: $isCreating) {
                TextField("Playlist Name", text: $newPlaylistName)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    createPlaylist(with: ids)
                }
            } message: {
                Text(ids.count == 1
                     ? "The song will be added to the new playlist."
                     : "\(PlayerUIText.songCount(ids.count)) will be added to the new playlist.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Data

    /// De-duplicated IDs (order preserved) that still exist in the library.
    private var uniqueExistingTrackIDs: [String] {
        var seen = Set<String>()
        return trackIDs.filter { trackID in
            library.track(id: trackID) != nil && seen.insert(trackID).inserted
        }
    }

    private func existingCount(of playlist: Playlist) -> Int {
        playlist.trackIDs.reduce(into: 0) { count, trackID in
            if library.track(id: trackID) != nil { count += 1 }
        }
    }

    private func headerText(for ids: [String]) -> String {
        if ids.count == 1, let track = library.track(id: ids[0]) {
            return "Add “\(track.title)” to…"
        }
        return "Add \(PlayerUIText.songCount(ids.count)) to…"
    }

    // MARK: Actions

    private func add(_ ids: [String], to playlist: Playlist) {
        guard !ids.isEmpty else { return }
        library.addTracks(ids, to: playlist.id)
        router.showToast("Added to \(playlist.name)")
        dismiss()
    }

    private func createPlaylist(with ids: [String]) {
        let name = PlayerUIText.cleanedName(newPlaylistName)
            ?? PlayerUIText.uniqueName("New Playlist", existing: library.playlists)
        let playlist = library.createPlaylist(name: name, trackIDs: ids)
        newPlaylistName = ""
        router.showToast("Added to \(playlist.name)")
        dismiss()
    }
}

// MARK: - Row

private struct AddToPlaylistRowLabel: View {
    let playlist: Playlist
    let songCount: Int
    let isAdded: Bool

    var body: some View {
        HStack(spacing: 12) {
            PlaylistArtworkMosaic(trackIDs: playlist.trackIDs, size: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(PlayerUIText.songCount(songCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isAdded {
                Label("Added", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .opacity(isAdded ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
