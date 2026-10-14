import SwiftUI
import UIKit

/// Settings tab: music sources, library options, playback info, help and about.
struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LyricsStore.self) private var lyrics
    @Environment(AppRouter.self) private var router
    @Environment(\.openURL) private var openURL

    @State private var isPickingFolder = false
    @State private var isImportingFiles = false
    @State private var folderPendingRemoval: LinkedFolder?
    @State private var isRequestingMusicAccess = false
    @State private var isShowingMusicAccessDenied = false
    @State private var isConfirmingClearLyrics = false

    private static let minimumDurationOptions: [(label: String, seconds: TimeInterval)] = [
        ("Off", 0),
        ("10 seconds", 10),
        ("30 seconds", 30),
        ("60 seconds", 60),
    ]

    var body: some View {
        @Bindable var library = library
        @Bindable var lyrics = lyrics

        Form {
            sourcesSection
            librarySection(includeVideos: $library.settings.includeVideos, minimumDuration: $library.settings.minimumDuration)
            playbackSection
            lyricsSection(onlineLookup: $lyrics.onlineLookupEnabled)
            howToSection
            aboutSection
        }
        .navigationTitle("Settings")
        .musicSourceImporters(isPickingFolder: $isPickingFolder, isImportingFiles: $isImportingFiles)
        .confirmationDialog(
            removalTitle,
            isPresented: removalBinding,
            titleVisibility: .visible,
            presenting: folderPendingRemoval
        ) { folder in
            Button("Remove Folder", role: .destructive) {
                library.removeFolder(folder.id)
                router.showToast("Removed “\(folder.displayName)”")
                folderPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                folderPendingRemoval = nil
            }
        } message: { folder in
            Text(removalMessage(for: folder))
        }
        .alert("Music Library Access", isPresented: $isShowingMusicAccessDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("To include songs synced to this iPhone from your computer, allow Musicbox to access Media & Apple Music in Settings.")
        }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        Section {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "iphone", color: .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("On My iPhone")
                    Text("Files app › On My iPhone › Musicbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(LibraryFormatting.songCount(library.documentsTrackCount))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            if library.settings.includeMusicLibrary {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "music.note", color: .pink)
                    Text("Music Library")
                    Spacer(minLength: 8)
                    Text(LibraryFormatting.songCount(library.musicLibraryTrackCount))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            ForEach(library.folders) { folder in
                LinkedFolderRow(folder: folder)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            folderPendingRemoval = folder
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            folderPendingRemoval = folder
                        } label: {
                            Label("Remove Folder", systemImage: "trash")
                        }
                    }
            }

            Button {
                isPickingFolder = true
            } label: {
                Label("Link a Folder…", systemImage: "folder.badge.plus")
            }

            Button {
                isImportingFiles = true
            } label: {
                Label("Import Files…", systemImage: "square.and.arrow.down")
            }

            Button {
                Task { @MainActor in
                    guard !library.isScanning else { return }
                    await library.rescan()
                    if library.lastErrorMessage == nil {
                        router.showToast("Library Updated")
                    }
                }
            } label: {
                HStack {
                    Label("Rescan Now", systemImage: "arrow.clockwise")
                    Spacer()
                    if library.isScanning {
                        ProgressView()
                    }
                }
            }
            .disabled(library.isScanning)
        } header: {
            Text("Sources")
        } footer: {
            SettingsScanStatusFooter()
        }
    }

    // MARK: Library

    private func librarySection(includeVideos: Binding<Bool>, minimumDuration: Binding<TimeInterval>) -> some View {
        Section {
            HStack {
                Toggle(isOn: musicLibraryBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include Music Library")
                        Text("Songs synced from a computer (DRM-free only)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isRequestingMusicAccess)

                if isRequestingMusicAccess {
                    ProgressView()
                        .padding(.leading, 6)
                }
            }

            Toggle(isOn: includeVideos) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include Videos")
                    Text("MP4, MOV and M4V files, played as audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker(selection: minimumDuration) {
                ForEach(Self.minimumDurationOptions, id: \.seconds) { option in
                    Text(option.label).tag(option.seconds)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skip Short Clips")
                    Text("Hide voice notes and ringtones")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Library")
        } footer: {
            Text("New files in linked folders are picked up automatically, also while Musicbox is open. Pull down in the Library to check right away.")
        }
    }

    private var musicLibraryBinding: Binding<Bool> {
        Binding(
            get: { library.settings.includeMusicLibrary },
            set: { isOn in
                if isOn {
                    guard !isRequestingMusicAccess else { return }
                    isRequestingMusicAccess = true
                    Task { @MainActor in
                        let granted = await library.requestMusicLibraryAccessAndEnable()
                        isRequestingMusicAccess = false
                        if granted {
                            router.showToast("Music Library Included")
                        } else {
                            isShowingMusicAccessDenied = true
                        }
                    }
                } else {
                    library.settings.includeMusicLibrary = false
                }
            }
        )
    }

    // MARK: Playback

    private var playbackSection: some View {
        Section {
            SettingsInfoRow(
                systemName: "film",
                color: .purple,
                title: "Videos play as audio by default",
                detail: "Open Now Playing and tap Show Video to watch."
            )
            SettingsInfoRow(
                systemName: "lock.fill",
                color: .gray,
                title: "Keeps playing in the background",
                detail: "Music continues when you lock your iPhone or switch apps. Use the Lock Screen, Control Center or your headphones to control it."
            )
        } header: {
            Text("Playback")
        }
    }

    // MARK: Lyrics

    private func lyricsSection(onlineLookup: Binding<Bool>) -> some View {
        Section {
            Toggle(isOn: onlineLookup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find Lyrics Online")
                    Text("Live, time-synced lyrics from LRCLIB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(role: .destructive) {
                isConfirmingClearLyrics = true
            } label: {
                HStack {
                    Text("Clear Saved Lyrics")
                    Spacer()
                    if lyrics.cachedCount > 0 {
                        Text("\(lyrics.cachedCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(lyrics.cachedCount == 0)
            .confirmationDialog(
                "Clear Saved Lyrics?",
                isPresented: $isConfirmingClearLyrics,
                titleVisibility: .visible
            ) {
                Button("Clear Lyrics", role: .destructive) {
                    lyrics.clearCache()
                    router.showToast("Saved lyrics cleared")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every saved lyric, including .lrc files you imported and timing adjustments, and forgets lyrics you marked as wrong. Lyrics next to your songs or inside the files are not affected.")
            }
        } header: {
            Text("Lyrics")
        } footer: {
            Text("Tap the lyrics button in Now Playing to sing along. Musicbox first uses .lrc files next to your songs (Song.mp3 → Song.lrc) and lyrics inside the files. When Find Lyrics Online is on, it asks LRCLIB — a free, open lyrics library — using only the song’s title, artist, album and length. No account, no subscription. Your music files never leave your iPhone, and found lyrics are saved for offline use.")
        }
    }

    // MARK: How to add music

    private var howToSection: some View {
        Section {
            SettingsInfoRow(
                systemName: "folder.fill",
                color: .blue,
                title: "Link your Downloads or iCloud Drive folder",
                detail: "Tap Link a Folder… once. New songs saved there are detected automatically."
            )
            SettingsInfoRow(
                systemName: "doc.on.doc.fill",
                color: .teal,
                title: "Use the Files app",
                detail: "Copy music to On My iPhone › Musicbox › Music."
            )
            SettingsInfoRow(
                systemName: "square.and.arrow.up.fill",
                color: .orange,
                title: "Share from any app",
                detail: "On any audio or video file, tap Share › Musicbox (or Open in Musicbox)."
            )
            SettingsInfoRow(
                systemName: "desktopcomputer",
                color: .indigo,
                title: "From your computer",
                detail: "Connect your iPhone and drag files onto Musicbox under Files in Finder (or iTunes on Windows)."
            )
        } header: {
            Text("How to Add Music")
        } footer: {
            Text("Supported: MP3, M4A, AAC, WAV, AIFF, FLAC, ALAC, CAF, and MP4, M4V, MOV videos.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.appVersion)
            VStack(alignment: .leading, spacing: 6) {
                Text("Musicbox \(Self.shortVersion) — Free forever.")
                    .font(.headline)
                Text("No subscription, no ads, no account. Your music files never leave your device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        } header: {
            Text("About")
        }
    }

    private static var shortVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    private static var appVersion: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, !build.isEmpty, build != shortVersion {
            return "\(shortVersion) (\(build))"
        }
        return shortVersion
    }

    // MARK: Folder removal

    private var removalTitle: String {
        if let folder = folderPendingRemoval {
            return "Remove “\(folder.displayName)”?"
        }
        return "Remove Folder?"
    }

    /// Only promises the 30-day restore when the library can recognise the folder again.
    private func removalMessage(for folder: LinkedFolder) -> String {
        if library.canRestoreFolderAfterRemoval(folder.id) {
            return "Its songs are removed from your library, but the files themselves are not deleted. Link the same folder again within 30 days to get its songs back in your playlists, with their favorites and play counts."
        }
        return "Its songs are removed from your library, but the files themselves are not deleted. Musicbox can’t tell where this folder was, so linking it again adds its songs as new ones, without their favorites and play counts."
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { folderPendingRemoval != nil },
            set: { isPresented in
                if !isPresented { folderPendingRemoval = nil }
            }
        )
    }
}

// MARK: - Rows

private struct LinkedFolderRow: View {
    let folder: LinkedFolder

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: "folder.fill", color: folder.isAvailable ? .cyan : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let lastScan = folder.lastScanAt {
                    Text("Scanned \(lastScan, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if folder.isAvailable {
                Text(LibraryFormatting.songCount(folder.trackCount))
                    .foregroundStyle(.secondary)
            } else {
                Text("Unavailable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Swipe left to remove this folder")
    }
}

private struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

private struct SettingsInfoRow: View {
    let systemName: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(systemName: systemName, color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Scan progress / last-scan time. Separate view so frequent `scanStatus` updates only
/// re-render this footer.
private struct SettingsScanStatusFooter: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if library.isScanning {
            Text(library.scanStatus ?? "Scanning…")
        } else if let lastScan = library.lastScanDate {
            Text("Last scanned \(lastScan, format: .relative(presentation: .named)).")
        } else {
            Text("Musicbox scans your sources each time you open it.")
        }
    }
}
