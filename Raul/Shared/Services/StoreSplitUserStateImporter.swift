import Foundation
import SwiftData

/// What one import pass did to one synchronized stream. A no-op pass reports
/// rows fetched but zero changed rows and zero saves.
struct StoreSplitUserStateStreamMetrics: Equatable, Sendable {
    var rowsFetched = 0
    var rowsChanged = 0
    var saves = 0
    var fullPass = false
}

struct StoreSplitUserStateImportResult: Sendable {
    var subscriptionsApplied = 0
    var episodeStatesApplied = 0
    var playlistsApplied = 0
    var playlistEntriesApplied = 0
    var bookmarksApplied = 0
    var preferencesApplied = 0
    var listeningHistoryApplied = 0
    var duplicatePodcastsHidden = 0
    var feedsToBootstrap: [URL] = []
    /// Credential-free feed identities that were retained but intentionally
    /// not fetched because this device has not supplied their credential yet.
    var feedsAwaitingCredentials: [URL] = []
    var credentialRequiredProfileIDs: [String] = []
    var playlistFeedsToBootstrap: [URL] = []
    /// Streams containing records that could not yet be projected. Their
    /// cursors must stay eligible until targeted retry has durably completed.
    var unresolvedStreams: Set<StoreSplitUserStateStream> = []
    var failed = 0
    var interruptedByPlayback = false
    var streamMetrics: [StoreSplitUserStateStream: StoreSplitUserStateStreamMetrics] = [:]
    /// Library saves made by this pass, across all streams.
    var librarySaves: Int {
        streamMetrics.values.reduce(0) { $0 + $1.saves }
    }
}

