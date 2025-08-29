//
//  PlaySessionTrackerActor.swift
//  Raul
//
//  Created by Holger Krupp on 27.08.25.
//


import Foundation
import SwiftData
import UIKit


@Model
final class RateSegment: Identifiable {
    // Properties made optional for CloudKit compatibility
    
    var id: UUID?
    var rate: Float?
    var startTime: Date?
    var startPosition: Double?
    var endTime: Date?
    var endPosition: Double?
    
    // Inverse relationship to parent PlaySession, required for SwiftData relationship syncing (e.g., for iCloud)
    var parentSession: PlaySession?

    init(
        id: UUID? = nil,
        rate: Float? = nil,
        startTime: Date? = nil,
        startPosition: Double? = nil,
        endTime: Date? = nil,
        endPosition: Double? = nil,
        parentSession: PlaySession? = nil
    ) {
        self.id = id
        self.rate = rate
        self.startTime = startTime
        self.startPosition = startPosition
        self.endTime = endTime
        self.endPosition = endPosition
        self.parentSession = parentSession
    }
}

@Model
final class PlaySession: Identifiable {
    // Properties made optional for CloudKit compatibility
    
    var id: UUID?
    
    // Use a relationship to the Episode model instead of just episodeID to enable SwiftData relationship syncing (e.g., for iCloud).
    // Explicit inverse relationship is required for proper syncing.
    @Relationship(inverse: \Episode.playSessions) var episode: Episode?
    var podcastName: String?
    var deviceModel: String?
    var osVersion: String?
    var appVersion: String?
    var startTime: Date?
    var endTime: Date?
    var startPosition: Double?
    var endPosition: Double?
    
    // Relationship to RateSegment with explicit inverse to RateSegment.parentSession for syncing
    @Relationship(inverse: \RateSegment.parentSession) var segments: [RateSegment]?

    var endedCleanly: Bool?

    init(
        id: UUID? = nil,
        episode: Episode? = nil,
        deviceModel: String? = nil,
        osVersion: String? = nil,
        appVersion: String? = nil,
        startTime: Date? = nil,
        endTime: Date? = nil,
        startPosition: Double? = nil,
        endPosition: Double? = nil,
        segments: [RateSegment]? = [],
        endedCleanly: Bool? = nil
    ) {
        self.id = id
        self.episode = episode
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.startTime = startTime
        self.endTime = endTime
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.segments = segments
        self.endedCleanly = endedCleanly
        self.podcastName = episode?.podcast?.title
    }
}

