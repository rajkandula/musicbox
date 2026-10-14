import SwiftUI
import Observation

/// Top-level tabs of the app.
enum AppTab: Hashable {
    case library, playlists, search, settings
}

/// A request to show the "Add to Playlist" sheet for one or more tracks.
struct AddToPlaylistRequest: Identifiable {
    let id = UUID()
    let trackIDs: [String]
}

/// Shared UI routing state: selected tab, sheet presentation and transient toasts.
@MainActor @Observable
final class AppRouter {
    var selectedTab: AppTab = .library
    var isNowPlayingPresented: Bool = false
    /// Presented by RootView as `AddToPlaylistSheet(trackIDs:)`.
    var addToPlaylistRequest: AddToPlaylistRequest?
    /// Presented by NowPlayingView (so it works while Now Playing is itself a sheet).
    var nowPlayingAddToPlaylistRequest: AddToPlaylistRequest?
    /// Transient message shown as a capsule overlay; auto-hides after ~1.8 s.
    var toast: String?

    @ObservationIgnored private var toastHideTask: Task<Void, Never>?

    init() {}

    func showToast(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        toastHideTask?.cancel()
        toast = trimmed
        toastHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.toastHideTask = nil
        }
    }

    /// Routes to whichever presenter is on top: if Now Playing is presented, NowPlayingView presents
    /// the sheet; otherwise RootView does. Never present sheets from inside List rows.
    func addToPlaylist(_ trackIDs: [String]) {
        var seen = Set<String>()
        let unique = trackIDs.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        let request = AddToPlaylistRequest(trackIDs: unique)
        if isNowPlayingPresented {
            nowPlayingAddToPlaylistRequest = request
        } else {
            addToPlaylistRequest = request
        }
    }
}
