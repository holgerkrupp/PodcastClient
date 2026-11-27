import SwiftUI
import SwiftData
import ESADesignKit
import os
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum PlayerLayoutMode: Equatable {
    case compact
    case compactFull
    case expandedHorizontal
    case expandedVertical
}

enum PlayerLayoutPolicy {
    static let horizontalArrangementMinimumWidth: CGFloat = 640

    /// - Parameter isPhone: Every iPhone, including a wide or unfolded iPhone
    ///   Duo, keeps the cover-hero player (AGENTS.md player requirements):
    ///   only its dimensions adapt. The context-pane arrangements are for
    ///   iPad and Mac.
    static func mode(
        fullSize: Bool,
        size: CGSize,
        horizontalSizeClass: UserInterfaceSizeClass?,
        requestedExpandedLayout: Bool?,
        isPhone: Bool
    ) -> PlayerLayoutMode {
        guard fullSize else { return .compact }
        guard isPhone == false else { return .compactFull }

        let isExpanded = requestedExpandedLayout
            ?? (horizontalSizeClass == .regular
                || (horizontalSizeClass == nil && size.width >= horizontalArrangementMinimumWidth))
        guard isExpanded else { return .compactFull }

        let usesHorizontalArrangement = size.width >= horizontalArrangementMinimumWidth
            && size.width >= size.height * 0.95
        return usesHorizontalArrangement ? .expandedHorizontal : .expandedVertical
    }
}

struct PlayerView: View {
    @Bindable private var player = Player.shared
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @SceneStorage("player.contentTab") private var contentTabRawValue = PlayerContentTab.shownotes.rawValue
    @State private var contentAvailability: PlayerContentAvailability?
    @State private var isTransportPinned = false
    /// iPhone Duo vertical bar (closed display, inner landscape). While it is
    /// present the pinned transport moves into that strip (HIG, Vertical
    /// controls); elsewhere it pins horizontally to the top.
    @State private var verticalBar = VerticalBarPlacement.none

    let fullSize: Bool
    /// Set by the iOS presentation host because a sheet's local size class can
    /// differ from the scene that presented it.
    var usesExpandedLayout: Bool? = nil
    var onDismiss: (() -> Void)? = nil

    private var contentTab: PlayerContentTab {
        PlayerContentTab(rawValue: contentTabRawValue) ?? .shownotes
    }

    private var contentTabSelection: Binding<PlayerContentTab> {
        Binding(
            get: { contentTab },
            set: { newValue in
                guard newValue != contentTab else { return }
                PlayerOpeningPerformance.beginInteraction(.contentTab)
                contentTabRawValue = newValue.rawValue
            }
        )
    }

    private var currentArtworkSource: ESAImageSource {
        guard let image = player.currentArtworkImage else { return .url(nil) }
#if os(macOS)
        // Player keeps its decoded artwork as UIImage on every platform. The
        // design kit uses NSImage on macOS, so bridge the same pixels without
        // changing which chapter/episode image the player selected.
        if let cgImage = image.cgImage {
            return .platformImage(NSImage(
                cgImage: cgImage,
                size: NSSize(width: image.size.width, height: image.size.height)
            ))
        }
        if let data = image.pngData(), let nsImage = NSImage(data: data) {
            return .platformImage(nsImage)
        }
        return .url(nil)
#else
        return .platformImage(image)
#endif
    }

