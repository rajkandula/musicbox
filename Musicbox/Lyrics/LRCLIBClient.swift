import Foundation

// MARK: - Query

/// What Musicbox sends to LRCLIB: only the song's title, artist, album and length (never audio).
/// Values are cleaned up so that tags taken from video rips and file names still find a match.
struct LRCLIBQuery: Sendable, Hashable {
    var title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval?
}

extension LRCLIBQuery {
    /// Builds a cleaned query from a Track:
    /// - drop "Unknown Artist"/"Unknown Album"; if artist unknown and title is "Artist - Title", split it
    /// - strip noise in ()/[] containing: official, video, audio, lyric(s), lyrics video, hd, 4k,
    ///   visualizer, mv, m/v, remaster(ed), explicit, clean; strip "feat./ft./featuring …" from title
    /// - underscores → spaces, collapse whitespace; duration nil when ≤ 0
    /// - also strips download leftovers: a video id ("[dQw4w9WgXcQ]", "Title-dQw4w9WgXcQ"),
    ///   bitrate/format tags ("(320 kbps)", "[MP3 128k]") and a converter site prefix
    ///   ("y2mate.com - Artist - Title")
    init(track: Track) {
        // Video ids may contain "_" and "-", so they are removed before underscores become spaces.
        let originalTitle = LRCLIBQueryCleaner.tidy(LRCLIBQueryCleaner.removingVideoIDs(from: track.title))
        var artist = LRCLIBQueryCleaner.meaningfulArtist(track.artist)
        if artist == nil, let albumArtist = track.albumArtist {
            artist = LRCLIBQueryCleaner.meaningfulArtist(albumArtist)
        }
        let album = LRCLIBQueryCleaner.meaningfulAlbum(track.album)

        var title = LRCLIBQueryCleaner.removingSitePrefix(from: LRCLIBQueryCleaner.strippingNoise(from: originalTitle))
        if let knownArtist = artist {
            // "Artist - Title" in the title tag while the artist tag is also set.
            title = LRCLIBQueryCleaner.removingArtistPrefix(knownArtist, from: title)
        } else {
            title = LRCLIBQueryCleaner.removingTrackNumberPrefix(from: title)
            if let split = LRCLIBQueryCleaner.splitArtistAndTitle(title) {
                artist = LRCLIBQueryCleaner.meaningfulArtist(split.artist)
                title = split.title
            }
        }

        title = LRCLIBQueryCleaner.tidy(LRCLIBQueryCleaner.strippingFeaturing(from: title))
        if title.isEmpty { title = originalTitle }
        if let current = artist {
            let cleaned = LRCLIBQueryCleaner.tidy(LRCLIBQueryCleaner.strippingFeaturing(from: current))
            artist = cleaned.isEmpty ? current : cleaned
        }

        self.title = title
        self.artist = artist
        self.album = album
        self.duration = track.duration.isFinite && track.duration > 0 ? track.duration : nil
    }
}

// MARK: - Errors

/// `offline`: the device has no usable connection. `unavailable`: the device is online but LRCLIB
/// can't be reached or is too slow (DNS/TLS/connect failures, timeouts). `disabled`: the lookup
/// was stopped because the user turned online lookup off while it ran.
enum LRCLIBError: Error { case offline, http(Int), decoding, unavailable, disabled }

// MARK: - Client

