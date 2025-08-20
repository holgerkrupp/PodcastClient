//
//  AIChapter.swift
//  Raul
//
//  Created by Holger Krupp on 24.06.25.
//

import Foundation
import FoundationModels

actor AIChapterGenerator{
    
    
    
    @Generable(description: "Extracted Chapters")
    struct AIChapter {
        // A guide isn't necessary for basic fields.
        var title: String
        
        @Guide(description: "The timecode of the chapter in the format hh:mm:ss")
        var timecode: String
    }
    
    func extractChaptersFromText(_ text: String) async -> [String:String] {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return [:]
        }
            do{
                let options = GenerationOptions(temperature: 2.0)
                
                
                let instructions = """
                   If the following text might contain time codes (in the format 00:00 or 00:00:00) and titles, please extract them and format them as chapters. If the text does not conatin time codes, return an empty dictionary.
                """
                let session = LanguageModelSession(instructions: instructions)
                
                let prompt = text
                let response = try await session.respond(
                    to: prompt,
                    generating: [AIChapter].self,
                    options: options
                )
                return Dictionary<String, String>(response.content.compactMap { $0 }.map { ($0.timecode, $0.title) }, uniquingKeysWith: { first, _ in return first })
                
            }
            catch{
                // print("Error: \(error)")
                return [:]
            }
        }
    
    func createChaptersFromTranscriptLines(_ lines: String) async -> [String:String] {
        
        
        
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return [:]
        }
            do{
                
                
                let options = GenerationOptions(temperature: 2.0)
                
                
                let instructions = """
                   You are a podcast chapter generator. Given the transcription and timestamps below, identify if this section starts a new topic. If so, generate a short title (max 8 words) that summarizes it. If it's a continuation, say "continuation".

                """
                let session = LanguageModelSession(instructions: instructions)
                
                //let prompt = text
                let response = try await session.respond(
                    to: lines,
                    generating: [AIChapter].self,
                    options: options
                )
                return Dictionary<String, String>(response.content.compactMap { $0 }.map { ($0.timecode, $0.title) }, uniquingKeysWith: { first, _ in return first })
                
            }
            catch{
                // print("Error: \(error)")
                return [:]
            }
    }
    

    
}

