import Foundation
import SwiftData
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

struct DownloadedFilesManagerReference: @unchecked Sendable {
    weak var manager: DownloadedFilesManager?
}

enum PodcastDownloadAssociationKey {
    /// Returns an opaque URL used for persisted download/profile associations.
    /// Protected URL credentials are removed before hashing so a token rotation
    /// continues to find the same interrupted download after relaunch.
    static func url(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.podcastNonSecretURL
        }
        if components.fragment?.hasPrefix("upnext-download-") == true {
            return url
        }

        let identityURL = url.isLikelyPrivatePodcastURL ? url.podcastNonSecretURL : url
        let digest = SHA256.hash(data: Data(identityURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        components.user = nil
        components.password = nil
        if url.isLikelyPrivatePodcastURL {
            components.query = nil
        }
        components.fragment = "upnext-download-" + String(digest.prefix(32))
        return components.url ?? identityURL
    }
}

enum PodcastDownloadCompletionPolicy {
    /// Authentication failures are recoverable after re-authentication or a
    /// rotated private-feed credential. Preserve the profile association for
    /// an explicit retry instead of retrying automatically in a loop.
    static func preservesAuthorization(for statusCode: Int?) -> Bool {
        statusCode == 401 || statusCode == 403
    }
}

actor DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    private struct PersistedAuthorization: Codable, Sendable {
        let profileID: String
        let kind: PodcastAccessKind
        let resourceURL: URL
        let providerID: PremiumPodcastProviderID?
        let destination: URL?
    }

    private static let authorizationKey = "downloads.authorization.v1"

    /// Resolve the current production store at request time. The active
    /// Apple TV user can change after this actor has been created.
    private var accessResolver: PodcastAccessResolver {
        PodcastAccessResolver()
    }
    
    private var downloads: [URL: DownloadItem] = [:]
    private var urlToTask: [URL: URLSessionDownloadTask] = [:]
    private var destinations: [URL: URL] = [:]
    private var resumeData: [URL: Data] = [:]
    private var profiles: [URL: PodcastAccessProfile] = [:]
    
    private var downloadedFilesManagerReference: DownloadedFilesManagerReference?

    // MARK: - Inject external manager
    func injectDownloadedFilesManager(_ managerReference: DownloadedFilesManagerReference) {
        downloadedFilesManagerReference = managerReference
    }
    
    // MARK: - Background Session
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.yourapp.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {
        if let data = UserDefaults.standard.data(forKey: Self.authorizationKey),
           let stored = try? JSONDecoder().decode([String: PersistedAuthorization].self, from: data) {
            var restoredProfiles: [URL: PodcastAccessProfile] = [:]
            var restoredDestinations: [URL: URL] = [:]
            for entry in stored {
                guard let url = URL(string: entry.key) else { continue }
                restoredProfiles[url] = PodcastAccessProfile(
                    id: entry.value.profileID,
                    kind: entry.value.kind,
                    resourceURL: entry.value.resourceURL,
                    providerID: entry.value.providerID
                )
                if let destination = entry.value.destination {
                    restoredDestinations[url] = destination
                }
            }
            profiles = restoredProfiles
            destinations = restoredDestinations
        }
    }

    private func makeEpisodeActor() async -> EpisodeActor? {
        guard let container = await ModelContainerManager.shared
            .prepareContainerForExternalEntryPoint() else {
            return nil
        }
        return EpisodeActor(modelContainer: container)
    }

