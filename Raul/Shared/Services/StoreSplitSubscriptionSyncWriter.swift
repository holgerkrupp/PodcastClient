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
        let descriptor = FetchDescriptor<SubscriptionSync>(
            predicate: #Predicate<SubscriptionSync> { $0.id == normalizedFeedURL }
        )
        let deviceID = ListeningDeviceIdentity.current().id

        if let subscription = try? modelContext.fetch(descriptor).first {
            guard date >= subscription.updatedAt else { return }
            subscription.feedURL = normalizedFeedURL
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
}
