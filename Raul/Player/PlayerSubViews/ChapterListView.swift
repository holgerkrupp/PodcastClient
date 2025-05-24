//
//  ChapterListView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 23.01.24.
//

import SwiftUI

struct ChapterListView: View {
    var player = Player.shared
    var chapters: [Chapter]
    
    private var sortedChapters: [Chapter] {
        chapters.sorted(by: { first, second in
            first.start ?? 0.0 < second.start ?? 0
        })
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                HStack {
                    Spacer()
                    Text("Chapters")
                        .font(.title)
                        .padding()
                    Spacer()
                    Text(chapters.first?.type.rawValue ?? "Unknown")
                        .font(.caption)
                }
                .padding()
               
                
                ForEach(sortedChapters, id: \.id) { chapter in
                   
                         ChapterRowView(chapter: chapter)
                        if chapter.id != sortedChapters.last?.id {
                            Divider()
                                .padding(.horizontal)
                        }
                    
                   
                }
            }
        }
    }
}

#Preview {
    let sampleChapters = [
        Chapter(start: 5651.469, title: "Epilog", type: .mp3, duration: 226.507),
        Chapter(start: 31.319, title: "Prolog", duration: 175.654),
        Chapter(start: 0.0, title: "Intro", duration: 31.319),
        Chapter(start: 4849.457, title: "Palantir", duration: 461.69),
        Chapter(start: 4357.445, title: "Open Technology Fund", duration: 321.905),
        Chapter(start: 5311.147, title: "Altersverifikation", duration: 340.322),
        Chapter(start: 206.973, title: "Feedback: Propaganda", duration: 159.488),
        Chapter(start: 1042.935, title: "Signalgate", duration: 1607.82),
        Chapter(start: 4679.35, title: "Chatkontrolle", duration: 82.117),
        Chapter(start: 642.922, title: "Feedback: Digitalministerium", duration: 400.013),
        Chapter(start: 2650.755, title: "Informationsfreiheitsgesetz", duration: 1706.69),
        Chapter(start: 366.461, title: "Feedback: Isländische Fussballmannschaft", duration: 152.857),
        Chapter(start: 4761.467, title: "CDU und AfD in Umfragen gleichauf", duration: 87.99),
        Chapter(start: 519.318, title: "Feedback: Leuchttürme", duration: 123.604)
    ]
    
    
    ChapterListView(chapters: sampleChapters)
}
