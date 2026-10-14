import SwiftUI
import UIKit

/// Square artwork loaded asynchronously from `ArtworkCache` (downsampled to the on-screen pixel size).
/// Falls back to a gradient placeholder whose hue is derived from the track ID, with a
/// "music.note" (or "film" for videos) symbol.
struct ArtworkView: View {
    private let trackID: String?
    private let size: CGFloat
    private let cornerRadius: CGFloat
    private let isVideo: Bool
    private let hue: Double

    @Environment(\.displayScale) private var displayScale
    @State private var loadedImage: UIImage?
    @State private var loadedTrackID: String?

    init(trackID: String?, size: CGFloat, cornerRadius: CGFloat = 6, isVideo: Bool = false) {
        self.trackID = trackID
        // Guard against NaN / infinite / negative sizes coming from geometry calculations.
        self.size = size.isFinite ? Swift.max(size, 0) : 0
        self.cornerRadius = cornerRadius.isFinite ? Swift.max(cornerRadius, 0) : 0
        self.isVideo = isVideo
        self.hue = ArtworkView.stableHue(for: trackID)
    }

    var body: some View {
        let side = size
        ZStack {
            if let loadedImage, loadedTrackID != nil {
                Image(uiImage: loadedImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                placeholder(side: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: loadKey) {
            await loadArtwork()
        }
    }

    // MARK: Loading

    /// Changes whenever the track or the requested pixel size changes.
    private var loadKey: String {
        "\(trackID ?? "-")@\(Int(pixelSize))"
    }

    private var pixelSize: CGFloat {
        let scale = displayScale > 0 ? displayScale : 2
        return Swift.min((size * scale).rounded(.up), 4096)
    }

    private func loadArtwork() async {
        guard let trackID, !trackID.isEmpty, pixelSize >= 1 else {
            loadedImage = nil
            loadedTrackID = nil
            return
        }
        // Keep showing the previous image while the next one loads (avoids a placeholder flash
        // in the mini player / now playing when the track changes).
        let image = await ArtworkCache.shared.image(for: trackID, maxPixel: pixelSize)
        guard !Task.isCancelled else { return }
        if let image {
            let animation: Animation? = loadedImage == nil ? Animation.easeOut(duration: 0.15) : nil
            withAnimation(animation) {
                loadedImage = image
                loadedTrackID = trackID
            }
        } else {
            loadedImage = nil
            loadedTrackID = nil
        }
    }

    // MARK: Placeholder

    private func placeholder(side: CGFloat) -> some View {
        let top = Color(hue: hue, saturation: 0.42, brightness: 0.88)
        let bottom = Color(hue: (hue + 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.58)
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: isVideo ? "film" : "music.note")
                    .font(.system(size: Swift.max(side * 0.38, 8), weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.12), radius: side * 0.03)
            }
    }

    /// Stable across launches (unlike `hashValue`, which is randomly seeded per process).
    private static func stableHue(for id: String?) -> Double {
        guard let id, !id.isEmpty else { return 0.95 }
        var hash: UInt64 = 5381
        for scalar in id.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return Double(hash % 360) / 360.0
    }
}
