# Musicbox — Live Lyrics Contract (v1)

Adds **live, time-synced lyrics** (karaoke-style: current line highlighted, auto-scrolling, tap a
line to jump there) to Now Playing. Free, no account, no subscription. Read `SPEC.md` first for the
app architecture; this file is the binding contract for the lyrics feature. Same rules: exact names
and signatures, private helpers allowed, never re-declare another module's types.

## Where lyrics come from (resolution order)

1. **Imported** — the user picked a `.lrc`/`.txt` file for this song ("Import .lrc File…"). Always wins.
2. **Sidecar file** — a `.lrc` file with the same base name next to the audio file
   (`Song.mp3` → `Song.lrc`, case-insensitive extension match, same folder). Works for `.documents`
   and `.folder` locations (linked folders are already security-scope-accessible via
   `library.url(for:)` → `deletingPathExtension()`). Not for `.mediaLibrary`. A sidecar that is
   only in iCloud Drive (hidden `.Song.lrc.icloud` placeholder, or an item whose
   `ubiquitousItemDownloadingStatus` is `.notDownloaded`) gets `startDownloadingUbiquitousItem`
   and is waited for up to ~6 s (polled every 0.5 s); if it hasn't arrived, resolution goes on
   without it and the saved answer carries a "pending" fingerprint, so the next load after the
   download re-resolves. Sidecars are read through `NSFileCoordinator`.
3. **Embedded** — lyrics inside the media file: ID3 `SYLT` (synced) / `USLT` (unsynced) in MP3,
   iTunes `©lyr` in M4A/MP4, `AVAsset.lyrics`. If embedded *text* is LRC-formatted (has
   `[mm:ss.xx]` stamps) it is parsed as synced.
4. **Online (LRCLIB)** — only when `onlineLookupEnabled` (default **false**: off for new installs; a saved choice is kept). Free open database,
   no API key. Only title/artist/album/duration are sent — never audio. If local sources gave only
   *unsynced* text, still try online for a *synced* version and prefer it; otherwise keep local.
   Turning the setting off also stops lookups already running (checked before every request; a
   reply that arrives after it was turned off is discarded). Lyrics the user marked as
   **Wrong Lyrics** for a song are never chosen for that song again.
5. Otherwise → `.notFound` (or `.offlineDisabled` if online is off and nothing local exists).

## Files (all NEW — do not edit existing files in the Core phase)

| Owner | Files |
|---|---|
| **L1 – parsing & embedded** | `Musicbox/Lyrics/LyricsModels.swift`, `Musicbox/Lyrics/LRCParser.swift`, `Musicbox/Lyrics/EmbeddedLyricsReader.swift` |
| **L2 – store & online** | `Musicbox/Lyrics/LRCLIBClient.swift`, `Musicbox/Lyrics/LyricsStore.swift` |
| **L3 – UI** | `Musicbox/Views/Player/LyricsView.swift` (+ private helpers in the same file) |

## L1 — Models (`Musicbox/Lyrics/LyricsModels.swift`)

```swift
import Foundation

struct LyricLine: Codable, Hashable, Identifiable, Sendable {
    let id: Int               // index in the lines array (0-based, stable)
    let time: TimeInterval    // start time in seconds (file time, BEFORE user offset)
    let text: String          // "" = instrumental gap / pause
}

enum LyricsSource: String, Codable, Sendable {
    case imported, sidecarFile, embedded, online
}

struct Lyrics: Codable, Hashable, Sendable {
    var source: LyricsSource
    var lines: [LyricLine]        // sorted by time; non-empty ⇒ synced
    var plainText: String?        // unsynced text (always filled when known, even if synced lines exist)
    var isInstrumental: Bool
    var attribution: String       // shown under lyrics: "Lyrics from LRCLIB", "From “Song.lrc”", "Embedded in file", "Imported"
    var isSynced: Bool { get }    // !lines.isEmpty
}

enum LyricsState: Equatable, Sendable {
    case idle
    case loading
    case loaded(Lyrics)
    case notFound
    case offlineDisabled          // nothing local, online lookup turned off
    case failed(String)           // retryable (e.g. no internet)
}
```