@ModelActor
actor PlaySessionTrackerActor {
    private var currentSession: PlaySession?


    /// Call this after initialization to kick off recovery.
    func startRecovery()  {
        Task{
             recoverIncompleteSessionIfNeeded()
        }
    }

    func startOrUpdateSession(episode: Episode, position: Double, rate: Float, appVersion: String) async {
        let now = Date()
        let deviceModel = getDeviceModel()
        let osVersion = getOSVersion()

        if let session = currentSession, session.episode?.id == episode.id {
            // Continue existing session; maybe add new rate segment if rate changed
            if let lastSegment = session.segments?.last, lastSegment.rate != rate {
                endCurrentRateSegment(at: now, position: position)
                addRateSegment(rate: rate, startTime: now, startPosition: position)
            }
            return
        }

        // End previous session if different episode
        if let session = currentSession {
            endSession(at: position, appTerminated: false)
        }

        // Start new session
        let id = UUID()
        currentSession = PlaySession(
            id: id,
            episode: episode,
            deviceModel: deviceModel,
            osVersion: osVersion,
            appVersion: appVersion,
            startTime: now,
            endTime: nil,
            startPosition: position,
            endPosition: nil,
            segments: [RateSegment(rate: rate, startTime: now, startPosition: position)],
            endedCleanly: false
        )
         saveSession()
    }

    func pauseSession(at position: Double) async {
        endSession(at: position, appTerminated: false)
    }

    func handlePlaybackRateChange(to rate: Float, at position: Double) async {
        let now = Date()
        guard var session = currentSession else { return }
        if let lastSegment = session.segments?.last, lastSegment.rate != rate {
            endCurrentRateSegment(at: now, position: position)
            addRateSegment(rate: rate, startTime: now, startPosition: position)
             saveSession()
        }
    }

    func updatePosition(_ position: Double) async {
        // For periodic progress update; updates can be batched or rate limited as needed
        // Optionally flush to disk here
    }

    private func endSession(at position: Double, appTerminated: Bool) {
        guard var session = currentSession else { return }
        let now = Date()
        session.endTime = now
        session.endPosition = position
        session.endedCleanly = !appTerminated
        endCurrentRateSegment(at: now, position: position)
        currentSession = nil
       
            saveSession()
        
    }

    private func endCurrentRateSegment(at date: Date, position: Double) {
        guard var session = currentSession, var last = session.segments?.last else { return }
        last.endTime = date
        last.endPosition = position
        if var segments = session.segments {
            segments[segments.count - 1] = last
            session.segments = segments
        }
        currentSession = session
    }

    private func addRateSegment(rate: Float, startTime: Date, startPosition: Double) {
        guard var session = currentSession else { return }
        let segment = RateSegment(rate: rate, startTime: startTime, startPosition: startPosition)
        if session.segments == nil {
            session.segments = []
        }
        session.segments?.append(segment)
        currentSession = session
    }

    // Recovery logic: On launch, check if a session was left open, and finalize it
    private func recoverIncompleteSessionIfNeeded()  {
        // Fetch all incomplete sessions (where endTime == nil)
        let descriptor = FetchDescriptor<PlaySession>(predicate: #Predicate { $0.endTime == nil })
        guard let incompleteSessions = try? modelContext.fetch(descriptor), !incompleteSessions.isEmpty else { return }
        
        for session in incompleteSessions {
            guard let episode = session.episode, let sessionStart = session.startTime, let sessionStartPosition = session.startPosition else { continue }
            // Find all sessions for this episode with startTime > this session
            let allSessions = (try? modelContext.fetch(FetchDescriptor<PlaySession>())) ?? []
            let newerSessions = allSessions
                .filter { $0.episode?.id == episode.id && $0.startTime != nil && ($0.startTime! > sessionStart) }
            // Find the earliest newer session
            let nextSession = newerSessions.sorted(by: { ($0.startTime ?? .distantFuture) < ($1.startTime ?? .distantFuture) }).first
            var endPosition: Double?
            if let next = nextSession, let nextStartPosition = next.startPosition {
                // Use the next session's startPosition
                endPosition = nextStartPosition
            } else {
                // Use the episode's maxPlayProgress (convert to absolute position, not ratio)
                let maxProgress = episode.maxPlayProgress
                endPosition = (episode.duration ?? 0.0) * maxProgress
            }
            // Prevent overlap: ensure endPosition > startPosition and <= nextSession.startPosition (if any)
            if let endPosition, endPosition > sessionStartPosition {
                session.endPosition = endPosition
                session.endedCleanly = false
                // Update last segment too
                if var segments = session.segments, !segments.isEmpty {
                    var last = segments[segments.count - 1]
                    last.endPosition = endPosition
                    // Estimate endTime using playback rate
                    let rate = last.rate ?? 1.0
                    let duration = endPosition - (last.startPosition ?? sessionStartPosition)
                    if let segStartTime = last.startTime {
                        last.endTime = segStartTime.addingTimeInterval(duration / Double(rate))
                        session.endTime = last.endTime
                    }
                    segments[segments.count - 1] = last
                    session.segments = segments
                } else {
                    // If no segment, just set endTime
                    if let start = session.startTime {
                        let rate = session.segments?.last?.rate ?? 1.0
                        let duration = endPosition - sessionStartPosition
                        session.endTime = start.addingTimeInterval(duration / Double(rate))
                    }
                }
                // Save the session
                modelContext.saveIfNeeded()
            }
        }
    }



    private func saveSession() {
        modelContext.saveIfNeeded()
    }

    // MARK: - Device Info Helpers

    private func getDeviceModel() -> String {
#if os(iOS)
   
        return UIDevice.current.model
#elseif os(macOS)
        return "Mac"
#else
        return "Unknown"
#endif
    }

    private func getOSVersion() -> String {
#if os(iOS)
    
        return UIDevice.current.systemVersion
#elseif os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
#else
        return "Unknown"
#endif
    }
}
