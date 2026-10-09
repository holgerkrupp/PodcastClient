import Foundation
import SwiftData

/// Shared entry point for subscription writes from both model actors and
/// feed-discovery routes. The split store is prepared before an outcome is
/// reported so callers never mistake a manifest-only write for a commit.
enum PodcastSubscriptionPersistence {
    static func isSubscribed(
        feedURL: URL,
        legacyContainer: ModelContainer
    ) async -> Bool {
        await ModelContainerManager.shared.prepareSplitStores()
        if let userStateContainer = await MainActor.run(body: {
            ModelContainerManager.shared.preparedUserStateContainer
        }) {
            let context = ModelContext(userStateContainer)
            var newestRecord: SubscriptionSync?
            for key in feedURL.podcastFeedComparisonKeys {
                let descriptor = FetchDescriptor<SubscriptionSync>(
                    predicate: #Predicate<SubscriptionSync> { $0.id == key }
                )
                if let record = try? context.fetch(descriptor).first,
                   newestRecord.map({ $0.updatedAt < record.updatedAt }) ?? true {
                    newestRecord = record
                }
            }
            if let newestRecord {
                return newestRecord.isSubscribed && newestRecord.unsubscribedAt == nil
            }
        }

        let legacyContext = ModelContext(legacyContainer)
        let requestedKeys = feedURL.podcastFeedComparisonKeys
        for key in requestedKeys {
            guard let candidate = URL(string: key) else { continue }
            let descriptor = FetchDescriptor<Podcast>(
                predicate: #Predicate<Podcast> { $0.feed == candidate }
            )
            if let podcast = try? legacyContext.fetch(descriptor).first,
               podcast.isSubscribed {
                return true
            }
        }
        return false
    }

    static func setSubscribed(
        feedURL: URL,
        isSubscribed: Bool,
        accessProfile: PodcastAccessProfile? = nil
    ) async throws -> StoreSplitSubscriptionSyncWriter.Result {
        await ModelContainerManager.shared.prepareSplitStores()
        guard let userStateContainer = await MainActor.run(body: {
            ModelContainerManager.shared.preparedUserStateContainer
        }) else {
            CrashBreadcrumbs.shared.record(
                "store_split_subscription_write_deferred",
                details: PodcastFeedIdentity.normalizedFeedURLString(feedURL)
            )
            throw PodcastSubscriptionMutationError.authoritativeStoreUnavailable
        }

        return try await StoreSplitSubscriptionSyncWriter(
            modelContainer: userStateContainer
        ).setSubscribed(
            feedURL: feedURL,
            isSubscribed: isSubscribed,
            accessProfile: accessProfile
        )
    }
}

func storedPodcastAccessProfile(for podcast: Podcast) -> PodcastAccessProfile? {
    guard let metadata = podcast.metaData,
          let profileID = metadata.accessProfileID,
          let rawKind = metadata.accessKindRawValue,
          let kind = PodcastAccessKind(rawValue: rawKind),
          let feedURL = podcast.feed else {
        return nil
    }
    return PodcastAccessProfile(
        id: profileID,
        kind: kind,
        resourceURL: feedURL,
        providerID: metadata.accessProviderID.flatMap(PremiumPodcastProviderID.init(rawValue:))
    )
}