## L1 — `LRCParser` (`Musicbox/Lyrics/LRCParser.swift`)

```swift
enum LRCParser {
    struct Result: Sendable { var lines: [LyricLine]; var offset: TimeInterval; var title: String?; var artist: String? }
    /// Parses LRC text. Supports: [mm:ss], [mm:ss.x], [mm:ss.xx], [mm:ss.xxx], [m:ss:xx] (colon
    /// centiseconds), [hh:mm:ss.xx], multiple stamps per line ([00:12.00][01:30.00]text), metadata
    /// tags ([ar:], [ti:], [al:], [by:], [length:], [offset:±ms] → `offset` in SECONDS, positive
    /// offset = lyrics appear earlier per LRC spec, so convert: effectiveTime = time - offset/1000),
    /// enhanced/word-level tags (<mm:ss.xx> inside text are stripped), BOM, CRLF, stray whitespace.
    /// Lines are sorted by time, ids re-assigned 0..<n; identical consecutive empty gaps collapsed.
    /// Returns nil if the text contains no time-stamped lines.
    static func parse(_ text: String) -> Result?
    /// True if the text looks like LRC (≥ 2 lines starting with a time stamp).
    static func looksLikeLRC(_ text: String) -> Bool
    /// Plain text from LRC (timestamps & metadata tags removed, gaps as blank lines).
    static func plainText(fromLRC text: String) -> String
    /// Decodes an ID3v2 SYLT frame payload (encoding byte, 3-byte language, timestamp format
    /// (2 = milliseconds; 1 = MPEG frames → unsupported → nil), content type, null-terminated
    /// descriptor, then repeated [null-terminated text in the frame encoding][UInt32 big-endian time]).
    /// Handles ISO-8859-1, UTF-16 with BOM, UTF-16BE, UTF-8. Returns nil when unusable.
    static func parseSYLT(_ data: Data) -> [LyricLine]?
}
```

## L1 — `EmbeddedLyricsReader` (`Musicbox/Lyrics/EmbeddedLyricsReader.swift`)

```swift
enum EmbeddedLyricsReader {
    /// Off the main actor. AVURLAsset: try `load(.lyrics)`; then for each available metadata
    /// format, items with identifiers .id3MetadataSynchronizedLyric (SYLT → parseSYLT on dataValue),
    /// .id3MetadataUnsynchronizedLyric (USLT), .iTunesMetadataLyrics (©lyr), quickTime lyrics.
    /// LRC-formatted text → synced via LRCParser. Returns nil when there are no lyrics.
    /// attribution: "Embedded in file"; source: .embedded.
    static func read(url: URL) async -> Lyrics?
}
```

## L2 — `LRCLIBClient` (`Musicbox/Lyrics/LRCLIBClient.swift`)