/// Tiny client for LRCLIB (https://lrclib.net), a free, open lyrics database that needs no API key.
struct LRCLIBClient: Sendable {
    static let shared = LRCLIBClient()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = LRCLIBClient.requestTimeout
        configuration.timeoutIntervalForResource = LRCLIBClient.requestTimeout * 2
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.httpAdditionalHeaders = [
            "User-Agent": LRCLIBClient.userAgent,
            "Accept": "application/json",
        ]
        session = URLSession(configuration: configuration)
    }

    /// 1) GET https://lrclib.net/api/get?track_name=&artist_name=&album_name=&duration= (only when
    ///    artist AND duration known; 404 → continue)
    /// 2) GET /api/search?track_name=&artist_name=  (artist known) → best match
    /// 3) GET /api/search?q=<artist title | title>          → best match
    /// 4) nothing matched and the title has bracketed / " - Suffix" parts: GET /api/search with
    ///    track_name=<core title> (+ artist_name when known) once more.
    /// Best match scoring: synced > plain; |duration diff| ≤ 2 s best, reject > 12 s when both
    /// known; normalized (case/diacritic/punctuation-insensitive) title equal > contains; artist match.
    /// Without an artist only the same title within 2 s of a known length counts (never a generic
    /// title such as "Intro" or a short single word such as "Home").
    /// Header "User-Agent: Musicbox/1.0 (free offline music player for iOS)". Timeout 12 s.
    ///
    /// Returns nil only when every request was answered and nothing matches: a request that failed
    /// (HTTP 429/5xx, timeout, unreadable reply) makes an empty result throw that failure instead,
    /// so it is retried rather than remembered as "not found". Throws `.offline` when the device has
    /// no connection, `.unavailable` when LRCLIB can't be reached or times out, `.disabled` as soon
    /// as `isAllowed` returns false (checked before every request).
    /// `isRejected`: lyrics the user marked as wrong for this song are never chosen.
    func lookup(
        _ query: LRCLIBQuery,
        isRejected: @escaping @Sendable (Lyrics) -> Bool = { _ in false },
        isAllowed: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Lyrics? {
        let title = LRCLIBQueryCleaner.tidy(query.title)
        guard !LRCLIBMatcher.normalize(title).isEmpty else { return nil }
        let artist = query.artist.map(LRCLIBQueryCleaner.tidy).flatMap { $0.isEmpty ? nil : $0 }
        let album = query.album.map(LRCLIBQueryCleaner.tidy).flatMap { $0.isEmpty ? nil : $0 }
        let duration = query.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let matcher = LRCLIBMatcher(title: title, artist: artist, duration: duration)

        var candidates: [LRCLIBCandidate] = []
        /// A request that got no usable answer. While there is one, "nothing matched" is not a
        /// real answer (the missing reply might have had the lyrics).
        var failure: LRCLIBError?

        func consider(_ records: [LRCLIBRecord], trusted: Bool) {
            for record in records {
                guard let candidate = matcher.evaluate(record, trusted: trusted),
                      !isRejected(candidate.lyrics) else { continue }
                candidates.append(candidate)
            }
        }

        /// A synced match for the very same song: nothing better can come from further requests.
        func hasSyncedCandidate() -> Bool {
            candidates.contains { $0.lyrics.isSynced && $0.isSameSong }
        }

        /// False once LRCLIB said "slow down": more requests right now only make it worse.
        func mayAskAgain() -> Bool {
            if case .http(429)? = failure { return false }
            return true
        }

        func checkAllowed() throws {
            guard isAllowed() else { throw LRCLIBError.disabled }
        }

        // 1) Exact signature lookup.
        if let artist, let duration {
            var items = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
            ]
            if let album { items.append(URLQueryItem(name: "album_name", value: album)) }
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
            do {
                try checkAllowed()
                // 404 (no record with this exact signature) is a normal answer: go on searching.
                if let data = try await fetch(path: "/api/get", queryItems: items) {
                    consider([try decodeRecord(data)], trusted: true)
                }
            } catch let error as LRCLIBError {
                switch error {
                case .offline, .disabled: throw error
                case .http, .decoding, .unavailable: failure = error
                }
            } catch is LRCLIBTimedOut {
                // A miss on /api/get makes LRCLIB ask external sources, which can be slow; the
                // searches below only read its own database and usually still answer quickly.
                failure = .unavailable
            }
        }

        /// Runs one search. Returns true when it timed out: the service is too slow right now, so
        /// no further 12 s wait is queued up.
        func runSearch(_ items: [URLQueryItem]) async throws -> Bool {
            do {
                try checkAllowed()
                consider(try await search(items), trusted: false)
            } catch let error as LRCLIBError {
                switch error {
                case .offline, .disabled: throw error
                case .http, .decoding, .unavailable: failure = error
                }
            } catch is LRCLIBTimedOut {
                failure = .unavailable
                return true
            }
            return false
        }

        // 2) Field search.
        var timedOut = false
        if let artist, !hasSyncedCandidate(), mayAskAgain() {
            let items = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
            ]
            timedOut = try await runSearch(items)
        }

        // 3) Free-text search.
        if !timedOut, !hasSyncedCandidate(), mayAskAgain() {
            let text = artist.map { "\($0) \(title)" } ?? title
            timedOut = try await runSearch([URLQueryItem(name: "q", value: text)])
        }

        // 4) LRCLIB matches every word of a query, so leftovers in the title (a bracketed tag,
        //    a " - Suffix") can hide a song it has: ask once more with just the core title.
        if !timedOut, candidates.isEmpty, mayAskAgain() {
            let core = LRCLIBQueryCleaner.tidy(LRCLIBMatcher.core(of: title))
            let normalizedCore = LRCLIBMatcher.normalize(core)
            if !normalizedCore.isEmpty, normalizedCore != LRCLIBMatcher.normalize(title) {
                var items = [URLQueryItem(name: "track_name", value: core)]
                if let artist { items.append(URLQueryItem(name: "artist_name", value: artist)) }
                _ = try await runSearch(items)
            }
        }

        if let best = LRCLIBMatcher.best(of: candidates) {
            return best.lyrics
        }
        if let failure {
            throw failure
        }
        return nil
    }

    // MARK: - Private

    private static let host = "lrclib.net"
    private static let userAgent = "Musicbox/1.0 (free offline music player for iOS)"
    private static let requestTimeout: TimeInterval = 12
    /// LRC for even very long songs is a few tens of KB; a search returns at most ~20 records.
    private static let maximumResponseBytes = 8 * 1024 * 1024

    private func search(_ items: [URLQueryItem]) async throws -> [LRCLIBRecord] {
        guard let data = try await fetch(path: "/api/search", queryItems: items) else { return [] }
        do {
            return try JSONDecoder().decode([LRCLIBLossy<LRCLIBRecord>].self, from: data).compactMap(\.value)
        } catch {
            throw LRCLIBError.decoding
        }
    }

    private func decodeRecord(_ data: Data) throws -> LRCLIBRecord {
        do {
            return try JSONDecoder().decode(LRCLIBRecord.self, from: data)
        } catch {
            throw LRCLIBError.decoding
        }
    }

    /// Returns the body for HTTP 200, nil for HTTP 404. Throws `LRCLIBTimedOut` when the request
    /// timed out, `CancellationError` when the calling task was cancelled, and `LRCLIBError` for
    /// everything else.
    private func fetch(path: String, queryItems: [URLQueryItem]) async throws -> Data? {
        try Task.checkCancellation()

        var components = URLComponents()
        components.scheme = "https"
        components.host = LRCLIBClient.host
        components.path = path
        components.queryItems = queryItems
        // URLComponents leaves "+" alone, but the server decodes it as a space ("C++", "Love + Hate").
        if let encoded = components.percentEncodedQuery {
            components.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw LRCLIBError.decoding }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: LRCLIBClient.requestTimeout)
        request.httpMethod = "GET"
        request.setValue(LRCLIBClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // Only a cancelled caller is a cancellation: URLSession can also report `.cancelled`
            // for its own reasons (e.g. the app was suspended), which must still end the lookup.
            if Task.isCancelled { throw CancellationError() }
            if error.code == .timedOut { throw LRCLIBTimedOut() }
            throw LRCLIBClient.isConnectivityFailure(error) ? LRCLIBError.offline : LRCLIBError.unavailable
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw LRCLIBError.unavailable
        }

        guard let http = response as? HTTPURLResponse else { throw LRCLIBError.decoding }
        switch http.statusCode {
        case 200:
            guard data.count <= LRCLIBClient.maximumResponseBytes else { throw LRCLIBError.decoding }
            return data
        case 404:
            return nil
        default:
            throw LRCLIBError.http(http.statusCode)
        }
    }
}

