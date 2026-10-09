//
//  PodcastModelActor.swift
//  Raul
//
//  Created by Holger Krupp on 04.04.25.
//

import SwiftData
import Foundation
import CryptoKit
import os
import OSLog
import mp3ChapterReader

/// Describes the freshness check independently from whether the caller needs
/// an authoritative feed body. A due release still probes the server but does
/// not trust an unchanged HEAD response to suppress its GET.
struct PodcastRefreshRequestPolicy: Sendable, Equatable {
    let performHEAD: Bool
    let forceGETRegardlessOfHEAD: Bool

    func shouldGET(
        afterHEADResult feedWasUpdated: Bool?,
        hasTimeSensitiveLiveItem: Bool = false
    ) -> Bool {
        forceGETRegardlessOfHEAD || hasTimeSensitiveLiveItem || feedWasUpdated != false
    }

    static let regular = PodcastRefreshRequestPolicy(
        performHEAD: true,
        forceGETRegardlessOfHEAD: false
    )
    static let manualBulk = PodcastRefreshRequestPolicy(
        performHEAD: true,
        forceGETRegardlessOfHEAD: false
    )
    static let manualSingle = PodcastRefreshRequestPolicy(
        performHEAD: false,
        forceGETRegardlessOfHEAD: true
    )
    static let dueRelease = PodcastRefreshRequestPolicy(
        performHEAD: true,
        forceGETRegardlessOfHEAD: true
    )
    static let validatedImport = PodcastRefreshRequestPolicy(
        performHEAD: false,
        forceGETRegardlessOfHEAD: true
    )
}

enum PodcastFeedSwitchError: LocalizedError {
    case feedAlreadyExists

    var errorDescription: String? {
        switch self {
        case .feedAlreadyExists:
            return "Another podcast already uses this feed URL."
        }
    }
}

enum PodcastFeedEndpointRecoveryError: LocalizedError {
    case identityCouldNotBeVerified
    case feedCouldNotBeValidated

    var errorDescription: String? {
        switch self {
        case .identityCouldNotBeVerified:
            return "The recovered feed could not be verified as this podcast."
        case .feedCouldNotBeValidated:
            return "The replacement feed could not be validated."
        }
    }
}

enum PodcastFeedEndpointIdentity {
    static func matchesExistingPodcast(
        _ parsedFeed: [String: Any],
        knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers
    ) -> Bool {
        guard knownEpisodeIdentifiers.isEmpty == false,
              let episodes = parsedFeed["episodes"] as? [[String: Any]] else {
            return false
        }

        var matchingURLs = Set<String>()
        for episode in episodes {
            // Website RSS can reuse the same post GUIDs as the podcast feed.
            // Only episodes that the importer can actually play and retain
            // provide evidence for an endpoint replacement.
            guard let draft = PodcastEpisodeDraft(episodeData: episode) else { continue }
            if let guid = draft.guid,
               knownEpisodeIdentifiers.guids.contains(guid) {
                return true
            }
            let enclosureURL = draft.episodeURL.absoluteString
            if knownEpisodeIdentifiers.urls.contains(enclosureURL) {
                matchingURLs.insert(enclosureURL)
            }
            for key in ["url", "link"] {
                if let value = episode[key] as? String,
                   knownEpisodeIdentifiers.urls.contains(value) {
                    matchingURLs.insert(value)
                }
            }
        }
        return matchingURLs.count >= 2
    }
}

/// A deliberately small, value-only result suitable for presenting a feed
/// repair preview. The parsed XML remains inside `PodcastModelActor`; it is
/// never used as a reason to mutate a subscription before validation finishes.
struct PodcastFeedReplacementPreview: Sendable {
    let resolvedURL: URL
    let title: String
    let episodeCount: Int
    let matchesExistingEpisodes: Bool
}

struct PodcastBulkRefreshError: LocalizedError {
    let failedCount: Int
    let totalCount: Int

    var errorDescription: String? {
        "\(failedCount) of \(totalCount) podcast feeds could not be refreshed."
    }
}

struct PodcastUpdateSummary: Sendable {
    let didUpdateFeed: Bool
    let newEpisodeCount: Int
    let isPartial: Bool

    init(didUpdateFeed: Bool, newEpisodeCount: Int, isPartial: Bool = false) {
        self.didUpdateFeed = didUpdateFeed
        self.newEpisodeCount = newEpisodeCount
        self.isPartial = isPartial
    }
}

enum PodcastSubscriptionMutationError: LocalizedError {
    case missingPodcast
    case authoritativeStoreUnavailable
    case legacyProjectionFailed(Error)
    case supersededByNewerState

    var errorDescription: String? {
        switch self {
        case .missingPodcast:
            return "This podcast no longer has a usable feed and cannot change subscription state."
        case .authoritativeStoreUnavailable:
            return "Subscription storage is temporarily unavailable. Please try again."
        case .legacyProjectionFailed:
            return "The subscription was not fully applied to the library. Please try again."
        case .supersededByNewerState:
            return "A newer subscription change was received. Refresh the podcast state and try again."
        }
    }
}

/// Values captured before any refresh network await. The model objects used
/// to build this snapshot remain in the lexical snapshot scope; the prepare
/// and commit stages use fresh identities instead of carrying live models.
private struct PodcastRefreshSnapshot: Sendable {
    let feedURL: URL
    let podcastID: PersistentIdentifier
    let metadataID: PersistentIdentifier?
    let accessProfile: PodcastAccessProfile?
    let hadSuccessfulImport: Bool
    let title: String
    let knownEpisodes: KnownPodcastEpisodeIdentifiers
    let hasTimeSensitiveLiveItem: Bool
}

private struct PodcastHEADSnapshot: Sendable {
    let feedURL: URL
    let podcastID: PersistentIdentifier
    let metadataID: PersistentIdentifier
    let lastRefresh: Date?
    let accessProfile: PodcastAccessProfile?
}

