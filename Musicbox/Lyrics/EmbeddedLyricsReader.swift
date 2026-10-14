import Foundation
import AVFoundation

/// Reads lyrics stored inside a media file: ID3 `SYLT` (synced) / `USLT` (unsynced) in MP3,
/// iTunes `©lyr` in M4A/MP4, QuickTime user-data lyrics, and `AVAsset.lyrics`.
enum EmbeddedLyricsReader {
    /// Off the main actor. AVURLAsset: try `load(.lyrics)`; then for each available metadata
    /// format, items with identifiers .id3MetadataSynchronizedLyric (SYLT → parseSYLT on dataValue),
    /// .id3MetadataUnsynchronizedLyric (USLT), .iTunesMetadataLyrics (©lyr), quickTime lyrics.
    /// LRC-formatted text → synced via LRCParser. Returns nil when there are no lyrics.
    /// attribution: "Embedded in file"; source: .embedded.
    static func read(url: URL) async -> Lyrics? {
        let asset = AVURLAsset(url: url)
        var texts: [String] = []
        var syncedPayloads: [Data] = []

        func addText(_ raw: String?) {
            guard let text = cleanedText(raw), !texts.contains(text) else { return }
            texts.append(text)
        }

        // The asset's own pick is the one suited to the current locale, so it goes first.
        addText(try? await asset.load(.lyrics))
        if Task.isCancelled { return nil }

        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
            guard let items = try? await asset.loadMetadata(for: format) else { continue }
            for item in items {
                if Task.isCancelled { return nil }
                guard let kind = lyricKind(of: item, description: await userTextDescription(of: item)) else { continue }
                let data = try? await item.load(.dataValue)
                let string = try? await item.load(.stringValue)
                switch kind {
                case .synchronized:
                    if let data, !data.isEmpty { syncedPayloads.append(data) }
                    // Some containers surface the SYLT text as a string; keep it as plain/LRC text.
                    addText(string)
                case .unsynchronized:
                    if let string, cleanedText(string) != nil {
                        addText(string)
                    } else if let data {
                        addText(unsynchronizedText(fromUSLT: data))
                    }
                }
            }
        }
        if Task.isCancelled { return nil }

        // 1) SYLT: real synced lyrics.
        for payload in syncedPayloads {
            if let lines = LRCParser.parseSYLT(payload) {
                return Lyrics(
                    source: .embedded,
                    lines: lines,
                    plainText: plainText(from: lines),
                    isInstrumental: false,
                    attribution: attribution
                )
            }
        }

        // 2) Text tags that are actually LRC (common with taggers that paste .lrc into USLT/©lyr).
        for text in texts where LRCParser.looksLikeLRC(text) {
            if let result = LRCParser.parse(text) {
                let plain = LRCParser.plainText(fromLRC: text)
                return Lyrics(
                    source: .embedded,
                    lines: result.lines,
                    plainText: plain.isEmpty ? plainText(from: result.lines) : plain,
                    isInstrumental: false,
                    attribution: attribution
                )
            }
        }

