import SwiftUI

/// Compact player bar shown above the tab bar while a session is active.
/// Tap (or swipe up) to open the full Now Playing sheet.
struct MiniPlayerView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppRouter.self) private var router

    private let cornerRadius: CGFloat = 14

    init() {}

    var body: some View {
        if let track = player.currentTrack {
            bar(for: track)
        }
    }

    // MARK: Layout

    private func bar(for track: Track) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        return HStack(spacing: 2) {
            Button {
                openNowPlaying()
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(trackID: track.id, size: 44, cornerRadius: 8, isVideo: track.isVideo)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(PlayerUIText.subtitle(for: track))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing: \(track.title), \(track.displayArtist)")
            .accessibilityHint("Opens the full player")

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.2), value: player.isPlaying)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MiniPlayerButtonStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MiniPlayerButtonStyle())
            .accessibilityLabel("Next Track")
        }
        .foregroundStyle(.primary)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 64)
        .background(.regularMaterial, in: shape)
        .overlay(alignment: .bottom) {
            MiniPlayerProgressLine()
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, x: 0, y: 3)
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 14)
                .onEnded { value in
                    let isUpwardSwipe = value.translation.height < -24
                        && abs(value.translation.height) > abs(value.translation.width)
                    if isUpwardSwipe {
                        openNowPlaying()
                    }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Open Now Playing")) {
            openNowPlaying()
        }
    }

    private func openNowPlaying() {
        router.isNowPlayingPresented = true
    }
}

// MARK: - Progress

/// Thin progress line along the bottom edge. Reads `currentTime` in its own body so the
/// twice-per-second time updates only re-render this small view.
private struct MiniPlayerProgressLine: View {
    @Environment(PlayerEngine.self) private var player

    var body: some View {
        let duration = player.duration
        let time = player.currentTime
        let progress: Double = (duration.isFinite && duration > 0 && time.isFinite)
            ? min(max(time / duration, 0), 1)
            : 0

        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * CGFloat(progress))
                    .animation(.linear(duration: 0.5), value: progress)
            }
        }
        .frame(height: 2.5)
        .accessibilityHidden(true)
    }
}

// MARK: - Button style

private struct MiniPlayerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
