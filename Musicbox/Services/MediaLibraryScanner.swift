import Foundation
import MediaPlayer
import UIKit

/// A DRM-free, locally stored song from the device Music library.
struct MediaLibraryItem: Sendable {
    let location: TrackLocation      // .mediaLibrary(persistentID:assetURL:)
    let metadata: TrackMetadata      // from MPMediaItem properties
    let dateAdded: Date
}

/// Reads songs synced to the device's Music library (opt-in, needs Apple Music permission).
enum MediaLibraryScanner {
    static var isAuthorized: Bool {
        MPMediaLibrary.authorizationStatus() == .authorized
    }

    /// Asks for Music library access if it has not been decided yet.
    static func requestAuthorization() async -> Bool {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            break
        @unknown default:
            break
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// MPMediaQuery.songs(); skips items with nil assetURL (DRM / cloud-only) and hasProtectedAsset.
    /// Returns [] when not authorized or on simulator. Synchronous — call off the main actor.
    /// `needsArtwork(stableID)` returning false skips rendering that song's artwork (already cached).
    static func scan(needsArtwork: (String) -> Bool = { _ in true }) -> [MediaLibraryItem] {
        #if targetEnvironment(simulator)
        return []
        #else
        guard isAuthorized else { return [] }

        let query = MPMediaQuery.songs()
        query.addFilterPredicate(
            MPMediaPropertyPredicate(value: false, forProperty: MPMediaItemPropertyIsCloudItem)
        )
        guard let items = query.items, !items.isEmpty else { return [] }

        var results: [MediaLibraryItem] = []
        results.reserveCapacity(items.count)
        var seenIDs = Set<MPMediaEntityPersistentID>()
        var artworkCache = AlbumArtworkCache()

        for item in items {
            autoreleasepool {
                guard let entry = makeItem(
                    from: item,
                    seenIDs: &seenIDs,
                    artworkCache: &artworkCache,
                    needsArtwork: needsArtwork
                ) else {
                    return
                }
                results.append(entry)
            }
        }
        return results
        #endif
    }

    // MARK: - Private

    /// Songs of one album share artwork; rendering/encoding it once per album keeps scans fast and
    /// memory bounded for large libraries (identical `Data` values share storage).
    private struct AlbumArtworkCache {
        var dataByAlbum: [MPMediaEntityPersistentID: Data] = [:]
        var albumsWithoutArtwork = Set<MPMediaEntityPersistentID>()
    }

    private static let artworkSize = CGSize(width: 600, height: 600)
    private static let artworkQuality: CGFloat = 0.85

    private static func makeItem(
        from item: MPMediaItem,
        seenIDs: inout Set<MPMediaEntityPersistentID>,
        artworkCache: inout AlbumArtworkCache,
        needsArtwork: (String) -> Bool
    ) -> MediaLibraryItem? {
        guard let assetURL = item.assetURL, !item.hasProtectedAsset else { return nil }
        guard seenIDs.insert(item.persistentID).inserted else { return nil }

        let location = TrackLocation.mediaLibrary(persistentID: item.persistentID, assetURL: assetURL.absoluteString)
        let duration = item.playbackDuration
        var metadata = TrackMetadata(
            duration: duration.isFinite && duration > 0 ? duration : 0,
            hasAudio: true,
            hasVideo: !item.mediaType.intersection(.anyVideo).isEmpty
        )
        metadata.title = cleaned(item.title)
        metadata.artist = cleaned(item.artist)
        metadata.album = cleaned(item.albumTitle)
        metadata.albumArtist = cleaned(item.albumArtist)
        metadata.genre = cleaned(item.genre)
        metadata.trackNumber = item.albumTrackNumber > 0 ? item.albumTrackNumber : nil
        if needsArtwork(location.stableID) {
            metadata.artworkData = artworkData(for: item, cache: &artworkCache)
        }

        return MediaLibraryItem(
            location: location,
            metadata: metadata,
            dateAdded: item.dateAdded
        )
    }

    private static func artworkData(for item: MPMediaItem, cache: inout AlbumArtworkCache) -> Data? {
        let albumID = item.albumPersistentID
        if albumID != 0 {
            if let data = cache.dataByAlbum[albumID] { return data }
            if cache.albumsWithoutArtwork.contains(albumID) { return nil }
        }

        var data: Data?
        if let artwork = item.artwork, let image = artwork.image(at: artworkSize) {
            data = image.jpegData(compressionQuality: artworkQuality)
        }

        if albumID != 0 {
            if let data {
                cache.dataByAlbum[albumID] = data
            } else {
                cache.albumsWithoutArtwork.insert(albumID)
            }
        }
        return data
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