extension LRCLIBClient {
    /// The device itself has no usable connection. Anything else (the host can't be found or
    /// reached, TLS fails, the connection is reset) is LRCLIB's side: the device is online, so
    /// "no internet connection" would be wrong and waiting for the network to return never ends.
    fileprivate static func isConnectivityFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }
}

/// A request that ran into the 12 s timeout. Internal to the client: `lookup` turns it into
/// `LRCLIBError.unavailable` unless another request can still answer.
private struct LRCLIBTimedOut: Error {}

// MARK: - Decoding

/// One LRCLIB record. Every field is optional so that a single odd record never fails a response.
private struct LRCLIBRecord: Decodable, Sendable {
    let id: Int?
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    private enum CodingKeys: String, CodingKey {
        case id, trackName, artistName, albumName, duration, instrumental, plainLyrics, syncedLyrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeIfPresent(Int.self, forKey: .id)
        trackName = try? container.decodeIfPresent(String.self, forKey: .trackName)
        artistName = try? container.decodeIfPresent(String.self, forKey: .artistName)
        albumName = try? container.decodeIfPresent(String.self, forKey: .albumName)
        duration = try? container.decodeIfPresent(Double.self, forKey: .duration)
        instrumental = try? container.decodeIfPresent(Bool.self, forKey: .instrumental)
        plainLyrics = try? container.decodeIfPresent(String.self, forKey: .plainLyrics)
        syncedLyrics = try? container.decodeIfPresent(String.self, forKey: .syncedLyrics)
    }
}