    // MARK: - Public API
    func download(
        from url: URL,
        saveTo destination: URL? = nil,
        profile: PodcastAccessProfile? = nil
    ) async -> DownloadItem? {
        if let existing = downloads[url] {
            return existing
        }

        let resolvedProfile = profile ?? profiles[url] ?? profiles[authorizationKeyURL(for: url)]
        
        let finalDestination = destination
            ?? destinations[url]
            ?? destinations[authorizationKeyURL(for: url)]
            ?? defaultDestination(for: url)
        guard !fileExists(at: finalDestination) else {
            await markDownloaded(for: finalDestination)
            if let episodeActor = await makeEpisodeActor() {
                await episodeActor.markEpisodeAvailable(fileURL: url)
            }
            return nil
        }
        
        let item = await MainActor.run { DownloadItem(url: url) }
        downloads[url] = item
        destinations[url] = finalDestination
        
        let request: URLRequest
        do {
            request = try accessResolver.request(for: url, profile: resolvedProfile)
        } catch {
            downloads[url] = nil
            destinations[url] = nil
            return nil
        }
        if let resolvedProfile {
            profiles[url] = resolvedProfile
            destinations[url] = finalDestination
            persistProfiles()
        }
        let task = session.downloadTask(with: request)
        urlToTask[url] = task
        await MainActor.run { item.isDownloading = true }
        task.resume()
        
        // Notify the view model that a download has started
        await notifyViewModel(for: url)
        
        return item
    }
    func notifyViewModel(for url: URL) async {
        if let item = downloads[url] {
            await MainActor.run {
                item.isDownloading = true
            }
        }
    }
    
    func cancelDownload(for url: URL) {
        urlToTask[url]?.cancel()
        urlToTask[url] = nil
        downloads[url] = nil
        destinations[url] = nil
        resumeData[url] = nil
        profiles[url] = nil
        let authorizationKey = authorizationKeyURL(for: url)
        destinations[authorizationKey] = nil
        profiles[authorizationKey] = nil
        persistProfiles()
    }
    
    func pauseDownload(for url: URL) async {
        guard let task = urlToTask[url] else { return }
        await withCheckedContinuation { continuation in
            task.cancel { data in
                Task {
                    await self.storeResumeData(data, for: url)
                    continuation.resume()
                }
            }
        }
    }
    
    func resumeDownload(for url: URL) {
        let profile = profiles[url] ?? profiles[authorizationKeyURL(for: url)]
        if let profile,
           let request = try? accessResolver.request(for: url, profile: profile) {
            // Resume data contains the old request headers. Rebuild the task
            // with the current Keychain credential after a re-authentication
            // so a rotated token/password is used safely.
            let task = session.downloadTask(with: request)
            urlToTask[url] = task
            task.resume()
        } else if profile != nil {
            // Never fall back to old resume data without rebuilding an
            // authorized request: resume data can contain stale auth headers.
            return
        } else if let data = resumeData[url] {
            let task = session.downloadTask(withResumeData: data)
            urlToTask[url] = task
            task.resume()
            resumeData.removeValue(forKey: url)
        } else {
            // start fresh if no resume data
            Task { _ = await download(from: url) }
        }
    }

    private func persistProfiles() {
        let records = profiles.reduce(into: [String: PersistedAuthorization]()) { result, entry in
            guard let resourceURL = entry.value.resourceURL else { return }
            result[authorizationKeyURL(for: entry.key).absoluteString] = PersistedAuthorization(
                profileID: entry.value.id,
                kind: entry.value.kind,
                resourceURL: resourceURL,
                providerID: entry.value.providerID,
                destination: destinations[entry.key]
            )
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.authorizationKey)
    }
    
    // MARK: - Helpers
    private func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func markDownloaded(for url: URL) async {
        print("markDownloaded: \(url.path)")
        refreshDownloadedFiles()
     //   let episodeActor = await makeEpisodeActor()
     //   await episodeActor.markEpisodeAvailable(fileURL: url)
    }

    private func defaultDestination(for url: URL) -> URL {
        let filename = url.lastPathComponent
        let documents = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent(filename)
    }

    private func authorizationKeyURL(for url: URL) -> URL {
        PodcastDownloadAssociationKey.url(for: url)
    }

    func refreshDownloadedFiles() {
        downloadedFilesManagerReference?.manager?.refreshDownloadedFiles()
    }

