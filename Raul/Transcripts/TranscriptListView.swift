import SwiftUI

private struct TranscriptDisplayRow: Identifiable {
    let id: UUID
    let lineID: UUID
    let speaker: String?
    let showsSpeaker: Bool
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
}

struct TranscriptListView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let transcriptLines: [TranscriptLineAndTime]
    let episode: Episode?

    @Bindable private var player = Player.shared
    @State private var searchText: String
    @State private var followPlayback: Bool
    @State private var displayRows: [TranscriptDisplayRow]
    @State private var speakerColorMap: [String: Color]
    @State private var lineToDisplayRowID: [UUID: UUID]

    init(
        transcriptLines: [TranscriptLineAndTime],
        episode: Episode? = nil,
        searchText: String = "",
        startFollowingPlayback: Bool = false
    ) {
        let sortedLines = transcriptLines.sorted { $0.startTime < $1.startTime }
        let initialRows = Self.makeDisplayRows(from: sortedLines, matching: searchText)

        self.transcriptLines = sortedLines
        self.episode = episode
        _searchText = State(initialValue: searchText)
        _followPlayback = State(initialValue: startFollowingPlayback)
        _displayRows = State(initialValue: initialRows)
        _speakerColorMap = State(initialValue: Self.makeSpeakerColorMap(from: initialRows))
        _lineToDisplayRowID = State(initialValue: Self.makeLineToDisplayRowID(from: initialRows))
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
        episode ?? transcriptLines.first?.episode
    }

    private var viewedEpisodeURL: URL? {
        viewedEpisode?.url
    }

    private var isShowingCurrentEpisode: Bool {
        guard let viewedEpisodeURL else { return false }
        return player.currentEpisodeURL == viewedEpisodeURL
    }

    private var activeTranscriptLineID: UUID? {
        guard isShowingCurrentEpisode, player.playPosition.isFinite else { return nil }
        return transcriptLineID(at: player.playPosition)
    }

    private var activeDisplayRowID: UUID? {
        guard let activeTranscriptLineID else { return nil }
        return lineToDisplayRowID[activeTranscriptLineID]
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

                if isShowingCurrentEpisode {
                    Button {
                        followPlayback.toggle()
                    } label: {
                        Label(followPlayback ? "Following" : "Follow", systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(followPlayback ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.glass(.clear))
                    .help(followPlayback ? "Stop following playback" : "Keep the current transcript line centered")
                    .accessibilityLabel(followPlayback ? "Following playback" : "Follow playback")
                    .accessibilityHint("Keeps captions centered around the current playback time")
                    .accessibilityInputLabels([Text("Follow captions"), Text("Follow playback")])
                }
            }
            .padding()

            ScrollViewReader { proxy in
                ScrollView {
                    if displayRows.isEmpty {
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
                    scrollToActiveRow(with: proxy, animated: false)
                }
                .onChange(of: searchText) {
                    rebuildDisplayRows()
                }
                .onChange(of: activeDisplayRowID) {
                    scrollToActiveRow(with: proxy, animated: false)
                }
                .onChange(of: followPlayback) {
                    scrollToActiveRow(with: proxy, animated: true)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(_ row: TranscriptDisplayRow) -> some View {
        let isActive = row.id == activeDisplayRowID

        VStack(alignment: .leading, spacing: 8) {
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
                .accessibilityLabel("Play from \(formatTime(row.startTime))")
                .accessibilityHint("Starts playback from this caption line")
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

            Text(row.text)
                .font(.body)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                        : Color.secondary.opacity(differentiateWithoutColor ? 0.35 : 0.15),
                    lineWidth: differentiateWithoutColor && isActive ? 2 : 1
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
        guard followPlayback, let activeDisplayRowID else { return }

        if animated && !reduceMotion {
            withAnimation(.snappy(duration: 0.18, extraBounce: 0.0)) {
                proxy.scrollTo(activeDisplayRowID, anchor: .center)
            }
        } else {
            proxy.scrollTo(activeDisplayRowID, anchor: .center)
        }
    }

    @MainActor
    private func playTranscript(at time: TimeInterval) async {
        guard let viewedEpisodeURL else {
            await player.jumpTo(time: time)
            if player.isPlaying == false {
                player.play()
            }
            return
        }

        if player.currentEpisodeURL == viewedEpisodeURL {
            await player.jumpTo(time: time)
            if player.isPlaying == false {
                player.play()
            }
        } else {
            await player.playEpisode(viewedEpisodeURL, playDirectly: true, startingAt: time)
        }
    }

    private func transcriptLineID(at time: TimeInterval) -> UUID? {
        guard transcriptLines.isEmpty == false else { return nil }

        var low = 0
        var high = transcriptLines.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let line = transcriptLines[mid]
            let endTime = effectiveEndTime(for: mid)

            if time < line.startTime {
                high = mid - 1
            } else if time >= endTime {
                low = mid + 1
            } else {
                return line.id
            }
        }

        let fallbackIndex = max(0, min(low - 1, transcriptLines.count - 1))
        return transcriptLines[fallbackIndex].id
    }

    private func effectiveEndTime(for index: Int) -> TimeInterval {
        if let endTime = transcriptLines[index].endTime {
            return endTime
        }

        if index + 1 < transcriptLines.count {
            return transcriptLines[index + 1].startTime
        }

        return .infinity
    }

    private func formatTime(_ timeInterval: TimeInterval) -> String {
        let minutes = Int(timeInterval) / 60
        let seconds = Int(timeInterval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func rebuildDisplayRows() {
        let rows = Self.makeDisplayRows(from: transcriptLines, matching: searchText)
        displayRows = rows
        speakerColorMap = Self.makeSpeakerColorMap(from: rows)
        lineToDisplayRowID = Self.makeLineToDisplayRowID(from: rows)
    }

    private static func makeDisplayRows(from lines: [TranscriptLineAndTime], matching searchText: String) -> [TranscriptDisplayRow] {
        let filteredLines: [TranscriptLineAndTime]
        if searchText.isEmpty {
            filteredLines = lines
        } else {
            filteredLines = lines.filter { line in
                line.text.localizedCaseInsensitiveContains(searchText) ||
                (line.speaker?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        var rows: [TranscriptDisplayRow] = []
        rows.reserveCapacity(filteredLines.count)

        var previousSpeaker: String?
        for line in filteredLines {
            rows.append(
                TranscriptDisplayRow(
                    id: line.id,
                    lineID: line.id,
                    speaker: line.speaker,
                    showsSpeaker: line.speaker != previousSpeaker,
                    text: line.text,
                    startTime: line.startTime,
                    endTime: line.endTime
                )
            )

            previousSpeaker = line.speaker
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

    private static func makeLineToDisplayRowID(from rows: [TranscriptDisplayRow]) -> [UUID: UUID] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.lineID, $0.id) })
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