/// Decodes an array element without failing the whole array.
private struct LRCLIBLossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

// MARK: - Matching

private struct LRCLIBCandidate: Sendable {
    let lyrics: Lyrics
    let score: Double
    /// Title equal (or equal apart from bracketed/suffix parts), or matched by LRCLIB's exact lookup.
    let isSameSong: Bool
}

/// Decides whether an LRCLIB record is the song being played, and how good a match it is.
private struct LRCLIBMatcher: Sendable {
    let title: String
    let artist: String?
    let duration: TimeInterval?

    private let normalizedTitle: String
    private let coreTitle: String
    private let normalizedArtist: String?
    private let artistParts: Set<String>
    /// A title shared by countless unrelated songs ("Intro", "Home"): meaningless without an artist.
    private let titleIsGeneric: Bool
    private let coreTitleIsGeneric: Bool

    init(title: String, artist: String?, duration: TimeInterval?) {
        self.title = title
        self.artist = artist
        self.duration = duration
        normalizedTitle = LRCLIBMatcher.normalize(LRCLIBQueryCleaner.strippingFeaturing(from: LRCLIBQueryCleaner.strippingNoise(from: title)))
        coreTitle = LRCLIBMatcher.normalize(LRCLIBMatcher.core(of: title))
        titleIsGeneric = LRCLIBMatcher.isGeneric(normalizedTitle)
        coreTitleIsGeneric = LRCLIBMatcher.isGeneric(coreTitle)
        if let artist {
            let normalized = LRCLIBMatcher.normalize(artist)
            normalizedArtist = normalized.isEmpty ? nil : normalized
            artistParts = LRCLIBMatcher.parts(of: artist)
        } else {
            normalizedArtist = nil
            artistParts = []
        }
    }

