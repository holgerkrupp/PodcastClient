import SwiftUI
import SwiftData
import CloudKitSyncMonitor
import ESADesignKit

enum OnboardingPreferenceKeys {
    static let didCompleteOnboarding = "didCompleteOnboarding"
}

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPage = 0
    @AppStorage(UpNextVisualDesignPreference.storageKey) private var storedVisualStyle = ESAVisualStyle.artwork.rawValue
    @State private var selectedVisualStyle: ESAVisualStyle

    private let requiresInitialCloudImport: Bool
    private let modelContainer: ModelContainer?

    init(requiresInitialCloudImport: Bool = false, modelContainer: ModelContainer? = nil) {
        self.requiresInitialCloudImport = requiresInitialCloudImport
        self.modelContainer = modelContainer
        let rawStyle = UserDefaults.standard.string(forKey: UpNextVisualDesignPreference.storageKey) ?? ESAVisualStyle.artwork.rawValue
        _selectedVisualStyle = State(initialValue: ESAVisualStyle(rawValue: rawStyle) ?? .artwork)
    }

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "Welcome to Up Next",
            summary: "Up Next helps you collect new podcast episodes, choose what is worth hearing, and keep one clear playback list.",
            systemImage: "play.circle.fill",
            tint: .accentColor,
            bullets: [
                "Subscribe to podcasts from search, categories, hot podcasts, or an OPML import.",
                "Fresh episodes arrive in Inbox first unless your settings send them directly to a playlist.",
                "The player follows your playlist order and keeps playback ready across the app."
            ]
        ),
        OnboardingPage(
            title: "Subscribe",
            summary: "Use Add to find shows by name, paste a feed URL, browse categories, or import your subscriptions.",
            systemImage: "plus.circle.fill",
            tint: .green,
            bullets: [
                "Open Add from the tab bar.",
                "Search for a podcast or paste its RSS feed URL.",
                "Tap Subscribe to add the show to your library and start receiving episodes."
            ]
        ),
        OnboardingPage(
            title: "Inbox",
            summary: "Inbox is the calm sorting place for new episodes before they join your listening queue.",
            systemImage: "tray.fill",
            tint: .orange,
            bullets: [
                "Review newly found episodes without cluttering your playlist.",
                "Move episodes you want to hear into a playlist.",
                "Adding an episode to a playlist removes it from Inbox. You can also remove it directly when you are done triaging."
            ]
        ),
        OnboardingPage(
            title: "Playlists",
            summary: "Playlists decide what plays next. Keep one main Up Next queue or create separate lists for different moods.",
            systemImage: "text.line.first.and.arrowtriangle.forward",
            tint: .blue,
            bullets: [
                "Add episodes from Inbox, Library, or podcast detail screens.",
                "Reorder episodes manually when your listening priorities change.",
                "Use Settings to choose where new episodes from subscriptions should go."
            ]
        )
    ]

    private var pageCount: Int {
        pages.count + 1 + (requiresInitialCloudImport && modelContainer != nil ? 1 : 0)
    }

    var body: some View {
        NavigationStack {
            pageContent
                .navigationTitle("Getting Started")
                .platformInlineNavigationTitle()
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        HStack {
                            ForEach(0..<pageCount, id: \.self) { index in
                                Button {
                                    withAnimation { selectedPage = index }
                                } label: {
                                    Image(systemName: selectedPage == index ? "circle.fill" : "circle")
                                        .font(.caption)
                                        .foregroundStyle(selectedPage == index ? Color.accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Page \(index + 1) of \(pageCount)")
                                .accessibilityAddTraits(selectedPage == index ? .isSelected : [])
                            }
                        }

                        Spacer()

                        Button {
                            storedVisualStyle = selectedVisualStyle.rawValue
                            dismiss()
                        } label: {
                            Text("Start Listening")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal)
                    .padding(.vertical)
                }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        #if os(macOS)
        ZStack {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                if selectedPage == index {
                    OnboardingPageView(page: page)
                }
            }

            if selectedPage == pages.count {
                VisualDesignChooser(selection: $selectedVisualStyle)
            }

            if selectedPage == pages.count + 1, requiresInitialCloudImport, let modelContainer {
                OnboardingCloudSyncPageView(modelContainer: modelContainer)
            }
        }
        #else
        TabView(selection: $selectedPage) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                OnboardingPageView(page: page)
                    .tag(index)
            }

            VisualDesignChooser(selection: $selectedVisualStyle)
                .tag(pages.count)

            if requiresInitialCloudImport, let modelContainer {
                OnboardingCloudSyncPageView(modelContainer: modelContainer)
                    .tag(pages.count + 1)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #endif
    }
}

