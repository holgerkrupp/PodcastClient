import Foundation
import SwiftData

/// Device-local retry records contain only a sanitized feed URL, never private
/// query tokens or authorization headers. The subscription remains authoritative
/// in UserState; this queue only records unfinished, rebuildable episode imports.
actor PodcastEpisodeImportRetryQueue {
    static let shared = PodcastEpisodeImportRetryQueue()
    private static let maximumAttempts = 12

    private struct Job: Codable, Identifiable {
        var id: String
        var feedURL: String
        var attempts: Int
        var nextAttemptAt: Date
        var authenticationRequired: Bool
        var resumeURL: String?
    }

    private var jobs: [String: Job] = [:]
    private var didLoad = false
    private var isProcessing = false
    private var modelContainer: ModelContainer?
    private var scheduledRetryTask: Task<Void, Never>?
    private var scheduledRetryDate: Date?

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PodcastEpisodeImportRetries.json", isDirectory: false)
    }

    func enqueue(
        feedURL: URL,
        error: Error? = nil,
        retryAfter: Date? = nil,
        resumeURL: URL? = nil
    ) async {
        await loadIfNeeded()
        let outcome = Self.disposition(for: error)
        let key = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        guard outcome != .permanent, outcome != .cancelled else {
            jobs[key] = nil
            await save()
            return
        }

        let sanitizedURL = feedURL.podcastNonSecretURL
        let previous = jobs[key]
        if (previous?.attempts ?? 0) >= Self.maximumAttempts, outcome != .authentication {
            jobs[key] = nil
            await save()
            CrashBreadcrumbs.shared.record("podcast_episode_import_retry_exhausted")
            return
        }
        let attempts = min((previous?.attempts ?? 0) + 1, 12)
        let pausedForAuthentication = outcome == .authentication
        let baseDelay = Self.backoffSeconds(attempt: attempts)
        let jitter = Double.random(in: 0...(baseDelay * 0.25))
        let exponentialDate = Date().addingTimeInterval(baseDelay + jitter)
        let nextAttempt = pausedForAuthentication
            ? .distantFuture
            : max(exponentialDate, retryAfter ?? .distantPast)
        jobs[key] = Job(
            id: key,
            feedURL: sanitizedURL.absoluteString,
            attempts: attempts,
            nextAttemptAt: nextAttempt,
            authenticationRequired: pausedForAuthentication,
            resumeURL: resumeURL?.podcastNonSecretURL.absoluteString ?? previous?.resumeURL
        )
        await save()
        scheduleNextAttempt()
        CrashBreadcrumbs.shared.record(
            "podcast_episode_import_retry_scheduled",
            details: "attempt=\(attempts) auth_required=\(pausedForAuthentication)"
        )
    }

    func remove(feedURL: URL) async {
        await loadIfNeeded()
        jobs[PodcastFeedIdentity.normalizedFeedURLString(feedURL)] = nil
        await save()
        scheduleNextAttempt()
    }

    func checkpoint(feedURL: URL, resumeURL: URL) async {
        await loadIfNeeded()
        let key = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        let previous = jobs[key]
        jobs[key] = Job(
            id: key,
            feedURL: feedURL.podcastNonSecretURL.absoluteString,
            attempts: previous?.attempts ?? 0,
            nextAttemptAt: previous?.nextAttemptAt ?? Date().addingTimeInterval(Self.backoffSeconds(attempt: 1)),
            authenticationRequired: previous?.authenticationRequired ?? false,
            resumeURL: resumeURL.podcastNonSecretURL.absoluteString
        )
        await save()
        scheduleNextAttempt()
    }

    func removeAll() async {
        await loadIfNeeded()
        jobs.removeAll()
        await save()
        scheduledRetryTask?.cancel()
        scheduledRetryTask = nil
        scheduledRetryDate = nil
    }

    func retryNow(feedURL: URL, modelContainer: ModelContainer) async {
        await loadIfNeeded()
        let key = PodcastFeedIdentity.normalizedFeedURLString(feedURL)
        if var job = jobs[key] {
            job.nextAttemptAt = .distantPast
            job.authenticationRequired = false
            jobs[key] = job
            await save()
        } else {
            await enqueue(feedURL: feedURL)
        }
        await processDue(modelContainer: modelContainer, force: true)
    }

    func processDue(modelContainer: ModelContainer, force: Bool = false) async {
        await loadIfNeeded()
        self.modelContainer = modelContainer
        guard isProcessing == false else { return }
        isProcessing = true
        defer { isProcessing = false }

        let now = Date()
        let ready = jobs.values
            .filter { force || (!$0.authenticationRequired && $0.nextAttemptAt <= now) }
            .sorted { $0.nextAttemptAt < $1.nextAttemptAt }

        for job in ready {
            guard let feedURL = URL(string: job.feedURL) else {
                jobs[job.id] = nil
                continue
            }
            do {
                let summary = try await PodcastMutationCoordinator.shared.withExclusive(feedURL: feedURL) {
                    try await PodcastModelActor(modelContainer: modelContainer)
                        .updatePodcastWithSummary(
                            feedURL,
                            force: true,
                            silent: true,
                            startingAt: job.resumeURL.flatMap(URL.init(string:))
                        )
                }
                if summary.isPartial == false {
                    jobs[job.id] = nil
                }
            } catch is CancellationError {
                continue
            } catch {
                // updatePodcastWithSummary classifies and persists its failure.
                // Keep the record as-is if it was not classifiable here.
                if Self.disposition(for: error) == .permanent {
                    jobs[job.id] = nil
                }
            }
            await save()
        }
        scheduleNextAttempt()
    }

    static func disposition(for error: Error?) -> RetryDisposition {
        guard let error else { return .retryable }
        if error is CancellationError { return .cancelled }
        let statusCode: Int?
        if case PodcastParserError.couldNotLoad(_, let code, _) = error {
            statusCode = code
        } else if case PodcastFeedResolverError.httpStatus(_, let code, _) = error {
            statusCode = code
        } else {
            statusCode = nil
        }
        if let statusCode {
            switch statusCode {
            case 401, 403: return .authentication
            case 0, 408, 425, 429, 500...599: return .retryable
            case 400...499: return .permanent
            default: return .retryable
            }
        }
        if case PodcastFeedResolverError.authenticationRequired = error { return .authentication }
        if case PodcastFeedResolverError.bearerAuthenticationRequired = error { return .authentication }
        if case PodcastFeedResolverError.notAPodcastFeed = error { return .permanent }
        if case PodcastParserError.notAPodcastFeed = error { return .permanent }
        if case PodcastParserError.xmlParserError = error { return .permanent }
        return .retryable
    }

    static func backoffSeconds(attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 10)
        return min(30 * pow(2, Double(exponent)), 6 * 60 * 60)
    }

    enum RetryDisposition: Equatable {
        case retryable
        case authentication
        case permanent
        case cancelled
    }

    private func loadIfNeeded() async {
        guard didLoad == false else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Job].self, from: data) else { return }
        jobs = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
    }

    private func save() async {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(jobs.values.sorted { $0.id < $1.id })
            try data.write(to: fileURL, options: .atomic)
        } catch {
            CrashBreadcrumbs.shared.record("podcast_episode_import_retry_save_failed", details: "storage=application_support")
        }
    }

    private func scheduleNextAttempt() {
        guard let modelContainer else { return }
        let nextDate = jobs.values
            .filter { !$0.authenticationRequired }
            .map(\.nextAttemptAt)
            .min()
        guard let nextDate else {
            scheduledRetryTask?.cancel()
            scheduledRetryTask = nil
            scheduledRetryDate = nil
            return
        }
        guard scheduledRetryDate.map({ $0 <= nextDate }) != true else { return }

        scheduledRetryTask?.cancel()
        scheduledRetryDate = nextDate
        let delay = max(0, nextDate.timeIntervalSinceNow)
        scheduledRetryTask = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            await self.processDue(modelContainer: modelContainer)
        }
    }
}
