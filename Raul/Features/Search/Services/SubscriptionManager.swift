//
//  SubscriptionManager.swift
//  PodcastClient
//
//  Created by Holger Krupp on 27.12.23.
//

import Foundation
import SwiftData
import BasicLogger


@ModelActor
actor SubscriptionManager:NSObject{
    

    var podcasts : [Podcast] = []
    var opmlParser = OPMLParser()
   // var podcastParser = PodcastParser()

    private func ensureMetadata(for podcast: Podcast) -> PodcastMetaData {
        if let metaData = podcast.metaData {
            return metaData
        }

        let metaData = PodcastMetaData()
        modelContext.insert(metaData)
        podcast.metaData = metaData
        return metaData
    }

    private func applyFeedPreview(_ podcastFeed: PodcastFeed, to podcast: Podcast) {
        podcast.title = podcastFeed.title ?? podcast.title
        podcast.desc = podcastFeed.description ?? podcast.desc
        podcast.author = podcastFeed.artist ?? podcast.author

        if let artworkURL = podcastFeed.artworkURL {
            podcast.imageURL = artworkURL
        }
        podcast.alternativeFeeds = podcastFeed.alternativeFeeds
    }
    
     func fetchData() {
        
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.metaData?.isSubscribed ?? true == true },
            sortBy: [SortDescriptor(\.title)]
        )
        if let fetchresult = try? modelContext.fetch(descriptor){
            podcasts = fetchresult
        }
        
    }
    
    
    func contains(url: URL) -> Bool{
        existingFeedComparisonKeys.contains { url.podcastFeedComparisonKeys.contains($0) }
    }

    private var existingFeedComparisonKeys: Set<String> {
        podcasts.reduce(into: Set<String>()) { keys, podcast in
            if let feed = podcast.feed {
                keys.formUnion(feed.podcastFeedComparisonKeys)
            }

            for alternativeFeed in podcast.alternativeFeeds {
                keys.formUnion(alternativeFeed.url.podcastFeedComparisonKeys)
            }
        }
    }
    
    func read(file url: URL, progress: SubscriptionProgressHandler? = nil) async -> [PodcastFeed]?{
        var newPodcasts: [PodcastFeed] = []
        
        // print("subscriptionmanager: read \(url.absoluteString)")
        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }
        defer {
            url.stopAccessingSecurityScopedResource()
        }

        if let progress {
            await progress(SubscriptionProgressUpdate(0.05, "Opening OPML file"))
        }

        if let data = try? Data(contentsOf: url){
            if let progress {
                await progress(SubscriptionProgressUpdate(0.2, "Reading subscriptions"))
            }
            fetchData()
            if let progress {
                await progress(SubscriptionProgressUpdate(0.35, "Parsing OPML"))
            }
            if parseOPMLData(data) || parseSanitizedOPMLData(data) {
                let feeds = opmlParser.podcastFeeds
                if feeds.isEmpty == false {
                    if let progress {
                        await progress(SubscriptionProgressUpdate(0.65, "Comparing with library"))
                    }
                    newPodcasts = feeds
                    for index in newPodcasts.indices {
                        newPodcasts[index].existing = podcasts.contains { newPodcasts[index].matchesExistingPodcast($0) }
                    }
                    if let progress {
                        await progress(SubscriptionProgressUpdate(0.8, "Preparing import preview"))
                    }
                    
                }
                return newPodcasts
            }
            
            
        }else{
            // print("could not read data from OPML file")
        }
        return nil
    }

    private func parseOPMLData(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = true
        parser.delegate = opmlParser
        return parser.parse()
    }

    private func parseSanitizedOPMLData(_ data: Data) -> Bool {
        guard let sanitizedData = OPMLImportSanitizer.sanitizedDataIfNeeded(from: data) else {
            return false
        }

        return parseOPMLData(sanitizedData)
    }
    

    enum SubscribeError: Error {
        case existing, parsing, loadfeed
        
        var localizedDescription:String{
            switch self {
            case .existing:
                "Podcast already subscribed to"
            case .parsing:
                "Could not parse feed"
            case .loadfeed:
                "Could not load feed"
            }
        }
        
        
        
    }

    
    func subscribe(all urls:[URL?], progress: SubscriptionProgressHandler? = nil) async{
        
        
        let validURLs = urls.compactMap { $0 }
        let total = max(validURLs.count, 1)

        for (index, url) in validURLs.enumerated() {
            do {
                let _ = try await PodcastModelActor(modelContainer: modelContainer).createPodcast(from: url) { update in
                    guard let progress else { return }
                    let overall = (Double(index) + update.fractionCompleted) / Double(total)
                    await progress(SubscriptionProgressUpdate(overall, update.message))
                }
            } catch {
                print(error)
            }
        }
        await SubscriptionManifestSync.publishCurrentSubscriptions(modelContainer: modelContainer)
    }

    func addToLibrary(
        _ podcastFeed: PodcastFeed,
        subscribe: Bool,
        progress: SubscriptionProgressHandler? = nil
    ) async throws -> PersistentIdentifier {
        guard let url = podcastFeed.url else {
            throw SubscribeError.loadfeed
        }

        if subscribe {
            if let progress {
                await progress(SubscriptionProgressUpdate(0.02, "Checking podcast feed"))
            }
            _ = try await PodcastParser.fetchPage(from: url)
        }

        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.feed == url }
        )

        let existingPodcast = (try? modelContext.fetch(descriptor))?.first
        let previousIsSubscribed = existingPodcast?.metaData?.isSubscribed
        let previousSubscriptionDate = existingPodcast?.metaData?.subscriptionDate
        var podcastForRollback: Podcast?
        var insertedNewPodcast = false

        do {
            let podcast: Podcast
            if let existingPodcast {
                podcast = existingPodcast
                applyFeedPreview(podcastFeed, to: existingPodcast)

                let metadata = ensureMetadata(for: existingPodcast)
                if subscribe {
                    metadata.isSubscribed = true
                    metadata.subscriptionDate = Date()
                }
            } else {
                let newPodcast = Podcast(from: podcastFeed)
                let metadata = newPodcast.metaData ?? PodcastMetaData()
                newPodcast.metaData = metadata
                metadata.isSubscribed = subscribe
                metadata.subscriptionDate = subscribe ? Date() : nil
                modelContext.insert(newPodcast)
                podcast = newPodcast
                insertedNewPodcast = true
            }
            podcastForRollback = podcast

            modelContext.saveIfNeeded()
            await SubscriptionManifestSync.publishCurrentSubscriptions(
                modelContainer: modelContainer,
                allowEmpty: subscribe == false
            )

            if let progress {
                await progress(
                    SubscriptionProgressUpdate(
                        0.08,
                        subscribe ? "Preparing subscription" : "Preparing podcast"
                    )
                )
            }

            if let feed = podcast.feed {
                let worker = PodcastModelActor(modelContainer: modelContainer)
                _ = try await worker.updatePodcast(feed, force: true, silent: true) { update in
                    guard let progress else { return }

                    let message: String
                    switch update.message {
                    case "Subscription complete" where subscribe == false:
                        message = "Podcast ready"
                    case "Subscription failed" where subscribe == false:
                        message = "Podcast import failed"
                    default:
                        message = update.message
                    }

                    await progress(SubscriptionProgressUpdate(update.fractionCompleted, message))
                }
                await SubscriptionManifestSync.publishCurrentSubscriptions(
                    modelContainer: modelContainer,
                    allowEmpty: subscribe == false
                )
            }

            if subscribe == false {
                let metadata = ensureMetadata(for: podcast)
                metadata.isSubscribed = false
                metadata.subscriptionDate = nil
                modelContext.saveIfNeeded()
                await SubscriptionManifestSync.publishCurrentSubscriptions(
                    modelContainer: modelContainer,
                    allowEmpty: true
                )
            }

            return podcast.persistentModelID
        } catch {
            if let podcast = podcastForRollback {
                if insertedNewPodcast {
                    modelContext.delete(podcast)
                } else if subscribe {
                    let metadata = ensureMetadata(for: podcast)
                    metadata.isSubscribed = previousIsSubscribed ?? false
                    metadata.subscriptionDate = previousSubscriptionDate
                }
                modelContext.saveIfNeeded()
            }
            await SubscriptionManifestSync.publishCurrentSubscriptions(
                modelContainer: modelContainer,
                allowEmpty: true
            )
            throw error
        }
    }
    
    
    

    private func fetchPodcast(by feedURL: URL) -> Podcast? {
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.feed == feedURL }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchPodcast(by id: PersistentIdentifier) -> Podcast? {
        if let podcast = modelContext.model(for: id) as? Podcast {
            return podcast
        }

        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.persistentModelID == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchEpisode(by episodeURL: URL) -> Episode? {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.url == episodeURL }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func upsertEpisode(
        from draft: PodcastEpisodeDraft,
        in podcast: Podcast
    ) -> Episode? {
        if let existingEpisode = fetchEpisode(by: draft.episodeURL) {
            if existingEpisode.podcast?.feed != podcast.feed {
                existingEpisode.podcast = podcast
            }
            existingEpisode.update(from: draft.rawEpisodeData)
            return existingEpisode
        }

        guard let episode = Episode(from: draft.rawEpisodeData, podcast: podcast) else {
            return nil
        }

        modelContext.insert(episode)
        return episode
    }

    func queueBrowseEpisode(
        _ draft: PodcastEpisodeDraft,
        from podcastFeed: PodcastFeed,
        to position: Playlist.Position = .end
    ) async throws {
        guard let feedURL = podcastFeed.url else {
            throw SubscribeError.loadfeed
        }

        let existingPodcast = fetchPodcast(by: feedURL)
        let podcast: Podcast
        if let existingPodcast {
            podcast = existingPodcast
            applyFeedPreview(podcastFeed, to: existingPodcast)
        } else {
            let newPodcast = Podcast(from: podcastFeed)
            modelContext.insert(newPodcast)
            podcast = newPodcast
        }

        let metadata = ensureMetadata(for: podcast)
        if existingPodcast == nil {
            metadata.isSubscribed = false
            metadata.subscriptionDate = nil
        }

        guard let episode = upsertEpisode(from: draft, in: podcast) else {
            throw SubscribeError.parsing
        }

        modelContext.saveIfNeeded()

        let playlistActor = try PlaylistModelActor(modelContainer: modelContainer)
        try await playlistActor.add(episodeURL: episode.url ?? draft.episodeURL, to: position)
    }

    func subscribe_old(all newPodcasts: [PodcastFeed]) async {
        let podcastSemaphore = AsyncSemaphore(value: 1)
        await withTaskGroup(of: Void.self) { group in
            for podcast in newPodcasts {
                if let url = podcast.url {
                    group.addTask {
                        await podcastSemaphore.wait()
                        do {
                            let worker = PodcastModelActor(modelContainer: self.modelContainer)
                            _ = try await worker.createPodcast(from: url)
                        } catch {
                            print(error)
                        }
                        await podcastSemaphore.signal()
                    }
                }
            }
        }
    }
    
    
    func subscribe(all newPodcasts: [PodcastFeed], progress: SubscriptionProgressHandler? = nil) async {
        
        // 1. SERIAL PHASE: Mass-insert all new podcasts quickly.
        //    Perform this on a single ModelContext serially to avoid "Database busy" errors
        //    for the crucial insertion step.
        
        var newPodcastFeeds: Set<URL> = []
        let importTotal = max(newPodcasts.count, 1)

        if let progress {
            await progress(SubscriptionProgressUpdate(0.02, "Preparing subscriptions"))
        }
        
        for (index, podcastFeed) in newPodcasts.enumerated() {
            guard let url = podcastFeed.url else { continue }

            // Check if podcast with this feed URL already exists (if PodcastFeed.existing is not reliable)
            let descriptor = FetchDescriptor<Podcast>(
                predicate: #Predicate<Podcast> { $0.feed == url }
            )
            
            // This fetch/insert/save is now done serially, preventing contention.
            if let existingPodcasts = try? modelContext.fetch(descriptor),
               let existingPodcast = existingPodcasts.first, let existinURL = existingPodcast.feed {
                // Already exists, maybe update some basic properties from feedData if needed
                existingPodcast.title = podcastFeed.title ?? existingPodcast.title
                let metadata = ensureMetadata(for: existingPodcast)
                metadata.isSubscribed = true
                metadata.subscriptionDate = Date()
                // existingPodcast.message = nil
                
                newPodcastFeeds.insert(existinURL)
                
            } else {
                let podcast = Podcast(from: podcastFeed) // Use the fast, new initializer
                if let feed = podcast.feed{
                    modelContext.insert(podcast)
                    newPodcastFeeds.insert(feed)
                }
               
            }

            if let progress {
                let completed = index + 1
                let fraction = 0.02 + (Double(completed) / Double(importTotal)) * 0.18
                await progress(
                    SubscriptionProgressUpdate(
                        fraction,
                        "Adding \(completed) of \(newPodcasts.count) subscriptions"
                    )
                )
            }
        }
        
        // Commit all changes from the serial inserts at once.
        // This is one large, safe save operation.
        if let progress {
            await progress(SubscriptionProgressUpdate(0.22, "Saving subscriptions"))
        }
        modelContext.saveIfNeeded()
        await SubscriptionManifestSync.publishCurrentSubscriptions(modelContainer: modelContainer)
        
        if let progress {
            await progress(
                SubscriptionProgressUpdate(
                    1.0,
                    "Subscriptions added. Episodes will import in the background."
                )
            )
        }

        scheduleBackgroundFeedImport(for: Array(newPodcastFeeds))
    }

    private nonisolated func scheduleBackgroundFeedImport(for feeds: [URL]) {
        let modelContainer = self.modelContainer
        Task.detached(priority: .utility) {
            let worker = PodcastModelActor(modelContainer: modelContainer)

            for feed in feeds {
                do {
                    print("background importing podcast: \(feed)")
                    _ = try await worker.updatePodcast(feed, force: true, silent: true)
                } catch {
                    print("could not import podcast feed \(feed): \(error)")
                }
            }

            await SubscriptionManifestSync.publishCurrentSubscriptions(modelContainer: modelContainer)
        }
    }
    
    func deleteAllPodcasts() async {
        let descriptor = FetchDescriptor<Podcast>()
        do {
            let all = try modelContext.fetch(descriptor)
            for podcast in all {
                modelContext.delete(podcast)
            }
            try modelContext.save()
            await SubscriptionManifestSync.publishCurrentSubscriptions(
                modelContainer: modelContainer,
                allowEmpty: true
            )
        } catch {
            print("Failed to delete all podcasts: \(error)")
        }
        let downloadedFilesManager = DownloadedFilesManager(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
        try? downloadedFilesManager.deleteAllFiles()
    }
    
    
    //MARK: Background
    //the next functions are for background refresh activites. but could be also used in other occations
    
    private enum TimedPodcastUpdateResult: Sendable {
        case completed(Bool?)
        case timedOut
    }

    enum FeedRefreshReason {
        case foregroundQuiet
        case appRefresh
        case processing
    }

    struct PredictedReleaseRefreshTarget: Identifiable, Sendable, Equatable {
        let title: String
        let feed: URL
        let releaseDate: Date
        let refreshStart: Date
        let refreshEnd: Date
        let lastCheck: Date?
        let lastRefresh: Date?
        let score: Int

        var id: String { feed.absoluteString }

        func nextAttemptDate(releaseDelay: TimeInterval, retryDelay: TimeInterval) -> Date {
            let firstAttemptDate = releaseDate.addingTimeInterval(releaseDelay)
            guard let lastRefresh, lastRefresh >= releaseDate else {
                return firstAttemptDate
            }

            return max(firstAttemptDate, lastRefresh.addingTimeInterval(retryDelay))
        }
    }

    private static let predictedReleaseRefreshRuntimeLimit: TimeInterval = 25
    private static let predictedReleaseRefreshPerPodcastRuntimeLimit: TimeInterval = 5
    private static let predictedReleaseRefreshMinimumRuntimeRemaining: TimeInterval = 2

    private struct BackgroundFeedRefreshPolicy: Sendable {
        let maxPodcastsPerRun: Int
        let maxConcurrentPodcastUpdates: Int
        let maxRuntime: TimeInterval
        let perPodcastRuntimeLimit: TimeInterval
        let minimumRuntimeRemainingBeforeStartingFeed: TimeInterval
        let notifyNewEpisodes: Bool

        static func forReason(_ reason: FeedRefreshReason) -> BackgroundFeedRefreshPolicy {
            switch reason {
            case .foregroundQuiet:
                return .init(
                    maxPodcastsPerRun: 3,
                    maxConcurrentPodcastUpdates: 1,
                    maxRuntime: 24,
                    perPodcastRuntimeLimit: 7,
                    minimumRuntimeRemainingBeforeStartingFeed: 2,
                    notifyNewEpisodes: true
                )
            case .appRefresh:
                return .init(
                    maxPodcastsPerRun: 5,
                    maxConcurrentPodcastUpdates: 1,
                    maxRuntime: 25,
                    perPodcastRuntimeLimit: 7,
                    minimumRuntimeRemainingBeforeStartingFeed: 2,
                    notifyNewEpisodes: true
                )
            case .processing:
                return .init(
                    maxPodcastsPerRun: 12,
                    maxConcurrentPodcastUpdates: 1,
                    maxRuntime: 120,
                    perPodcastRuntimeLimit: 12,
                    minimumRuntimeRemainingBeforeStartingFeed: 4,
                    notifyNewEpisodes: true
                )
            }
        }
    }

    private struct BackgroundFeedRefreshCandidate: Sendable {
        let title: String
        let feed: URL
        let lastCheckAge: Int
        let forceParse: Bool
    }

    private struct BackgroundFeedRefreshResult: Sendable {
        let title: String
        let feed: URL
        let lastCheckAge: Int
        let result: TimedPodcastUpdateResult
        let newEpisodeCount: Int
        let errorMessage: String?
    }

    private func backgroundRefreshCandidates() -> [Podcast] {
        podcasts
            .filter { $0.metaData?.isSubscribed != false }
            .sorted { lhs, rhs in
                let lhsCheckDate = lhs.metaData?.feedUpdateCheckDate ?? .distantPast
                let rhsCheckDate = rhs.metaData?.feedUpdateCheckDate ?? .distantPast
                if lhsCheckDate != rhsCheckDate {
                    return lhsCheckDate < rhsCheckDate
                }

                return (lhs.metaData?.lastRefresh ?? .distantPast) < (rhs.metaData?.lastRefresh ?? .distantPast)
            }
    }

    private func markBackgroundFeedCheckAttempt(for podcast: Podcast) {
        let metaData = ensureMetadata(for: podcast)
        metaData.feedUpdateCheckDate = Date()
        modelContext.saveIfNeeded()
    }

    private func makeBackgroundFeedRefreshCandidates(
        startedAt: Date,
        policy: BackgroundFeedRefreshPolicy
    ) -> [BackgroundFeedRefreshCandidate] {
        var candidates: [BackgroundFeedRefreshCandidate] = []

        for ranked in podcastsPrioritizedForBackgroundRefresh(now: startedAt) {
            if candidates.count >= policy.maxPodcastsPerRun {
                CrashBreadcrumbs.shared.record("bgupdate_feeds_stopped", details: "reason=max_podcasts")
                break
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= policy.maxRuntime {
                CrashBreadcrumbs.shared.record("bgupdate_feeds_stopped", details: "reason=max_runtime")
                break
            }
            if policy.maxRuntime - elapsed < policy.minimumRuntimeRemainingBeforeStartingFeed {
                CrashBreadcrumbs.shared.record("bgupdate_feeds_stopped", details: "reason=runtime_remaining")
                break
            }

            let podcast = ranked.podcast
            guard let feed = podcast.feed else { continue }

            let lastCheckAge = podcast.metaData?.feedUpdateCheckDate.map { Int(Date().timeIntervalSince($0)) } ?? -1
            candidates.append(
                BackgroundFeedRefreshCandidate(
                    title: podcast.title,
                    feed: feed,
                    lastCheckAge: lastCheckAge,
                    forceParse: ranked.forceParse
                )
            )
        }

        return candidates
    }

    private func updatePodcastWithTimeBudget(
        _ feed: URL,
        timeBudget: TimeInterval,
        notifyNewEpisodes: Bool,
        forceParse: Bool = false
    ) async -> (TimedPodcastUpdateResult, Int, String?) {
        let worker = PodcastModelActor(modelContainer: modelContainer)
        let deadline = Date().addingTimeInterval(timeBudget)

        do {
            let summary = try await worker.updatePodcastWithSummary(
                feed,
                force: forceParse,
                silent: true,
                processNewEpisodesDuringSilentRefresh: notifyNewEpisodes,
                deadline: deadline
            )
            let result: TimedPodcastUpdateResult = Date() >= deadline
                ? .timedOut
                : .completed(summary.didUpdateFeed)
            return (result, summary.newEpisodeCount, nil)
        } catch is CancellationError {
            return (.timedOut, 0, nil)
        } catch {
            return (.completed(false), 0, error.localizedDescription)
        }
    }

    

    func nextPredictedFeedRefreshDate(after now: Date = Date()) async -> Date? {
        fetchData()
        let predictedRefreshDates = podcasts
            .filter { $0.metaData?.isSubscribed != false }
            .compactMap {
                PodcastReleasePredictor
                    .updateCachedPrediction(for: $0, after: now)?
                    .refreshStart
            }

        modelContext.saveIfNeeded()
        return predictedRefreshDates.min()
    }

    func predictedReleaseDate(
        for podcastID: PersistentIdentifier,
        after now: Date = Date()
    ) async -> Date? {
        guard let podcast = fetchPodcast(by: podcastID) else { return nil }

        _ = ensureMetadata(for: podcast)
        let prediction = PodcastReleasePredictor.updateCachedPrediction(
            for: podcast,
            after: now,
            allowRelationshipFallback: true
        )
        modelContext.saveIfNeeded()

        return prediction?.releaseDate ?? podcast.metaData?.nextPredictedReleaseDate
    }

    func nextPredictedReleaseRefreshTarget(
        after now: Date = Date(),
        releaseDelay: TimeInterval = 0,
        retryDelay: TimeInterval = 0
    ) async -> PredictedReleaseRefreshTarget? {
        fetchData()
        let target = nextPredictedReleaseRefreshTargetFromLoadedPodcasts(
            after: now,
            releaseDelay: releaseDelay,
            retryDelay: retryDelay
        )
        modelContext.saveIfNeeded()
        return target
    }

    func predictedReleaseRefreshCandidates(
        after now: Date = Date(),
        limit: Int? = nil
    ) async -> [PredictedReleaseRefreshTarget] {
        fetchData()
        let targets = predictedReleaseRefreshCandidatesFromLoadedPodcasts(
            after: now,
            limit: limit
        )
        modelContext.saveIfNeeded()
        return targets
    }

    private func nextPredictedReleaseRefreshTargetFromLoadedPodcasts(
        after now: Date,
        releaseDelay: TimeInterval,
        retryDelay: TimeInterval
    ) -> PredictedReleaseRefreshTarget? {
        predictedReleaseRefreshScheduleCandidatesFromLoadedPodcasts(
            after: now,
            releaseDelay: releaseDelay,
            retryDelay: retryDelay
        ).first
    }

    private func predictedReleaseRefreshCandidatesFromLoadedPodcasts(
        after now: Date,
        limit: Int? = nil
    ) -> [PredictedReleaseRefreshTarget] {
        let sortedTargets = predictedReleaseRefreshTargetsFromLoadedPodcasts(after: now)
            .sorted { lhs, rhs in
                // Urgency first (overdue / in-window beats merely soon), then the
                // earliest predicted release, then the least-recently refreshed.
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.releaseDate != rhs.releaseDate {
                    return lhs.releaseDate < rhs.releaseDate
                }
                return (lhs.lastRefresh ?? .distantPast) < (rhs.lastRefresh ?? .distantPast)
            }

        guard let limit else { return sortedTargets }
        return Array(sortedTargets.prefix(max(0, limit)))
    }

    private func predictedReleaseRefreshScheduleCandidatesFromLoadedPodcasts(
        after now: Date,
        releaseDelay: TimeInterval,
        retryDelay: TimeInterval
    ) -> [PredictedReleaseRefreshTarget] {
        predictedReleaseRefreshTargetsFromLoadedPodcasts(after: now)
            .sorted { lhs, rhs in
                let lhsAttempt = lhs.nextAttemptDate(
                    releaseDelay: releaseDelay,
                    retryDelay: retryDelay
                )
                let rhsAttempt = rhs.nextAttemptDate(
                    releaseDelay: releaseDelay,
                    retryDelay: retryDelay
                )
                if lhsAttempt != rhsAttempt { return lhsAttempt < rhsAttempt }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.releaseDate != rhs.releaseDate { return lhs.releaseDate < rhs.releaseDate }
                return (lhs.lastRefresh ?? .distantPast) < (rhs.lastRefresh ?? .distantPast)
            }
    }

    private func predictedReleaseRefreshTargetsFromLoadedPodcasts(
        after now: Date
    ) -> [PredictedReleaseRefreshTarget] {
        podcasts
            .filter { $0.metaData?.isSubscribed != false }
            .compactMap { podcast -> PredictedReleaseRefreshTarget? in
                guard let feed = podcast.feed,
                      let prediction = PodcastReleasePredictor
                        .updateCachedPrediction(
                            for: podcast,
                            after: now,
                            allowRelationshipFallback: true
                        ) else {
                    return nil
                }

                return PredictedReleaseRefreshTarget(
                    title: podcast.title,
                    feed: feed,
                    releaseDate: prediction.releaseDate,
                    refreshStart: prediction.refreshStart,
                    refreshEnd: prediction.refreshEnd,
                    lastCheck: podcast.metaData?.feedUpdateCheckDate,
                    lastRefresh: podcast.metaData?.lastRefresh,
                    score: backgroundRefreshScore(
                        for: podcast,
                        prediction: prediction,
                        now: now
                    )
                )
            }
    }

    @discardableResult
    func refreshNextPredictedReleasePodcast(
        releaseDelay: TimeInterval,
        now: Date = Date()
    ) async -> Bool {
        await refreshNextPredictedReleasePodcasts(
            limit: 1,
            releaseDelay: releaseDelay,
            now: now
        ) > 0
    }

    @discardableResult
    func refreshNextPredictedReleasePodcasts(
        limit: Int,
        releaseDelay: TimeInterval,
        retryDelay: TimeInterval = BackgroundTaskConfiguration.predictedReleaseRefreshRetryDelay,
        now: Date = Date()
    ) async -> Int {
        guard await FeedRefreshRunCoordinator.shared.begin() else {
            CrashBreadcrumbs.shared.record(
                "predicted_release_refresh_skipped",
                details: "reason=already_running"
            )
            return 0
        }

        let startedAt = Date()
        let maxPodcasts = max(1, limit)
#if DEBUG
        var checkedPodcasts: [RefreshHistoryPodcastCheck] = []
#endif

        fetchData()
        let candidates = predictedReleaseRefreshCandidatesFromLoadedPodcasts(
            after: now
        )
        modelContext.saveIfNeeded()

        guard candidates.isEmpty == false else {
            CrashBreadcrumbs.shared.record(
                "predicted_release_refresh_skipped",
                details: "reason=no_prediction"
            )
#if DEBUG
            await RefreshHistoryStore.shared.record(
                RefreshHistoryEntry(
                    startedAt: startedAt,
                    finishedAt: Date(),
                    trigger: .backgroundPredictedRelease,
                    checkedPodcasts: checkedPodcasts
                )
            )
#endif
            await FeedRefreshRunCoordinator.shared.finish()
            return 0
        }

        let dueTargets = candidates.filter {
            now >= $0.nextAttemptDate(
                releaseDelay: releaseDelay,
                retryDelay: retryDelay
            )
        }
        guard dueTargets.isEmpty == false else {
            let nextTarget = candidates.min {
                let lhsAttempt = $0.nextAttemptDate(
                    releaseDelay: releaseDelay,
                    retryDelay: retryDelay
                )
                let rhsAttempt = $1.nextAttemptDate(
                    releaseDelay: releaseDelay,
                    retryDelay: retryDelay
                )
                if lhsAttempt != rhsAttempt { return lhsAttempt < rhsAttempt }
                return $0.releaseDate < $1.releaseDate
            }
            let nextDueDate = nextTarget?.nextAttemptDate(
                releaseDelay: releaseDelay,
                retryDelay: retryDelay
            )
            CrashBreadcrumbs.shared.record(
                "predicted_release_refresh_skipped",
                details: "reason=too_early,release=\(nextTarget?.releaseDate.description ?? "unknown"),due=\(nextDueDate?.description ?? "unknown"),now=\(now)"
            )
            await FeedRefreshRunCoordinator.shared.finish()
            return 0
        }

        var attemptedCount = 0
        var updatedCount = 0
        var timedOutCount = 0

        for target in dueTargets.prefix(maxPodcasts) {
            if Task.isCancelled {
                CrashBreadcrumbs.shared.record(
                    "predicted_release_refresh_stopped",
                    details: "reason=cancelled,attempted=\(attemptedCount)"
                )
                break
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= Self.predictedReleaseRefreshRuntimeLimit {
                CrashBreadcrumbs.shared.record(
                    "predicted_release_refresh_stopped",
                    details: "reason=max_runtime,attempted=\(attemptedCount)"
                )
                break
            }
            if Self.predictedReleaseRefreshRuntimeLimit - elapsed
                < Self.predictedReleaseRefreshMinimumRuntimeRemaining {
                CrashBreadcrumbs.shared.record(
                    "predicted_release_refresh_stopped",
                    details: "reason=runtime_remaining,attempted=\(attemptedCount)"
                )
                break
            }

            guard let podcast = podcasts.first(where: { $0.feed == target.feed }) else {
                CrashBreadcrumbs.shared.record(
                    "predicted_release_refresh_skipped",
                    details: "reason=podcast_missing,feed=\(target.feed.absoluteString)"
                )
                continue
            }

            let lastCheckAge = podcast.metaData?.feedUpdateCheckDate
                .map { Int(Date().timeIntervalSince($0)) } ?? -1

            CrashBreadcrumbs.shared.record(
                "predicted_release_refresh_started",
                details: "feed=\(target.feed.absoluteString),release=\(target.releaseDate)"
            )

            let remainingRuntime = Self.predictedReleaseRefreshRuntimeLimit
                - Date().timeIntervalSince(startedAt)
            let timeBudget = min(
                Self.predictedReleaseRefreshPerPodcastRuntimeLimit,
                max(1, remainingRuntime)
            )
            // These targets are overdue / inside their predicted window, so parse
            // the feed in full rather than trusting a possibly-stale Last-Modified.
            let (result, newEpisodeCount, errorMessage) = await updatePodcastWithTimeBudget(
                target.feed,
                timeBudget: timeBudget,
                notifyNewEpisodes: true,
                forceParse: true
            )
            attemptedCount += 1

            switch result {
            case .completed(let didUpdate):
                if didUpdate == true { updatedCount += 1 }
                CrashBreadcrumbs.shared.record(
                    "predicted_release_refresh_completed",
                    details: "updated=\(didUpdate == true),new_episodes=\(newEpisodeCount),last_check_age=\(lastCheckAge)s"
                )
#if DEBUG
                let podcastResult: RefreshHistoryPodcastResult
                if let errorMessage {
                    podcastResult = .failed(errorMessage)
                } else if didUpdate == true {
                    podcastResult = .refreshed(newEpisodeCount: newEpisodeCount)
                } else {
                    podcastResult = .feedNotUpdated
                }
                checkedPodcasts.append(
                    RefreshHistoryPodcastCheck(
                        title: target.title,
                        feedURL: target.feed,
                        result: podcastResult
                    )
                )
#endif
            case .timedOut:
                timedOutCount += 1
                CrashBreadcrumbs.shared.record(
                    "predicted_release_refresh_timed_out",
                    details: "feed=\(target.feed.absoluteString),last_check_age=\(lastCheckAge)s"
                )
#if DEBUG
                checkedPodcasts.append(
                    RefreshHistoryPodcastCheck(
                        title: target.title,
                        feedURL: target.feed,
                        result: .timedOut
                    )
                )
#endif
            }
        }

        CrashBreadcrumbs.shared.record(
            "predicted_release_refresh_completed_batch",
            details: "attempted=\(attemptedCount),updated=\(updatedCount),timed_out=\(timedOutCount)"
        )
#if DEBUG
        await RefreshHistoryStore.shared.record(
            RefreshHistoryEntry(
                startedAt: startedAt,
                finishedAt: Date(),
                trigger: .backgroundPredictedRelease,
                checkedPodcasts: checkedPodcasts
            )
        )
#endif
        if attemptedCount > 0 {
            WatchSyncCoordinator.refreshSoon()
        }
        await FeedRefreshRunCoordinator.shared.finish()
        return attemptedCount
    }

    private func podcastsPrioritizedForBackgroundRefresh(
        now: Date
    ) -> [(podcast: Podcast, forceParse: Bool)] {
        let rankedPodcasts = podcasts
            .filter { $0.metaData?.isSubscribed != false }
            .map { podcast -> (podcast: Podcast, prediction: PodcastReleasePredictor.Prediction?, score: Int) in
                let prediction = PodcastReleasePredictor.updateCachedPrediction(for: podcast, after: now)
                return (
                    podcast: podcast,
                    prediction: prediction,
                    score: backgroundRefreshScore(for: podcast, prediction: prediction, now: now)
                )
            }

        modelContext.saveIfNeeded()

        return rankedPodcasts
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }

                // Tie-break on the last *actual* parse so the daily floor cycles
                // through the least-recently-refreshed feeds first.
                return (lhs.podcast.metaData?.lastRefresh ?? .distantPast)
                    < (rhs.podcast.metaData?.lastRefresh ?? .distantPast)
            }
            .map { entry in
                (
                    podcast: entry.podcast,
                    forceParse: PodcastBackgroundRefreshPriority.shouldForceParse(
                        prediction: entry.prediction,
                        now: now
                    )
                )
            }
    }

    private func backgroundRefreshScore(
        for podcast: Podcast,
        prediction: PodcastReleasePredictor.Prediction?,
        now: Date
    ) -> Int {
        PodcastBackgroundRefreshPriority.score(
            prediction: prediction,
            now: now,
            lastRefresh: podcast.metaData?.lastRefresh
        )
    }

    func bgupdateFeeds(reason: FeedRefreshReason = .foregroundQuiet) async{
        guard await FeedRefreshRunCoordinator.shared.begin() else {
            CrashBreadcrumbs.shared.record("bgupdate_feeds_skipped", details: "reason=already_running")
            return
        }

        // this updates the feeds. It takes more time
        // check only those that are not marked as old during the last run

       //  await BasicLogger.shared.log("bgupdateFeeds")
        
        let startedAt = Date()
        let policy = BackgroundFeedRefreshPolicy.forReason(reason)
        setLastRefreshDate()
        fetchData()
        var updated = 0
        var processed = 0
        var timedOut = 0
#if DEBUG
        var checkedPodcasts: [RefreshHistoryPodcastCheck] = []
#endif

        CrashBreadcrumbs.shared.record(
            "bgupdate_feeds_started",
            details: "reason=\(reason),podcasts=\(podcasts.count),limit=\(policy.maxPodcastsPerRun)"
        )

        let candidates = makeBackgroundFeedRefreshCandidates(startedAt: startedAt, policy: policy)
        CrashBreadcrumbs.shared.record(
            "bgupdate_feeds_candidates_prepared",
            details: "candidates=\(candidates.count),concurrency=\(policy.maxConcurrentPodcastUpdates)"
        )

        var candidateIndex = 0
        while candidateIndex < candidates.count {
            if Task.isCancelled {
                CrashBreadcrumbs.shared.record("bgupdate_feeds_stopped", details: "reason=cancelled")
                break
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= policy.maxRuntime {
                CrashBreadcrumbs.shared.record("bgupdate_feeds_stopped", details: "reason=max_runtime")
                break
            }
            if policy.maxRuntime - elapsed < policy.minimumRuntimeRemainingBeforeStartingFeed {
                CrashBreadcrumbs.shared.record("bgupdate_feeds_stopped", details: "reason=runtime_remaining")
                break
            }

            let batchEndIndex = min(
                candidateIndex + policy.maxConcurrentPodcastUpdates,
                candidates.count
            )
            let batch = candidates[candidateIndex..<batchEndIndex]
            candidateIndex = batchEndIndex

            await withTaskGroup(of: BackgroundFeedRefreshResult.self) { group in
                for candidate in batch {
                    if let podcast = podcasts.first(where: { $0.feed == candidate.feed }) {
                        // Mark only work that is actually launched. Candidate
                        // preparation may outlive an app-refresh task, and marking
                        // everything up front made untouched feeds look checked.
                        markBackgroundFeedCheckAttempt(for: podcast)
                    }
                    group.addTask {
                        let (result, newEpisodeCount, errorMessage) = await self.updatePodcastWithTimeBudget(
                            candidate.feed,
                            timeBudget: policy.perPodcastRuntimeLimit,
                            notifyNewEpisodes: policy.notifyNewEpisodes,
                            forceParse: candidate.forceParse
                        )
                        return BackgroundFeedRefreshResult(
                            title: candidate.title,
                            feed: candidate.feed,
                            lastCheckAge: candidate.lastCheckAge,
                            result: result,
                            newEpisodeCount: newEpisodeCount,
                            errorMessage: errorMessage
                        )
                    }
                }

                for await refreshResult in group {
                    processed += 1
                    switch refreshResult.result {
                    case .completed(let new):
                        if new == true { updated += 1 }
#if DEBUG
                        let podcastResult: RefreshHistoryPodcastResult
                        if let errorMessage = refreshResult.errorMessage {
                            podcastResult = .failed(errorMessage)
                        } else if new == true {
                            podcastResult = .refreshed(newEpisodeCount: refreshResult.newEpisodeCount)
                        } else {
                            podcastResult = .feedNotUpdated
                        }
                        checkedPodcasts.append(
                            RefreshHistoryPodcastCheck(
                                title: refreshResult.title,
                                feedURL: refreshResult.feed,
                                result: podcastResult
                            )
                        )
#endif
                    case .timedOut:
                        timedOut += 1
                        CrashBreadcrumbs.shared.record(
                            "bgupdate_feed_timed_out",
                            details: "feed=\(refreshResult.feed.absoluteString),last_check_age=\(refreshResult.lastCheckAge)s"
                        )
#if DEBUG
                        checkedPodcasts.append(
                            RefreshHistoryPodcastCheck(
                                title: refreshResult.title,
                                feedURL: refreshResult.feed,
                                result: .timedOut
                            )
                        )
#endif
                    }
                }
            }
        }

        CrashBreadcrumbs.shared.record(
            "bgupdate_feeds_completed",
            details: "processed=\(processed),updated=\(updated),timed_out=\(timedOut),duration=\(Int(Date().timeIntervalSince(startedAt)))s"
        )
#if DEBUG
        await RefreshHistoryStore.shared.record(
            RefreshHistoryEntry(
                startedAt: startedAt,
                finishedAt: Date(),
                trigger: refreshHistoryTrigger(for: reason),
                checkedPodcasts: checkedPodcasts
            )
        )
#endif
        WatchSyncCoordinator.refreshSoon()
        await FeedRefreshRunCoordinator.shared.finish()
    }

#if DEBUG
    private func refreshHistoryTrigger(for reason: FeedRefreshReason) -> RefreshHistoryTrigger {
        switch reason {
        case .foregroundQuiet:
            .backgroundForegroundQuiet
        case .appRefresh:
            .backgroundAppRefresh
        case .processing:
            .backgroundProcessing
        }
    }
#endif
    
    func getLastRefreshDate() -> Date? {
        let lastDate = Date.dateFromRFC1123(dateString: UserDefaults.standard.string(forKey: "LastBackgroundRefresh") ?? "")
        return lastDate
    }
    
    func setLastRefreshDate(){
        UserDefaults.standard.setValue(Date().RFC1123String(), forKey: "LastBackgroundRefresh")
    }
    
    private func latestFetchedEpisode(for podcast: Podcast) -> Episode? {
        podcast.episodes?.max {
            ($0.publishDate ?? .distantPast) < ($1.publishDate ?? .distantPast)
        }
    }

    private func opmlAttribute(_ name: String, _ value: String?) -> String {
        guard let value, value.isEmpty == false else { return "" }
        return " \(name)=\"\(value.xmlEscaped)\""
    }

    func generateOPML() -> String {
        fetchData()
        // print("generate OPML")
        var opmlString = """
    <?xml version="1.0" encoding="UTF-8"?>\n
    <opml version="1.1">\n
        <head>\n
            <title>Up Next Podcasts</title>\n
        </head>\n
        <body>\n
    """
        
        for podcast in podcasts {
            let latestEpisode = latestFetchedEpisode(for: podcast)
            let lastRefresh = podcast.metaData?.lastRefresh?.opmlMetadataString()
            let lastEpisodeDate = latestEpisode?.publishDate?.opmlMetadataString()
            let lastEpisodeURL = latestEpisode?.url?.absoluteString

            opmlString += """
            <outline text="\(podcast.title.xmlEscaped)" type="rss" xmlUrl="\((podcast.feed?.absoluteString ?? "").xmlEscaped)"\(opmlAttribute("upnextLastRefresh", lastRefresh))\(opmlAttribute("upnextLastEpisodeDate", lastEpisodeDate))\(opmlAttribute("upnextLastEpisodeURL", lastEpisodeURL)) />\n
        """
        }
        
        opmlString += """
        </body>\n
    </opml>\n
    """
        
        return opmlString
    }
    



}

private actor FeedRefreshRunCoordinator {
    static let shared = FeedRefreshRunCoordinator()

    private var isRunning = false

    func begin() -> Bool {
        guard isRunning == false else { return false }
        isRunning = true
        return true
    }

    func finish() {
        isRunning = false
    }
}

extension String {
    var xmlEscaped: String {
        var escaped = self
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
        return escaped
    }
}

struct PodcastReleasePredictor {
    struct Prediction {
        let releaseDate: Date
        let refreshStart: Date
        let refreshEnd: Date
    }

    private struct WeeklySlot {
        let weekday: Int
        let minuteOfDay: Int
    }

    private static let maximumEpisodes = 32
    private static let minimumEpisodes = 3
    private static let refreshLeadTime: TimeInterval = 30 * 60
    private static let minimumInterval: TimeInterval = 6 * 60 * 60
    private static let maximumInterval: TimeInterval = 45 * 24 * 60 * 60
    private static let minimumIrregularIntervals = 4
    private static let irregularIntervalPercentile = 0.75
    private static let minimumFollowUpTime: TimeInterval = 3 * 60 * 60
    private static let maximumFollowUpTime: TimeInterval = 24 * 60 * 60

    static func prediction(
        for podcast: Podcast,
        after now: Date,
        allowRelationshipFallback: Bool = false
    ) -> Prediction? {
        let dates = recentPublishDates(
            for: podcast,
            before: now.addingTimeInterval(24 * 60 * 60),
            limit: maximumEpisodes,
            allowRelationshipFallback: allowRelationshipFallback
        )
        return prediction(
            from: dates,
            after: now,
            calendar: .autoupdatingCurrent
        )
    }

    @discardableResult
    static func updateCachedPrediction(
        for podcast: Podcast,
        after now: Date,
        allowRelationshipFallback: Bool = false
    ) -> Prediction? {
        let prediction = prediction(
            for: podcast,
            after: now,
            allowRelationshipFallback: allowRelationshipFallback
        )

        guard let metaData = podcast.metaData else {
            return prediction
        }

        let releaseDate = prediction?.releaseDate
        let refreshStart = prediction?.refreshStart
        let refreshEnd = prediction?.refreshEnd

        guard metaData.nextPredictedReleaseDate != releaseDate
            || metaData.nextPredictedRefreshStartDate != refreshStart
            || metaData.nextPredictedRefreshEndDate != refreshEnd
        else {
            return prediction
        }

        metaData.nextPredictedReleaseDate = releaseDate
        metaData.nextPredictedRefreshStartDate = refreshStart
        metaData.nextPredictedRefreshEndDate = refreshEnd
        metaData.releasePredictionUpdatedAt = now
        return prediction
    }

    static func prediction(
        from publishDates: [Date],
        after now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Prediction? {
        let dates = normalizedPublishDates(publishDates, before: now.addingTimeInterval(24 * 60 * 60))
        guard dates.count >= minimumEpisodes, let latestRelease = dates.last else { return nil }

        let intervals = zip(dates.dropFirst(), dates)
            .map { newer, older in newer.timeIntervalSince(older) }
            .filter { $0 >= minimumInterval && $0 <= maximumInterval }
        guard intervals.count >= minimumEpisodes - 1 else { return nil }

        let typicalInterval = median(intervals)
        let followUpTime = min(
            maximumFollowUpTime,
            max(minimumFollowUpTime, typicalInterval * 0.25)
        )

        let nextRelease: Date
        if let slots = recurringWeeklySlots(
            from: dates,
            typicalInterval: typicalInterval,
            calendar: calendar
        ), let scheduledRelease = nextScheduledRelease(
            in: slots,
            afterLatestRelease: latestRelease,
            now: now,
            followUpTime: followUpTime,
            calendar: calendar
        ) {
            nextRelease = scheduledRelease
        } else {
            let interval: TimeInterval
            if intervalIsConsistent(intervals, around: typicalInterval) {
                interval = typicalInterval
            } else if let irregularInterval = irregularReleaseInterval(from: intervals) {
                interval = irregularInterval
            } else {
                return nil
            }

            nextRelease = nextIntervalRelease(
                afterLatestRelease: latestRelease,
                interval: interval,
                now: now,
                followUpTime: followUpTime
            )
        }

        return Prediction(
            releaseDate: nextRelease,
            refreshStart: nextRelease.addingTimeInterval(-refreshLeadTime),
            refreshEnd: nextRelease.addingTimeInterval(followUpTime)
        )
    }

    /// The most recent episode publish dates for the podcast, fetched with a
    /// bounded query rather than faulting the whole `podcast.episodes`
    /// relationship. Only `publishDate` is fetched, so the episodes' expensive
    /// transformable attributes (deeplinks/funding/social/people/tags) are never
    /// decoded — faulting every episode of every podcast here previously blocked
    /// the main thread long enough to trip the 10s scene-update watchdog.
    private static func recentPublishDates(
        for podcast: Podcast,
        before cutoff: Date,
        limit: Int,
        allowRelationshipFallback: Bool
    ) -> [Date] {
        guard let feed = podcast.feed, let context = podcast.modelContext else {
            // Fallback for a detached podcast with no backing context.
            return relationshipPublishDates(for: podcast, before: cutoff, limit: limit)
        }
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.podcast?.feed == feed
                    && episode.publishDate != nil
                    && episode.publishDate! < cutoff
            },
            sortBy: [SortDescriptor(\Episode.publishDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        descriptor.propertiesToFetch = [\Episode.publishDate]

        do {
            let dates = try context.fetch(descriptor).compactMap(\.publishDate)
            if dates.isEmpty == false || allowRelationshipFallback == false {
                return dates
            }
        } catch {
            if allowRelationshipFallback == false {
                return []
            }
        }

        return relationshipPublishDates(for: podcast, before: cutoff, limit: limit)
    }

    private static func relationshipPublishDates(
        for podcast: Podcast,
        before cutoff: Date,
        limit: Int
    ) -> [Date] {
        Array(
            (podcast.episodes ?? [])
                .compactMap(\.publishDate)
                .filter { $0 < cutoff }
                .sorted(by: >)
                .prefix(limit)
        )
    }

    private static func normalizedPublishDates(_ dates: [Date], before cutoff: Date) -> [Date] {
        let sorted = dates
            .filter { $0 < cutoff }
            .sorted()
            .suffix(maximumEpisodes)

        return sorted.reduce(into: [Date]()) { result, date in
            guard let previous = result.last else {
                result.append(date)
                return
            }

            // Bonus episodes and corrected feed entries published within a few
            // hours should not look like a new recurring release slot.
            if date.timeIntervalSince(previous) >= minimumInterval {
                result.append(date)
            }
        }
    }

    private static func recurringWeeklySlots(
        from dates: [Date],
        typicalInterval: TimeInterval,
        calendar: Calendar
    ) -> [WeeklySlot]? {
        guard typicalInterval <= 8 * 24 * 60 * 60 else { return nil }

        let grouped = Dictionary(grouping: dates) { calendar.component(.weekday, from: $0) }
        guard let maximumCount = grouped.values.map(\.count).max(), maximumCount >= 2 else {
            return nil
        }

        let minimumWeekdayCount = max(2, Int(ceil(Double(maximumCount) * 0.6)))
        let activeGroups = grouped.filter { $0.value.count >= minimumWeekdayCount }
        let representedDates = activeGroups.values.reduce(0) { $0 + $1.count }
        guard Double(representedDates) / Double(dates.count) >= 0.75 else { return nil }

        if activeGroups.count == 1, let weekdayDates = activeGroups.values.first {
            let sameWeekdayIntervals = zip(weekdayDates.dropFirst(), weekdayDates)
                .map { newer, older in newer.timeIntervalSince(older) }
            guard sameWeekdayIntervals.isEmpty == false,
                  median(sameWeekdayIntervals) <= 9 * 24 * 60 * 60 else {
                // A fortnightly show happens on the same weekday too, but must
                // remain an interval schedule rather than being checked weekly.
                return nil
            }
        }

        let slots = activeGroups.compactMap { weekday, weekdayDates -> WeeklySlot? in
            let minutes = weekdayDates.map { minuteOfDay(for: $0, calendar: calendar) }
            let typicalMinute = Int(median(minutes.map(TimeInterval.init)))
            let deviations = minutes.map { circularMinuteDistance($0, typicalMinute) }
            guard median(deviations.map(TimeInterval.init)) <= 3 * 60 else { return nil }
            return WeeklySlot(weekday: weekday, minuteOfDay: typicalMinute)
        }

        guard slots.count == activeGroups.count else { return nil }
        return slots
    }

    /// The predicted slot anchors to the episode we have *not yet fetched*: it
    /// stays on the slot following the latest known release until either that
    /// episode actually lands (advancing `latestRelease`) or the follow-up
    /// window lapses (treating it as a skipped week). It deliberately does *not*
    /// consult `feedUpdateCheckDate` — a bare HEAD/"not modified" probe must not
    /// look like the release was handled, otherwise an in-window episode behind a
    /// stale `Last-Modified` header would be dropped from the refresh queue.
    private static func nextScheduledRelease(
        in slots: [WeeklySlot],
        afterLatestRelease latestRelease: Date,
        now: Date,
        followUpTime: TimeInterval,
        calendar: Calendar
    ) -> Date? {
        guard var candidate = nextWeeklySlot(
            in: slots,
            after: latestRelease.addingTimeInterval(minimumInterval),
            calendar: calendar
        ) else {
            return nil
        }

        while candidate < now.addingTimeInterval(-followUpTime) {
            guard let following = nextWeeklySlot(in: slots, after: candidate, calendar: calendar) else {
                return nil
            }
            candidate = following
        }

        return candidate
    }

    private static func nextWeeklySlot(
        in slots: [WeeklySlot],
        after lowerBound: Date,
        calendar: Calendar
    ) -> Date? {
        let startOfDay = calendar.startOfDay(for: lowerBound)
        var candidates: [Date] = []

        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else {
                continue
            }
            let weekday = calendar.component(.weekday, from: day)
            for slot in slots where slot.weekday == weekday {
                guard let candidate = calendar.date(
                    bySettingHour: slot.minuteOfDay / 60,
                    minute: slot.minuteOfDay % 60,
                    second: 0,
                    of: day
                ), candidate > lowerBound else {
                    continue
                }
                candidates.append(candidate)
            }
        }

        return candidates.min()
    }

    private static func nextIntervalRelease(
        afterLatestRelease latestRelease: Date,
        interval: TimeInterval,
        now: Date,
        followUpTime: TimeInterval
    ) -> Date {
        var candidate = latestRelease.addingTimeInterval(interval)
        while candidate < now.addingTimeInterval(-followUpTime) {
            candidate = candidate.addingTimeInterval(interval)
        }
        return candidate
    }

    private static func intervalIsConsistent(
        _ intervals: [TimeInterval],
        around typicalInterval: TimeInterval
    ) -> Bool {
        let deviations = intervals.map { abs($0 - typicalInterval) }
        let allowedDeviation = max(2 * 60 * 60, typicalInterval * 0.25)
        return median(deviations) <= allowedDeviation
    }

    private static func irregularReleaseInterval(from intervals: [TimeInterval]) -> TimeInterval? {
        guard intervals.count >= minimumIrregularIntervals else { return nil }
        return upperPercentile(intervals, percentile: irregularIntervalPercentile)
    }

    private static func upperPercentile(
        _ values: [TimeInterval],
        percentile: Double
    ) -> TimeInterval {
        let sorted = values.sorted()
        let clampedPercentile = min(1, max(0, percentile))
        let index = Int(ceil(Double(sorted.count - 1) * clampedPercentile))
        return sorted[min(sorted.count - 1, max(0, index))]
    }

    private static func minuteOfDay(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func circularMinuteDistance(_ lhs: Int, _ rhs: Int) -> Int {
        let direct = abs(lhs - rhs)
        return min(direct, 24 * 60 - direct)
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

struct PodcastBackgroundRefreshPriority {
    /// Feeds that have not actually been parsed within this interval earn a
    /// baseline boost on general-purpose runs, providing the "every podcast at
    /// least daily" floor regardless of whether the feed is modelled.
    static let dailyStalenessInterval: TimeInterval = 24 * 60 * 60
    static let postReleaseRetryInterval: TimeInterval = 30 * 60

    /// Priority tiers, highest first.
    enum Tier: Int {
        case overdue = 100        // inside the window and the episode is already due
        case imminentWindow = 70  // inside the window, episode not quite due yet
        case withinHour = 60      // window opens within the hour
        case withinThreeHours = 40
        case staleFloor = 50      // not parsed in a day — the daily catch-up floor
        case idle = 0
    }

    /// `lastRefresh` is the last time the feed was *actually parsed* (not a bare
    /// HEAD probe), so the staleness floor reflects real fetches. The prediction
    /// stays anchored on an unfetched in-window release, so "inside the window"
    /// already implies "episode not yet captured" — no separate check-date guard
    /// is needed (and using one would mis-handle stale `Last-Modified` headers).
    static func score(
        prediction: PodcastReleasePredictor.Prediction?,
        now: Date,
        lastRefresh: Date?,
        retryDelay: TimeInterval = postReleaseRetryInterval
    ) -> Int {
        let isStale = lastRefresh.map { now.timeIntervalSince($0) >= dailyStalenessInterval } ?? true
        let staleFloor = isStale ? Tier.staleFloor.rawValue : Tier.idle.rawValue

        guard let prediction else {
            return staleFloor
        }

        // At or past the window opening we expect an episode we have not fetched
        // yet (the predictor only advances once the real episode lands or the
        // window lapses). Overdue outranks not-yet-due.
        if now >= prediction.refreshStart {
            if let lastRefresh,
               lastRefresh >= prediction.releaseDate,
               now < lastRefresh.addingTimeInterval(retryDelay) {
                return staleFloor
            }

            return now >= prediction.releaseDate
                ? Tier.overdue.rawValue
                : Tier.imminentWindow.rawValue
        }

        let secondsUntilWindow = prediction.refreshStart.timeIntervalSince(now)
        if secondsUntilWindow <= 60 * 60 { return max(Tier.withinHour.rawValue, staleFloor) }
        if secondsUntilWindow <= 3 * 60 * 60 { return max(Tier.withinThreeHours.rawValue, staleFloor) }

        // A reliable but distant prediction is scheduling information, not refresh
        // urgency; fall back to the daily staleness floor.
        return staleFloor
    }

    /// Whether a podcast is inside (or past) its predicted refresh window and so
    /// should be parsed in full, bypassing the `Last-Modified` short-circuit.
    static func shouldForceParse(
        prediction: PodcastReleasePredictor.Prediction?,
        now: Date
    ) -> Bool {
        guard let prediction else { return false }
        return now >= prediction.refreshStart
    }
}