private struct OnboardingPage {
    let title: String
    let summary: String
    let systemImage: String
    let tint: Color
    let bullets: [String]
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        GeometryReader { geometry in
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
            .frame(maxWidth: min(geometry.size.width, geometry.size.height) * 0.9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var content: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: page.systemImage)
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(page.tint)
                    .padding()
                    .background(page.tint.opacity(0.12), in: .circle)

                Text(page.title)
                    .font(.title.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom)

            Text(page.summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom)

            VStack(alignment: .leading) {
                ForEach(page.bullets, id: \.self) { bullet in
                    Label {
                        Text(bullet)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(page.tint)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Final onboarding page shown only on a fresh device that still needs to pull an
/// existing library down from iCloud. It folds the former blocking "Waiting for
/// iCloud" launch gate into onboarding: the app is already usable behind it, and
/// this page simply reports sync progress until the library has arrived.
private struct OnboardingCloudSyncPageView: View {
    @StateObject private var syncMonitor = SyncMonitor.default
    let modelContainer: ModelContainer

    @State private var localRecordCount = 0
    @State private var referenceRecordCount: Int?

    private var isComplete: Bool {
        syncMonitor.importState.didSucceed
    }

    private var hasBlockingProblem: Bool {
        if syncMonitor.importError != nil || syncMonitor.setupError != nil {
            return true
        }

        switch syncMonitor.syncStateSummary {
        case .noNetwork, .accountNotAvailable, .error:
            return true
        default:
            return false
        }
    }

    private var systemImage: String {
        if isComplete { return "checkmark.icloud.fill" }
        return hasBlockingProblem ? "exclamationmark.icloud" : "arrow.clockwise.icloud"
    }

    private var tint: Color {
        if isComplete { return .green }
        return hasBlockingProblem ? .orange : .blue
    }

    private var title: String {
        if isComplete {
            return "Your Library Is Ready"
        }

        if syncMonitor.importError != nil || syncMonitor.setupError != nil {
            return "iCloud Sync Could Not Finish"
        }

        switch syncMonitor.syncStateSummary {
        case .noNetwork:
            return "Waiting for a Network"
        case .accountNotAvailable:
            return "iCloud Is Not Available"
        default:
            return "Syncing Your Library"
        }
    }

    private var summary: String {
        if isComplete {
            return "Your podcasts, playlists, and playback history have arrived from iCloud."
        }

        if syncMonitor.importError != nil || syncMonitor.setupError != nil {
            return "You can start using Up Next now. Your library will keep updating in the background, though some data may not have arrived from iCloud yet."
        }

        switch syncMonitor.syncStateSummary {
        case .noNetwork:
            return "Connect to the internet to download your podcasts and playback data. You can start exploring now and your library will sync when you're back online."
        case .accountNotAvailable:
            return "Sign in to iCloud and enable iCloud Drive to download your existing library. You can still start using Up Next right away."
        default:
            return "Downloading podcasts, playlists, and playback data from iCloud. Large libraries may take a moment — feel free to start exploring."
        }
    }

    private var estimatedProgress: Double? {
        guard let referenceRecordCount, referenceRecordCount > 0 else { return nil }
        return min(Double(localRecordCount) / Double(referenceRecordCount), 0.95)
    }

    var body: some View {
        GeometryReader { geometry in
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
            .frame(maxWidth: min(geometry.size.width, geometry.size.height) * 0.9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await updateEstimatedProgress()
        }
    }

    private var content: some View {
        VStack(alignment: .leading) {
            HStack {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .symbolEffect(.rotate, options: .repeating, isActive: !isComplete && !hasBlockingProblem)
                    .padding()
                    .background(tint.opacity(0.12), in: .circle)

                Text(title)
                    .font(.title.bold())
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom)

            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !isComplete && !hasBlockingProblem {
                VStack {
                    if let estimatedProgress {
                        ProgressView(value: estimatedProgress)
                            .progressViewStyle(.linear)

                        Text("\(localRecordCount.formatted()) of about \(referenceRecordCount?.formatted() ?? "0") records")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top)
            }
        }
        .padding()
        .fixedSize(horizontal: false, vertical: true)
    }

    private func updateEstimatedProgress() async {
        while !Task.isCancelled {
            if let reference = CloudSyncProgressReferenceStore.load() {
                referenceRecordCount = reference.recordCount
            }

            localRecordCount = await CloudSyncProgressReferenceStore.localRecordCount(
                modelContainer: modelContainer
            )

            if syncMonitor.importState.didSucceed { break }

            try? await Task.sleep(for: .milliseconds(750))
        }
    }
}

private extension SyncMonitor.SyncState {
    var didSucceed: Bool {
        if case .succeeded = self {
            return true
        }
        return false
    }
}

#Preview {
    OnboardingView()
}