@ModelActor
actor PodcastModelActor {
    private let maximumTrustedHeaderSkipInterval: TimeInterval = 60 * 60 * 6
    private let authenticationRetryInterval: TimeInterval = 6 * 60 * 60
    private static let refreshLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "UpNext",
        category: "PodcastRefresh"
    )
    private static let refreshSignpostLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "UpNext",
        category: .pointsOfInterest
    )
    /// Foreground Refresh All overlaps feed network and parse work while the
    /// commit coordinator serializes SwiftData writes. The device-local key
    /// remains a rollback control for slower or memory-constrained devices.
    static var maximumConcurrentRefreshes: Int {
        let configured = UserDefaults.standard.integer(forKey: "PodcastRefreshNetworkConcurrency")
        return configured == 0 ? 4 : min(max(configured, 1), 4)
    }

    private static func logRefresh(_ message: String) {
        refreshLogger.info("\(message, privacy: .public)")
        Task { @MainActor in
            AppDiagnostics.log("[PodcastRefresh] \(message)")
        }
    }

    private static func feedCorrelationID(_ feedURL: URL) -> String {
        var components = URLComponents(url: feedURL, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        let identity = components?.string ?? feedURL.host ?? "unknown-feed"
        return SHA256.hash(data: Data(identity.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func feedFailureStatusCode(from error: Error) -> Int? {
        if case PodcastParserError.couldNotLoad(_, let statusCode, _) = error { return statusCode }
        if case PodcastFeedResolverError.httpStatus(_, let statusCode, _) = error { return statusCode }
        if case PodcastFeedResolverError.authenticationRequired = error { return 401 }
        if case PodcastFeedResolverError.bearerAuthenticationRequired = error { return 401 }
        return nil
    }

    private static func retryAfter(from error: Error) -> Date? {
        if case PodcastParserError.couldNotLoad(_, _, let date) = error { return date }
        if case PodcastFeedResolverError.httpStatus(_, _, let date) = error { return date }
        return nil
    }

    private static func safeFeedFailureDescription(_ error: Error) -> String {
        if case PodcastParserError.notAPodcastFeed = error {
            return "The response is not a podcast feed."
        }
        if case PodcastParserError.xmlParserError(_, let line, let column) = error {
            return "The feed XML could not be parsed at line \(line), column \(column)."
        }
        if let statusCode = feedFailureStatusCode(from: error), statusCode != 0 {
            if statusCode == 401 || statusCode == 403 {
                return "Authentication is required (HTTP \(statusCode))."
            }
            return "The feed server returned HTTP \(statusCode)."
        }
        if let resolverError = error as? PodcastFeedResolverError {
            return resolverError.localizedDescription
        }
        if let recoveryError = error as? PodcastFeedEndpointRecoveryError {
            return recoveryError.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "The feed request timed out."
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return "The feed server could not be reached."
            default: break
            }
        }
        return "The feed could not be refreshed."
    }

    private func accessProfile(
        for metadata: PodcastMetaData?,
        feedURL: URL?
    ) -> PodcastAccessProfile? {
        guard let feedURL else { return nil }
        let providerID = metadata?.accessProviderID.flatMap(PremiumPodcastProviderID.init(rawValue:))
        let resolver = PodcastAccessResolver()

        if let metadata,
           let id = metadata.accessProfileID,
           let rawKind = metadata.accessKindRawValue,
           let kind = PodcastAccessKind(rawValue: rawKind) {
            let profile = PodcastAccessProfile(
                id: id,
                kind: kind,
                resourceURL: feedURL,
                providerID: providerID
            )

            // Some early private-feed records retained a canonicalized feed
            // URL but lost their access metadata. If the stored identifier no
            // longer locates a Basic credential, recover the bounded legacy
            // identifier (for example /feed/plus versus /feed/plus/) before
            // declaring the subscription unauthenticated.
            if kind != .httpBasic || resolver.credentialState(for: profile) == .available {
                return profile
            }
            if let recovered = resolver.recoverLegacyHTTPBasicProfile(
                for: feedURL,
                providerID: providerID
            ) {
                applyAccessProfile(recovered, to: metadata)
                return recovered
            }
            return profile
        }

        // A metadata row can be absent on pre-private-feed installations.
        // Probe only deterministic, local legacy identifiers; this lets the
        // Keychain credential restore the profile without treating ordinary
        // 401/403 responses as an authentication challenge.
        guard let recovered = resolver.recoverLegacyHTTPBasicProfile(
            for: feedURL,
            providerID: providerID
        ) else {
            return nil
        }
        if let metadata {
            applyAccessProfile(recovered, to: metadata)
        }
        return recovered
    }

    private func applyAccessProfile(
        _ profile: PodcastAccessProfile,
        to metadata: PodcastMetaData
    ) {
        metadata.accessProfileID = profile.id
        metadata.accessKindRawValue = profile.kind.rawValue
        metadata.accessProviderID = profile.providerID?.rawValue
        metadata.credentialState = .available
        metadata.authenticationRetryAfter = nil
    }

    private func configureAccessMetadata(for feedURL: URL, metadata: PodcastMetaData?) {
        guard let metadata, feedURL.isLikelyPrivatePodcastURL else { return }
        let kind: PodcastAccessKind = feedURL.user != nil || feedURL.password != nil
            ? .httpBasic
            : .privateURL
        let profile = PodcastAccessProfile.make(for: feedURL, kind: kind)
        metadata.accessProfileID = profile.id
        metadata.accessKindRawValue = profile.kind.rawValue
        metadata.accessProviderID = profile.providerID?.rawValue
        metadata.credentialState = .available
        switch kind {
        case .privateURL:
            try? PodcastCredentialStoreProvider.current.save(.privateURL(feedURL), for: profile)
        case .httpBasic:
            let credential = feedURL.podcastBasicCredential
            try? PodcastCredentialStoreProvider.current.save(
                .httpBasic(username: credential.username, password: credential.password),
                for: profile
            )
        case .publicFeed, .bearerToken:
            break
        }
    }

    private func recordFeedRefreshSuccess(metadataID: PersistentIdentifier) {
        guard let metadata: PodcastMetaData = modelContext.existingModel(for: metadataID) else { return }
        guard metadata.consecutiveFeedFailureCount != 0
            || metadata.firstConsecutiveFeedFailureDate != nil
            || metadata.lastFeedFailureDate != nil
            || metadata.lastFeedFailureStatusCode != nil
            || metadata.lastFeedFailureMessage != nil
            || metadata.credentialState != .available
            || metadata.authenticationRetryAfter != nil else { return }
        metadata.consecutiveFeedFailureCount = 0
        metadata.firstConsecutiveFeedFailureDate = nil
        metadata.lastFeedFailureDate = nil
        metadata.lastFeedFailureStatusCode = nil
        metadata.lastFeedFailureMessage = nil
        metadata.credentialState = .available
        metadata.authenticationRetryAfter = nil
    }

    private func recordFeedRefreshFailure(
        metadataID: PersistentIdentifier,
        error: Error
    ) {
        guard let metadata: PodcastMetaData = modelContext.existingModel(for: metadataID) else { return }
        let now = Date()
        let statusCode = Self.feedFailureStatusCode(from: error)
        if statusCode == 401 || statusCode == 403 {
            metadata.credentialState = .needsLogin
            metadata.authenticationRetryAfter = now.addingTimeInterval(authenticationRetryInterval)
            metadata.lastFeedFailureDate = now
            metadata.lastFeedFailureStatusCode = statusCode
            metadata.lastFeedFailureMessage = error.localizedDescription
            // Authentication failures are recoverable and must not feed the
            // abandoned/cancelled heuristics or trigger a retry storm.
            metadata.consecutiveFeedFailureCount = 0
            metadata.firstConsecutiveFeedFailureDate = nil
            return
        }
        if metadata.consecutiveFeedFailureCount == 0 {
            metadata.firstConsecutiveFeedFailureDate = now
        }
        metadata.consecutiveFeedFailureCount += 1
        metadata.lastFeedFailureDate = now
        metadata.lastFeedFailureStatusCode = statusCode
        metadata.lastFeedFailureMessage = error.localizedDescription
    }

    private func checkRefreshDeadline(_ deadline: Date?) throws {
        try Task.checkCancellation()
        if let deadline, Date() >= deadline {
            throw CancellationError()
        }
    }

    private func knownEpisodeIdentifiers(for podcast: Podcast) -> KnownPodcastEpisodeIdentifiers {
        var identifiers = KnownPodcastEpisodeIdentifiers()

        for episode in podcast.episodes ?? [] {
            if let guid = episode.guid, guid.isEmpty == false {
                identifiers.guids.insert(guid)
            }
            if let url = episode.url?.absoluteString, url.isEmpty == false {
                identifiers.urls.insert(url)
            }
            if let link = episode.link?.absoluteString, link.isEmpty == false {
                identifiers.urls.insert(link)
            }
        }

        return identifiers
    }

    private func recoveredEndpointMatchesExistingPodcast(
        _ parsedFeed: [String: Any],
        knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers
    ) -> Bool {
        PodcastFeedEndpointIdentity.matchesExistingPodcast(
            parsedFeed,
            knownEpisodeIdentifiers: knownEpisodeIdentifiers
        )
    }

    /// Commits a feed endpoint only after its caller has resolved HTML,
    /// redirects and RSS/Atom parsing and verified it belongs to this podcast.
    /// Updating the existing row deliberately preserves its episodes, playback
    /// state, bookmarks, playlists and preferences.
    private func commitValidatedFeedEndpoint(
        for podcast: Podcast,
        from oldURL: URL,
        to validatedEndpoint: URL,
        accessProfile: PodcastAccessProfile?,
        reason: FeedAliasReason
    ) async throws {
        let shouldRedactEndpoint = accessProfile.map { $0.kind != .publicFeed } ?? false
        let persistedEndpoint = (shouldRedactEndpoint || validatedEndpoint.isLikelyPrivatePodcastURL)
            ? validatedEndpoint.podcastNonSecretURL
            : validatedEndpoint
        guard oldURL != persistedEndpoint else { return }

        let existingDescriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.feed == persistedEndpoint }
        )
        if let existingPodcast = try? modelContext.fetch(existingDescriptor).first,
           existingPodcast.persistentModelID != podcast.persistentModelID {
            throw PodcastFeedSwitchError.feedAlreadyExists
        }

        podcast.feed = persistedEndpoint
        podcast.metaData?.feedUpdated = nil
        podcast.metaData?.feedUpdateCheckDate = nil
        if let accessProfile, let metadata = podcast.metaData {
            let migratedProfile = PodcastAccessProfile(
                id: accessProfile.id,
                kind: accessProfile.kind,
                resourceURL: persistedEndpoint,
                providerID: accessProfile.providerID
            )
            applyAccessProfile(migratedProfile, to: metadata)
        } else if validatedEndpoint.isLikelyPrivatePodcastURL {
            configureAccessMetadata(for: validatedEndpoint, metadata: podcast.metaData)
        } else if let metadata = podcast.metaData {
            // A manually repaired public endpoint must not retain stale
            // credentials from the old subscription.
            metadata.accessProfileID = nil
            metadata.accessKindRawValue = nil
            metadata.accessProviderID = nil
            metadata.credentialState = .available
            metadata.authenticationRetryAfter = nil
        }
        modelContext.saveIfNeeded()

        await recordFeedAlias(
            from: oldURL,
            to: persistedEndpoint,
            reason: reason
        )
        await SubscriptionManifestSync.publishCurrentSubscriptions(modelContainer: modelContainer)
        CrashBreadcrumbs.shared.record(
            "feed_endpoint_recovered",
            details: "method=validated_endpoint identity=episode_identifiers migration=success"
        )
    }

    private func candidateAccessProfile(
        _ profile: PodcastAccessProfile?,
        oldURL: URL,
        candidateURL: URL
    ) -> PodcastAccessProfile? {
        guard let profile else { return nil }
        // Credentials are never sent to another origin while validating a
        // suggested replacement. Same-origin path changes remain supported.
        guard oldURL.host?.caseInsensitiveCompare(candidateURL.host ?? "") == .orderedSame,
              oldURL.scheme?.caseInsensitiveCompare(candidateURL.scheme ?? "") == .orderedSame else {
            return nil
        }
        return profile
    }

    private func validateReplacement(
        for podcast: Podcast,
        candidateURL: URL,
        requiresExistingIdentity: Bool
    ) async throws -> (preview: PodcastFeedReplacementPreview, parsedFeed: [String: Any], endpoint: URL, profile: PodcastAccessProfile?) {
        guard let oldURL = podcast.feed else {
            throw PodcastFeedEndpointRecoveryError.feedCouldNotBeValidated
        }
        let oldProfile = accessProfile(for: podcast.metaData, feedURL: oldURL)
        let profile = candidateAccessProfile(oldProfile, oldURL: oldURL, candidateURL: candidateURL)
        let resolvedFeed = try await PodcastFeedResolver.resolveExistingEndpoint(
            from: candidateURL,
            profile: profile
        )
        let endpoint = resolvedFeed.url ?? candidateURL
        let parsedFeed = try await PodcastParser.fetchAllPages(
            from: endpoint,
            knownEpisodeIdentifiers: KnownPodcastEpisodeIdentifiers(),
            profile: profile
        )
        let matchesExistingEpisodes = recoveredEndpointMatchesExistingPodcast(
            parsedFeed,
            knownEpisodeIdentifiers: knownEpisodeIdentifiers(for: podcast)
        )
        if requiresExistingIdentity, endpoint != oldURL, matchesExistingEpisodes == false {
            throw PodcastFeedEndpointRecoveryError.identityCouldNotBeVerified
        }
        let title = (parsedFeed["title"] as? String) ?? resolvedFeed.title ?? "Podcast feed"
        let episodeCount = (parsedFeed["episodes"] as? [[String: Any]])?.count ?? 0
        return (
            PodcastFeedReplacementPreview(
                resolvedURL: endpoint.podcastNonSecretURL,
                title: title,
                episodeCount: episodeCount,
                matchesExistingEpisodes: matchesExistingEpisodes
            ),
            parsedFeed,
            endpoint,
            profile
        )
    }

    func previewFeedReplacement(
        _ podcastID: PersistentIdentifier,
        candidateURL: URL
    ) async throws -> PodcastFeedReplacementPreview {
        guard let podcast: Podcast = modelContext.existingModel(for: podcastID) else {
            throw PodcastFeedEndpointRecoveryError.feedCouldNotBeValidated
        }
        return try await validateReplacement(
            for: podcast,
            candidateURL: candidateURL,
            requiresExistingIdentity: false
        ).preview
    }

    func replacePodcastFeed(
        _ podcastID: PersistentIdentifier,
        candidateURL: URL,
        allowUnverifiedIdentity: Bool = false,
        reason: FeedAliasReason = .explicitSwitch,
        progress: SubscriptionProgressHandler? = nil
    ) async throws {
        guard let oldURL = modelContext.existingModel(for: podcastID)?.feed else { return }
        try await PodcastMutationCoordinator.shared.withExclusive(feedURL: oldURL) {
            try await self.performReplacePodcastFeed(
                podcastID,
                candidateURL: candidateURL,
                allowUnverifiedIdentity: allowUnverifiedIdentity,
                reason: reason,
                progress: progress
            )
        }
    }

    private func performReplacePodcastFeed(
        _ podcastID: PersistentIdentifier,
        candidateURL: URL,
        allowUnverifiedIdentity: Bool,
        reason: FeedAliasReason,
        progress: SubscriptionProgressHandler?
    ) async throws {
        guard let podcast: Podcast = modelContext.existingModel(for: podcastID),
              let oldURL = podcast.feed else { return }
        let validation = try await validateReplacement(
            for: podcast,
            candidateURL: candidateURL,
            requiresExistingIdentity: allowUnverifiedIdentity == false
        )
        guard let freshPodcast: Podcast = modelContext.existingModel(for: podcastID) else { return }
        try await commitValidatedFeedEndpoint(
            for: freshPodcast,
            from: oldURL,
            to: validation.endpoint,
            accessProfile: validation.profile,
            reason: reason
        )
        await PodcastEpisodeImportRetryQueue.shared.remove(feedURL: oldURL)
        guard let committedPodcast: Podcast = modelContext.existingModel(for: podcastID) else { return }
        _ = try await updateDetails(
            committedPodcast,
            fullPodcast: validation.parsedFeed,
            silent: true,
            progress: progress
        )
    }

    private func reportProgress(
        _ update: SubscriptionProgressUpdate,
        using progressHandler: SubscriptionProgressHandler?
    ) async {
        guard let progressHandler else { return }
        await progressHandler(update)
    }

    private func ensureMetadata(for podcast: Podcast) -> PodcastMetaData {
        if let metaData = podcast.metaData {
            return metaData
        }

        let metaData = PodcastMetaData()
        modelContext.insert(metaData)
        podcast.metaData = metaData
        modelContext.saveIfNeeded()
        return metaData
    }

    func setSubscriptionStatus(
        _ podcastID: PersistentIdentifier,
        isSubscribed: Bool
    ) async throws -> StoreSplitSubscriptionSyncWriter.Result {
        guard let feedURL = modelContext.existingModel(for: podcastID)?.feed else {
            throw PodcastSubscriptionMutationError.missingPodcast
        }
        return try await PodcastMutationCoordinator.shared.withExclusive(feedURL: feedURL) {
            try await self.performSetSubscriptionStatus(
                podcastID,
                isSubscribed: isSubscribed
            )
        }
    }

    private func performSetSubscriptionStatus(
        _ podcastID: PersistentIdentifier,
        isSubscribed: Bool
    ) async throws -> StoreSplitSubscriptionSyncWriter.Result {
        guard let podcast: Podcast = modelContext.existingModel(for: podcastID),
              let feedURL = podcast.feed else {
            throw PodcastSubscriptionMutationError.missingPodcast
        }
        let metaData = ensureMetadata(for: podcast)
        let writerResult = try await updateSplitSubscription(
            feedURL: feedURL,
            isSubscribed: isSubscribed,
            accessProfile: storedPodcastAccessProfile(for: podcast)
        )

        let effectiveState = writerResult.isSubscribed
        metaData.isSubscribed = effectiveState
        if effectiveState {
            if writerResult.didChange || metaData.subscriptionDate == nil {
                metaData.subscriptionDate = writerResult.committedAt
            }
        } else {
            metaData.subscriptionDate = nil
        }

        if effectiveState == false {
            await PodcastEpisodeImportRetryQueue.shared.remove(feedURL: feedURL)
        }
        do {
            try modelContext.save()
        } catch {
            throw PodcastSubscriptionMutationError.legacyProjectionFailed(error)
        }
        if writerResult.didChange {
            await SubscriptionManifestSync.publishCurrentSubscriptions(
                modelContainer: modelContainer,
                allowEmpty: effectiveState == false
            )
        }
        return writerResult
    }

    func switchPodcastFeed(
        _ podcastID: PersistentIdentifier,
        to alternativeFeed: PodcastAlternativeFeed,
        progress: SubscriptionProgressHandler? = nil
    ) async throws {
        guard let podcast: Podcast = modelContext.existingModel(for: podcastID) else { return }
        let alternativeFeedURL: URL? = alternativeFeed.url
        let existingDescriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { $0.feed == alternativeFeedURL }
        )

        if let existingPodcast = try? modelContext.fetch(existingDescriptor).first,
           existingPodcast.persistentModelID != podcastID {
            throw PodcastFeedSwitchError.feedAlreadyExists
        }

        try await replacePodcastFeed(
            podcastID,
            candidateURL: alternativeFeed.url,
            // An alternative advertised by the podcast is still not proof of
            // identity. Empty/new subscriptions have no episode evidence, so
            // retain the existing behaviour only for that narrow case.
            allowUnverifiedIdentity: (podcast.episodes ?? []).isEmpty,
            reason: .explicitSwitch,
            progress: progress
        )
    }

    
    func fetchPodcast(byFeed podcastFeed: URL) async -> Podcast? {
        let storedFeedURL = podcastFeed.isLikelyPrivatePodcastURL
            ? podcastFeed.podcastNonSecretURL
            : podcastFeed
        let predicate = #Predicate<Podcast> { podcast in
            // Older installs could persist the complete private URL, including
            // HTTP Basic user info. Search for both representations so those
            // records can be found and migrated before the safe identity is
            // used for subsequent lookups.
            podcast.feed == storedFeedURL || podcast.feed == podcastFeed
        }

        do {
            let exactMatch = try modelContext.fetch(FetchDescriptor<Podcast>(predicate: predicate)).first
            let podcast: Podcast?
            if let exactMatch {
                podcast = exactMatch
            } else {
                podcast = try modelContext.fetch(FetchDescriptor<Podcast>()).first(where: {
                    $0.matchesFeedURL(podcastFeed)
                })
            }
            guard let podcast else {
                return nil
            }

            // Migrate legacy records that stored the private endpoint directly
            // in SwiftData. The original URL is used once to recover the
            // credential; the model keeps only the safe identity thereafter.
            if let existingFeed = podcast.feed, existingFeed.isLikelyPrivatePodcastURL {
                let metadata = ensureMetadata(for: podcast)
                configureAccessMetadata(for: existingFeed, metadata: metadata)
                podcast.feed = existingFeed.podcastNonSecretURL
                modelContext.saveIfNeeded()
            }
            return podcast
        } catch {
            print("❌ Error fetching podcast feed \(podcastFeed.redactedPodcastURLString), Error: \(error)")
            return nil
        }
    }

    func fetchPodcastTitle(byFeed podcastFeed: URL) async -> String? {
        await fetchPodcast(byFeed: podcastFeed)?.title
    }
    
    func linkEpisodeToPodcast(
        _ episodeURL: URL,
        _ podcastFeed: URL,
        savesImmediately: Bool = true
    ) async {
   
        guard let podcast = await fetchPodcast(byFeed: podcastFeed) else { return }
        let episodedescriptor = FetchDescriptor<Episode>(predicate: #Predicate<Episode> { $0.url == episodeURL })

        guard let episode = try? modelContext.fetch(episodedescriptor).first else { return }
        if let episodes = podcast.episodes, !episodes.contains(where: { $0.url == episodeURL }) {
            episode.podcast = podcast
        }
      
        if savesImmediately {
            modelContext.saveIfNeeded()
        }
    }

    private func episodeIdentifier(from episodeData: [String: Any]) -> String? {
        if let guid = episodeData["guid"] as? String, guid.isEmpty == false {
            return guid
        }

        if let podcastGUID = episodeData["podcast:guid"] as? String, podcastGUID.isEmpty == false {
            return podcastGUID
        }

        if let enclosure = EpisodeMedia.playableEnclosure(from: episodeData["enclosure"] as? [[String: Any]])?["url"] as? String,
           enclosure.isEmpty == false {
            return enclosure
        }

        if let link = episodeData["link"] as? String, link.isEmpty == false {
            return link
        }

        return nil
    }

    private func episodeURL(from episodeData: [String: Any]) -> URL? {
        guard let enclosure = EpisodeMedia.playableEnclosure(from: episodeData["enclosure"] as? [[String: Any]])?["url"] as? String,
              enclosure.isEmpty == false else {
            return nil
        }

        return URL(string: enclosure)
    }

    private func existingEpisodeURL(identifier: String?, episodeURL: URL?) -> URL? {
        if let identifier {
            let descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate<Episode> { $0.guid == identifier }
            )

            if let existingURL = (try? modelContext.fetch(descriptor))?.first?.url {
                return existingURL
            }
        }

        guard let episodeURL else { return nil }
        return fetchEpisode(byURL: episodeURL)?.url
    }

    private func fetchEpisode(byURL episodeURL: URL) -> Episode? {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.url == episodeURL }
        )

        return try? modelContext.fetch(descriptor).first
    }

    private func refreshFeedExternalFiles(
        for episodeURL: URL,
        from episodeData: [String: Any],
        savesImmediately: Bool = true
    ) {
        guard let episode = fetchEpisode(byURL: episodeURL) else { return }
        episode.refreshFeedExternalFiles(from: episodeData)
        if savesImmediately {
            modelContext.saveIfNeeded()
        }
    }

    private func fillMissingRemoteMP3DurationIfNeeded(
        episodeID: PersistentIdentifier,
        episodeURL: URL?,
        currentDuration: TimeInterval?
    ) async {
        guard currentDuration == nil || currentDuration == 0,
              let episodeURL,
              episodeURL.pathExtension.lowercased() == "mp3" else {
            return
        }

        guard let duration = try? await RemoteMP3DurationReader.duration(from: episodeURL),
              duration > 0 else {
            return
        }

        guard let episode: Episode = modelContext.existingModel(for: episodeID),
              episode.duration == nil || episode.duration == 0 else {
            return
        }

        episode.duration = duration
        modelContext.saveIfNeeded()
    }

    private func suppressFromInbox(
        _ episode: Episode,
        reason: EpisodeSystemSuppressionReason
    ) {
        if episode.metaData == nil {
            let metadata = EpisodeMetaData()
            metadata.episode = episode
            episode.metaData = metadata
        }

        episode.metaData?.setInboxMembership(false)
        episode.metaData?.systemSuppressionReason = reason
    }
    

    
    func safeFetchMeta(_ id: PersistentIdentifier) -> PodcastMetaData? {
        let descriptor = FetchDescriptor<PodcastMetaData>(
            predicate: #Predicate { $0.persistentModelID == id }
        )
        return try? modelContext.fetch(descriptor).first
    }
    
    func checkIfFeedHasBeenUpdated(_ podcastFeed: URL) async -> Bool? {
        let snapshot: PodcastHEADSnapshot
        do {
            guard let podcast = await fetchPodcast(byFeed: podcastFeed),
                  let feedURL = podcast.feed else { return nil }
            let podcastID = podcast.persistentModelID
            var metadataID = podcast.metaData?.persistentModelID
            if metadataID == nil {
                let metadata = PodcastMetaData()
                modelContext.insert(metadata)
                podcast.metaData = metadata
                modelContext.saveIfNeeded()
                metadataID = metadata.persistentModelID
            }
            guard let metadataID else { return nil }
            snapshot = PodcastHEADSnapshot(
                feedURL: feedURL,
                podcastID: podcastID,
                metadataID: metadataID,
                lastRefresh: safeFetchMeta(metadataID)?.lastRefresh,
                accessProfile: accessProfile(for: podcast.metaData, feedURL: feedURL)
            )
        }

        let status = try? await snapshot.feedURL.status(profile: snapshot.accessProfile)
        if Task.isCancelled { return nil }
        let serverLastModified = status?.lastModified
        let now = Date()
        



        // --- Re-fetch fresh models after await ---
        guard
            let freshPodcast: Podcast = modelContext.existingModel(for: snapshot.podcastID),
            freshPodcast.feed == snapshot.feedURL,
            let freshMeta: PodcastMetaData = modelContext.existingModel(for: snapshot.metadataID)
        else {
            return nil
        }

       
        // A redirect is evidence to refresh, never permission to overwrite a
        // subscription. `updatePodcast` resolves, parses and verifies it
        // before committing a replacement endpoint.
        
        // Treat the preflight request as advisory only. Some feeds either reject HEAD
        // requests or return stale/missing Last-Modified values.
        var feedWasUpdated: Bool?
        defer {
            // Keep the status in memory until the caller has handled the
            // result. Persisting "checking", then "unchanged", then clearing
            // old errors made one empty feed check create several CloudKit
            // history transactions for the legacy graph.
            freshMeta.feedUpdateCheckDate = now
            freshMeta.feedUpdated = feedWasUpdated
        }
        guard let statusCode = status?.statusCode else {
            return nil
        }

        if statusCode == 401 || statusCode == 403 {
            freshMeta.credentialState = .needsLogin
            freshMeta.authenticationRetryAfter = now.addingTimeInterval(authenticationRetryInterval)
            freshMeta.lastFeedFailureDate = now
            freshMeta.lastFeedFailureStatusCode = statusCode
            freshMeta.lastFeedFailureMessage = status?.displayMessage
            freshMeta.consecutiveFeedFailureCount = 0
            freshMeta.firstConsecutiveFeedFailureDate = nil
            return nil
        }

        guard (200...299).contains(statusCode) || (300...399).contains(statusCode) else {
            return nil
        }

        guard let serverLastModified else {
            return nil
        }

        if serverLastModified > (snapshot.lastRefresh ?? .distantPast) {
            feedWasUpdated = true
            return true
        }

        if let lastRefreshSnapshot = snapshot.lastRefresh,
           now.timeIntervalSince(lastRefreshSnapshot) > maximumTrustedHeaderSkipInterval {
            return nil
        }

        feedWasUpdated = false
        return false
    }
    
    
    func updateLastRefresh(for metadataID: PersistentIdentifier) async {
        let descriptor = FetchDescriptor<PodcastMetaData>(
            predicate: #Predicate { $0.persistentModelID == metadataID }
        )
        let metaData = try? modelContext.fetch(descriptor).first
        metaData?.lastRefresh = Date()
        metaData?.feedUpdateCheckDate = Date()
        // The refresh caller saves this with the imported feed graph.
    }
    
    func updateFeedURL(_ podcastFeed: URL) async{
        // Kept for callers on older refresh paths. Do not persist the result
        // of a reachability probe: it might be HTML, a login page or a
        // temporary redirect. A forced refresh performs the validated path.
        _ = try? await updatePodcast(podcastFeed, policy: .validatedImport, silent: true)
    }

    func bootstrapPodcast(
        _ podcastFeed: URL,
        maximumEpisodes: Int
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard let podcast = await fetchPodcast(byFeed: podcastFeed) else { return false }
        guard let feedURL = podcast.feed else { return false }

        let podcastIDRef = podcast.persistentModelID
        var metaIDRef = podcast.metaData?.persistentModelID

        if podcast.metaData == nil {
            let meta = PodcastMetaData()
            modelContext.insert(meta)
            podcast.metaData = meta
            modelContext.saveIfNeeded()
            metaIDRef = meta.persistentModelID
        }

        let accessProfile = accessProfile(for: podcast.metaData, feedURL: feedURL)

        if let accessProfile,
           PodcastAccessResolver().credentialState(for: accessProfile) != .available {
            if let metaIDRef,
               let metadata: PodcastMetaData = modelContext.existingModel(for: metaIDRef) {
                metadata.credentialState = .missing
                metadata.authenticationRetryAfter = nil
                metadata.lastFeedFailureStatusCode = nil
                metadata.lastFeedFailureMessage = PodcastAccessError.credentialMissing(accessProfile.id).localizedDescription
            }
            modelContext.saveIfNeeded()
            return false
        }

        // Manifest/store-split restore can call bootstrap again after a
        // relaunch when a protected feed has no episodes yet. Respect the
        // authentication backoff here as well as in updatePodcast, otherwise
        // a rejected credential would be retried on every launch until the
        // user repairs it.
        if let metaIDRef,
           let metadata: PodcastMetaData = modelContext.existingModel(for: metaIDRef),
           metadata.credentialState == .needsLogin,
           let retryAfter = metadata.authenticationRetryAfter,
           retryAfter > Date() {
            return false
        }

        if let metaIDRef,
           let freshMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef) {
            freshMeta.message = "Restoring subscription ..."
            freshMeta.isUpdating = true
        }
        if let freshPodcast: Podcast = modelContext.existingModel(for: podcastIDRef) {
            freshPodcast.message = "Restoring subscription ..."
        }
        modelContext.saveIfNeeded()

        do {
            let page = try await PodcastParser.fetchPage(
                from: feedURL,
                maximumEpisodes: maximumEpisodes,
                profile: accessProfile
            )
            try Task.checkCancellation()

            guard
                let metaIDRef,
                let finalMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef),
                let finalPodcast: Podcast = modelContext.existingModel(for: podcastIDRef)
            else {
                return false
            }

            var partialPodcast = page.parsedFeed
            partialPodcast["episodes"] = page.episodes.map(\.rawEpisodeData)

            _ = try await updateDetails(
                finalPodcast,
                fullPodcast: partialPodcast,
                silent: true
            )

            finalPodcast.message = nil
            finalMeta.message = nil
            finalMeta.isUpdating = false
            finalMeta.feedUpdated = true
            await updateLastRefresh(for: finalMeta.persistentModelID)
            PodcastReleasePredictor.updateCachedPrediction(for: finalPodcast, after: Date())
            modelContext.saveIfNeeded()
            await reconcileLiveNotifications(for: finalPodcast)
            return true
        } catch {
            if let metaIDRef {
                recordFeedRefreshFailure(metadataID: metaIDRef, error: error)
            }
            if let metaIDRef,
               let failedMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef) {
                failedMeta.isUpdating = false
                failedMeta.message = nil
                failedMeta.feedUpdateCheckDate = Date()
            }
            if let failedPodcast: Podcast = modelContext.existingModel(for: podcastIDRef) {
                failedPodcast.message = nil
            }
            modelContext.saveIfNeeded()
            throw error
        }
    }

    func updatePodcast(
        _ podcastFeed: URL,
        policy: PodcastRefreshRequestPolicy = .regular,
        refreshRunID: UUID = UUID(),
        silent: Bool? = false,
        resolveExistingMissingDurations: Bool = true,
        processNewEpisodesDuringSilentRefresh: Bool = false,
        deadline: Date? = nil,
        initialPage: PreparedPodcastFeedSeed? = nil,
        startingAt: URL? = nil,
        progress: SubscriptionProgressHandler? = nil
    ) async throws -> Bool {
        let summary = try await updatePodcastWithSummary(
            podcastFeed,
            policy: policy,
            refreshRunID: refreshRunID,
            silent: silent,
            resolveExistingMissingDurations: resolveExistingMissingDurations,
            processNewEpisodesDuringSilentRefresh: processNewEpisodesDuringSilentRefresh,
            deadline: deadline,
            initialPage: initialPage,
            startingAt: startingAt,
            progress: progress
        )
        return summary.didUpdateFeed
    }

    func updatePodcastWithSummary(
        _ podcastFeed: URL,
        policy: PodcastRefreshRequestPolicy = .regular,
        refreshRunID: UUID = UUID(),
        silent: Bool? = false,
        resolveExistingMissingDurations: Bool = true,
        processNewEpisodesDuringSilentRefresh: Bool = false,
        deadline: Date? = nil,
        initialPage: PreparedPodcastFeedSeed? = nil,
        startingAt: URL? = nil,
        progress: SubscriptionProgressHandler? = nil
    ) async throws -> PodcastUpdateSummary {
        let operation: @Sendable (SubscriptionProgressHandler?) async throws -> PodcastUpdateSummary = { activeProgress in
            try await PodcastMutationCoordinator.shared.withExclusive(feedURL: podcastFeed) {
                try await self.performUpdatePodcastWithSummary(
                    podcastFeed,
                    policy: policy,
                    refreshRunID: refreshRunID,
                    silent: silent,
                    resolveExistingMissingDurations: resolveExistingMissingDurations,
                    processNewEpisodesDuringSilentRefresh: processNewEpisodesDuringSilentRefresh,
                    deadline: deadline,
                    initialPage: initialPage,
                    startingAt: startingAt,
                    progress: activeProgress
                )
            }
        }

        // Imports and page continuations carry a specific validated seed or
        // checkpoint. They still use the mutation lock, but must not join a
        // general refresh that would discard that input.
        if initialPage != nil || startingAt != nil {
            return try await operation(progress)
        }

        let profileScope: String?
        if let currentPodcast = await fetchPodcast(byFeed: podcastFeed) {
            profileScope = accessProfile(
                for: currentPodcast.metaData,
                feedURL: currentPodcast.feed
            )?.id
        } else {
            profileScope = nil
        }

        return try await FeedRefreshCoordinator.shared.run(
            feedURL: podcastFeed,
            profileScope: profileScope,
            intent: .init(
                requiresGET: policy.forceGETRegardlessOfHEAD,
                visible: silent != true,
                resolvesMissingDurations: resolveExistingMissingDurations,
                processesNewEpisodes: processNewEpisodesDuringSilentRefresh,
                deadline: deadline
            ),
            progress: progress,
            operation: operation
        )
    }

    private func performUpdatePodcastWithSummary(
        _ podcastFeed: URL,
        policy: PodcastRefreshRequestPolicy,
        refreshRunID: UUID,
        silent: Bool?,
        resolveExistingMissingDurations: Bool,
        processNewEpisodesDuringSilentRefresh: Bool,
        deadline: Date?,
        initialPage: PreparedPodcastFeedSeed?,
        startingAt: URL?,
        progress: SubscriptionProgressHandler?
    ) async throws -> PodcastUpdateSummary {
        let refreshSignpostID = OSSignpostID(log: Self.refreshSignpostLog)
        os_signpost(
            .begin,
            log: Self.refreshSignpostLog,
            name: "Podcast feed refresh",
            signpostID: refreshSignpostID
        )
        os_signpost(
            .event,
            log: Self.refreshSignpostLog,
            name: "Podcast refresh correlation",
            signpostID: refreshSignpostID,
            "run_id=%{public}@ feed_id=%{public}@",
            refreshRunID.uuidString as NSString,
            Self.feedCorrelationID(podcastFeed) as NSString
        )
        defer {
            os_signpost(
                .end,
                log: Self.refreshSignpostLog,
                name: "Podcast feed refresh",
                signpostID: refreshSignpostID
            )
        }
        let refreshStartedAt = ContinuousClock.now
        var statusDuration: Duration = .zero
        var downloadAndParseDuration: Duration = .zero
        var databaseDuration: Duration = .zero
        var refreshStage = "snapshot"

        func logRefreshResult(_ result: String) {
            let totalDuration = refreshStartedAt.duration(to: .now)
            Self.logRefresh(
                "feed=\(podcastFeed.redactedPodcastURLString) "
                    + "run_id=\(refreshRunID.uuidString) "
                    + "feed_id=\(Self.feedCorrelationID(podcastFeed)) "
                    + "result=\(result) "
                    + "stage=\(refreshStage) "
                    + "status=\(Self.milliseconds(statusDuration))ms "
                    + "download_parse=\(Self.milliseconds(downloadAndParseDuration))ms "
                    + "database=\(Self.milliseconds(databaseDuration))ms "
                    + "total=\(Self.milliseconds(totalDuration))ms"
            )
        }

        try checkRefreshDeadline(deadline)
        let snapshot: PodcastRefreshSnapshot
        do {
            guard let podcast = await fetchPodcast(byFeed: podcastFeed),
                  let feedURL = podcast.feed else {
                return PodcastUpdateSummary(didUpdateFeed: false, newEpisodeCount: 0)
            }
            guard podcast.isSubscribed else {
                return PodcastUpdateSummary(didUpdateFeed: false, newEpisodeCount: 0)
            }
            let podcastID = podcast.persistentModelID
            var metadataID = podcast.metaData?.persistentModelID
            if podcast.metaData == nil {
                let metadata = PodcastMetaData()
                modelContext.insert(metadata)
                podcast.metaData = metadata
                modelContext.saveIfNeeded()
                metadataID = metadata.persistentModelID
            }

            let profile = accessProfile(for: podcast.metaData, feedURL: feedURL)
            if let profile,
               PodcastAccessResolver().credentialState(for: profile) != .available {
                if let metadataID,
                   let metadata: PodcastMetaData = modelContext.existingModel(for: metadataID) {
                    metadata.credentialState = .missing
                    metadata.authenticationRetryAfter = nil
                    metadata.lastFeedFailureStatusCode = nil
                    metadata.lastFeedFailureMessage = PodcastAccessError.credentialMissing(profile.id).localizedDescription
                }
                modelContext.saveIfNeeded()
                return PodcastUpdateSummary(didUpdateFeed: false, newEpisodeCount: 0)
            }
            if policy.forceGETRegardlessOfHEAD == false,
               let metadataID,
               let metadata: PodcastMetaData = modelContext.existingModel(for: metadataID),
               let retryAfter = metadata.authenticationRetryAfter,
               retryAfter > Date() {
                return PodcastUpdateSummary(didUpdateFeed: false, newEpisodeCount: 0)
            }

            let liveVerificationHorizon = Date().addingTimeInterval(24 * 60 * 60)
            let liveNeedsGET = podcast.liveItems.contains { item in
                item.status == .live
                    || item.status == .pending
                        && (item.start.map { $0 <= liveVerificationHorizon } ?? true)
            }
            if silent != true, let metadataID,
               let metadata: PodcastMetaData = modelContext.existingModel(for: metadataID) {
                metadata.message = "Refreshing Podcast ..."
                metadata.isUpdating = true
            }
            snapshot = PodcastRefreshSnapshot(
                feedURL: feedURL,
                podcastID: podcastID,
                metadataID: metadataID,
                accessProfile: profile,
                hadSuccessfulImport: podcast.metaData?.lastRefresh != nil,
                title: podcast.title,
                knownEpisodes: knownEpisodeIdentifiers(for: podcast),
                hasTimeSensitiveLiveItem: liveNeedsGET
            )
        }
        let feedURL = snapshot.feedURL
        let podcastIDRef = snapshot.podcastID
        let metaIDRef = snapshot.metadataID
        let accessProfile = snapshot.accessProfile
        let hadSuccessfulImport = snapshot.hadSuccessfulImport
        let titleSnapshot = snapshot.title
        let knownEpisodeIdentifiers = snapshot.knownEpisodes
        let existingEpisodeIdentifiers = snapshot.knownEpisodes
        let hasTimeSensitiveLiveItem = snapshot.hasTimeSensitiveLiveItem
        /*
        if let freshPodcast: Podcast = modelContext.existingModel(for: podcastIDRef) {
            freshPodcast.message = "Refreshing Podcast ..."
        }
         */
        await reportProgress(SubscriptionProgressUpdate(0.12, "Checking feed status"), using: progress)
        try checkRefreshDeadline(deadline)
        var headWasInconclusive = false

        // Probe the saved endpoint before downloading or parsing its body.
        // A successful unchanged HEAD should end this refresh without a GET.
        if policy.performHEAD, startingAt == nil, initialPage?.matches(feedURL) != true {
            refreshStage = "status_check"
            let statusSignpostID = OSSignpostID(log: Self.refreshSignpostLog)
            os_signpost(.begin, log: Self.refreshSignpostLog, name: "Podcast refresh HEAD", signpostID: statusSignpostID)
            let statusStartedAt = ContinuousClock.now
            let feedWasUpdated = await checkIfFeedHasBeenUpdated(feedURL)
            headWasInconclusive = feedWasUpdated == nil
            os_signpost(.end, log: Self.refreshSignpostLog, name: "Podcast refresh HEAD", signpostID: statusSignpostID)
            statusDuration = statusStartedAt.duration(to: .now)
            guard policy.shouldGET(
                afterHEADResult: feedWasUpdated,
                hasTimeSensitiveLiveItem: hasTimeSensitiveLiveItem
            ) else {
                print("\(titleSnapshot) not updated")

                if silent != true {
                    if let metaIDRef, let freshMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef) {
                        freshMeta.isUpdating = false
                        freshMeta.message = nil
                    }
                    if let freshPodcast: Podcast = modelContext.existingModel(for: podcastIDRef) {
                        freshPodcast.message = nil
                    }
                }
                if let metaIDRef {
                    recordFeedRefreshSuccess(metadataID: metaIDRef)
                    if let freshPodcast: Podcast = modelContext.existingModel(for: podcastIDRef) {
                        PodcastReleasePredictor.updateCachedPrediction(for: freshPodcast, after: Date())
                    }
                    modelContext.saveIfNeeded()
                }
                await reportProgress(SubscriptionProgressUpdate(1.0, "Feed already up to date"), using: progress)
                await PodcastEpisodeImportRetryQueue.shared.remove(feedURL: feedURL)
                logRefreshResult("not-modified")
                return PodcastUpdateSummary(didUpdateFeed: false, newEpisodeCount: 0)
            }
            modelContext.saveIfNeeded()
        }
        try checkRefreshDeadline(deadline)
        refreshStage = "endpoint_resolution"

        let conditionalValidator = policy.performHEAD
            && policy.forceGETRegardlessOfHEAD == false
            && hasTimeSensitiveLiveItem == false
            && headWasInconclusive
            && hadSuccessfulImport
            && startingAt == nil
            && initialPage == nil
            ? await PodcastHTTPValidatorStore.shared.validated(for: feedURL, profile: accessProfile)
            : nil
        let feedClient = conditionalValidator.map {
            PodcastHTTPClient(conditionalFeedURL: feedURL, conditionalValidator: $0)
        } ?? .shared

        // Resolve only the stored feed URL. URLSession may follow an HTTP
        // redirect for this request, but website discovery must not choose a
        // different RSS feed during an ordinary refresh.
        let resolvedEndpoint: URL
        let resolvedAccessProfile: PodcastAccessProfile?
        let resolvedInitialPage: PreparedPodcastFeedSeed?
        if startingAt != nil {
            // A persisted continuation was created from a previously validated
            // feed. Resume at that page instead of downloading the first page
            // again just to repeat endpoint validation.
            resolvedEndpoint = feedURL
            resolvedAccessProfile = accessProfile
            resolvedInitialPage = nil
        } else if let initialPage, initialPage.matches(feedURL) {
            resolvedEndpoint = feedURL
            resolvedAccessProfile = accessProfile
            resolvedInitialPage = initialPage
        } else {
            let endpointSignpostID = OSSignpostID(log: Self.refreshSignpostLog)
            os_signpost(.begin, log: Self.refreshSignpostLog, name: "Podcast endpoint validation", signpostID: endpointSignpostID)
            do {
                let resolvedFeed = try await PodcastRefreshNetworkPreparer.resolveEndpoint(
                    from: feedURL,
                    profile: accessProfile,
                    knownEpisodeIdentifiers: knownEpisodeIdentifiers,
                    client: feedClient
                )
                os_signpost(.end, log: Self.refreshSignpostLog, name: "Podcast endpoint validation", signpostID: endpointSignpostID)
                resolvedEndpoint = resolvedFeed.url
                resolvedAccessProfile = accessProfile
                resolvedInitialPage = resolvedFeed.firstPage
            } catch {
                os_signpost(.end, log: Self.refreshSignpostLog, name: "Podcast endpoint validation", signpostID: endpointSignpostID)
                if error is PodcastHTTPNotModified, conditionalValidator != nil,
                   let metaIDRef,
                   let metadata: PodcastMetaData = modelContext.existingModel(for: metaIDRef) {
                    metadata.feedUpdateCheckDate = Date()
                    metadata.feedUpdated = false
                    metadata.isUpdating = false
                    metadata.message = nil
                    if let currentPodcast: Podcast = modelContext.existingModel(for: podcastIDRef) {
                        currentPodcast.message = nil
                        PodcastReleasePredictor.updateCachedPrediction(for: currentPodcast, after: Date())
                    }
                    recordFeedRefreshSuccess(metadataID: metaIDRef)
                    modelContext.saveIfNeeded()
                    await reportProgress(SubscriptionProgressUpdate(1.0, "Feed already up to date"), using: progress)
                    logRefreshResult("not-modified-304")
                    return PodcastUpdateSummary(didUpdateFeed: false, newEpisodeCount: 0)
                }
                let primaryError = error as NSError
                Self.logRefresh(
                    "endpoint_primary_failure feed=\(feedURL.redactedPodcastURLString) "
                        + "error_domain=\(primaryError.domain) error_code=\(primaryError.code) "
                        + "reason=\(Self.safeFeedFailureDescription(error))"
                )
                if error is PodcastFeedResolverError {
                    CrashBreadcrumbs.shared.record(
                        "feed_endpoint_validation_failed",
                        details: "stage=endpoint_validation"
                    )
                }
                if let metaIDRef,
                   let freshMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef) {
                    freshMeta.isUpdating = false
                    freshMeta.message = nil
                    if error is CancellationError == false {
                        freshMeta.feedUpdateCheckDate = Date()
                    }
                }
                if let freshPodcast: Podcast = modelContext.existingModel(for: podcastIDRef) {
                    freshPodcast.message = nil
                }
                if error is CancellationError == false, let metaIDRef {
                    recordFeedRefreshFailure(metadataID: metaIDRef, error: error)
                    if let freshMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef) {
                        freshMeta.lastFeedFailureMessage = "Feed refresh failed. \(Self.safeFeedFailureDescription(error))"
                    }
                }
                modelContext.saveIfNeeded()
                if error is CancellationError == false {
                    await PodcastEpisodeImportRetryQueue.shared.enqueue(
                        feedURL: feedURL,
                        error: error,
                        retryAfter: Self.retryAfter(from: error)
                    )
                }
                await reportProgress(
                    SubscriptionProgressUpdate(
                        1,
                        error is CancellationError
                            ? "Refresh paused"
                            : "Cannot validate feed — \(Self.safeFeedFailureDescription(error))"
                    ),
                    using: progress
                )
                let failure = error as NSError
                logRefreshResult(
                    error is CancellationError
                        ? "cancelled"
                        : "endpoint-resolution-failed error_domain=\(failure.domain) error_code=\(failure.code)"
                )
                throw error
            }
        }
        let shouldRedactResolvedEndpoint = resolvedAccessProfile.map { $0.kind != .publicFeed } ?? false
        let persistedResolvedEndpoint = (shouldRedactResolvedEndpoint || resolvedEndpoint.isLikelyPrivatePodcastURL)
            ? resolvedEndpoint.podcastNonSecretURL
            : resolvedEndpoint
        let endpointChanged = persistedResolvedEndpoint != feedURL

        // --- Next await boundary ---
        guard
              let metaIDRef,
              let freshMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef),
              let freshPodcast: Podcast = modelContext.existingModel(for: podcastIDRef) else {
            return PodcastUpdateSummary(didUpdateFeed: false, newEpisodeCount: 0)
        }
         
        // Safe updates again
        if silent != true {
            freshMeta.message = "Reading Podcast Feed."
            freshPodcast.message = "Reading Podcast Feed."
        }
        await reportProgress(SubscriptionProgressUpdate(0.32, "Downloading and parsing feed"), using: progress)
        try checkRefreshDeadline(deadline)

        do {
            var initialPageNewEpisodeCount = 0
            refreshStage = "initial_page_import"
            if endpointChanged == false,
               let resolvedInitialPage, resolvedInitialPage.matches(resolvedEndpoint),
               // A complete single-page feed is already the whole import. Defer
               // its one database pass until the parse/identity checks below
               // have completed; importing it here and then again in
               // `updateDetails` needlessly touches every episode twice and can
               // keep CloudKit's import background task alive for too long.
               resolvedInitialPage.shouldCommitBeforeContinuation {
                // Make the already validated first page visible and durable
                // before downloading the rest of a large back catalogue.
                let commitCoordinator = PodcastFeedCommitCoordinator.shared
                try await commitCoordinator.acquire()
                guard let seedPodcast: Podcast = modelContext.existingModel(for: podcastIDRef),
                      seedPodcast.feed == feedURL else {
                    await commitCoordinator.release()
                    return PodcastUpdateSummary(didUpdateFeed: false, newEpisodeCount: 0)
                }
                do {
                    try checkRefreshDeadline(deadline)
                    let seedFeed = try resolvedInitialPage.feed.importDictionary
                    initialPageNewEpisodeCount = try await updateDetails(
                        seedPodcast,
                        fullPodcast: knownEpisodeIdentifiers.stoppingAtFirstKnownEpisode(
                            in: seedFeed
                        ),
                        silent: true,
                        resolveExistingMissingDurations: false,
                        processNewEpisodesDuringSilentRefresh: false,
                        deadline: deadline,
                        writerAlreadyHeld: true,
                        updateCache: false
                    )
                    modelContext.saveIfNeeded()
                } catch {
                    await commitCoordinator.release()
                    throw error
                }
                await commitCoordinator.release()
                if let checkpoint = resolvedInitialPage.nextPageURL {
                    await PodcastEpisodeImportRetryQueue.shared.checkpoint(
                        feedURL: feedURL,
                        resumeURL: checkpoint
                    )
                }
            }

            // Parse XML
            refreshStage = "feed_parse"
            let downloadAndParseStartedAt = ContinuousClock.now
            let parseSignpostID = OSSignpostID(log: Self.refreshSignpostLog)
            os_signpost(.begin, log: Self.refreshSignpostLog, name: "Podcast refresh GET and parse", signpostID: parseSignpostID)
            let preparedOutcome: PodcastRefreshNetworkPreparer.Outcome
            do {
                preparedOutcome = try await PodcastRefreshNetworkPreparer.preparePages(
                    from: resolvedEndpoint,
                    knownEpisodeIdentifiers: knownEpisodeIdentifiers,
                    profile: resolvedAccessProfile,
                    firstPage: startingAt == nil ? resolvedInitialPage : nil,
                    startingAt: startingAt,
                    client: feedClient
                )
                os_signpost(.end, log: Self.refreshSignpostLog, name: "Podcast refresh GET and parse", signpostID: parseSignpostID)
            } catch {
                os_signpost(.end, log: Self.refreshSignpostLog, name: "Podcast refresh GET and parse", signpostID: parseSignpostID)
                throw error
            }
            let preparedFeed = preparedOutcome.feed
            downloadAndParseDuration = downloadAndParseStartedAt.duration(to: .now)
            try checkRefreshDeadline(deadline)

            let commitCoordinator = PodcastFeedCommitCoordinator.shared
            let writerWaitStartedAt = ContinuousClock.now
            try await commitCoordinator.acquire()
            var writerHeld = true
            defer {
                if writerHeld { Task { await commitCoordinator.release() } }
            }
            os_signpost(
                .event,
                log: Self.refreshSignpostLog,
                name: "Podcast feed writer acquired",
                "wait_ms=%{public}lld buffered_bytes=%{public}lld",
                Self.milliseconds(writerWaitStartedAt.duration(to: .now)),
                Int64(preparedFeed.bufferedByteCount)
            )
            try checkRefreshDeadline(deadline)
            let fullPodcast = try preparedFeed.importDictionary

            guard
                let finalMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef),
                let finalPodcast: Podcast = modelContext.existingModel(for: podcastIDRef),
                finalPodcast.feed == feedURL
            else {
                return PodcastUpdateSummary(didUpdateFeed: false, newEpisodeCount: 0)
            }

            refreshStage = "identity_verification"
            if endpointChanged, existingEpisodeIdentifiers.isEmpty == false {
                // This is content returned by an HTTP redirect from the saved
                // URL. Verify it against known playable episodes, while
                // leaving the saved subscription URL unchanged.
                let stoppedAtKnownEpisode = resolvedInitialPage?.didStopAtKnownEpisode == true
                    || (fullPodcast["didStopAtKnownEpisode"] as? Bool == true)
                let identityVerified: Bool
                if stoppedAtKnownEpisode {
                    identityVerified = true
                } else {
                    identityVerified = recoveredEndpointMatchesExistingPodcast(
                        fullPodcast,
                        knownEpisodeIdentifiers: existingEpisodeIdentifiers
                    )
                }
                guard identityVerified else {
                    CrashBreadcrumbs.shared.record(
                        "feed_endpoint_recovery_failed",
                        details: "stage=identity_verification"
                    )
                    throw PodcastFeedEndpointRecoveryError.identityCouldNotBeVerified
                }
            }

            let importPodcast = knownEpisodeIdentifiers.stoppingAtFirstKnownEpisode(in: fullPodcast)

            // Update podcast details safely
            if silent != true {
                finalMeta.message = "Updating Podcast details"
                finalPodcast.message = "Updating Podcast details"
            }
            await reportProgress(SubscriptionProgressUpdate(0.56, "Updating podcast details"), using: progress)

            refreshStage = "episode_import"
            let databaseStartedAt = ContinuousClock.now
            let writeSignpostID = OSSignpostID(log: Self.refreshSignpostLog)
            os_signpost(.begin, log: Self.refreshSignpostLog, name: "Podcast refresh store commit", signpostID: writeSignpostID)
            let newEpisodeCount: Int
            do {
                newEpisodeCount = try await updateDetails(
                    finalPodcast,
                    fullPodcast: importPodcast,
                    silent: silent,
                    resolveExistingMissingDurations: resolveExistingMissingDurations,
                    processNewEpisodesDuringSilentRefresh: processNewEpisodesDuringSilentRefresh,
                    deadline: deadline,
                    progress: progress,
                    writerAlreadyHeld: true,
                    updateCache: false
                )
                os_signpost(.end, log: Self.refreshSignpostLog, name: "Podcast refresh store commit", signpostID: writeSignpostID)
            } catch {
                os_signpost(.end, log: Self.refreshSignpostLog, name: "Podcast refresh store commit", signpostID: writeSignpostID)
                throw error
            }
            let totalNewEpisodeCount = initialPageNewEpisodeCount + newEpisodeCount

            var enrichmentSources: [String] = []
            if let description = importPodcast["description"] as? String {
                enrichmentSources.append(description)
            }
            if let episodes = importPodcast["episodes"] as? [[String: Any]] {
                for episode in episodes {
                    if let content = episode["content"] as? String {
                        enrichmentSources.append(content)
                    }
                    if let description = episode["description"] as? String {
                        enrichmentSources.append(description)
                    }
                }
            }
            if silent != true {
                finalPodcast.message = nil
                finalMeta.message = nil
                finalMeta.isUpdating = false
            }
            refreshStage = "finalization"
            finalMeta.feedUpdated = true
            let importIsPartial = preparedOutcome.isPartial
            if importIsPartial {
                finalMeta.feedUpdated = false
                finalMeta.lastFeedFailureDate = Date()
                finalMeta.lastFeedFailureMessage = "Episode import is incomplete and needs to resume."
                CrashBreadcrumbs.shared.record(
                    "feed_import_partial",
                    details: "resume_available=\((fullPodcast["resumeURL"] as? String) != nil)"
                )
                let resumeURL = (fullPodcast["resumeURL"] as? String).flatMap(URL.init(string:))
                if let resumeURL {
                    await PodcastEpisodeImportRetryQueue.shared.enqueue(
                        feedURL: feedURL,
                        resumeURL: resumeURL
                    )
                } else {
                    // Cyclic pages have no safe continuation URL. Keep the
                    // imported episodes and expose manual retry without
                    // scheduling the same known cycle repeatedly.
                    await PodcastEpisodeImportRetryQueue.shared.remove(feedURL: feedURL)
                }
            } else {
                recordFeedRefreshSuccess(metadataID: finalMeta.persistentModelID)
                await updateLastRefresh(for: finalMeta.persistentModelID)
                await PodcastEpisodeImportRetryQueue.shared.remove(feedURL: feedURL)
            }
            PodcastReleasePredictor.updateCachedPrediction(for: finalPodcast, after: Date())
            modelContext.saveIfNeeded()
            await MainActor.run {
                NotificationCenter.default.post(name: .smartPlaylistEpisodeDataDidChange, object: nil)
            }
            // The cache projection reads the just-committed graph and writes a
            // shared cache store. Keep it behind the same writer gate so only
            // one large materialized feed and cache projection are active.
            await updateFeedCache(
                feedURL: feedURL,
                parsedFeed: fullPodcast,
                deadline: deadline
            )
            writerHeld = false
            await commitCoordinator.release()
            await ShownoteEnrichmentService.shared.enqueue(htmlSources: enrichmentSources)
            if importIsPartial {
                await PodcastHTTPValidatorStore.shared.invalidate(for: feedURL, profile: accessProfile)
            } else {
                await PodcastHTTPValidatorStore.shared.commit(for: feedURL, profile: accessProfile)
            }
            await reconcileLiveNotifications(for: finalPodcast)
            databaseDuration = databaseStartedAt.duration(to: .now)
            await reportProgress(
                SubscriptionProgressUpdate(1.0, importIsPartial ? "Subscribed — import needs retry" : "Subscription complete"),
                using: progress
            )
            logRefreshResult(importIsPartial ? "partial" : "updated")

            return PodcastUpdateSummary(
                didUpdateFeed: true,
                newEpisodeCount: totalNewEpisodeCount,
                isPartial: importIsPartial
            )
        } catch is CancellationError {
            if silent != true {
                if let cancelledMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef) {
                    cancelledMeta.isUpdating = false
                    cancelledMeta.message = nil
                }
                if let cancelledPodcast: Podcast = modelContext.existingModel(for: podcastIDRef) {
                    cancelledPodcast.message = nil
                }
                modelContext.saveIfNeeded()
            }
            await reportProgress(SubscriptionProgressUpdate(1.0, "Refresh paused"), using: progress)
            logRefreshResult("cancelled")
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            print(
                "Podcast refresh failed for \(feedURL.redactedPodcastURLString):",
                "domain=\(nsError.domain)",
                "code=\(nsError.code)",
                "description=\(Self.safeFeedFailureDescription(error))"
            )
            if let failedMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef) {
                failedMeta.isUpdating = false
                if silent != true {
                    failedMeta.message = nil
                }
                failedMeta.feedUpdateCheckDate = Date()
                failedMeta.feedUpdated = nil
            }
            recordFeedRefreshFailure(metadataID: metaIDRef, error: error)
            if let failedMeta: PodcastMetaData = modelContext.existingModel(for: metaIDRef) {
                failedMeta.lastFeedFailureMessage = "Episode import failed. \(Self.safeFeedFailureDescription(error))"
            }
            if silent != true, let failedPodcast: Podcast = modelContext.existingModel(for: podcastIDRef) {
                failedPodcast.message = nil
            }
            modelContext.saveIfNeeded()
            await PodcastEpisodeImportRetryQueue.shared.enqueue(
                feedURL: feedURL,
                error: error,
                retryAfter: Self.retryAfter(from: error)
            )
            await reportProgress(
                SubscriptionProgressUpdate(1.0, "Refresh failed — \(Self.safeFeedFailureDescription(error))"),
                using: progress
            )
            logRefreshResult("failed error_domain=\(nsError.domain) error_code=\(nsError.code)")
            throw error
        }
    }

    private func reconcileLiveNotifications(for podcast: Podcast) async {
        guard let feed = podcast.feed else { return }
        let descriptor = FetchDescriptor<PodcastSettings>(
            predicate: #Predicate<PodcastSettings> { $0.title == "de.holgerkrupp.podbay.queue" }
        )
        let globalSettings = try? modelContext.fetch(descriptor).first
        let featureEnabled = globalSettings?.showLivePodcasts != false
        await NotificationManager.shared.reconcileLiveNotifications(
            podcastFeed: feed,
            podcastTitle: podcast.title,
            liveItems: podcast.liveItems,
            featureEnabled: featureEnabled
        )
    }
    
    func updateDetails(
        _ podcast: Podcast,
        fullPodcast: [String : Any],
        silent: Bool? = false,
        resolveExistingMissingDurations: Bool = true,
        processNewEpisodesDuringSilentRefresh: Bool = false,
        deadline: Date? = nil,
        progress: SubscriptionProgressHandler? = nil,
        writerAlreadyHeld: Bool = false,
        updateCache: Bool = true
    ) async throws -> Int {
        let commitCoordinator = PodcastFeedCommitCoordinator.shared
        if writerAlreadyHeld == false {
            let writerWaitStartedAt = ContinuousClock.now
            try await commitCoordinator.acquire()
            let writerWait = writerWaitStartedAt.duration(to: .now)
            os_signpost(
                .event,
                log: Self.refreshSignpostLog,
                name: "Podcast feed writer acquired",
                "wait_ms=%{public}lld",
                Self.milliseconds(writerWait)
            )
        }
        defer {
            if writerAlreadyHeld == false {
                Task { await commitCoordinator.release() }
            }
        }
        try Task.checkCancellation()
        try checkRefreshDeadline(deadline)
        let detailsSignpostID = OSSignpostID(log: Self.refreshSignpostLog)
        os_signpost(.begin, log: Self.refreshSignpostLog, name: "Podcast updateDetails", signpostID: detailsSignpostID)
        defer {
            os_signpost(.end, log: Self.refreshSignpostLog, name: "Podcast updateDetails", signpostID: detailsSignpostID)
        }
        print("updateDetails for \(podcast.title)")
        var newEpisodeCount = 0

        podcast.title = fullPodcast["title"] as? String ?? ""
        podcast.author = fullPodcast["itunes:author"] as? String
        podcast.desc = fullPodcast["description"] as? String
        podcast.copyright = fullPodcast["copyright"] as? String
        podcast.language = fullPodcast["language"] as? String
        podcast.link = URL(string: fullPodcast["link"] as? String ?? "")
        if let imageURL = fullPodcast["coverImage"] as? String {
            podcast.imageURL = URL(string: imageURL)
        }
        podcast.lastBuildDate = Date.dateFromRFC1123(
            dateString: fullPodcast["lastBuildDate"] as? String ?? ""
        )

        if silent != true {
            podcast.metaData?.message = "Updating Podcast details"
            podcast.message = "Updating Podcast details"
        }

        if let fundingArr = fullPodcast["funding"] as? [[String: String]] {
            podcast.funding = fundingArr.compactMap { dict in
                guard let string = dict["url"], let url = URL(string: string), let label = dict["label"] else { return nil }
                return FundingInfo(url: url, label: label)
            }
        } else if let fundingArr = fullPodcast["funding"] as? [FundingInfo] {
            podcast.funding = fundingArr
        }

        if let socialArr = fullPodcast["socialInteract"] as? [[String: Any]] {
            podcast.social = socialArr.compactMap { dict in
                guard
                    let proto = dict["protocol"] as? String,
                    let uriStr = dict["uri"] as? String,
                    let uri = URL(string: uriStr)
                else { return nil }
                let accountId = dict["accountId"] as? String
                let accountUrlString = dict["accountUrl"] as? String
                let accountURL = accountUrlString.flatMap(URL.init(string:))
                let priority = dict["priority"] as? Int
                return SocialInfo(url: uri, socialprotocol: proto, accountId: accountId, accountURL: accountURL, priority: priority)
            }
        } else if let socialArr = fullPodcast["socialInteract"] as? [SocialInfo] {
            podcast.social = socialArr
        }

        if let peopleArr = fullPodcast["people"] as? [[String: Any]] {
            podcast.people = peopleArr.compactMap { dict in
                guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
                let role = dict["role"] as? String
                let href = (dict["href"] as? String).flatMap(URL.init(string:))
                let img = (dict["img"] as? String).flatMap(URL.init(string:))
                return PersonInfo(name: name, role: role, href: href, img: img)
            }
        } else if let peopleArr = fullPodcast["people"] as? [PersonInfo] {
            podcast.people = peopleArr
        }

        if let alternativeFeeds = fullPodcast["alternativeFeeds"] as? [[String: String]] {
            var seen = Set<URL>()
            podcast.alternativeFeeds = alternativeFeeds.compactMap { dict in
                guard
                    let urlString = dict["url"],
                    let url = URL(string: urlString, relativeTo: podcast.feed)?.absoluteURL,
                    seen.insert(url).inserted
                else { return nil }

                return PodcastAlternativeFeed(
                    url: url,
                    title: dict["title"],
                    type: dict["type"]
                )
            }
        } else if let alternativeFeeds = fullPodcast["alternativeFeeds"] as? [PodcastAlternativeFeed] {
            podcast.alternativeFeeds = alternativeFeeds
        } else {
            podcast.alternativeFeeds = []
        }

        if let optionalTags = fullPodcast["optionalTags"] as? PodcastNamespaceOptionalTags,
           optionalTags.isEmpty == false {
            podcast.optionalTags = optionalTags
        } else {
            podcast.optionalTags = nil
        }

        if let episodesData = fullPodcast["episodes"] as? [[String: Any]] {
            if silent != true {
                podcast.metaData?.message = "Updating Podcast Episodes"
                podcast.message = "Updating Podcast Episodes"
            }
            await reportProgress(SubscriptionProgressUpdate(0.7, "Creating database entries"), using: progress)

            let totalEpisodes = max(episodesData.count, 1)
            let progressStep = max(1, episodesData.count / 100)
            let podcastTitle = podcast.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let progressPodcastTitle = podcastTitle.isEmpty ? "podcast" : podcastTitle
            var unsavedSilentEpisodeChanges = 0
            let shouldProcessNewEpisodes = (silent != true || processNewEpisodesDuringSilentRefresh)
                && podcast.metaData?.lastRefresh != nil
                && (podcast.episodes?.isEmpty == false)
            let existingEpisodes = podcast.episodes ?? []
            var existingEpisodesByGUID: [String: Episode] = [:]
            var existingEpisodesByURL: [URL: Episode] = [:]
            for episode in existingEpisodes {
                if let guid = episode.guid, guid.isEmpty == false {
                    existingEpisodesByGUID[guid] = episode
                }
                if let url = episode.url {
                    existingEpisodesByURL[url] = episode
                }
            }

            for (index, episodeData) in episodesData.enumerated() {
                // Once the writer starts a feed graph commit, finish it before
                // yielding. A deadline midway through this array would leave
                // a saved prefix; first-known-episode stopping on the next run
                // could then hide the uncommitted suffix.
                if index == 0 || index % progressStep == 0 || index == episodesData.count - 1 {
                    let episodeProgress = 0.7 + (Double(index) / Double(totalEpisodes)) * 0.25
                    await reportProgress(
                        SubscriptionProgressUpdate(
                            episodeProgress,
                            "Importing episodes for \(progressPodcastTitle) \(index + 1)/\(episodesData.count)"
                        ),
                        using: progress
                    )
                }

                let episodeIdentifier = episodeIdentifier(from: episodeData)
                let candidateEpisodeURL = episodeURL(from: episodeData)

                if let existingEpisode = episodeIdentifier.flatMap({ existingEpisodesByGUID[$0] })
                    ?? candidateEpisodeURL.flatMap({ existingEpisodesByURL[$0] }) {
                    existingEpisode.update(from: episodeData)
                    existingEpisode.refreshFeedExternalFiles(from: episodeData)
                    existingEpisode.refreshOptionalTags(from: episodeData)
                    if let guid = existingEpisode.guid, guid.isEmpty == false {
                        existingEpisodesByGUID[guid] = existingEpisode
                    }
                    if let url = existingEpisode.url {
                        existingEpisodesByURL[url] = existingEpisode
                    }
                    if silent == true {
                        unsavedSilentEpisodeChanges += 1
                    } else if resolveExistingMissingDurations {
                        await fillMissingRemoteMP3DurationIfNeeded(
                            episodeID: existingEpisode.persistentModelID,
                            episodeURL: existingEpisode.url,
                            currentDuration: existingEpisode.duration
                        )
                    }
                    if silent == true, unsavedSilentEpisodeChanges >= 25 {
                        modelContext.saveIfNeeded()
                        unsavedSilentEpisodeChanges = 0
                    }
                    continue
                }

                if let episodeURL = existingEpisodeURL(identifier: episodeIdentifier, episodeURL: candidateEpisodeURL),
                   let feed = podcast.feed {
                    print("reusing existing episode: \(episodeData["title"] as? String ?? "")")
                    await linkEpisodeToPodcast(
                        episodeURL,
                        feed,
                        savesImmediately: silent != true
                    )
                    refreshFeedExternalFiles(
                        for: episodeURL,
                        from: episodeData,
                        savesImmediately: silent != true
                    )
                    if silent == true {
                        unsavedSilentEpisodeChanges += 1
                    } else if let existingEpisode = fetchEpisode(byURL: episodeURL) {
                        if resolveExistingMissingDurations {
                            await fillMissingRemoteMP3DurationIfNeeded(
                                episodeID: existingEpisode.persistentModelID,
                                episodeURL: existingEpisode.url,
                                currentDuration: existingEpisode.duration
                            )
                        }
                        if let guid = existingEpisode.guid, guid.isEmpty == false {
                            existingEpisodesByGUID[guid] = existingEpisode
                        }
                        if let url = existingEpisode.url {
                            existingEpisodesByURL[url] = existingEpisode
                        }
                    }

                    if silent == true, unsavedSilentEpisodeChanges >= 25 {
                        modelContext.saveIfNeeded()
                        unsavedSilentEpisodeChanges = 0
                    }
                    continue
                }

                print("new episode: \(episodeData["title"] as? String ?? "")")
                guard let episode = Episode(from: episodeData, podcast: podcast) else { continue }

                print("newly created")
                modelContext.insert(episode)
                newEpisodeCount += 1
                if let guid = episode.guid, guid.isEmpty == false {
                    existingEpisodesByGUID[guid] = episode
                }
                if let url = episode.url {
                    existingEpisodesByURL[url] = episode
                }
                if shouldProcessNewEpisodes {
                    await fillMissingRemoteMP3DurationIfNeeded(
                        episodeID: episode.persistentModelID,
                        episodeURL: episode.url,
                        currentDuration: episode.duration
                    )
                }

                let episodeActor = EpisodeActor(modelContainer: modelContainer)
                if shouldProcessNewEpisodes {
                    print("NOT SILENT")
                    if episode.publishDate ?? Date() < episode.podcast?.metaData?.subscriptionDate ?? Date(timeIntervalSinceNow: -60 * 60 * 24 * 7) {
                        print("episode is old")
                        suppressFromInbox(episode, reason: .backCatalogImport)
                        modelContext.saveIfNeeded()
                    } else {
                        print("episode is new")
                        if let episodeURL = episode.url {
                            modelContext.saveIfNeeded()
                            await episodeActor.processAfterCreation(episodeURL: episodeURL)
                            // The episode is persisted at this point, so let the
                            // inbox pick it up now instead of when the whole
                            // refresh run finishes.
                            await InboxChangeBroadcaster.notifyInboxDidChange()
                        }
                    }
                } else {
                    print("SILENT")
                    suppressFromInbox(episode, reason: .backCatalogImport)
                    unsavedSilentEpisodeChanges += 1

                    if unsavedSilentEpisodeChanges >= 25 {
                        modelContext.saveIfNeeded()
                        unsavedSilentEpisodeChanges = 0
                    }
                }
            }

            if silent == true, unsavedSilentEpisodeChanges > 0 {
                modelContext.saveIfNeeded()
            }

            await reportProgress(SubscriptionProgressUpdate(0.96, "Finalizing library updates"), using: progress)

            if Task.isCancelled == false,
               deadline.map({ Date() < $0 }) ?? true,
               let podcastFeed = podcast.feed {
                await EpisodeActor(modelContainer: modelContainer).applyAutomaticDownloadPolicy(for: podcastFeed)
            }
        }

        if let podcastFeed = podcast.feed {
            // The cache writer reads a fresh legacy context, so flush first.
            modelContext.saveIfNeeded()
            if updateCache {
                await updateFeedCache(
                    feedURL: podcastFeed,
                    parsedFeed: fullPodcast,
                    deadline: deadline
                )
            }
        }

        return newEpisodeCount
    }

    /// Mirror this feed's feed-derivable data into the local-only cache store
    /// after it has been written to legacy. Phase 3 extends the projection with
    /// chapters, transcripts and device-local download metadata.
    private func updateFeedCache(
        feedURL: URL,
        parsedFeed: [String: Any],
        deadline: Date?
    ) async {
        guard StoreDevelopmentConfiguration.splitStoresEnabled,
              StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            return
        }
        let cacheStartedAt = ContinuousClock.now
        let cacheSignpostID = OSSignpostID(log: Self.refreshSignpostLog)
        os_signpost(.begin, log: Self.refreshSignpostLog, name: "Podcast refresh cache projection", signpostID: cacheSignpostID)
        defer {
            os_signpost(.end, log: Self.refreshSignpostLog, name: "Podcast refresh cache projection", signpostID: cacheSignpostID)
        }
        guard deadline.map({ Date() < $0 }) ?? true else { return }
        await ModelContainerManager.shared.prepareSplitStores()
        guard Task.isCancelled == false,
              deadline.map({ Date() < $0 }) ?? true else {
            return
        }
        guard let cacheContainer = await MainActor.run(body: {
            ModelContainerManager.shared.preparedCacheContainer
        }) else { return }

        // Mirroring the whole feed graph into PodcastCache is only worth its disk
        // writes when the cache is the durable source for the runtime graph. With
        // the on-disk library store authoritative, the mirror would duplicate
        // every episode on every refresh for nothing.
        let projectsFromCache = await MainActor.run {
            ModelContainerManager.shared.runtimeProjectsFromCache
        }
        let projection = projectsFromCache
            ? StoreSplitFeedCacheWriter.projectFeed(
                feedURL: feedURL,
                legacyContainer: modelContainer,
                cacheContainer: cacheContainer,
                deadline: deadline
            )
            : StoreSplitFeedCacheWriter.FeedCacheProjectionResult()
        // Namespaced extension subtrees have no equivalent in the model graph, so
        // they are captured in every mode.
        let extensionCount = StoreSplitFeedCacheWriter.replaceParsedExtensionElements(
            feedURL: feedURL,
            parsedFeed: parsedFeed,
            cacheContainer: cacheContainer
        )
        Self.logRefresh(
            "cache_projection feed=\(feedURL.redactedPodcastURLString) "
                + "completed=\(projection.completed) "
                + "episodes=\(projection.episodesProcessed) "
                + "inserted=\(projection.inserted) "
                + "updated=\(projection.updated) "
                + "unchanged=\(projection.unchanged) "
                + "deleted=\(projection.deleted) "
                + "fetches=\(projection.fetchCount) "
                + "saves=\(projection.saveCount)"
                + " extensions=\(extensionCount)"
                + " duration_ms=\(Self.milliseconds(cacheStartedAt.duration(to: .now)))"
        )
        if projection.completed == false {
            CrashBreadcrumbs.shared.record(
                "feed_cache_projection_deferred",
                details: "reason=not_committed,feed=\(feedURL.redactedPodcastURLString)"
            )
        }
    }

    private func recordFeedAlias(
        from oldURL: URL,
        to newURL: URL,
        reason: FeedAliasReason
    ) async {
        guard StoreDevelopmentConfiguration.splitStoresEnabled,
              StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused == false else {
            return
        }
        await ModelContainerManager.shared.prepareSplitStores()
        guard let cacheContainer = await MainActor.run(body: {
            ModelContainerManager.shared.preparedCacheContainer
        }) else { return }

        StoreSplitFeedCacheWriter.upsertFeedAlias(
            from: oldURL,
            to: newURL,
            reason: reason,
            cacheContainer: cacheContainer
        )
    }
    
    func createPodcast(
        from url: URL,
        progress: SubscriptionProgressHandler? = nil
    ) async throws -> PersistentIdentifier {
        await reportProgress(SubscriptionProgressUpdate(0.02, "Resolving podcast feed"), using: progress)
        let resolvedFeed: PodcastFeed
        switch try await PodcastFeedResolver.resolve(url: url, allowAuthenticationPrompt: false) {
        case .podcast(let feed): resolvedFeed = feed
        case .requiresBasicAuth, .requiresBearerToken:
            throw PodcastFeedResolverError.authenticationRequired(url)
        }
        if url.user != nil || url.password != nil {
            let basic = url.podcastBasicCredential
            resolvedFeed.accessCredential = .httpBasic(username: basic.username, password: basic.password)
            resolvedFeed.accessKind = .httpBasic
        } else if url.isLikelyPrivatePodcastURL {
            resolvedFeed.accessCredential = .privateURL(url)
            resolvedFeed.accessKind = .privateURL
        }
        return try await SubscriptionManager(modelContainer: modelContainer).addToLibrary(
            resolvedFeed,
            subscribe: true,
            feedWasValidated: true,
            progress: progress
        )
    }
    
    func archiveEpisodes(of podcastID: PersistentIdentifier) async throws {
        // Snapshot URLs in this context before the first suspension. The
        // podcast relationship can be invalidated while the episode actor is
        // archiving a previous item.
        guard let podcast: Podcast = modelContext.existingModel(for: podcastID),
              let feed = podcast.feed else { return }
        let episodeURLs = (try? modelContext.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { $0.podcast?.feed == feed }
        )))?.compactMap(\.url) ?? []

        let episodeActor = EpisodeActor(modelContainer: modelContainer)
        for episodeURL in episodeURLs {
            try Task.checkCancellation()
            await episodeActor.archiveEpisode(episodeURL)
        }
    }
    
    func removeEpisodesFromInbox(episodeURLs: [URL?]) async {
        let episodeActor = EpisodeActor(modelContainer: modelContainer)
        for episodeURL in episodeURLs {
            await episodeActor.removeFromInbox(episodeURL)
        }
    }
    
    func unarchiveEpisode(_ episodeID: PersistentIdentifier) async throws {
        
        guard let episode: Episode = modelContext.existingModel(for: episodeID) else { return }
        episode.metaData?.setArchived(false)

        modelContext.saveIfNeeded()
    }
    
    func deleteEpisode(_ episodeID: PersistentIdentifier) async throws {
        // Read the values needed for file cleanup in one synchronous turn, then
        // reacquire the row after the file operation. No model instance crosses
        // the await boundary.
        guard let episode: Episode = modelContext.existingModel(for: episodeID) else { return }
        let source = episode.source
        let episodeURL = episode.url
        if let episodeURL {
            await Player.shared.prepareForLibraryDeletion(episodeURLs: [episodeURL])
        }
        if source != .sideLoaded {
            await EpisodeActor(modelContainer: modelContainer).deleteFile(episodeURL: episodeURL)
        }
        guard let currentEpisode: Episode = modelContext.existingModel(for: episodeID) else { return }
        modelContext.delete(currentEpisode)
        try modelContext.save()
    }
    
    func deletePodcast(_ podcastID: PersistentIdentifier) async throws {
        guard let feedURL = modelContext.existingModel(for: podcastID)?.feed else { return }

        try await PodcastMutationCoordinator.shared.withExclusive(feedURL: feedURL) {
            try await self.performDeletePodcast(podcastID)
        }
    }

    private func performDeletePodcast(_ podcastID: PersistentIdentifier) async throws {
        guard let podcast: Podcast = modelContext.existingModel(for: podcastID),
              let feedURL = podcast.feed else { return }
        let profile = storedPodcastAccessProfile(for: podcast)

        // Query children directly instead of faulting `podcast.episodes`.
        // The player must release a current episode before this cascade delete
        // can invalidate the SwiftData model it retains.
        let episodeDescriptor = FetchDescriptor<Episode>(
            predicate: #Predicate<Episode> { episode in
                episode.podcast?.persistentModelID == podcastID
            }
        )
        let episodeURLs = Set(try modelContext.fetch(episodeDescriptor).compactMap(\.url))
        await Player.shared.prepareForLibraryDeletion(episodeURLs: episodeURLs)

        guard try deletePodcastRow(podcastID) != nil else { return }
        _ = try await updateSplitSubscription(
            feedURL: feedURL,
            isSubscribed: false,
            accessProfile: profile
        )
        await SubscriptionManifestSync.publishCurrentSubscriptions(
            modelContainer: modelContainer,
            allowEmpty: true
        )
    }

    private func deletePodcastRow(_ podcastID: PersistentIdentifier) throws -> URL? {
        guard let podcast: Podcast = modelContext.existingModel(for: podcastID),
              let feedURL = podcast.feed else { return nil }

        // Drop the feed from the manifest before the cascade delete starts.
        // Removing a podcast walks every episode, chapter and bookmark it owns,
        // and anything that interrupts that work would otherwise leave a
        // manifest that restores the podcast on the next launch.
        SubscriptionManifestSync.forgetFeed(feedURL)
        if let episodeFolder = podcast.directoryURL {
            try? FileManager.default.removeItem(at: episodeFolder)
        }
        modelContext.delete(podcast)
        try modelContext.save()
        return feedURL
    }

    private func updateSplitSubscription(
        feedURL: URL,
        isSubscribed: Bool,
        accessProfile: PodcastAccessProfile? = nil
    ) async throws -> StoreSplitSubscriptionSyncWriter.Result {
        try await PodcastSubscriptionPersistence.setSubscribed(
            feedURL: feedURL,
            isSubscribed: isSubscribed,
            accessProfile: accessProfile
        )
    }
    
    func refreshAllPodcasts(
        progress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async throws {
        let bulkSignpostID = OSSignpostID(log: Self.refreshSignpostLog)
        os_signpost(.begin, log: Self.refreshSignpostLog, name: "Podcast refresh all", signpostID: bulkSignpostID)
        defer {
            os_signpost(.end, log: Self.refreshSignpostLog, name: "Podcast refresh all", signpostID: bulkSignpostID)
        }
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate<Podcast> { podcast in
                podcast.metaData?.isSubscribed != false
            }
        )

        let podcasts = try modelContext.fetch(descriptor)
        let feeds = podcasts.compactMap(\.feed)
        let maxConcurrent = Self.maximumConcurrentRefreshes
        let refreshStartedAt = ContinuousClock.now
        let runStartedAt = Date()
        let refreshRunID = UUID()
        await progress?(0, feeds.count)
        guard feeds.isEmpty == false else { return }

#if DEBUG
        var checkedPodcasts: [RefreshHistoryPodcastCheck] = []
#endif

        let failed = await withTaskGroup(
            of: (success: Bool, didUpdate: Bool, title: String, feed: URL, newEpisodeCount: Int, errorMessage: String?).self,
            returning: Int.self
        ) { group in
            var nextIndex = 0
            var completed = 0
            var failed = 0

            func enqueueNext() {
                guard nextIndex < feeds.count else { return }
                let feed = feeds[nextIndex]
                nextIndex += 1
                group.addTask {
                    let worker = PodcastModelActor(modelContainer: self.modelContainer)
                    do {
                        let summary = try await worker.updatePodcastWithSummary(
                            feed,
                            policy: .manualBulk,
                            refreshRunID: refreshRunID,
                            resolveExistingMissingDurations: false
                        )
                        let title = await worker.fetchPodcastTitle(byFeed: feed)
                        return (
                            true,
                            summary.didUpdateFeed,
                            title ?? feed.absoluteString,
                            feed,
                            summary.newEpisodeCount,
                            nil
                        )
                    } catch {
                        let title = await worker.fetchPodcastTitle(byFeed: feed)
                        return (
                            false,
                            false,
                            title ?? feed.absoluteString,
                            feed,
                            0,
                            error.localizedDescription
                        )
                    }
                }
            }

            for _ in 0..<min(maxConcurrent, feeds.count) {
                enqueueNext()
            }

            while let result = await group.next() {
                completed += 1
#if DEBUG
                let podcastResult: RefreshHistoryPodcastResult
                if let errorMessage = result.errorMessage {
                    podcastResult = .failed(errorMessage)
                } else if result.didUpdate {
                    podcastResult = .refreshed(newEpisodeCount: result.newEpisodeCount)
                } else {
                    podcastResult = .feedNotUpdated
                }
                checkedPodcasts.append(
                    RefreshHistoryPodcastCheck(
                        title: result.title,
                        feedURL: result.feed,
                        result: podcastResult
                    )
                )
#endif
                if result.success == false {
                    failed += 1
                }
                if result.success, result.newEpisodeCount > 0 {
                    // Surface this feed's episodes while the remaining feeds are
                    // still being fetched.
                    await InboxChangeBroadcaster.notifyInboxDidChange()
                }
                await progress?(completed, feeds.count)
                enqueueNext()
            }

            let totalDuration = refreshStartedAt.duration(to: .now)
            Self.logRefresh(
                "bulk feeds=\(feeds.count) "
                    + "run_id=\(refreshRunID.uuidString) "
                    + "concurrency=\(maxConcurrent) "
                    + "failed=\(failed) "
                    + "total=\(Self.milliseconds(totalDuration))ms"
            )
            return failed
        }

#if DEBUG
        await RefreshHistoryStore.shared.record(
            RefreshHistoryEntry(
                startedAt: runStartedAt,
                finishedAt: Date(),
                trigger: .userInitiatedBulk,
                checkedPodcasts: checkedPodcasts
            )
        )
#endif

        if failed > 0 {
            throw PodcastBulkRefreshError(failedCount: failed, totalCount: feeds.count)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000
            + Int64(components.attoseconds / 1_000_000_000_000_000)
    }
}

actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        permits = value
    }

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            permits += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}
