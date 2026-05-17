//
//  ChapterListView.swift
//  PodcastClient
//
//  Created by Holger Krupp on 23.01.24.
//

import SwiftUI
import SwiftData

enum ChapterDisplaySelection: String, CaseIterable, Identifiable {
    case automatic
    case mp3
    case mp4
    case podlove
    case ai
    case extracted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            "Automatic"
        case .mp3:
            "MP3"
        case .mp4:
            "MP4"
        case .podlove:
            "Podlove"
        case .ai:
            "AI"
        case .extracted:
            "Extracted"
        }
    }

    var markerType: MarkerType? {
        switch self {
        case .automatic:
            nil
        case .mp3:
            .mp3
        case .mp4:
            .mp4
        case .podlove:
            .podlove
        case .ai:
            .ai
        case .extracted:
            .extracted
        }
    }
}

private enum ChapterListTab: String, CaseIterable, Identifiable {
    case chapters
    case soundbites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chapters:
            "Chapters"
        case .soundbites:
            "Soundbites"
        }
    }
}

struct ChapterListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var player = Player.shared

    @Bindable var episode: Episode
    @State private var selectedTab: ChapterListTab = .chapters

#if DEBUG
    @AppStorage("ChapterListView.debugChapterSource") private var debugChapterSourceRaw = ChapterDisplaySelection.automatic.rawValue
#endif

    private var selectedChapterSource: ChapterDisplaySelection {
#if DEBUG
        ChapterDisplaySelection(rawValue: debugChapterSourceRaw) ?? .automatic
#else
        .automatic
#endif
    }

    private var sortedChapters: [Marker] {
        episode.chaptersForDisplay(preferredType: selectedChapterSource.markerType)
    }

    private var sortedSoundbites: [Marker] {
        episode.soundbitesForDisplay
    }

    private var displayedMarkers: [Marker] {
        switch selectedTab {
        case .chapters:
            sortedChapters
        case .soundbites:
            sortedSoundbites
        }
    }

    private var hasSoundbites: Bool {
        sortedSoundbites.isEmpty == false
    }

    private var currentDisplayedChapter: Marker? {
        displayedMarkers.last(where: { ($0.start ?? 0) <= player.playPosition })
    }

    private var emptyStateText: String {
        if selectedTab == .soundbites {
            return "No soundbites to display"
        }

        if selectedChapterSource == .automatic {
            return "No chapters to display"
        } else {
            return "No \(selectedChapterSource.title.lowercased()) chapters available"
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("Chapters")
                        .font(.title)
                    Spacer()
                }
                .padding()

#if DEBUG
                debugControls
#endif

                if hasSoundbites {
                    Picker("Marker type", selection: $selectedTab) {
                        ForEach(ChapterListTab.allCases) { tab in
                            Text(tab.title)
                                .tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .accessibilityLabel("Chapter list tab")
                }

                if displayedMarkers.isEmpty {
                    Text(emptyStateText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(displayedMarkers, id: \.id) { chapter in
                        let isCurrentChapter = chapter.id == currentDisplayedChapter?.id
                        let backgroundProgress = chapterBackgroundProgress(for: chapter)

                        ZStack {
                            Rectangle()
                                .fill(Color.accent.opacity(0.1))
                                .scaleEffect(x: backgroundProgress, y: 1, anchor: .leading)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .animation(reduceMotion ? nil : .easeInOut, value: backgroundProgress)

                            VStack {
                                ChapterRowView(
                                    chapter: chapter,
                                    isCurrentChapter: isCurrentChapter,
                                    markerLabel: selectedTab == .soundbites ? "soundbite" : "chapter",
                                    showsPlayToggle: selectedTab != .soundbites
                                )
                                    .padding()
                                if chapter.id != displayedMarkers.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                if let chapterInfo = displayedMarkers.first?.type.desc {
                    Spacer()
                    Text(chapterInfo)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding()
                }
            }
        }
        .onAppear {
            if sortedChapters.isEmpty, hasSoundbites {
                selectedTab = .soundbites
            }
        }
    }

#if DEBUG
    private var debugControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chapter source")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("Chapter source", selection: $debugChapterSourceRaw) {
                    ForEach(ChapterDisplaySelection.allCases) { selection in
                        Text(selection.title)
                            .tag(selection.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }

            Divider()
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
#endif

    private func chapterBackgroundProgress(for chapter: Marker) -> Double {
        guard chapter.id == currentDisplayedChapter?.id else {
            return chapter.progress ?? 0.0
        }

        guard let chapterStart = chapter.start else { return 0.0 }
        let chapterEnd = endTime(for: chapter)
        guard chapterEnd > chapterStart else { return 0.0 }

        let clampedPosition = min(max(player.playPosition, chapterStart), chapterEnd)
        return (clampedPosition - chapterStart) / (chapterEnd - chapterStart)
    }

    private func endTime(for chapter: Marker) -> Double {
        if let end = chapter.end {
            return end
        }

        guard let chapterIndex = displayedMarkers.firstIndex(where: { $0.id == chapter.id }) else {
            return episode.duration ?? chapter.start ?? 0
        }

        if let nextChapter = displayedMarkers.dropFirst(chapterIndex + 1).first,
           let nextStart = nextChapter.start {
            return nextStart
        }

        return episode.duration ?? chapter.start ?? 0
    }
}
