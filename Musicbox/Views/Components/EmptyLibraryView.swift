import SwiftUI

/// Onboarding shown when the library has no songs yet: explains the three ways to add music.
struct EmptyLibraryView: View {
    private let onLinkFolder: () -> Void
    private let onImportFiles: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var isShowingFilesHelp = false

    init(onLinkFolder: @escaping () -> Void, onImportFiles: @escaping () -> Void) {
        self.onLinkFolder = onLinkFolder
        self.onImportFiles = onImportFiles
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                VStack(alignment: .leading, spacing: 18) {
                    EmptyLibraryTipRow(
                        number: 1,
                        title: "Link a folder",
                        text: "Link your Downloads or iCloud Drive folder once — new songs are detected automatically."
                    )
                    EmptyLibraryTipRow(
                        number: 2,
                        title: "Import files",
                        text: "Pick MP3, M4A, MP4 and other audio or video files to copy into Musicbox."
                    )
                    EmptyLibraryTipRow(
                        number: 3,
                        title: "Use the Files app or Share",
                        text: "In the Files app, copy music to On My iPhone › Musicbox › Music, or use Share › Musicbox from any app."
                    )
                }
                .frame(maxWidth: 480, alignment: .leading)

                VStack(spacing: 12) {
                    Button(action: onLinkFolder) {
                        Label("Link a Folder…", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: onImportFiles) {
                        Label("Import Files…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button("How to use the Files app") {
                        isShowingFilesHelp = true
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .padding(.top, 2)
                }
                .font(.headline)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .frame(maxWidth: 420)

                Text("Free forever. No subscription, no ads, no account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .alert("Using the Files app", isPresented: $isShowingFilesHelp) {
            Button("Open Files") { openFilesApp() }
            Button("OK", role: .cancel) {}
        } message: {
            Text("1. Open the Files app.\n2. Go to On My iPhone › Musicbox › Music.\n3. Copy or move your songs there.\n\nMusicbox finds them automatically the next time you open it — or pull down in the Library to refresh.")
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 16, y: 6)
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            Text("Your library is empty")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Musicbox plays the music and videos already on your iPhone — offline, in the background and on the Lock Screen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    /// Opens the Files app at the app's Music folder (falls back silently if unsupported).
    private func openFilesApp() {
        let path = AppPaths.musicFolder.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        if let url = URL(string: "shareddocuments://" + encoded) {
            openURL(url)
        }
    }
}

private struct EmptyLibraryTipRow: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.bold())
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
