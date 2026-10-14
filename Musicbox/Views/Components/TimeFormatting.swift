import Foundation

extension TimeInterval {
    /// "3:07" for durations under an hour, "1:02:03" otherwise. Invalid or negative values -> "0:00".
    var mmss: String {
        guard isFinite, self > 0 else { return "0:00" }
        // Nearest second, like Apple Music: a 59.98 s song reads "1:00", not "0:59".
        let totalSeconds = Int(Swift.min(self, 359_999_999).rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Small text helpers shared by the library, album, artist, search and settings screens.
enum LibraryFormatting {
    /// "1 song", "12 songs".
    static func songCount(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }

    /// "1 album", "3 albums".
    static func albumCount(_ count: Int) -> String {
        count == 1 ? "1 album" : "\(count) albums"
    }

    /// "42 min", "1 hr 5 min", "2 hr".
    static func totalDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        let minutes = Swift.max(1, Int((Swift.min(seconds, 359_999_999) / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    /// "12 songs · 42 min" (duration omitted when unknown).
    static func songsAndDuration(count: Int, duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return songCount(count) }
        return "\(songCount(count)) · \(totalDuration(duration))"
    }
}
