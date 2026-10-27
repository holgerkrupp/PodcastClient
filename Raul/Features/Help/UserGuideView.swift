import SwiftUI

private enum UserGuideCategory: String, CaseIterable, Identifiable {
    case start = "Getting started"
    case discover = "Discover podcasts"
    case playback = "Playback"
    case library = "Queue & playlists"
    case chapters = "Chapters & transcripts"
    case refresh = "Refresh & downloads"
    case sharing = "Bookmarks & sharing"
    case settings = "Settings & integrations"
    case help = "Troubleshooting"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .start: "sparkles"
        case .discover: "magnifyingglass"
        case .playback: "play.circle"
        case .library: "list.bullet.rectangle"
        case .chapters: "captions.bubble"
        case .refresh: "arrow.clockwise"
        case .sharing: "bookmark"
        case .settings: "slider.horizontal.3"
        case .help: "questionmark.circle"
        }
    }
}

private enum UserGuideAction: Hashable {
    case section(AppSection, title: String)
    case siri
    case player
}

private struct UserGuideTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let category: UserGuideCategory
    let aliases: [String]
    let summary: String
    let steps: [String]
    let example: String
    let options: String
    let action: UserGuideAction?
    let related: [String]

    var searchableText: String {
        ([title, summary, example, options] + aliases + steps).joined(separator: " ")
    }
}

