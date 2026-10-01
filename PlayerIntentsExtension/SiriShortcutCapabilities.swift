import AppIntents
import SwiftUI

struct SiriShortcutCapability: Identifiable {
    enum Category: String, CaseIterable {
        case playback = "Playback"
        case queue = "Queue & Playlists"
        case listening = "Listening"
        case episodes = "Episode Actions"
        case podcasts = "Podcasts"
        case automation = "Automation & Sharing"

        var localizedTitle: LocalizedStringResource {
            LocalizedStringResource(stringLiteral: rawValue)
        }
    }

    enum Surface: String {
        case siri = "Siri"
        case shortcuts = "Shortcuts"
        case both = "Siri & Shortcuts"

        var localizedTitle: LocalizedStringResource {
            LocalizedStringResource(stringLiteral: rawValue)
        }
    }

    let id: String
    let title: LocalizedStringResource
    let summary: LocalizedStringResource
    let systemImage: String
    let examples: [LocalizedStringResource]
    let category: Category
    let surface: Surface
    let minimumOS: Int?
}

enum SiriShortcutCapabilityCatalog {
    static var available: [SiriShortcutCapability] {
        var capabilities: [SiriShortcutCapability] = [
            .init(id: "resume", title: "Resume Playback", summary: "Continue the current or most recent episode.", systemImage: "play.circle", examples: ["Resume playback in Up Next"], category: .playback, surface: .both, minimumOS: nil),
            .init(id: "pause", title: "Pause Playback", summary: "Pause the active episode.", systemImage: "pause.circle", examples: ["Pause playback in Up Next"], category: .playback, surface: .both, minimumOS: nil),
            .init(id: "skip", title: "Skip Forward or Backward", summary: "Use the configured skip intervals.", systemImage: "arrow.forward.circle", examples: ["Skip forward in Up Next", "Skip back in Up Next"], category: .playback, surface: .both, minimumOS: nil),
            .init(id: "play-queue", title: "Play Up Next", summary: "Start the first episode in the Up Next queue.", systemImage: "text.line.first.and.arrowtriangle.forward", examples: ["Play Up Next"], category: .playback, surface: .both, minimumOS: nil),
            .init(id: "play-episode", title: "Play an Episode", summary: "Play a selected episode from your library.", systemImage: "play.circle", examples: ["Play this episode in Up Next"], category: .playback, surface: .both, minimumOS: nil),
            .init(id: "play-latest", title: "Play the Latest Episode", summary: "Play the newest episode of a podcast.", systemImage: "sparkles", examples: ["Play the latest episode of this podcast"], category: .playback, surface: .both, minimumOS: nil),
            .init(id: "speed", title: "Playback Speed", summary: "Set the same playback rate used by the player.", systemImage: "gauge.with.dots.needle.50percent", examples: ["Play Up Next at 1.5 times"], category: .playback, surface: .both, minimumOS: nil),
            .init(id: "chapters", title: "Chapter Navigation", summary: "Move to the next, previous, or current chapter.", systemImage: "bookmark", examples: ["Next chapter in Up Next", "Restart this chapter in Up Next"], category: .playback, surface: .both, minimumOS: nil),
            .init(id: "add-queue", title: "Add an Episode to Up Next", summary: "Put an episode first or last in the queue.", systemImage: "text.badge.plus", examples: ["Play this episode next in Up Next"], category: .queue, surface: .both, minimumOS: nil),
            .init(id: "move-remove", title: "Move or Remove the Current Episode", summary: "Clean up the active queue item.", systemImage: "list.bullet.indent", examples: ["Move this episode to the end in Up Next"], category: .queue, surface: .both, minimumOS: nil),
            .init(id: "bookmark", title: "Create a Bookmark", summary: "Save the current playback position.", systemImage: "bookmark", examples: ["Bookmark this in Up Next"], category: .listening, surface: .both, minimumOS: nil),
            .init(id: "sleep", title: "Sleep Timer", summary: "Stop after a duration or after the current episode.", systemImage: "zzz", examples: ["Stop Up Next in 20 minutes", "Stop Up Next after this episode"], category: .listening, surface: .both, minimumOS: nil),
            .init(id: "now-playing", title: "Ask What Is Playing", summary: "Return structured now-playing details for Siri or Shortcuts.", systemImage: "waveform", examples: ["What am I listening to in Up Next?"], category: .listening, surface: .both, minimumOS: nil),
            .init(id: "up-next-query", title: "Ask What Is Next", summary: "Return the ordered Up Next queue.", systemImage: "text.line.3.horizontal", examples: ["What is next in Up Next?"], category: .listening, surface: .both, minimumOS: nil),
            .init(id: "played", title: "Mark Episode Played", summary: "Mark the current or selected episode as played.", systemImage: "checkmark.circle", examples: ["Mark this played in Up Next"], category: .episodes, surface: .both, minimumOS: nil),
            .init(id: "archive", title: "Archive or Unarchive Episode", summary: "Manage an episode's inbox and archive state.", systemImage: "archivebox", examples: ["Archive this episode in Up Next"], category: .episodes, surface: .both, minimumOS: nil),
            .init(id: "download", title: "Download Episode", summary: "Start the normal Up Next download flow.", systemImage: "arrow.down.circle", examples: ["Download this episode in Up Next"], category: .episodes, surface: .shortcuts, minimumOS: nil),
            .init(id: "refresh-one", title: "Refresh One Podcast", summary: "Refresh a selected subscribed feed without refreshing the library.", systemImage: "arrow.clockwise", examples: ["Refresh this podcast in Up Next"], category: .podcasts, surface: .both, minimumOS: nil),
            .init(id: "subscribe", title: "Subscribe from a URL", summary: "Resolve and subscribe to a podcast feed or podcast page.", systemImage: "plus.circle", examples: [], category: .podcasts, surface: .shortcuts, minimumOS: nil),
            .init(id: "live", title: "Live Podcast Discovery and Playback", summary: "Find current live subscribed podcasts and play or stop them.", systemImage: "dot.radiowaves.left.and.right", examples: ["What podcasts are live in Up Next?"], category: .podcasts, surface: .both, minimumOS: nil),
            .init(id: "transcript", title: "Retrieve or Generate a Transcript", summary: "Use transcript text as a Shortcuts file or request the existing transcription pipeline.", systemImage: "captions.bubble", examples: [], category: .automation, surface: .shortcuts, minimumOS: nil),
            .init(id: "share-image", title: "Generate a Podcast Share Image", summary: "Create a listening-statistics PNG for later Shortcuts actions.", systemImage: "photo", examples: [], category: .automation, surface: .shortcuts, minimumOS: nil),
            .init(id: "clip", title: "Export a Podcast Clip", summary: "Export a clip from the current local episode.", systemImage: "scissors", examples: ["Export a clip from Up Next"], category: .automation, surface: .shortcuts, minimumOS: nil)
        ]

        capabilities.append(.init(id: "playlist", title: "Named Playlist Actions", summary: "Add, remove, list, and play episodes in a named playlist.", systemImage: "list.bullet.rectangle", examples: ["Play my Commute playlist in Up Next"], category: .queue, surface: .both, minimumOS: nil))

        if #available(iOS 27.0, macOS 27.0, *) {
            capabilities.append(.init(id: "bulk-queue", title: "Add Multiple Episodes to Up Next", summary: "Add an entity collection while preserving its order.", systemImage: "text.badge.plus", examples: [], category: .queue, surface: .shortcuts, minimumOS: 27))
            capabilities.append(.init(id: "audio-schema-playlist", title: "Audio Schema Playlist Actions", summary: "Use the iOS/macOS 27 Audio App Schema for playlist additions.", systemImage: "wand.and.stars", examples: [], category: .queue, surface: .both, minimumOS: 27))
        }
        return capabilities
    }
}

