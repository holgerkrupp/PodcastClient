import SwiftUI
import SwiftData

struct TranscriptSearchNavigation: Hashable, Sendable {
    let episodeID: String
    let timestamp: TimeInterval
    let query: String
}

private struct TranscriptDisplayRow: Identifiable, Sendable {
    let segment: TranscriptSegment
    let id: UUID
    let speaker: String?
    let showsSpeaker: Bool
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
}

struct TranscriptListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Bindable private var synchronizationStore = TranscriptSynchronizationStore.shared
    let preparedSnapshot: TranscriptPreparedSnapshot
    /// Captured once with the transcript snapshot; row rendering must not scan
    /// SwiftData models for transcript-global metadata.
    let usesPublisherAlignment: Bool
    let episode: Episode?
    let searchNavigation: TranscriptSearchNavigation?
    let canFollowPlayback: Bool

    @Bindable private var player = Player.shared
    @State private var searchText: String
    @State private var followPlayback: Bool
    @State private var displayRows: [TranscriptDisplayRow]
    @State private var speakerColorMap: [String: Color]
    @State private var isPreparingRows: Bool
    @State private var selectedSearchRowID: UUID?
    @State private var tracker = TranscriptPlaybackTracker()
    @State private var passageSelectionMode = false
    @State private var selectionActive = false
    @State private var frozenActive: TranscriptPlaybackTracker.Active?
    @State private var pendingRowsUpdate = false

    init(
        preparedSnapshot: TranscriptPreparedSnapshot,
        episode: Episode? = nil,
        searchText: String = "",
        startFollowingPlayback: Bool = false,
        searchNavigation: TranscriptSearchNavigation? = nil,
        canFollowPlayback: Bool = true
    ) {
        let initialSearchText = searchNavigation?.query.isEmpty == false
            ? searchNavigation!.query
            : searchText
        self.preparedSnapshot = preparedSnapshot
        self.usesPublisherAlignment = preparedSnapshot.sourceMetadata.usesPublisherAlignment
        self.episode = episode
        self.searchNavigation = searchNavigation
        self.canFollowPlayback = canFollowPlayback
        _searchText = State(initialValue: initialSearchText)
        _followPlayback = State(initialValue: startFollowingPlayback)
        _displayRows = State(initialValue: [])
        _speakerColorMap = State(initialValue: [:])
        _isPreparingRows = State(initialValue: true)
    }

    init(
        transcriptLines: [TranscriptLineAndTime],
        episode: Episode? = nil,
        searchText: String = "",
        startFollowingPlayback: Bool = false,
        searchNavigation: TranscriptSearchNavigation? = nil,
        canFollowPlayback: Bool = true
    ) {
        let sources = transcriptLines.map {
            TranscriptSegmentSource(
                id: $0.id,
                speaker: $0.speaker,
                text: $0.text,
                startTime: $0.startTime,
                endTime: $0.endTime,
                sourceRawValue: $0.sourceRawValue,
                timedSpans: $0.timedSpans
            )
        }
        self.init(
            preparedSnapshot: TranscriptPreparedSnapshot.make(from: sources),
            episode: episode,
            searchText: searchText,
            startFollowingPlayback: startFollowingPlayback,
            searchNavigation: searchNavigation,
            canFollowPlayback: canFollowPlayback
        )
    }

    private static let speakerColors: [Color] = [
        .blue,
        .green,
        .orange,
        .purple,
        .red,
        .teal
    ]

    private var viewedEpisode: Episode? {
        episode
    }

    private var viewedEpisodeURL: URL? {
        viewedEpisode?.url
    }

    private var isShowingCurrentEpisode: Bool {
        guard canFollowPlayback, let viewedEpisodeURL else { return false }
        return player.currentEpisodeURL == viewedEpisodeURL
    }

    private var activeDisplayRowID: UUID? {
        (selectionActive ? frozenActive : tracker.active)?.segmentID
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField("Search captions…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    passageSelectionMode.toggle()
                    if passageSelectionMode {
                        frozenActive = tracker.active
                        selectionActive = true
                        followPlayback = false
                    } else {
                        selectionActive = false
                        if pendingRowsUpdate {
                            pendingRowsUpdate = false
                            rebuildDisplayRows()
                        }
                    }
                } label: {
                    Label(passageSelectionMode ? "Done Copying" : "Select Passage", systemImage: "text.cursor")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass(.clear))
                .accessibilityHint("Select and copy words across multiple transcript lines without changing playback")

                if (isShowingCurrentEpisode || selectionActive) && !passageSelectionMode {
                    Button {
                        let wasSelecting = selectionActive
                        selectionActive = false
                        if pendingRowsUpdate {
                            pendingRowsUpdate = false
                            rebuildDisplayRows()
                        }
                        if isShowingCurrentEpisode {
                            followPlayback = wasSelecting ? true : !followPlayback
                        }
                    } label: {
                        Label(selectionActive && !isShowingCurrentEpisode ? "Done Selecting" : (followPlayback ? "Following" : "Follow"), systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(followPlayback ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.glass(.clear))
                    .help(followPlayback ? "Stop following playback" : "Keep the current transcript line centered")
                    .accessibilityLabel(selectionActive && !isShowingCurrentEpisode ? "Done selecting" : (followPlayback ? "Following playback" : "Follow playback"))
                    .accessibilityHint(isShowingCurrentEpisode ? "Keeps captions centered around the current playback time" : "Resumes transcript updates")
                    .accessibilityInputLabels([Text("Follow captions"), Text("Follow playback")])
                }
            }
            .padding()

            if isShowingCurrentEpisode && usesPublisherAlignment && synchronizationStore.isEnabled
                && (!synchronizationStore.hasVerifiedTimeline(for: viewedEpisodeURL)
                    || synchronizationStore.isUnverifiedAudioTime(player.playPosition, episodeURL: viewedEpisodeURL)) {
                Label("Transcript timing could not be verified for this audio.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    if passageSelectionMode {
                        Text(displayRows.map(\.text).joined(separator: "\n"))
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else if isPreparingRows {
                        ProgressView("Preparing transcript…")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if displayRows.isEmpty {
                        ContentUnavailableView("No Matching Transcript", systemImage: "magnifyingglass")
                            .padding(.top, 60)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(displayRows) { row in
                                transcriptRow(row)
                                    .id(row.id)
                                    .padding(.horizontal)
                            }
                        }
                        .padding(.bottom)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { _ in
                            guard followPlayback else { return }
                            followPlayback = false
                        }
                )
                .onAppear {
                    if canFollowPlayback {
                        tracker.start(segments: displayRows.map(\.segment), episodeURL: viewedEpisodeURL, useAlignment: usesPublisherAlignment)
                    }
                    scrollToInitialLocation(with: proxy)
                }
                .task(id: preparedSnapshot) {
                    await prepareDisplayRows()
                }
        .onAppear {
            PlayerOpeningPerformance.event("Transcript surface visible")
        }
                .onDisappear { tracker.stop() }
                .onChange(of: player.playPosition) { tracker.refresh() }
                .onChange(of: player.currentEpisodeURL) { tracker.refresh() }
                .onChange(of: canFollowPlayback) {
                    if canFollowPlayback {
                        tracker.start(segments: displayRows.map(\.segment), episodeURL: viewedEpisodeURL, useAlignment: usesPublisherAlignment)
                    } else { tracker.stop() }
                }
                .onChange(of: searchText) {
                    if selectionActive { pendingRowsUpdate = true } else { rebuildDisplayRows() }
                }
                .onChange(of: preparedSnapshot) {
                    if selectionActive {
                        pendingRowsUpdate = true
                    } else {
                        isPreparingRows = true
                    }
                }
                .onChange(of: isPreparingRows) {
                    guard isPreparingRows == false else { return }
                    scrollToInitialLocation(with: proxy)
                }
                .onChange(of: activeDisplayRowID) {
                    scrollToActiveRow(with: proxy, animated: false)
                }
                .onChange(of: followPlayback) {
                    scrollToActiveRow(with: proxy, animated: true)
                }
                .onChange(of: selectedSearchRowID) {
                    guard let selectedSearchRowID else { return }
                    proxy.scrollTo(selectedSearchRowID, anchor: .center)
                }
            }
        }
        .toolbar {
            if searchText.isEmpty == false, displayRows.isEmpty == false {
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button {
                        moveSearchMatch(by: -1)
                    } label: {
                        Label("Previous match", systemImage: "chevron.up")
                    }
                    .accessibilityLabel("Previous transcript match")

                    Button {
                        moveSearchMatch(by: 1)
                    } label: {
                        Label("Next match", systemImage: "chevron.down")
                    }
                    .accessibilityLabel("Next transcript match")
                }
            }
        }
    }

    private func transcriptRow(_ row: TranscriptDisplayRow) -> some View {
        let isActive = row.id == activeDisplayRowID
        let isFocusedSearchMatch = row.id == selectedSearchRowID
        let canSeek = !usesPublisherAlignment || !synchronizationStore.isEnabled
            || synchronizationStore.audioTime(forTranscriptTime: row.startTime, episodeURL: viewedEpisodeURL) != nil
        let caption = row.segment.highlightedText(selectionActive ? frozenActive : tracker.active)
        let displayedCaption = !searchText.isEmpty && TranscriptSearchText.matches(row.text, query: searchText)
            ? caption.underline() : caption

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    Task {
                        await playTranscript(at: row.startTime)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: playbackIcon(isActive: isActive))
                            .font(.caption2.weight(.bold))
                        Text(formatTime(row.startTime))
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canFollowPlayback || !canSeek)
                .accessibilityLabel("Play from \(formatTime(row.startTime))")
                .accessibilityHint(!canFollowPlayback ? "Start live transcription to verify timing for this audio" : (canSeek ? "Starts playback from this caption line" : "Timing is not verified for this passage"))
                .accessibilityInputLabels([Text("Play from \(formatTime(row.startTime))"), Text("Play caption")])

                if row.showsSpeaker, let speaker = row.speaker {
                    Text("\(speaker):")
                        .font(.headline)
                        .foregroundColor(differentiateWithoutColor ? .primary : (speakerColorMap[speaker] ?? .accent))
                }

                if isActive && differentiateWithoutColor {
                    Label("Current", systemImage: "speaker.wave.2.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

#if canImport(UIKit)
            SelectableTranscriptText(
                segment: row.segment,
                active: selectionActive ? frozenActive : tracker.active,
                underlineForSearch: !searchText.isEmpty && TranscriptSearchText.matches(row.text, query: searchText),
                onSelectionChange: { selecting in
                    if selecting && !selectionActive {
                        frozenActive = tracker.active
                        selectionActive = true
                        followPlayback = false
                    } else if !selecting && selectionActive {
                        selectionActive = false
                        if pendingRowsUpdate {
                            pendingRowsUpdate = false
                            rebuildDisplayRows()
                        }
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
#else
            displayedCaption
                .font(.body)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.25).onEnded { _ in
                    frozenActive = tracker.active
                    selectionActive = true
                    followPlayback = false
                })
#endif
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(differentiateWithoutColor ? 0.08 : 0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isActive
                        ? Color.accentColor.opacity(differentiateWithoutColor ? 0.8 : 0.45)
                        : isFocusedSearchMatch
                            ? Color.accentColor.opacity(0.75)
                        : Color.secondary.opacity(differentiateWithoutColor ? 0.35 : 0.15),
                    lineWidth: (differentiateWithoutColor && isActive) || isFocusedSearchMatch ? 2 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Caption \(formatTime(row.startTime))")
        .accessibilityValue(row.speaker == nil ? row.text : "\(row.speaker!), \(row.text)")
    }

    private func playbackIcon(isActive: Bool) -> String {
        if isActive && player.isPlaying && isShowingCurrentEpisode {
            return "speaker.wave.2.fill"
        }
        return "play.fill"
    }

    private func scrollToActiveRow(with proxy: ScrollViewProxy, animated: Bool = true) {
        guard followPlayback, !selectionActive, let activeDisplayRowID else { return }

        if animated && !reduceMotion {
            withAnimation(.snappy(duration: 0.18, extraBounce: 0.0)) {
                proxy.scrollTo(activeDisplayRowID, anchor: .center)
            }
        } else {
            proxy.scrollTo(activeDisplayRowID, anchor: .center)
        }
    }

    private func scrollToInitialLocation(with proxy: ScrollViewProxy) {
        if let searchNavigation,
           let row = displayRows.first(where: { row in
               row.startTime <= searchNavigation.timestamp
                   && (row.endTime ?? .greatestFiniteMagnitude) > searchNavigation.timestamp
           }) ?? displayRows.min(by: {
               abs($0.startTime - searchNavigation.timestamp) < abs($1.startTime - searchNavigation.timestamp)
           }) {
            proxy.scrollTo(row.id, anchor: .center)
            return
        }
        scrollToActiveRow(with: proxy, animated: false)
    }

    @MainActor
    private func playTranscript(at time: TimeInterval) async {
        guard let audioTime = (usesPublisherAlignment ? synchronizationStore.audioTime(
            forTranscriptTime: time,
            episodeURL: viewedEpisodeURL
        ) : time) else { return }
        guard let viewedEpisodeURL else {
            await player.jumpTo(time: audioTime)
            if player.isPlaying == false {
                player.play()
            }
            return
        }

        if player.currentEpisodeURL == viewedEpisodeURL {
            await player.jumpTo(time: audioTime)
            if player.isPlaying == false {
                player.play()
            }
        } else {
            await player.playEpisode(viewedEpisodeURL, playDirectly: true, startingAt: audioTime)
        }
    }

    private func formatTime(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func rebuildDisplayRows() {
        let rows = Self.makeDisplayRows(from: preparedSnapshot.segments, matching: searchText)
        displayRows = rows
        isPreparingRows = false
        tracker.update(segments: rows.map(\.segment), episodeURL: viewedEpisodeURL, useAlignment: usesPublisherAlignment)
        speakerColorMap = Self.makeSpeakerColorMap(from: rows)
        selectedSearchRowID = nil
    }

    private func prepareDisplayRows() async {
        let segments = preparedSnapshot.segments
        let query = searchText
        let rows = await Task.detached(priority: .userInitiated) {
            Self.makeDisplayRows(from: segments, matching: query)
        }.value
        guard Task.isCancelled == false else { return }
        displayRows = rows
        speakerColorMap = Self.makeSpeakerColorMap(from: rows)
        isPreparingRows = false
        if rows.isEmpty == false {
            PlayerOpeningPerformance.event("Transcript first row ready")
        }
        tracker.update(segments: rows.map(\.segment), episodeURL: viewedEpisodeURL, useAlignment: usesPublisherAlignment)
    }

    private func moveSearchMatch(by offset: Int) {
        guard displayRows.isEmpty == false else { return }
        let currentIndex = selectedSearchRowID.flatMap { id in
            displayRows.firstIndex { $0.id == id }
        } ?? (offset > 0 ? -1 : displayRows.count)
        let nextIndex = (currentIndex + offset + displayRows.count) % displayRows.count
        selectedSearchRowID = displayRows[nextIndex].id
    }

    nonisolated private static func makeDisplayRows(from segments: [TranscriptSegment], matching searchText: String) -> [TranscriptDisplayRow] {
        let filteredSegments: [TranscriptSegment]
        if searchText.isEmpty {
            filteredSegments = segments
        } else {
            filteredSegments = segments.filter { segment in
                TranscriptSearchText.matches(segment.text, query: searchText) ||
                (segment.speaker.map { TranscriptSearchText.matches($0, query: searchText) } ?? false)
            }
        }

        var rows: [TranscriptDisplayRow] = []
        rows.reserveCapacity(filteredSegments.count)

        var previousSpeaker: String?
        for segment in filteredSegments {
            rows.append(
                TranscriptDisplayRow(
                    segment: segment,
                    id: segment.id,
                    speaker: segment.speaker,
                    showsSpeaker: segment.speaker != previousSpeaker,
                    text: segment.text,
                    startTime: segment.startTime,
                    endTime: segment.endTime
                )
            )

            previousSpeaker = segment.speaker
        }

        return rows
    }

    private static func makeSpeakerColorMap(from rows: [TranscriptDisplayRow]) -> [String: Color] {
        var colorMap: [String: Color] = [:]
        let speakers = Array(Set(rows.compactMap(\.speaker))).sorted(by: <)

        for (index, speaker) in speakers.enumerated() {
            colorMap[speaker] = speakerColors[index % speakerColors.count]
        }

        return colorMap
    }

}

/// Loads and presents transcript values progressively so switching the player
/// to Transcript can render a useful state before SwiftData or segmentation
/// work completes.
struct TranscriptPane: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable private var liveTranscript = LiveTranscriptController.shared

    let episode: Episode
    let availability: PlayerContentAvailability?
    let startFollowingPlayback: Bool

    @State private var preparedSnapshot: TranscriptPreparedSnapshot?
    @State private var isLiveSnapshot = false
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var retryCount = 0

    private struct LoadID: Equatable {
        let episodeURL: URL?
        let refresh: Bool
        let availability: PlayerContentAvailability?
        let retryCount: Int
    }

    private var loadID: LoadID {
        LoadID(
            episodeURL: episode.url,
            refresh: episode.refresh,
            availability: availability,
            retryCount: retryCount
        )
    }

    var body: some View {
        Group {
            if let preparedSnapshot, preparedSnapshot.segments.isEmpty == false {
                VStack(spacing: isLiveSnapshot ? 12 : 0) {
                    if isLiveSnapshot {
                        TranscriptGenerationActionsView(episode: episode)
                        LiveTranscriptCoverageView(episode: episode)
                    }

                    TranscriptListView(
                        preparedSnapshot: preparedSnapshot,
                        episode: episode,
                        startFollowingPlayback: startFollowingPlayback,
                        canFollowPlayback: !isLiveSnapshot || liveTranscript.isActive(for: episode)
                    )
                }
            } else if isLoading {
                ProgressView("Loading transcript…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .accessibilityLabel("Loading transcript")
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Transcript Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The transcript could not be loaded. Playback remains available.")
                } actions: {
                    Button("Retry") { retryCount += 1 }
                }
            } else {
                TranscriptEmptyStateView(episode: episode)
            }
        }
        .task(id: loadID) {
            await loadTranscript()
        }
        .onChange(of: liveTranscript.cues.count) {
            guard isLiveSnapshot else { return }
            Task { await refreshLiveTranscript() }
        }
    }

    @MainActor
    private func loadTranscript() async {
        preparedSnapshot = nil
        isLiveSnapshot = false
        isLoading = true
        loadFailed = false

        guard episode.url != nil else {
            isLoading = false
            return
        }

        do {
            let worker = PlayerTranscriptModelActor(modelContainer: modelContext.container)
            if let snapshot = try await worker.preparedSnapshot(for: episode.url!) {
                guard Task.isCancelled == false else { return }
                preparedSnapshot = snapshot
                isLoading = false
                return
            }

            let liveSources = liveTranscript.displaySources(for: episode)
            if liveSources.isEmpty == false {
                let snapshot = await preparedLiveSnapshot(from: liveSources)
                guard Task.isCancelled == false else { return }
                preparedSnapshot = snapshot
                isLiveSnapshot = true
            }
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard Task.isCancelled == false else { return }
            loadFailed = true
            isLoading = false
        }
    }

    @MainActor
    private func refreshLiveTranscript() async {
        let liveSources = liveTranscript.displaySources(for: episode)
        guard liveSources.isEmpty == false else { return }
        let snapshot = await preparedLiveSnapshot(from: liveSources)
        guard Task.isCancelled == false else { return }
        preparedSnapshot = snapshot
        isLiveSnapshot = true
    }

    private func preparedLiveSnapshot(from sources: [TranscriptSegmentSource]) async -> TranscriptPreparedSnapshot {
        await Task.detached(priority: .userInitiated) {
            TranscriptPreparedSnapshot.make(from: sources, sourcesAreSorted: true)
        }.value
    }
}

#Preview {
    let sampleTranscriptLines: [TranscriptLineAndTime] = [
        TranscriptLineAndTime(
            speaker: "Daniel",
            text: "Dave, how do you feel about cold opens? I don't care. I'm going to open coldly.",
            startTime: 9.0,
            endTime: 15.0
        ),
        TranscriptLineAndTime(
            speaker: "Dave",
            text: "I support this energy.",
            startTime: 16.0,
            endTime: 20.0
        )
    ]

    TranscriptListView(transcriptLines: sampleTranscriptLines)
}
