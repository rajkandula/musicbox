import AVFoundation
import SwiftUI
import UIKit

/// SwiftUI view that renders the engine's video when showVideo is on.
///
/// The view registers its AVPlayerLayer with the engine, which decides when the layer is connected
/// to the player (foreground only) and when video tracks are decoded, so audio keeps playing when
/// the app goes to the background or the screen locks.
struct PlayerVideoView: UIViewRepresentable {
    private let engine: PlayerEngine

    init(engine: PlayerEngine) {
        self.engine = engine
    }

    /// A UIView backed directly by an AVPlayerLayer, so the video resizes with the view.
    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer {
            // Safe: `layerClass` guarantees the backing layer type.
            layer as! AVPlayerLayer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        private func configure() {
            backgroundColor = .black
            clipsToBounds = true
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = UIColor.black.cgColor
            isAccessibilityElement = true
            accessibilityLabel = "Video"
            accessibilityTraits = .image
        }
    }

    @MainActor
    final class Coordinator {
        var engine: PlayerEngine

        init(engine: PlayerEngine) {
            self.engine = engine
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(engine: engine)
    }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView(frame: .zero)
        context.coordinator.engine.attachVideoLayer(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.engine !== engine else { return }
        coordinator.engine.detachVideoLayer(uiView.playerLayer)
        coordinator.engine = engine
        engine.attachVideoLayer(uiView.playerLayer)
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: Coordinator) {
        coordinator.engine.detachVideoLayer(uiView.playerLayer)
    }
}
