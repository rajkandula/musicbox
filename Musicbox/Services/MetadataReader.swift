import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Tags and technical facts read from a media file.
struct TrackMetadata: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var trackNumber: Int?
    var duration: TimeInterval
    var hasAudio: Bool
    var hasVideo: Bool
    var artworkData: Data?
}

/// Reads tags, duration, track layout and artwork with AVFoundation's async loading API.
enum MetadataReader {
    /// Uses AVURLAsset async loading (load(.commonMetadata), load(.duration), load(.tracks)) plus
    /// ID3/iTunes metadata formats for track number, album artist, genre. Never throws; missing
    /// fields are nil. For videos with no embedded artwork, generate a frame thumbnail
    /// (AVAssetImageGenerator at ~10% of duration, max 600px) as artworkData.
    static func read(url: URL) async -> TrackMetadata {
        var metadata = TrackMetadata(duration: 0, hasAudio: false, hasVideo: false)

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        // Tracks decide whether the file is playable at all.
        guard let tracks = try? await asset.load(.tracks) else { return metadata }
        metadata.hasAudio = tracks.contains { $0.mediaType == .audio }
        metadata.hasVideo = tracks.contains { $0.mediaType == .video }
        guard metadata.hasAudio || metadata.hasVideo else { return metadata }

        if let duration = try? await asset.load(.duration) {
            metadata.duration = seconds(from: duration)
        }

        // Common (format-independent) metadata.
        let common = (try? await asset.load(.commonMetadata)) ?? []
        metadata.title = await firstString(for: [.commonIdentifierTitle], in: common)
        metadata.artist = await firstString(for: [.commonIdentifierArtist], in: common)
        metadata.album = await firstString(for: [.commonIdentifierAlbumName], in: common)
        metadata.artworkData = await firstImageData(for: [.commonIdentifierArtwork], in: common)

        // Format-specific metadata (ID3, iTunes, QuickTime) for the fields "common" does not cover.
        var formatItems: [AVMetadataItem] = []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let items = try? await asset.loadMetadata(for: format) {
                    formatItems.append(contentsOf: items)
                }
            }
        }

        if !formatItems.isEmpty {
            if metadata.title == nil {
                metadata.title = await firstString(
                    for: [.id3MetadataTitleDescription, .iTunesMetadataSongName, .quickTimeMetadataTitle],
                    in: formatItems
                )
            }
            if metadata.artist == nil {
                metadata.artist = await firstString(
                    for: [.id3MetadataLeadPerformer, .iTunesMetadataArtist,
                          .quickTimeMetadataArtist, .quickTimeUserDataArtist],
                    in: formatItems
                )
            }
            if metadata.album == nil {
                metadata.album = await firstString(
                    for: [.id3MetadataAlbumTitle, .iTunesMetadataAlbum,
                          .quickTimeMetadataAlbum, .quickTimeUserDataAlbum],
                    in: formatItems
                )
            }
            metadata.albumArtist = await firstString(
                for: [.iTunesMetadataAlbumArtist, .id3MetadataBand],
                in: formatItems
            )
            metadata.trackNumber = await trackNumber(in: formatItems)
            metadata.genre = await genre(in: formatItems)
            if metadata.artworkData == nil {
                metadata.artworkData = await firstImageData(
                    for: [.id3MetadataAttachedPicture, .iTunesMetadataCoverArt, .quickTimeMetadataArtwork],
                    in: formatItems
                )
            }
        }

        // AVFoundation plays FLAC but does not surface its Vorbis comments / PICTURE blocks.
        if url.pathExtension.lowercased() == "flac", metadata.needsTagFallback {
            applyFLACTags(from: url, to: &metadata)
        }

        if metadata.artworkData == nil, metadata.hasVideo {
            metadata.artworkData = await videoThumbnail(for: asset, duration: metadata.duration)
        }

        return metadata
    }

    // MARK: - Strings

    private static func firstString(
        for identifiers: [AVMetadataIdentifier],
        in items: [AVMetadataItem]
    ) async -> String? {
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let value = cleaned(try? await item.load(.stringValue)) {
                    return value
                }
            }
        }
        return nil
    }

    /// Trims whitespace / NUL padding, keeps the first of NUL-separated ID3v2.4 multi-values,
    /// and maps empty strings to nil.
    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let firstValue = value
            .split(separator: "\0", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let trimmed = firstValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Track number

    private static func trackNumber(in items: [AVMetadataItem]) async -> Int? {
        // ID3 TRCK: "3" or "3/12".
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataTrackNumber) {
            if let text = cleaned(try? await item.load(.stringValue)),
               let number = leadingInteger(in: text),
               isValidTrackNumber(number) {
                return number
            }
            if let number = try? await item.load(.numberValue), isValidTrackNumber(number.intValue) {
                return number.intValue
            }
        }

        // iTunes trkn: 8 bytes [0, 0, track(UInt16 BE), total(UInt16 BE), 0, 0].
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataTrackNumber) {
            if let data = try? await item.load(.dataValue), data.count >= 4 {
                let bytes = [UInt8](data.prefix(4))
                let number = Int(bytes[2]) << 8 | Int(bytes[3])
                if isValidTrackNumber(number) { return number }
            }
            if let number = try? await item.load(.numberValue), isValidTrackNumber(number.intValue) {
                return number.intValue
            }
            if let text = cleaned(try? await item.load(.stringValue)),
               let number = leadingInteger(in: text),
               isValidTrackNumber(number) {
                return number
            }
        }
        return nil
    }

    private static func leadingInteger(in text: String) -> Int? {
        let digits = text
            .trimmingCharacters(in: .whitespaces)
            .prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 6 else { return nil }
        return Int(digits)
    }

    private static func isValidTrackNumber(_ number: Int) -> Bool {
        number > 0 && number < 10_000
    }

    // MARK: - Genre

    private static func genre(in items: [AVMetadataItem]) async -> String? {
        // ID3 TCON: "Rock", "(17)", "(17)Rock", "17", "(RX)", "(CR)".
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .id3MetadataContentType) {
            if let raw = cleaned(try? await item.load(.stringValue)),
               let genre = parseID3Genre(raw) {
                return genre
            }
        }

        // iTunes free-text genre (©gen).
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataUserGenre) {
            if let text = cleaned(try? await item.load(.stringValue)) {
                return text
            }
        }

        // iTunes predefined genre (gnre): UInt16 BE = ID3v1 genre index + 1.
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataPredefinedGenre) {
            if let text = cleaned(try? await item.load(.stringValue)), Int(text) == nil {
                return text
            }
            if let data = try? await item.load(.dataValue), data.count >= 2 {
                let bytes = [UInt8](data.prefix(2))
                let code = Int(bytes[0]) << 8 | Int(bytes[1])
                if let name = id3v1GenreName(code - 1) { return name }
            }
            if let number = try? await item.load(.numberValue),
               let name = id3v1GenreName(number.intValue - 1) {
                return name
            }
        }

        // QuickTime.
        return await firstString(for: [.quickTimeMetadataGenre, .quickTimeUserDataGenre], in: items)
    }

    private static func parseID3Genre(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // "((" escapes a literal parenthesis.
        if text.hasPrefix("((") {
            return cleaned(String(text.dropFirst()))
        }

        // Strip leading "(n)" references, remembering the first one.
        var firstReference: String?
        while text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            let inner = String(text[text.index(after: text.startIndex)..<close])
            if firstReference == nil { firstReference = inner }
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }

        // A refinement text after the reference wins ("(17)Rock" -> "Rock").
        if !text.isEmpty {
            if let number = Int(text) { return id3v1GenreName(number) }
            return text
        }

        guard let reference = firstReference?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let number = Int(reference) { return id3v1GenreName(number) }
        switch reference.uppercased() {
        case "RX": return "Remix"
        case "CR": return "Cover"
        default: return cleaned(reference)
        }
    }

    private static func id3v1GenreName(_ index: Int) -> String? {
        guard index >= 0, index < id3v1Genres.count else { return nil }
        return id3v1Genres[index]
    }

    /// ID3v1 genre table including the Winamp extensions.
    private static let id3v1Genres: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop",
        "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap",
        "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
        "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance",
        "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock",
        "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
        "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi",
        "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
        // Winamp extensions
        "Folk", "Folk-Rock", "National Folk", "Swing", "Fast Fusion", "Bebop", "Latin", "Revival",
        "Celtic", "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock", "Symphonic Rock", "Slow Rock",
        "Big Band", "Chorus", "Easy Listening", "Acoustic", "Humour", "Speech", "Chanson", "Opera",
        "Chamber Music", "Sonata", "Symphony", "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam",
        "Club", "Tango", "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
        "Duet", "Punk Rock", "Drum Solo", "A Cappella", "Euro-House", "Dance Hall", "Goa", "Drum & Bass",
        "Club-House", "Hardcore", "Terror", "Indie", "BritPop", "Afro-Punk", "Polsk Punk", "Beat",
        "Christian Gangsta Rap", "Heavy Metal", "Black Metal", "Crossover", "Contemporary Christian", "Christian Rock", "Merengue", "Salsa",
        "Thrash Metal", "Anime", "J-Pop", "Synthpop", "Abstract", "Art Rock", "Baroque", "Bhangra",
        "Big Beat", "Breakbeat", "Chillout", "Downtempo", "Dub", "EBM", "Eclectic", "Electro",
        "Electroclash", "Emo", "Experimental", "Garage", "Global", "IDM", "Illbient", "Industro-Goth",
        "Jam Band", "Krautrock", "Leftfield", "Lounge", "Math Rock", "New Romantic", "Nu-Breakz", "Post-Punk",
        "Post-Rock", "Psytrance", "Shoegaze", "Space Rock", "Trop Rock", "World Music", "Neoclassical", "Audiobook",
        "Audio Theatre", "Neue Deutsche Welle", "Podcast", "Indie Rock", "G-Funk", "Dubstep", "Garage Rock", "Psybient",
    ]

    // MARK: - Artwork

    private static func firstImageData(
        for identifiers: [AVMetadataIdentifier],
        in items: [AVMetadataItem]
    ) async -> Data? {
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier) {
                if let data = try? await item.load(.dataValue),
                   let image = decodableImageData(from: data) {
                    return image
                }
            }
        }
        return nil
    }

    /// Returns `data` if ImageIO can decode it. Otherwise looks for an embedded JPEG/PNG
    /// signature near the start (some ID3 APIC payloads still carry their frame header).
    private static func decodableImageData(from data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        if isDecodableImage(data) { return data }

        let bytes = [UInt8](data.prefix(1024))
        let signatures: [[UInt8]] = [
            [0xFF, 0xD8, 0xFF],                     // JPEG
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A],   // PNG
        ]
        for signature in signatures where bytes.count > signature.count {
            for offset in 1...(bytes.count - signature.count) {
                if Array(bytes[offset..<(offset + signature.count)]) == signature {
                    let slice = Data(data.dropFirst(offset))
                    if isDecodableImage(slice) { return slice }
                    break
                }
            }
        }
        return nil
    }

    private static func isDecodableImage(_ data: Data) -> Bool {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [String: Any] else {
            return false
        }
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        return width > 0 && height > 0
    }

    /// Grabs a representative frame (~10% into the video, at least 1 s, clamped to the duration).
    private static func videoThumbnail(for asset: AVURLAsset, duration: TimeInterval) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)

        var candidates: [TimeInterval] = []
        if duration > 0 {
            candidates.append(min(max(duration * 0.1, 1), duration))
        }
        candidates.append(0)

        for seconds in candidates {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let result = try? await generator.image(at: time),
               let data = jpegData(from: result.image, quality: 0.8) {
                return data
            }
        }
        return nil
    }

    private static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output.length > 0 ? output as Data : nil
    }

    // MARK: - Time

    private static func seconds(from time: CMTime) -> TimeInterval {
        guard time.isValid, time.isNumeric, !time.isIndefinite else { return 0 }
        let value = time.seconds
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }

    // MARK: - FLAC

    /// Fills only the fields AVFoundation left empty.
    private static func applyFLACTags(from url: URL, to metadata: inout TrackMetadata) {
        guard let tags = FLACTagParser.read(url: url) else { return }
        if metadata.title == nil { metadata.title = cleaned(tags.title) }
        if metadata.artist == nil { metadata.artist = cleaned(tags.artist) }
        if metadata.album == nil { metadata.album = cleaned(tags.album) }
        if metadata.albumArtist == nil { metadata.albumArtist = cleaned(tags.albumArtist) }
        if metadata.genre == nil, let genre = cleaned(tags.genre) {
            metadata.genre = parseID3Genre(genre) ?? genre
        }
        if metadata.trackNumber == nil,
           let text = cleaned(tags.trackNumber),
           let number = leadingInteger(in: text),
           isValidTrackNumber(number) {
            metadata.trackNumber = number
        }
        if metadata.artworkData == nil, let picture = tags.picture {
            metadata.artworkData = decodableImageData(from: picture)
        }
    }
}

