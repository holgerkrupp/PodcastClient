# Up Next view hierarchy and action locations

This is the shared presentation guide for UX epic #312 and hierarchy work #313. It maps existing actions to their intended location; the surface-specific child issues implement the layouts.

## In-app User Guide

The bundled, searchable help entry point is `Raul/Features/Help/UserGuideView.swift` and is linked from Settings → Help & About → Using Up Next. The guide is offline and uses native SwiftUI navigation. Its topic registry is the canonical source for article copy, search aliases, related-topic links, and safe in-app actions. The existing Siri & Shortcuts guide remains the source for the live App Intents catalog; link to it rather than duplicating its capability list.

Every user-visible behavior change must review and maintain the corresponding guide topic in the same change. Keep the topic's actual entry point, steps, example, settings/availability limits, related links, and action in sync with the shipped UI. Do not claim DEBUG-only or planned behavior as available. See `AGENTS.md` for the full maintenance rule.

Playback and listening-history portable-write recovery is quiet and does not interrupt Inbox, Up Next, or the player. Settings → iCloud Sync shows whether local recovery is pending, in progress, or needs attention; the status clears after local repair is verified. This local status does not claim that CloudKit has exported the change to another device. Support Diagnostics on the iCloud Sync screen includes redacted queue counts, failure categories, retry timing, and repair status for support.

If startup cannot access a previously initialized library, the dedicated recovery screen offers **Try Again**, **Copy Diagnostics**, and **Share Diagnostics**. The report reads app metadata, defaults, and SQLite file metadata without opening another store. It does not imply that subscriptions were deleted; keep the app installed while retrying or contacting support.

Screenshot examples must come from repeatable preview or UI-test fixtures using sample podcast titles and transcripts. Never capture account state, private feed URLs, credentials, personal history, or other sensitive data. Keep capture metadata with each image: source screen, platform/OS, locale, and last verified app version. Do not use fabricated mockups as current UI examples. When adding a screenshot pipeline, document how to regenerate it and validate compact iPhone, regular-width/iPad, and macOS variants where behavior differs.

Guide validation should check stable topic ID uniqueness, related-topic resolution, search across title/aliases/keywords/article text, action destination availability, accessibility text for images, and packaged resources. Add platform UI smoke coverage for Settings → guide → topic → action → back when a fixture-based harness is available. Avoid screenshot recapture for unrelated changes.

## Shared rules

- Keep one primary action prominent in each context. Use a short secondary-action group for frequent actions and native menus or disclosures for occasional utilities.
- Use a consistent artwork, title, author, and summary treatment. Podcast rows use the shared value-driven `PodcastRowContentView`: comfortable density in Library, compact density in Search and broadcaster discovery. The caller owns navigation and subscription lookup.
- Keep artwork and text readable in Artwork, Adaptive Color, and Uniform styles, including Increased Contrast. Scale row and header content with Dynamic Type; use 44 pt or larger interactive targets.
- Appearance → Design → Artwork exposes a five-step, device-only **Background blur** slider. The Standard preset reproduces existing artwork-row and detail-blur radii and frosted materials; other presets adjust both while leaving the cover-hero image sharp, the hero scroll/transport hierarchy unchanged, and Adaptive Color / Uniform untouched. The app publishes this device-local blur choice with the existing widget appearance snapshot in the App Group; both Now Playing and Play Next Queue use the matching blurred cover and frosted material when their widget backgrounds are displayed. Changing the slider requests widget timeline reloads, which the OS may delay. Tinted and accessory widget rendering is system-controlled.
- Avoid per-row model queries, episode-relationship access, repeated HTML parsing, or additional image decoding. Pass small presentation values into shared row content.
- Keep critical errors, active work, and retry states visible. Put low-frequency management and diagnostic actions in native menus or disclosures.

## User Guide ↔ design contract