    /// `trusted` = the record came from the exact-signature endpoint (server already matched it).
    func evaluate(_ record: LRCLIBRecord, trusted: Bool) -> LRCLIBCandidate? {
        guard let lyrics = LRCLIBMatcher.lyrics(from: record) else { return nil }

        // Duration: reject > 12 s when both are known.
        var durationScore: Double = 0
        var durationDifference: TimeInterval?
        if let duration, let recordDuration = record.duration, recordDuration.isFinite, recordDuration > 0 {
            let difference = abs(recordDuration - duration)
            durationDifference = difference
            if difference > 12 { return nil }
            if difference <= 2 {
                durationScore = 30
            } else if difference <= 5 {
                durationScore = 15
            } else {
                durationScore = 3
            }
        }
        let durationIsClose = durationDifference.map { $0 <= 2 } ?? false

        // Title: equal > same core title > word-contained.
        let recordTitle = record.trackName ?? ""
        let recordNormalized = LRCLIBMatcher.normalize(
            LRCLIBQueryCleaner.strippingFeaturing(from: LRCLIBQueryCleaner.strippingNoise(from: recordTitle))
        )
        let recordCore = LRCLIBMatcher.normalize(LRCLIBMatcher.core(of: recordTitle))
        var titleScore: Double
        if !normalizedTitle.isEmpty, recordNormalized == normalizedTitle {
            titleScore = 40
        } else if !coreTitle.isEmpty, recordCore == coreTitle {
            titleScore = 32
        } else if LRCLIBMatcher.wordContains(recordNormalized, normalizedTitle)
                    || LRCLIBMatcher.wordContains(normalizedTitle, recordNormalized) {
            titleScore = 20
        } else if trusted {
            titleScore = 10
        } else {
            return nil
        }

        // Artist.
        var artistScore: Double = 0
        var artistMatches = false
        if let normalizedArtist {
            let recordArtist = LRCLIBMatcher.normalize(record.artistName ?? "")
            if recordArtist == normalizedArtist {
                artistScore = 30
                artistMatches = true
            } else if LRCLIBMatcher.wordContains(recordArtist, normalizedArtist)
                        || LRCLIBMatcher.wordContains(normalizedArtist, recordArtist) {
                artistScore = 22
                artistMatches = true
            } else if !artistParts.isDisjoint(with: LRCLIBMatcher.parts(of: record.artistName ?? "")) {
                artistScore = 15
                artistMatches = true
            } else if trusted {
                artistScore = 5
                artistMatches = true
            } else {
                // A different artist is only believable for the very same title and length (a cover
                // or a differently credited release), which carries the same words.
                guard titleScore >= 32, durationIsClose else { return nil }
                artistScore = -40
            }
        }

        // Without an artist (a title-only file name), the title and length are all there is to go
        // on, and the same title exists for many different songs: only the same title at (almost)
        // the same length is believable, and never a generic one.
        if normalizedArtist == nil && !trusted {
            // Matched on the core title ("Home" for "Home (Acoustic)"): judge the core.
            let isGeneric = titleScore >= 40 ? titleIsGeneric : coreTitleIsGeneric
            guard titleScore >= 32, durationIsClose, !isGeneric else { return nil }
        }

        // A title that merely contains the other needs another signal.
        if titleScore < 32 && !trusted {
            let hasArtistSignal = normalizedArtist != nil && artistMatches
            guard hasArtistSignal || durationIsClose else { return nil }
        }

        // The same song always beats a merely similar title; for the same song, synced beats plain.
        let isSameSong = titleScore >= 32 || trusted
        let sameSongTier: Double = isSameSong ? 2000 : 0
        let syncTier: Double = lyrics.isSynced ? 1000 : 500
        let trustBonus: Double = trusted ? 25 : 0
        return LRCLIBCandidate(
            lyrics: lyrics,
            score: sameSongTier + syncTier + titleScore + artistScore + durationScore + trustBonus,
            isSameSong: isSameSong
        )
    }

    /// Highest score wins; ties keep the earliest candidate (server relevance order).
    static func best(of candidates: [LRCLIBCandidate]) -> LRCLIBCandidate? {
        var best: LRCLIBCandidate?
        for candidate in candidates {
            if let current = best, candidate.score <= current.score { continue }
            best = candidate
        }
        return best
    }

    // MARK: Conversion

    private static let attribution = "Lyrics from LRCLIB"

    static func lyrics(from record: LRCLIBRecord) -> Lyrics? {
        let synced = record.syncedLyrics.flatMap(nonBlank)
        let plain = record.plainLyrics.flatMap(nonBlank)
        let instrumental = record.instrumental ?? false

        var lines: [LyricLine] = []
        if let synced, let parsed = LRCParser.parse(synced) {
            lines = parsed.lines
        }
        var plainText = plain.map { LRCParser.plainText(fromLRC: $0) }.flatMap(nonBlank)
        if plainText == nil, let synced {
            plainText = nonBlank(LRCParser.plainText(fromLRC: synced))
        }

        guard !lines.isEmpty || plainText != nil || instrumental else { return nil }
        return Lyrics(
            source: .online,
            lines: lines,
            plainText: plainText,
            isInstrumental: instrumental && lines.isEmpty,
            attribution: attribution
        )
    }

