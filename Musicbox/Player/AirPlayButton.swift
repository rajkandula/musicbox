import AVKit
import SwiftUI
import UIKit

/// AVRoutePickerView wrapper (AirPlay / Bluetooth output picker).
/// The glyph uses `tint`; while an external route is active it switches to the app accent color.
struct AirPlayButton: UIViewRepresentable {
    private let tint: UIColor

    init(tint: UIColor = .label) {
        self.tint = tint
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        view.backgroundColor = .clear
        view.prioritizesVideoDevices = false
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        apply(to: uiView)
    }

    /// Keeps a 44 pt tap target when the parent proposes more space (or none), but shrinks to fit
    /// an explicit smaller frame.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AVRoutePickerView, context: Context) -> CGSize? {
        CGSize(width: Self.dimension(proposal.width), height: Self.dimension(proposal.height))
    }

    private static func dimension(_ proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite, proposed > 0 else { return 44 }
        return min(proposed, 44)
    }

    private func apply(to view: AVRoutePickerView) {
        if view.tintColor != tint {
            view.tintColor = tint
        }
        let accent = UIColor(named: "AccentColor") ?? tint
        if view.activeTintColor != accent {
            view.activeTintColor = accent
        }
    }
}
