//
//  AIChapter.swift
//  Raul
//
//  Created by Holger Krupp on 24.06.25.
//

import Foundation
import FoundationModels

struct TranscriptLineSnapshot: Sendable {
    let speaker: String?
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
}

private struct ChapterCarryOverContext: Sendable {
    let timecode: String
    let title: String
}

private struct TranscriptChunkGenerationResult: Sendable {
    let chapters: [String: String]
    let lastChapter: ChapterCarryOverContext?
}

actor AIChapterGenerator{
    private let maxChaptersPerChunk = 4
    
    
    
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
                let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: 384)
                
                
                let instructions = """
                   If the following text might contain time codes (in the format 00:00 or 00:00:00) and titles, please extract them and format them as chapters. If the text does not conatin time codes, return an empty dictionary.
                """
                let session = LanguageModelSession(instructions: instructions)
                
                let prompt = text
                let response = try await session.respond(
                    to: prompt,
                    generating: [AIChapter].self,
                    includeSchemaInPrompt: false,
                    options: options
                )
                let chapters = response.content.compactMap { chapter -> (String, String)? in
                    let title = normalizedChapterTitle(chapter.title)
                    guard title.isEmpty == false else { return nil }
                    return (chapter.timecode, title)
                }
                return Dictionary<String, String>(chapters, uniquingKeysWith: { first, _ in return first })
                
            }
            catch {
                #if DEBUG
                print("AI chapter extraction failed: \(error)")
                if let localizedError = error as? LocalizedError {
                    if let reason = localizedError.failureReason {
                        print("AI chapter extraction reason: \(reason)")
                    }
                    if let suggestion = localizedError.recoverySuggestion {
                        print("AI chapter extraction suggestion: \(suggestion)")
                    }
                }
                #endif
                return [:]
            }
    }
    
    func createChaptersFromTranscriptLines(_ lines: String) async -> [String:String] {
        guard lines.isEmpty == false else { return [:] }
        let snapshots = lines
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .map { TranscriptLineSnapshot(speaker: nil, text: $0, startTime: 0, endTime: nil) }

        return await createChaptersFromTranscriptLines(snapshots)
    }

    func createChaptersFromTranscriptLines(_ transcriptLines: [TranscriptLineSnapshot]) async -> [String:String] {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return [:]
        }
        guard transcriptLines.isEmpty == false else { return [:] }

        let instructions = """
           You are a podcast chapter generator.
           Given transcript lines with timestamps, produce a sparse list of chapter boundaries.
           Create a chapter when the topic clearly changes or an advertisement / sponsor segment begins.
           Make advertisement sections explicit chapters so they can be skipped later.
           Return at most 4 chapters for this chunk, ideally 1 to 3.
           Only keep the strongest topic shifts or ad / sponsor breaks.
           Do not create chapters for every line, do not output continuation entries, and keep titles short (max 8 words).
           Use the timestamp where the new section starts.
           The transcript below is one chunk from a longer episode. Only return chapters that begin inside this chunk.
           Neighboring chunks will also be processed, so be very selective.
        """

        let chunkBudget: Int
        let usesExactTokenCounting: Bool
        if #available(iOS 26.4, macOS 26.4, *) {
            usesExactTokenCounting = true
            chunkBudget = 1600
        } else {
            usesExactTokenCounting = false
            chunkBudget = 800
        }

        let chunks = await chunkTranscriptLines(transcriptLines, tokenBudget: chunkBudget, model: model)

        #if DEBUG
        print("AI transcript chapter generation will process \(transcriptLines.count) transcript line(s) in \(chunks.count) chunk(s) using \(usesExactTokenCounting ? "exact" : "estimated") token counting and will keep up to \(maxChaptersPerChunk) chapter(s) per chunk.")
        #endif

        var mergedChapters: [String: String] = [:]
        var carryOverContext: ChapterCarryOverContext?

        for (index, chunk) in chunks.enumerated() {
            let chunkLabel = "\(index + 1)/\(chunks.count)"
            let chunkResult = await generateChapters(
                from: chunk,
                instructions: instructions,
                model: model,
                chunkLabel: chunkLabel,
                previousChapterContext: carryOverContext
            )
            mergedChapters.merge(chunkResult.chapters, uniquingKeysWith: { first, _ in first })
            if let lastChapter = chunkResult.lastChapter {
                carryOverContext = lastChapter
            }
        }

        return mergedChapters
    }

    private struct TranscriptChunk {
        let lines: [TranscriptLineSnapshot]
        let prompt: String
        let tokenCount: Int
    }

    private func chunkTranscriptLines(
        _ transcriptLines: [TranscriptLineSnapshot],
        tokenBudget: Int,
        model: SystemLanguageModel
    ) async -> [TranscriptChunk] {
        guard transcriptLines.isEmpty == false else { return [] }

        let normalizedLines = await expandTranscriptLines(
            transcriptLines,
            tokenBudget: tokenBudget,
            model: model
        )

        var chunks: [TranscriptChunk] = []
        var currentLines: [TranscriptLineSnapshot] = []
        var currentTokenCount = 0

        for line in normalizedLines {
            let linePrompt = formattedTranscriptLine(for: line)
            let lineTokenCount = await tokenCount(for: linePrompt, model: model)

            if currentLines.isEmpty {
                currentLines = [line]
                currentTokenCount = lineTokenCount
                continue
            }

            if currentTokenCount + 1 + lineTokenCount > tokenBudget {
                chunks.append(await makeTranscriptChunk(lines: currentLines, model: model))
                currentLines = [line]
                currentTokenCount = lineTokenCount
            } else {
                currentLines.append(line)
                currentTokenCount += 1 + lineTokenCount
            }
        }

        if currentLines.isEmpty == false {
            chunks.append(await makeTranscriptChunk(lines: currentLines, model: model))
        }

        return chunks
    }

    private func expandTranscriptLines(
        _ transcriptLines: [TranscriptLineSnapshot],
        tokenBudget: Int,
        model: SystemLanguageModel
    ) async -> [TranscriptLineSnapshot] {
        var expandedLines: [TranscriptLineSnapshot] = []
        expandedLines.reserveCapacity(transcriptLines.count)

        for line in transcriptLines {
            let linePieces = await splitTranscriptLineIfNeeded(
                line,
                tokenBudget: tokenBudget,
                model: model
            )
            expandedLines.append(contentsOf: linePieces)
        }

        return expandedLines
    }

    private func splitTranscriptLineIfNeeded(
        _ line: TranscriptLineSnapshot,
        tokenBudget: Int,
        model: SystemLanguageModel
    ) async -> [TranscriptLineSnapshot] {
        let prompt = formattedTranscriptLine(for: line)
        let tokenCount = await tokenCount(for: prompt, model: model)
        let characterThreshold = max((tokenBudget * 3) / 2, 240)

        guard tokenCount > tokenBudget || line.text.utf8.count > characterThreshold else {
            return [line]
        }

        let fragments = splitTextIntoFragments(line.text, maxCharacters: characterThreshold)
        guard fragments.count > 1 else {
            return [line]
        }

        #if DEBUG
        print("AI transcript line exceeded the budget and was split into \(fragments.count) fragment(s).")
        #endif

        return fragments.map {
            TranscriptLineSnapshot(
                speaker: line.speaker,
                text: $0,
                startTime: line.startTime,
                endTime: line.endTime
            )
        }
    }

    private func makeTranscriptChunk(
        lines: [TranscriptLineSnapshot],
        model: SystemLanguageModel
    ) async -> TranscriptChunk {
        let prompt = lines.map(formattedTranscriptLine(for:)).joined(separator: "\n")
        let tokenCount = await tokenCount(for: prompt, model: model)
        return TranscriptChunk(lines: lines, prompt: prompt, tokenCount: tokenCount)
    }

    private func splitTextIntoFragments(_ text: String, maxCharacters: Int) -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return [] }

        let words = trimmedText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.isEmpty == false else { return [trimmedText] }

        var fragments: [String] = []
        var currentFragment = ""

        for word in words {
            if word.count > maxCharacters {
                if currentFragment.isEmpty == false {
                    fragments.append(currentFragment)
                    currentFragment = ""
                }
                fragments.append(contentsOf: splitLongWord(word, maxCharacters: maxCharacters))
                continue
            }

            if currentFragment.isEmpty {
                currentFragment = word
                continue
            }

            if currentFragment.count + 1 + word.count > maxCharacters {
                fragments.append(currentFragment)
                currentFragment = word
            } else {
                currentFragment += " "
                currentFragment += word
            }
        }

        if currentFragment.isEmpty == false {
            fragments.append(currentFragment)
        }

        return fragments.isEmpty ? [trimmedText] : fragments
    }

    private func splitLongWord(_ word: String, maxCharacters: Int) -> [String] {
        guard word.count > maxCharacters else { return [word] }

        var fragments: [String] = []
        var currentIndex = word.startIndex

        while currentIndex < word.endIndex {
            let endIndex = word.index(
                currentIndex,
                offsetBy: maxCharacters,
                limitedBy: word.endIndex
            ) ?? word.endIndex
            fragments.append(String(word[currentIndex..<endIndex]))
            currentIndex = endIndex
        }

        return fragments
    }

    private func selectChapterCandidates(
        _ candidates: [(String, String)],
        maxCount: Int
    ) -> [(String, String)] {
        guard candidates.isEmpty == false, maxCount > 0 else { return [] }

        let orderedCandidates = candidates
            .enumerated()
            .map { index, candidate in
                (index: index, candidate: candidate)
            }
            .sorted { left, right in
                let leftScore = chapterPriorityScore(for: left.candidate.1)
                let rightScore = chapterPriorityScore(for: right.candidate.1)

                if leftScore != rightScore {
                    return leftScore > rightScore
                }

                let leftTime = left.candidate.0.durationAsSeconds ?? .greatestFiniteMagnitude
                let rightTime = right.candidate.0.durationAsSeconds ?? .greatestFiniteMagnitude

                if leftTime != rightTime {
                    return leftTime < rightTime
                }

                return left.index < right.index
            }

        var selected: [(String, String)] = []
        var seenTimecodes = Set<String>()

        for entry in orderedCandidates {
            guard seenTimecodes.insert(entry.candidate.0).inserted else {
                continue
            }

            selected.append(entry.candidate)
            if selected.count == maxCount {
                break
            }
        }

        return selected.sorted {
            let leftTime = $0.0.durationAsSeconds ?? .greatestFiniteMagnitude
            let rightTime = $1.0.durationAsSeconds ?? .greatestFiniteMagnitude
            if leftTime != rightTime {
                return leftTime < rightTime
            }
            return $0.0 < $1.0
        }
    }

    private func chapterPriorityScore(for title: String) -> Int {
        let lowered = title.lowercased()
        let priorityKeywords = [
            "ad",
            "advert",
            "advertisement",
            "sponsor",
            "sponsored",
            "promo",
            "promotion"
        ]

        return priorityKeywords.contains { lowered.contains($0) } ? 1 : 0
    }

    private func normalizedChapterTitle(_ title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else { return "" }

        let patterns = [
            #"(?i)^\s*chapter\s*(?:#\s*)?(?:\d+\s*)?[:\-–—]\s*"#,
            #"(?i)^\s*chapter\s*(?:#\s*)?\d+\s*$"#
        ]

        var normalizedTitle = trimmedTitle
        for pattern in patterns {
            normalizedTitle = normalizedTitle.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }

        normalizedTitle = normalizedTitle
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizedTitle
    }

    private func estimatedTokenCount(for text: String) -> Int {
        max(1, text.utf8.count / 2)
    }

    private func tokenCount(for text: String, model: SystemLanguageModel) async -> Int {
        if #available(iOS 26.4, macOS 26.4, *) {
            do {
                return try await model.tokenCount(for: text)
            } catch {
                #if DEBUG
                print("AI transcript token counting failed, falling back to estimate: \(error)")
                #endif
            }
        }

        return estimatedTokenCount(for: text)
    }

    private func formattedTranscriptLine(for line: TranscriptLineSnapshot) -> String {
        let start = line.startTime.secondsToHoursMinutesSeconds ?? "00:00"
        let speaker = line.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerPrefix = speaker?.isEmpty == false ? "\(speaker!): " : ""
        return "\(start) | \(speakerPrefix)\(line.text)"
    }

    private func generateChapters(
        from chunk: TranscriptChunk,
        instructions: String,
        model: SystemLanguageModel,
        chunkLabel: String,
        previousChapterContext: ChapterCarryOverContext?
    ) async -> TranscriptChunkGenerationResult {
        guard chunk.lines.isEmpty == false else {
            return TranscriptChunkGenerationResult(chapters: [:], lastChapter: previousChapterContext)
        }

        do {
            let options = GenerationOptions(temperature: 0.5, maximumResponseTokens: 1024)
            let session = LanguageModelSession(instructions: instructions)
            let continuityPrompt = promptPrefix(for: previousChapterContext)
            let response = try await session.respond(
                to: continuityPrompt.isEmpty ? chunk.prompt : "\(continuityPrompt)\n\n\(chunk.prompt)",
                generating: [AIChapter].self,
                includeSchemaInPrompt: false,
                options: options
            )

            let candidates = response.content.compactMap { $0 }
            let validChapters: [(String, String)] = candidates.compactMap { (chapter: AIChapter) -> (String, String)? in
                let title = normalizedChapterTitle(chapter.title)
                guard title.isEmpty == false,
                      title.lowercased() != "continuation",
                      chapter.timecode.durationAsSeconds != nil else {
                    return nil
                }
                return (chapter.timecode, title)
            }
            let selectedChapters = selectChapterCandidates(validChapters, maxCount: maxChaptersPerChunk)

            #if DEBUG
            print("AI transcript chunk \(chunkLabel) returned \(candidates.count) candidate(s), \(validChapters.count) valid chapter(s), and kept \(selectedChapters.count) chapter(s) for \(chunk.tokenCount) tokens.")
            for candidate in candidates {
                print("AI transcript chunk \(chunkLabel) candidate: timecode=\(candidate.timecode), title=\(candidate.title)")
            }
            if validChapters.count > selectedChapters.count {
                print("AI transcript chunk \(chunkLabel) trimmed \(validChapters.count - selectedChapters.count) extra chapter(s) to keep the result sparse.")
            }
            #endif

            let chapterDictionary = Dictionary<String, String>(
                selectedChapters,
                uniquingKeysWith: { first, _ in return first }
            )
            return TranscriptChunkGenerationResult(
                chapters: chapterDictionary,
                lastChapter: selectedChapters.last.map { ChapterCarryOverContext(timecode: $0.0, title: $0.1) }
            )
        } catch let generationError as LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize(let context):
                #if DEBUG
                print("AI transcript chunk \(chunkLabel) exceeded context window: \(context)")
                #endif
                guard chunk.lines.count > 1 else {
                    return TranscriptChunkGenerationResult(chapters: [:], lastChapter: previousChapterContext)
                }

                let midpoint = chunk.lines.count / 2
                let leftChunk = await makeTranscriptChunk(lines: Array(chunk.lines[..<midpoint]), model: model)
                let rightChunk = await makeTranscriptChunk(lines: Array(chunk.lines[midpoint...]), model: model)

                let leftResult = await generateChapters(
                    from: leftChunk,
                    instructions: instructions,
                    model: model,
                    chunkLabel: "\(chunkLabel)A",
                    previousChapterContext: previousChapterContext
                )
                let rightResult = await generateChapters(
                    from: rightChunk,
                    instructions: instructions,
                    model: model,
                    chunkLabel: "\(chunkLabel)B",
                    previousChapterContext: leftResult.lastChapter ?? previousChapterContext
                )

                return TranscriptChunkGenerationResult(
                    chapters: leftResult.chapters.merging(rightResult.chapters, uniquingKeysWith: { first, _ in first }),
                    lastChapter: rightResult.lastChapter ?? leftResult.lastChapter ?? previousChapterContext
                )
            default:
                #if DEBUG
                print("AI transcript chunk \(chunkLabel) failed: \(generationError)")
                if let reason = generationError.failureReason {
                    print("AI transcript chunk \(chunkLabel) reason: \(reason)")
                }
                if let suggestion = generationError.recoverySuggestion {
                    print("AI transcript chunk \(chunkLabel) suggestion: \(suggestion)")
                }
                #endif
                return TranscriptChunkGenerationResult(chapters: [:], lastChapter: previousChapterContext)
            }
        } catch {
            #if DEBUG
            print("AI transcript chunk \(chunkLabel) failed: \(error)")
            if let localizedError = error as? LocalizedError {
                if let reason = localizedError.failureReason {
                    print("AI transcript chunk \(chunkLabel) reason: \(reason)")
                }
                if let suggestion = localizedError.recoverySuggestion {
                    print("AI transcript chunk \(chunkLabel) suggestion: \(suggestion)")
                }
            }
            #endif
            return TranscriptChunkGenerationResult(chapters: [:], lastChapter: previousChapterContext)
        }
    }

    private func promptPrefix(for previousChapterContext: ChapterCarryOverContext?) -> String {
        guard let previousChapterContext else { return "" }

        return """
        Continuity context from the previous chunk:
        - Previous chunk ended with chapter "\(previousChapterContext.title)" at \(previousChapterContext.timecode).
        - If this chunk continues that same topic, keep it as the same chapter until there is a clear topic change or ad break.
        """
    }
    

    
}
