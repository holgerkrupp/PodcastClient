import Foundation
import CarPlay

@MainActor
class CarPlayChapterMarkList {
    let interfaceController: CPInterfaceController
    var template: CPListTemplate
    private var artworkTask: Task<Void, Never>?
    private var generation = 0

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.template = CPListTemplate(title: "Chapters", sections: [])
        setupTemplate()
    }

    deinit { artworkTask?.cancel() }

    func invalidate() {
        generation &+= 1
        artworkTask?.cancel()
        artworkTask = nil
    }

    func refreshForArtworkPreferenceChange() { setupTemplate() }

    private func setupTemplate() {
        artworkTask?.cancel()
        generation &+= 1
        let requestGeneration = generation
        let loadedChapters = Array(
            (Player.shared.currentEpisode?.preferredChapters ?? [])
                .prefix(max(1, CPListTemplate.maximumItemCount))
        )
        guard loadedChapters.isEmpty == false else {
            template.updateSections([])
            return
        }

        var artworkTargets: [(item: CPListItem, request: CarPlayArtworkProvider.Request)] = []
        let items = loadedChapters.map { chapter in
            let item = CPListItem(
                text: chapter.displayTitle,
                detailText: chapter.start.map(formattedTime),
                image: nil
            )
            item.userInfo = chapter
            item.isPlaying = chapter.id == Player.shared.currentChapter?.id
            item.handler = { [weak self] _, completion in
                completion()
                guard let self else { return }
                Task { await Player.shared.skipTo(chapter: chapter) }
                self.interfaceController.popTemplate(animated: true, completion: nil)
            }
            if let imageData = chapter.imageData {
                artworkTargets.append((item, CarPlayArtworkProvider.Request(
                    index: artworkTargets.count, url: nil, data: imageData
                )))
            } else if let url = chapter.image {
                artworkTargets.append((item, CarPlayArtworkProvider.Request(
                    index: artworkTargets.count, url: url, data: nil
                )))
            }
            return item
        }
        template.trailingNavigationBarButtons = []
        template.updateSections([CPListSection(items: items)])

        let targets = artworkTargets
        let activeTemplate = template
        let maxPixelSize = CarPlayArtworkProvider.pixelBudget(
            displayScale: interfaceController.carTraitCollection.displayScale
        )
        artworkTask = Task { [weak self] in
            await CarPlayArtworkProvider.loadBounded(
                requests: targets.map(\.request),
                maxPixelSize: maxPixelSize
            ) { index, image in
                guard let self,
                      self.generation == requestGeneration,
                      self.template === activeTemplate,
                      Task.isCancelled == false else { return }
                targets[index].item.setImage(image)
            }
        }
    }

    private func formattedTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if hours > 0 { return String(format: "%01d:%02d:%02d", hours, mins % 60, secs) }
        return String(format: "%02d:%02d", mins, secs)
    }
}
