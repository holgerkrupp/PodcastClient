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
    var showsTitle = true
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

    private var displayedPlayPosition: Double? {
        if player.currentEpisodeURL == episode.url {
            return player.playPosition
        }

        guard episode.hasPlaybackHistory else { return nil }
        return episode.metaData?.playPosition
    }

    private func displayedChapterRows() -> [ChapterRowLayout] {
        ChapterRowLayout.rows(
            markers: displayedMarkers,
            playPosition: displayedPlayPosition,
            hasPlaybackHistory: episode.hasPlaybackHistory,
            episodeDuration: episode.duration
        )
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
        // Computed once per update and threaded through the whole body. Reading
        // any of the marker-derived properties inside the `ForEach` closure is
        // what made this view quadratic.
        let rows = displayedChapterRows()
        let showsTabPicker = hasSoundbites

        return ScrollView {
            LazyVStack(spacing: 0) {
                if showsTitle {
                    HStack {
                        Spacer()
                        Text("Chapters")
                            .font(.title)
                        Spacer()
                    }
                    .padding()
                }

#if DEBUG
                debugControls
#endif

                if showsTabPicker {
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

                if rows.isEmpty {
                    Text(emptyStateText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(rows) { row in
                        ZStack {
                            Rectangle()
                                .fill(Color.accent.opacity(0.1))
                                .scaleEffect(x: row.backgroundProgress, y: 1, anchor: .leading)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .animation(reduceMotion ? nil : .easeInOut, value: row.backgroundProgress)

                            VStack {
                                ChapterRowView(
                                    chapter: row.marker,
                                    isCurrentChapter: row.isCurrent,
                                    markerLabel: selectedTab == .soundbites ? "soundbite" : "chapter",
                                    showsPlayToggle: selectedTab != .soundbites
                                )
                                    .padding()
                                if row.isLast == false {
                                    Divider()
                                }
                            }
                        }
                    }
                }

                if let chapterInfo = rows.first?.marker.type.desc {
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

}
