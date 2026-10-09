import Foundation
import SwiftData

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
        at date: Date = .now
    ) throws -> Result {
        let normalizedFeedURL = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
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
}
