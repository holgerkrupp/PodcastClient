import Foundation

protocol AdSignalProvider: Sendable {
    var source: AdSignalSource { get }
    func observations(for request: AdDetectionRequest) async throws -> [AdDetectionObservation]
}

struct AdDetectionSnapshot: Sendable, Equatable {
    let episodeIdentity: String
    let segments: [AdSegment]
    let updatedAt: Date
}

/// Coordinates signal providers while keeping cancellation and rolling state
/// outside SwiftUI and the playback actor. A disabled engine does no provider
/// work and clears its transient state immediately.
actor AdDetectionEngine {
    private var providers: [any AdSignalProvider]
    private var configuration: AdDetectionConfiguration
    private var currentEpisodeIdentity: String?
    private var observations: [AdDetectionObservation] = []
    private var segments: [AdSegment] = []
    private var generation: UInt64 = 0

    init(
        configuration: AdDetectionConfiguration = .default,
        providers: [any AdSignalProvider] = []
    ) {
        self.configuration = configuration
        self.providers = providers
    }

    func setProviders(_ providers: [any AdSignalProvider]) {
        self.providers = providers
    }

    func setConfiguration(_ configuration: AdDetectionConfiguration) {
        self.configuration = configuration
        if configuration.enabled == false {
            clear()
        }
    }

    func clear() {
        generation &+= 1
        currentEpisodeIdentity = nil
        observations.removeAll(keepingCapacity: false)
        segments.removeAll(keepingCapacity: false)
    }

    func cancelEpisode(_ episodeIdentity: String? = nil) {
        guard episodeIdentity == nil || episodeIdentity == currentEpisodeIdentity else { return }
        generation &+= 1
        currentEpisodeIdentity = nil
        observations.removeAll(keepingCapacity: false)
        segments.removeAll(keepingCapacity: false)
    }

    func detect(for request: AdDetectionRequest) async throws -> AdDetectionSnapshot {
        guard configuration.enabled, request.configuration.enabled else {
            clear()
            return AdDetectionSnapshot(episodeIdentity: request.episodeIdentity, segments: [], updatedAt: Date())
        }

        generation &+= 1
        let requestGeneration = generation
        currentEpisodeIdentity = request.episodeIdentity
        observations.removeAll(keepingCapacity: true)
        segments.removeAll(keepingCapacity: true)

        let providerList = providers
        var newObservations: [AdDetectionObservation] = []
        try await withThrowingTaskGroup(of: [AdDetectionObservation].self) { group in
            for provider in providerList {
                group.addTask {
                    try Task.checkCancellation()
                    return try await provider.observations(for: request)
                }
            }

            for try await providerObservations in group {
                try Task.checkCancellation()
                guard requestGeneration == generation else { throw CancellationError() }
                newObservations.append(contentsOf: providerObservations)
            }
        }

        guard requestGeneration == generation else { throw CancellationError() }
        observations = newObservations
        segments = AdDetectionFusion.merge(
            observations: newObservations,
            episodeIdentity: request.episodeIdentity,
            thresholds: request.configuration.thresholds
        )
        return snapshot()
    }

    func ingest(_ newObservations: [AdDetectionObservation], episodeIdentity: String) -> AdDetectionSnapshot {
        guard configuration.enabled else {
            clear()
            return AdDetectionSnapshot(episodeIdentity: episodeIdentity, segments: [], updatedAt: Date())
        }

        if currentEpisodeIdentity != episodeIdentity {
            currentEpisodeIdentity = episodeIdentity
            observations.removeAll(keepingCapacity: true)
        }
        observations.append(contentsOf: newObservations)
        // Keep rolling memory bounded while retaining enough context to refine
        // a provisional start as the end of an ad becomes known.
        if observations.count > 512 {
            observations.removeFirst(observations.count - 512)
        }
        segments = AdDetectionFusion.merge(
            observations: observations,
            episodeIdentity: episodeIdentity,
            thresholds: configuration.thresholds
        )
        return snapshot()
    }

    func snapshot() -> AdDetectionSnapshot {
        AdDetectionSnapshot(
            episodeIdentity: currentEpisodeIdentity ?? "",
            segments: segments,
            updatedAt: Date()
        )
    }
}

