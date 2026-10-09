import Foundation
import SwiftData

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
