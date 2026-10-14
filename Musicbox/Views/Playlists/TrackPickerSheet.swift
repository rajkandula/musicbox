import SwiftUI

/// Searchable multi-select list of every library track, used to add songs to a playlist.
/// Tracks already in the playlist are shown as "Added" and can't be selected again.
struct TrackPickerSheet: View {
    let playlistID: UUID

    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection: Set<String> = []
    /// Results for `resultsQuery` (filtered off the main thread).
    @State private var searchResults: [Track] = []
    @State private var resultsQuery = ""

    init(playlistID: UUID) {
        self.playlistID = playlistID
    }

    var body: some View {
        let playlist = library.playlist(id: playlistID)
        let title: String = playlist.map { "Add to \($0.name)" } ?? "Add Songs"

        NavigationStack {
            Group {
                if let playlist {
                    if library.tracks.isEmpty {
                        ContentUnavailableView(
                            "No Songs in Your Library",
                            systemImage: "music.note",
                            description: Text("Add music from the Library tab, then come back to build this playlist.")
                        )
                    } else {
                        picker(for: playlist)
                    }
                } else {
                    ContentUnavailableView(
                        "Playlist Unavailable",
                        systemImage: "music.note.list",
                        description: Text("This playlist no longer exists.")
                    )
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        commit()
                    } label: {
                        Text(selection.isEmpty ? "Add" : "Add (\(selection.count))")
                            .fontWeight(.semibold)
                    }
                    .disabled(selection.isEmpty || playlist == nil)
                }
            }
        }
    }

    // MARK: Picker list

    private func picker(for playlist: Playlist) -> some View {
        let existing = Set(playlist.trackIDs)
        let normalizedQuery = Self.normalize(query)
        let isSearching = !normalizedQuery.isEmpty
        let shown = isSearching ? searchResults : library.tracks
        let isSearchPending = isSearching && resultsQuery != normalizedQuery
        let selectableIDs = shown.lazy.map(\.id).filter { !existing.contains($0) }
        let allShownSelected = !selectableIDs.isEmpty && selectableIDs.allSatisfy { selection.contains($0) }

        return List {
            ForEach(shown) { track in
                let isAdded = existing.contains(track.id)
                let isSelected = selection.contains(track.id)

                Button {
                    toggle(track.id)
                } label: {
                    TrackPickerRow(track: track, isSelected: isSelected, isAlreadyAdded: isAdded)
                }
                .buttonStyle(.plain)
                .disabled(isAdded)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint(isAdded ? "Already in this playlist" : "")
            }
        }
        .listStyle(.plain)
        .overlay {
            if isSearching && !isSearchPending && shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Songs, artists, albums"
        )
        .autocorrectionDisabled()
        .task(id: normalizedQuery) {
            await updateSearch(for: normalizedQuery)
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button(allShownSelected ? "Deselect All" : "Select All") {
                    let ids = Array(selectableIDs)
                    if allShownSelected {
                        selection.subtract(ids)
                    } else {
                        selection.formUnion(ids)
                    }
                }
                .disabled(selectableIDs.isEmpty)

                Spacer()

                Text(selection.isEmpty ? "No songs selected" : "\(PlayerUIText.songCount(selection.count)) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()   // iOS 26 bottom-bar glass items otherwise truncate this to "2 so…"
            }
        }
    }

    // MARK: Actions

    private func toggle(_ trackID: String) {
        if selection.contains(trackID) {
            selection.remove(trackID)
        } else {
            selection.insert(trackID)
        }
    }

    private func commit() {
        guard let playlist = library.playlist(id: playlistID) else {
            dismiss()
            return
        }
        // Keep library order so the playlist reads naturally.
        let ids = library.tracks.lazy.map(\.id).filter { selection.contains($0) }
        let orderedIDs = Array(ids)
        guard !orderedIDs.isEmpty else {
            dismiss()
            return
        }
        library.addTracks(orderedIDs, to: playlistID)
        router.showToast("Added \(PlayerUIText.songCount(orderedIDs.count)) to \(playlist.name)")
        dismiss()
    }

    // MARK: Search

    private func updateSearch(for normalizedQuery: String) async {
        guard !normalizedQuery.isEmpty else {
            searchResults = []
            resultsQuery = ""
            return
        }
        // Debounce keystrokes; `.task(id:)` cancels this when the query changes again.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }

        let allTracks = library.tracks
        let results = await Task.detached(priority: .userInitiated) {
            TrackPickerSheet.filter(allTracks, query: normalizedQuery)
        }.value
        guard !Task.isCancelled else { return }
        searchResults = results
        resultsQuery = normalizedQuery
    }

    private nonisolated static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every whitespace-separated term must match the title, artist or album
    /// (case- and diacritic-insensitive).
    private nonisolated static func filter(_ tracks: [Track], query: String) -> [Track] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return tracks }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return tracks.filter { track in
            terms.allSatisfy { term in
                track.title.range(of: term, options: options) != nil
                    || track.artist.range(of: term, options: options) != nil
                    || track.album.range(of: term, options: options) != nil
            }
        }
    }
}

// MARK: - Row

private struct TrackPickerRow: View {
    let track: Track
    let isSelected: Bool
    let isAlreadyAdded: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(trackID: track.id, size: 40, cornerRadius: 5, isVideo: track.isVideo)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if track.isVideo {
                        Image(systemName: "film")
                            .font(.caption2)
                    }
                    Text(PlayerUIText.subtitle(for: track))
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isAlreadyAdded {
                Text("Added")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(isAlreadyAdded ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}