The public in-app **Settings → Help & About → Using Up Next** manual must reflect the action location and behavior described here. The [User Guide epic #347](https://github.com/holgerkrupp/PodcastClient/issues/347) establishes the searchable, illustrated guide and its proposed canonical topic/screenshot sources under `Documentation/UserGuide/` (the current short `SettingsHelpView` is in `Raul/Features/Settings/Views/PodcastSettingsView.swift`).

When changing an action's **placement, grouping, visual control, gesture, name, default, availability, effect, or interaction flow**, update its matching user-facing guide topic in the **same PR**, alongside this document. Include correct step-by-step paths, current control labels, real/sanitized UI screenshots, and safe contextual “Open …” destinations. Check compact/short iPhone layouts, regular-width/macOS differences, localization, accessibility, and OS gating. If a topic does not yet exist, add it once the guide system lands and track interim omissions in #347; do not let stale copy or screenshots become the released documentation.

This applies to all frequently used and More-menu actions listed in the tables, plus subscription, refresh, chapter, transcript, queue, playlist, Siri/App Intent, widget, bookmark, export, sync and Settings behavior. Follow the repository-wide [AGENTS.md](../AGENTS.md) User Guide maintenance rule.

## Before / after inventory

| Surface | Current grouping | iPhone target | Regular-width target |
| --- | --- | --- | --- |
| Player | Chapter/transcript/settings controls, scrubber, transport, utility row, and footer actions occupy separate zones. | Artwork and now-playing identity; chapter context and scrubber; primary transport; compact speed/output/sleep row; optional player content and More actions. Keep Duo hero height and top-pinned transport behavior unchanged. | Keep the same playback hierarchy; use the existing segmented content pane for show notes, transcript, and chapters. Advanced actions remain contextual. |

| Episode Detail | Progress, download, icon controls, funding, transcript/AI, browser/share, full podcast row, and metadata stack together. | Play/Resume first, queue actions grouped, Download adjacent; then available transcript/chapter/AI, show notes, compact related-podcast link, and expandable metadata. | Preserve the same primary order; use regular-width space for content sections without promoting rare actions above playback. |
| Podcast Detail | Update diagnostics precede identity; search, funding, subscription, feed repair, and metadata use competing action treatments before episodes. | Identity and Subscribe/Subscribed first, then transcript search when available and episode list. About is expandable; feed repair and other management actions are in More. Keep feed errors and refresh feedback visible. | Keep the same identity and episode priority; allow About/details beside or below episodes where layout permits. Keep refresh in the toolbar and management in More. |
| Add Podcast / Search | Discovery destinations, import/export, recent searches, and results share one landing list. | Native search field accepts names, websites, RSS links, and private feeds. Empty state has compact discovery destinations and recent searches; results take over while typing. Import/export stays secondary. | Keep search first and group discovery destinations and recent searches in a compact supporting area. Preserve URL authentication and play/queue before subscribing. |
| Podcast Browse | The unsaved feed header already has a details disclosure, with subscription, discovery metadata, and episode browsing using a separate presentation. | Keep podcast identity, Subscribe/Importing/Retry state, and the episode list near the top. Preserve play/queue without subscribing, refresh, filters, trailers, alternative feeds, and RSS details. | Reuse the same identity and episode hierarchy as subscribed detail while retaining unsaved-feed semantics and visible errors. Never create a persistent `Podcast` model for a preview. |
| Podcast rows | Library, unsaved search results, and broadcaster discovery each render their own artwork, summary, and status layout. | Use one value-driven row presenter: comfortable Library density and compact 56–72 pt artwork in Search and broadcaster discovery. Keep caller navigation and trailing subscribe actions outside the preview. | Keep artwork, title, summary, status, and theme treatment consistent; let text grow with Dynamic Type. Keep broadcaster/country context accessible without exposing private feed URLs. |
| Share Extension | Recognized episodes show a destination picker and one generic Add Episode action. | Keep Inbox as an explicit destination; for a selected manual playlist, show Play Next and Play Last using the episode-row queue actions and positions. | Keep both queue actions labeled and reachable in the extension's scrollable content. |

Manual chapter-skip recognition is local to the device. After five different episodes of the same show are manually skipped with a recurring title keyword, the player can display a TipKit suggestion below the chapter controls. **Review Skip Rule** opens that podcast's Chapter Skip Rules settings with an editable, unsaved draft. **Save Chapter Skip Rule** is the only action that adds the suggestion to synced podcast settings (enabling inherited podcast-specific settings if necessary); **Not Now** dismisses it without changing settings.

## Action locations

The **Icon** section in both New Playlist and Playlist Settings shows one grid of large, labeled square tiles. It includes a small set of generic and podcast-topic choices; there is no second Symbols catalog. Older stored symbols remain unchanged and can be replaced from the same grid (displayed as **Current** when no longer in the curated set).

| Surface | Frequent actions | Contextual and less-frequent actions |
| --- | --- | --- |
| Player | Scrub, play/pause, skip, bookmark, playback speed, output, sleep timer, chapter selection, transcript visibility/settings. | Website, share at current position, audio/video switch, Listen Together, and debug metadata in the player More menu; full transcript opens from the inline transcript card. Show Notes, transcript, and chapters stay in the content pane or scrolling content. |
| Episode Detail | Play/Resume, queue positions, download, available transcript/chapter controls, or transcript generation when supported. | Sharing, website, media switch, debug utilities, bookmarks, funding, related podcast, and technical metadata remain grouped in More or expandable sections. |
| Podcast Detail | Subscribe/Subscribed, transcript search when indexed, refresh/retry, episode list, search, and sort. An authentication failure shows an inline Fix Authentication action. | Podcast settings, credential management, alternative feeds, feed repair, unsubscribe, archive all, debug diagnostics, funding, podroll, trailers, release information, and extended metadata are in Manage Podcast or About & Podcast Details. Feed errors and active refresh remain visible. |
| Add Podcast / Search | Native podcast search for names, websites, public RSS/XML, and private feeds; recent searches and discovery destinations appear when search is empty. | Private-feed authentication stays in its secure flow. Import/Export is in the secondary Library group. Alternative feeds and trailers stay with an individual preview. |
| Podcast Browse | Subscribe state, episode list, play, and queue work without subscribing. | Feed details and update diagnostics are in the disclosure; alternative feeds stay in their menu; refresh and page retry stay visible. Broadcaster feed-resolution failures keep Retry Feed Lookup and Open Programme Website visible until a validated RSS feed opens this same preview. |
| Share Extension | For a recognized episode, Play Next and Play Last add it to the selected manual playlist using the same placement as episode rows. | Inbox remains available as a destination; podcast subscription stays on its podcast card. |
| Global Settings | Privacy contains the default-on network tracking protection control and a short explanation of its limits. | Local request counts are shown only when available; feed credentials, URLs, and request identifiers are never included. |

## Responsive review

Review portrait and compact-height iPhone, iPhone Duo, landscape, regular-width iPad, and macOS layouts. Let content wrap or move into scrollable sections and native menus rather than increasing the Player hero or shrinking transport hit targets. Check long localized titles, large text, VoiceOver, Reduce Motion, high contrast, and all three visual styles. The detailed player interaction and Duo regression gate remains in #314/#320.

### Inbox bulk clearing and subscription imports

The Inbox toolbar exposes **Clear inbox** beside refresh when episodes are present. A confirmation shows the current episode count. Clearing removes the current inbox snapshot in batches while preserving Library, playlists, playback history and archive state.

All subscriptions, including OPML imports, admit only episodes released strictly after the subscription date to Inbox. Older or undated episodes remain in Library as suppressed back catalogue.


### Playlist persistence and Downloads recovery (#390)

- New Playlist stays open with **Could Not Save Playlist** if the local persistent write fails. Retry after storage is available. Other playlist edits/deletions surface the same error at the app root.
- Up Next membership/order is acknowledged after the local UserState commit; CloudKit delivery is asynchronous. Split-only runtimes hydrate later imports additively; only explicit tombstones remove membership.
- If the default queue has no local active entries while the shared presence reference reports saved entries, show a recovery state and reconcile additively instead of presenting the queue as empty. Presence counts indicate that recovery may be needed; they do not prove account-wide sync completion.
- **Downloads → More → Rescan** refreshes the local file inventory. Files decide visibility even when reconstructed metadata is stale. No navigation action performs a replacement download.
- Download starts show inline progress immediately. Save failures remain non-modal with Retry, and insufficient storage is called out when identified. Completed files appear without waiting for chapter/metadata processing.

### Bookmark persistence

The player, macOS menu, CarPlay and bookmark App Intent wait for a local save and either a portable save or a durable retry before reporting success. If the bookmark was saved locally but could not be queued for syncing, the error says it already exists on the device. Bookmark removal stages a retry before deleting locally; an error leaves the bookmark visible. The retry publishes a deletion only after the durable library confirms the local bookmark is absent.

### Startup and library restoration

- Mount the main app shell directly when its runtime container is available, without a decorative launch curtain. During local hydration, show **Restoring your saved library…** without obscuring navigation. Saved playlist references awaiting episode data use the contextual playlist recovery state.
- Initial local hydration belongs to the container manager and survives removal of the launch view. Background interruption resumes on foreground activation; it is not an initialization error.
- If the initial launch screen remains visible for ten seconds, it offers **Copy Diagnostics** and **Share Diagnostics**. These actions read local status and never upload automatically or reset stores.
- A genuine initialization failure offers **Try Again**. Rendering the error screen does not automatically restart initialization or repeatedly replay the launch animation.
