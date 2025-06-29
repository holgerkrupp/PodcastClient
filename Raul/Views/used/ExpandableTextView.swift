//
//  ExpandableTextView.swift
//  Raul
//
//  Created by Holger Krupp on 07.05.25.
//
import SwiftUI

struct ExpandableTextView: View {
    @State private var isExpanded = false
    @Environment(\.lineLimit) private var externalLineLimit
    @State private var attributedHTML: AttributedString?

    var text: String
    
    var body: some View {
        VStack {
       //     Text(text)
            Group {
                if let attributed = attributedHTML {
                    Text(attributed)
                        .lineLimit(isExpanded ? nil : externalLineLimit) // Use the maxLines parameter

                } else {
                    Text("Loading...")
                }
            }
            .task {
                if attributedHTML == nil {
                    attributedHTML = HTMLTextView.parse(html: text)
                }
            }
            
            if text.count > 100 { // Optional: only show "Read More" if the text is long enough
                Button(action: {
                    isExpanded.toggle()
                }) {
                    Text(isExpanded ? "Show Less" : "Show More")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.top, 5)
                }
            }
        }
    }
}
