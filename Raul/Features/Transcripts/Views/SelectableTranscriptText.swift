import SwiftUI

#if canImport(UIKit)
import UIKit

/// Keeps UIKit's selection intact while playback changes the highlighted span.
struct SelectableTranscriptText: UIViewRepresentable {
    let segment: TranscriptSegment
    let active: TranscriptPlaybackTracker.Active?
    let underlineForSearch: Bool
    let onSelectionChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelectionChange: onSelectionChange) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onSelectionChange = onSelectionChange
        guard view.selectedRange.length == 0 else { return }
        let font = UIFont.preferredFont(forTextStyle: .body)
        let value = NSMutableAttributedString(string: segment.text, attributes: [.font: font, .foregroundColor: UIColor.label])
        if underlineForSearch {
            value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: value.length))
        }
        if active?.segmentID == segment.id, let location = active?.location, let length = active?.length,
           location >= 0, length > 0, location <= value.length, length <= value.length - location,
           Range(NSRange(location: location, length: length), in: segment.text) != nil {
            let range = NSRange(location: location, length: length)
            let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
            value.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
            value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        if view.attributedText != value { view.attributedText = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSelectionChange: (Bool) -> Void
        private var wasSelected = false
        init(onSelectionChange: @escaping (Bool) -> Void) { self.onSelectionChange = onSelectionChange }
        func textViewDidChangeSelection(_ textView: UITextView) {
            let hasSelection = textView.selectedRange.length > 0
            guard hasSelection != wasSelected else { return }
            wasSelected = hasSelection
            DispatchQueue.main.async { [weak self] in self?.onSelectionChange(hasSelection) }
        }
    }
}
#endif
