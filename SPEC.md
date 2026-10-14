# Musicbox — Architecture Contract (v1)

A free, offline, no-account iOS music player. It finds local audio/video files, plays them like a
music player (MP4/MOV play as **audio by default**), supports playlists, and keeps playing on the
lock screen / in the background with full lock-screen + Control Center + headphone controls.

This file is the **binding contract** between parallel implementers. Every public type, property and
method listed here MUST exist with exactly this name and signature. You may add `private` /
`fileprivate` helpers freely, and you may add extra *internal* members if truly needed, but never
rename or change a listed signature. If you need something from another module that is not listed
here, do NOT invent it — work around it inside your own files.

## Toolchain / project facts

- Xcode 26, iOS deployment target **17.0**, SwiftUI app lifecycle, **Swift 5 language mode**
  (`SWIFT_VERSION = 5.0`). Use the Observation framework (`@Observable`), not `ObservableObject`.
- Project: `Musicbox.xcodeproj`, single target `Musicbox`. The `Musicbox/` folder is a
  *synchronized folder*: **every `.swift` file you create anywhere under `Musicbox/` is compiled
  automatically**. Do not touch `project.pbxproj`. Do not create duplicate type names.
- `Musicbox/Info.plist` already contains: `UIBackgroundModes = [audio]`, `UIFileSharingEnabled`,
  `LSSupportsOpeningDocumentsInPlace`, `CFBundleDocumentTypes` (audio + movie), and
  `NSAppleMusicUsageDescription` (via build settings). Accent color asset: `AccentColor`.
- No third-party packages. No analytics. No subscriptions. The network is used ONLY for the optional
  LRCLIB lyrics lookup (song title, artist, album, length — never audio); see LYRICS_SPEC.md.
- Build command (simulator):
  `xcodebuild -project Musicbox.xcodeproj -scheme Musicbox -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`
- Main-thread types are annotated `@MainActor`. Background work uses `Task.detached` or
  `nonisolated` static functions. Avoid Swift 6-only syntax that fails in Swift 5 mode.

## File ownership

| Owner | Files |
|---|---|
| **A – Library core** | `Musicbox/Models/Track.swift`, `Musicbox/Models/Playlist.swift`, `Musicbox/Models/LibraryModels.swift`, `Musicbox/Services/AppPaths.swift`, `Musicbox/Services/JSONStore.swift`, `Musicbox/Services/LibraryStore.swift` |
| **B – Sources & scanning** | `Musicbox/Services/SupportedMedia.swift`, `Musicbox/Services/FileScanner.swift`, `Musicbox/Services/FolderBookmarks.swift`, `Musicbox/Services/MetadataReader.swift`, `Musicbox/Services/ArtworkCache.swift`, `Musicbox/Services/MediaLibraryScanner.swift`, `Musicbox/Services/ImportService.swift` |
| **C – Playback engine** | `Musicbox/Player/PlayerEngine.swift`, `Musicbox/Player/NowPlayingController.swift`, `Musicbox/Player/PlaybackStateStore.swift`, `Musicbox/Player/PlayerVideoView.swift`, `Musicbox/Player/AirPlayButton.swift` |
| **D1 – App shell, library & settings UI** | `Musicbox/App/MusicboxApp.swift` (replace placeholder), `Musicbox/App/AppRouter.swift`, `Musicbox/Views/RootView.swift`, `Musicbox/Views/Components/*.swift`, `Musicbox/Views/Library/*.swift`, `Musicbox/Views/Search/*.swift`, `Musicbox/Views/Settings/*.swift` |
| **D2 – Player & playlist UI** | `Musicbox/Views/Player/*.swift`, `Musicbox/Views/Playlists/*.swift` |

---

## A — Models (`Musicbox/Models/`)

