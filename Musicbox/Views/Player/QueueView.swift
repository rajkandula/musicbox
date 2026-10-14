import SwiftUI

/// The play queue, embedded inline in NowPlayingView (no NavigationStack of its own).
///
/// "Now Playing" shows the current track (not deletable / movable); "Up Next" lists everything
/// after it. Swipe to delete, long-press-drag (or Edit) to reorder, tap to jump, "Clear" to drop
/// all upcoming tracks. Display offsets are mapped back to real queue indices, so missing tracks
/// or duplicate IDs in the queue never cause the wrong item to be moved or removed.
struct QueueView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    @State private var editMode: EditMode = .inactive

    init() {}

    var body: some View {
        let upcoming = upcomingEntries()

        List {
            if let current = player.currentTrack {
                Section {
                    QueueTrackRowView(track: current, isCurrent: true)
                        .listRowBackground(Color.clear)
                        .moveDisabled(true)
                        .deleteDisabled(true)
                } header: {
                    Text("Now Playing")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }

            Section {
                if upcoming.isEmpty {
                    Text("No upcoming songs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(Color.clear)
                        .moveDisabled(true)
                        .deleteDisabled(true)
                } else {
                    ForEach(upcoming) { entry in
                        Button {
                            guard !editMode.isEditing else { return }
                            player.jump(to: entry.queueIndex)
                        } label: {
                            QueueTrackRowView(track: entry.track, isCurrent: false)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .accessibilityHint("Plays this song now")
                    }
                    .onMove { source, destination in
                        move(from: source, to: destination, in: upcoming)
                    }
                    .onDelete { offsets in
                        remove(at: offsets, in: upcoming)
                    }
                }
            } header: {
                upNextHeader(count: upcoming.count)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
        .onChange(of: upcoming.isEmpty) { _, isEmpty in
            if isEmpty { editMode = .inactive }
        }
    }

    // MARK: Header

    private func upNextHeader(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Up Next")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            if count > 0 {
                Text(PlayerUIText.songCount(count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if count > 0 {
                Button(editMode.isEditing ? "Done" : "Edit") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
                .font(.subheadline.weight(editMode.isEditing ? .semibold : .regular))
                .buttonStyle(.borderless)

                Button("Clear") {
                    clearUpcoming()
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
                .accessibilityHint("Removes all upcoming songs from the queue")
            }
        }
        .textCase(nil)
        .tint(Color.accentColor)
    }

    // MARK: Data

    /// Upcoming queue items with their real queue index. IDs stay stable across moves
    /// (track ID + occurrence number), which keeps List animations correct.
    private func upcomingEntries() -> [QueueEntryItem] {
        let queue = player.queue
        let start = (player.currentIndex ?? -1) + 1
        guard start >= 0, start < queue.count else { return [] }

        var occurrences: [String: Int] = [:]
        var result: [QueueEntryItem] = []
        result.reserveCapacity(queue.count - start)

        for index in start..<queue.count {
            let trackID = queue[index]
            let occurrence = occurrences[trackID, default: 0]
            occurrences[trackID] = occurrence + 1
            guard let track = library.track(id: trackID) else { continue }
            let id = occurrence == 0 ? trackID : "\(trackID)#\(occurrence)"
            result.append(QueueEntryItem(id: id, queueIndex: index, track: track))
        }
        return result
    }

    // MARK: Actions

    private func move(from source: IndexSet, to destination: Int, in entries: [QueueEntryItem]) {
        let mappedSource = IndexSet(source.compactMap { offset in
            entries.indices.contains(offset) ? entries[offset].queueIndex : nil
        })
        guard !mappedSource.isEmpty else { return }

        let mappedDestination: Int
        if destination >= 0, destination < entries.count {
            mappedDestination = entries[destination].queueIndex
        } else {
            mappedDestination = player.queue.count
        }
        player.moveInQueue(from: mappedSource, to: mappedDestination)
    }

    private func remove(at offsets: IndexSet, in entries: [QueueEntryItem]) {
        let mapped = IndexSet(offsets.compactMap { offset in
            entries.indices.contains(offset) ? entries[offset].queueIndex : nil
        })
        guard !mapped.isEmpty else { return }
        player.removeFromQueue(at: mapped)
    }

    private func clearUpcoming() {
        let start = (player.currentIndex ?? -1) + 1
        let count = player.queue.count
        guard start >= 0, start < count else { return }
        withAnimation {
            player.removeFromQueue(at: IndexSet(integersIn: start..<count))
            editMode = .inactive
        }
    }
}

// MARK: - Row model

private struct QueueEntryItem: Identifiable {
    let id: String
    let queueIndex: Int
    let track: Track
}

// MARK: - Row view

private struct QueueTrackRowView: View {
    let track: Track
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(trackID: track.id, size: 44, cornerRadius: 6, isVideo: track.isVideo)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(PlayerUIText.subtitle(for: track))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isCurrent {
                QueuePlayingIndicator()
            } else if track.duration > 0 {
                Text(track.duration.mmss)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Animated waveform for the current row; reads `isPlaying` in its own body.
private struct QueuePlayingIndicator: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        Image(systemName: "waveform")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: player.isPlaying)
            .accessibilityLabel(player.isPlaying ? "Playing" : "Paused")
    }
}