    var body: some View {
        if let episode = player.currentEpisode {
            // No root-level `episode.refresh` read: reference changes reach the
            // availability snapshot below and the shownotes/chapter tab views
            // through their own revisions, never the whole player (#520).
            GeometryReader { geometry in
                Group {
                    switch PlayerLayoutPolicy.mode(
                        fullSize: fullSize,
                        size: geometry.size,
                        horizontalSizeClass: horizontalSizeClass,
                        requestedExpandedLayout: usesExpandedLayout,
                        isPhone: PlatformSupport.isPhone
                    ) {
                    case .compact:
                        compactPlayer(episode: episode)
                    case .compactFull:
                        compactFullPlayer(episode: episode, in: geometry.size)
                    case .expandedHorizontal:
                        expandedPlayer(
                            episode: episode,
                            in: geometry.size,
                            arrangement: .horizontal
                        )
                    case .expandedVertical:
                        expandedPlayer(
                            episode: episode,
                            in: geometry.size,
                            arrangement: .vertical
                        )
                    }
                }
            }
            .esaResolveTheme(image: currentArtworkSource)
            .onAppear {
                PlayerOpeningPerformance.noteInteraction()
                PlayerOpeningPerformance.firstMeaningfulFrame(artworkReady: player.currentArtworkImage != nil)
            }
            .background {
                ESADesignKit.ESAFullBackground(image: currentArtworkSource)
            }
            .onChange(of: episode.url) { _, _ in
                isTransportPinned = false
                contentAvailability = nil
            }
            .task(id: episode.url) {
                await refreshContentAvailability(for: episode)
                await fetchAdvertisedTranscriptIfNeeded(for: episode)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .episodeReferencesDidChange)
                    .receive(on: DispatchQueue.main)
            ) { notification in
                guard notificationMatchesEpisode(notification, episode: episode) else { return }
                Task { @MainActor in
                    await refreshContentAvailability(for: episode, forceRefresh: true)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playerChapterDataDidChange)) { _ in
                Task { @MainActor in
                    await refreshContentAvailability(for: episode, forceRefresh: true)
                }
            }
        } else {
            PlayerEmptyView()
        }
    }

    private enum ExpandedArrangement {
        case horizontal
        case vertical
    }

    @ViewBuilder
    private func expandedPlayer(
        episode: Episode,
        in size: CGSize,
        arrangement: ExpandedArrangement
    ) -> some View {
        Group {
            switch arrangement {
            case .horizontal:
                HStack(spacing: 0) {
                    playerContentPane(episode: episode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    // Keep the panes clear of a possible Duo division without
                    // coupling the layout to a device-specific measurement.
                    Color.clear
                        .frame(width: size.width * 0.06)
                        .accessibilityHidden(true)

                    Divider()

                    expandedPlayerControls(episode: episode, in: size)
                }
            case .vertical:
                VStack(spacing: 0) {
                    playerContentPane(episode: episode)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    ScrollView {
                        expandedPlayerControls(episode: episode, in: size)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: min(max(size.height * 0.44, 280), 480))
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
        .safeAreaPadding()
    }

    private func expandedPlayerControls(episode: Episode, in size: CGSize) -> some View {
        PlayerControllView(
            mediaHeight: min(size.width, size.height) * 0.33,
            showsInlineTranscript: false,
            hidesTranscriptGeneration: contentTab == .transcript,
            contentAvailability: contentAvailability
        )
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls for \(episode.title)")
    }

    private func playerContentPane(episode: Episode) -> some View {
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Player content", selection: contentTabSelection) {
                    ForEach(PlayerContentTab.allCases) { tab in
                        Text(tab.title)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Player content")

                PlayerMoreActionsMenu(episode: episode)
            }
            .padding()

            Divider()

            Group {
                switch contentTab {
                case .shownotes:
                    ScrollView {
                        PlayerShownotesView(episode: episode)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .transcript:
                    TranscriptPane(
                        episode: episode,
                        availability: contentAvailability,
                        startFollowingPlayback: true
                    )
                case .chapters:
                    PlayerChaptersTabContent(episode: episode)
                case .upNext:
                    UpcomingQueuePreview()
                }
            }
            .id(contentTab)
            .onAppear { PlayerOpeningPerformance.interactionVisible(.contentTab) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.regularMaterial)
    }

    private func compactFullPlayer(episode: Episode, in size: CGSize) -> some View {
        let usesArtworkHero = !player.currentPlaybackIsVideo && colorSchemeContrast != .increased

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PlayerControllView(
                    showPrimaryTransportControls: false,
                    mediaHeight: min(max(0, size.width - 32), size.height * 0.72),
                    showsMedia: !usesArtworkHero,
                    showsTranscriptOverHero: usesArtworkHero,
                    showsPlaybackUtilities: false,
                    contentAvailability: contentAvailability
                )
                    .frame(maxWidth: .infinity, alignment: .top)

                transportControls
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named("playerViewport")).minY
                    } action: { _, headerY in
                        isTransportPinned = headerY <= 0
                    }
                    .opacity(isTransportPinned ? 0 : 1)
                    .allowsHitTesting(!isTransportPinned)

                PlayerPlaybackUtilitiesRow()
                    .padding(.horizontal)
                    .padding(.bottom, 12)

                compactPlayerContent(episode: episode)

            }
            .fullPageScreenshotSupport()
            .safeAreaPadding(.horizontal)
            .safeAreaPadding(.bottom)
            .safeAreaPadding(.top, usesArtworkHero ? 0 : nil)
        }
        .coordinateSpace(name: "playerViewport")
        .coverHero(
            image: currentArtworkSource,
            enabled: usesArtworkHero,
            placeholderAspectRatio: 1.0
        )
        .overlay(alignment: .top) {
            if isTransportPinned, verticalBar.edge == nil {
                transportControls
                    .safeAreaPadding(.horizontal)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The pinned transport owns the top edge, so the close button
            // steps aside while it is pinned and returns when scrolled back up.
            // Reserving room for it instead shifted and squeezed the row until
            // the clip and bookmark buttons overlapped the skip buttons.
            if let onDismiss, !isTransportPinned {
                Button(action: onDismiss) {
                    Label("Close player", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.glass(.clear))
                .accessibilityLabel("Close player")
                .padding()
            }
        }
        // A square cover should fit within a short landscape iPhone viewport.
        .frame(width: min(size.width, size.height * 0.55))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isTransportPinned, let edge = verticalBar.edge {
                verticalTransportColumn(edge: edge)
            }
        }
#if os(iOS)
        .background {
            VerticalBarProbe(placement: $verticalBar)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
#endif
        .scrollIndicators(.automatic)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback controls and shownotes for \(episode.title)")
    }

    /// The pinned transport as a column in the vertical bar strip, below the
    /// status items and centred in the rest of the bar, within thumb reach.
    /// The strip lies outside the safe area, so the column is offset past the
    /// content's edge by the bar's inset and never covers content.
    private func verticalTransportColumn(edge: VerticalBarPlacement.Edge) -> some View {
        GeometryReader { proxy in
            let barWidth = edge == .trailing ? proxy.safeAreaInsets.trailing : proxy.safeAreaInsets.leading
            // The status items sit at the top of the window; this view may start lower.
            let windowTop = proxy.frame(in: .global).minY
            let reservedTop = max(VerticalBarPlacement.reservedStatusHeight - windowTop, 0)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                PlayerPrimaryTransportControlsView(includeBookmark: true, axis: .vertical)
                    .tint(.primary)
                Spacer(minLength: 0)
            }
            .frame(width: max(barWidth, 64))
            .padding(.top, reservedTop)
            .padding(.bottom, proxy.safeAreaInsets.bottom)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: edge == .trailing ? .trailing : .leading
            )
            .offset(x: edge == .trailing ? barWidth : -barWidth)
        }
        .transition(.opacity)
    }

    private var transportControls: some View {
        PlayerPrimaryTransportControlsView(includeBookmark: true)
            .tint(.primary)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .onAppear {
                PlayerOpeningPerformance.controlsResponsive()
            }
    }

    private func compactPlayerContent(episode: Episode) -> some View {
        VStack(alignment: .leading) {
            HStack(spacing: 12) {
                Picker("Player content", selection: contentTabSelection) {
                    ForEach(PlayerContentTab.allCases) { tab in
                        Text(tab.title)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Player content")
            }

            Divider()

            VStack(alignment: .leading) {
                switch contentTab {
                case .shownotes:
                    HStack {
                        Text("Shownotes")
                            .font(.headline)
                        Spacer()
                        PlayerMoreActionsMenu(episode: episode)
                    }
                    .padding(.bottom, 8)

                    PlayerShownotesView(episode: episode)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .transcript:
                    TranscriptPane(
                        episode: episode,
                        availability: contentAvailability,
                        startFollowingPlayback: true
                    )
                case .chapters:
                    PlayerChaptersTabContent(episode: episode)
                case .upNext:
                    UpcomingQueuePreview()
                }
            }
            .id(contentTab)
            .onAppear { PlayerOpeningPerformance.interactionVisible(.contentTab) }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactPlayer(episode: Episode) -> some View {
        VStack(spacing: 0) {
            PlayerControllView(
                contentAvailability: contentAvailability
            )
                .padding()
#if DEBUG
            NavigationLink(destination: EpisodeDebugMetadataView(episode: episode)) {
                Image(systemName: "ladybug")
                    .imageScale(.small)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .tint(.blue)
            .accessibilityLabel("Episode debug metadata")
#endif
        }
    }

    /// Episodes whose advertised transcript was already requested this launch,
    /// so a missing or broken file is not fetched on every player open.
    @MainActor private static var advertisedTranscriptRequests: Set<URL> = []

    /// A streamed episode gets its publisher transcript here; downloads still
    /// fetch it after the audio file arrives.
    @MainActor
    private func fetchAdvertisedTranscriptIfNeeded(for episode: Episode) async {
        guard let episodeURL = episode.url,
              let availability = contentAvailability,
              availability.episodeURL == episodeURL,
              availability.hasTranscript == false,
              Self.advertisedTranscriptRequests.insert(episodeURL).inserted else { return }
        let container = modelContext.container
        let fetched = await Task.detached(priority: .utility) {
            await EpisodeActor(modelContainer: container).fetchAdvertisedTranscriptIfNeeded(episodeURL: episodeURL)
        }.value
        guard fetched, !Task.isCancelled, player.currentEpisode?.url == episodeURL else { return }
        await refreshContentAvailability(for: episode, forceRefresh: true)
    }

    @MainActor
    private func refreshContentAvailability(for episode: Episode, forceRefresh: Bool = false) async {
        guard let episodeURL = episode.url else { return }
        if contentAvailability?.episodeURL != episodeURL {
            contentAvailability = nil
        }
        let worker = PlayerContentAvailabilityModelActor(modelContainer: modelContext.container)
        if forceRefresh {
            await worker.invalidate(episodeURL: episodeURL)
        }
        let snapshot = await worker.availability(for: episodeURL)
        guard Task.isCancelled == false, player.currentEpisode?.url == episodeURL else { return }
        // Re-queries after unrelated reference notifications usually return the
        // same value; don't invalidate the player for them.
        if contentAvailability != snapshot {
            contentAvailability = snapshot
        }
    }

    private func notificationMatchesEpisode(_ notification: Notification, episode: Episode) -> Bool {
        PlayerReferenceNotificationPolicy.matches(
            changedURL: notification.userInfo?[EpisodeReferenceNotificationKey.episodeURL] as? URL,
            episodeURL: episode.url
        )
    }

}

struct PlayerContentAvailability: Sendable, Equatable {
    let episodeURL: URL
    let hasTranscript: Bool
    let hasChapterSelectionUI: Bool
    let hasUsableChapters: Bool
    /// A saved live-caption session exists. Read by the background query so
    /// the player never inspects `liveTranscriptData` while rendering.
    var hasSavedLiveTranscript: Bool = false
}


enum PlayerChapterRowPolicy {
    /// The player's chapter array is already selected/deduplicated for playback.
    /// Inspect only its count and first start; never fetch SwiftData relationships
    /// while the player is opening.
    static func hasSelectablePlaybackChapters(
        for episodeURL: URL?,
        activeEpisodeURL: URL?,
        chapterCount: Int?,
        firstStart: Double?
    ) -> Bool {
        guard let episodeURL, episodeURL == activeEpisodeURL else { return false }
        return (chapterCount ?? 0) > 1
            || (chapterCount == 1 && (firstStart ?? 0) > 0.5)
    }

    /// Chapter controls appear for a matching prepared snapshot or for the
    /// chapters the player already loaded for playback. A missing snapshot
    /// never falls back to a relationship fault during body evaluation.
    static func hasChapterSelectionUI(
        availability: PlayerContentAvailability?,
        episodeURL: URL?,
        hasPlaybackChapters: Bool
    ) -> Bool {
        if hasPlaybackChapters { return true }
        guard let availability, let episodeURL, availability.episodeURL == episodeURL else {
            return false
        }
        return availability.hasChapterSelectionUI
    }

    /// A missing availability snapshot is *unknown*, not "no transcript/chapters".
    /// An active playback chapter set must also override a stale negative query.
    static func generationAction(
        availability: PlayerContentAvailability?,
        hasPlaybackChapters: Bool,
        aiAvailable: Bool
    ) -> EpisodeAIGenerationAction? {
        guard let availability else { return nil }
        return EpisodeAIGenerationPolicy.action(
            isAvailable: aiAvailable,
            hasTranscript: availability.hasTranscript,
            hasUsableChapters: availability.hasUsableChapters || hasPlaybackChapters
        )
    }
}

private actor PlayerContentAvailabilitySnapshotCache {
    static let shared = PlayerContentAvailabilitySnapshotCache()

    private var snapshots: [URL: PlayerContentAvailability] = [:]
    private var order: [URL] = []
    private let limit = 24

    func snapshot(for episodeURL: URL) -> PlayerContentAvailability? {
        snapshots[episodeURL]
    }

    func store(_ snapshot: PlayerContentAvailability) {
        snapshots[snapshot.episodeURL] = snapshot
        order.removeAll { $0 == snapshot.episodeURL }
        order.append(snapshot.episodeURL)
        if order.count > limit {
            let evictedURL = order.removeFirst()
            snapshots.removeValue(forKey: evictedURL)
        }
    }

    func invalidate(episodeURL: URL) {
        snapshots.removeValue(forKey: episodeURL)
        order.removeAll { $0 == episodeURL }
    }
}

@ModelActor
actor PlayerContentAvailabilityModelActor {
    func availability(for episodeURL: URL) async -> PlayerContentAvailability {
        if let cached = await PlayerContentAvailabilitySnapshotCache.shared.snapshot(for: episodeURL) {
            os_signpost(.event, log: PlayerOpeningPerformance.log, name: "Player availability cache hit")
            return cached
        }

        let signpostID = OSSignpostID(log: PlayerOpeningPerformance.log)
        os_signpost(.begin, log: PlayerOpeningPerformance.log, name: "Player availability query", signpostID: signpostID)
        defer { os_signpost(.end, log: PlayerOpeningPerformance.log, name: "Player availability query", signpostID: signpostID) }

        let episodeDescriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.url == episodeURL }
        )
        let episode = (try? modelContext.fetch(episodeDescriptor))?.first

        // Query children by the episode's foreign key. An optional-chained
        // `$0.episode?.url` predicate compiles to CASE…END and scans the whole
        // transcript/marker table.
        var hasTranscript = false
        var markers: [Marker] = []
        if let episodeID = episode?.persistentModelID {
            var transcriptDescriptor = FetchDescriptor<TranscriptLineAndTime>(
                predicate: #Predicate { $0.episode != nil && $0.episode!.persistentModelID == episodeID }
            )
            transcriptDescriptor.fetchLimit = 1
            hasTranscript = ((try? modelContext.fetchCount(transcriptDescriptor)) ?? 0) > 0

            let markerDescriptor = FetchDescriptor<Marker>(
                predicate: #Predicate { $0.episode != nil && $0.episode!.persistentModelID == episodeID }
            )
            markers = (try? modelContext.fetch(markerDescriptor)) ?? []
        }
        let displayChapters = episode?.chaptersForDisplay(from: markers) ?? []
        let hasChapterSelectionUI = displayChapters.count > 1
            || (displayChapters.first?.start ?? 0) > 0.5
        let hasUsableChapters = hasChapterSelectionUI
            || markers.contains(where: { $0.type == .soundbite })
        let snapshot = PlayerContentAvailability(
            episodeURL: episodeURL,
            hasTranscript: hasTranscript,
            hasChapterSelectionUI: hasChapterSelectionUI,
            hasUsableChapters: hasUsableChapters,
            hasSavedLiveTranscript: episode?.liveTranscriptData != nil
        )

        await PlayerContentAvailabilitySnapshotCache.shared.store(snapshot)
        return snapshot
    }

    func invalidate(episodeURL: URL) async {
        await PlayerContentAvailabilitySnapshotCache.shared.invalidate(episodeURL: episodeURL)
        await PlayerTranscriptSnapshotCache.shared.invalidate(episodeURL: episodeURL)
    }
}

private actor PlayerTranscriptSnapshotCache {
    static let shared = PlayerTranscriptSnapshotCache()

    private var snapshots: [URL: TranscriptPreparedSnapshot] = [:]
    private var order: [URL] = []
    private let limit = 2

    func snapshot(for episodeURL: URL) -> TranscriptPreparedSnapshot? {
        snapshots[episodeURL]
    }

    func store(_ snapshot: TranscriptPreparedSnapshot, for episodeURL: URL) {
        snapshots[episodeURL] = snapshot
        order.removeAll { $0 == episodeURL }
        order.append(episodeURL)
        if order.count > limit {
            let evictedURL = order.removeFirst()
            snapshots.removeValue(forKey: evictedURL)
        }
    }

    func invalidate(episodeURL: URL) {
        snapshots.removeValue(forKey: episodeURL)
        order.removeAll { $0 == episodeURL }
    }
}

@ModelActor
actor PlayerTranscriptModelActor {
    func preparedSnapshot(for episodeURL: URL) async throws -> TranscriptPreparedSnapshot? {
        if let cached = await PlayerTranscriptSnapshotCache.shared.snapshot(for: episodeURL) {
            os_signpost(.event, log: PlayerOpeningPerformance.log, name: "Transcript snapshot cache hit")
            return cached
        }

        let signpostID = OSSignpostID(log: PlayerOpeningPerformance.log)
        os_signpost(.begin, log: PlayerOpeningPerformance.log, name: "Transcript snapshot load", signpostID: signpostID)
        defer {
            os_signpost(.end, log: PlayerOpeningPerformance.log, name: "Transcript snapshot load", signpostID: signpostID)
        }

        var episodeDescriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.url == episodeURL }
        )
        episodeDescriptor.fetchLimit = 1
        guard let episodeID = try modelContext.fetch(episodeDescriptor).first?.persistentModelID else {
            return nil
        }
        // Foreign-key predicate so SQLite can use the episode index.
        let descriptor = FetchDescriptor<TranscriptLineAndTime>(
            predicate: #Predicate { $0.episode != nil && $0.episode!.persistentModelID == episodeID },
            sortBy: [SortDescriptor(\.startTime)]
        )
        let sources = try modelContext.fetch(descriptor).map { line in
            TranscriptSegmentSource(
                id: line.id,
                speaker: line.speaker,
                text: line.text,
                startTime: line.startTime,
                endTime: line.endTime,
                sourceRawValue: line.sourceRawValue,
                timedSpans: line.timedSpans
            )
        }
        guard sources.isEmpty == false else { return nil }

        let snapshot = TranscriptPreparedSnapshot.make(from: sources, sourcesAreSorted: true)
        os_signpost(
            .event,
            log: PlayerOpeningPerformance.log,
            name: "Transcript snapshot prepared",
            "lines=%{public}ld segments=%{public}ld publisher=%{public}s",
            sources.count,
            snapshot.segments.count,
            snapshot.sourceMetadata.usesPublisherAlignment ? "true" : "false"
        )
        await PlayerTranscriptSnapshotCache.shared.store(snapshot, for: episodeURL)
        return snapshot
    }
}

private enum PlayerContentTab: String, CaseIterable, Identifiable {
    case shownotes
    case transcript
    case chapters
    case upNext

    var id: Self { self }

    var title: String {
        switch self {
        case .shownotes: "Shownotes"
        case .transcript: "Transcript"
        case .chapters: "Chapters"
        case .upNext: "Up Next"
        }
    }
}

private struct PlayerShownotesView: View {
    let episode: Episode
    @State private var revision = 0

    var body: some View {
        let _ = revision
        ShownoteContentView(
            html: episode.content ?? episode.desc ?? "",
            episodeURL: episode.url,
            episodeTitle: episode.title
        )
        .modifier(EpisodeReferenceRevisionModifier(episodeURL: episode.url, revision: $revision))
    }
}

/// The More menu builds its share URL from the playback position, so it lives
/// in its own view: playback ticks rebuild this menu, not the player (#520).
private struct PlayerMoreActionsMenu: View {
    let episode: Episode
    private var player: Player { .shared }

    var body: some View {
        Menu {
            if let episodeLink = episode.link {
                Link(destination: episodeLink) {
                    Label("Open Episode Website", systemImage: "safari")
                }
            }

            if let url = episode.deeplinks?.first ?? episode.link {
                ShareLink(item: positionedURL(for: url)) {
                    Label("Share at Current Position", systemImage: "square.and.arrow.up")
                }
            }

            if player.canSwitchCurrentEpisodeMedia {
                Button {
                    Task { await player.switchCurrentEpisodeMedia() }
                } label: {
                    Label(
                        player.currentPlaybackIsVideo ? "Switch to Audio" : "Switch to Video",
                        systemImage: player.currentPlaybackIsVideo ? "waveform" : "play.rectangle"
                    )
                }
            }

            if ListenTogetherController.shared.isInSession {
                Button {
                    ListenTogetherController.shared.leave()
                } label: {
                    Label("Leave SharePlay", systemImage: "shareplay.slash")
                }
            } else if let activity = ListenTogetherActivity(episode: episode) {
                ShareLink(
                    item: ListenTogetherInvitation(activity: activity),
                    preview: SharePreview(episode.title)
                ) {
                    Label("Listen Together", systemImage: "shareplay")
                }
            }

#if DEBUG
            NavigationLink(destination: EpisodeDebugMetadataView(episode: episode)) {
                Label("Episode Debug Metadata", systemImage: "ladybug")
            }
#endif
        } label: {
            Label("More", systemImage: "ellipsis")
                .labelStyle(.titleAndIcon)
            
        }
      
        .accessibilityLabel("More episode actions")
        .accessibilityHint("Opens website, sharing, media, and developer actions")
    }

    private func positionedURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "t" }
        queryItems.append(URLQueryItem(name: "t", value: "\(Int(player.playPosition))"))
        components.queryItems = queryItems
        return components.url ?? url
    }
}