```swift
import Foundation

enum MediaKind: String, Codable, Hashable, Sendable { case audio, video }

/// Where a track physically lives. Used to build a stable ID and to resolve a playable URL.
enum TrackLocation: Codable, Hashable, Sendable {
    /// Inside the app's own Documents folder (visible in Files app as On My iPhone › Musicbox).
    case documents(relativePath: String)
    /// Inside a user-linked folder (security-scoped bookmark), e.g. Files › Downloads or iCloud Drive.
    case folder(sourceID: UUID, relativePath: String)
    /// A DRM-free item from the device Music library (songs synced from a computer).
    case mediaLibrary(persistentID: UInt64, assetURL: String)

    /// Stable identifier string. MUST be exactly:
    ///   documents  -> "doc:" + relativePath
    ///   folder     -> "fld:" + sourceID.uuidString + ":" + relativePath
    ///   mediaLib   -> "mpl:" + String(persistentID)
    var stableID: String { get }
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

    var isVideo: Bool { get }              // kind == .video
    var displayArtist: String { get }      // artist
    var subtitle: String { get }           // "Artist · Album" (omit Unknown parts gracefully)
}

struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var trackIDs: [String]         // ordered; duplicates NOT allowed
    var createdAt: Date
    var updatedAt: Date
}

struct LinkedFolder: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String        // last path component at link time
    var bookmarkData: Data
    var addedAt: Date
    var lastScanAt: Date?
    var trackCount: Int            // updated after each scan
    var isAvailable: Bool          // false if bookmark failed to resolve on last scan
    var canonicalPath: String? = nil   // where the folder was last seen (set on link, refreshed whenever the
                                       // bookmark resolves); decodeIfPresent. Lets removeFolder recognise an
                                       // offline folder (drive unplugged) when it is linked again.
}

struct AppSettings: Codable, Hashable, Sendable {
    var includeMusicLibrary: Bool = false     // opt-in: needs Apple Music permission
    var includeVideos: Bool = true            // include mp4/m4v/mov/3gp files in library
    var minimumDuration: TimeInterval = 0     // skip clips shorter than this (0 = keep all)
    var songSort: SongSort = .title
    init() {}
}

enum SongSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case title, artist, album, dateAdded, duration
    var id: String { rawValue }
    var label: String { get }                  // "Title", "Artist", "Album", "Recently Added", "Duration"
}

struct AlbumGroup: Identifiable, Hashable {
    let id: String            // lowercased "album|albumArtistOrArtist"
    let title: String
    let artist: String
    let tracks: [Track]       // sorted by trackNumber then title
    var artworkTrackID: String? { get }   // first track with hasArtwork, else first track
    var totalDuration: TimeInterval { get }
}

struct ArtistGroup: Identifiable, Hashable {
    let id: String            // lowercased artist name
    let name: String
    let tracks: [Track]       // sorted by album then trackNumber then title
    let albumCount: Int
    var artworkTrackID: String? { get }
}
```

## A — `AppPaths` (`Services/AppPaths.swift`)

```swift
enum AppPaths {
    static var documents: URL { get }            // FileManager documents dir
    static var musicFolder: URL { get }          // documents/"Music" (created on demand) — default import target
    static var applicationSupport: URL { get }   // created on demand
    static var caches: URL { get }               // created on demand
    static var artworkCache: URL { get }         // caches/"Artwork" (created on demand)
    static func ensureDirectoriesExist()         // creates musicFolder, applicationSupport, artworkCache
}
```

## A — `JSONStore` (`Services/JSONStore.swift`)