@ModelActor
actor StoreSplitSubscriptionSyncWriter {
    enum WriteError: LocalizedError {
        case fetchFailed(Error)
        case saveFailed(Error)

        var errorDescription: String? {
            switch self {
            case .fetchFailed:
                return "The subscription could not be read from local sync storage."
            case .saveFailed:
                return "The subscription could not be saved locally."
            }
        }
    }

    struct Result: Sendable {
        let feedKey: String
        let isSubscribed: Bool
        let didChange: Bool
        let committedAt: Date
    }

    func setSubscribed(
        feedURL: URL,
        isSubscribed: Bool,
        accessProfile: PodcastAccessProfile? = nil,
        at date: Date = .now
    ) throws -> Result {
        let normalizedFeedURL = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        let profile = accessProfile ?? Self.legacyAccessProfile(for: feedURL)
        if accessProfile == nil, let profile {
            try? Self.saveCredential(for: feedURL, profile: profile)
        }
        let descriptor = FetchDescriptor<SubscriptionSync>(
            predicate: #Predicate<SubscriptionSync> { $0.id == normalizedFeedURL }
        )
        let deviceID = ListeningDeviceIdentity.current().id

        let existingSubscription: SubscriptionSync?
        do {
            existingSubscription = try modelContext.fetch(descriptor).first
        } catch {
            throw WriteError.fetchFailed(error)
        }

        if let subscription = existingSubscription {
            guard date >= subscription.updatedAt else {
                return Result(
                    feedKey: normalizedFeedURL,
                    isSubscribed: subscription.isSubscribed,
                    didChange: false,
                    committedAt: subscription.updatedAt
                )
            }
            let stateIsConsistent = isSubscribed
                ? subscription.unsubscribedAt == nil
                : subscription.unsubscribedAt != nil
            if subscription.isSubscribed == isSubscribed, stateIsConsistent {
                return Result(
                    feedKey: normalizedFeedURL,
                    isSubscribed: subscription.isSubscribed,
                    didChange: false,
                    committedAt: subscription.updatedAt
                )
            }
            let didChange = subscription.isSubscribed != isSubscribed
            subscription.feedURL = normalizedFeedURL
            subscription.accessProfileID = profile?.id
            subscription.accessKindRawValue = profile?.kind.rawValue
            subscription.accessProviderID = profile?.providerID?.rawValue
            subscription.isSubscribed = isSubscribed
            subscription.unsubscribedAt = isSubscribed ? nil : date
            if isSubscribed {
                if didChange {
                    subscription.subscribedAt = date
                }
            }
            subscription.updatedAt = date
            subscription.sourceDeviceID = deviceID
            do {
                try modelContext.save()
            } catch {
                throw WriteError.saveFailed(error)
            }
            return Result(
                feedKey: normalizedFeedURL,
                isSubscribed: isSubscribed,
                didChange: didChange,
                committedAt: date
            )
        } else {
            modelContext.insert(
                SubscriptionSync(
                    feedURL: normalizedFeedURL,
                    accessProfileID: profile?.id,
                    accessKindRawValue: profile?.kind.rawValue,
                    accessProviderID: profile?.providerID?.rawValue,
                    isSubscribed: isSubscribed,
                    subscribedAt: isSubscribed ? date : .distantPast,
                    unsubscribedAt: isSubscribed ? nil : date,
                    updatedAt: date,
                    sourceDeviceID: deviceID
                )
            )
            do {
                try modelContext.save()
            } catch {
                throw WriteError.saveFailed(error)
            }
            return Result(
                feedKey: normalizedFeedURL,
                isSubscribed: isSubscribed,
                didChange: true,
                committedAt: date
            )
        }
    }

    private static func legacyAccessProfile(for feedURL: URL) -> PodcastAccessProfile? {
        guard feedURL.isLikelyPrivatePodcastURL else { return nil }
        let kind: PodcastAccessKind = feedURL.user != nil || feedURL.password != nil
            ? .httpBasic
            : .privateURL
        return PodcastAccessProfile.make(for: feedURL, kind: kind)
    }

    private static func saveCredential(
        for feedURL: URL,
        profile: PodcastAccessProfile
    ) throws {
        let credential: PodcastCredential
        switch profile.kind {
        case .privateURL:
            credential = .privateURL(feedURL)
        case .httpBasic:
            let basicCredential = feedURL.podcastBasicCredential
            credential = .httpBasic(
                username: basicCredential.username,
                password: basicCredential.password
            )
        case .publicFeed, .bearerToken:
            return
        }
        try PodcastCredentialStoreProvider.current.save(credential, for: profile)
    }
}