private enum UserGuideRegistry {
    static let topics: [UserGuideTopic] = [
        .init(id: "first-listen", title: "From a new show to listening", category: .start,
              aliases: ["first podcast", "subscribe", "new episode", "workflow"],
              summary: "Up Next keeps newly found episodes, your listening queue, and your subscribed shows in separate places.",
              steps: ["Open Add and search for a show, or paste its website or RSS feed address.", "Subscribe to the show. New episodes appear in Inbox when they are found.", "Add an episode from Inbox to Up Next or a playlist, then tap it to play."],
              example: "Inbox is a place to review new episodes. Up Next is the ordered list the player uses for what plays next.",
              options: "The tabs or sidebar depend on the available window width. On iPad and Mac, navigation may appear as a sidebar.", action: .section(.search, title: "Open Add"), related: ["queue-inbox", "subscribe"]),
        .init(id: "queue-inbox", title: "Inbox, Up Next, and Library", category: .start,
              aliases: ["queue", "inbox", "library", "played", "archive", "tabs"],
              summary: "Inbox is for triaging new episodes; Up Next is a play order; Library is your subscribed collection.",
              steps: ["Review new episodes in Inbox.", "Move episodes you want to hear into Up Next or a playlist.", "Use Library to find shows and their episodes. Use Downloads and Bookmarks for those saved items."],
              example: "Archiving clears an episode from Inbox without marking it played. Marking played records that you finished or no longer need it.",
              options: "Removing an episode from a playlist does not put it back in Inbox. Queue placement and new-episode defaults are configurable in Settings.", action: .section(.inbox, title: "Open Inbox"), related: ["queue-actions", "playlists"]),
        .init(id: "subscribe", title: "Find and subscribe to a podcast", category: .discover,
              aliases: ["RSS", "XML", "private feed", "URL", "OPML", "import"],
              summary: "Add accepts podcast names, websites, and feed addresses, including private feeds supported by the app.",
              steps: ["Open Add and enter a show name, website, or RSS/XML feed address.", "Choose a result to preview its episodes.", "Subscribe when you want the show in your Library."],
              example: "You can play or queue an episode from a preview before subscribing.",
              options: "Some private feeds require authentication. Invalid or redirected feeds may need a corrected feed address. OPML import and export are available from the library management actions.", action: .section(.search, title: "Open Add"), related: ["queue-inbox", "refresh"]),
        .init(id: "player", title: "Use the player", category: .playback,
              aliases: ["play", "pause", "seek", "scrub", "skip", "mini player", "full player", "offline cover", "embedded artwork", "cover retry"],
              summary: "The mini player provides quick access to current playback. Episode covers can fall back to artwork embedded in a downloaded audio file and retry failed remote images while playback remains relevant.",
              steps: ["Tap the mini player to open the full player.", "Use the timeline to move through the episode. Tap play or pause to control playback.", "Use skip back and forward for the configured intervals. Use the chapter controls when chapters are available."],
              example: "If you skip by accident, use the undo prompt when it appears to return to the previous position.",
              options: "Playback speed, skip intervals, audio enhancements, output, and sleep timer are configurable or available from the player. When offline, a downloaded MP3 or M4A can provide embedded cover art; a cached podcast cover can also appear. Remote episode artwork is retried after temporary failures and when connectivity returns. Retries depend on the app being able to run and are not guaranteed at exact times in the background. Pausing preserves the saved position, including near the end; confirmed completion removes the episode from the playlist being played. Other playlists follow their removal preference. A completed episode can be deliberately played again from its episode actions. Some controls depend on the episode and device.", action: nil, related: ["chapters", "transcripts", "settings-playback", "queue-actions", "playlists", "downloads"]),
        .init(id: "now-playing-widget", title: "Use the Now Playing widget", category: .playback,
              aliases: ["widget", "home screen widget", "cover art", "chapter art", "skip controls"],
              summary: "The Now Playing widget shows the current episode artwork and provides playback controls from the Home Screen.",
              steps: ["Add the Up Next Now Playing widget from the Home Screen widget gallery.", "When an episode is playing, use its play or pause and skip controls.", "The artwork follows the player and can show chapter artwork when the current chapter provides it."],
              example: "Changing to a chapter with its own artwork updates the image shown for the current episode.",
              options: "Widget updates are scheduled by iOS and may not appear immediately. Artwork follows the player, including offline embedded covers and successful remote retries, when an update can run.", action: nil, related: ["player", "queue-inbox", "downloads"]),
        .init(id: "settings-playback", title: "Speed, output, and sleep timer", category: .playback,
              aliases: ["AirPlay", "audio", "continuous playback", "settings"],
              summary: "The player keeps common playback choices near the transport controls; broader defaults live in Playback settings.",
              steps: ["Open the full player.", "Use the compact controls below the main transport row for speed, audio output, or sleep timer.", "Open Settings → Playback to change default behavior."],
              example: "A sleep timer can stop playback after a duration or at the end of the current episode, depending on the selected option.",
              options: "Available output and audio controls depend on the current device, route, and media type. Video episodes can use a dedicated presentation.", action: nil, related: ["player", "settings"]),
        .init(id: "video-shareplay", title: "Video and Listen Together", category: .playback,
              aliases: ["audio video", "SharePlay", "watch together", "FaceTime"],
              summary: "Some episodes include video, and supported devices can share playback through SharePlay.",
              steps: ["Open an episode that includes video and use its media switch or player action when available.", "For a shared session, start SharePlay from the player when the device and account offer it.", "Use the system playback controls to manage the shared session."],
              example: "Video uses its media presentation while playing. The artwork player is used for audio playback.",
              options: "Video and SharePlay availability depends on the episode, OS, device, and session participants. System controls such as AirPlay, CarPlay, Apple Watch, and widgets vary by platform.", action: .player, related: ["player", "settings-playback"]),
        .init(id: "chapters", title: "Chapters and automatic skips", category: .chapters,
              aliases: ["chapter list", "skip rules", "intro", "outro", "ads", "contains", "equals", "suggested chapter rule", "tip", "skip recognition"],
              summary: "Chapters may come from a feed, audio metadata, or supported show notes. You can choose chapters and configure title rules for recurring segments.",
              steps: ["Open an episode or the full player and show its chapter list when chapters are available.", "Use the chapter controls to move between chapters or change which chapters play.", "After you manually skip similarly titled chapters in five different episodes of the same podcast, the player may suggest a keyword rule. Tap Review Skip Rule to open a prefilled draft, edit it if necessary, then tap Save Chapter Skip Rule.", "In Settings → Playback, configure global chapter skip rules; podcast settings can override defaults."],
              example: "A rule using “contains” intro can match titles such as “Welcome and intro”. “Equals” only matches the complete title.",
              options: "Manually turning off a chapter or pressing Next Chapter while well before its end can contribute to a suggestion. Automatic skips and near-end button presses do not count. Skip recognition stays on this device; only a rule you explicitly save syncs via iCloud. Saving a suggestion for a show that uses global defaults enables podcast-specific settings; existing disabled overrides may be reactivated, otherwise the new settings inherit global defaults. Rules support contains, equals, starts with, and ends with. Generated chapters require an eligible transcript and a supported on-device Apple Intelligence configuration; availability varies by device and OS.", action: nil, related: ["transcripts", "settings-playback"]),
        .init(id: "transcripts", title: "Read and search transcripts", category: .chapters,
              aliases: ["captions", "speech recognition", "transcribe", "follow along", "transcript search"],
              summary: "Publisher transcripts are used when available. Eligible episodes can also be transcribed on device.",
              steps: ["Open Transcript from an episode or the player when transcript text is available.", "Tap a passage to seek to its position in the episode.", "Use transcript search to find words in the current episode, a podcast, or your stored library."],
              example: "Following playback can highlight the current passage. Turn following off if you prefer to read without the transcript moving.",
              options: "On-device transcription depends on OS language and device support and may take time, especially for long episodes. Dynamic ad insertion can make transcript timing differ from the audio.", action: nil, related: ["chapters", "downloads"]),
        .init(id: "queue-actions", title: "Reorder and manage Up Next", category: .library,
              aliases: ["play next", "play last", "move", "remove", "automatic add"],
              summary: "Up Next is an ordered playlist. New episodes follow the placement and playlist selected in podcast settings.",
              steps: ["Open Up Next.", "Reorder an episode with its drag handle, or open its action menu for play-next, play-last, and removal actions.", "In Settings → Podcasts or a show's settings, set New episodes go to and Default playlist for auto-add."],
              example: "Play Next moves an episode near the current position. Play Last adds it after the existing queue.",
              options: "Choose Top or Bottom to add new episodes to the selected manual playlist. Choose Inbox to keep them out of playlists. The currently playing item can stay at the top while playback is active.", action: .section(.queue, title: "Open Up Next"), related: ["queue-inbox", "playlists"]),
        .init(id: "playlists", title: "Create and use playlists", category: .library,
              aliases: ["smart playlist", "manual playlist", "playlist icon", "icon picker", "symbols", "route podcasts", "auto-download"],
              summary: "Use playlists to keep a listening order or collect episodes that match conditions.",
              steps: ["Open Playlists from Library and create a playlist.", "Enter a name, choose Manual or Smart, and select an icon from the single grid of square tiles.", "Add episodes from their menus or route a podcast to a manual playlist in its settings. Smart playlists fill automatically from their filters.", "Open the playlist's settings to change its icon later."],
              example: "A manual playlist is curated by you. A smart playlist fills from episodes matching its rules.",
              options: "The icon grid offers a curated set for common listening habits and podcast topics. An older icon that is no longer in the grid remains selected and appears as Current until you choose a new one. Playlist settings also control download behavior.", action: .section(.library, title: "Open Library"), related: ["queue-inbox", "downloads"]),
        .init(id: "refresh", title: "Refresh subscriptions", category: .refresh,
              aliases: ["new episodes", "update feed", "refresh all", "last checked", "background refresh"],
              summary: "Refreshing checks subscribed podcast feeds for changes. Different refresh routes use different work and iOS controls when scheduled work can run.",
              steps: ["For one show, open its detail page and choose Refresh.", "For all shows, use the refresh action in the Library or podcast list.", "If an expected episode is missing, open that show and refresh it; then check for a feed error or authentication issue."],
              example: "A feed can be checked without importing a new episode. “Last checked” and “last successful refresh” describe different outcomes.",
              options: "A single-podcast manual refresh fetches the feed directly. Refresh All can first ask the server whether feeds changed. Quiet and background refreshes work within time, battery, and OS scheduling limits; they do not promise an exact interval. A predicted-release refresh probes the due feed and fetches it when due.", action: .section(.library, title: "Open Library"), related: ["subscribe", "downloads"]),
        .init(id: "downloads", title: "Download episodes and manage storage", category: .refresh,
              aliases: ["offline", "automatic download", "cache", "cancel download", "stalled download", "retry download"],
              summary: "Downloaded episode files support offline listening. Temporary artwork and data caches are separate from episode downloads.",
              steps: ["Use an episode's download action for a manual download.", "Use Pause, Resume, or Cancel while the transfer is in progress. If a download fails or makes no progress for 90 seconds, choose Retry.", "Open Downloads to find saved episodes and available download controls.", "Configure automatic downloads in podcast or playlist settings."],
              example: "Removing a downloaded file frees local space; it does not unsubscribe from the show.",
              options: "Portable automatic-download policy settings sync with your account. Downloaded episode files remain on the device that downloaded them. Background transfers may continue after the app closes; iOS schedules their progress. Retry restarts a stalled transfer. Sideloaded media is available only when that feature is enabled.", action: .section(.downloads, title: "Open Downloads"), related: ["transcripts", "playlists", "network-privacy"]),
        .init(id: "bookmarks", title: "Save a bookmark or share a clip", category: .sharing,
              aliases: ["scissors", "clip", "timestamp", "export", "share"],
              summary: "Bookmarks save a point in an episode. Clip tools select a range to preview and share when the source media permits it.",
              steps: ["While listening, use the bookmark action to save the current position.", "Open Bookmarks to revisit saved positions.", "Use the clip action to choose a start and end, preview the selection, then share or export it."],
              example: "A bookmark takes you back to one moment; a clip contains a selected range of media.",
              options: "Export can require locally available media and may be unavailable for some protected or remote sources. Sharing at the current timestamp is a separate option from exporting a clip.", action: .section(.bookmarks, title: "Open Bookmarks"), related: ["player", "downloads"]),
        .init(id: "settings", title: "Find a setting", category: .settings,
              aliases: ["appearance", "data", "storage", "podcast overrides", "themes", "iCloud", "blur"],
              summary: "Settings are grouped by the kind of behavior they control. Podcast settings can inherit global defaults or override them.",
              steps: ["Open Settings.", "Choose Playback, Podcasts, Playlists, Transcriptions, Appearance, Integrations, Privacy, or Data & Storage.", "For the Artwork background blur, open Appearance → Design, select Artwork, and adjust Background blur.", "For a per-show change, open that podcast's settings and enable custom settings when offered."],
              example: "When custom settings are enabled, supported podcast options start with the current global values. Later podcast-specific changes apply to that show, while other settings continue to follow global defaults.",
              options: "A newly created custom settings profile starts with the current global values. Disabling an existing profile keeps its saved overrides; enabling it again restores those overrides. iCloud synchronization and local feed refresh are separate processes. Appearance, including Artwork blur strength, is device-specific.", action: nil, related: ["settings-playback", "settings-appearance", "siri"]),
        .init(id: "settings-appearance", title: "Customize Artwork backgrounds", category: .settings,
              aliases: ["appearance", "design", "artwork", "frosted", "material", "blurry", "blur strength", "background blur"],
              summary: "Choose how strongly cover artwork is blurred and how frosted the content surface looks on rows and detail screens.",
              steps: ["Open Settings → Appearance → Design.", "Select Artwork.", "Move the five-step Background blur slider from Minimal to Maximum. The Standard step preserves the original artwork look.", "Return to a podcast or episode row or detail screen to see the change."],
              example: "Minimal makes background artwork easier to recognize; Maximum produces a softer, more strongly frosted appearance.",
              options: "This device-only preference changes the Artwork design. Adaptive Color and Uniform are unchanged. The actual cover hero remains sharp; the adjustable blur applies to the background and frosted content. Increased Contrast can use solid accessibility backgrounds instead of artwork blur.", action: nil, related: ["settings", "player", "chapters"]),
        .init(id: "siri", title: "Siri, Shortcuts, and automations", category: .settings,
              aliases: ["App Intents", "voice commands", "automation", "shortcut"],
              summary: "The Siri & Shortcuts settings page lists actions available on this device and operating system.",
              steps: ["Open Settings → Integrations → Siri & Shortcuts.", "Browse the capabilities shown for your current device.", "In Shortcuts, search for Up Next to add an action to a shortcut or personal automation."],
              example: "A personal automation can refresh podcasts at a time you choose, subject to the action and OS availability shown in the app.",
              options: "The available actions and Siri phrases vary by platform and OS version. Use the existing capabilities list as the current source of truth.", action: .siri, related: ["refresh", "settings"]),
        .init(id: "privacy-sync", title: "Sync, privacy, and local data", category: .settings,
              aliases: ["CloudKit", "iCloud", "private feed", "transcript storage", "delete data", "diagnostics", "legacy library sync", "sync recovery"],
              summary: "Up Next stores library and playback data on your devices and can synchronize supported data through iCloud. Feed refresh and sync are separate.",
              steps: ["Review Settings → Data & Storage for storage and maintenance controls.", "Review Settings → Transcriptions for transcript generation and stored-text options.", "Use the in-app privacy and diagnostics information when investigating a sync or data issue. If Settings → iCloud Sync offers Stop on Next Launch, read its warning before choosing it."],
              example: "A podcast feed may refresh successfully on one device before its updated library state appears on another device.",
              options: "A short app session or ordinary backgrounding does not stop legacy library sync. The one-way Stop on Next Launch recovery action is manual; use it only when no other device depends on the legacy library sync. Feed and artwork caches are local. Sideloaded or private feed content may be sensitive; protect the device and account used to access it. Sync timing depends on network and Apple services.", action: nil, related: ["downloads", "transcripts", "refresh"]),
        .init(id: "network-privacy", title: "Reduce tracking in network requests", category: .settings,
              aliases: ["tracking protection", "UTM", "click IDs", "network privacy", "feed URL", "signed URL"],
              summary: "Up Next removes recognized tracking parameters from supported requests by default while preserving unknown and access-related URL fields.",
              steps: ["Open Settings → Privacy.", "Leave Reduce tracking in network requests enabled to remove recognized tracking parameters from new supported requests.", "If a podcast stops working, try switching the setting off for subsequent requests."],
              example: "A feed URL's source identity stays the same; the app cleans only its outgoing request URL when it recognizes tracking parameters. Supported Podtrac audio links are resolved directly to a validated HTTPS publisher address.",
              options: "Some servers can still identify requests from IP address and timing. Embedded remote images and media in shownotes are blocked. AVFoundation playback and background download redirects have platform limits, and a few podcasts may need their original link. Changing the setting affects newly created requests; current playback or downloads may continue.", action: nil, related: ["privacy-sync", "subscribe", "downloads"]),
        .init(id: "live-podcasts", title: "Live episodes and notifications", category: .settings,
              aliases: ["liveItem", "live podcast", "notifications", "widgets", "CarPlay", "CarPlay queue", "vehicle", "Apple Watch", "menu bar"],
              summary: "Up Next can surface live items published by supported feeds. Other system integrations depend on the platform and current OS.",
              steps: ["Subscribe to a podcast that publishes a supported live item.", "Check podcast and notification settings if you want live updates surfaced.", "Use the player or system surface available on your device to listen."],
              example: "A live item is provided by the show feed; it is different from an ordinary episode with a scheduled release.",
              options: "Widgets, CarPlay, Apple Watch, notifications, SharePlay, and the macOS menu bar player have different platform and OS availability. The app only shows controls supported by the current build and device. In CarPlay, open Playlists to choose a playlist and Inbox to review new episodes. Episode text appears before available covers load. The vehicle sets the maximum number of rows a CarPlay list can display; use Up Next on iPhone to reach items beyond that limit.", action: nil, related: ["refresh", "player", "settings", "queue-inbox", "playlists"]),
        .init(id: "troubleshoot-refresh", title: "An expected episode is missing", category: .help,
              aliases: ["feed did not update", "no new episodes", "refresh error", "authentication"],
              summary: "A successful feed check does not always mean the publisher has published a new item or that it has reached its expected release time.",
              steps: ["Open the podcast and run its manual Refresh action.", "Check the podcast's latest episode date and any visible feed or sign-in error.", "If the episode is still missing, confirm the feed address with the publisher and try again when the server is available."],
              example: "Scheduled refresh is controlled by iOS and may run later than requested. Opening the app does not guarantee every feed will be fetched immediately.",
              options: "Servers can be offline, require updated authentication, or report that a feed is unchanged. Refresh All may avoid downloading an unchanged feed body; a single manual refresh requests the feed directly.", action: .section(.library, title: "Open Library"), related: ["refresh", "subscribe"]),
        .init(id: "private-feed-authentication", title: "Fix podcast authentication", category: .help,
              aliases: ["private podcast", "HTTP Basic", "username", "password", "login required", "credentials", "Fix Authentication", "Bearer token"],
              summary: "Repair access to a subscribed private podcast without changing its feed address or removing it from your Library.",
              steps: ["Open the podcast from Library. If its saved access is rejected or unavailable, choose Fix Authentication on the warning.", "Enter the username and password requested by the feed, or update its private RSS link or access token in Podcast Settings.", "Up Next checks the credentials against the feed before replacing saved access. Correct credentials close the form and start a refresh."],
              example: "A podcast may keep its episodes and listening history while waiting for credentials on a device that does not have the device-only Keychain item.",
              options: "Credentials are stored in the device Keychain. They are not included in feed URLs, CloudKit subscription records, logs, or exports. A new device may ask for credentials again. Network failures can be temporary; retry when the server is available. A server rejection requires updated credentials.", action: .section(.library, title: "Open Library"), related: ["subscribe", "refresh", "privacy-sync", "troubleshoot-refresh"]),
        .init(id: "troubleshoot-transcript", title: "A transcript or chapter is missing", category: .help,
              aliases: ["no transcript", "no chapters", "transcription unavailable", "language"],
              summary: "Transcript and chapter availability depends on the publisher, media metadata, language, and device support.",
              steps: ["Check the episode detail and full player for Transcript or Chapters.", "If offered, use the on-device generation action and keep the episode available while it works.", "Check transcription settings and supported language/device requirements if generation is unavailable."],
              example: "A publisher may provide chapters but no transcript, or a transcript without chapter markers.",
              options: "On-device speech recognition and Apple Intelligence features are limited by OS, language, and device. Generated text can take time and may need correction.", action: nil, related: ["transcripts", "chapters"])
    ]

