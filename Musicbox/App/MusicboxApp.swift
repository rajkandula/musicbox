import SwiftUI

@main
struct MusicboxApp: App {
    @State private var library: LibraryStore
    @State private var player: PlayerEngine
    @State private var lyrics: LyricsStore
    @State private var documentsWatcher: DocumentsWatcher
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The player must observe the very same library instance the UI uses.
        let lib = LibraryStore()
        _library = State(initialValue: lib)
        _player = State(initialValue: PlayerEngine(library: lib))
        _lyrics = State(initialValue: LyricsStore(library: lib))
        // Songs copied into On My iPhone › Musicbox while the app is open show up by themselves.
        // The watcher already debounces, and scans never write there, so every event gets a pass
        // (rescan() folds it into a follow-up pass if a scan is running).
        _documentsWatcher = State(initialValue: DocumentsWatcher {
            Task { @MainActor in await lib.rescan() }
        })
    }

    var body: some Scene {
        WindowGroup {
            // One router per window: on iPad every window keeps its own tab, sheets and toasts.
            MusicboxSceneRoot(library: library, player: player, lyrics: lyrics)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                // Covers first launch too, and songs added in the Files app while we were away.
                Task { @MainActor in await library.rescanIfNeeded() }
                documentsWatcher.start()
                library.startWatchingLinkedFolders()
            case .background:
                documentsWatcher.stop()
                library.stopWatchingLinkedFolders()
                player.saveState()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

/// Root of one window. Library and player are shared by every window; the router (selected tab,
/// presented sheets, toasts) belongs to this window only.
private struct MusicboxSceneRoot: View {
    let library: LibraryStore
    let player: PlayerEngine
    let lyrics: LyricsStore

    @State private var router = AppRouter()

    var body: some View {
        RootView()
            .environment(library)
            .environment(player)
            .environment(lyrics)
            .environment(router)
            .onOpenURL { url in
                // "Open in Musicbox" / Share › Musicbox from Files, Safari, messaging apps…
                Task { @MainActor in
                    let countBefore = library.tracks.count
                    await library.handleOpenURL(url)
                    if library.tracks.count > countBefore {
                        router.showToast("Added to Your Library")
                    }
                }
            }
    }
}
