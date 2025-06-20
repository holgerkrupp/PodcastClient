//
//  TimeLineViewModel.swift
//  Raul
//
//  Created by Holger Krupp on 16.06.25.
//

import Foundation
import SwiftData
import Combine
import SwiftUI



class TimelineViewModel: ObservableObject {
    private var modelContext: ModelContext

    private var historyEpisodes: [Episode] = []
    private var playlistEntries: [PlaylistEntry] = []
   

    private var nowPlayingEpisode: Episode?
    @Published var nowPlayingID: UUID? {
        didSet {
            withAnimation(.spring()) {
                rebuildTimeline()
            }
        }
    }
    
    @Published var timelineItems: [TimelineItem] = []

    @Published var isNowPlayingExpanded: Bool = true

    init(modelContext: ModelContext,
         historyEpisodes: [Episode],
         playlistEntries: [PlaylistEntry]) {
        self.modelContext = modelContext
        self.historyEpisodes = historyEpisodes
        self.playlistEntries = playlistEntries
        loadNowPlayingIDFromUserDefaults()
        rebuildTimeline()
    }

    func updateData(historyEpisodes: [Episode], playlistEntries: [PlaylistEntry]) {
        print("updateData")
        self.historyEpisodes = historyEpisodes
        self.playlistEntries = playlistEntries
        rebuildTimeline()
    }

 

    
    private func loadNowPlayingIDFromUserDefaults() {
        if let idString = UserDefaults.standard.string(forKey: "lastPlayedEpisodeID"),
           let uuid = UUID(uuidString: idString) {
            self.nowPlayingID = uuid
            do {
                nowPlayingEpisode = try modelContext.fetch(
                    FetchDescriptor<Episode>(predicate: #Predicate { $0.id == uuid })
                ).first
            } catch {
                print("Failed to fetch nowPlaying episode: \(error)")
                nowPlayingEpisode = nil
            }
        } else {
            nowPlayingEpisode = nil
        }
    }
    


    func rebuildTimeline() {
       
        var items: [TimelineItem] = []

        let played = historyEpisodes
            .filter { $0.id != nowPlayingID }
            .map { TimelineItem.played($0) }

        // Now Playing
        if let nowPlaying = nowPlayingEpisode {
            items.append(TimelineItem.nowPlaying(nowPlaying))
        }

        

        let nowPlaying: [TimelineItem] = nowPlayingEpisode.map { [.nowPlaying($0)] } ?? []

        let queued = playlistEntries
            .compactMap { $0.episode }
            .filter { $0.id != nowPlayingID }
            .map { TimelineItem.queued($0) }

        items = played + nowPlaying + queued

        withAnimation {
            timelineItems = items
        }
    }

    func moveItems(from source: IndexSet, to destination: Int) {
        print("move items from \(source) to \(destination)")
        guard let firstQueuedIndex = timelineItems.firstIndex(where: { $0.isQueued }) else { return }
        let queueRange = timelineItems[firstQueuedIndex...].enumerated().map { $0.offset + firstQueuedIndex }

        guard source.allSatisfy({ queueRange.contains($0) }) && queueRange.contains(destination) else {
            return
        }

        var currentQueue = playlistEntries
        var reordered = currentQueue.map { $0 }
        
        print("move translates to \(IndexSet(source.map { $0 - firstQueuedIndex })), \(destination - firstQueuedIndex)")
        
        
        reordered.move(fromOffsets: IndexSet(source.map { $0 - firstQueuedIndex }),
                        toOffset: destination - firstQueuedIndex)

        for (index, entry) in reordered.enumerated() {
            entry.order = index
        }

        modelContext.saveIfNeeded()
        rebuildTimeline()
    }
}

// MARK: - TimelineItem Enum

enum TimelineItem: Identifiable, Equatable {
    case played(Episode)
    case nowPlaying(Episode)
    case queued(Episode)

    var id: UUID {
        switch self {
        case .played(let ep), .nowPlaying(let ep), .queued(let ep):
            return ep.id
        }
    }

    var episode: Episode {
        switch self {
        case .played(let ep), .nowPlaying(let ep), .queued(let ep):
            return ep
        }
    }

    var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }
}