    static func topic(id: String) -> UserGuideTopic? { topics.first { $0.id == id } }
}

struct SettingsHelpView: View {
    @State private var searchText = ""

    private var filteredTopics: [UserGuideTopic] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return UserGuideRegistry.topics }
        return UserGuideRegistry.topics.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                Section {
                    NavigationLink {
                        UserGuideArticleView(topic: UserGuideRegistry.topic(id: "first-listen")!)
                    } label: {
                        Label("Getting started", systemImage: "sparkles")
                    }
                } header: { Text("Start here") }
            }

            ForEach(UserGuideCategory.allCases) { category in
                let categoryTopics = filteredTopics.filter { $0.category == category }
                if categoryTopics.isEmpty == false {
                    Section {
                        ForEach(categoryTopics) { topic in
                            NavigationLink {
                                UserGuideArticleView(topic: topic)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(topic.title).foregroundStyle(.primary)
                                    Text(topic.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    } header: {
                        Label(category.rawValue, systemImage: category.symbol)
                    }
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $searchText, prompt: "Search the guide")
        .navigationTitle("Using Up Next")
        .platformInlineNavigationTitle()
    }
}

private struct UserGuideArticleView: View {
    @Environment(\.userGuideNavigation) private var navigation
    let topic: UserGuideTopic

    var body: some View {
        List {
            Section("What it does") { Text(topic.summary) }
            Section("Where to find it") { Text(entryPoint) }
            Section("Steps") {
                ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                    LabeledContent("\(index + 1)", value: step)
                }
            }
            Section("Example") { Text(topic.example) }
            if topic.id == "refresh" || topic.id == "troubleshoot-refresh" {
                Section("How Up Next checks for new episodes") {
                    RefreshGuideDiagram()
                }
            }
            Section("Options and availability") { Text(topic.options) }
            if let action = topic.action {
                Section {
                    switch action {
                    case .section(let section, let title):
                        Button {
                            navigation?.select(section)
                        } label: {
                            Label(title, systemImage: "arrow.up.right.circle")
                        }
                    case .siri:
                    NavigationLink {
                        SiriShortcutsGuideView()
                        } label: {
                            Label("Open Siri & Shortcuts guide", systemImage: "arrow.up.forward.app")
                        }
                    case .player:
                        Button {
                            Player.shared.isPlayerSheetPresented = true
                        } label: {
                            Label("Open Player", systemImage: "play.circle")
                        }
                    }
                } header: { Text("Try it") }
            }
            let relatedTopics = topic.related.compactMap(UserGuideRegistry.topic)
            if relatedTopics.isEmpty == false {
                Section("Related topics") {
                    ForEach(relatedTopics) { related in
                        NavigationLink {
                            UserGuideArticleView(topic: related)
                        } label: {
                            Text(related.title)
                        }
                    }
                }
            }
        }
        .navigationTitle(topic.title)
        .platformInlineNavigationTitle()
    }

    private var entryPoint: String {
        switch topic.action {
        case .section(_, let title): title
        case .siri: "Settings → Integrations → Siri & Shortcuts, or search for Up Next in Shortcuts."
        case .player: "Tap the mini player or open an episode."
        case nil: "Open the relevant episode, player, podcast, or Settings page described above."
        }
    }

}

private struct RefreshGuideDiagram: View {
    private let paths: [(String, String)] = [
        ("Refresh one show", "Fetch the feed directly to recheck it."),
        ("Refresh all shows", "Check for changes first; fetch feed content when needed."),
        ("Expected release", "Check the due show, then fetch even if the quick check looks unchanged."),
        ("Scheduled refresh", "Work through a limited set when iOS grants time."),
        ("Add or import a feed", "Fetch and validate its feed content.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Refresh paths work differently")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.tint, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path.0).font(.subheadline.weight(.medium))
                        Text(path.1).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("If an episode is missing, refresh the show directly and check its latest published item and any visible feed or sign-in error. Scheduled work has no guaranteed interval.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

private struct UserGuideNavigationKey: EnvironmentKey {
    static let defaultValue: AppNavigationModel? = nil
}

extension EnvironmentValues {
    var userGuideNavigation: AppNavigationModel? {
        get { self[UserGuideNavigationKey.self] }
        set { self[UserGuideNavigationKey.self] = newValue }
    }
}
