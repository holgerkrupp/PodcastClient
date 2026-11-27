//
//  VerticalBarProbe.swift
//  Raul
//
//  Reports where the iPhone Duo places its vertical bar (status bar,
//  toolbars and tab bars on the side; HIG "Designing for iPhone Duo",
//  Vertical controls), so the player can move its pinned transport into
//  that strip while scrolling. SwiftUI has no equivalent of
//  UITraitCollection.verticalBarEdge (iOS 27.1), so a tiny non-interactive
//  UIKit view reads it.
//

import SwiftUI

/// Where the vertical bar sits for a view. `edge == nil` means no vertical bar:
/// standard iPhones, the Duo's inner display in portrait, iPad and Mac.
struct VerticalBarPlacement: Equatable {
    enum Edge: Equatable { case leading, trailing }

    var edge: Edge?

    static let none = VerticalBarPlacement(edge: nil)

    /// Height at the top of the vertical bar that the system keeps for the
    /// outer camera, time and connectivity symbols. UIKit exposes no layout
    /// guide for them (`statusBarFrame` is a 2 pt strip on iPhone Duo), so
    /// custom controls in the bar stay below this measured height.
    static let reservedStatusHeight: CGFloat = 170
}

#if os(iOS)
import UIKit

struct VerticalBarProbe: UIViewRepresentable {
    @Binding var placement: VerticalBarPlacement

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = { placement = $0 }
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = { placement = $0 }
    }

    final class ProbeView: UIView {
        var onChange: ((VerticalBarPlacement) -> Void)?
        private var lastReported: VerticalBarPlacement?

        override init(frame: CGRect) {
            super.init(frame: frame)
            if #available(iOS 27.1, *) {
                registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (view: ProbeView, _: UITraitCollection) in
                    view.scheduleReport()
                }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleReport()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleReport()
        }

        /// Reported on the next main-queue turn so SwiftUI state never changes
        /// during its own view update.
        private func scheduleReport() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                let placement = self.currentPlacement()
                guard placement != self.lastReported else { return }
                self.lastReported = placement
                self.onChange?(placement)
            }
        }

        private func currentPlacement() -> VerticalBarPlacement {
            var edge: VerticalBarPlacement.Edge?
            if #available(iOS 27.1, *) {
                switch traitCollection.verticalBarEdge {
                case .leading: edge = .leading
                case .trailing: edge = .trailing
                default: edge = nil
                }
            }
            return VerticalBarPlacement(edge: edge)
        }
    }
}
#endif
