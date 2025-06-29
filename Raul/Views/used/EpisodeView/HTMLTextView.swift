import SwiftUI

struct HTMLTextView: View {
    let attributedString: AttributedString

    init(html: String) {
        self.attributedString = HTMLTextView.parse(html: html) ?? AttributedString("Invalid HTML")
    }

    var body: some View {
        Text(attributedString)
    }

     static func parse(html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        do {
            let nsAttr = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            ).removingColorAttributes()
            return try AttributedString(nsAttr, including: \.uiKit)
        } catch {
            print("HTML parse error: \(error)")
            return nil
        }
    }
}

extension NSAttributedString {
    func removingColorAttributes() -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: self)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(.foregroundColor, range: fullRange)
        return mutable
    }
}
