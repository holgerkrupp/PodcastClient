import SwiftUI
import UIKit

struct HTMLView: UIViewRepresentable {
    let htmlString: String
    
    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.attributedText = attributedText(from: htmlString)
        
      //  let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        let bodyFont = UIFont.systemFont(ofSize: UIFont.systemFontSize)
        textView.font = bodyFont
        
        
        return textView
    }
    
    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.attributedText = attributedText(from: htmlString)
    }
    
    private func attributedText(from htmlString: String) -> NSAttributedString? {
        do {
            let data = htmlString.data(using: .utf8)!
            let attributedString = try NSAttributedString(data: data,
                                                          options: [.documentType: NSAttributedString.DocumentType.html,
                                                                    .characterEncoding: String.Encoding.utf8.rawValue],
                                                          documentAttributes: nil)
            return attributedString
        } catch {
            print("Error converting HTML to NSAttributedString: \(error)")
            return nil
        }
    }
}
