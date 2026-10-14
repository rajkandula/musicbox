import SwiftUI
import UIKit

/// Library tab root: Songs / Albums / Artists / Videos.
struct LibraryView: View {
    enum Segment: String, CaseIterable, Identifiable {
        case songs, albums, artists, videos

        var id: String { rawValue }

        var title: String {
            switch self {
            case .songs: return "Songs"
            case .albums: return "Albums"
            case .artists: return "Artists"
            case .videos: return "Videos"
            }
        }
    }

    @Environment(LibraryStore.self) private var library
    @SceneStorage("musicbox.library.segment") private var segment: Segment = .songs
    @State private var isPickingFolder = false
    @State private var isImportingFiles = false

    var body: some View {
        @Bindable var library = library

        content
            .navigationTitle("Library")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if (segment == .songs || segment == .videos) && !library.tracks.isEmpty {
                        Menu {
                            Picker("Sort Songs By", selection: $library.settings.songSort) {
                                ForEach(SongSort.allCases) { sort in
                                    Text(sort.label).tag(sort)
                                }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    }

                    Button {
                        Task { @MainActor in await rescanIfIdle() }
                    } label: {
                        if library.isScanning {
                            ProgressView()
                        } else {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(library.isScanning)
                    .accessibilityLabel(library.isScanning ? "Scanning" : "Rescan Library")

                    Menu {
                        Button {
                            isPickingFolder = true
                        } label: {
                            Label("Link a Folder…", systemImage: "folder.badge.plus")
                        }
                        Button {
                            isImportingFiles = true
                        } label: {
                            Label("Import Files…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Label("Add Music", systemImage: "plus")
                    }
                }
            }
            .refreshable {
                // Even while a scan runs: it queues one more pass, so a song that just arrived is
                // found (the running pass may already have listed its folder).
                await library.rescan()
            }
            .navigationDestination(for: AlbumGroup.self) { album in
                AlbumDetailView(album: album)
            }
            .navigationDestination(for: ArtistGroup.self) { artist in
                ArtistDetailView(artist: artist)
            }
            .musicSourceImporters(isPickingFolder: $isPickingFolder, isImportingFiles: $isImportingFiles)
    }

    @ViewBuilder
    private var content: some View {
        if library.tracks.isEmpty {
            if library.isScanning {
                LibraryFirstScanView()
            } else {
                EmptyLibraryView(
                    onLinkFolder: { isPickingFolder = true },
                    onImportFiles: { isImportingFiles = true }
                )
            }
        } else {
            switch segment {
            case .songs:
                LibrarySongsList(segment: $segment)
            case .albums:
                AlbumsView(segment: $segment)
            case .artists:
                ArtistsView(segment: $segment)
            case .videos:
                VideosView(segment: $segment)
            }
        }
    }

    private func rescanIfIdle() async {
        guard !library.isScanning else { return }
        await library.rescan()
    }
}

// MARK: - Header (segment picker + scan banner)

/// Top of every library list: the segmented picker plus a scan-progress banner.
struct LibraryHeader: View {
    @Binding var segment: LibraryView.Segment

    var body: some View {
        VStack(spacing: 10) {
            Picker("Show", selection: $segment) {
                ForEach(LibraryView.Segment.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LibraryScanBanner()
        }
    }
}

extension View {
    /// Row styling for `LibraryHeader` when used as the first row of a plain List.
    @MainActor func libraryHeaderListRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
    }
}

/// Shows "Scanning…" progress while the library is scanning. Reads the frequently-changing
/// `scanStatus` in its own body so the (potentially huge) lists don't re-render on every update.
struct LibraryScanBanner: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if library.isScanning {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(library.scanStatus ?? "Scanning for music…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityElement(children: .combine)
        }
    }
}

/// Shown instead of the empty-library onboarding while the very first scan is running.
private struct LibraryFirstScanView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Looking for music…")
                .font(.headline)
            Text(library.scanStatus ?? "Checking your files")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Songs

private struct LibrarySongsList: View {
    @Binding var segment: LibraryView.Segment

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        // Computed once per body evaluation (the store keeps `tracks` pre-sorted).
        let tracks = library.tracks

        List {
            LibraryHeader(segment: $segment)
                .libraryHeaderListRow()

            PlayShuffleHeader(tracks: tracks)
                .listRowSeparator(.hidden)

            Section {
                ForEach(tracks) { track in
                    TrackRow(track: track)
                        .trackRowTapToPlay {
                            LibraryPlayback.play(track, in: tracks, player: player, router: router)
                        }
                        .trackQueueSwipeActions(trackID: track.id, player: player, router: router)
                }
            } footer: {
                LibraryListFooter(tracks: tracks)
            }
        }
        .listStyle(.plain)
    }
}

/// "1234 songs · 76 hr 4 min" style footer under long lists.
struct LibraryListFooter: View {
    let tracks: [Track]
    var countsVideos: Bool = false

    var body: some View {
        let total = tracks.reduce(0.0) { partial, track in
            track.duration.isFinite && track.duration > 0 ? partial + track.duration : partial
        }
        let count = tracks.count
        let countText: String = countsVideos
            ? (count == 1 ? "1 video" : "\(count) videos")
            : LibraryFormatting.songCount(count)
        Text(total > 0 ? "\(countText) · \(LibraryFormatting.totalDuration(total))" : countText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}
