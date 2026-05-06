import Foundation
import SwiftData

@Model
final class ListeningStat: Identifiable {
    var id: UUID?
    var startOfHour: Date?
    var podcastFeed: URL?
    var podcastName: String?
    var totalSeconds: Double?

    init(
        id: UUID? = nil,
        startOfHour: Date? = nil,
        podcastFeed: URL? = nil,
        podcastName: String? = nil,
        totalSeconds: Double? = nil
    ) {
        self.id = id
        self.startOfHour = startOfHour
        self.podcastFeed = podcastFeed
        self.podcastName = podcastName
        self.totalSeconds = totalSeconds
    }
}
