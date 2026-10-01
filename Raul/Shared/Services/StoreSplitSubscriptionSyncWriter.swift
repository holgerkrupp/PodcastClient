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
    func setSubscribed(
        feedURL: URL,
        isSubscribed: Bool,
        accessProfile: PodcastAccessProfile? = nil,
        at date: Date = .now
    ) {
        let normalizedFeedURL = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        let profile = accessProfile ?? Self.legacyAccessProfile(for: feedURL)
        if accessProfile == nil, let profile {
            try? Self.saveCredential(for: feedURL, profile: profile)
        }
        let descriptor = FetchDescriptor<SubscriptionSync>(
            predicate: #Predicate<SubscriptionSync> { $0.id == normalizedFeedURL }
        )
        let deviceID = ListeningDeviceIdentity.current().id

        if let subscription = try? modelContext.fetch(descriptor).first {
            guard date >= subscription.updatedAt else { return }
            subscription.feedURL = normalizedFeedURL
            subscription.accessProfileID = profile?.id
            subscription.accessKindRawValue = profile?.kind.rawValue
            subscription.accessProviderID = profile?.providerID?.rawValue
            subscription.isSubscribed = isSubscribed
            subscription.unsubscribedAt = isSubscribed ? nil : date
            if isSubscribed {
                subscription.subscribedAt = date
            }
            subscription.updatedAt = date
            subscription.sourceDeviceID = deviceID
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
        }

        modelContext.saveIfNeeded()
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
