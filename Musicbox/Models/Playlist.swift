import Foundation

struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var trackIDs: [String]         // ordered; duplicates NOT allowed
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, trackIDs, createdAt, updatedAt
    }
}

// Tolerant decoding so a partially damaged or older playlists file still loads.
extension Playlist {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Playlist" : name

        var seen = Set<String>()
        let storedIDs = try container.decodeIfPresent([String].self, forKey: .trackIDs) ?? []
        self.trackIDs = storedIDs.filter { seen.insert($0).inserted }

        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.createdAt = createdAt
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}