    // MARK: - Delegate
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard let url = downloadTask.originalRequest?.url else { return }
        Task {
            if let item = await DownloadManager.shared.getItem(for: url) {
                await MainActor.run {
                    item.update(bytesWritten: totalBytesWritten, totalBytes: totalBytesExpectedToWrite)
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let url = downloadTask.originalRequest?.url else { return }
        print("downloaded \(url.redactedPodcastURLString)")

        let tempCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)

        do {
            try FileManager.default.copyItem(at: location, to: tempCopy)
        } catch {
            return
        }

        
        
        Task {
            

            
            guard let destination = await DownloadManager.shared.getDestination(for: url) else {
                try? FileManager.default.removeItem(at: tempCopy)
                await DownloadManager.shared.cleanUp(url: url)
                return
            }
            var didStoreFile = false
            do {
                let dir = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempCopy, to: destination)
                didStoreFile = true
            } catch {
                didStoreFile = false
            }

            try? FileManager.default.removeItem(at: tempCopy)

            if didStoreFile {
                if let episodeActor = await DownloadManager.shared.makeEpisodeActor() {
                    await episodeActor.markEpisodeAvailable(fileURL: url)
                }
            }
            
            
            if let item = await DownloadManager.shared.getItem(for: url) {
                print("item received")
                await MainActor.run {
                    item.isDownloading = false
                    item.isFinished = didStoreFile
                }
            }
            await markDownloaded(for: destination)

            await MainActor.run {
                NotificationCenter.default.post(
                    name: .episodeDownloadFinished,
                    object: nil,
                    userInfo: [EpisodeDownloadNotificationKey.episodeURL: url]
                )
            }
            await DownloadManager.shared.cleanUp(url: url)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let url = task.originalRequest?.url else { return }
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode

        Task {
            await DownloadManager.shared.handleCompletion(
                for: url,
                statusCode: statusCode,
                error: error
            )
        }
    }

    private func handleCompletion(
        for url: URL,
        statusCode: Int?,
        error: (any Error)?
    ) async {
        if PodcastDownloadCompletionPolicy.preservesAuthorization(for: statusCode) {
            urlToTask[url] = nil
            if let item = downloads[url] {
                await MainActor.run {
                    item.isDownloading = false
                    item.isFinished = false
                }
            }
            // Keep profiles and destinations persisted. An explicit
            // resumeDownload(for:) will resolve the current credential and
            // rebuild the request rather than reuse stale resume headers.
            persistProfiles()
            print("Protected download paused for re-authentication: \(url.redactedPodcastURLString)")
            return
        }

        if let item = downloads[url] {
            await MainActor.run {
                item.isDownloading = false
                item.isFinished = false
            }
        }
        await cleanUp(url: url)
        if let error {
            print("Download failed for \(url.redactedPodcastURLString): \(error.localizedDescription)")
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
#if canImport(UIKit)
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
               let completionHandler = appDelegate.backgroundSessionCompletionHandler {
                appDelegate.backgroundSessionCompletionHandler = nil
                completionHandler()
            }
#endif
        }
    }

    // MARK: - Internal lookups
    func getItem(for url: URL) -> DownloadItem? { downloads[url] }
    private func getDestination(for url: URL) -> URL? {
        destinations[url] ?? destinations[authorizationKeyURL(for: url)]
    }

    private func cleanUp(url: URL) async {
        downloads.removeValue(forKey: url)
        urlToTask.removeValue(forKey: url)
        destinations.removeValue(forKey: url)
        resumeData.removeValue(forKey: url)
        profiles.removeValue(forKey: url)
        profiles.removeValue(forKey: authorizationKeyURL(for: url))
        persistProfiles()
    }

    private func storeResumeData(_ data: Data?, for url: URL) {
        if let data { resumeData[url] = data }
        urlToTask[url] = nil
    }
}
