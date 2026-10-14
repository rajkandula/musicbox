# Musicbox

A free iOS music player for the songs and videos already on your iPhone. No subscription, no ads,
no account.

Musicbox is open source (MIT) by [Harakumo](https://harakumo.com) and listed on
[Nucleus](https://nucleus.harakumo.com/-/explore).

## Features

- **Finds your music automatically**
  - Anything in *Files › On My iPhone › Musicbox* (drop files there with the Files app, Finder, or
    *Share › Musicbox* from any app).
  - Any folder you link once, such as *Downloads* or an iCloud Drive folder. New files there are
    picked up by themselves, including while the app is open.
  - Optionally, DRM-free songs you synced from a computer.
- **Formats:** MP3, M4A, AAC, WAV, AIFF, FLAC, CAF, and MP4 / M4V / MOV video files. Videos play
  **as audio by default**, like an MP3. Tap *Show Video* in Now Playing to watch.
- **Plays like a real music player**
  - Queue, shuffle, repeat (all / one), scrubbing, playback speed and a sleep timer.
  - Albums, artists, search, favourites, and Recently Added / Most Played lists.
- **Keeps playing when the phone is locked or you switch apps**, with Lock Screen, Control Center,
  headphone and AirPlay controls. After a phone call it resumes, and it pauses when you unplug
  headphones.
- **Playlists:** create, rename, reorder, and add from any song's "…" menu. They're saved on the
  device.
- **Live synced lyrics:** tap the 💬 button in Now Playing. The current line is highlighted and
  auto-scrolls, and you can tap any line to jump there. Lyrics come from, in order:
  1. a `.lrc` file next to the song (`Song.mp3` → `Song.lrc`);
  2. lyrics embedded in the file (ID3 `USLT`/`SYLT`/`TXXX:LYRICS`, iTunes `©lyr`);
  3. an optional online lookup on [LRCLIB](https://lrclib.net), a free open lyrics database. It
     is **off by default**; turn on *Find Lyrics Online* in Settings (or tap *Turn On* in the
     lyrics panel). It sends only the title, artist, album and length. Found lyrics are saved for
     offline use.

  You can shift the lyric timing ±0.5 s, import your own `.lrc` file, or mark online lyrics that
  belong to a different song as "Wrong Lyrics" so they aren't shown for it again.

## Run it on your iPhone

You need a Mac with **Xcode 26 or newer** (built with Xcode 26.6). The app targets **iOS 17.0 or
later** on iPhone and iPad. There are no third-party packages, so nothing is downloaded at build time.

1. Open `Musicbox.xcodeproj` in Xcode.
2. Select the **Musicbox** target, then **Signing & Capabilities**:
   - Tick *Automatically manage signing* and pick your own **Team** (sign in with your Apple ID
     under *Xcode › Settings › Accounts*). The project ships with no team set.
   - Change the bundle identifier `com.charanraj.musicbox` to one of your own (for example
     `com.yourname.musicbox`). Forks must use their own bundle ID and team.
3. Plug in your iPhone, choose it as the run destination, and press **Run** (⌘R).
4. On the iPhone:
   - Allow the developer certificate under *Settings › General › VPN & Device Management*.
   - Turn on *Developer Mode* under *Settings › Privacy & Security* if you're asked to.

> With a free Apple ID, apps you install yourself expire after 7 days; run it from Xcode again
> to refresh it. A paid Apple Developer account lasts a year. Neither is a subscription inside the
> app.

To check that it compiles without signing anything (Simulator build):

```sh
xcodebuild -project Musicbox.xcodeproj -scheme Musicbox \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Songs synced from a computer (*Settings › Include Music Library*) only show up on a real device;
the Simulator has no Music library.

## Privacy

Everything happens on your device. Musicbox has no account, no analytics, no ads, no tracking and no
server of its own. Your music and video files are never uploaded anywhere; the library, playlists,
play counts and settings are stored only in the app's private storage on the device.

Out of the box the app makes **no network requests**. The online lyrics lookup on
[LRCLIB](https://lrclib.net) is **off by default**. If you turn on *Find Lyrics Online* (in
Settings, or *Turn On* in the lyrics panel), then for songs without time-synced lyrics on the
device the app sends LRCLIB, over HTTPS, just that song's title, artist, album and length, with a
`Musicbox/1.0` user agent; never the audio, the file, or anything about you. Like any web request
it reaches LRCLIB from your IP address. Turn the setting off again and the app stops making network
requests (lookups already running are stopped too).

## Good to know (iOS rules)

- iOS doesn't let any app scan the whole phone. Musicbox sees its own folder, any folders you link,
  and (if you allow it) your synced Music library.
- Music keeps playing in the background and on the Lock Screen. If you **swipe the app away** in
  the app switcher, iOS stops it; that's true for every music app.
- Songs from an Apple Music subscription are DRM-protected and can't be played by other apps.

## Project layout

```
Musicbox/
  App/         entry point, per-window router
  Models/      Track, Playlist, settings, albums/artists
  Services/    LibraryStore (scan/merge/persist), file & folder scanning, bookmarks,
               metadata/artwork, imports, folder watchers
  Player/      PlayerEngine (AVPlayer, queue, background audio, remote commands,
               Now Playing info, state restore), video layer, AirPlay
  Lyrics/      LRC/SYLT parsing, embedded lyrics, LRCLIB client, lyrics store & cache
  Views/       Library, Search, Playlists, Settings, Now Playing, mini player, lyrics
SPEC.md         architecture contract
LYRICS_SPEC.md  lyrics feature contract
```

The project has no third-party dependencies. Every `.swift` file under `Musicbox/` is compiled
automatically, because the project uses Xcode's synchronized folders.

## License

[MIT](LICENSE) © 2026 Charan Raj Kandula
