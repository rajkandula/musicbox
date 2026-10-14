import Foundation

/// Small, pure text helpers shared by the player and playlist screens (module D2).
enum PlayerUIText {
    /// "Artist · Album", falling back to the artist name when the subtitle is empty.
    static func subtitle(for track: Track) -> String {
        let subtitle = track.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return subtitle.isEmpty ? track.displayArtist : subtitle
    }

    /// "1 song", "12 songs".
    static func songCount(_ count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }

    /// "42 sec", "12 min", "1 hr 5 min", "2 hr".
    static func totalDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        let total = Int(min(seconds, 359_999_999).rounded())
        if total < 60 { return "\(total) sec" }
        let minutes = Int((Double(total) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    /// "12 songs · 42 min" (duration omitted when unknown).
    static func summary(count: Int, duration: TimeInterval) -> String {
        guard count > 0 else { return "No songs" }
        guard duration.isFinite, duration > 0 else { return songCount(count) }
        return "\(songCount(count)) · \(totalDuration(duration))"
    }

    /// "0.75×", "1×", "1.5×".
    static func speedLabel(_ rate: Float) -> String {
        String(format: "%g×", Double(rate))
    }

    static func sameRate(_ lhs: Float, _ rhs: Float) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    /// Trimmed playlist name, or nil when the user typed only whitespace.
    static func cleanedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `base`, or "base 2", "base 3"… so a default name never duplicates an existing playlist.
    static func uniqueName(_ base: String, existing: [Playlist]) -> String {
        let taken = Set(existing.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) {
            number += 1
        }
        return "\(base) \(number)"
    }
}