@MainActor
enum SiriShortcutVocabularyCoordinator {
    private static var refreshTask: Task<Void, Never>?
    private static var observerTokens: [NSObjectProtocol] = []

    static func start() {
        guard observerTokens.isEmpty else {
            scheduleRefresh()
            return
        }
        let center = NotificationCenter.default
        for name in [Notification.Name("inboxDidChange"), Notification.Name("podcastSettingsDidChange")] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in scheduleRefresh() }
            })
        }
        scheduleRefresh()
    }

    static func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard Task.isCancelled == false else { return }
            BookmarkCurrentPlaybackShortcut.updateAppShortcutParameters()
        }
    }
}

struct SiriShortcutsGuideView: View {
    private var groupedCapabilities: [(SiriShortcutCapability.Category, [SiriShortcutCapability])] {
        SiriShortcutCapability.Category.allCases.compactMap { category in
            let values = SiriShortcutCapabilityCatalog.available.filter { $0.category == category }
            return values.isEmpty ? nil : (category, values)
        }
    }

    var body: some View {
        List {
            Section {
                Text("Siri wording can vary. The examples below are suggestions; the same capabilities are also available as actions in Shortcuts.")
                    .font(.subheadline)
            }
            ForEach(groupedCapabilities, id: \.0) { group in
                SiriShortcutCapabilitySection(category: group.0, capabilities: group.1)
            }
        }
#if os(macOS)
        .listStyle(.inset)
#else
        .listStyle(.insetGrouped)
#endif
        .navigationTitle("Siri & Shortcuts")
        .platformInlineNavigationTitle()
    }
}

private struct SiriShortcutCapabilitySection: View {
    let category: SiriShortcutCapability.Category
    let capabilities: [SiriShortcutCapability]

    var body: some View {
        Section {
            ForEach(capabilities) { capability in
                VStack(alignment: .leading, spacing: 7) {
                    Label {
                        Text(capability.title)
                    } icon: {
                        Image(systemName: capability.systemImage)
                    }
                    .font(.headline)
                    Text(capability.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(capability.surface.localizedTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                    ForEach(Array(capability.examples.enumerated()), id: \.offset) { _, example in
                        Text(example)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text(category.localizedTitle)
        }
    }
}