actor StoreSplitUserStateImporter {
    private var sourceReadFailed = false
    private let sourcePageSize = 200
    private let historyPageSize = 100
    /// Page size for the last-resort feed scan. Kept small so each batch of
    /// faulted episodes is released before the next one loads.
    private let episodeScanPageSize = 200
    private let legacyContainer: ModelContainer
    private let userStateContainer: ModelContainer
    private let cacheContainer: ModelContainer?
    private let isInitialRuntimeHydration: Bool
    /// Narrow imports touch few rows, so they don't have to wait out playback.
    private let continuesDuringPlayback: Bool
    private let episodeStatesUpdatedSince: Date?
    /// Upgraded devices only: see `StoreCutoverState.localLibraryStartedAt`.
    private let subscriptionCreationCutoff: Date?
    private let credentialStore: any PodcastCredentialStore
    private let previousImportCursors: [StoreSplitUserStateStream: StoreSplitImportCursor]
    /// Where per-batch cursor progress is persisted; nil reads and writes no
    /// cursor, so every stream is walked in full.
    private let cursorDefaults: UserDefaults?
    /// A user-requested reconcile walks the small streams in full instead of
    /// trusting the cursors.
    private let forcesFullPass: Bool
    private var streamMetrics: [StoreSplitUserStateStream: StoreSplitUserStateStreamMetrics] = [:]
    /// Normalized feed keys of podcasts this pass created from subscriptions;
    /// their preferences may have been imported before the podcast existed.
    private var createdPodcastFeedKeys: Set<String> = []
    private var podcastIndexBuilt = false
    private var completedDeltaBatches = 0
    private var legacyContext: ModelContext
    private var userStateContext: ModelContext
    private var podcastsByComparisonKey: [String: PersistentIdentifier] = [:]
    private var resolvedEpisodeIDsByIdentity: [String: PersistentIdentifier] = [:]
    /// Identities this run has already tried and failed to resolve.
    ///
    /// Deliberately a separate set rather than a `nil` value in the map above:
    /// with an optional value type, `map[key] = nil` *removes* the key instead of
    /// recording the miss, so the negative cache the resolver was written around
    /// never actually held anything.
    private var unresolvableEpisodeIdentities: Set<String> = []
    /// Feeds whose episodes have all been walked by the last-resort scan, so
    /// every identity they can produce is already in the map above.
    ///
    /// A negative cache keyed on the identity alone cannot bound the scan: each
    /// page of synced state brings *new* unresolvable identities for the same
    /// feed, so the scan re-ran per page and paged the whole feed every time.
    /// Rescanning a feed already walked end to end cannot find anything new.
    private var fullyScannedFeeds: Set<String> = []
#if DEBUG
    nonisolated(unsafe) static var debugPodcastIndexBuildCount = 0
    /// Test hook: how many last-resort whole-feed scans have run in this process.
    /// The negative cache above is the only thing that keeps this bounded, so a
    /// regression in it shows up here and nowhere else — the import's output is
    /// identical either way, just orders of magnitude more expensive.
    nonisolated(unsafe) static var debugFeedScanCount = 0
    /// Test hook: smaller source pages so batch boundaries can be exercised.
    nonisolated(unsafe) static var debugSourcePageSizeOverride: Int?
    /// Test hook: behave as if interrupted after this many saved delta batches.
    nonisolated(unsafe) static var debugStopAfterDeltaBatches: Int?
#endif

    private init(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        credentialStore: any PodcastCredentialStore,
        cacheContainer: ModelContainer? = nil,
        isInitialRuntimeHydration: Bool = false,
        continuesDuringPlayback: Bool = false,
        episodeStatesUpdatedSince: Date? = nil,
        cursorSuiteName: String? = nil,
        forcesFullPass: Bool = false
    ) {
        let cursorDefaults = cursorSuiteName.flatMap { UserDefaults(suiteName: $0) }
        self.cursorDefaults = cursorDefaults
        self.forcesFullPass = forcesFullPass
        self.continuesDuringPlayback = continuesDuringPlayback
        self.episodeStatesUpdatedSince = episodeStatesUpdatedSince
        self.legacyContainer = legacyContainer
        self.userStateContainer = userStateContainer
        self.cacheContainer = cacheContainer
        self.isInitialRuntimeHydration = isInitialRuntimeHydration
        self.subscriptionCreationCutoff = StoreCutoverState.localLibraryStartedAt
        self.credentialStore = credentialStore
        previousImportCursors = cursorDefaults.map {
            StoreSplitImportCursorStore.load(defaults: $0)
        } ?? [:]
        legacyContext = ModelContext(legacyContainer)
        userStateContext = ModelContext(userStateContainer)
        legacyContext.autosaveEnabled = false
        userStateContext.autosaveEnabled = false
    }

    nonisolated static func apply(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer,
        credentialStore: any PodcastCredentialStore = PodcastCredentialStoreProvider.current,
        cacheContainer: ModelContainer? = nil,
        authoritativePlaylists: Bool = false,
        projectListeningHistoryToLegacy: Bool = true,
        episodeStateProjectionRecencyCutoff: Date? = nil,
        isInitialRuntimeHydration: Bool = false,
        continuesDuringPlayback: Bool = false,
        episodeStatesUpdatedSince: Date? = nil,
        changedStreams: Set<StoreSplitUserStateStream> = Set(
            StoreSplitUserStateStream.allCases
        ),
        cursorSuiteName: String? = StoreSplitImportCursorStore.importerSuiteName
    ) async -> StoreSplitUserStateImportResult {
        // Run inline (not detached) so cancellation from the caller's task
        // propagates into the importer. A detached task would keep scanning the
        // legacy store after the app is backgrounded, holding the app-group
        // SQLite lock across suspension and triggering an 0xdead10cc kill.
        let importer = StoreSplitUserStateImporter(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            credentialStore: credentialStore,
            cacheContainer: cacheContainer,
            isInitialRuntimeHydration: isInitialRuntimeHydration,
            continuesDuringPlayback: continuesDuringPlayback,
            episodeStatesUpdatedSince: episodeStatesUpdatedSince,
            cursorSuiteName: cursorSuiteName,
            forcesFullPass: authoritativePlaylists
        )
        var result = await importer.run(
            authoritativePlaylists: authoritativePlaylists,
            projectListeningHistoryToLegacy: projectListeningHistoryToLegacy,
            episodeStateProjectionRecencyCutoff: episodeStateProjectionRecencyCutoff,
            changedStreams: changedStreams
        )
        if await importer.sourceReadFailed { result.failed += 1 }
        // Collected here rather than in `run` so an interrupted or failed pass
        // still reports what it read and wrote.
        result.streamMetrics = await importer.streamMetrics
        await importer.logStreamMetrics(result: result)
        return result
    }

#if DEBUG
    /// Projects **only** the synchronized listening history and summaries back
    /// onto the library graph.
    ///
    /// Sessions recorded while the runtime container was the in-memory cache
    /// projection never reached `SharedDatabase.sqlite` — they survive only in
    /// `ListeningHistorySync`. The `dualSyncBackfill` release leaves the importer
    /// off, so nothing brings them back on its own; this is the one-off recovery
    /// for a development device that spent time on those builds.
    ///
    /// Deliberately not wired into launch: it is the same projection pass that
    /// dominated the disk-write storm, so it stays an explicit, observable action.
    nonisolated static func applyListeningHistoryOnly(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) async -> StoreSplitUserStateImportResult {
        let importer = StoreSplitUserStateImporter(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            credentialStore: PodcastCredentialStoreProvider.current
        )
        return await importer.runListeningHistoryOnly()
    }

    private func runListeningHistoryOnly() async -> StoreSplitUserStateImportResult {
        var result = StoreSplitUserStateImportResult()
        guard Task.isCancelled == false else {
            result.interruptedByPlayback = true
            return result
        }
        await awaitIdleWindow()
        // Episode resolution's last-resort feed scan needs this index; without it
        // history for episodes whose GUID/URL lookup misses would be dropped.
        await buildPodcastIndex()

        await applyListeningHistory(result: &result)
        saveLegacyChanges(phase: "recovery_listening_history", result: &result)

        CrashBreadcrumbs.shared.record(
            "store_split_listening_history_recovery_completed",
            details: "history=\(result.listeningHistoryApplied),failed=\(result.failed)"
        )
        return result
    }
#endif

    private func run(
        authoritativePlaylists: Bool,
        projectListeningHistoryToLegacy: Bool,
        episodeStateProjectionRecencyCutoff: Date?,
        changedStreams: Set<StoreSplitUserStateStream>
    ) async -> StoreSplitUserStateImportResult {
        var result = StoreSplitUserStateImportResult()
        guard Task.isCancelled == false else {
            result.interruptedByPlayback = true
            return result
        }
        await awaitIdleWindow()
        // Episode state resolves its rows by GUID/URL first and only needs the
        // podcast index for the last-resort feed scan, which builds it lazily.
        // A playback-position-only change therefore never reads the library's
        // podcast list.
        let needsPodcastIndex = changedStreams.intersection([
            .subscriptions,
            .playlists,
            .playlistEntries,
            .queueEntries,
            .bookmarks,
            .preferences,
            .listeningHistory
        ]).isEmpty == false
        let podcasts = needsPodcastIndex ? await buildPodcastIndex() : []
        // A failed index read must not look like an empty library: doing so
        // could create duplicate podcasts or commit incomplete projections.
        guard sourceReadFailed == false else { return result }

        let subscriptions: [String: SubscriptionSync]
        var subscriptionReader = makeDeltaReader(for: .subscriptions, periodicFullPass: true)
        let subscriptionsFailedBefore = result.failed
        if changedStreams.contains(.subscriptions) {
            // Subscriptions are bounded by the library size, so the changed
            // rows are collected first and deduplicated across pages before
            // anything is applied.
            var records: [SubscriptionSync] = []
            while let page = nextDeltaPage(Self.subscriptionDelta, reader: &subscriptionReader) {
                records.append(contentsOf: page)
            }
            guard sourceReadFailed == false else {
                CrashBreadcrumbs.shared.record("store_split_import_subscriptions_fetch_failed")
                return result
            }
            subscriptions = deduplicatedSubscriptions(records)
        } else {
            subscriptions = [:]
        }
        let accessResolver = PodcastAccessResolver(credentialStore: credentialStore)
        if changedStreams.contains(.subscriptions) {
        for subscription in subscriptions.values {
            if await shouldStop() {
                result.interruptedByPlayback = true
                return result
            }
            guard let manifestFeedURL = URL(string: subscription.feedURL) else {
                result.failed += 1
                continue
            }
            let locallyKnownPodcast = manifestFeedURL.podcastFeedComparisonKeys
                .compactMap { podcastsByComparisonKey[$0].flatMap(indexedPodcast) }
                .first
            // A legacy/partial UserState record may omit access metadata even
            // though the library already has the authoritative local profile.
            let accessProfile = locallyKnownPodcast.flatMap(storedPodcastAccessProfile(for:))
                ?? accessProfile(for: subscription, resourceURL: manifestFeedURL)
            let bootstrapDecision = accessResolver.bootstrapDecision(
                for: accessProfile,
                fallbackURL: manifestFeedURL
            )
            let resolvedFeedURL: URL
            let hasCredential: Bool
            switch bootstrapDecision {
            case .publicFeed(let url), .ready(let url):
                resolvedFeedURL = url
                hasCredential = true
            case .credentialsRequired(let profileID, let feedURL):
                resolvedFeedURL = feedURL
                hasCredential = false
                result.feedsAwaitingCredentials.append(feedURL)
                result.credentialRequiredProfileIDs.append(profileID)
            }
            var createdPodcast = false
            let podcast = locallyKnownPodcast ?? resolvedFeedURL.podcastFeedComparisonKeys.compactMap {
                podcastsByComparisonKey[$0].flatMap(indexedPodcast)
            }.first ?? {
                guard subscription.isSubscribed else { return nil }
                if let startedAt = subscriptionCreationCutoff, subscription.updatedAt < startedAt {
                    return nil
                }
                let podcast = Podcast(feed: resolvedFeedURL)
                legacyContext.insert(podcast)
                createdPodcast = true
                self.createdPodcastFeedKeys.insert(
                    PodcastFeedIdentity.normalizedFeedURLString(resolvedFeedURL)
                )
                self.createdPodcastFeedKeys.insert(
                    PodcastFeedIdentity.normalizedFeedURLString(manifestFeedURL)
                )
                for key in resolvedFeedURL.podcastFeedComparisonKeys {
                    self.podcastsByComparisonKey[key] = podcast.persistentModelID
                }
                return podcast
            }()
            guard let podcast else { continue }

            let metadata = ensureMetadata(for: podcast)
            let profileWasAlreadyApplied = metadata.accessProfileID == accessProfile?.id
            let credentialWasMissing = metadata.credentialState == .missing
            // A subscription can already exist locally in a credential-missing
            // state when a Keychain entry is restored or re-entered later. In
            // that case the row is not new, but it must still be bootstrapped
            // once the access profile becomes usable. Do not enqueue it on
            // every subsequent store projection.
            if subscription.isSubscribed,
               hasCredential,
               createdPodcast || !profileWasAlreadyApplied || credentialWasMissing {
                result.feedsToBootstrap.append(resolvedFeedURL)
            }
            setIfChanged(metadata, \.isSubscribed, subscription.isSubscribed)
            // Old synchronized records can lack access-profile fields. Treat
            // that as unknown rather than a request to clear local metadata.
            if let accessProfile {
                setIfChanged(metadata, \.accessProfileID, accessProfile.id)
                setIfChanged(metadata, \.accessKindRawValue, accessProfile.kind.rawValue)
                setIfChanged(metadata, \.accessProviderID, accessProfile.providerID?.rawValue)
                setIfChanged(metadata, \.credentialState, hasCredential ? .available : .missing)
            } else if metadata.accessProfileID == nil {
                setIfChanged(metadata, \.accessKindRawValue, Optional<String>.none)
                setIfChanged(metadata, \.accessProviderID, Optional<String>.none)
                setIfChanged(metadata, \.credentialState, PodcastCredentialState.available)
            }
            if subscription.isSubscribed {
                if metadata.subscriptionDate == nil {
                    metadata.subscriptionDate = subscription.subscribedAt
                }
                if let titleOverride = nonEmpty(subscription.titleOverride) {
                    setIfChanged(podcast, \.title, titleOverride)
                }
            } else {
                setIfChanged(metadata, \.subscriptionDate, Optional<Date>.none)
            }
            result.subscriptionsApplied += 1
        }
            if StoreDevelopmentConfiguration.modeAllowsDuplicateCleanupDuringProjection {
                result.duplicatePodcastsHidden = hideDuplicatePodcasts(podcasts)
            }
            if saveLegacyChanges(phase: "subscriptions", stream: .subscriptions, result: &result) {
                finishDeltaBatch(subscriptionReader, failedBefore: subscriptionsFailedBefore, result: result)
                finishDeltaStream(subscriptionReader, failedBefore: subscriptionsFailedBefore, result: result)
            }
            refreshContexts()
            if await shouldStop() {
                result.interruptedByPlayback = true
                return result
            }
        }

        if changedStreams.contains(.episodeState) {
            await awaitIdleWindow()
            await applyEpisodeStates(
                recencyCutoff: episodeStateProjectionRecencyCutoff,
                result: &result
            )
            guard result.failed == 0, result.interruptedByPlayback == false else { return result }
        }
        if changedStreams.intersection([.playlists, .playlistEntries, .queueEntries]).isEmpty == false {
            await awaitIdleWindow()
            await applyPlaylists(
                authoritative: authoritativePlaylists,
                result: &result
            )
            guard result.failed == 0, result.interruptedByPlayback == false else { return result }
        }
        // Recover cache-only device settings before portable preference import
        // creates any missing PodcastSettings rows. The cache payload applies
        // only when the canonical local row is absent; synced fields are then
        // merged by the ordinary preference pass below.
        if isInitialRuntimeHydration,
           changedStreams.contains(.preferences) || changedStreams.contains(.playlists) {
            let migratedLocalSettingsIDs = applyLocalSettings(result: &result)
            guard result.failed == 0 else { return result }
            guard saveLegacyChanges(phase: "local_settings_recovery", stream: .preferences, result: &result) else {
                return result
            }
            retireLocalSettingsRows(migratedLocalSettingsIDs)
            refreshContexts()
        }
        // Preferences store playlist sync identities. Project playlists first
        // so newly received targets can be resolved to this device's local UUID.
        if changedStreams.contains(.preferences)
            || changedStreams.contains(.playlists)
            || createdPodcastFeedKeys.isEmpty == false {
            await awaitIdleWindow()
            await applyPreferences(
                includeChangedRecords: changedStreams.contains(.preferences),
                result: &result
            )
            guard result.failed == 0, sourceReadFailed == false else { return result }
            guard result.interruptedByPlayback == false else { return result }
            guard saveLegacyChanges(phase: "preferences", stream: .preferences, result: &result) else { return result }
            refreshContexts()
            if await shouldStop() {
                result.interruptedByPlayback = true
                return result
            }
        }
        if changedStreams.contains(.bookmarks) {
            await awaitIdleWindow()
            await applyBookmarks(result: &result)
            guard result.failed == 0, result.interruptedByPlayback == false else { return result }
        }
        saveLegacyChanges(phase: "user_state", stream: .bookmarks, result: &result)
        if await shouldStop() {
            result.interruptedByPlayback = true
            return result
        }
        if projectListeningHistoryToLegacy, changedStreams.contains(.listeningHistory) {
            await awaitIdleWindow()
            // Only sessions are projected. The legacy `PlaySessionSummary` table
            // is rebuilt from them locally by `rebuildListeningStats`; writing it
            // from synced aggregates is what let a derived total become an input
            // to its own derivation.
            await applyListeningHistory(
                result: &result
            )
            guard result.failed == 0, result.interruptedByPlayback == false else { return result }
            saveLegacyChanges(phase: "listening_history_final", stream: .listeningHistory, result: &result)
        }
        // Disabling projection does not prove the synchronized source is
        // complete. Preserve all previously projected local sessions.

        if Task.isCancelled {
            result.interruptedByPlayback = true
            return result
        }

        result.feedsToBootstrap = Array(Set(result.feedsToBootstrap)).sorted {
            $0.absoluteString < $1.absoluteString
        }
        result.feedsAwaitingCredentials = Array(Set(result.feedsAwaitingCredentials)).sorted {
            $0.absoluteString < $1.absoluteString
        }
        result.credentialRequiredProfileIDs = Array(Set(result.credentialRequiredProfileIDs)).sorted()
        result.playlistFeedsToBootstrap = Array(Set(result.playlistFeedsToBootstrap)).sorted {
            $0.absoluteString < $1.absoluteString
        }
        CrashBreadcrumbs.shared.record(
            "store_split_user_state_import_completed",
            details: "subscriptions=\(result.subscriptionsApplied),preferences=\(result.preferencesApplied),episodes=\(result.episodeStatesApplied),playlists=\(result.playlistsApplied),entries=\(result.playlistEntriesApplied),bookmarks=\(result.bookmarksApplied),history=\(result.listeningHistoryApplied),duplicates=\(result.duplicatePodcastsHidden),feeds=\(result.feedsToBootstrap.count),credentials_required=\(result.feedsAwaitingCredentials.count),failed=\(result.failed)"
        )
#if DEBUG
        logProjectionAudit(result: result)
#endif
        return result
    }

    private func accessProfile(
        for subscription: SubscriptionSync,
        resourceURL: URL
    ) -> PodcastAccessProfile? {
        guard let id = subscription.accessProfileID,
              let rawKind = subscription.accessKindRawValue,
              let kind = PodcastAccessKind(rawValue: rawKind) else {
            return nil
        }
        return PodcastAccessProfile(
            id: id,
            kind: kind,
            resourceURL: resourceURL,
            providerID: subscription.accessProviderID.flatMap(PremiumPodcastProviderID.init(rawValue:))
        )
    }

    /// Indexes the library's podcasts by feed comparison key and returns them.
    /// Episode resolution's last-resort feed scan depends on this map, so any
    /// entry point that projects episode-keyed rows has to build it first.
    @discardableResult
    private func buildPodcastIndex() async -> [Podcast] {
#if DEBUG
        Self.debugPodcastIndexBuildCount += 1
#endif
        podcastIndexBuilt = true
        let startedAt = Date()
        let cpuStartedAt = SystemProcessCPUTimeSource().sample().cpuTime
        let podcasts: [Podcast]
        do {
            podcasts = try legacyContext.fetch(FetchDescriptor<Podcast>())
        } catch {
            sourceReadFailed = true
            CrashBreadcrumbs.shared.record("store_split_import_podcast_index_fetch_failed")
            return []
        }
        // The fetch already handed us every podcast, so duplicate keys are
        // settled against that list rather than by asking the context to
        // resolve an identifier again.
        let podcastsByID = podcasts.reduce(into: [PersistentIdentifier: Podcast]()) { values, podcast in
            values[podcast.persistentModelID] = podcast
        }

        podcastsByComparisonKey = podcasts.reduce(into: [String: PersistentIdentifier]()) { values, podcast in
            guard let feed = podcast.feed else { return }
            for key in feed.podcastFeedComparisonKeys {
                if let existing = values[key] {
                    guard let existingPodcast = podcastsByID[existing] else {
                        values[key] = podcast.persistentModelID
                        continue
                    }
                    values[key] = preferredPodcast(existingPodcast, podcast).persistentModelID
                } else {
                    values[key] = podcast.persistentModelID
                }
            }
        }
        let cpuDelta = max(0, SystemProcessCPUTimeSource().sample().cpuTime - cpuStartedAt)
        let appState = await MainActor.run {
            ModelContainerManager.shared.databaseWorkAppState
        }
        let completedAt = Date()
        AppDiagnostics.log(
            "database_work operation=user_state_import_podcast_index source=user_state_reconcile stores=shared_database started_at=\(startedAt.formatted(.iso8601)) completed_at=\(completedAt.formatted(.iso8601)) duration_ms=\(Int(completedAt.timeIntervalSince(startedAt) * 1_000)) records=\(podcasts.count) process_cpu_seconds_delta=\(String(format: "%.2f", cpuDelta)) app_state=\(appState) cancelled=\(Task.isCancelled)"
        )
        return podcasts
    }

    /// Resolves an identifier the comparison-key index handed out.
    ///
    /// The index is built once and then consulted across many `await`s, so an
    /// entry can name a podcast that a delete or a dedup pass has since removed.
    /// `model(for:)` would return an object for it anyway and trap on first use.
    private func indexedPodcast(_ podcastID: PersistentIdentifier) -> Podcast? {
        legacyContext.existingModel(for: podcastID)
    }

    private func applyPreferences(
        includeChangedRecords: Bool,
        result: inout StoreSplitUserStateImportResult
    ) async {
        let decoder = JSONDecoder()
        let playlists: [Playlist]
        do { playlists = try legacyContext.fetch(FetchDescriptor<Playlist>()) }
        catch {
            result.failed += 1
            CrashBreadcrumbs.shared.record("store_split_preferences_destination_fetch_failed")
            return
        }

        if includeChangedRecords {
            var reader = makeDeltaReader(for: .preferences, periodicFullPass: true)
            let failedBefore = result.failed
            while let page = nextDeltaPage(Self.preferenceDelta, reader: &reader) {
                for record in page {
                    guard applyPreference(record, playlists: playlists, decoder: decoder, result: &result) else {
                        return
                    }
                }
                guard saveLegacyChanges(
                    phase: "preferences_batch",
                    stream: .preferences,
                    result: &result
                ) else { return }
                finishDeltaBatch(reader, failedBefore: failedBefore, result: result)
                if await shouldStop() {
                    result.interruptedByPlayback = true
                    return
                }
            }
            guard sourceReadFailed == false else { return }
            finishDeltaStream(reader, failedBefore: failedBefore, result: result)
        }

        // A preference can reach this device before the subscription that
        // creates its podcast. Those records sit behind the cursor, so the
        // podcasts created in this pass look their preferences up directly.
        if createdPodcastFeedKeys.isEmpty == false {
            let feedKeys = Array(createdPodcastFeedKeys)
            let descriptor = FetchDescriptor<PodcastPreferenceSync>(
                predicate: #Predicate { record in
                    record.feedURL != nil && feedKeys.contains(record.feedURL!)
                },
                sortBy: [SortDescriptor(\PodcastPreferenceSync.updatedAt)]
            )
            let records: [PodcastPreferenceSync]
            do { records = try userStateContext.fetch(descriptor) }
            catch {
                sourceReadFailed = true
                CrashBreadcrumbs.shared.record("store_split_import_fetch_failed")
                return
            }
            streamMetrics[.preferences, default: StoreSplitUserStateStreamMetrics()].rowsFetched += records.count
            for record in records {
                guard applyPreference(record, playlists: playlists, decoder: decoder, result: &result) else {
                    return
                }
            }
        }

        reconcilePlaylistTargets(playlists: playlists)
    }

    /// Applies one synchronized preference. Returns false when the pass must
    /// stop because the destination could not be read.
    private func applyPreference(
        _ record: PodcastPreferenceSync,
        playlists: [Playlist],
        decoder: JSONDecoder,
        result: inout StoreSplitUserStateImportResult
    ) -> Bool {
        let settings: PodcastSettings
        if let feedKey = record.feedURL {
            guard let feedURL = URL(string: feedKey) else {
                result.failed += 1
                return true
            }
            guard let podcast = feedURL.podcastFeedComparisonKeys.compactMap({
                podcastsByComparisonKey[$0].flatMap(indexedPodcast)
            }).first else {
                appendMissingFeed(feedKey, to: &result)
                return true
            }
            settings = ensureSettings(for: podcast)
        } else {
            let globalTitle = "de.holgerkrupp.podbay.queue"
            var descriptor = FetchDescriptor<PodcastSettings>(
                predicate: #Predicate { $0.title == globalTitle }
            )
            descriptor.fetchLimit = 1
            do {
                if let existing = try legacyContext.fetch(descriptor).first {
                    settings = existing
                } else {
                    settings = PodcastSettings(defaultSettings: true)
                    legacyContext.insert(settings)
                }
            } catch {
                legacyContext.rollback()
                result.failed += 1
                CrashBreadcrumbs.shared.record("store_split_preferences_destination_fetch_failed")
                return false
            }
        }

        setIfChanged(settings, \.isEnabled, record.isEnabled)
        if let data = record.playNextPositionRawValue.data(using: .utf8),
           let position = try? decoder.decode(Playlist.Position.self, from: data) {
            setIfChanged(settings, \.playnextPosition, position)
        }
        if let storedPlaylistID = record.defaultPlaylistID {
            // Keep the synchronized choice itself, resolved or not. Only a
            // playlist that exists on this device may become the local
            // UUID; a foreign UUID never does (#359).
            let match = PodcastPlaylistTargetResolver.matchingPlaylist(
                syncID: storedPlaylistID,
                in: playlists
            )
            setIfChanged(
                settings,
                \.defaultPlaylistSyncID,
                Optional(match?.storeSplitSyncID ?? storedPlaylistID)
            )
            resolveLocalPlaylistTarget(of: settings, match: match, playlists: playlists)
        }
        if let value = record.autoDownload {
            setIfChanged(settings, \.autoDownload, value)
        }
        if let value = record.autoDownloadEpisodeCount {
            setIfChanged(settings, \.autoDownloadEpisodeCount, value)
        }
        if let value = record.autoDownloadSelectionRawValue {
            setIfChanged(settings, \.autoDownloadSelectionRawValue, value)
        }
        if let value = record.autoDownloadNetworkModeRawValue {
            setIfChanged(settings, \.autoDownloadNetworkModeRawValue, value)
        }
        if let value = record.autoDownloadIncludesArchivedEpisodes {
            setIfChanged(settings, \.autoDownloadIncludesArchivedEpisodes, value)
        }
        if let value = record.archiveFileRetentionDays {
            setIfChanged(settings, \.archiveFileRetentionDays, value)
        }
        setIfChanged(settings, \.playbackSpeed, record.playbackSpeed.map(Float.init))
        setIfChanged(settings, \.reduceSilenceGapsEnabled, record.reduceSilenceGapsEnabled)
        setIfChanged(settings, \.silenceGapReductionLevelRawValue, record.silenceGapReductionLevelRawValue)
        setIfChanged(settings, \.voiceEnhancementEnabled, record.voiceEnhancementEnabled)
        if let preset = record.equalizerPresetRawValue,
           EqualizerPreset(rawValue: preset) != nil {
            setIfChanged(settings, \.equalizerPresetRawValue, preset)
        }
        setIfChanged(settings, \.autoDownloadFilterJSON, record.autoDownloadFilterJSON)
        if let data = record.autoSkipKeywordsJSON.data(using: .utf8),
           let keywords = try? decoder.decode([skipKey].self, from: data) {
            if let existingData = try? JSONEncoder().encode(settings.autoSkipKeywords),
               existingData != data {
                settings.autoSkipKeywords = keywords
            }
        }
        setIfChanged(settings, \.cutFront, record.cutFront.map(Float.init))
        setIfChanged(settings, \.cutEnd, record.cutEnd.map(Float.init))
        setIfChanged(settings, \.skipForward, SkipSteps(rawValue: record.skipForwardSeconds) ?? .thirty)
        setIfChanged(settings, \.skipBack, SkipSteps(rawValue: record.skipBackSeconds) ?? .fifteen)
        setIfChanged(settings, \.skipForwardBehaviorRawValue, record.skipForwardBehaviorRawValue)
        setIfChanged(settings, \.skipBackBehaviorRawValue, record.skipBackBehaviorRawValue)
        setIfChanged(settings, \.markAsPlayedAfterSubscribe, record.markAsPlayedAfterSubscribe)
        setIfChanged(settings, \.playSumAdjustedbyPlayspeed, record.playSumAdjustedByPlaySpeed)
        setIfChanged(settings, \.enableLockscreenSlider, record.enableLockscreenSlider)
        setIfChanged(settings, \.enableInAppSlider, record.enableInAppSlider)
        setIfChanged(settings, \.getContinuousPlay, record.continuousPlayEnabled)
        setIfChanged(settings, \.showLivePodcasts, record.showLivePodcasts)
        setIfChanged(settings, \.enableLiveItemNotifications, record.liveItemNotificationsEnabled)
        if let value = record.networkTrackingProtectionEnabled {
            setIfChanged(settings, \.networkTrackingProtectionEnabled, value)
        }
        setIfChanged(settings, \.sleepTimerAddMinutes, record.sleepTimerAddMinutes)
        setIfChanged(settings, \.sleepTimerDurationToReactivate, record.sleepTimerDurationToReactivate)
        setIfChanged(settings, \.sleepTimerVoiceFeedbackEnabled, record.sleepTimerVoiceFeedbackEnabled)
        setIfChanged(settings, \.sleepTimerText, record.sleepTimerText)
        result.preferencesApplied += 1
        return true
    }

    /// Points each stored playlist choice at this device's copy of the
    /// playlist once it exists. Runs whenever playlists or preferences
    /// change, so a preference imported before its playlist resolves when the
    /// playlist arrives without re-reading the preference stream.
    private func reconcilePlaylistTargets(playlists: [Playlist]) {
        let descriptor = FetchDescriptor<PodcastSettings>(
            predicate: #Predicate { $0.defaultPlaylistSyncID != nil }
        )
        guard let settingsRows = try? legacyContext.fetch(descriptor) else {
            // The stored choice is untouched and routing resolves it on read;
            // a later pass retries the local UUID.
            CrashBreadcrumbs.shared.record("store_split_playlist_target_reconcile_failed")
            return
        }
        for settings in settingsRows {
            guard let syncID = settings.defaultPlaylistSyncID else { continue }
            resolveLocalPlaylistTarget(
                of: settings,
                match: PodcastPlaylistTargetResolver.matchingPlaylist(syncID: syncID, in: playlists),
                playlists: playlists
            )
        }
    }

    /// Sets the local UUID for a stored choice. An unresolved choice keeps
    /// whatever local playlist the row already names (for example the
    /// built-in queue repair of the global row) but drops a UUID that names
    /// no playlist here, which only an older importer could have written.
    private func resolveLocalPlaylistTarget(
        of settings: PodcastSettings,
        match: Playlist?,
        playlists: [Playlist]
    ) {
        if let match {
            setIfChanged(settings, \.defaultPlaylistID, Optional(match.id))
        } else if let localID = settings.defaultPlaylistID,
                  playlists.contains(where: { $0.id == localID }) == false {
            settings.defaultPlaylistID = nil
        }
    }

    private func applyLocalSettings(result: inout StoreSplitUserStateImportResult) -> [String] {
        guard let cacheContainer else { return [] }
        let rows: [CachedPodcastLocalSettings]
        do {
            rows = try ModelContext(cacheContainer).fetch(FetchDescriptor<CachedPodcastLocalSettings>())
        } catch {
            result.failed += 1
            CrashBreadcrumbs.shared.record("store_split_local_settings_fetch_failed")
            return []
        }
        var reconciledIDs: [String] = []
        let decoder = JSONDecoder()
        for row in rows {
            guard let payload = try? decoder.decode(PodcastLocalSettingsPayload.self, from: row.payload) else {
                continue
            }
            if let feedKey = row.feedURL {
                guard let podcast = URL(string: feedKey)?.podcastFeedComparisonKeys.compactMap({
                    podcastsByComparisonKey[$0].flatMap(indexedPodcast)
                }).first else { continue }
                // SharedDatabase is authoritative when it already has a row.
                // The cache payload is used only to fill a projection that has
                // no canonical settings yet.
                if podcast.settings == nil {
                    payload.apply(to: ensureSettings(for: podcast))
                }
                reconciledIDs.append(row.id)
            } else {
                let globalTitle = PodcastSettings.globalSettingsTitle
                var descriptor = FetchDescriptor<PodcastSettings>(
                    predicate: #Predicate { $0.title == globalTitle }
                )
                descriptor.fetchLimit = 1
                let settings: PodcastSettings
                let hadCanonicalSettings: Bool
                do {
                    if let existing = try legacyContext.fetch(descriptor).first {
                        settings = existing
                        hadCanonicalSettings = true
                    } else {
                        settings = PodcastSettings(defaultSettings: true)
                        legacyContext.insert(settings)
                        hadCanonicalSettings = false
                    }
                } catch {
                    result.failed += 1
                    CrashBreadcrumbs.shared.record("store_split_local_settings_destination_fetch_failed")
                    return reconciledIDs
                }
                // As with podcast settings, do not roll back an existing local
                // edit from a stale cache mirror.
                if hadCanonicalSettings == false { payload.apply(to: settings) }
                reconciledIDs.append(row.id)
            }
        }
        return reconciledIDs
    }

    private func retireLocalSettingsRows(_ ids: [String]) {
        guard let cacheContainer, ids.isEmpty == false else { return }
        let context = ModelContext(cacheContainer)
        do {
            for id in ids {
                try context.delete(
                    model: CachedPodcastLocalSettings.self,
                    where: #Predicate { $0.id == id }
                )
            }
            try context.save()
        } catch {
            context.rollback()
            // The canonical values have already been saved. Keeping the old
            // cache payload is safe and lets a later migration retry retire it.
            CrashBreadcrumbs.shared.record("store_split_local_settings_retire_failed")
        }
    }

    private func applyEpisodeStates(
        recencyCutoff: Date?,
        result: inout StoreSplitUserStateImportResult
    ) async {
        // Episode state is the largest stream, so a manual reconcile does not
        // force a full walk. It still gets the weekly full pass: progress from
        // a device that was offline arrives with an `updatedAt` older than the
        // cursor and would otherwise never be projected. Unchanged rows cost
        // no writes. A narrow import (`episodeStatesUpdatedSince`) starts later
        // than the cursor and therefore never advances it.
        var reader = makeDeltaReader(
            for: .episodeState,
            periodicFullPass: true,
            honorsForcedFullPass: false,
            notBefore: episodeStatesUpdatedSince
        )
        let failedBefore = result.failed

        while true {
            await awaitIdleWindow()
            guard let page = nextDeltaPage(Self.episodeStateDelta, reader: &reader) else { break }

            let freshStates = page.filter {
                shouldProjectEpisodeState($0, recencyCutoff: recencyCutoff)
            }
            let episodesByIdentity = await resolveEpisodesByIdentity(
                identityKeys: freshStates.map {
                    stableIdentityKey(feedURL: $0.feedURL, episodeID: $0.episodeID)
                }
            )
            guard sourceReadFailed == false else { legacyContext.rollback(); return }
            var missing: [StoreSplitMissingEpisodeReference] = []


            for state in freshStates {
                let identityKey = stableIdentityKey(
                    feedURL: state.feedURL,
                    episodeID: state.episodeID
                )
                guard let episode = episodesByIdentity[identityKey] else {
                    // The first build is deliberately partial; the fill applies this.
                    if isInitialRuntimeHydration, StoreRuntimeProjection.isLibraryBackfillPending { continue }
                    appendMissingFeed(state.feedURL, to: &result)
                    missing.append(.init(stream: .episodeState, sourceRecordID: state.id,
                                         feedURL: state.feedURL, episodeID: state.episodeID,
                                         sourceUpdatedAt: state.updatedAt,
                                         payloadDigest: StoreSplitMissingEpisodeFingerprint.episodeState(state)))
                    continue
                }
                let metadata = ensureMetadata(for: episode)

                if metadata.effectiveStateUpdatedAt == state.updatedAt,
                   !StoreSplitEpisodeStateComparison.agrees(state, with: metadata) {
                    result.unresolvedStreams.insert(.episodeState)
                    continue
                }

                // Monotonic fields always merge upwards: the furthest point a
                // user ever reached is not something a second device can undo.
                setIfChanged(
                    metadata,
                    \.maxPlayposition,
                    max(
                        0,
                        state.maxPlayPosition,
                        state.playPosition,
                        metadata.maxPlayposition ?? 0
                    )
                )

                // Everything else is last-writer-wins. A local row that changed
                // after this record was published is newer than the record, so
                // applying it would roll the user back. Skip it and let the
                // dual-write publish the local value instead.
                guard isRemoteStateNewer(state, than: metadata) else {
                    result.episodeStatesApplied += 1
                    continue
                }

                setIfChanged(metadata, \.playPosition, max(0, state.playPosition))
                setIfChanged(metadata, \.stateUpdatedAt, state.updatedAt)
                setIfChanged(metadata, \.lastPlayed, state.lastPlayedAt)
                setIfChanged(metadata, \.firstListenDate, state.firstPlayedAt)
                setIfChanged(metadata, \.completionDate, state.completedAt)
                setIfChanged(metadata, \.archivedAt, state.archivedAt)
                setIfChanged(metadata, \.wasSkipped, state.wasSkipped)
                setIfChanged(metadata, \.isArchived, state.isArchived)
                setIfChanged(metadata, \.isHistory, state.isPlayed)
                setIfChanged(metadata, \.isSavedForLater, state.isSavedForLater)
                setIfChanged(metadata, \.isFavorite, state.isFavorite)
                if state.isArchived || state.isPlayed {
                    setIfChanged(metadata, \.isInbox, false)
                }

                if state.isArchived {
                    setIfChanged(metadata, \.status, .archived)
                } else if state.isPlayed {
                    setIfChanged(metadata, \.status, .history)
                } else if metadata.status == .archived || metadata.status == .history {
                    let independentStatus: EpisodeStatus? = metadata.isInbox == true ? .inbox : nil
                    setIfChanged(metadata, \.status, independentStatus)
                }
                result.episodeStatesApplied += 1
            }

            guard persistMissingReferences(missing, result: &result) else { return }

            guard saveLegacyChanges(
                phase: "episode_states_batch",
                stream: .episodeState,
                result: &result
            ) else { return }
            finishDeltaBatch(reader, failedBefore: failedBefore, result: result)
            refreshContexts()
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }
        }
        guard sourceReadFailed == false else { return }
        finishDeltaStream(reader, failedBefore: failedBefore, result: result)
    }

    private func applyPlaylists(
        authoritative: Bool,
        result: inout StoreSplitUserStateImportResult
    ) async {
        // Queue rows can arrive before their PlaylistSync header.
        let fetchedPlaylists: [Playlist]
        do {
            _ = try Playlist.ensureDefaultQueueCommitted(in: legacyContext)
            fetchedPlaylists = try legacyContext.fetch(FetchDescriptor<Playlist>())
        } catch {
            result.failed += 1
            return
        }
        var localPlaylists = fetchedPlaylists
            .reduce(into: [String: Playlist]()) { $0[$1.id.uuidString] = $1 }
        var localPlaylistBySyncedID: [String: Playlist] = [:]
        var localPlaylistByLogicalKey: [String: Playlist] = [:]
        var playlistOffset = 0

        while true {
            let page = fetchPage(
                PlaylistSync.self,
                offset: playlistOffset,
                limit: sourcePageSize,
                sortBy: [SortDescriptor(\PlaylistSync.updatedAt, order: .reverse)]
            )
            guard page.isEmpty == false else { break }

            for record in page {
                let logicalKey = StableIdentityKey.make(
                    record.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased(),
                    record.kindRawValue
                )
                // Older builds could upload the same logical playlist under a
                // different local UUID. The newest record owns the metadata, but
                // every older ID remains an import alias for its entries.
                if let playlist = localPlaylistByLogicalKey[logicalKey] {
                    localPlaylistBySyncedID[record.id] = playlist
                    continue
                }

                if record.isDeleted || record.deletedAt != nil {
                    // A tombstone may arrive before the original playlist.
                    // Never materialize it as a new default-titled Playlist.
                    if let playlist = localPlaylists[record.id]
                        ?? matchingLocalPlaylist(for: record, among: Array(localPlaylists.values)),
                       record.id != Playlist.defaultQueueSyncID {
                        setIfChanged(playlist, \.hidden, true)
                        for entry in playlist.items ?? [] { legacyContext.delete(entry) }
                        localPlaylistByLogicalKey[logicalKey] = playlist
                        result.playlistsApplied += 1
                    }
                    continue
                }

                guard let playlistID = UUID(uuidString: record.id) else {
                    result.failed += 1
                    continue
                }
                let playlist = localPlaylists[record.id]
                    ?? matchingLocalPlaylist(
                        for: record,
                        among: Array(localPlaylists.values)
                    )
                    ?? {
                        let playlist = Playlist()
                        playlist.id = playlistID
                        legacyContext.insert(playlist)
                        localPlaylists[record.id] = playlist
                        return playlist
                    }()
                localPlaylistBySyncedID[record.id] = playlist
                localPlaylistByLogicalKey[logicalKey] = playlist
                setIfChanged(
                    playlist,
                    \.syncID,
                    record.title == Playlist.defaultQueueTitle
                        ? Playlist.defaultQueueSyncID
                        : record.id
                )

                setIfChanged(playlist, \.title, record.title)
                setIfChanged(playlist, \.symbolName, record.symbolName)
                setIfChanged(playlist, \.sortIndex, record.sortIndex)
                setIfChanged(playlist, \.kindRawValue, record.kindRawValue)
                setIfChanged(playlist, \.hidden, record.isHidden)
                setIfChanged(playlist, \.autoDownloadEnabled, record.autoDownloadEnabled)
                setIfChanged(playlist, \.autoDownloadEpisodeLimit, record.autoDownloadEpisodeLimit)
                setIfChanged(
                    playlist,
                    \.removesEpisodesPlayedElsewhere,
                    record.removesEpisodesPlayedElsewhere
                )
                setIfChanged(playlist, \.deleteable, record.title != Playlist.defaultQueueTitle)
                setIfChanged(
                    playlist,
                    \.smartFilter,
                    record.smartFilterRawValue
                        .flatMap { $0.data(using: .utf8) }
                        .flatMap {
                            try? JSONDecoder().decode(SmartPlaylistFilter.self, from: $0)
                        }
                )
                result.playlistsApplied += 1
            }

            saveLegacyChanges(
                phase: "playlists_batch_\(playlistOffset)",
                stream: .playlists,
                result: &result
            )
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }

            playlistOffset += page.count
        }

        var activeRemoteIdentitiesByPlaylistID: [String: Set<String>] = [:]
        var seenEntryIDs = Set<String>()
        var seenLogicalEntries = Set<String>()
        var localEntriesByPlaylistID: [String: [String: PlaylistEntry]] = [:]
        var defaultQueuePlaylistEntryDates: [String: Date] = [:]
        var entryOffset = 0

        while true {
            let page = fetchPage(
                PlaylistEntrySync.self,
                offset: entryOffset,
                limit: sourcePageSize,
                sortBy: [SortDescriptor(\PlaylistEntrySync.updatedAt, order: .reverse)]
            )
            guard page.isEmpty == false else { break }

            let freshEntries = page.filter { seenEntryIDs.insert($0.id).inserted }
            let episodesByIdentity = await resolveEpisodesByIdentity(
                identityKeys: freshEntries.map {
                    stableIdentityKey(feedURL: $0.feedURL, episodeID: $0.episodeID)
                }
            )
            guard sourceReadFailed == false else { legacyContext.rollback(); return }
            var missing: [StoreSplitMissingEpisodeReference] = []

            // Pages are newest-first. Deduplicate by the local logical playlist
            // and episode, rather than by the old remote record ID, so a recent
            // tombstone or reorder wins over stale aliases from another device.
            for record in freshEntries {
                guard let playlist = localPlaylistBySyncedID[record.playlistID],
                      playlist.isSmartPlaylist == false else {
                    if !record.isDeleted && record.deletedAt == nil {
                        missing.append(.init(stream: .playlistEntries, sourceRecordID: record.id,
                                             feedURL: record.feedURL, episodeID: record.episodeID,
                                             sourceUpdatedAt: record.updatedAt,
                                         payloadDigest: StoreSplitMissingEpisodeFingerprint.playlistEntry(record)))
                    }
                    continue
                }
                let localPlaylistID = playlist.id.uuidString
                let identityKey = stableIdentityKey(
                    feedURL: record.feedURL,
                    episodeID: record.episodeID
                )
                let logicalEntryKey = StableIdentityKey.make(
                    localPlaylistID,
                    identityKey
                )
                guard seenLogicalEntries.insert(logicalEntryKey).inserted else {
                    continue
                }
                if activeRemoteIdentitiesByPlaylistID[localPlaylistID] == nil {
                    activeRemoteIdentitiesByPlaylistID[localPlaylistID] = []
                }
                if playlist.title == Playlist.defaultQueueTitle {
                    defaultQueuePlaylistEntryDates[identityKey] = record.updatedAt
                }

                if localEntriesByPlaylistID[localPlaylistID] == nil {
                    var entriesByIdentity: [String: PlaylistEntry] = [:]
                    for entry in playlist.ordered {
                        guard let episode = entry.episode else {
                            legacyContext.delete(entry)
                            continue
                        }
                        let identity = stableIdentityKey(
                            feedURL: episode.stableEpisodeIdentity.feedURL,
                            episodeID: episode.stableEpisodeIdentity.episodeID
                        )
                        if entriesByIdentity[identity] == nil {
                            entriesByIdentity[identity] = entry
                        } else {
                            legacyContext.delete(entry)
                            result.playlistEntriesApplied += 1
                        }
                    }
                    localEntriesByPlaylistID[localPlaylistID] = entriesByIdentity
                }

                if record.isDeleted || record.deletedAt != nil {
                    if let existing = localEntriesByPlaylistID[localPlaylistID]?
                        .removeValue(forKey: identityKey) {
                        legacyContext.delete(existing)
                        result.playlistEntriesApplied += 1
                    }
                    continue
                }
                activeRemoteIdentitiesByPlaylistID[localPlaylistID, default: []]
                    .insert(identityKey)
                guard let episode = episodesByIdentity[identityKey] else {
                    appendMissingPlaylistFeed(record.feedURL, to: &result)
                    missing.append(.init(stream: .playlistEntries, sourceRecordID: record.id,
                                         feedURL: record.feedURL, episodeID: record.episodeID,
                                         sourceUpdatedAt: record.updatedAt,
                                         payloadDigest: StoreSplitMissingEpisodeFingerprint.playlistEntry(record)))
                    continue
                }
                // A queue record authored before the episode was finished must
                // never put it back into a playlist: local completion outranks
                // remote membership. A deliberate re-listen is recognised by an
                // `addedAt` newer than the completion, and still projects.
                // `PlayedEpisodePlaylistPruner` removes and tombstones whatever
                // is already queued, so this only has to stop new arrivals.
                if PlayedEpisodePlaylistPruner.isEnabled,
                   PlayedEpisodeQueuePolicy.isStaleQueueMembership(
                       for: episode,
                       addedAt: record.addedAt
                   ) {
                    continue
                }
                let entry: PlaylistEntry
                if let existing = localEntriesByPlaylistID[localPlaylistID]?[identityKey] {
                    entry = existing
                } else {
                    let newEntry = PlaylistEntry(
                        episode: episode,
                        order: record.sortIndex
                    )
                    legacyContext.insert(newEntry)
                    newEntry.playlist = playlist
                    localEntriesByPlaylistID[localPlaylistID]?[identityKey] = newEntry
                    entry = newEntry
                }
                assignIfChanged(entry, episode: episode, playlist: playlist,
                                order: record.sortIndex, dateAdded: record.addedAt)
                result.playlistEntriesApplied += 1
            }

            guard persistMissingReferences(missing, result: &result) else { return }

            guard saveLegacyChanges(
                phase: "playlist_entries_batch_\(entryOffset)",
                stream: .playlistEntries,
                result: &result
            ) else { return }
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }

            entryOffset += page.count
        }

        // QueueEntrySync has a device-independent per-episode identity and is
        // therefore the migration tie-breaker for Up Next. Apply it after old
        // PlaylistEntrySync aliases, unless a playlist record is strictly newer.
        if let defaultQueue = localPlaylists.values.first(where: {
               $0.title == Playlist.defaultQueueTitle
           }) {
            await applyQueueEntryFallback(
                to: defaultQueue,
                playlistEntryDates: defaultQueuePlaylistEntryDates,
                activeRemoteIdentitiesByPlaylistID: &activeRemoteIdentitiesByPlaylistID,
                result: &result
            )
            if result.interruptedByPlayback {
                return
            }
        }

        // Never infer removals from membership absent in a partial CloudKit
        // delivery. Explicit tombstones above carry deletion intent.
    }

    private func applyQueueEntryFallback(
        to playlist: Playlist,
        playlistEntryDates: [String: Date],
        activeRemoteIdentitiesByPlaylistID: inout [String: Set<String>],
        result: inout StoreSplitUserStateImportResult
    ) async {
        let localPlaylistID = playlist.id.uuidString
        var entriesByIdentity: [String: PlaylistEntry] = [:]
        for entry in playlist.ordered {
            guard let episode = entry.episode else {
                legacyContext.delete(entry)
                continue
            }
            let identity = stableIdentityKey(
                feedURL: episode.stableEpisodeIdentity.feedURL,
                episodeID: episode.stableEpisodeIdentity.episodeID
            )
            if entriesByIdentity[identity] == nil {
                entriesByIdentity[identity] = entry
            } else {
                legacyContext.delete(entry)
                result.playlistEntriesApplied += 1
            }
        }

        var seenEntryIDs = Set<String>()
        var offset = 0
        while true {
            let page = fetchPage(
                QueueEntrySync.self,
                offset: offset,
                limit: sourcePageSize,
                sortBy: [SortDescriptor(\QueueEntrySync.updatedAt, order: .reverse)]
            )
            guard page.isEmpty == false else { break }
            if activeRemoteIdentitiesByPlaylistID[localPlaylistID] == nil {
                activeRemoteIdentitiesByPlaylistID[localPlaylistID] = []
            }

            let freshEntries = page.filter { seenEntryIDs.insert($0.id).inserted }
            let episodesByIdentity = await resolveEpisodesByIdentity(
                identityKeys: freshEntries.map {
                    stableIdentityKey(feedURL: $0.feedURL, episodeID: $0.episodeID)
                }
            )
            guard sourceReadFailed == false else { legacyContext.rollback(); return }
            var missing: [StoreSplitMissingEpisodeReference] = []

            for record in freshEntries {
                let identityKey = stableIdentityKey(
                    feedURL: record.feedURL,
                    episodeID: record.episodeID
                )
                if let playlistEntryDate = playlistEntryDates[identityKey],
                   playlistEntryDate > record.updatedAt {
                    continue
                }
                if record.isDeleted || record.deletedAt != nil {
                    activeRemoteIdentitiesByPlaylistID[localPlaylistID]?
                        .remove(identityKey)
                    if let existing = entriesByIdentity.removeValue(forKey: identityKey) {
                        legacyContext.delete(existing)
                        result.playlistEntriesApplied += 1
                    }
                    continue
                }

                activeRemoteIdentitiesByPlaylistID[localPlaylistID, default: []]
                    .insert(identityKey)
                guard let episode = episodesByIdentity[identityKey] else {
                    appendMissingPlaylistFeed(record.feedURL, to: &result)
                    missing.append(.init(stream: .queueEntries, sourceRecordID: record.id,
                                         feedURL: record.feedURL, episodeID: record.episodeID,
                                         sourceUpdatedAt: record.updatedAt,
                                         payloadDigest: StoreSplitMissingEpisodeFingerprint.queueEntry(record)))
                    continue
                }
                // A queue record authored before the episode was finished must
                // never put it back into a playlist: local completion outranks
                // remote membership. A deliberate re-listen is recognised by an
                // `addedAt` newer than the completion, and still projects.
                // `PlayedEpisodePlaylistPruner` removes and tombstones whatever
                // is already queued, so this only has to stop new arrivals.
                if PlayedEpisodePlaylistPruner.isEnabled,
                   PlayedEpisodeQueuePolicy.isStaleQueueMembership(
                       for: episode,
                       addedAt: record.addedAt
                   ) {
                    continue
                }
                let entry: PlaylistEntry
                if let existing = entriesByIdentity[identityKey] {
                    entry = existing
                } else {
                    let newEntry = PlaylistEntry(
                        episode: episode,
                        order: record.sortIndex
                    )
                    legacyContext.insert(newEntry)
                    newEntry.playlist = playlist
                    entriesByIdentity[identityKey] = newEntry
                    entry = newEntry
                }
                assignIfChanged(entry, episode: episode, playlist: playlist,
                                order: record.sortIndex, dateAdded: record.addedAt)
                result.playlistEntriesApplied += 1
            }

            guard persistMissingReferences(missing, result: &result) else { return }

            guard saveLegacyChanges(
                phase: "queue_entries_batch_\(offset)",
                stream: .queueEntries,
                result: &result
            ) else { return }
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }
            offset += page.count
        }
    }

    private func matchingLocalPlaylist(
        for record: PlaylistSync,
        among playlists: [Playlist]
    ) -> Playlist? {
        if record.title == Playlist.defaultQueueTitle {
            return playlists.first { $0.title == Playlist.defaultQueueTitle }
        }
        return playlists.first {
            $0.title.localizedCaseInsensitiveCompare(record.title) == .orderedSame
                && $0.kindRawValue == record.kindRawValue
        }
    }

    private func applyBookmarks(
        result: inout StoreSplitUserStateImportResult
    ) async {
        let existingBookmarks: [Bookmark]
        do { existingBookmarks = try legacyContext.fetch(FetchDescriptor<Bookmark>()) }
        catch {
            result.failed += 1
            CrashBreadcrumbs.shared.record("store_split_bookmarks_destination_fetch_failed")
            return
        }
        var bookmarksByID = existingBookmarks.reduce(into: [String: Bookmark]()) {
            guard let uuid = $1.uuid else { return }
            $0[uuid.uuidString] = $1
        }
        var reader = makeDeltaReader(for: .bookmarks, periodicFullPass: true)
        let failedBefore = result.failed

        while true {
            // Oldest first, so a later page (newer rows) wins for any bookmark
            // that appears more than once.
            guard let page = nextDeltaPage(Self.bookmarkDelta, reader: &reader) else { break }
            let freshRecords = page
            let episodesByIdentity = await resolveEpisodesByIdentity(
                identityKeys: freshRecords.map {
                    stableIdentityKey(feedURL: $0.feedURL, episodeID: $0.episodeID)
                }
            )
            guard sourceReadFailed == false else { legacyContext.rollback(); return }
            var missing: [StoreSplitMissingEpisodeReference] = []
            var reconciledDetailIDs: [String] = []


            for record in freshRecords {
                let bookmarkUUID = UUID(uuidString: record.id) ?? stableUUID(record.id)
                if record.isDeleted || record.deletedAt != nil {
                    if let bookmark = bookmarksByID.removeValue(forKey: record.id)
                        ?? bookmarksByID.removeValue(forKey: bookmarkUUID.uuidString) {
                        legacyContext.delete(bookmark)
                        result.bookmarksApplied += 1
                    }
                    reconciledDetailIDs.append(record.id)
                    continue
                }
                let identityKey = stableIdentityKey(
                    feedURL: record.feedURL,
                    episodeID: record.episodeID
                )
                guard let episode = episodesByIdentity[identityKey] else {
                    appendMissingFeed(record.feedURL, to: &result)
                    missing.append(.init(stream: .bookmarks, sourceRecordID: record.id,
                                         feedURL: record.feedURL, episodeID: record.episodeID,
                                         sourceUpdatedAt: record.updatedAt,
                                         payloadDigest: StoreSplitMissingEpisodeFingerprint.bookmark(record)))
                    continue
                }
                let existingBookmark = bookmarksByID[record.id]
                    ?? bookmarksByID[bookmarkUUID.uuidString]
                let bookmark = existingBookmark ?? {
                        let bookmark = Bookmark(
                            start: record.time,
                            title: record.title ?? episode.title,
                            type: .bookmark
                        )
                        bookmark.uuid = bookmarkUUID
                        legacyContext.insert(bookmark)
                        bookmarksByID[record.id] = bookmark
                        bookmarksByID[bookmarkUUID.uuidString] = bookmark
                        return bookmark
                    }()
                setIfChanged(bookmark, \.start, record.time)
                setIfChanged(bookmark, \.title, record.title ?? episode.title)
                setIfChanged(bookmark, \.creationtime, record.createdAt)
                if bookmark.bookmarkEpisode?.persistentModelID
                    != episode.persistentModelID {
                    bookmark.bookmarkEpisode = episode
                }
                if episode.bookmarks?.contains(where: { $0 === bookmark }) == false {
                    episode.bookmarks?.append(bookmark)
                }
                if applyLocalBookmarkDetail(
                    id: record.id,
                    to: bookmark,
                    fillAllFields: existingBookmark == nil
                ) {
                    reconciledDetailIDs.append(record.id)
                }
                result.bookmarksApplied += 1
            }

            guard persistMissingReferences(missing, result: &result) else { return }

            guard saveLegacyChanges(
                phase: "bookmarks_batch",
                stream: .bookmarks,
                result: &result
            ) else { return }
            finishDeltaBatch(reader, failedBefore: failedBefore, result: result)
            retireBookmarkDetailRows(reconciledDetailIDs)
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }
        }
        guard sourceReadFailed == false else { return }
        finishDeltaStream(reader, failedBefore: failedBefore, result: result)
    }

    private func applyLocalBookmarkDetail(
        id: String,
        to bookmark: Bookmark,
        fillAllFields: Bool
    ) -> Bool {
        guard let cacheContainer else { return false }
        var descriptor = FetchDescriptor<CachedBookmarkDetail>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let detail = try? ModelContext(cacheContainer).fetch(descriptor).first else { return false }
        if fillAllFields || bookmark.imageData == nil {
            setIfChanged(bookmark, \.imageData, detail.imageData)
        }
        if fillAllFields || bookmark.duration == nil {
            setIfChanged(bookmark, \.duration, detail.duration)
        }
        if fillAllFields || bookmark.endTime == nil {
            setIfChanged(bookmark, \.endTime, detail.endTime)
        }
        if fillAllFields || bookmark.link == nil {
            setIfChanged(bookmark, \.link, detail.link)
        }
        if fillAllFields || bookmark.progress == nil {
            setIfChanged(bookmark, \.progress, detail.progress)
        }
        return true
    }

    private func retireBookmarkDetailRows(_ ids: [String]) {
        guard let cacheContainer, ids.isEmpty == false else { return }
        let context = ModelContext(cacheContainer)
        do {
            for id in ids {
                try context.delete(
                    model: CachedBookmarkDetail.self,
                    where: #Predicate { $0.id == id }
                )
            }
            try context.save()
        } catch {
            context.rollback()
            // A durable bookmark save happened first; retaining the old detail
            // row is safe and lets a later import retry cleanup.
            CrashBreadcrumbs.shared.record("store_split_bookmark_detail_retire_failed")
        }
    }

    private func applyListeningHistory(
        result: inout StoreSplitUserStateImportResult
    ) async {
        let activeSubscriptionKeys = activeSubscriptionComparisonKeys()
        var reader = makeDeltaReader(for: .listeningHistory, periodicFullPass: true)
        let failedBefore = result.failed

        while true {
            guard let page = nextDeltaPage(
                Self.listeningHistoryDelta,
                reader: &reader,
                pageSize: historyPageSize
            ) else { break }
            guard sourceReadFailed == false else { return }

            // Pages run oldest first, so a later page always overrides an
            // earlier one. Within a page, the preferred copy of a logical
            // session is the one the full newest-first order put first.
            var seenHistoryKeys = Set<String>()
            let freshRecords = page.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                if lhs.endedAt != rhs.endedAt { return lhs.endedAt > rhs.endedAt }
                if lhs.listenedSeconds != rhs.listenedSeconds {
                    return lhs.listenedSeconds > rhs.listenedSeconds
                }
                return lhs.sourceDeviceID < rhs.sourceDeviceID
            }.filter {
                seenHistoryKeys.insert(
                    ListeningHistoryIdentity.canonicalAggregationKey(for: $0)
                ).inserted
            }
            let episodesByIdentity = await resolveEpisodesByIdentity(
                identityKeys: freshRecords.map {
                    stableIdentityKey(feedURL: $0.feedURL, episodeID: $0.episodeID)
                }
            )
            guard sourceReadFailed == false else { legacyContext.rollback(); return }
            var missing: [StoreSplitMissingEpisodeReference] = []

            let deterministicIDs = freshRecords.map {
                stableUUID(ListeningHistoryIdentity.canonicalAggregationKey(for: $0))
            }
            var sessionsByUUID: [UUID: PlaySession]
            do {
                sessionsByUUID = try fetchPlaySessions(ids: deterministicIDs)
                    .reduce(into: [UUID: PlaySession]()) { result, session in
                    guard let id = session.id else { return }
                    result[id] = session
                }
            } catch {
                legacyContext.rollback()
                result.failed += 1
                CrashBreadcrumbs.shared.record("store_split_history_destination_fetch_failed")
                return
            }

            for record in freshRecords {
                let identity = ListeningHistoryIdentity.canonicalAggregationKey(for: record)
                let deterministicID = stableUUID(identity)
                let episodeIdentity = stableIdentityKey(
                    feedURL: record.feedURL,
                    episodeID: record.episodeID
                )
                let episode = episodesByIdentity[episodeIdentity]
                if episode == nil, expectsEpisodes(forFeed: record.feedURL, activeSubscriptionKeys: activeSubscriptionKeys) {
                    appendMissingFeed(record.feedURL, to: &result)
                    missing.append(.init(stream: .listeningHistory, sourceRecordID: record.id,
                                         feedURL: record.feedURL, episodeID: record.episodeID,
                                         sourceUpdatedAt: record.updatedAt,
                                         payloadDigest: StoreSplitMissingEpisodeFingerprint.history(record)))
                    continue
                }
                if episode == nil {
                    if let projected = sessionsByUUID[deterministicID], projected.detachedPodcastFeed != nil {
                        result.listeningHistoryApplied += 1
                        continue
                    }
                    // A session this device recorded itself is better evidence
                    // than the synced copy: leave it and keep the retry.
                    if sessionsByUUID[deterministicID] != nil
                        || (try? equivalentLocalSession(for: record, episode: nil)) != nil {
                        missing.append(.init(stream: .listeningHistory, sourceRecordID: record.id,
                                             feedURL: record.feedURL, episodeID: record.episodeID,
                                             sourceUpdatedAt: record.updatedAt,
                                             payloadDigest: StoreSplitMissingEpisodeFingerprint.history(record)))
                        continue
                    }
                }

                let session: PlaySession
                do {
                    if let existing = sessionsByUUID[deterministicID] {
                        session = existing
                    } else if let equivalent = try equivalentLocalSession(for: record, episode: episode) {
                        session = equivalent
                    } else {
                        session = PlaySession(id: deterministicID)
                        legacyContext.insert(session)
                    }
                } catch {
                    legacyContext.rollback()
                    result.failed += 1
                    CrashBreadcrumbs.shared.record("store_split_history_destination_fetch_failed")
                    return
                }
                sessionsByUUID[deterministicID] = session
                setIfChanged(session, \.id, deterministicID)
                if let episode {
                    if session.episode?.persistentModelID != episode.persistentModelID {
                        session.episode = episode
                    }
                } else if session.episode == nil {
                    setIfChanged(session, \.detachedPodcastFeed, URL(string: record.feedURL))
                    setIfChanged(session, \.detachedEpisodeTitle, record.episodeTitle)
                }
                setIfChanged(
                    session,
                    \.podcastName,
                    record.podcastName ?? episode?.displayPodcastTitle
                )
                setIfChanged(session, \.sourceDeviceID, record.sourceDeviceID)
                setIfChanged(session, \.sourceDeviceName, record.sourceDeviceName)
                setIfChanged(session, \.deviceModel, record.deviceModel)
                setIfChanged(
                    session,
                    \.appVersion,
                    ListeningDeviceIdentity.splitStoreProjectionAppVersion
                )
                setIfChanged(session, \.startTime, record.startedAt)
                setIfChanged(session, \.endTime, record.endedAt)
                setIfChanged(session, \.startPosition, record.startPosition)
                setIfChanged(session, \.endPosition, record.endPosition)
                setIfChanged(
                    session,
                    \.silenceGapTimeSavedSeconds,
                    record.silenceGapTimeSavedSeconds
                )
                setIfChanged(session, \.endedCleanly, record.endedCleanly)
                result.listeningHistoryApplied += 1
            }

            guard persistMissingReferences(missing, result: &result) else { return }

            guard saveLegacyChanges(
                phase: "listening_history_batch",
                stream: .listeningHistory,
                result: &result
            ) else { return }
            finishDeltaBatch(reader, failedBefore: failedBefore, result: result)
            refreshContexts()
            if await shouldStop() {
                result.interruptedByPlayback = true
                return
            }
        }
        guard sourceReadFailed == false else { return }
        finishDeltaStream(reader, failedBefore: failedBefore, result: result)

        // A local absence from a partial or delayed CloudKit delivery is not
        // evidence of deletion. Never prune destination-only history here.
    }

    /// History for a podcast that was deleted or unsubscribed must not fetch the
    /// feed: that would bring it back, including into libraries that never had it.
    private func expectsEpisodes(forFeed feedURL: String, activeSubscriptionKeys: Set<String>) -> Bool {
        guard let feed = URL(string: feedURL) else { return false }
        let keys = feed.podcastFeedComparisonKeys
        return keys.isDisjoint(with: activeSubscriptionKeys) == false
            || keys.contains { podcastsByComparisonKey[$0] != nil }
    }

    private func activeSubscriptionComparisonKeys() -> Set<String> {
        let descriptor = FetchDescriptor<SubscriptionSync>(predicate: #Predicate { $0.isSubscribed })
        let subscriptions = (try? userStateContext.fetch(descriptor)) ?? []
        return subscriptions.reduce(into: Set<String>()) { keys, subscription in
            if let feed = URL(string: subscription.feedURL) {
                keys.formUnion(feed.podcastFeedComparisonKeys)
            }
        }
    }

    private func equivalentLocalSession(
        for record: ListeningHistorySync,
        episode: Episode?
    ) throws -> PlaySession? {
        let startedAt = record.startedAt
        let endedAt = record.endedAt
        let descriptor = FetchDescriptor<PlaySession>(
            predicate: #Predicate {
                $0.startTime == startedAt && $0.endTime == endedAt
            }
        )
        return try legacyContext.fetch(descriptor).first { candidate in
            guard candidate.appVersion
                    != ListeningDeviceIdentity.splitStoreProjectionAppVersion else {
                return false
            }
            if let episode {
                guard candidate.episode?.stableEpisodeIdentityKey
                        == episode.stableEpisodeIdentityKey else { return false }
            }
            return abs((candidate.startPosition ?? 0) - record.startPosition) < 2
                && abs((candidate.endPosition ?? 0) - record.endPosition) < 2
        }
    }

    @discardableResult
    private func saveLegacyChanges(
        phase: String,
        stream: StoreSplitUserStateStream? = nil,
        result: inout StoreSplitUserStateImportResult
    ) -> Bool {
        guard legacyContext.hasChanges else { return true }
        let changedRows = legacyContext.insertedModelsArray.count
            + legacyContext.changedModelsArray.count
            + legacyContext.deletedModelsArray.count
        do {
            try legacyContext.save()
            if let stream {
                streamMetrics[stream, default: StoreSplitUserStateStreamMetrics()].saves += 1
                streamMetrics[stream, default: StoreSplitUserStateStreamMetrics()].rowsChanged += changedRows
            }
            return true
        } catch {
            result.failed += 1
            result.feedsToBootstrap = Array(Set(result.feedsToBootstrap)).sorted {
                $0.absoluteString < $1.absoluteString
            }
            result.playlistFeedsToBootstrap = Array(Set(result.playlistFeedsToBootstrap)).sorted {
                $0.absoluteString < $1.absoluteString
            }
            CrashBreadcrumbs.shared.record(
                "store_split_user_state_import_save_failed",
                details: "phase=\(phase),error_type=\(String(describing: type(of: error)))"
            )
#if DEBUG
            NSLog(
                "[StoreSplitProjection] save failed phase=%@ error_type=%@",
                phase,
                String(describing: type(of: error))
            )
#endif
            legacyContext.rollback()
            return false
        }
    }

