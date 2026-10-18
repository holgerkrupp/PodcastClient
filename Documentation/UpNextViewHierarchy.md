# Up Next view hierarchy and action locations

This is the shared presentation guide for UX epic #312 and hierarchy work #313. It maps existing actions to their intended location; the surface-specific child issues implement the layouts.

## In-app User Guide

The bundled, searchable help entry point is `Raul/Features/Help/UserGuideView.swift` and is linked from Settings → Help & About → Using Up Next. The guide is offline and uses native SwiftUI navigation. Its topic registry is the canonical source for article copy, search aliases, related-topic links, and safe in-app actions. The existing Siri & Shortcuts guide remains the source for the live App Intents catalog; link to it rather than duplicating its capability list.

Every user-visible behavior change must review and maintain the corresponding guide topic in the same change. Keep the topic's actual entry point, steps, example, settings/availability limits, related links, and action in sync with the shipped UI. Do not claim DEBUG-only or planned behavior as available. See `AGENTS.md` for the full maintenance rule.

Screenshot examples must come from repeatable preview or UI-test fixtures using sample podcast titles and transcripts. Never capture account state, private feed URLs, credentials, personal history, or other sensitive data. Keep capture metadata with each image: source screen, platform/OS, locale, and last verified app version. Do not use fabricated mockups as current UI examples. When adding a screenshot pipeline, document how to regenerate it and validate compact iPhone, regular-width/iPad, and macOS variants where behavior differs.

Guide validation should check stable topic ID uniqueness, related-topic resolution, search across title/aliases/keywords/article text, action destination availability, accessibility text for images, and packaged resources. Add platform UI smoke coverage for Settings → guide → topic → action → back when a fixture-based harness is available. Avoid screenshot recapture for unrelated changes.

## Shared rules

- Keep one primary action prominent in each context. Use a short secondary-action group for frequent actions and native menus or disclosures for occasional utilities.
- Use a consistent artwork, title, author, and summary treatment. Podcast rows use the shared value-driven `PodcastRowContentView`: comfortable density in Library, compact density in Search and broadcaster discovery. The caller owns navigation and subscription lookup.
- Keep artwork and text readable in Artwork, Adaptive Color, and Uniform styles, including Increased Contrast. Scale row and header content with Dynamic Type; use 44 pt or larger interactive targets.
- Avoid per-row model queries, episode-relationship access, repeated HTML parsing, or additional image decoding. Pass small presentation values into shared row content.
- Keep critical errors, active work, and retry states visible. Put low-frequency management and diagnostic actions in native menus or disclosures.

## Before / after inventory

| Surface | Current grouping | iPhone target | Regular-width target |
| --- | --- | --- | --- |
| Player | Chapter/transcript/settings controls, scrubber, transport, utility row, and footer actions occupy separate zones. | Artwork and now-playing identity; chapter context and scrubber; primary transport; compact speed/output/sleep row; optional player content and More actions. Keep Duo hero height and top-pinned transport behavior unchanged. | Keep the same playback hierarchy; use the existing segmented content pane for show notes, transcript, and chapters. Advanced actions remain contextual. |
| Episode Detail | Progress, download, icon controls, funding, transcript/AI, browser/share, full podcast row, and metadata stack together. | Play/Resume first, queue actions grouped, Download adjacent; then available transcript/chapter/AI, show notes, compact related-podcast link, and expandable metadata. | Preserve the same primary order; use regular-width space for content sections without promoting rare actions above playback. |
| Podcast Detail | Update diagnostics precede identity; search, funding, subscription, feed repair, and metadata use competing action treatments before episodes. | Identity and Subscribe/Subscribed first, then transcript search when available and episode list. About is expandable; feed repair and other management actions are in More. Keep feed errors and refresh feedback visible. | Keep the same identity and episode priority; allow About/details beside or below episodes where layout permits. Keep refresh in the toolbar and management in More. |
| Add Podcast / Search | Discovery destinations, import/export, recent searches, and results share one landing list. | Native search field accepts names, websites, RSS links, and private feeds. Empty state has compact discovery destinations and recent searches; results take over while typing. Import/export stays secondary. | Keep search first and group discovery destinations and recent searches in a compact supporting area. Preserve URL authentication and play/queue before subscribing. |
| Podcast Browse | The unsaved feed header already has a details disclosure, with subscription, discovery metadata, and episode browsing using a separate presentation. | Keep podcast identity, Subscribe/Importing/Retry state, and the episode list near the top. Preserve play/queue without subscribing, refresh, filters, trailers, alternative feeds, and RSS details. | Reuse the same identity and episode hierarchy as subscribed detail while retaining unsaved-feed semantics and visible errors. Never create a persistent `Podcast` model for a preview. |
| Podcast rows | Library, unsaved search results, and broadcaster discovery each render their own artwork, summary, and status layout. | Use one value-driven row presenter: comfortable Library density and compact 56–72 pt artwork in Search and broadcaster discovery. Keep caller navigation and trailing subscribe actions outside the preview. | Keep artwork, title, summary, status, and theme treatment consistent; let text grow with Dynamic Type. Keep broadcaster/country context accessible without exposing private feed URLs. |

## Action locations

| Surface | Frequent actions | Contextual and less-frequent actions |
| --- | --- | --- |
| Player | Scrub, play/pause, skip, bookmark, playback speed, output, sleep timer, chapter selection, transcript visibility/settings. | Website, share at current position, audio/video switch, Listen Together, and debug metadata in the player More menu; full transcript opens from the inline transcript card. Show Notes, transcript, and chapters stay in the content pane or scrolling content. |
| Episode Detail | Play/Resume, queue positions, download, available transcript/chapter controls, or transcript generation when supported. | Sharing, website, media switch, debug utilities, bookmarks, funding, related podcast, and technical metadata remain grouped in More or expandable sections. |
| Podcast Detail | Subscribe/Subscribed, transcript search when indexed, refresh/retry, episode list, search, and sort. | Podcast settings, alternative feeds, feed repair, unsubscribe, archive all, debug diagnostics, funding, podroll, trailers, release information, and extended metadata are in Manage Podcast or About & Podcast Details. Feed errors and active refresh remain visible. |
| Add Podcast / Search | Native podcast search for names, websites, public RSS/XML, and private feeds; recent searches and discovery destinations appear when search is empty. | Private-feed authentication stays in its secure flow. Import/Export is in the secondary Library group. Alternative feeds and trailers stay with an individual preview. |
| Podcast Browse | Subscribe state, episode list, play, and queue work without subscribing. | Feed details and update diagnostics are in the disclosure; alternative feeds stay in their menu; refresh and page retry stay visible. |
| Global Settings | Privacy contains the default-on network tracking protection control and a short explanation of its limits. | Local request counts are shown only when available; feed credentials, URLs, and request identifiers are never included. |

## Responsive review

Review portrait and compact-height iPhone, iPhone Duo, landscape, regular-width iPad, and macOS layouts. Let content wrap or move into scrollable sections and native menus rather than increasing the Player hero or shrinking transport hit targets. Check long localized titles, large text, VoiceOver, Reduce Motion, high contrast, and all three visual styles. The detailed player interaction and Duo regression gate remains in #314/#320.
