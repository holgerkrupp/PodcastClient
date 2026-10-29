//
//  CarPlayNowPlaying.swift
//  PodcastClient
//
//  Created by Holger Krupp on 21.02.24.
//

import Foundation
import CarPlay
import SwiftData

private final class CarPlayNotificationObserver: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

@MainActor
class CarPlayNowPlaying {
    var interfaceController: CPInterfaceController

    
    let player = Player.shared
    
    var template: CPNowPlayingTemplate = CPNowPlayingTemplate.shared
    private var chapterDataObserver: CarPlayNotificationObserver?
    private var artworkSettingsObserver: CarPlayNotificationObserver?
    private var chapterList: CarPlayChapterMarkList?
    
    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        setupTempate(interfaceController: interfaceController)

        let observer = NotificationCenter.default.addObserver(
            forName: .playerChapterDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setupTempate(interfaceController: self.interfaceController)
            }
        }
        chapterDataObserver = CarPlayNotificationObserver(token: observer)
        let artworkObserver = NotificationCenter.default.addObserver(
            forName: CarPlayArtworkSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.setupTempate(interfaceController: self.interfaceController)
                self.chapterList?.refreshForArtworkPreferenceChange()
            }
        }
        artworkSettingsObserver = CarPlayNotificationObserver(token: artworkObserver)
    }

    func invalidate() {
        chapterDataObserver = nil
        artworkSettingsObserver = nil
        chapterList?.invalidate()
        chapterList = nil
    }
    
    func setupTempate(interfaceController: CPInterfaceController) {
        // print("setupTempate")
        let player = self.player
 
        // Configure the now playing template
        template.isUpNextButtonEnabled = false
        template.isAlbumArtistButtonEnabled = false
        
        var buttons : [CPNowPlayingButton] = []
    
        let preferredChapters = player.currentEpisode?.preferredChapters ?? []
        if preferredChapters.isEmpty == false {
            if let image = CarPlayArtworkProvider.buttonImage(
                systemName: "list.bullet", displayScale: interfaceController.carTraitCollection.displayScale
            ) {
                let listButton = CPNowPlayingImageButton(image: image) { [weak self] _ in
                    guard let self else { return }
                    let chapterList = CarPlayChapterMarkList(interfaceController: interfaceController)
                    self.chapterList?.invalidate()
                    self.chapterList = chapterList
                    interfaceController.pushTemplate(chapterList.template, animated: false, completion: nil)
                }
                buttons.append(listButton)
            }

            if let image = CarPlayArtworkProvider.buttonImage(
                systemName: "backward.end.alt", displayScale: interfaceController.carTraitCollection.displayScale
            ) {
                let previousChapterButton = CPNowPlayingImageButton(image: image) { [weak self] _ in
                    Task { await self?.skipToCurrentPreferredChapterStart() }
                }
                buttons.append(previousChapterButton)
            }

            if let image = CarPlayArtworkProvider.buttonImage(
                systemName: "forward.end.alt", displayScale: interfaceController.carTraitCollection.displayScale
            ) {
                let nextChapterButton = CPNowPlayingImageButton(image: image) { [weak self] _ in
                    Task { await self?.skipToNextPreferredChapter() }
                }
                buttons.append(nextChapterButton)
            }
        }
        
        
        
        let rateButton = CPNowPlayingPlaybackRateButton { _ in
            player.switchPlayBackSpeed()
        }
        
        buttons.append(rateButton)
        
        if let image = CarPlayArtworkProvider.buttonImage(
            systemName: "bookmark", displayScale: interfaceController.carTraitCollection.displayScale
        ) {
            let bookmarkButton = CPNowPlayingImageButton(image: image) { [weak self] _ in
                guard let self else { return }
                Task {
                    do { try await self.player.createBookmark() }
                    catch { self.showBookmarkError(error.localizedDescription) }
                }
            }
            buttons.append(bookmarkButton)
        }

        
        template.updateNowPlayingButtons(buttons)
    }

    private func showBookmarkError(_ message: String) {
        let ok = CPAlertAction(title: String(localized: "OK"), style: .default) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [ok])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    private func preferredChapters() -> [Marker] {
        player.currentEpisode?.preferredChapters ?? []
    }

    private func skipToCurrentPreferredChapterStart() async {
        let chapters = preferredChapters()
        guard let currentChapter = chapters.last(where: { ($0.start ?? 0) <= player.playPosition }),
              let start = currentChapter.start else {
            return
        }

        await player.jumpTo(time: start)
    }

    private func skipToNextPreferredChapter() async {
        // Share the manual-next action with the full player, including its
        // local chapter-skip recognition and near-boundary false-positive guard.
        await player.skipToNextChapter()
    }
    
}