#if DEBUG
    private func logProjectionAudit(
        result: StoreSplitUserStateImportResult
    ) {
        func count<Model: PersistentModel>(
            _ type: Model.Type,
            in context: ModelContext
        ) -> Int {
            (try? context.fetchCount(FetchDescriptor<Model>())) ?? -1
        }

        NSLog(
            """
            [StoreSplitProjection] source subscriptions=%d states=%d playlists=%d entries=%d bookmarks=%d history=%d \
            local podcasts=%d episodes=%d playlists=%d entries=%d bookmarks=%d history=%d \
            applied subscriptions=%d states=%d playlists=%d entries=%d bookmarks=%d history=%d missingFeeds=%d failed=%d
            """,
            count(SubscriptionSync.self, in: userStateContext),
            count(EpisodeStateSync.self, in: userStateContext),
            count(PlaylistSync.self, in: userStateContext),
            count(PlaylistEntrySync.self, in: userStateContext),
            count(BookmarkSync.self, in: userStateContext),
            count(ListeningHistorySync.self, in: userStateContext),
            count(Podcast.self, in: legacyContext),
            count(Episode.self, in: legacyContext),
            count(Playlist.self, in: legacyContext),
            count(PlaylistEntry.self, in: legacyContext),
            count(Bookmark.self, in: legacyContext),
            count(PlaySession.self, in: legacyContext),
            result.subscriptionsApplied,
            result.episodeStatesApplied,
            result.playlistsApplied,
            result.playlistEntriesApplied,
            result.bookmarksApplied,
            result.listeningHistoryApplied,
            result.feedsToBootstrap.count,
            result.failed
        )
    }
