import Foundation
import CarPlay

@MainActor
class CarPlayChapterMarkList {
    let interfaceController: CPInterfaceController
    var template: CPListTemplate
    
    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.template = CPListTemplate(title: "Chapters", sections: [])
        Task{
            await setupTemplate()
        }
    }

    private func setupTemplate()  async{
        let loadedChapters = Player.shared.chapters ?? []
        guard loadedChapters.isEmpty == false else {
            template.updateSections([])
            return
        }
        let interfaceController = self.interfaceController

        var images: [UIImage?] = []
        images.reserveCapacity(loadedChapters.count)
        for chapter in loadedChapters {
            images.append(await loadImage(chapter: chapter))
        }
        
        let items = loadedChapters.enumerated().map { idx, chapter in
            let item = CPListItem(
                text: chapter.title,
                detailText: chapter.start != nil ? formattedTime(chapter.start!) : nil,
                image: images[idx] ?? UIImage()
            )
            item.userInfo = chapter
            item.isPlaying = (chapter.id == Player.shared.currentChapter?.id)
            item.handler = { _, _ in
                Task {
                    await Player.shared.skipTo(chapter: chapter)
                }
                interfaceController.popTemplate(animated: true, completion: nil)
            }
            return item
        }
        let section = CPListSection(items: items)
        template.trailingNavigationBarButtons = []
        template.updateSections([section])
    }

    private func formattedTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%01d:%02d:%02d", hours, mins % 60, secs)
        }
        return String(format: "%02d:%02d", mins, secs)
    }
    
    private func loadImage(chapter: Marker) async -> UIImage?{
        if let imageData = chapter.imageData,
           let uiImage = ImageLoaderAndCache.makeUIImage(from: imageData, maxPixelSize: 240) {
            
            return uiImage
        }else if let chapterImageURL = chapter.image{
            if let uiImage = await ImageLoaderAndCache.loadUIImage(from: chapterImageURL) {
              
                return uiImage
            }
        }
        return nil
    }
    
}
