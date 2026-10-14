import Foundation

/// Persists access to user-linked folders (Files › Downloads, iCloud Drive, external drives…).
///
/// On iOS a URL obtained from the document picker is security-scoped; a *plain* bookmark created
/// while the scope is active keeps that grant (iOS has no `.withSecurityScope` option). After
/// resolving, callers must call `startAccessingSecurityScopedResource()` on the returned URL.
enum FolderBookmarks {
    /// Creates bookmark data for `url`. Call while the URL's security scope is active.
    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves bookmark data. Returns nil if the bookmark cannot be resolved (folder deleted,
    /// drive disconnected, provider removed, corrupt data…). When `isStale` is true the caller
    /// should create a fresh bookmark from the returned URL and persist it.
    static func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        guard !data.isEmpty else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            return nil
        }
    }
}
