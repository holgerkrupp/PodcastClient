import Foundation
import SwiftData

@ModelActor
actor StoreSplitSubscriptionSyncWriter {
    func setSubscribed(
        feedURL: URL,
        isSubscribed: Bool,
        at date: Date = .now
    ) {
        let normalizedFeedURL = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        let accessProfile = Self.accessProfile(for: feedURL)
        if let accessProfile {
            try? Self.saveCredential(for: feedURL, profile: accessProfile)
        }
        let descriptor = FetchDescriptor<SubscriptionSync>(
            predicate: #Predicate<SubscriptionSync> { $0.id == normalizedFeedURL }
        )
        let deviceID = ListeningDeviceIdentity.current().id

        if let subscription = try? modelContext.fetch(descriptor).first {
            guard date >= subscription.updatedAt else { return }
            subscription.feedURL = normalizedFeedURL
            subscription.accessProfileID = accessProfile?.id
            subscription.accessKindRawValue = accessProfile?.kind.rawValue
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
                    accessProfileID: accessProfile?.id,
                    accessKindRawValue: accessProfile?.kind.rawValue,
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

    private static func accessProfile(for feedURL: URL) -> PodcastAccessProfile? {
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
            credential = .httpBasic(
                username: feedURL.user ?? "",
                password: feedURL.password ?? ""
            )
        case .publicFeed, .bearerToken:
            return
        }
        try KeychainPodcastCredentialStore.shared.save(credential, for: profile)
    }
}