```swift
struct LRCLIBQuery: Sendable, Hashable {
    var title: String; var artist: String?; var album: String?; var duration: TimeInterval?
    /// Builds a cleaned query from a Track:
    /// - drop "Unknown Artist"/"Unknown Album"; if artist unknown and title is "Artist - Title", split it
    /// - strip noise in ()/[] containing: official, video, audio, lyric(s), lyrics video, hd, 4k,
    ///   visualizer, mv, m/v, remaster(ed), explicit, clean; strip "feat./ft./featuring …" from title
    /// - underscores → spaces, collapse whitespace; duration nil when ≤ 0
    /// - download leftovers: a bracketed 11-char video id ("[dQw4w9WgXcQ]", needs a digit, "-"/"_"
    ///   or an inner capital), a trailing "-<id>", bitrate/format groups ("(320 kbps)", "[MP3 128k]"),
    ///   a leading converter-site segment ("y2mate.com - …"); a domain-like artist tag is dropped
    init(track: Track)
}

/// offline = the device has no connection (notConnectedToInternet, networkConnectionLost,
/// dataNotAllowed, internationalRoamingOff, callIsActive); unavailable = online but LRCLIB can't be
/// reached or timed out (DNS/TLS/connect errors, 12 s timeout); disabled = lookup turned off meanwhile.
enum LRCLIBError: Error { case offline, http(Int), decoding, unavailable, disabled }

struct LRCLIBClient: Sendable {
    static let shared: LRCLIBClient
    /// 1) GET https://lrclib.net/api/get?track_name=&artist_name=&album_name=&duration= (only when
    ///    artist AND duration known; 404 → continue)
    /// 2) GET /api/search?track_name=&artist_name=  (artist known) → best match
    /// 3) GET /api/search?q=<artist title | title>          → best match
    /// 4) still nothing and the title has bracketed / " - Suffix" parts → GET /api/search with
    ///    track_name=<core title> (+ artist_name when known), once
    /// Best match scoring: synced > plain; |duration diff| ≤ 2 s best, reject > 12 s when both
    /// known; normalized (case/diacritic/punctuation-insensitive) title equal > contains; artist match.
    /// Artist unknown: only an equal (or equal core) title within 2 s of a KNOWN duration counts,
    /// and never a generic title ("Intro", "Outro", "Interlude", "Track 3", …) or a single word
    /// shorter than 5 characters ("Home").
    /// Header "User-Agent: Musicbox/1.0 (free offline music player for iOS)". Timeout 12 s.
    /// After HTTP 429 no further request is made. A step-2/3 timeout stops the lookup.
    /// Returns nil ONLY when every request made was answered (200 or 404) and nothing matches;
    /// if any request failed (HTTP error, timeout, bad JSON) and nothing matched, throws that failure
    /// (so a transient problem is never saved as a 3-day "not found"). `.offline` / `.disabled` are
    /// thrown immediately. `isAllowed` is checked before every request (false → `.disabled`);
    /// candidates whose lyrics `isRejected` are skipped.
    func lookup(_ query: LRCLIBQuery,
                isRejected: @escaping @Sendable (Lyrics) -> Bool = { _ in false },
                isAllowed: @escaping @Sendable () -> Bool = { true }) async throws -> Lyrics?   // source .online, attribution "Lyrics from LRCLIB"; instrumental → isInstrumental true
}
```
Response JSON fields: `id, trackName, artistName, albumName, duration (seconds, Double), instrumental (Bool), plainLyrics (String?), syncedLyrics (String? LRC)`. `/api/search` returns an array; `/api/get` returns one object or 404.

## L2 — `LyricsStore` (`Musicbox/Lyrics/LyricsStore.swift`)