/// Chapter tab content. It reads the chapter relationship only while the tab is
/// visible and re-reads it on this episode's reference/chapter revisions.
private struct PlayerChaptersTabContent: View {
    let episode: Episode
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let chapterMarkers = episode.chapters ?? []
        Group {
            if hasDisplayableChapters(in: chapterMarkers, for: episode) {
                ChapterListView(
                    episode: episode,
                    showsTitle: false,
                    markersOverride: chapterMarkers
                )
            } else {
                missingChaptersView
            }
        }
        .modifier(EpisodeReferenceRevisionModifier(
            episodeURL: episode.url,
            includesChapterData: true,
            revision: $revision
        ))
    }

    private var missingChaptersView: some View {
        ContentUnavailableView {
            Label("No Chapters", systemImage: "list.bullet.rectangle")
        } description: {
            Text("Generate a transcript and use it to create chapter markers.")
        } actions: {
            Text("Use the chapter row to generate chapters on this device.")
        }
    }

    private func hasDisplayableChapters(in markers: [Marker], for episode: Episode) -> Bool {
        if markers.contains(where: { $0.type == .soundbite }) {
            return true
        }

        let displayChapters = episode.chaptersForDisplay(from: markers)
        return displayChapters.count > 1 || (displayChapters.first?.start ?? 0) > 0.5
    }
}


#Preview {
    @Previewable @State var fullSize: Bool = false
    let episode = Episode(
        title: "Test Episode",
        url: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!,
        podcast: Podcast(feed: URL(string: "https://www.apple.com/podcasts/feed/id1491111222")!)
    )
    let _: () = Player.shared.currentEpisode = episode

    Toggle("Full Size", isOn: $fullSize)
    PlayerView(fullSize: fullSize)
}