private extension TrackMetadata {
    var needsTagFallback: Bool {
        title == nil || artist == nil || album == nil || albumArtist == nil
            || genre == nil || trackNumber == nil || artworkData == nil
    }
}

/// Minimal reader for FLAC metadata blocks: VORBIS_COMMENT (tags) and PICTURE (cover art).
/// Reads only the metadata header region of the file, with strict bounds checks.
private enum FLACTagParser {
    struct Tags {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var genre: String?
        var trackNumber: String?
        var picture: Data?
    }

    private static let maxBlockLength = 16 * 1024 * 1024
    private static let maxBlocks = 128
    private static let vorbisCommentType: UInt8 = 4
    private static let pictureType: UInt8 = 6
    private static let frontCoverPictureType: UInt32 = 3

    static func read(url: URL) -> Tags? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard skipToFLACStream(handle) else { return nil }

        var tags = Tags()
        var pictureIsFrontCover = false
        var isLastBlock = false
        var blockCount = 0

        while !isLastBlock, blockCount < maxBlocks {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { break }
            let bytes = [UInt8](header)
            isLastBlock = bytes[0] & 0x80 != 0
            let type = bytes[0] & 0x7F
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            blockCount += 1

            let wantsBlock = (type == vorbisCommentType)
                || (type == pictureType && !pictureIsFrontCover)
            if wantsBlock, length <= maxBlockLength {
                guard let block = try? handle.read(upToCount: length), block.count == length else { break }
                if type == vorbisCommentType {
                    parseVorbisComment([UInt8](block), into: &tags)
                } else if let picture = parsePicture([UInt8](block)) {
                    let isFront = picture.type == frontCoverPictureType
                    if tags.picture == nil || isFront {
                        tags.picture = picture.data
                        pictureIsFrontCover = isFront
                    }
                }
            } else {
                guard let offset = try? handle.offset(),
                      (try? handle.seek(toOffset: offset + UInt64(length))) != nil else { break }
            }
        }
        return tags
    }

    /// Positions the handle right after the "fLaC" marker, skipping a leading ID3v2 tag if present.
    private static func skipToFLACStream(_ handle: FileHandle) -> Bool {
        guard let start = try? handle.read(upToCount: 10), start.count >= 4 else { return false }
        let bytes = [UInt8](start)
        if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {   // "fLaC"
            return (try? handle.seek(toOffset: 4)) != nil
        }
        // "ID3" + version(2) + flags(1) + syncsafe size(4)
        guard bytes.count == 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return false }
        let size = (Int(bytes[6] & 0x7F) << 21) | (Int(bytes[7] & 0x7F) << 14)
            | (Int(bytes[8] & 0x7F) << 7) | Int(bytes[9] & 0x7F)
        let hasFooter = bytes[5] & 0x10 != 0
        let streamStart = UInt64(10 + size + (hasFooter ? 10 : 0))
        guard (try? handle.seek(toOffset: streamStart)) != nil,
              let marker = try? handle.read(upToCount: 4),
              [UInt8](marker) == [0x66, 0x4C, 0x61, 0x43] else {
            return false
        }
        return true
    }

    private static func parseVorbisComment(_ block: [UInt8], into tags: inout Tags) {
        var reader = ByteReader(bytes: block)
        guard let vendorLength = reader.uint32LE(),
              reader.skip(Int(vendorLength)),
              let count = reader.uint32LE() else { return }

        for _ in 0..<min(Int(count), 10_000) {
            guard let length = reader.uint32LE(),
                  let entry = reader.bytes(Int(length)) else { break }
            guard let text = String(bytes: entry, encoding: .utf8),
                  let separator = text.firstIndex(of: "=") else { continue }
            let key = text[..<separator].uppercased()
            let value = String(text[text.index(after: separator)...])

            switch key {
            case "TITLE":
                if tags.title == nil { tags.title = value }
            case "ARTIST":
                if tags.artist == nil { tags.artist = value }
            case "ALBUM":
                if tags.album == nil { tags.album = value }
            case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST":
                if tags.albumArtist == nil { tags.albumArtist = value }
            case "GENRE":
                if tags.genre == nil { tags.genre = value }
            case "TRACKNUMBER", "TRACK":
                if tags.trackNumber == nil { tags.trackNumber = value }
            default:
                break
            }
        }
    }

    private static func parsePicture(_ block: [UInt8]) -> (type: UInt32, data: Data)? {
        var reader = ByteReader(bytes: block)
        guard let pictureType = reader.uint32BE(),
              let mimeLength = reader.uint32BE(), reader.skip(Int(mimeLength)),
              let descriptionLength = reader.uint32BE(), reader.skip(Int(descriptionLength)),
              reader.skip(16),                                   // width, height, depth, colors
              let dataLength = reader.uint32BE(),
              dataLength > 0,
              let data = reader.bytes(Int(dataLength)) else {
            return nil
        }
        return (pictureType, Data(data))
    }

    private struct ByteReader {
        private let storage: [UInt8]
        private var position = 0

        init(bytes: [UInt8]) {
            storage = bytes
        }

        private var remaining: Int { storage.count - position }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, count <= remaining else { return false }
            position += count
            return true
        }

        mutating func bytes(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, count <= remaining else { return nil }
            defer { position += count }
            return storage[position..<(position + count)]
        }

        mutating func uint32LE() -> UInt32? {
            guard let b = bytes(4) else { return nil }
            let i = b.startIndex
            return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }

        mutating func uint32BE() -> UInt32? {
            guard let b = bytes(4) else { return nil }
            let i = b.startIndex
            return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
        }
    }
}