```swift
import SwiftUI
import Observation

@MainActor @Observable
final class LyricsStore {
    init(library: LibraryStore)

    /// Persisted in UserDefaults key "lyrics.onlineLookup" (default false; a saved value is kept).
    var onlineLookupEnabled: Bool
    private(set) var cachedCount: Int

    func state(for trackID: String) -> LyricsState       // .idle if never requested
    func lyrics(for trackID: String) -> Lyrics?          // convenience when state is .loaded

    /// Resolves by the priority order above. Sets state .loading → result. Dedupes concurrent calls
    /// for the same track. Uses the disk cache unless `force`. Local results are cached with a
    /// fingerprint (fileSize + fileModificationDate + sidecar mtime) and re-resolved when it changes.
    /// Online hits cached forever; online "not found" cached 3 days (force bypasses).
    /// Network errors → .failed("No internet connection — lyrics will load when you're online.")
    /// only if nothing local was found (else show local).
    func load(_ track: Track, force: Bool = false) async
    /// Background warm-up for the next song: same as load but never sets .loading/.failed states
    /// visibly for other tracks and never throws. No-op if cached or already loading.
    func prefetch(_ track: Track)

    /// User-picked .lrc/.txt (from .fileImporter): security scope start/stop, read as UTF-8 (fallback
    /// ISO Latin-1 / UTF-16), LRC → synced else plain. Saved as .imported (survives rescans).
    /// Returns false (and leaves state unchanged) if the file has no usable text.
    @discardableResult func importLyrics(from url: URL, for track: Track) async -> Bool
    /// Removes an imported override (falls back to other sources on next load).
    func removeImportedLyrics(for track: Track) async
    /// "Wrong Lyrics": the LRCLIB lyrics shown for this track belong to another song. Their word
    /// digest (SHA-256 of the normalized text) is remembered for this track only, the saved answer is
    /// dropped, and a forced load runs; LRCLIB candidates with a rejected digest are never chosen
    /// (and never re-saved). No-op unless the track currently shows `.online` lyrics.
    func rejectOnlineLyrics(for track: Track) async

    /// User timing adjustment in seconds for a track (positive = lyrics later). Persisted.
    func offset(for trackID: String) -> TimeInterval
    func adjustOffset(for trackID: String, by delta: TimeInterval)   // clamp ±30 s, round to 0.1
    func resetOffset(for trackID: String)

    func clearCache()   // deletes all cached lyrics (keeps imported? NO — clears everything incl. offsets), resets states

    /// Index of the line that is active at playback `time` (seconds) with user `offset` applied:
    /// the last line whose (line.time + offset) <= time + 0.05; nil before the first line.
    /// Binary search (O(log n)).
    nonisolated static func activeLineIndex(in lines: [LyricLine], at time: TimeInterval, offset: TimeInterval) -> Int?
}
```
Storage: `AppPaths.applicationSupport/Lyrics/<sha256(trackID) hex>.json` (one Codable entry per
track: lyrics?, state kind, fingerprint, fetchedAt, isImported, rejectedLyrics?) and `Lyrics/offsets.json`.
Fingerprint = `fileSize|fileModificationDate|<sidecar mtime, "0.0" none, "pending" still downloading>`;
when `library.url(for:)` is nil (file unreachable) it is `fileSize|mtime|0.0|unreachable`, so an
answer found meanwhile is re-resolved (sidecar + embedded first) once the file is back.
Error messages: `.offline` → "No internet connection — lyrics will load when you're online.";
`.http(429)` → "The lyrics service is busy right now. Try again in a minute."; other HTTP,
`.decoding`, `.unavailable` → "The lyrics service isn't responding right now. Try again later."
Use `CryptoKit`. All disk/network work off the main actor. `AppPaths` is nonisolated.

## L3 — `LyricsView` (`Musicbox/Views/Player/LyricsView.swift`)

```swift
/// Embedded in NowPlayingView in place of the artwork (like the inline queue). Dark translucent
/// context: use white text. Reads LyricsStore + PlayerEngine + LibraryStore from the environment.
struct LyricsView: View {
    init(track: Track)
}
```
Behaviour:
- `.task(id: track.id) { await lyrics.load(track) }`.
- **Synced**: `ScrollViewReader` + `ScrollView` + `LazyVStack(alignment: .leading, spacing: 18)` of
  lines (id = line.id). Current time source: while playing, `TimelineView(.animation(minimumInterval: 0.1, paused: !player.isPlaying))`
  reading `player.player.currentTime().seconds` (fallback `player.currentTime`); while paused use
  `player.currentTime` (it updates on seek). Active index via `LyricsStore.activeLineIndex`.
  Every line whose time equals the active line's time (±1 ms: an original + translation, a duet) is
  active; auto-scroll targets the FIRST line of that group.
  Styling: active line `.title2.weight(.bold)` opacity 1; other lines `.title2.weight(.bold)` opacity 0.32
  (0.5 with Increase Contrast) with slight scale 0.96 (anchor .leading); spring animation on change. Empty-text lines render as
  an animated "♪ ♪ ♪" (pulse when active). Auto-scroll active line to anchor `UnitPoint(x: 0, y: 0.3)`
  with `.easeInOut(duration: 0.35)`; pause auto-scroll for 3 s after the user drags the list
  (`simultaneousGesture(DragGesture())`), then resume. Tap a line → `player.seek(to: max(0, line.time + offset))`
  and resume auto-scroll immediately. Top & bottom fade mask (LinearGradient). Padding so the first
  line can sit at 30% and the last line can scroll up.
