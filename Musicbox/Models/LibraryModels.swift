import Foundation

// MARK: - Linked folder

struct LinkedFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String        // last path component at link time
    var bookmarkData: Data
    var addedAt: Date
    var lastScanAt: Date?
    var trackCount: Int            // updated after each scan
    var isAvailable: Bool          // false if bookmark failed to resolve on last scan
    /// Where the folder was last seen (set when linked, refreshed whenever the bookmark resolves).
    /// Lets a folder that is offline (drive unplugged) still be recognised when it is linked again.
    var canonicalPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, displayName, bookmarkData, addedAt, lastScanAt, trackCount, isAvailable, canonicalPath
    }
}

extension LinkedFolder {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
        let name = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.displayName = name.isEmpty ? "Folder" : name
        self.addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        self.lastScanAt = try container.decodeIfPresent(Date.self, forKey: .lastScanAt)
        let trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        self.trackCount = max(0, trackCount)
        self.isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        let path = try? container.decodeIfPresent(String.self, forKey: .canonicalPath)
        self.canonicalPath = path.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Settings

struct AppSettings: Codable, Hashable, Sendable {
    var includeMusicLibrary: Bool = false     // opt-in: needs Apple Music permission
    var includeVideos: Bool = true            // include mp4/m4v/mov/3gp files in library
    var minimumDuration: TimeInterval = 0     // skip clips shorter than this (0 = keep all)
    var songSort: SongSort = .title

    init() {}

    enum CodingKeys: String, CodingKey {
        case includeMusicLibrary, includeVideos, minimumDuration, songSort
    }
}

// Every field falls back to its default, so adding settings later never resets the others.
extension AppSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .includeMusicLibrary) {
            includeMusicLibrary = value
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .includeVideos) {
            includeVideos = value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: .minimumDuration),
           value.isFinite {
            minimumDuration = max(0, value)
        }
        if let value = try? container.decodeIfPresent(SongSort.self, forKey: .songSort) {
            songSort = value
        }
    }
}

enum SongSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case title, artist, album, dateAdded, duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .dateAdded: return "Recently Added"
        case .duration: return "Duration"
        }
    }
}

// MARK: - Browsing groups

struct AlbumGroup: Identifiable, Hashable, Sendable {
    let id: String            // lowercased "album|albumArtistOrArtist"
    let title: String
    let artist: String
    let tracks: [Track]       // sorted by trackNumber then title

    /// First track with artwork, else the first track.
    var artworkTrackID: String? {
        tracks.first(where: { $0.hasArtwork })?.id ?? tracks.first?.id
    }

    var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }
}

struct ArtistGroup: Identifiable, Hashable, Sendable {
    let id: String            // lowercased artist name
    let name: String
    let tracks: [Track]       // sorted by album then trackNumber then title
    let albumCount: Int

    /// First track with artwork, else the first track.
    var artworkTrackID: String? {
        tracks.first(where: { $0.hasArtwork })?.id ?? tracks.first?.id
    }
}
