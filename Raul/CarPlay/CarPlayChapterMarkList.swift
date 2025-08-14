import Foundation
import CarPlay

@MainActor
class CarPlayChapterMarkList {
    let interfaceController: CPInterfaceController
    var template: CPListTemplate
    private var chapters: [Marker] = []
    private var images: [UIImage?] = []
    
    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.template = CPListTemplate(title: "Chapters", sections: [])
        Task{
            await setupTemplate()
        }
    }

    private func setupTemplate()  async{
        // Get chapters from the current player
        guard let loadedChapters = Player.shared.currentEpisode?.preferredChapters.sorted(by: { first, second in
            first.start ?? 0.0 < second.start ?? 0
        }) else {
            template.updateSections([])
            return
        }
        self.chapters = loadedChapters
        self.images = []
            for chapter in loadedChapters {
                await images.append(loadImage(chapter: chapter))
            }
        

        // Map chapters to CPListItems
        let items = self.chapters.enumerated().map { (idx, chapter) in
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
        template.trailingNavigationBarButtons = []
        template.updateSections([section])
    }

    private func formattedTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    private func loadImage(chapter: Marker) async -> UIImage?{
        if let imageData = chapter.imageData,
           let uiImage = UIImage(data: imageData) {
            
            return uiImage
        }else if let chapterImageURL = chapter.image{
            if let uiImage = await ImageLoaderAndCache.loadUIImage(from: chapterImageURL) {
              
                return uiImage
            }
        }
        return nil
    }
    
}

