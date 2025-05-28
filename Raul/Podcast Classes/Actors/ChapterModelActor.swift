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
    func fetchChapter(byID chapterID: UUID) async -> Chapter? {
        let predicate = #Predicate<Chapter> { chapter in
            chapter.id == chapterID
        }

        do {
            let results = try modelContext.fetch(FetchDescriptor<Chapter>(predicate: predicate))
            return results.first
        } catch {
            print("❌ Error fetching episode for Chapter ID: \(chapterID), Error: \(error)")
            return nil
        }
    }
    
    func markChapterAsSkipped(_ chapterID: UUID) async {
        guard let chapter = await fetchChapter(byID: chapterID) else { return }
        
        chapter.didSkip = true
        modelContext.saveIfNeeded()
    }
    
    func setChapterProgress(_ progress: Double, for chapterID: UUID) async {
        guard let chapter = await fetchChapter(byID: chapterID) else { return }
        
        chapter.progress = progress
       modelContext.saveIfNeeded()
    }
    
    func saveAllChanges() async {
        print("saving Chapter Progress")
        modelContext.saveIfNeeded()
    }
    
}