- **Unsynced**: scrollable `.title3.weight(.semibold)` text + small caption "These lyrics aren't time-synced".
- **Instrumental**: centered "♪ Instrumental".
- **Loading**: ProgressView + "Finding lyrics…". **notFound**: `quote.bubble` icon, "No lyrics found",
  buttons "Search Again" (force load) and "Import .lrc File…", caption "Tip: save a .lrc file with the
  same name next to the song (Song.mp3 → Song.lrc)" — for `.mediaLibrary` tracks (no sidecars) instead
  "Tip: use Import .lrc File… to add lyrics for songs from your Music library.". **offlineDisabled**:
  "Online lyrics lookup is off" + "Turn On" (sets `onlineLookupEnabled = true` then force load) +
  "Import .lrc File…" (same caption rule). **failed(msg)**: msg + "Try Again" (retried automatically
  only after the network goes offline → online).
- Footer row (when loaded): attribution text (caption, 60% white; 80% with Increase Contrast) + trailing
  `Menu` ("ellipsis.circle"): "Lyrics Earlier (−0.5 s)", "Lyrics Later (+0.5 s)", "Reset Timing" (shows
  current offset like "Timing +1.0 s" when ≠ 0), Divider, "Search Again", "Import .lrc File…",
  "Wrong Lyrics" (only when source == .online; confirmation "Wrong Lyrics?" → "Remove These Lyrics" →
  `lyrics.rejectOnlineLyrics(for:)` for the song it was opened for, toast "Wrong lyrics removed"), and
  "Remove Imported Lyrics" (only when source == .imported).
- Importing: one `.fileImporter(isPresented:allowedContentTypes: [UTType(filenameExtension: "lrc") ?? .plainText, .plainText, .text])`
  owned by `View.lyricsImportHost()` (declared in LyricsView.swift; publishes
  `EnvironmentValues.lyricsImport: LyricsImportAction?`, which LyricsView calls with its track).
  NowPlayingView applies it on its root so rotation (which rebuilds the lyrics panel) doesn't dismiss
  an open picker; a LyricsView without a host above it hosts its own. Result →
  `lyrics.importLyrics(from:for:)` for the song the picker was opened for; failure →
  `router.showToast("That file has no lyrics")`.
- Accessibility: each line is a button with label = text and hint "Plays from this line" while
  playing, "Moves playback to this line" while paused (tapping only seeks); VoiceOver users get
  "Lyrics" header.

## Integration (after the Core phase) — edits to existing files

- `MusicboxApp.swift`: create `LyricsStore(library: lib)` once (like the player), inject `.environment(lyrics)` in `MusicboxSceneRoot`.
- `NowPlayingView.swift`: bottom row gains a Lyrics toggle (`quote.bubble` / `quote.bubble.fill`,
  tinted when on). Middle area modes become mutually exclusive: artwork | queue | lyrics. In lyrics
  mode show `LyricsView(track:)` sized to the area the artwork uses (portrait) or the left pane
  (landscape); it may use a bit more height than the square artwork. Remember the last mode choice
  (lyrics on/off) with `@AppStorage("nowPlaying.showLyrics")`. Prefetch: on current-track change,
  `lyrics.prefetch(current)` and `lyrics.prefetch(player.upNext.first)`. `.lyricsImportHost()` on the
  root. While the lyrics panel is shown, the backdrop gets an extra animated scrim (black 0.38 → 0.2 →
  0.12 top to bottom over the usual 0.28 → 0.5 → 0.68) so white lyrics keep ≥ 4.5:1 over white covers.
- `RootView.swift`: `.onChange(of: player.currentTrack?.id)` → prefetch current + next (so lyrics are
  ready before Now Playing opens).
- `SettingsView.swift`: new "Lyrics" section: Toggle "Find Lyrics Online" (`lyrics.onlineLookupEnabled`),
  "Clear Saved Lyrics" (shows `cachedCount`, confirmation), footer: "Musicbox looks for lyrics in .lrc
  files next to your songs and inside the files first. When online lookup is on, it asks LRCLIB — a free,
  open lyrics library — using only the song's title, artist, album and length. No account, no subscription.
  Your music files never leave your iPhone. Found lyrics are saved for offline use." Update About/Privacy
  wording accordingly (no "fully offline" claims that are now false).
- `SPEC.md`: note that the network is used only for optional lyrics lookup.
