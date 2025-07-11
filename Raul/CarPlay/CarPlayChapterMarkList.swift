import Foundation
import CarPlay

@MainActor
class CarPlayChapterMarkList {
    let interfaceController: CPInterfaceController
    var template: CPListTemplate
    private var chapters: [Chapter] = []
    
    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.template = CPListTemplate(title: "Chapters", sections: [])
        setupTemplate()
    }

    private func setupTemplate() {
        // Get chapters from the current player
        guard let loadedChapters = Player.shared.currentEpisode?.preferredChapters else {
            template.updateSections([])
            return
        }
        self.chapters = loadedChapters

        // Map chapters to CPListItems
        let items = chapters.enumerated().map { (idx, chapter) in
            let item = CPListItem(
                text: chapter.title,
                detailText: chapter.start != nil ? formattedTime(chapter.start!) : nil,
                image: nil
            )
            item.userInfo = chapter
            item.handler = { [weak self] _, _ in
                guard let self else { return }
                let chapter = self.chapters[idx]
                Task {
                    await Player.shared.skipTo(chapter: chapter)
                }
                self.interfaceController.popTemplate(animated: true, completion: nil)
            }
            return item
        }
        let section = CPListSection(items: items)
        template.updateSections([section])
    }

    private func formattedTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

