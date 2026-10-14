import SwiftUI

/// Videos segment: MP4 / MOV / M4V files. They play as audio like any song.
struct VideosView: View {
    @Binding var segment: LibraryView.Segment

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    var body: some View {
        let videos = library.videoTracks
        let includesVideos = library.settings.includeVideos

        List {
            LibraryHeader(segment: $segment)
                .libraryHeaderListRow()

            if !includesVideos {
                ContentUnavailableView {
                    Label("Videos Are Hidden", systemImage: "film")
                } description: {
                    Text("Turn on Include Videos to add MP4, MOV and M4V files to your library. They play as audio, even when your iPhone is locked.")
                } actions: {
                    Button("Include Videos") {
                        library.settings.includeVideos = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .listRowSeparator(.hidden)
            } else if videos.isEmpty {
                ContentUnavailableView(
                    "No Videos",
                    systemImage: "film",
                    description: Text("MP4, MOV and M4V files you add show up here and play as audio.")
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .listRowSeparator(.hidden)
            } else {
                Label {
                    Text("Videos play as audio. Open Now Playing › Show Video to watch.")
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.tint)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)

                PlayShuffleHeader(tracks: videos)
                    .listRowSeparator(.hidden)

                Section {
                    ForEach(videos) { track in
                        TrackRow(track: track)
                            .trackRowTapToPlay {
                                LibraryPlayback.play(track, in: videos, player: player, router: router)
                            }
                            .trackQueueSwipeActions(trackID: track.id, player: player, router: router)
                    }
                } footer: {
                    LibraryListFooter(tracks: videos, countsVideos: true)
                }
            }
        }
        .listStyle(.plain)
    }
}