        // 3) Plain, unsynced text.
        guard let text = texts.first else { return nil }
        return Lyrics(
            source: .embedded,
            lines: [],
            plainText: text,
            isInstrumental: isInstrumentalMarker(text),
            attribution: attribution
        )
    }

    // MARK: - Private

    private static let attribution = "Embedded in file"

    private enum LyricKind {
        case synchronized, unsynchronized
    }

    /// The description of an ID3 user-defined text frame (TXXX / v2.2 TXX); nil for other items.
    private static func userTextDescription(of item: AVMetadataItem) async -> String? {
        guard let raw = item.identifier?.rawValue.lowercased(), raw == "id3/txxx" || raw == "id3/txx" else {
            return nil
        }
        let attributes = try? await item.load(.extraAttributes)
        return attributes?[.info] as? String
    }

    /// Identifies lyric items across ID3 (v2.2–2.4), iTunes, QuickTime user data and metadata key
    /// spaces. `description` is the TXXX description (see `userTextDescription(of:)`).
    private static func lyricKind(of item: AVMetadataItem, description: String?) -> LyricKind? {
        guard let identifier = item.identifier else { return nil }
        switch identifier {
        case .id3MetadataSynchronizedLyric:
            return .synchronized
        case .id3MetadataUnsynchronizedLyric, .iTunesMetadataLyrics:
            return .unsynchronized
        default:
            break
        }
        let raw = identifier.rawValue.lowercased()
        if raw == "id3/slt" { return .synchronized }                              // ID3v2.2 SYLT
        if raw == "id3/ult" { return .unsynchronized }                            // ID3v2.2 USLT
        if raw.hasSuffix("/%a9lyr") || raw.hasSuffix("/\u{00A9}lyr") {            // udta/©lyr, itsk/©lyr
            return .unsynchronized
        }
        if raw.hasPrefix("mdta/"), raw.hasSuffix(".lyrics") || raw.hasSuffix("/lyrics") {
            return .unsynchronized                                                // e.g. mdta/com.apple.quicktime.lyrics
        }
        // iTunes freeform atoms such as "----:com.apple.iTunes:LYRICS" (itlk/…lyrics).
        if raw.hasPrefix("itlk/"), raw.contains("lyric") {
            return .unsynchronized
        }
        // ID3 user-defined text frames: ffmpeg, yt-dlp and several taggers store lyrics as
        // TXXX:LYRICS, TXXX:UNSYNCEDLYRICS, TXXX:SYNCEDLYRICS, TXXX:lyrics-eng — or, from ffmpeg's
        // `-metadata lyrics=…`, TXXX:USLT — instead of a real USLT frame. SYNCEDLYRICS is LRC
        // text, which the LRC check below turns into synced lines.
        if raw == "id3/txxx" || raw == "id3/txx" {
            let label = description?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if label.contains("lyric") || label == "uslt" || label == "sylt" {
                return .unsynchronized
            }
        }
        return nil
    }

    /// Normalises newlines, drops BOM/NUL padding, trims. Nil when nothing readable is left.
    private static func cleanedText(_ raw: String?) -> String? {
        guard var text = raw else { return nil }
        text = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{0}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var collapsed: [String] = []
        for line in lines {
            if line.isEmpty, collapsed.last?.isEmpty ?? true { continue }   // no leading / repeated blanks
            collapsed.append(line)
        }
        while collapsed.last?.isEmpty == true { collapsed.removeLast() }
        let result = collapsed.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    /// Decodes a raw ID3 USLT payload (encoding, language, descriptor, text) when AVFoundation only
    /// hands over bytes. Tolerates a missing encoding byte / language. Nil when nothing readable.
    private static func unsynchronizedText(fromUSLT data: Data) -> String? {
        var bytes = [UInt8](data)
        if bytes.count >= 10, bytes[0] == 0x55, bytes[1] == 0x53, bytes[2] == 0x4C, bytes[3] == 0x54 {
            bytes.removeFirst(10)                                                  // "USLT" frame header
        }
        guard bytes.count >= 2 else { return nil }
        guard bytes[0] <= 3 else {
            return cleanedText(decode(bytes[...], encoding: 3))                   // bare text, no header
        }
        guard bytes.count >= 5 else { return nil }
        let encoding = bytes[0]
        let body = bytes[4...]                                                     // skip encoding + language
        let isUTF16 = encoding == 1 || encoding == 2
        // Skip the descriptor up to its terminator; the rest is the lyric text.
        var index = body.startIndex
        var textStart: Int?
        while index < body.endIndex {
            if isUTF16 {
                guard index + 1 < body.endIndex else { break }
                if body[index] == 0 && body[index + 1] == 0 { textStart = index + 2; break }
                index += 2
            } else {
                if body[index] == 0 { textStart = index + 1; break }
                index += 1
            }
        }
        guard let start = textStart, start < body.endIndex else { return nil }
        return cleanedText(decode(body[start...], encoding: encoding))
    }

    private static func decode(_ bytes: ArraySlice<UInt8>, encoding: UInt8) -> String? {
        switch encoding {
        case 1:
            if bytes.count >= 2, bytes[bytes.startIndex] == 0xFE, bytes[bytes.startIndex + 1] == 0xFF {
                return String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian)
            }
            if bytes.count >= 2, bytes[bytes.startIndex] == 0xFF, bytes[bytes.startIndex + 1] == 0xFE {
                return String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian)
            }
            return String(bytes: bytes, encoding: .utf16LittleEndian)
        case 2:
            return String(bytes: bytes, encoding: .utf16BigEndian)
        case 3:
            return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
        default:
            if bytes.contains(where: { $0 >= 0x80 }), let utf8 = String(bytes: bytes, encoding: .utf8) {
                return utf8
            }
            return String(bytes: bytes, encoding: .isoLatin1)
        }
    }

    /// Plain text for synced lines: one line each, gaps as a single blank line.
    private static func plainText(from lines: [LyricLine]) -> String {
        var output: [String] = []
        for line in lines {
            if line.text.isEmpty {
                if let last = output.last, !last.isEmpty { output.append("") }
            } else {
                output.append(line.text)
            }
        }
        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }

    /// Tags like "Instrumental", "[Instrumental]" or "♪ Instrumental ♪".
    private static func isInstrumentalMarker(_ text: String) -> Bool {
        let core = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]()♪♫*-_. ").union(.whitespacesAndNewlines))
        return core == "instrumental"
    }
}
