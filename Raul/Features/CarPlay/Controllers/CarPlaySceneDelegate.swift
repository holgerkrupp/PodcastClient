#if os(iOS)
import CarPlay
import SwiftData
import UIKit
import os

@MainActor
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UpNext", category: "CarPlayScene")
    var interfaceController: CPInterfaceController?
    var playNext: CarPlayPlayNext?
    var nowPlaying: CarPlayNowPlaying?
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let icon = UIApplication.shared.alternateIconName ?? "primary"
        logger.info("CarPlay connected; scene=UpNext template=queue artwork=\(CarPlayArtworkSettings.showArtwork ? "enabled" : "text-only", privacy: .public) app=\(version, privacy: .public)(\(build, privacy: .public)) iOS=\(UIDevice.current.systemVersion, privacy: .public) icon=\(icon, privacy: .public)")
        connectionTask?.cancel()
        playNext?.invalidate()
        nowPlaying?.invalidate()
        playNext = nil
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let connectedAt = ContinuousClock.now
        self.interfaceController = interfaceController
        CarPlayDiagnostics.recordTransition("carplay_connected")

        // Now Playing needs only the player, so the controls work while a slow
        // library load is still running.
        let nowPlaying = CarPlayNowPlaying(interfaceController: interfaceController)
        self.nowPlaying = nowPlaying

        let loadingTemplate = CPListTemplate(title: "Up Next", sections: [])
        loadingTemplate.emptyViewTitleVariants = ["Loading"]
        if Player.shared.currentEpisode != nil {
            let nowPlayingItem = CPListItem(text: String(localized: "Now Playing"), detailText: nil)
            nowPlayingItem.handler = { _, completion in
                completion()
                interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            }
            loadingTemplate.updateSections([CPListSection(items: [nowPlayingItem])])
        }
        interfaceController.setRootTemplate(loadingTemplate, animated: false) { @Sendable success, error in
            CarPlayDiagnostics.logger.info("Loading template set; success=\(success, privacy: .public) failed=\(error != nil, privacy: .public)")
        }

        connectionTask = Task { @MainActor [weak self, weak interfaceController] in
            guard let self, let interfaceController else { return }

            let containerManager = ModelContainerManager.shared
            // Never wait silently: say so in the car and in diagnostics when
            // the library takes long, without giving up on it.
            let slowLoadNotice = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard Task.isCancelled == false else { return }
                loadingTemplate.emptyViewSubtitleVariants = ["Still loading. Playback controls stay available."]
                CarPlayDiagnostics.recordTransition("carplay_container_slow", details: "waitedS=10")
            }
            let prepareStartedAt = ContinuousClock.now
            await containerManager.prepareContainer()
            slowLoadNotice.cancel()
            let prepareMs = CarPlayPlayNext.milliseconds(since: prepareStartedAt)

            guard Task.isCancelled == false,
                  self.connectionGeneration == generation,
                  self.interfaceController === interfaceController else { return }
            guard let container = containerManager.preparedContainer,
                  let playlistActor = try? PlaylistModelActor(modelContainer: container) else {
                CarPlayDiagnostics.recordTransition("carplay_container_failed", details: "prepareMs=\(prepareMs)")
                loadingTemplate.emptyViewTitleVariants = ["Unable to load Up Next"]
                let message = containerManager.initializationError ?? "Open Up Next on iPhone and try again."
                loadingTemplate.emptyViewSubtitleVariants = [message]
                if let nowPlayingItems = loadingTemplate.sections.first?.items, nowPlayingItems.isEmpty == false {
                    let errorItem = CPListItem(text: String(localized: "Unable to load Up Next"), detailText: message)
                    loadingTemplate.updateSections([CPListSection(items: nowPlayingItems + [errorItem])])
                } else {
                    loadingTemplate.updateSections([])
                }
                return
            }

            let playNext = CarPlayPlayNext(playlistActor: playlistActor, interfaceController: interfaceController)
            self.playNext = playNext

            guard Task.isCancelled == false,
                  self.connectionGeneration == generation,
                  self.interfaceController === interfaceController else {
                playNext.invalidate()
                return
            }
            // CarPlay may call this off the main thread.
            interfaceController.setRootTemplate(playNext.template, animated: false) { @Sendable success, error in
                let details = "success=\(success) failed=\(error != nil) prepareMs=\(prepareMs) totalMs=\(CarPlayPlayNext.milliseconds(since: connectedAt))"
                Task { @MainActor in
                    CarPlayDiagnostics.recordTransition("carplay_root_published", details: details)
                }
            }
        }
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        guard self.interfaceController === interfaceController else { return }
        CarPlayDiagnostics.recordTransition("carplay_disconnected")
        connectionGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        playNext?.invalidate()
        nowPlaying?.invalidate()
        self.interfaceController = nil
        playNext = nil
        nowPlaying = nil
    }
}
#endif
