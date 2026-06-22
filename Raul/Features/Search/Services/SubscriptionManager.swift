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
    
    private enum TimedPodcastUpdateResult {
        case completed(Bool?)
        case timedOut
    }

    enum FeedRefreshReason {
        case foregroundQuiet
        case appRefresh
        case processing
    }

    private func updatePodcastWithTimeBudget(
        _ feed: URL,
        timeBudget: TimeInterval,
        notifyNewEpisodes: Bool
    ) async -> TimedPodcastUpdateResult {
        let worker = PodcastModelActor(modelContainer: modelContainer)
        let deadline = Date().addingTimeInterval(timeBudget)

        do {
            let updated = try await worker.updatePodcast(
                feed,
                silent: true,
                processNewEpisodesDuringSilentRefresh: notifyNewEpisodes,
                deadline: deadline
            )
            return Date() >= deadline ? .timedOut : .completed(updated)
        } catch is CancellationError {
            return .timedOut
        } catch {
            return .completed(false)
        }
    }

    

    func nextPredictedFeedRefreshDate(after now: Date = Date()) async -> Date? {
        fetchData()
        return podcasts
            .filter { $0.metaData?.isSubscribed != false }
            .compactMap { PodcastReleasePredictor.prediction(for: $0, after: now)?.refreshStart }
            .min()
    }

    private func podcastsPrioritizedForBackgroundRefresh(now: Date) -> [Podcast] {
        podcasts
            .filter { $0.metaData?.isSubscribed != false }
            .sorted { lhs, rhs in
                let lhsPrediction = PodcastReleasePredictor.prediction(for: lhs, after: now)
                let rhsPrediction = PodcastReleasePredictor.prediction(for: rhs, after: now)
                let lhsScore = backgroundRefreshScore(for: lhs, prediction: lhsPrediction, now: now)
                let rhsScore = backgroundRefreshScore(for: rhs, prediction: rhsPrediction, now: now)
                if lhsScore != rhsScore { return lhsScore > rhsScore }

                let lhsCheck = lhs.metaData?.feedUpdateCheckDate ?? .distantPast
                let rhsCheck = rhs.metaData?.feedUpdateCheckDate ?? .distantPast
                if lhsCheck != rhsCheck { return lhsCheck < rhsCheck }
                return (lhs.metaData?.lastRefresh ?? .distantPast) < (rhs.metaData?.lastRefresh ?? .distantPast)
            }
    }

    private func backgroundRefreshScore(
        for podcast: Podcast,
        prediction: PodcastReleasePredictor.Prediction?,
        now: Date
    ) -> Int {
        guard let prediction else { return 0 }
        let lastCheck = podcast.metaData?.feedUpdateCheckDate ?? .distantPast
        if lastCheck >= prediction.refreshStart, lastCheck <= prediction.refreshEnd {
            return 25
        }
        if now >= prediction.refreshStart, now <= prediction.refreshEnd {
            return 100
        }
        if now > prediction.refreshEnd {
            return 75
        }
        let secondsUntilWindow = prediction.refreshStart.timeIntervalSince(now)
        if secondsUntilWindow <= 60 * 60 { return 60 }
        if secondsUntilWindow <= 3 * 60 * 60 { return 40 }
        return 10
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
        let maxPodcastsPerRun: Int
        let maxRuntime: TimeInterval
        let perPodcastRuntimeLimit: TimeInterval
        let notifyNewEpisodes = true

        switch reason {
        case .foregroundQuiet:
            maxPodcastsPerRun = 3
            maxRuntime = 24
            perPodcastRuntimeLimit = 7
        case .appRefresh:
            maxPodcastsPerRun = 4
            maxRuntime = 25
            perPodcastRuntimeLimit = 7
        case .processing:
            maxPodcastsPerRun = Int.max
            maxRuntime = 600
            perPodcastRuntimeLimit = 20
        }

        setLastRefreshDate()
        fetchData()
        var updated = 0
        var processed = 0
        var reachedPerPodcastTimeout = false

        CrashBreadcrumbs.shared.record(
            "bgupdate_feeds_started",
            details: "reason=\(reason),podcasts=\(podcasts.count),limit=\(maxPodcastsPerRun)"
        )

        let sortedPodcasts = podcastsPrioritizedForBackgroundRefresh(now: startedAt)

        for podcast in sortedPodcasts {
            if processed >= maxPodcastsPerRun {
                CrashBreadcrumbs.shared.record("bgupdate_feeds_stopped", details: "reason=max_podcasts")
                break
            }
            if Date().timeIntervalSince(startedAt) >= maxRuntime {
                CrashBreadcrumbs.shared.record("bgupdate_feeds_stopped", details: "reason=max_runtime")
                break
            }
            guard let feed = podcast.feed else { continue }

            processed += 1
            let result = await updatePodcastWithTimeBudget(
                feed,
                timeBudget: perPodcastRuntimeLimit,
                notifyNewEpisodes: notifyNewEpisodes
            )
            podcast.message = nil

            switch result {
            case .completed(let new):
                if new == true { updated += 1 }
            case .timedOut:
                CrashBreadcrumbs.shared.record(
                    "bgupdate_feeds_stopped",
                    details: "reason=per_podcast_timeout"
                )
                reachedPerPodcastTimeout = true
            }

            if reachedPerPodcastTimeout {
                break
            }
        }

        CrashBreadcrumbs.shared.record(
            "bgupdate_feeds_completed",
            details: "processed=\(processed),updated=\(updated),duration=\(Int(Date().timeIntervalSince(startedAt)))s"
        )
        WatchSyncCoordinator.refreshSoon()
        await FeedRefreshRunCoordinator.shared.finish()
    }
    
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

    private static let calendar = Calendar.autoupdatingCurrent
    private static let maximumEpisodes = 12
    private static let minimumEpisodes = 3
    private static let refreshLeadTime: TimeInterval = 30 * 60
    private static let refreshFollowUpTime: TimeInterval = 3 * 60 * 60
    private static let minimumInterval: TimeInterval = 6 * 60 * 60
    private static let maximumInterval: TimeInterval = 14 * 24 * 60 * 60

    static func prediction(for podcast: Podcast, after now: Date) -> Prediction? {
        let dates = (podcast.episodes ?? [])
            .compactMap(\.publishDate)
            .filter { $0 < now.addingTimeInterval(24 * 60 * 60) }
            .sorted(by: >)
            .prefix(maximumEpisodes)

        guard dates.count >= minimumEpisodes else { return nil }

        let sortedAscending = dates.sorted()
        let intervals = zip(sortedAscending.dropFirst(), sortedAscending)
            .map { newer, older in newer.timeIntervalSince(older) }
            .filter { $0 >= minimumInterval && $0 <= maximumInterval }

        guard intervals.count >= minimumEpisodes - 1 else { return nil }

        let interval = median(intervals)
        var nextRelease = sortedAscending.last!.addingTimeInterval(interval)
        while nextRelease <= now.addingTimeInterval(-refreshFollowUpTime) {
            nextRelease = nextRelease.addingTimeInterval(interval)
        }

        if let anchored = weekdayAndTimeAnchoredDate(from: Array(sortedAscending), near: nextRelease, after: now) {
            nextRelease = anchored
        }

        return Prediction(
            releaseDate: nextRelease,
            refreshStart: nextRelease.addingTimeInterval(-refreshLeadTime),
            refreshEnd: nextRelease.addingTimeInterval(refreshFollowUpTime)
        )
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func weekdayAndTimeAnchoredDate(from dates: [Date], near estimate: Date, after now: Date) -> Date? {
        let grouped = Dictionary(grouping: dates) { calendar.component(.weekday, from: $0) }
        guard let (weekday, weekdayDates) = grouped.max(by: { $0.value.count < $1.value.count }), weekdayDates.count >= 2 else {
            return nil
        }

        let minuteOfDayValues = weekdayDates.map {
            let components = calendar.dateComponents([.hour, .minute], from: $0)
            return (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
        let minuteOfDay = Int(median(minuteOfDayValues.map(TimeInterval.init)))

        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: estimate)
        components.weekday = weekday
        components.hour = minuteOfDay / 60
        components.minute = minuteOfDay % 60
        components.second = 0

        guard var anchored = calendar.date(from: components) else { return nil }
        let interval = max(median(zip(dates.dropFirst(), dates).map { $0.timeIntervalSince($1) }), 24 * 60 * 60)
        while anchored <= now.addingTimeInterval(-refreshFollowUpTime) {
            anchored = anchored.addingTimeInterval(interval)
        }
        return anchored
    }
}
