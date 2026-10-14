import Foundation

/// Whether a file is played as plain audio or is a video container (still played as audio by default).
enum MediaKind: String, Codable, Hashable, Sendable {
    case audio, video
}

/// Where a track physically lives. Used to build a stable ID and to resolve a playable URL.
enum TrackLocation: Codable, Hashable, Sendable {
    /// Inside the app's own Documents folder (visible in Files app as On My iPhone › Musicbox).
    case documents(relativePath: String)
    /// Inside a user-linked folder (security-scoped bookmark), e.g. Files › Downloads or iCloud Drive.
    case folder(sourceID: UUID, relativePath: String)
    /// A DRM-free item from the device Music library (songs synced from a computer).
    case mediaLibrary(persistentID: UInt64, assetURL: String)

    /// Stable identifier string:
    ///   documents  -> "doc:" + relativePath
    ///   folder     -> "fld:" + sourceID.uuidString + ":" + relativePath
    ///   mediaLib   -> "mpl:" + String(persistentID)
    var stableID: String {
        switch self {
        case .documents(let relativePath):
            return "doc:" + relativePath
        case .folder(let sourceID, let relativePath):
            return "fld:" + sourceID.uuidString + ":" + relativePath
        case .mediaLibrary(let persistentID, _):
            return "mpl:" + String(persistentID)
        }
    }
}

// Explicit coding keeps the on-disk format stable and stores the 64-bit persistent ID as a string,
// so it round-trips exactly no matter how the JSON number would be parsed.
extension TrackLocation {
    private enum StorageKeys: String, CodingKey {
        case kind, relativePath, sourceID, persistentID, assetURL
    }

    private enum StorageKind: String, Codable {
        case documents, folder, mediaLibrary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StorageKeys.self)
        switch try container.decode(StorageKind.self, forKey: .kind) {
        case .documents:
            self = .documents(relativePath: try container.decode(String.self, forKey: .relativePath))
        case .folder:
            self = .folder(
                sourceID: try container.decode(UUID.self, forKey: .sourceID),
                relativePath: try container.decode(String.self, forKey: .relativePath)
            )
        case .mediaLibrary:
            let persistentID: UInt64
            if let text = try? container.decode(String.self, forKey: .persistentID), let value = UInt64(text) {
                persistentID = value
            } else {
                persistentID = try container.decode(UInt64.self, forKey: .persistentID)
            }
            self = .mediaLibrary(
                persistentID: persistentID,
                assetURL: try container.decode(String.self, forKey: .assetURL)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StorageKeys.self)
        switch self {
        case .documents(let relativePath):
            try container.encode(StorageKind.documents, forKey: .kind)
            try container.encode(relativePath, forKey: .relativePath)
        case .folder(let sourceID, let relativePath):
            try container.encode(StorageKind.folder, forKey: .kind)
            try container.encode(sourceID, forKey: .sourceID)
            try container.encode(relativePath, forKey: .relativePath)
        case .mediaLibrary(let persistentID, let assetURL):
            try container.encode(StorageKind.mediaLibrary, forKey: .kind)
            try container.encode(String(persistentID), forKey: .persistentID)
            try container.encode(assetURL, forKey: .assetURL)
        }
    }
}

struct Track: Identifiable, Codable, Hashable, Sendable {
    let id: String                 // == location.stableID
    var location: TrackLocation
    var title: String              // falls back to file name without extension
    var artist: String             // falls back to "Unknown Artist"
    var album: String              // falls back to "Unknown Album"
    var albumArtist: String?
    var genre: String?
    var trackNumber: Int?
    var duration: TimeInterval     // seconds; 0 if unknown
    var kind: MediaKind
    var fileExtension: String      // lowercased, no dot ("mp3", "mp4"...)
    var fileSize: Int64
    var fileModificationDate: Date?
    var dateAdded: Date
    var hasArtwork: Bool
    // user data (must survive rescans)
    var isFavorite: Bool
    var playCount: Int
    var lastPlayedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, location, title, artist, album, albumArtist, genre, trackNumber, duration, kind
        case fileExtension, fileSize, fileModificationDate, dateAdded, hasArtwork
        case isFavorite, playCount, lastPlayedAt
    }

    var isVideo: Bool { kind == .video }

    var displayArtist: String { artist }

    /// "Artist · Album", leaving out unknown parts.
    var subtitle: String {
        let knownArtist = Track.isMeaningful(artist, placeholder: Track.unknownArtistPlaceholder)
        let knownAlbum = Track.isMeaningful(album, placeholder: Track.unknownAlbumPlaceholder)
        switch (knownArtist, knownAlbum) {
        case (true, true):
            return artist + " · " + album
        case (true, false):
            return artist
        case (false, true):
            return album
        case (false, false):
            return artist.isEmpty ? Track.unknownArtistPlaceholder : artist
        }
    }

    private static let unknownArtistPlaceholder = "Unknown Artist"
    private static let unknownAlbumPlaceholder = "Unknown Album"

    private static func isMeaningful(_ value: String, placeholder: String) -> Bool {
        !value.isEmpty && value != placeholder
    }
}

// Tolerant decoding: a field added or dropped in a future version must never wipe the library
// (and with it favourites and play counts). Only `id` and `location` are required.
extension Track {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let location = try container.decode(TrackLocation.self, forKey: .location)
        let storedID = try container.decodeIfPresent(String.self, forKey: .id)
        let fileExtension = try container.decodeIfPresent(String.self, forKey: .fileExtension) ?? ""

        self.id = storedID ?? location.stableID
        self.location = location
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? Track.fallbackTitle(for: location)
        self.artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        self.album = try container.decodeIfPresent(String.self, forKey: .album) ?? "Unknown Album"
        self.albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        self.genre = try container.decodeIfPresent(String.self, forKey: .genre)
        self.trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        let duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        self.duration = duration.isFinite && duration > 0 ? duration : 0
        let decodedKind: MediaKind? = try? container.decodeIfPresent(MediaKind.self, forKey: .kind)
        self.kind = decodedKind ?? .audio
        self.fileExtension = fileExtension.lowercased()
        self.fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        self.fileModificationDate = try container.decodeIfPresent(Date.self, forKey: .fileModificationDate)
        self.dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        self.hasArtwork = try container.decodeIfPresent(Bool.self, forKey: .hasArtwork) ?? false
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        let playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        self.playCount = max(0, playCount)
        self.lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
    }

    private static func fallbackTitle(for location: TrackLocation) -> String {
        let path: String
        switch location {
        case .documents(let relativePath), .folder(_, let relativePath):
            path = relativePath
        case .mediaLibrary:
            return "Unknown Title"
        }
        let fileName = path.split(separator: "/").last.map(String.init) ?? path
        let title = (fileName as NSString).deletingPathExtension
        return title.isEmpty ? "Untitled" : title
    }
}
