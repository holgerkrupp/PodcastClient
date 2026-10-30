//
//  ChapterModelActor.swift
//  Raul
//
//  Created by Holger Krupp on 05.05.25.
//


import SwiftData
import Foundation



@ModelActor
actor ChapterModelActor {
    func fetchChapter(byID chapterID: UUID) async -> Marker? {
        let predicate = #Predicate<Marker> { chapter in
            chapter.uuid == chapterID
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<Marker>(predicate: predicate))
            return results.first
        } catch {
            // print("❌ Error fetching episode for Chapter ID: \(chapterID), Error: \(error)")
            return nil
        }
    }
    
    func shouldPlayChapter(_ chapterID: UUID) async -> Bool {
        guard let chapter = await fetchChapter(byID: chapterID) else { return false }
        return chapter.shouldPlay
    }
    
    func markChapterAsSkipped(_ chapterID: UUID) async {
        guard let chapter = await fetchChapter(byID: chapterID) else { return }
        
        chapter.didSkip = true
        modelContext.saveIfNeeded()
    }

    func setShouldPlay(_ shouldPlay: Bool, for chapterID: UUID) async {
        guard let chapter = await fetchChapter(byID: chapterID) else { return }

        chapter.shouldPlay = shouldPlay
        modelContext.saveIfNeeded()
        requestCacheProjection(for: chapter)
    }
    
    func setChapterProgress(_ progress: Double, for chapterID: UUID) async {
        guard let chapter = await fetchChapter(byID: chapterID) else { return }
        
        chapter.progress = progress
       modelContext.saveIfNeeded()
        requestCacheProjection(
            for: chapter,
            delay: StoreSplitFeedCacheWriter.playbackProjectionInterval
        )
    }

    private func requestCacheProjection(
        for chapter: Marker,
        delay: TimeInterval = StoreSplitFeedCacheWriter.projectionDebounce
    ) {
        guard let episode = chapter.episode else { return }
        StoreSplitFeedCacheWriter.requestProjection(for: episode, delay: delay)
    }
    
    func saveAllChanges() async {
        // print("saving Chapter Progress")
        modelContext.saveIfNeeded()
    }
    
}