    private static func nonBlank(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: Normalization

    /// Case-, diacritic- and punctuation-insensitive form: "Don’t Stop (Me Now)!" → "dont stop me now".
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            switch scalar {
            case "'", "\u{2019}", "\u{2018}", "`", "\u{00B4}":
                continue
            case "&":
                if !output.isEmpty { output.append(" ") }
                output.append(contentsOf: "and".unicodeScalars)
                pendingSpace = true
            default:
                if CharacterSet.alphanumerics.contains(scalar) {
                    if pendingSpace, !output.isEmpty { output.append(" ") }
                    pendingSpace = false
                    output.append(scalar)
                } else {
                    pendingSpace = true
                }
            }
        }
        return String(output)
    }

    /// Title without any bracketed part and without a " - Suffix" ("Song - Remastered 2009").
    static func core(of title: String) -> String {
        var result = ""
        var depth = 0
        for character in title {
            switch character {
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}":
                depth = max(0, depth - 1)
            default:
                if depth == 0 { result.append(character) }
            }
        }
        for separator in [" - ", " – ", " — "] {
            if let range = result.range(of: separator) {
                let head = String(result[..<range.lowerBound])
                if !head.trimmingCharacters(in: .whitespaces).isEmpty { result = head }
            }
        }
        return result
    }

    private static let genericTitles: Set<String> = [
        "intro", "outro", "interlude", "prelude", "skit", "reprise", "untitled", "instrumental",
        "theme", "main theme", "overture", "finale", "introduction", "hidden track", "bonus track",
        "track", "audio", "song", "music", "demo", "new recording", "voice memo", "recording",
    ]

    /// Generic for a title-only match: a known placeholder title ("Intro", "Track 3"), a bare
    /// number, or a single word shorter than 5 letters ("Home", "Halo").
    static func isGeneric(_ normalized: String) -> Bool {
        guard !normalized.isEmpty else { return true }
        let words = normalized.split(separator: " ").map(String.init)
        let withoutNumbers = words.filter { !$0.allSatisfy(\.isNumber) }
        if withoutNumbers.isEmpty { return true }
        if genericTitles.contains(withoutNumbers.joined(separator: " ")) { return true }
        return words.count == 1 && normalized.count < 5
    }

    /// Whole-word containment of `needle` in `haystack` (both normalized).
    static func wordContains(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        return (" " + haystack + " ").contains(" " + needle + " ")
    }

    /// Individual artist names: "A feat. B & C" → {"a", "b", "c"}.
    static func parts(of artist: String) -> Set<String> {
        let normalized = normalize(artist)
        guard !normalized.isEmpty else { return [] }
        let separators: Set<String> = ["and", "feat", "ft", "featuring", "with", "x", "vs"]
        var parts: Set<String> = []
        var current: [String] = []
        for rawChunk in artist.split(whereSeparator: { $0 == "," || $0 == "/" || $0 == ";" }) {
            for word in normalize(String(rawChunk)).split(separator: " ").map(String.init) {
                if separators.contains(word) {
                    if !current.isEmpty { parts.insert(current.joined(separator: " ")) }
                    current = []
                } else {
                    current.append(word)
                }
            }
            if !current.isEmpty { parts.insert(current.joined(separator: " ")) }
            current = []
        }
        return parts
    }
}

// MARK: - Query cleaning

/// Pure string helpers used to build `LRCLIBQuery` and to compare LRCLIB records with it.
private enum LRCLIBQueryCleaner {
    /// Underscores → spaces, whitespace collapsed, trimmed.
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func meaningfulArtist(_ raw: String) -> String? {
        var artist = tidy(raw)
        // YouTube auto-generated channels: "Artist - Topic".
        if artist.lowercased().hasSuffix(" - topic") {
            artist = tidy(String(artist.dropLast(" - topic".count)))
        }
        let lowered = artist.lowercased()
        let placeholders: Set<String> = ["", "unknown artist", "unknown", "various artists", "various", "<unknown>"]
        // A converter site stamped into the tags ("y2mate.com") is not an artist.
        return placeholders.contains(lowered) || looksLikeDomain(artist) ? nil : artist
    }

    static func meaningfulAlbum(_ raw: String) -> String? {
        let album = tidy(raw)
        let placeholders: Set<String> = ["", "unknown album", "unknown", "<unknown>"]
        return placeholders.contains(album.lowercased()) ? nil : album
    }

