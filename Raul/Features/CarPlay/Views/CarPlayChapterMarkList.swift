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

        var remoteImageTargets: [(item: CPListItem, url: URL)] = []
        let items = loadedChapters.map { chapter in
            let image: UIImage?
            if let imageData = chapter.imageData {
                image = CarPlayArtworkProvider.loadImage(
                    from: imageData,
                    maxPixelSize: CarPlayArtworkProvider.pixelBudget(
                        displayScale: interfaceController.carTraitCollection.displayScale
                    )
                )
            } else {
                image = nil
            }
            let item = CPListItem(
                text: chapter.displayTitle,
                detailText: chapter.start.map(formattedTime),
                image: image
            )
            item.userInfo = chapter
            item.isPlaying = chapter.id == Player.shared.currentChapter?.id
            item.handler = { [weak self] _, completion in
                completion()
                guard let self else { return }
                Task { await Player.shared.skipTo(chapter: chapter) }
                self.interfaceController.popTemplate(animated: true, completion: nil)
            }
            if image == nil, let url = chapter.image {
                remoteImageTargets.append((item, url))
            }
            return item
        }
        template.trailingNavigationBarButtons = []
        template.updateSections([CPListSection(items: items)])

        let targets = remoteImageTargets
        let activeTemplate = template
        let maxPixelSize = CarPlayArtworkProvider.pixelBudget(
            displayScale: interfaceController.carTraitCollection.displayScale
        )
        artworkTask = Task { [weak self] in
            await CarPlayArtworkProvider.loadBounded(
                requests: targets.enumerated().map { (index: $0.offset, url: $0.element.url) },
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