#endif

    private func stableIdentityKey(
        feedURL: String,
        episodeID: String
    ) -> String {
        let normalizedFeedURL = URL(string: feedURL).map(
            {
                $0.podcastFeedComparisonKeys.sorted().first
                    ?? PodcastFeedIdentity.normalizedFeedURLString($0)
            }
        ) ?? feedURL
        return StableIdentityKey.make(normalizedFeedURL, episodeID)
    }

    private func appendMissingFeed(
        _ feedURL: String,
        to result: inout StoreSplitUserStateImportResult
    ) {
        guard let feed = URL(string: feedURL) else { return }
        result.feedsToBootstrap.append(feed)
    }

    private func appendMissingPlaylistFeed(
        _ feedURL: String,
        to result: inout StoreSplitUserStateImportResult
    ) {
        appendMissingFeed(feedURL, to: &result)
        guard let feed = URL(string: feedURL) else { return }
        result.playlistFeedsToBootstrap.append(feed)
    }

    /// The queue is written in small transactions to the local library before
    /// the caller can advance a stream cursor. The unresolved UserState record
    /// remains authoritative until a later retry projects it successfully.
    private func persistMissingReferences(
        _ references: [StoreSplitMissingEpisodeReference],
        result: inout StoreSplitUserStateImportResult
    ) -> Bool {
        guard !references.isEmpty else { return true }
        result.unresolvedStreams.formUnion(references.map(\.stream))
        do {
            for start in stride(from: 0, to: references.count,
                                by: StoreSplitMissingEpisodeLedger.maximumBatchSize) {
                guard Task.isCancelled == false else {
                    result.interruptedByPlayback = true
                    return false
                }
                let end = min(start + StoreSplitMissingEpisodeLedger.maximumBatchSize, references.count)
                try StoreSplitMissingEpisodeLedger.enqueue(
                    Array(references[start..<end]), libraryContainer: legacyContainer
                )
            }
            return true
        } catch {
            result.failed += 1
            result.feedsToBootstrap = Array(Set(result.feedsToBootstrap)).sorted {
                $0.absoluteString < $1.absoluteString
            }
            result.playlistFeedsToBootstrap = Array(Set(result.playlistFeedsToBootstrap)).sorted {
                $0.absoluteString < $1.absoluteString
            }
            CrashBreadcrumbs.shared.record(
                "store_split_missing_episode_ledger_save_failed",
                details: "reason=\(String(describing: error))"
            )
            return false
        }
    }

    private func stableUUID(_ value: String) -> UUID {
        StableIdentityKey.uuid(for: value)
    }

    private func setIfChanged<Root: AnyObject, Value: Equatable>(
        _ object: Root,
        _ keyPath: ReferenceWritableKeyPath<Root, Value>,
        _ value: Value
    ) {
        guard object[keyPath: keyPath] != value else { return }
        object[keyPath: keyPath] = value
    }

    private func deduplicatedSubscriptions(
        _ records: [SubscriptionSync]
    ) -> [String: SubscriptionSync] {
        var result: [String: SubscriptionSync] = [:]
        for record in records {
            guard let url = URL(string: record.feedURL) else { continue }
            let comparisonKey = url.podcastFeedComparisonKeys.sorted().first
                ?? PodcastFeedIdentity.normalizedFeedURLString(url)
            if let existing = result[comparisonKey],
               existing.updatedAt >= record.updatedAt {
                continue
            }
            result[comparisonKey] = record
        }
        return result
    }

    private func preferredPodcast(_ lhs: Podcast, _ rhs: Podcast) -> Podcast {
        let lhsSubscribed = lhs.metaData?.isSubscribed != false
        let rhsSubscribed = rhs.metaData?.isSubscribed != false
        if lhsSubscribed != rhsSubscribed {
            return lhsSubscribed ? lhs : rhs
        }
        return (lhs.metaData?.lastRefresh ?? .distantPast)
            >= (rhs.metaData?.lastRefresh ?? .distantPast) ? lhs : rhs
    }

    private func hideDuplicatePodcasts(_ podcasts: [Podcast]) -> Int {
        var groups: [[Podcast]] = []
        for podcast in podcasts {
            guard let feed = podcast.feed else { continue }
            if let index = groups.firstIndex(where: { group in
                group.contains { existing in
                    guard let existingFeed = existing.feed else { return false }
                    return existingFeed.podcastFeedComparisonKeys
                        .isDisjoint(with: feed.podcastFeedComparisonKeys) == false
                }
            }) {
                groups[index].append(podcast)
            } else {
                groups.append([podcast])
            }
        }

        var hidden = 0
        for group in groups where group.count > 1 {
            let survivor = group.dropFirst().reduce(group[0], preferredPodcast)
            for duplicate in group where duplicate !== survivor {
                let metadata = ensureMetadata(for: duplicate)
                if metadata.isSubscribed != false {
                    metadata.isSubscribed = false
                    hidden += 1
                }
                // The library copy keeps the row with the newest subscription
                // date for a feed. Moving the date to the survivor stops this
                // hidden row from unsubscribing the feed on every device.
                let survivorMetadata = ensureMetadata(for: survivor)
                if survivorMetadata.subscriptionDate == nil {
                    survivorMetadata.subscriptionDate = metadata.subscriptionDate ?? .now
                }
                metadata.subscriptionDate = nil
            }
        }
        return hidden
    }

    /// Local cleanup only: reads and writes nothing from synced subscriptions.
    @discardableResult
    nonisolated static func hideDuplicateLibraryPodcasts(
        legacyContainer: ModelContainer,
        userStateContainer: ModelContainer
    ) async -> Int {
        let importer = StoreSplitUserStateImporter(
            legacyContainer: legacyContainer,
            userStateContainer: userStateContainer,
            credentialStore: PodcastCredentialStoreProvider.current
        )
        return await importer.hideDuplicatesAndSave()
    }

    private func hideDuplicatesAndSave() -> Int {
        guard let podcasts = try? legacyContext.fetch(FetchDescriptor<Podcast>()) else { return 0 }
        let hidden = hideDuplicatePodcasts(podcasts)
        guard legacyContext.hasChanges else { return hidden }
        do {
            try legacyContext.save()
            return hidden
        } catch {
            legacyContext.rollback()
            return 0
        }
    }

    private func ensureMetadata(for podcast: Podcast) -> PodcastMetaData {
        if let metadata = podcast.metaData {
            return metadata
        }
        let metadata = PodcastMetaData()
        legacyContext.insert(metadata)
        podcast.metaData = metadata
        return metadata
    }

    private func ensureSettings(for podcast: Podcast) -> PodcastSettings {
        if let settings = podcast.settings {
            return settings
        }
        let settings = PodcastSettings(podcast: podcast)
        legacyContext.insert(settings)
        podcast.settings = settings
        return settings
    }

    private func ensureMetadata(for episode: Episode) -> EpisodeMetaData {
        if let metadata = episode.metaData {
            return metadata
        }
        let metadata = EpisodeMetaData()
        legacyContext.insert(metadata)
        metadata.episode = episode
        episode.metaData = metadata
        return metadata
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    private func shouldPauseForPlayback() async -> Bool {
        await MainActor.run {
            // Store projection can run during launch, before the app has
            // prepared the runtime container that Player.shared needs. In
            // that window there is no playback state to observe yet.
            guard ModelContainerManager.shared.preparedContainer != nil else {
                return false
            }
            return Player.shared.isPlaying
        }
    }

    /// Whether the importer should stop at the next checkpoint: the task was
    /// cancelled (e.g. the app is backgrounding) or playback started. Stopping
    /// promptly releases the shared-container SQLite lock before suspension.
    private func shouldStop() async -> Bool {
        if Task.isCancelled { return true }
#if DEBUG
        if let limit = Self.debugStopAfterDeltaBatches, completedDeltaBatches >= limit {
            return true
        }
#endif
        if isInitialRuntimeHydration || continuesDuringPlayback { return false }
        return await shouldPauseForPlayback()
    }

    /// Cooperatively pauses heavy import work while the device is under thermal
    /// or memory pressure, or while the user is actively interacting. Keeps the
    /// importer from competing with the UI for the main thread. Returns promptly
    /// when the task is cancelled.
    private func awaitIdleWindow() async {
        guard Task.isCancelled == false else { return }
        if isInitialRuntimeHydration {
            // Initial local restoration is required before the runtime store
            // can become ready. Do not leave startup settling indefinitely
            // behind transient thermal, memory, or foreground interaction
            // pressure; still yield so other tasks can make progress.
            await Task.yield()
            return
        }
        await SystemPressureGate.shared.waitUntilIdle()
    }

    /// Whether an incoming UserState record may overwrite the durable local
    /// episode state.
    ///
    /// The runtime graph is a real store that the app writes to directly, so an
    /// older CloudKit record must not be projected over newer local truth. Rows
    /// written before `stateUpdatedAt` existed fall back to the newest playback
    /// timestamp. Equal timestamps preserve local state because no reliable
    /// lineage tie-breaker is available.
    private func isRemoteStateNewer(
        _ state: EpisodeStateSync,
        than metadata: EpisodeMetaData
    ) -> Bool {
        guard let localUpdatedAt = metadata.effectiveStateUpdatedAt else {
            return true
        }
        return state.updatedAt > localUpdatedAt
    }

    private func shouldProjectEpisodeState(
        _ state: EpisodeStateSync,
        recencyCutoff: Date?
    ) -> Bool {
        let hasActiveProgress = state.playPosition > 0 || state.maxPlayPosition > 0
            || state.isSavedForLater || state.isFavorite
        if hasActiveProgress {
            return true
        }

        guard let recencyCutoff else {
            return true
        }

        let mostRelevantDate = [
            state.lastPlayedAt,
            state.completedAt,
            state.archivedAt,
            state.firstPlayedAt
        ]
            .compactMap { $0 }
            .max()

        guard let mostRelevantDate else {
            return false
        }

        return mostRelevantDate >= recencyCutoff
    }

    private func refreshContexts() {
        legacyContext = ModelContext(legacyContainer)
        userStateContext = ModelContext(userStateContainer)
        legacyContext.autosaveEnabled = false
        userStateContext.autosaveEnabled = false
    }

    private func resolveEpisodesByIdentity(
        identityKeys: [String]
    ) async -> [String: Episode] {
        let uniqueKeys = Set(identityKeys)
        await resolveEpisodeIDsIfNeeded(for: uniqueKeys)

        let episodeIDsByIdentity = uniqueKeys.reduce(into: [String: PersistentIdentifier]()) { result, identityKey in
            guard let episodeID = resolvedEpisodeIDsByIdentity[identityKey] else { return }
            result[identityKey] = episodeID
        }
        // Resolved identifiers are cached across pages, so some of them name
        // episodes that are already gone. One fetch keeps the live ones.
        let episodesByID: [PersistentIdentifier: Episode] = legacyContext.existingModels(
            for: Array(episodeIDsByIdentity.values)
        )

        return episodeIDsByIdentity.reduce(into: [String: Episode]()) { result, entry in
            guard let episode = episodesByID[entry.value] else { return }
            result[entry.key] = episode
        }
    }

    private func resolveEpisodeIDsIfNeeded(for identityKeys: Set<String>) async {
        let unresolvedKeys = identityKeys.filter {
            resolvedEpisodeIDsByIdentity[$0] == nil
                && unresolvableEpisodeIdentities.contains($0) == false
        }
        guard unresolvedKeys.isEmpty == false else { return }

        var guidCandidates: [String] = []
        var enclosureCandidates: [URL] = []
        var linkCandidates: [URL] = []
        var unresolvedByFeed: [String: Set<String>] = [:]

        for identityKey in unresolvedKeys {
            guard let components = decodeStableIdentityKey(identityKey) else {
                unresolvableEpisodeIdentities.insert(identityKey)
                continue
            }

            unresolvedByFeed[components.feedURL, default: []].insert(identityKey)

            if components.episodeID.hasPrefix("guid:") {
                guidCandidates.append(String(components.episodeID.dropFirst(5)))
            } else if components.episodeID.hasPrefix("enclosure:") || components.episodeID.hasPrefix("episode:") {
                let prefixLength = components.episodeID.hasPrefix("enclosure:") ? 10 : 8
                if let url = URL(string: String(components.episodeID.dropFirst(prefixLength))) {
                    enclosureCandidates.append(url)
                }
            } else if components.episodeID.hasPrefix("link:") {
                if let url = URL(string: String(components.episodeID.dropFirst(5))) {
                    linkCandidates.append(url)
                }
            }
        }

        cacheResolvedEpisodes(
            fetchEpisodesMatchingGUIDs(Array(Set(guidCandidates))),
            expectedKeys: unresolvedKeys
        )
        cacheResolvedEpisodes(
            fetchEpisodesMatchingURLs(Array(Set(enclosureCandidates))),
            expectedKeys: unresolvedKeys
        )
        cacheResolvedEpisodes(
            fetchEpisodesMatchingLinks(Array(Set(linkCandidates))),
            expectedKeys: unresolvedKeys
        )

        let stillUnresolved = unresolvedKeys.filter { resolvedEpisodeIDsByIdentity[$0] == nil }
        guard stillUnresolved.isEmpty == false else { return }

        // Scan each feed for its own keys only. Handing every feed the whole
        // cross-feed set left `remaining` non-empty no matter what that feed
        // contained, so the scan always paged the feed's episodes to the very
        // end instead of stopping once its keys were accounted for.
        for (feedURL, feedKeys) in unresolvedByFeed {
            let outstanding = feedKeys.intersection(stillUnresolved)
            guard outstanding.isEmpty == false else { continue }
            // Already walked end to end: anything it could resolve is cached, so
            // these keys are misses and a second pass would only cost CPU.
            guard fullyScannedFeeds.contains(feedURL) == false else { continue }
            if Task.isCancelled { return }
            await awaitIdleWindow()
            await resolveEpisodesByScanningFeed(feedURL, expectedKeys: outstanding)
        }

        for identityKey in stillUnresolved where resolvedEpisodeIDsByIdentity[identityKey] == nil {
            unresolvableEpisodeIdentities.insert(identityKey)
        }
    }

    private func fetchEpisodesMatchingGUIDs(_ guids: [String]) -> [Episode] {
        guard guids.isEmpty == false else { return [] }
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.guid != nil && guids.contains(episode.guid!)
            }
        )
        do { return try legacyContext.fetch(descriptor) }
        catch {
            sourceReadFailed = true
            CrashBreadcrumbs.shared.record("store_split_episode_destination_fetch_failed")
            return []
        }
    }

    private func fetchEpisodesMatchingURLs(_ urls: [URL]) -> [Episode] {
        guard urls.isEmpty == false else { return [] }
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.url != nil && urls.contains(episode.url!)
            }
        )
        do { return try legacyContext.fetch(descriptor) }
        catch {
            sourceReadFailed = true
            CrashBreadcrumbs.shared.record("store_split_episode_destination_fetch_failed")
            return []
        }
    }

    private func fetchEpisodesMatchingLinks(_ urls: [URL]) -> [Episode] {
        guard urls.isEmpty == false else { return [] }
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.link != nil && urls.contains(episode.link!)
            }
        )
        do { return try legacyContext.fetch(descriptor) }
        catch {
            sourceReadFailed = true
            CrashBreadcrumbs.shared.record("store_split_episode_destination_fetch_failed")
            return []
        }
    }

    private func cacheResolvedEpisodes(
        _ episodes: [Episode],
        expectedKeys: Set<String>
    ) {
        for episode in episodes {
            let identity = episode.stableEpisodeIdentity
            let key = stableIdentityKey(
                feedURL: identity.feedURL,
                episodeID: identity.episodeID
            )
            guard expectedKeys.contains(key) else { continue }
            resolvedEpisodeIDsByIdentity[key] = episode.persistentModelID
        }
    }

    private func resolveEpisodesByScanningFeed(
        _ normalizedFeedURL: String,
        expectedKeys: Set<String>
    ) async {
        if podcastIndexBuilt == false { await buildPodcastIndex() }
        guard let podcastID = podcastsByComparisonKey[normalizedFeedURL],
              let podcast = indexedPodcast(podcastID),
              let feed = podcast.feed else {
            return
        }
#if DEBUG
        Self.debugFeedScanCount += 1
#endif

        // Last-resort fallback after the targeted GUID/URL/link fetches missed.
        //
        // We deliberately do NOT walk `podcast.episodes`: the relationship getter
        // faults every episode of the feed and pins them on the live `Podcast`
        // object for the importer's lifetime, which materialises (and strongly
        // retains) the entire episode library. Instead we page episodes for the
        // feed with a fetch so each batch is released before the next one loads,
        // and stop as soon as every expected key is resolved or the app backgrounds.
        //
        // Every identity the walk passes is cached, not just the ones asked for:
        // the expensive part is the walk, and a later page asking about a
        // different episode of the same feed must not pay for it again.
        var remaining = expectedKeys
        var offset = 0
        let startedAt = Date()
        let cpuStartedAt = SystemProcessCPUTimeSource().sample().cpuTime
        var scannedRecords = 0
        while remaining.isEmpty == false {
            if Task.isCancelled {
                await logFeedScan(
                    startedAt: startedAt,
                    cpuStartedAt: cpuStartedAt,
                    records: scannedRecords,
                    cancelled: true
                )
                return
            }
            await awaitIdleWindow()
            let reachedEnd = autoreleasepool { () -> Bool in
                var descriptor = FetchDescriptor<Episode>(
                    predicate: #Predicate<Episode> { $0.podcast?.feed == feed },
                    // Offset paging over an unordered fetch can repeat or skip
                    // rows between pages. A missed episode now sticks as an
                    // unresolvable identity for the rest of the run, so the
                    // order has to be deterministic. Title plus GUID is
                    // effectively unique within one feed.
                    sortBy: [
                        SortDescriptor(\Episode.title),
                        SortDescriptor(\Episode.guid)
                    ]
                )
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = episodeScanPageSize
                let batch: [Episode]
                do { batch = try legacyContext.fetch(descriptor) }
                catch {
                    sourceReadFailed = true
                    CrashBreadcrumbs.shared.record("store_split_episode_destination_fetch_failed")
                    return true
                }
                guard batch.isEmpty == false else { return true }
                scannedRecords += batch.count

                for episode in batch {
                    let identity = episode.stableEpisodeIdentity
                    let key = stableIdentityKey(
                        feedURL: identity.feedURL,
                        episodeID: identity.episodeID
                    )
                    resolvedEpisodeIDsByIdentity[key] = episode.persistentModelID
                    remaining.remove(key)
                }

                offset += batch.count
                return batch.count < episodeScanPageSize
            }
            if reachedEnd {
                // Walked to the end of the feed, so the map now holds every
                // identity it can offer.
                fullyScannedFeeds.insert(normalizedFeedURL)
                await logFeedScan(
                    startedAt: startedAt,
                    cpuStartedAt: cpuStartedAt,
                    records: scannedRecords,
                    cancelled: false
                )
                return
            }
        }
        await logFeedScan(
            startedAt: startedAt,
            cpuStartedAt: cpuStartedAt,
            records: scannedRecords,
            cancelled: false
        )
    }

    private func logFeedScan(
        startedAt: Date,
        cpuStartedAt: TimeInterval,
        records: Int,
        cancelled: Bool
    ) async {
        let cpuDelta = max(0, SystemProcessCPUTimeSource().sample().cpuTime - cpuStartedAt)
        let appState = await MainActor.run {
            ModelContainerManager.shared.databaseWorkAppState
        }
        let completedAt = Date()
        AppDiagnostics.log(
            "database_work operation=user_state_episode_feed_scan source=user_state_reconcile stores=shared_database started_at=\(startedAt.formatted(.iso8601)) completed_at=\(completedAt.formatted(.iso8601)) duration_ms=\(Int(completedAt.timeIntervalSince(startedAt) * 1_000)) records=\(records) process_cpu_seconds_delta=\(String(format: "%.2f", cpuDelta)) app_state=\(appState) cancelled=\(cancelled)"
        )
    }

    private func decodeStableIdentityKey(
        _ value: String
    ) -> (feedURL: String, episodeID: String)? {
        var cursor = value.startIndex
        var components: [String] = []

        while cursor < value.endIndex, components.count < 2 {
            guard let separator = value[cursor...].firstIndex(of: ":"),
                  let length = Int(value[cursor..<separator]) else {
                return nil
            }
            let componentStart = value.index(after: separator)
            guard let componentEnd = value.index(
                componentStart,
                offsetBy: length,
                limitedBy: value.endIndex
            ) else {
                return nil
            }
            components.append(String(value[componentStart..<componentEnd]))
            cursor = componentEnd
        }

        guard components.count == 2 else { return nil }
        return (components[0], components[1])
    }

    private func fetchPlaySessions(ids: [UUID]) throws -> [PlaySession] {
        guard ids.isEmpty == false else { return [] }
        var sessions: [PlaySession] = []
        for id in ids {
            let optionalID: UUID? = id
            var descriptor = FetchDescriptor<PlaySession>(
                predicate: #Predicate<PlaySession> { session in
                    session.id == optionalID
                }
            )
            descriptor.fetchLimit = 1
            if let session = try legacyContext.fetch(descriptor).first {
                sessions.append(session)
            }
        }
        return sessions
    }

    private func fetchPage<Model: PersistentModel>(
        _ type: Model.Type,
        offset: Int,
        limit: Int,
        sortBy: [SortDescriptor<Model>] = []
    ) -> [Model] {
        guard Task.isCancelled == false else { return [] }
        var descriptor = FetchDescriptor<Model>(sortBy: sortBy)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        do { return try context(for: type).fetch(descriptor) }
        catch {
            sourceReadFailed = true
            CrashBreadcrumbs.shared.record("store_split_import_fetch_failed")
            return []
        }
    }

    // MARK: - Record-level incremental reads (#104)

    /// Describes how to page one synchronized model by `updatedAt`.
    /// `#Predicate` needs concrete key paths, so each stream supplies its own.
    private struct DeltaQuery<Model: PersistentModel> {
        let stream: StoreSplitUserStateStream
        let atOrAfter: (Date) -> Predicate<Model>
        let after: (Date) -> Predicate<Model>
        let at: (Date) -> Predicate<Model>
        let ascending: [SortDescriptor<Model>]
        let updatedAt: (Model) -> Date
        let id: (Model) -> String
    }

    /// Read position in one stream for one pass.
    ///
    /// Pages are keyed on `updatedAt` rather than an offset, and every page
    /// ends on a complete timestamp group, so the next page can start strictly
    /// after it. Rows that change while the pass runs move to the end instead
    /// of shifting unread rows into already-read offsets, so nothing is
    /// skipped, and the boundary is exactly the persisted cursor format.
    private struct DeltaReader {
        let stream: StoreSplitUserStateStream
        /// Reads from the beginning of the stream.
        let isFullPass: Bool
        /// Finishing this pass completes a full walk: it started from the
        /// beginning, or resumes an interrupted pass that did.
        let completesFullPass: Bool
        let commitsProgress: Bool
        var lowerBound: Date?
        var lowerBoundInclusive: Bool
        /// Records at `lowerBound` the stored cursor already covers.
        var excludedIDsAtLowerBound: Set<String>
        var finished = false
        var boundaryDate: Date?
        var boundaryIDs: Set<String> = []
    }

    private var effectivePageSize: Int {
#if DEBUG
        if let override = Self.debugSourcePageSizeOverride { return max(1, override) }
#endif
        return sourcePageSize
    }

    /// - Parameters:
    ///   - periodicFullPass: Walk the whole stream when the last full pass
    ///     is older than `StoreSplitImportCursorStore.fullPassInterval`, to
    ///     pick up records CloudKit delivered with an older timestamp.
    ///   - notBefore: A narrower lower bound requested by the caller. When it
    ///     is later than the cursor the pass skips rows the cursor has not
    ///     covered, so it must not advance the cursor.
    private func makeDeltaReader(
        for stream: StoreSplitUserStateStream,
        periodicFullPass: Bool,
        honorsForcedFullPass: Bool = true,
        notBefore: Date? = nil
    ) -> DeltaReader {
        let cursor = previousImportCursors[stream]
        let isFullPass = (honorsForcedFullPass && forcesFullPass)
            || StoreSplitImportCursorStore.needsFullPass(cursor, periodic: periodicFullPass)
        let resumesFullPass = isFullPass == false && cursor?.fullPassInProgress == true
        // The very first runtime hydration deliberately skips rows whose
        // episodes the partial library build has not created yet, so it must
        // not record those rows as imported.
        let commitsProgress = cursorDefaults != nil && isInitialRuntimeHydration == false
        var reader = DeltaReader(
            stream: stream,
            isFullPass: isFullPass,
            completesFullPass: isFullPass || resumesFullPass,
            commitsProgress: commitsProgress,
            lowerBound: isFullPass ? nil : cursor?.importedThrough,
            lowerBoundInclusive: true,
            excludedIDsAtLowerBound: isFullPass ? [] : Set(cursor?.recordIDsAtTimestamp ?? [])
        )
        if let notBefore, (reader.lowerBound ?? .distantPast) < notBefore {
            reader = DeltaReader(
                stream: stream,
                isFullPass: false,
                completesFullPass: false,
                commitsProgress: false,
                lowerBound: notBefore,
                lowerBoundInclusive: true,
                excludedIDsAtLowerBound: []
            )
        }
        streamMetrics[stream, default: StoreSplitUserStateStreamMetrics()].fullPass = reader.isFullPass
        return reader
    }

    /// The next page of changed rows, oldest first, or nil once the stream is
    /// exhausted. A page can be empty when every row in it was already
    /// covered by the cursor's boundary group.
    private func nextDeltaPage<Model: PersistentModel>(
        _ query: DeltaQuery<Model>,
        reader: inout DeltaReader,
        pageSize: Int? = nil
    ) -> [Model]? {
        guard reader.finished == false else { return nil }
        guard Task.isCancelled == false, sourceReadFailed == false else {
            reader.finished = true
            return nil
        }
        let limit = pageSize.map { min($0, effectivePageSize) } ?? effectivePageSize
        var descriptor = FetchDescriptor<Model>(
            predicate: reader.lowerBound.map {
                reader.lowerBoundInclusive ? query.atOrAfter($0) : query.after($0)
            },
            sortBy: query.ascending
        )
        descriptor.fetchLimit = limit
        do {
            var rows = try userStateContext.fetch(descriptor)
            guard let last = rows.last else {
                reader.finished = true
                return nil
            }
            let boundary = query.updatedAt(last)
            if rows.count >= limit {
                // The page may have cut a timestamp group in half. Load the
                // whole group so the next page can start strictly after it.
                rows.removeAll { query.updatedAt($0) == boundary }
                rows.append(contentsOf: try userStateContext.fetch(
                    FetchDescriptor<Model>(predicate: query.at(boundary), sortBy: query.ascending)
                ))
            } else {
                reader.finished = true
            }
            var boundaryIDs = Set(rows.lazy.filter { query.updatedAt($0) == boundary }.map(query.id))
            if let lowerBound = reader.lowerBound, reader.excludedIDsAtLowerBound.isEmpty == false {
                let excluded = reader.excludedIDsAtLowerBound
                rows.removeAll { query.updatedAt($0) == lowerBound && excluded.contains(query.id($0)) }
                if boundary == lowerBound { boundaryIDs.formUnion(excluded) }
            }
            reader.boundaryDate = boundary
            reader.boundaryIDs = boundaryIDs
            reader.lowerBound = boundary
            reader.lowerBoundInclusive = false
            reader.excludedIDsAtLowerBound = []
            streamMetrics[query.stream, default: StoreSplitUserStateStreamMetrics()].rowsFetched += rows.count
            return rows
        } catch {
            sourceReadFailed = true
            reader.finished = true
            CrashBreadcrumbs.shared.record(
                "store_split_import_fetch_failed",
                details: "stream=\(query.stream.rawValue)"
            )
            return nil
        }
    }

    /// Advances the stream's cursor past a batch the library has durably
    /// saved. A batch that left unresolved or failed records holds the cursor
    /// where it is, so they are read again on the next pass.
    private func finishDeltaBatch(
        _ reader: DeltaReader,
        failedBefore: Int,
        result: StoreSplitUserStateImportResult
    ) {
        completedDeltaBatches += 1
        guard reader.commitsProgress,
              let cursorDefaults,
              let boundaryDate = reader.boundaryDate,
              sourceReadFailed == false,
              result.failed == failedBefore,
              result.unresolvedStreams.contains(reader.stream) == false else { return }
        StoreSplitImportCursorStore.advance(
            reader.stream,
            through: boundaryDate,
            recordIDsAtTimestamp: reader.boundaryIDs,
            duringFullPass: reader.completesFullPass,
            defaults: cursorDefaults
        )
    }

    private func finishDeltaStream(
        _ reader: DeltaReader,
        failedBefore: Int,
        result: StoreSplitUserStateImportResult
    ) {
        guard reader.completesFullPass,
              reader.commitsProgress,
              reader.finished,
              let cursorDefaults,
              sourceReadFailed == false,
              result.failed == failedBefore,
              Task.isCancelled == false else { return }
        StoreSplitImportCursorStore.markFullPassCompleted(reader.stream, defaults: cursorDefaults)
    }

    fileprivate func logStreamMetrics(result: StoreSplitUserStateImportResult) {
        for (stream, metrics) in streamMetrics.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            AppDiagnostics.log(
                "database_work operation=user_state_import_stream source=user_state_reconcile stores=shared_database stream=\(stream.rawValue) full_pass=\(metrics.fullPass) rows_fetched=\(metrics.rowsFetched) rows_changed=\(metrics.rowsChanged) saves=\(metrics.saves) noop=\(metrics.saves == 0) failed=\(result.failed) interrupted=\(result.interruptedByPlayback)"
            )
        }
    }

    private func assignIfChanged(
        _ entry: PlaylistEntry,
        episode: Episode,
        playlist: Playlist,
        order: Int,
        dateAdded: Date
    ) {
        if entry.episode?.persistentModelID != episode.persistentModelID {
            entry.episode = episode
        }
        if entry.playlist?.persistentModelID != playlist.persistentModelID {
            entry.playlist = playlist
        }
        setIfChanged(entry, \.order, order)
        setIfChanged(entry, \.dateAdded, Optional(dateAdded))
    }

    private static var subscriptionDelta: DeltaQuery<SubscriptionSync> {
        DeltaQuery(
            stream: .subscriptions,
            atOrAfter: { date in #Predicate<SubscriptionSync> { $0.updatedAt >= date } },
            after: { date in #Predicate<SubscriptionSync> { $0.updatedAt > date } },
            at: { date in #Predicate<SubscriptionSync> { $0.updatedAt == date } },
            ascending: [SortDescriptor(\SubscriptionSync.updatedAt), SortDescriptor(\SubscriptionSync.id)],
            updatedAt: { $0.updatedAt },
            id: { $0.id }
        )
    }

    private static var episodeStateDelta: DeltaQuery<EpisodeStateSync> {
        DeltaQuery(
            stream: .episodeState,
            atOrAfter: { date in #Predicate<EpisodeStateSync> { $0.updatedAt >= date } },
            after: { date in #Predicate<EpisodeStateSync> { $0.updatedAt > date } },
            at: { date in #Predicate<EpisodeStateSync> { $0.updatedAt == date } },
            ascending: [SortDescriptor(\EpisodeStateSync.updatedAt), SortDescriptor(\EpisodeStateSync.id)],
            updatedAt: { $0.updatedAt },
            id: { $0.id }
        )
    }

    private static var preferenceDelta: DeltaQuery<PodcastPreferenceSync> {
        DeltaQuery(
            stream: .preferences,
            atOrAfter: { date in #Predicate<PodcastPreferenceSync> { $0.updatedAt >= date } },
            after: { date in #Predicate<PodcastPreferenceSync> { $0.updatedAt > date } },
            at: { date in #Predicate<PodcastPreferenceSync> { $0.updatedAt == date } },
            ascending: [SortDescriptor(\PodcastPreferenceSync.updatedAt), SortDescriptor(\PodcastPreferenceSync.id)],
            updatedAt: { $0.updatedAt },
            id: { $0.id }
        )
    }

    private static var bookmarkDelta: DeltaQuery<BookmarkSync> {
        DeltaQuery(
            stream: .bookmarks,
            atOrAfter: { date in #Predicate<BookmarkSync> { $0.updatedAt >= date } },
            after: { date in #Predicate<BookmarkSync> { $0.updatedAt > date } },
            at: { date in #Predicate<BookmarkSync> { $0.updatedAt == date } },
            ascending: [SortDescriptor(\BookmarkSync.updatedAt), SortDescriptor(\BookmarkSync.id)],
            updatedAt: { $0.updatedAt },
            id: { $0.id }
        )
    }

    private static var listeningHistoryDelta: DeltaQuery<ListeningHistorySync> {
        DeltaQuery(
            stream: .listeningHistory,
            atOrAfter: { date in #Predicate<ListeningHistorySync> { $0.updatedAt >= date } },
            after: { date in #Predicate<ListeningHistorySync> { $0.updatedAt > date } },
            at: { date in #Predicate<ListeningHistorySync> { $0.updatedAt == date } },
            ascending: [
                SortDescriptor(\ListeningHistorySync.updatedAt),
                SortDescriptor(\ListeningHistorySync.id)
            ],
            updatedAt: { $0.updatedAt },
            id: { $0.id }
        )
    }

    private func context<Model: PersistentModel>(
        for type: Model.Type
    ) -> ModelContext {
        switch type {
        case is Podcast.Type,
            is Episode.Type,
            is Playlist.Type,
            is PlaylistEntry.Type,
            is Bookmark.Type,
            is PlaySession.Type:
            return legacyContext
        default:
            return userStateContext
        }
    }
}