    /// Removes a video id left by download tools: yt-dlp's "Title [dQw4w9WgXcQ]" (also in
    /// parentheses) and youtube-dl's "Title-dQw4w9WgXcQ". Works on the raw title, because ids can
    /// contain "_" (which `tidy` turns into a space) and "-".
    static func removingVideoIDs(from title: String) -> String {
        var result = ""
        var index = title.startIndex
        while index < title.endIndex {
            let character = title[index]
            if character == "(" || character == "[" {
                let closer: Character = character == "(" ? ")" : "]"
                if let close = title[title.index(after: index)...].firstIndex(of: closer),
                   isVideoID(title[title.index(after: index)..<close].trimmingCharacters(in: .whitespaces)) {
                    index = title.index(after: close)
                    continue
                }
            }
            result.append(character)
            index = title.index(after: index)
        }
        // "Title-dQw4w9WgXcQ" (the id itself may contain "-" too).
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        if trimmed.count > videoIDLength + 1 {
            let idStart = trimmed.index(trimmed.endIndex, offsetBy: -videoIDLength)
            let separator = trimmed[trimmed.index(before: idStart)]
            let head = trimmed[..<trimmed.index(before: idStart)].trimmingCharacters(in: .whitespaces)
            if separator == "-", !head.isEmpty, isVideoID(String(trimmed[idStart...])) {
                result = head
            }
        }
        let cleaned = result.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    /// Drops a leading converter/download site ("y2mate.com - Artist - Title").
    static func removingSitePrefix(from title: String) -> String {
        let parts = splitOnDashes(title)
        guard parts.count >= 2, looksLikeDomain(parts[0]) else { return title }
        let rest = tidy(parts[1...].joined(separator: " - "))
        return rest.isEmpty ? title : rest
    }

    /// Removes "(Official Video)", "[HD]", "(Remastered 2011)", "(feat. X)", "(320 kbps)" … groups.
    static func strippingNoise(from title: String) -> String {
        var result = ""
        var index = title.startIndex
        while index < title.endIndex {
            let character = title[index]
            if character == "(" || character == "[" {
                let closer: Character = character == "(" ? ")" : "]"
                if let close = title[title.index(after: index)...].firstIndex(of: closer) {
                    let inner = title[title.index(after: index)..<close]
                    if isNoise(inner) || isFeaturing(inner) {
                        index = title.index(after: close)
                        continue
                    }
                }
            }
            result.append(character)
            index = title.index(after: index)
        }
        let tidied = tidy(result)
        return tidied.isEmpty ? tidy(title) : tidied
    }

    /// Removes a trailing "feat. X" / "ft. X" / "featuring X" (and bracketed forms).
    static func strippingFeaturing(from text: String) -> String {
        let bracketsRemoved = strippingBracketedFeaturing(from: text)
        let words = bracketsRemoved.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > 1 else { return bracketsRemoved }
        for (position, word) in words.enumerated() where position > 0 {
            let lowered = word.lowercased()
            if lowered == "feat." || lowered == "feat" || lowered == "ft." || lowered == "featuring" {
                guard position + 1 < words.count else { break }
                return words[..<position].joined(separator: " ")
            }
        }
        return bracketsRemoved
    }

    /// "Artist - Title" (also "01 - Artist - Title") → (Artist, Title).
    static func splitArtistAndTitle(_ title: String) -> (artist: String, title: String)? {
        var parts = splitOnDashes(title)
        if parts.count >= 3, isTrackNumber(parts[0]) {
            parts.removeFirst()
        }
        guard parts.count >= 2 else { return nil }
        let artist = tidy(parts[0])
        let rest = tidy(parts[1...].joined(separator: " - "))
        guard !artist.isEmpty, !rest.isEmpty, !isTrackNumber(artist) else { return nil }
        return (artist, rest)
    }

    /// "01 - Title" / "01. Title" → "Title" (only used when the artist is unknown, i.e. a file name).
    static func removingTrackNumberPrefix(from title: String) -> String {
        let parts = splitOnDashes(title)
        if parts.count == 2, isTrackNumber(parts[0]) {
            return tidy(parts[1])
        }
        // "01. Title" / "01) Title"
        var digits = 0
        var index = title.startIndex
        while index < title.endIndex, title[index].isASCII, title[index].isNumber, digits < 4 {
            digits += 1
            index = title.index(after: index)
        }
        guard (1...3).contains(digits), index < title.endIndex, title[index] == "." || title[index] == ")" else {
            return title
        }
        let afterMarker = title.index(after: index)
        guard afterMarker < title.endIndex, title[afterMarker].isWhitespace else { return title }
        let rest = tidy(String(title[afterMarker...]))
        return rest.isEmpty ? title : rest
    }

    /// Drops "Artist - " from the start of the title when it repeats the (known) artist.
    static func removingArtistPrefix(_ artist: String, from title: String) -> String {
        let parts = splitOnDashes(title)
        guard parts.count >= 2 else { return title }
        let head = LRCLIBMatcher.normalize(parts[0])
        guard !head.isEmpty, head == LRCLIBMatcher.normalize(artist) else { return title }
        let rest = tidy(parts[1...].joined(separator: " - "))
        return rest.isEmpty ? title : rest
    }

    // MARK: Private

    private static let noiseWords: Set<String> = [
        "official", "video", "audio", "lyric", "lyrics", "hd", "hq", "4k", "1080p", "720p",
        "visualizer", "visualiser", "mv", "remaster", "remastered", "explicit", "clean",
        "kbps", "kbit",
    ]

    /// Words of a bitrate / file-format tag: "(320 kbps)", "[MP3 128k]", "(320K)".
    private static let formatWords: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "alac", "kbps", "kbit",
    ]

