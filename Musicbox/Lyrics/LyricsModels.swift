import Foundation

/// One line of time-synced lyrics.
struct LyricLine: Codable, Hashable, Identifiable, Sendable {
    let id: Int               // index in the lines array (0-based, stable)
    let time: TimeInterval    // start time in seconds (file time, BEFORE user offset)
    let text: String          // "" = instrumental gap / pause
}

/// Where a set of lyrics came from.
enum LyricsSource: String, Codable, Sendable {
    case imported, sidecarFile, embedded, online
}

/// Lyrics for one track, either time-synced (`lines` non-empty) or plain text only.
struct Lyrics: Codable, Hashable, Sendable {
    var source: LyricsSource
    var lines: [LyricLine]        // sorted by time; non-empty ⇒ synced
    var plainText: String?        // unsynced text (always filled when known, even if synced lines exist)
    var isInstrumental: Bool
    var attribution: String       // shown under lyrics: "Lyrics from LRCLIB", "From “Song.lrc”", "Embedded in file", "Imported"

    var isSynced: Bool { !lines.isEmpty }
}

/// Loading state of the lyrics for one track.
enum LyricsState: Equatable, Sendable {
    case idle
    case loading
    case loaded(Lyrics)
    case notFound
    case offlineDisabled          // nothing local, online lookup turned off
    case failed(String)           // retryable (e.g. no internet)
}