```swift
enum JSONStore {
    /// Loads `T` from applicationSupport/<name>.json. Returns nil if missing/corrupt (never crashes).
    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T?
    /// Atomically writes to applicationSupport/<name>.json. Errors are logged, not thrown.
    static func save<T: Encodable>(_ value: T, to name: String)
}
```
File names used: `"library"` ([Track]), `"playlists"` ([Playlist]), `"folders"` ([LinkedFolder]),
`"settings"` (AppSettings), `"playback"` (owned by C's PlaybackStateStore).

## A — `LibraryStore` (`Services/LibraryStore.swift`)

```swift
import SwiftUI
import Observation

@MainActor @Observable
final class LibraryStore {
    init()  // loads library/playlists/folders/settings JSON synchronously; calls AppPaths.ensureDirectoriesExist()

    // MARK: State (read-only to UI)
    private(set) var tracks: [Track]            // sorted according to settings.songSort
    private(set) var tracksByID: [String: Track]
    private(set) var albums: [AlbumGroup]       // recomputed whenever tracks change; sorted by title
    private(set) var artists: [ArtistGroup]     // recomputed whenever tracks change; sorted by name
    private(set) var playlists: [Playlist]      // sorted by name (case-insensitive)
    private(set) var folders: [LinkedFolder]
    var settings: AppSettings                   // didSet: persist + re-sort/re-filter; toggling includeMusicLibrary/includeVideos triggers a rescan
    private(set) var isScanning: Bool
    private(set) var scanStatus: String?        // human text e.g. "Scanning Downloads… 120 files"
    private(set) var lastScanDate: Date?
    var lastErrorMessage: String?               // UI may clear it

    // MARK: Derived
    var audioTracks: [Track] { get }
    var videoTracks: [Track] { get }
    var favoriteTracks: [Track] { get }
    var recentlyAddedTracks: [Track] { get }     // by dateAdded desc, max 100
    var mostPlayedTracks: [Track] { get }        // playCount > 0, desc, max 100
    var documentsTrackCount: Int { get }
    var musicLibraryTrackCount: Int { get }
    func track(id: String) -> Track?
    func tracks(ids: [String]) -> [Track]        // preserves order, skips missing
    func tracks(in playlist: Playlist) -> [Track]
    func playlist(id: UUID) -> Playlist?
    func tracks(inFolder folderID: UUID) -> [Track]

    // MARK: Playback support
    /// Resolves a playable file URL. For `.folder` locations it uses the resolved, already
    /// access-started security-scoped folder URL. Returns nil if unavailable.
    func url(for track: Track) -> URL?

    // MARK: Scanning
    func rescan() async                 // full scan of Documents + linked folders (+ Music library if enabled); merges; drops missing
    func rescanIfNeeded() async         // on launch/foreground; if a scan is running, queues one follow-up pass; if one
                                        // finished < 2 s ago, schedules ONE trailing rescan() at the end of that window
                                        // (never drops the request)
                                        // rescan() also schedules "settle" passes (every 3 s, max 20 per request) while the
                                        // last pass saw a media file modified < 6 s ago or still empty (a copy in progress)
    func startWatchingLinkedFolders()   // scenePhase .active: file presenters on the resolved linked folders (debounced
    func stopWatchingLinkedFolders()    // rescan(), ≤ 1 per 10 s) + a 60 s poll while folders are linked; .background: stop
    /// Called by PlayerEngine; also the store calls `onTracksRemoved` after a scan removes tracks.
    var onTracksRemoved: ((Set<String>) -> Void)?

    // MARK: Sources
    func addFolder(_ url: URL) async    // url from .fileImporter(.folder); starts scope, bookmarks, persists, scans. Errors -> lastErrorMessage
    func removeFolder(_ id: UUID)       // removes folder and its tracks (and from playlists? NO — playlists keep IDs; they resolve to missing).
                                        // The songs wait hidden (user data + artwork) for 30 days; addFolder of the same path within
                                        // that time reuses the folder's UUID, so the same track IDs come back ("folders-removed" JSON).
                                        // Path: live access URL, else resolved bookmark, else LinkedFolder.canonicalPath, else the
                                        // path stored in the bookmark data. With no path at all the songs are dropped, and
                                        // canRestoreFolderAfterRemoval(_:) -> false lets the dialog say so.
    func canRestoreFolderAfterRemoval(_ id: UUID) -> Bool   // no side effects
    func importFiles(_ urls: [URL]) async -> Int   // copies into AppPaths.musicFolder via ImportService, then rescans; returns imported count
    func handleOpenURL(_ url: URL) async           // "Open in"/share-to-app entry point: import that file then rescan; an
                                                   // unsupported file's system copy (Documents/Inbox, tmp/…-Inbox) is deleted
    func deleteFromDevice(_ trackID: String) throws // only for .documents tracks: deletes file, removes track, cleans playlists
    func requestMusicLibraryAccessAndEnable() async -> Bool   // asks permission, sets settings.includeMusicLibrary on success

    // MARK: Playlists
    @discardableResult func createPlaylist(name: String, trackIDs: [String] = []) -> Playlist
    func renamePlaylist(_ id: UUID, to name: String)
    func deletePlaylist(_ id: UUID)
    func addTracks(_ trackIDs: [String], to playlistID: UUID)          // appends, skipping duplicates
    func removeTracks(at offsets: IndexSet, from playlistID: UUID)     // offsets index into playlist.trackIDs
    func removeTrack(_ trackID: String, from playlistID: UUID)
    func moveTracks(in playlistID: UUID, from source: IndexSet, to destination: Int)

    // MARK: User data
    func toggleFavorite(_ trackID: String)
    func recordPlay(_ trackID: String)   // playCount += 1, lastPlayedAt = now (debounced save)
}
```

Merge rules for `rescan()`:
1. Build the set of `ScannedFile`s from: `FileScanner.scan(root: AppPaths.documents, sourceID: nil)`,
   each linked folder (resolve bookmark with `FolderBookmarks.resolve`, call
   `startAccessingSecurityScopedResource()` once per resolved URL and keep it started for the app
   lifetime — cache resolved URLs in a `[UUID: URL]` dictionary; refresh stale bookmarks), and the
   Music library when `settings.includeMusicLibrary` and authorized (`MediaLibraryScanner.scan()`).
   File scanning must run off the main actor.
2. For each scanned file: if a track with the same id exists and `fileSize` + `fileModificationDate`
   are unchanged, keep it as-is (fast path, no metadata read). Otherwise read metadata with
   `MetadataReader.read(url:)` (bounded concurrency, e.g. 4 at a time), store artwork via
   `ArtworkCache.shared.store(_:for:)`, and create/update the Track **preserving** `dateAdded`,
   `isFavorite`, `playCount`, `lastPlayedAt` from the old track.
3. Skip videos when `!settings.includeVideos`; skip items shorter than `settings.minimumDuration`
   when > 0. Skip files whose metadata shows no audio and no video (unplayable).
4. Tracks not found any more are removed (and their artwork removed from cache); fire
   `onTracksRemoved`. Linked folders that fail to resolve are marked `isAvailable = false` and their
   existing tracks are **kept** (the drive may be temporarily offline) but not re-scanned.
5. Persist `library.json` + `folders.json`, recompute albums/artists, update `scanStatus`
   progressively ("Reading 34 of 120…"), set `lastScanDate`.

---

## B — Sources & scanning (`Musicbox/Services/`)

```swift
import Foundation
import UniformTypeIdentifiers

enum SupportedMedia {
    static let audioExtensions: Set<String>  // mp3 m4a m4b aac wav wave aif aiff aifc caf flac alac adts ac3 eac3 mp2 amr 3ga opus(if playable) — lowercased
    static let videoExtensions: Set<String>  // mp4 m4v mov 3gp 3g2
    static func kind(forExtension ext: String) -> MediaKind?   // case-insensitive
    static var importableTypes: [UTType] { get }               // [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .movie, .mpeg4Movie, .quickTimeMovie] + UTType(filenameExtension:"flac") etc.
}

struct ScannedFile: Sendable, Hashable {
    let location: TrackLocation
    let url: URL
    let fileExtension: String       // lowercased
    let kind: MediaKind
    let fileSize: Int64
    let modificationDate: Date?
}

enum FileScanner {
    /// Recursively enumerates `root` (nonisolated, synchronous — call off the main actor).
    /// - Includes only SupportedMedia extensions; skips hidden files, package contents, `.Trash`,
    ///   and symlink loops.
    /// - `sourceID == nil` => locations are `.documents(relativePath:)` (path relative to root),
    ///   otherwise `.folder(sourceID:relativePath:)`.
    /// - iCloud placeholders (`.<name>.icloud` or not-downloaded ubiquitous items) trigger
    ///   `FileManager.startDownloadingUbiquitousItem(at:)` and are NOT returned this pass.
    /// - relativePath uses "/" separators, no leading slash, standardized (resolve /private symlink
    ///   differences by comparing standardizedFileURL / resolvingSymlinksInPath paths).
    static func scan(root: URL, sourceID: UUID?) -> [ScannedFile]
    /// Same, plus `newestEmptyFileModificationDate` of skipped empty media files (copies in progress).
    /// Not-downloaded iCloud items get startDownloading only when no download was requested yet.
    static func scanWithDetails(root: URL, sourceID: UUID?) -> FileScanResult
}

enum FolderBookmarks {
    static func makeBookmark(for url: URL) throws -> Data            // plain (iOS has no .withSecurityScope option); call while scope is active
    static func resolve(_ data: Data) -> (url: URL, isStale: Bool)?  // nil if it cannot be resolved
}

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

enum MetadataReader {
    /// Uses AVURLAsset async loading (load(.commonMetadata), load(.duration), load(.tracks)) plus
    /// ID3/iTunes metadata formats for track number, album artist, genre. Never throws; missing
    /// fields are nil. For videos with no embedded artwork, generate a frame thumbnail
    /// (AVAssetImageGenerator at ~10% of duration, max 600px) as artworkData.
    static func read(url: URL) async -> TrackMetadata
}

final class ArtworkCache: @unchecked Sendable {
    static let shared: ArtworkCache
    /// Downsamples to max 600x600, writes JPEG (q 0.85) to AppPaths.artworkCache/<sha-ish filename>.jpg.
    /// Thread-safe; may be called from any thread.
    func store(_ data: Data, for trackID: String)
    func remove(for trackID: String)
    func hasArtwork(for trackID: String) -> Bool
    /// Fast synchronous lookup (NSCache → disk). Returns nil if none. Safe on main thread for small images.
    func image(for trackID: String) -> UIImage?
    /// Async, downsampled to `maxPixel` (e.g. 120 for rows, 600 for now playing), memory cached per size.
    func image(for trackID: String, maxPixel: CGFloat) async -> UIImage?
    func removeAll()
}

import MediaPlayer
struct MediaLibraryItem: Sendable {
    let location: TrackLocation      // .mediaLibrary(persistentID:assetURL:)
    let metadata: TrackMetadata      // from MPMediaItem properties; artworkData from item.artwork?.image(at: 600x600) as JPEG
    let dateAdded: Date
}
enum MediaLibraryScanner {
    static var isAuthorized: Bool { get }
    static func requestAuthorization() async -> Bool
    /// MPMediaQuery.songs(); skips items with nil assetURL (DRM / cloud-only) and hasProtectedAsset.
    /// Returns [] when not authorized or on simulator.
    static func scan() -> [MediaLibraryItem]
}

enum ImportService {
    /// Copies a picked/opened file into `destinationFolder` (default AppPaths.musicFolder),
    /// handling security scope (start/stop), coordinated reading (NSFileCoordinator) for
    /// iCloud/File Provider files, and name collisions ("Song 2.mp3"). If the file is already inside
    /// AppPaths.documents (e.g. Documents/Inbox from "Open in"), it is MOVED instead of copied
    /// (Inbox items moved into musicFolder). Returns the destination URL.
    static func importFile(at url: URL, into destinationFolder: URL = AppPaths.musicFolder) throws -> URL
}
```

---

## C — Playback engine (`Musicbox/Player/`)

```swift
import AVFoundation
import MediaPlayer
import Observation

enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
    var systemImage: String { get }    // "repeat", "repeat", "repeat.1"
}

@MainActor @Observable
final class PlayerEngine {
    init(library: LibraryStore)   // configures AVAudioSession(.playback, mode .default), remote commands, observers; restores last session (paused)

    // MARK: State
    private(set) var player: AVPlayer          // single AVPlayer; replaced only after a media services reset / failure (video layers are re-pointed by the engine)
    private(set) var videoAspectRatio: CGFloat? // displayed width/height of the current video (nil = unknown / audio)
    private(set) var queue: [String]           // track IDs in current play order
    private(set) var currentIndex: Int?        // index into queue
    var currentTrack: Track? { get }           // library.track(id: queue[currentIndex])
    var upNext: [Track] { get }                // tracks after currentIndex
    private(set) var isPlaying: Bool           // reflects player.timeControlStatus (playing or waiting-to-play-while-intending)
    private(set) var currentTime: TimeInterval
    private(set) var duration: TimeInterval
    private(set) var shuffleEnabled: Bool
    private(set) var repeatMode: RepeatMode
    var playbackRate: Float                    // 0.5…2.0, default 1.0; didSet applies if playing + updates now playing info
    private(set) var sleepTimerEndDate: Date?
    private(set) var sleepAtEndOfTrack: Bool
    var errorMessage: String?                  // transient, UI shows & clears
    var showVideo: Bool                        // user toggle in Now Playing; default false (audio-only). Only affects video tracks.
    var hasActiveSession: Bool { get }         // currentTrack != nil

    // MARK: Commands
    func play(tracks: [Track], startAt index: Int = 0, shuffle: Bool = false)
    func play(trackIDs: [String], startAt index: Int = 0, shuffle: Bool = false)
    func shuffleAll(_ tracks: [Track])         // play(tracks:, startAt: random, shuffle: true)
    func togglePlayPause()
    func resume()
    func pause()
    func next()                                // honours repeat/shuffle; at end with repeat off -> stop at end (paused, index stays last, time 0)
    func previous()                            // if currentTime > 3 s -> restart track, else previous (wraps if repeat all)
    func seek(to seconds: TimeInterval)
    func skip(by seconds: TimeInterval)        // ±15
    func toggleShuffle()                       // keeps current track playing; shuffles the rest; turning off restores original order
    func cycleRepeatMode()                     // off -> all -> one -> off
    func playNext(_ trackIDs: [String])        // insert right after current (start playing if queue empty)
    func addToQueue(_ trackIDs: [String])      // append (start playing if queue empty)
    func removeFromQueue(at offsets: IndexSet) // offsets index into `queue`; cannot remove current (ignored)
    func moveInQueue(from source: IndexSet, to destination: Int)  // indices into `queue`; keeps currentIndex pointing at the same track
    func jump(to queueIndex: Int)
    func setSleepTimer(minutes: Int?)          // nil cancels; fades/pauses at end
    func setSleepAtEndOfTrack()
    func clearQueue()                          // stops playback & clears now playing info
    func saveState()                           // persist queue/index/time/shuffle/repeat (PlaybackStateStore)
    func attachVideoLayer(_ layer: AVPlayerLayer)   // called by PlayerVideoView
    func detachVideoLayer(_ layer: AVPlayerLayer)
}
```

Behaviour requirements (C):
- `AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)`
  then `setActive(true)` right before playing. `UIBackgroundModes=audio` is already set.
- `player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible`;
  `player.allowsExternalPlayback = true`.
- **Video files play audio-only by default**: when the item becomes ready, disable its visual
  tracks (`item.tracks.filter { $0.assetTrack?.mediaType == .video }.forEach { $0.isEnabled = false }`)
  unless `showVideo` is true AND the app is in the foreground AND a layer is attached. When the app
  enters background (`UIApplication.didEnterBackgroundNotification`) detach every AVPlayerLayer
  (`layer.player = nil`) and disable visual tracks so audio keeps playing; re-attach on
  `willEnterForeground`. (Apple QA1668.)
- Remote commands (MPRemoteCommandCenter): play, pause, togglePlayPause, nextTrack,
  previousTrack, changePlaybackPosition, skipForward/skipBackward disabled (to keep next/prev on
  lock screen), changeRepeatMode, changeShuffleMode, changePlaybackRate (0.75,1,1.25,1.5,2).
- Now Playing info (MPNowPlayingInfoCenter): title, artist, album, duration, elapsed, rate,
  default rate, queue index/count, media type audio, artwork (`MPMediaItemArtwork` from
  `ArtworkCache.shared.image(for:)` — the artwork request handler must be safe to call on a
  background thread, so capture the UIImage, don't touch actor state inside it).
  Also set `MPNowPlayingInfoCenter.default().playbackState` on iOS 13+ where available.
- Interruptions: on `.began` → mark paused (remember whether we were playing); on `.ended` with
  `.shouldResume` → resume. Route change `.oldDeviceUnavailable` (headphones unplugged) → pause.
  `mediaServicesWereResetNotification` (or the AVPlayer's `status` turning `.failed`) → rebuild
  session/commands and replace the AVPlayer, reloading the current item paused (no alerts/auto-skip).
- Item end (`AVPlayerItem.didPlayToEndTimeNotification`): repeat one → seek 0 & play; else `next()`.
  `sleepAtEndOfTrack` → pause instead and clear it. Call `library.recordPlay(id)` when a track has
  played ≥ 50% or ended.
- Failed item (`status == .failed` or `failedToPlayToEndTime`, or `library.url(for:)` nil): set
  `errorMessage`, skip to next automatically; stop after 5 consecutive failures.
- Periodic time observer every 0.5 s updates `currentTime`; `duration` from item (fallback track.duration).
- Library changes: set `library.onTracksRemoved` in init; remove those IDs from the queue safely
  (if the current one vanished, advance or stop).
- State restoration: `PlaybackStateStore` saves `{queue, originalQueue, currentIndex, currentTime, shuffle, repeat, rate}`
  to JSON `"playback"`. Restore on init: prepare the item (paused) and seek to saved time; do not
  auto-play. Save on every track change, pause, `didEnterBackground`, `willTerminate`, and every
  ~15 s while playing.
- Sleep timer: a `Task` that sleeps until end date, then fades volume over 3 s, pauses, restores volume.
  A deadline that passed while nothing was playing (app suspended, interruption) only clears the
  timer: it never pauses playback the user starts later and it cancels the interruption auto-resume.

`NowPlayingController` (internal helper class owned by PlayerEngine) wraps the remote commands and
now-playing dictionary. `PlaybackStateStore` is a small Codable struct + load/save via `JSONStore`.

```swift
/// SwiftUI view that renders the engine's video when showVideo is on.
struct PlayerVideoView: UIViewRepresentable {
    init(engine: PlayerEngine)
    // makeUIView: a UIView subclass whose layerClass is AVPlayerLayer, videoGravity .resizeAspect;
    // calls engine.attachVideoLayer / detachVideoLayer (in dismantleUIView).
}

/// AVRoutePickerView wrapper (AirPlay / Bluetooth output picker).
struct AirPlayButton: UIViewRepresentable {
    init(tint: UIColor = .label)
}
```

---

## D — UI (`Musicbox/App`, `Musicbox/Views`)

Environment injection: `MusicboxApp` owns `@State private var library = LibraryStore()` and
`@State private var player: PlayerEngine` (created from library in `init()`), shared by every
window. Each `WindowGroup` window gets its own root view (`MusicboxSceneRoot`) that owns
`@State private var router = AppRouter()` (tab, sheets and toasts are per window on iPad), and
injects all three with `.environment(...)`; `.onOpenURL` lives on that per-window root.
Views read them with `@Environment(LibraryStore.self) private var library`,
`@Environment(PlayerEngine.self) private var player`, `@Environment(AppRouter.self) private var router`.

App lifecycle (D1): `.onOpenURL { url in Task { await library.handleOpenURL(url) } }`;
`scenePhase == .active` → `Task { await library.rescanIfNeeded() }`, `documentsWatcher.start()`,
`library.startWatchingLinkedFolders()`; `.background` → `documentsWatcher.stop()`,
`library.stopWatchingLinkedFolders()`, `player.saveState()`. First launch runs `rescan()`.
`DocumentsWatcher` (Services): vnode sources on Documents, Documents/Music and their subfolders (≤ 3 levels,
≤ 64 folders, re-listed after each event); debounced 1.5 s → `library.rescan()` (not rescanIfNeeded).

```swift
// D1 — Musicbox/App/AppRouter.swift
@MainActor @Observable
final class AppRouter {
    var selectedTab: AppTab = .library
    var isNowPlayingPresented: Bool = false
    var addToPlaylistRequest: AddToPlaylistRequest?            // RootView presents AddToPlaylistSheet(trackIDs:)
    var nowPlayingAddToPlaylistRequest: AddToPlaylistRequest?  // NowPlayingView presents it (sheet-on-sheet safe)
    var toast: String?                                // RootView AND NowPlayingView show a transient capsule overlay; auto-hides after ~1.8 s
    func showToast(_ text: String)
    /// Routes to whichever presenter is on top: if isNowPlayingPresented -> nowPlayingAddToPlaylistRequest,
    /// else addToPlaylistRequest. Never present sheets from inside List rows.
    func addToPlaylist(_ trackIDs: [String])
}
enum AppTab: Hashable { case library, playlists, search, settings }
struct AddToPlaylistRequest: Identifiable { let id = UUID(); let trackIDs: [String] }
```

Shared components (D1 owns, D2 uses) — `Musicbox/Views/Components/`:
```swift
/// Loads artwork async via ArtworkCache (maxPixel = size * displayScale); placeholder = gradient
/// (hue derived from trackID hash) + SF Symbol "music.note" (or "film" if isVideo).
struct ArtworkView: View {
    init(trackID: String?, size: CGFloat, cornerRadius: CGFloat = 6, isVideo: Bool = false)
}
/// Standard song row: ArtworkView(48), title (highlighted with accent + animated "waveform" symbol
/// if it is player.currentTrack), subtitle, a small "video" badge for videos, duration text,
/// and a trailing "ellipsis" Menu containing TrackMenuItems. Tapping the row is handled by the caller.
struct TrackRow: View {
    init(track: Track, playlistID: UUID? = nil, showsArtwork: Bool = true)
}
/// Menu/contextMenu contents: Play Next, Add to Queue, Add to Playlist…, Favorite/Unfavorite,
/// (if playlistID != nil) Remove from Playlist, (if track.location is .documents) Delete from iPhone (with confirmation handled via router toast / confirmationDialog inside TrackRow).
struct TrackMenuItems: View {
    init(track: Track, playlistID: UUID? = nil, onDeleteRequest: (() -> Void)? = nil)
}
/// Big play / shuffle button pair used at the top of song lists, albums, playlists.
struct PlayShuffleHeader: View {
    init(tracks: [Track])
}
/// Empty library onboarding: explains the 3 ways to add music with buttons
/// ("Link a Folder…", "Import Files…", "How to use Files app") — buttons call closures.
struct EmptyLibraryView: View {
    init(onLinkFolder: @escaping () -> Void, onImportFiles: @escaping () -> Void)
}
extension TimeInterval { var mmss: String { get } }   // "3:07", "1:02:03"
```

D1 screens:
- `RootView`: `TabView(selection: $router.selectedTab)` with tabs Library (`LibraryView`),
  Playlists (`PlaylistsView` — D2), Search (`SearchView`), Settings (`SettingsView`). Each tab's
  `NavigationStack` gets `.safeAreaInset(edge: .bottom) { MiniPlayerView() }` (D2) when
  `player.hasActiveSession`. Presents `.sheet(isPresented: $router.isNowPlayingPresented) { NowPlayingView() }` (D2),
  `.sheet(item: $router.addToPlaylistRequest) { AddToPlaylistSheet(trackIDs: $0.trackIDs) }` (D2),
  toast overlay, and an alert bound to `library.lastErrorMessage` / `player.errorMessage`.
- `LibraryView`: segmented Picker Songs / Albums / Artists / Videos; toolbar: sort Menu (SongSort),
  rescan button (spinner while `library.isScanning`), "+" Menu (Link Folder…, Import Files…).
  `.refreshable { await library.rescan() }`. Shows `EmptyLibraryView` when no tracks.
  Songs list uses `PlayShuffleHeader` then `TrackRow`s; tapping row → `player.play(tracks: list, startAt: i)`.
  `AlbumsView` (2-column LazyVGrid of artwork + title/artist) → `AlbumDetailView(album:)`;
  `ArtistsView` list → `ArtistDetailView(artist:)`; `VideosView` list of video tracks (they still play as audio).
  Scan status banner when `library.isScanning`.
  Folder picker: `.fileImporter(isPresented:allowedContentTypes: [.folder])` → `library.addFolder(url)`.
  File import: `.fileImporter(isPresented:allowedContentTypes: SupportedMedia.importableTypes, allowsMultipleSelection: true)` →
  `library.importFiles(urls)`. IMPORTANT: attach the two `.fileImporter` modifiers to DIFFERENT views
  (SwiftUI only honours one per view).
- `SearchView`: `.searchable` over songs (title/artist/album), albums, artists, playlists; sections.
- `SettingsView`: Sources section (On My iPhone count, each LinkedFolder row with track count /
  "Unavailable" badge / swipe-to-remove, "Link a Folder…", "Import Files…", "Rescan Now" with
  status), toggles (Include Music Library → calls `requestMusicLibraryAccessAndEnable()` when
  turning on; Include Videos), minimum duration picker (Off/10s/30s/60s), a "How to add music"
  help section (Files app → On My iPhone → Musicbox → Music; Share/“Open in Musicbox” from any
  app; Link your Downloads / iCloud Drive folder once — new files are detected automatically),
  and an About section ("Free forever. No subscription, no ads, no account. Everything stays on your device.").

D2 screens (`Musicbox/Views/Player/`, `Musicbox/Views/Playlists/`):
- `MiniPlayerView`: 64pt bar with material background, rounded, ArtworkView(44), title/artist
  (marquee not needed), play/pause + next buttons, thin progress line; tap → `router.isNowPlayingPresented = true`;
  swipe up also opens.
- `NowPlayingView`: large artwork (or `PlayerVideoView` when current track is video and
  `player.showVideo`), title/artist, favorite button, scrubber Slider with local drag state
  (don't fight periodic updates while dragging) and elapsed/remaining labels, transport controls
  (shuffle, previous, play/pause (large), next, repeat), a volume-free bottom row: AirPlayButton,
  "Show Video / Audio Only" toggle (only for video tracks), queue button (toggles inline `QueueView`),
  "…" Menu (Add to Playlist → `router.addToPlaylist([id])`, Sleep Timer submenu: Off/5/10/15/30/45/60 min/End of Track —
  shows remaining time, Playback Speed submenu 0.75/1/1.25/1.5/2). Background: blurred artwork
  / gradient. Works in dark & light. Drag indicator visible.
- NowPlayingView attaches `.sheet(item: $router.nowPlayingAddToPlaylistRequest) { AddToPlaylistSheet(trackIDs: $0.trackIDs) }`,
  shows `player.errorMessage` inline/toast, and renders the `router.toast` overlay (RootView's is hidden behind the sheet).
- The queue is shown **inline inside NowPlayingView** (Apple-Music style: the queue button swaps the
  artwork area for `QueueView`) — NOT as a nested sheet.
- `QueueView` (embeddable, no NavigationStack of its own): List "Now Playing" row + "Up Next" section with `.onMove` / `.onDelete` mapping to
  queue indices (`currentIndex + 1 + offset`), tap to `jump(to:)`, "Clear" button → keep current only
  (use removeFromQueue for all upcoming indices).
- `PlaylistsView`: "New Playlist" button (alert with TextField), smart rows Favorites / Recently
  Added / Most Played (→ `SmartPlaylistView(kind:)`), then user playlists (row: 2x2 artwork mosaic
  of first 4 tracks, name, count) with swipe delete + context menu rename/delete.
  Empty state text.
- `PlaylistDetailView(playlistID: UUID)`: header mosaic, name, count + total duration,
  PlayShuffleHeader, "Add Songs" button → `TrackPickerSheet(playlistID:)`, List of `TrackRow(track:, playlistID:)`
  with `.onDelete` / `.onMove` (EditButton), toolbar Menu Rename / Delete. Tapping row plays
  the playlist from that index.
- `TrackPickerSheet(playlistID: UUID)`: searchable multi-select list of all library tracks
  (checkmarks), "Add (n)" confirm → `library.addTracks`.
- `AddToPlaylistSheet(trackIDs: [String])`: "New Playlist…" (creates with these tracks) + list of
  existing playlists; tapping one adds and dismisses with a toast "Added to <name>".
- `SmartPlaylistView(kind: SmartPlaylistKind)` where `enum SmartPlaylistKind: String, CaseIterable, Identifiable { case favorites, recentlyAdded, mostPlayed }` (defined by D2 in `Views/Playlists/SmartPlaylistView.swift`).

Design language: clean Apple-Music-like, SF Symbols, `.accentColor` (AccentColor asset, a warm
pink-red), rounded artwork, `.listStyle(.plain)` for song lists, dynamic type friendly,
`accessibilityLabel`s on icon-only buttons. Dark mode supported automatically.