    private static func isNoise(_ inner: Substring) -> Bool {
        let lowered = inner.lowercased()
        if lowered.contains("m/v") { return true }
        let words = lowered.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        if words.contains(where: { noiseWords.contains($0) || isBitrate($0) }) { return true }
        return isFormatTag(words)
    }

    /// "320kbps", "128kbit".
    private static func isBitrate(_ word: String) -> Bool {
        for unit in ["kbps", "kbit"] where word.hasSuffix(unit) {
            let number = word.dropLast(unit.count)
            if !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        }
        return false
    }

    /// The whole group is a format tag: "(MP3)", "(320k)", "[MP3 320]". "(24K Gold)" is not.
    private static func isFormatTag(_ words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        var hasFormatWord = false
        for word in words {
            if formatWords.contains(word) {
                hasFormatWord = true
            } else if word.hasSuffix("k"), (3...4).contains(word.count),
                      word.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) {
                hasFormatWord = true                       // "128k", "320k"
            } else if !word.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return false
            }
        }
        return hasFormatWord
    }

    private static let videoIDLength = 11

    /// An 11-character YouTube-style id ([A-Za-z0-9_-]) that can't be a word: it has a digit, a
    /// "-" or "_", or a capital letter after the first character ("Nightingale" is not an id).
    private static func isVideoID(_ text: String) -> Bool {
        guard text.count == videoIDLength else { return false }
        var hasDigit = false
        var hasSymbol = false
        var hasInnerCapital = false
        var hasLowercase = false
        for (offset, character) in text.enumerated() {
            guard character.isASCII else { return false }
            if character.isNumber {
                hasDigit = true
            } else if character == "-" || character == "_" {
                hasSymbol = true
            } else if character.isUppercase {
                if offset > 0 { hasInnerCapital = true }
            } else if character.isLowercase {
                hasLowercase = true
            } else {
                return false
            }
        }
        return hasDigit || hasSymbol || (hasInnerCapital && hasLowercase)
    }

    private static let siteSuffixes: Set<String> = [
        "com", "net", "org", "to", "io", "cc", "co", "me", "is", "ws", "tv", "app", "info", "biz",
        "xyz", "site", "online", "top", "lol", "ch", "ru", "cx", "fm", "pro", "nu", "tube", "live",
    ]

    /// "y2mate.com", "ytmp3.cc", "SaveFrom.net" (no spaces, a common site suffix).
    private static func looksLikeDomain(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.contains(" ") else { return false }
        let labels = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let suffix = labels.last, siteSuffixes.contains(String(suffix)) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func isFeaturing(_ inner: Substring) -> Bool {
        let lowered = inner.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("feat.") || lowered.hasPrefix("feat ") || lowered.hasPrefix("ft.")
            || lowered.hasPrefix("ft ") || lowered.hasPrefix("featuring ")
    }

    private static func strippingBracketedFeaturing(from text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "(" || character == "[" {
                let closer: Character = character == "(" ? ")" : "]"
                if let close = text[text.index(after: index)...].firstIndex(of: closer),
                   isFeaturing(text[text.index(after: index)..<close]) {
                    index = text.index(after: close)
                    continue
                }
            }
            result.append(character)
            index = text.index(after: index)
        }
        let tidied = tidy(result)
        return tidied.isEmpty ? tidy(text) : tidied
    }

    /// Splits on spaced dashes (" - ", " – ", " — "); "Jay-Z" stays whole.
    private static func splitOnDashes(_ text: String) -> [String] {
        var normalized = text
        for dash in [" – ", " — ", " -- "] {
            normalized = normalized.replacingOccurrences(of: dash, with: " - ")
        }
        return normalized.components(separatedBy: " - ")
            .map { tidy($0) }
            .filter { !$0.isEmpty }
    }

    private static func isTrackNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return (1...3).contains(trimmed.count) && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
