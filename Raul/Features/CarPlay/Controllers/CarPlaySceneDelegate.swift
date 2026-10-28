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
        connectionGeneration &+= 1
        let generation = connectionGeneration
        self.interfaceController = interfaceController

        let loadingTemplate = CPListTemplate(title: "Up Next", sections: [])
        loadingTemplate.emptyViewTitleVariants = ["Loading"]
        interfaceController.setRootTemplate(loadingTemplate, animated: false, completion: nil)

        connectionTask = Task { @MainActor [weak self, weak interfaceController] in
            guard let self, let interfaceController else { return }

            let containerManager = ModelContainerManager.shared
            await containerManager.prepareContainer()

            guard Task.isCancelled == false,
                  self.connectionGeneration == generation,
                  self.interfaceController === interfaceController else { return }
            guard let container = containerManager.preparedContainer,
                  let playlistActor = try? PlaylistModelActor(modelContainer: container) else {
                loadingTemplate.emptyViewTitleVariants = ["Unable to load Up Next"]
                loadingTemplate.emptyViewSubtitleVariants = [containerManager.initializationError ?? "Open Up Next on iPhone and try again."]
                loadingTemplate.updateSections([])
                return
            }

            let playNext = CarPlayPlayNext(playlistActor: playlistActor, interfaceController: interfaceController)
            self.playNext = playNext

            let nowPlaying = CarPlayNowPlaying(interfaceController: interfaceController)
            self.nowPlaying = nowPlaying

            guard Task.isCancelled == false,
                  self.connectionGeneration == generation,
                  self.interfaceController === interfaceController else {
                playNext.invalidate()
                nowPlaying.invalidate()
                return
            }
            interfaceController.setRootTemplate(playNext.template, animated: false, completion: nil)
        }
    }
    
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        guard self.interfaceController === interfaceController else { return }
        logger.info("CarPlay disconnected")
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
