import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TopPodcastShareGalleryView: View {
    let rollups: [PodcastRollup]
    let timelineRollups: [TopPodcastShareTimelineRollup]
    let period: PlaySessionSummaryPeriod
    let periodStart: Date
    let periodLabel: String
    let dateRangeLabel: String
    let stats: TopPodcastShareStats

    @State private var renderedImages: [TopPodcastShareDesign: UIImage] = [:]
    @State private var selectedDesigns: Set<TopPodcastShareDesign> = []
    @State private var shareActivityItems: [Any] = []
    @State private var shareTempFileURLs: [URL] = []
    @State private var shareSheetID = UUID()
    @State private var showShareSheet = false
    @State private var isRendering = false
    @State private var renderedPreviewCount = 0
    @State private var previewRenderCount = 0
    @State private var renderCompletedUnitCount = 0
    @State private var renderTotalUnitCount = 0
    @State private var renderProgressMessage = "Preparing share pictures"
    @State private var shareTitle = "My Podcasts"
    @State private var selectedBackground: TopPodcastShareBackground = .current
    @State private var selectedVideoSize = TopPodcastShareAspect.defaultVideoSize
    @State private var usesMonthlyMiniMonthBackgrounds = false

    private var availableDesigns: [TopPodcastShareDesign] {
        TopPodcastShareDesign.allCases.filter { design in
            rollups.count >= design.minimumItemCount && design.supports(period: period)
        }
    }

    private var effectiveShareTitle: String {
        let trimmed = shareTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "My Podcasts" : trimmed
    }

    private var renderSignature: String {
        let rollupSignature = rollups.map { "\($0.id):\($0.totalSeconds)" }.joined(separator: "|")
        let timelineSignature = timelineRollups.map { "\($0.id):\($0.totalSeconds)" }.joined(separator: "|")
        return "\(effectiveShareTitle)|\(selectedBackground.rawValue)|\(usesMonthlyMiniMonthBackgrounds)|\(selectedVideoSize.width)x\(selectedVideoSize.height)|\(period.rawValue)|\(periodStart.timeIntervalSinceReferenceDate)|\(periodLabel)|\(dateRangeLabel)|\(stats.renderSignature)|\(rollupSignature)|\(timelineSignature)"
    }

    private var renderSize: CGSize {
        TopPodcastShareAspect.renderSize(for: selectedVideoSize)
    }

    private var previewAspectRatio: CGFloat {
        TopPodcastShareAspect.aspectRatio(for: selectedVideoSize)
    }

    private var shareDesignGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }

    private var canShareSelectedDesigns: Bool {
        selectedDesigns.isEmpty == false && selectedDesigns.contains { renderedImages[$0] == nil } == false
    }

    private var previewRenderProgress: Double {
        guard renderTotalUnitCount > 0 else { return 0 }
        return Double(renderCompletedUnitCount) / Double(renderTotalUnitCount)
    }

    var body: some View {
        List {
            if rollups.isEmpty {
                ContentUnavailableView(
                    "No Share Pictures",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Top podcast share pictures are available when the statistics show all podcasts.")
                )
            } else {
                Section {
                    NavigationLink {
                        TopPodcastShareCustomizeView(
                            title: $shareTitle,
                            selectedBackground: $selectedBackground,
                            selectedVideoSize: $selectedVideoSize,
                            usesMonthlyMiniMonthBackgrounds: $usesMonthlyMiniMonthBackgrounds
                        )
                    } label: {
                        Label("Customize", systemImage: "slider.horizontal.3")
                    }
                } footer: {
                    Text("Title: \(effectiveShareTitle) • Background: \(selectedBackground.title)")
                }

                Section {
                    if isRendering {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: previewRenderProgress)
                                .progressViewStyle(.linear)
                            Text(renderProgressMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                    }

                    LazyVGrid(columns: shareDesignGridColumns, spacing: 12) {
                        ForEach(availableDesigns) { design in
                            TopPodcastSharePreviewTile(
                                design: design,
                                image: renderedImages[design],
                                aspectRatio: previewAspectRatio,
                                isSelected: selectedDesigns.contains(design),
                                isRendering: isRendering
                            ) {
                                toggleSelection(for: design)
                            } shareAction: {
                                share(designs: [design])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Designs")
                } footer: {
                    Text(dateRangeLabel)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .navigationTitle("Share Top Podcasts")
        .platformInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    share(designs: Array(selectedDesigns))
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(canShareSelectedDesigns == false)
                .accessibilityLabel(selectedDesigns.count <= 1 ? "Share Selected Image" : "Share Selected Images")
            }
        }
        .task(id: renderSignature) {
            await renderPreviews()
        }
        .sheet(isPresented: $showShareSheet, onDismiss: cleanUpShareTemporaryFiles) {
            ShareSheet(activityItems: shareActivityItems)
                .id(shareSheetID)
        }
    }

    private func toggleSelection(for design: TopPodcastShareDesign) {
        if selectedDesigns.contains(design) {
            selectedDesigns.remove(design)
        } else {
            selectedDesigns.insert(design)
        }
    }

    private func share(designs: [TopPodcastShareDesign]) {
        let items = designs.compactMap { design -> (TopPodcastShareDesign, UIImage)? in
            guard let image = renderedImages[design] else { return nil }
            return (design, image)
        }
        guard !items.isEmpty else { return }

        if let fileURLs = writeShareImagesToTemporaryFiles(items) {
            shareTempFileURLs = fileURLs
            shareActivityItems = fileURLs
        } else {
            shareTempFileURLs = []
            shareActivityItems = items.map(\.1)
        }
        shareSheetID = UUID()
        showShareSheet = true
    }

    private func writeShareImagesToTemporaryFiles(_ items: [(TopPodcastShareDesign, UIImage)]) -> [URL]? {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("UpNextSharePics", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return try items.enumerated().map { index, item in
                guard let data = item.1.pngData() else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let filename = "\(index + 1)-\(shareFilenameComponent(for: item.0)).png"
                let url = directory.appendingPathComponent(filename)
                try data.write(to: url, options: .atomic)
                return url
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            return nil
        }
    }

    private func shareFilenameComponent(for design: TopPodcastShareDesign) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let words = design.title
            .lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
        return words.joined(separator: "-")
    }

    private func cleanUpShareTemporaryFiles() {
        let directories = Set(shareTempFileURLs.map { $0.deletingLastPathComponent() })
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        shareTempFileURLs = []
        shareActivityItems = []
    }

    @MainActor
    private func renderPreviews() async {
        guard !rollups.isEmpty else {
            renderedImages = [:]
            selectedDesigns = []
            renderedPreviewCount = 0
            previewRenderCount = 0
            renderCompletedUnitCount = 0
            renderTotalUnitCount = 0
            renderProgressMessage = "Preparing share pictures"
            return
        }

        let neededDesigns = availableDesigns

        guard !neededDesigns.isEmpty else {
            renderedImages = [:]
            selectedDesigns = []
            renderedPreviewCount = 0
            previewRenderCount = 0
            renderCompletedUnitCount = 0
            renderTotalUnitCount = 0
            isRendering = false
            return
        }

        let shouldLoadAllItems = neededDesigns.contains { $0.usesAllItems }
        let maxLimit = neededDesigns
            .filter { !$0.usesAllItems }
            .map(\.itemLimit)
            .max() ?? 0
        let sourceRollups = shouldLoadAllItems ? rollups : Array(rollups.prefix(maxLimit))
        let setupUnitCount = 1
        let itemUnitOffset = setupUnitCount
        let timelineUnitOffset = itemUnitOffset + sourceRollups.count
        let imageUnitOffset = timelineUnitOffset + timelineRollups.count

        renderedImages = [:]
        renderedPreviewCount = 0
        previewRenderCount = neededDesigns.count
        renderCompletedUnitCount = 0
        renderTotalUnitCount = setupUnitCount + sourceRollups.count + timelineRollups.count + neededDesigns.count
        renderProgressMessage = "Preparing share pictures"
        isRendering = true
        await Task.yield()

        renderCompletedUnitCount = setupUnitCount
        renderProgressMessage = sourceRollups.isEmpty
            ? "Preparing timeline data"
            : "Loading podcast artwork"

        let items = await topPodcastShareItems(from: sourceRollups) { completedCount in
            renderCompletedUnitCount = itemUnitOffset + completedCount
        }
        renderCompletedUnitCount = timelineUnitOffset
        renderProgressMessage = timelineRollups.isEmpty
            ? "Rendering share pictures"
            : "Loading timeline artwork"

        let timelineEntries = await topPodcastShareTimelineEntries(from: timelineRollups) { completedCount in
            renderCompletedUnitCount = timelineUnitOffset + completedCount
        }
        renderCompletedUnitCount = imageUnitOffset
        renderProgressMessage = "Rendering 0 of \(previewRenderCount) share pictures"

        let totalListeningSeconds = rollups.reduce(0) { $0 + $1.totalSeconds }

        var images: [TopPodcastShareDesign: UIImage] = [:]
        for design in neededDesigns {
            let designItems = design.usesAllItems ? items : Array(items.prefix(design.itemLimit))
            let image = renderTopPodcastShareImage(
                items: designItems,
                design: design,
                periodLabel: periodLabel,
                dateRangeLabel: dateRangeLabel,
                totalListeningSeconds: totalListeningSeconds,
                shareTitle: effectiveShareTitle,
                background: selectedBackground,
                renderSize: renderSize,
                stats: stats,
                period: period,
                periodStart: periodStart,
                timelineEntries: timelineEntries,
                usesMonthlyMiniMonthBackgrounds: usesMonthlyMiniMonthBackgrounds,
                durationFormatter: formatDuration
            )
            images[design] = image
            renderedImages = images
            renderedPreviewCount += 1
            renderCompletedUnitCount = imageUnitOffset + renderedPreviewCount
            renderProgressMessage = "Rendering \(renderedPreviewCount) of \(previewRenderCount) share pictures"
            await Task.yield()
        }

        renderedImages = images
        selectedDesigns = selectedDesigns.intersection(Set(neededDesigns))
        isRendering = false
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0m" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

private struct TopPodcastShareCustomizeView: View {
    @Binding var title: String
    @Binding var selectedBackground: TopPodcastShareBackground
    @Binding var selectedVideoSize: CGSize
    @Binding var usesMonthlyMiniMonthBackgrounds: Bool

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title)

                Button("Reset to Default") {
                    title = "My Podcasts"
                }
            } header: {
                Text("Share Picture Title")
            } footer: {
                Text("This title is used for every share picture preview and export.")
            }

            Section {
                VideoSizePicker(videoSize: $selectedVideoSize)
            } header: {
                Text("Aspect Ratio")
            } footer: {
                Text("The selected ratio is applied to every share picture preview and export.")
            }

            Section {
                Toggle("Monthly backgrounds in Year Calendar", isOn: $usesMonthlyMiniMonthBackgrounds)
            } header: {
                Text("Year Calendar")
            } footer: {
                Text("Applies the existing January to December backgrounds to the mini month blocks in the Year Calendar design.")
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                    ForEach(TopPodcastShareBackground.allCases) { background in
                        Button {
                            selectedBackground = background
                        } label: {
                            TopPodcastShareBackgroundOption(
                                background: background,
                                isSelected: selectedBackground == background
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Background")
            } footer: {
                Text("Background changes are applied to every share picture preview and export.")
            }
        }
        .navigationTitle("Customize")
        .platformInlineNavigationTitle()
    }
}

private struct TopPodcastShareBackgroundOption: View {
    let background: TopPodcastShareBackground
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TopPodcastShareBackgroundPreview(background: background)
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 3 : 1)
                )

            HStack(spacing: 6) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(background.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

private struct TopPodcastShareBackgroundPreview: View {
    let background: TopPodcastShareBackground

    var body: some View {
        return ZStack {
            if let occasionConfig = background.occasionConfig {
                SeasonalPodcastShareBackground(config: occasionConfig)
            } else if let month = background.seasonalMonth {
                SeasonalPodcastShareBackground(month: month)
            } else {
                switch background {
                case .current:
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.09, blue: 0.15),
                        Color(red: 0.04, green: 0.18, blue: 0.22),
                        Color(red: 0.47, green: 0.17, blue: 0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                case .stripes:
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            ForEach(Array(TopPodcastShareBackground.stripeColors.enumerated()), id: \.offset) { _, color in
                                color
                                    .frame(height: geometry.size.height / CGFloat(TopPodcastShareBackground.stripeColors.count))
                            }
                        }
                    }
                case .rainbowGradient:
                    LinearGradient(
                        colors: TopPodcastShareBackground.stripeColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                case .white:
                    Color.white
                case .black:
                    Color.black
                default:
                    Color.black
                }
            }
        }
    }
}


private struct TopPodcastSharePreviewTile: View {
    let design: TopPodcastShareDesign
    let image: UIImage?
    let aspectRatio: CGFloat
    let isSelected: Bool
    let isRendering: Bool
    let selectAction: () -> Void
    let shareAction: () -> Void

    private var accessibilityLabelText: String {
        isSelected ? "Deselect \(design.title)" : "Select \(design.title)"
    }

    private func shareIfImageIsReady() {
        guard image != nil else { return }
        shareAction()
    }

    private var previewContent: some View {
        return ZStack {
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.12))

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                            .controlSize(.regular)
                    }
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(isRendering && image == nil ? 0.72 : 1)
            }
        }
    }

    private var selectionStrokeColor: Color {
        isSelected ? Color.accentColor : Color.secondary.opacity(0.18)
    }

    private var selectionStrokeWidth: CGFloat {
        isSelected ? 3 : 1
    }

    private var tileBackgroundColor: Color {
        isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)
    }

    var body: some View {
        previewContent
        .padding(8)
        .background(
            tileBackgroundColor,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selectionStrokeColor, lineWidth: selectionStrokeWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(perform: selectAction)
        .onLongPressGesture(minimumDuration: 0.45, perform: shareIfImageIsReady)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            selectAction()
        }
    }
}
