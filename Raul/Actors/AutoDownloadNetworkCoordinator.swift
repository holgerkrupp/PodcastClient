import Foundation
import Network
import SwiftData
import BasicLogger

actor AutoDownloadNetworkCoordinator {
    static let shared = AutoDownloadNetworkCoordinator()

    private let monitorQueue = DispatchQueue(label: "AutoDownloadNetworkCoordinator")
    private var monitor: NWPathMonitor?
    private var modelContainer: ModelContainer?
    private var lastCanScheduleWiFiOnlyDownloads: Bool?

    private func logAutoDownload(_ message: String) async {
        await MainActor.run {
            BasicLogger.shared.log("[AutoDL] \(message)")
        }
    }

    func startMonitoringIfNeeded(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer

        guard monitor == nil else {
            return
        }

        Task {
            await logAutoDownload("network-monitor/start")
        }

        let monitor = NWPathMonitor()
        self.monitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            let isConnected = path.status == .satisfied
            let isWiFiLikeConnection = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            let canScheduleWiFiOnlyDownloads = isConnected && isWiFiLikeConnection

            Task {
                await self?.logAutoDownload(
                    "network-monitor/update connected=\(isConnected) wifiLike=\(isWiFiLikeConnection) canScheduleWiFiOnly=\(canScheduleWiFiOnlyDownloads)"
                )
                await self?.handleNetworkUpdate(canScheduleWiFiOnlyDownloads: canScheduleWiFiOnlyDownloads)
            }
        }

        monitor.start(queue: monitorQueue)
    }

    private func handleNetworkUpdate(canScheduleWiFiOnlyDownloads: Bool) async {
        defer {
            lastCanScheduleWiFiOnlyDownloads = canScheduleWiFiOnlyDownloads
        }

        guard canScheduleWiFiOnlyDownloads else {
            await logAutoDownload("network-monitor/skip reason=wifi-not-available")
            return
        }

        guard lastCanScheduleWiFiOnlyDownloads != true else {
            await logAutoDownload("network-monitor/skip reason=no-transition-to-wifi")
            return
        }

        await logAutoDownload("network-monitor/resume-waiting-downloads")
        await resumeWaitingAutoDownloads()
    }

    private func resumeWaitingAutoDownloads() async {
        guard let modelContainer else {
            await logAutoDownload("network-monitor/skip reason=no-model-container")
            return
        }

        let settingsActor = PodcastSettingsModelActor(modelContainer: modelContainer)
        let podcastFeeds = await settingsActor.podcastFeedsRequiringAutoDownloadReconciliationOnWiFi()
        guard podcastFeeds.isEmpty == false else {
            await logAutoDownload("network-monitor/skip reason=no-wifi-only-podcasts")
            return
        }

        await logAutoDownload("network-monitor/apply count=\(podcastFeeds.count)")

        let episodeActor = EpisodeActor(modelContainer: modelContainer)
        for podcastFeed in podcastFeeds {
            await logAutoDownload("network-monitor/apply feed=\(podcastFeed.absoluteString)")
            await episodeActor.applyAutomaticDownloadPolicy(for: podcastFeed)
        }
    }
}
