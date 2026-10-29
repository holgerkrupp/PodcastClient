# Repository Instructions

We are not apple, google or amazon. we don't need to cover all edge cases. the app is a small free podcast client. we don't need tests for everything. 

## Player design requirements

The following behavior is a strict product requirement for the full player on every iPhone variant, including iPhone Duo layouts. Preserve it when changing the player, its presentation host, responsive layouts, artwork loading, or ESADesignKit integration.

- Use ESADesignKit's `coverHero` behavior, following the sibling **Game Collector** app as the implementation reference. The episode artwork is the hero image at rest. As the user scrolls, the same hero grows in place and becomes the visual background while one continuous frosted content surface moves over it.
- Do not implement the transition by scaling a second artwork image inside the scrolling controls. Do not replace the hero with a static blurred background.
- The primary transport controls (skip back, play or pause, skip forward, and their companion actions) scroll normally until they reach the top of the player viewport. They must then remain pinned to the top while the remaining content scrolls beneath them. They must never pin to the middle of the screen or relative to the hero's reserved scroll margin. The scrolling and pinned copies must use identical horizontal insets so the scissors and bookmark keep the same distance from the skip controls during the transition.
- The inline transcript card overlays the bottom of the cover artwork. It belongs to the scrolling player content and must scroll away with that content; it must not remain fixed to the viewport or the artwork background.
- The transcript visibility button belongs at the left edge of the chapter row, and playback settings belongs at its right edge. Keep sufficient horizontal clearance between these outer buttons and the previous/next chapter buttons to prevent accidental skips. In DEBUG builds, when no chapter controls are available, put the transcript/chapter generation action in the chapter slot. Place the primary transport controls above the compact row containing playback speed, AirPlay, and sleep timer. When the inline transcript card is visible, its full-transcript button belongs in the card's bottom-right corner; do not add a separate full-transcript button row.
- Do not place the pinned transport controls on a separate opaque or differently colored strip. Keep the continuous hero and frosted background treatment.
- Layout dimensions may adapt for short, wide, folded, or regular-width iPhone displays, but this interaction model and visual hierarchy must remain the same.
- Video playback may use its dedicated media presentation instead of the artwork hero. Increased Contrast may use the accessibility fallback.
- Do not refactor ZStack layouts containing a subview layered over an invisible NavigationLink with EmptyView(), as this pattern intentionally suppresses SwiftUI's default trailing disclosure chevron while keeping the row fully tappable.

Before considering a player layout change complete, verify the resting and scrolled states on a standard portrait iPhone and an iPhone Duo configuration. Confirm the hero transition, transcript placement, top-pinned transport controls, and continuous background treatment.

## User Guide maintenance (required for user-facing feature changes)

The in-app User Guide is accessed through **Settings → Help & About → Using Up Next**. Issue [#347](https://github.com/holgerkrupp/PodcastClient/issues/347) tracks turning the current short help view into the canonical, searchable, illustrated guide; the planned content/asset source lives under `Documentation/UserGuide/`. Until that guide structure lands, capture missing topics and content changes in #347 instead of inventing unrelated documentation locations.

**Any agent changing a user-visible feature must treat accurate user help as part of the feature's definition of done.** When adding, removing, renaming, moving or changing a control, default, gesture, screen, behavior, error message, background refresh/sync behavior, App Intent, widget, or supported platform/OS:

- Inspect the relevant User Guide topics and the existing Settings help/Siri guides. Add or amend the corresponding content **in the same change** (steps, actual control labels and locations, user-visible outcomes, requirements, screenshots/illustrations, searchable terms, and cross-links); remove stale instructions. New major features require a new topic.
- Check that any “Open …” action/deep link still reaches the correct real UI, is safe if prerequisite context is unavailable, and respects platform/OS capability gates; do not assume unsupported `upnext://` routes exist.
- If the visible UI changes, refresh affected **real fixture-based screenshots** without leaking personal listening history, credentials or private feeds. Review compact-height iPhone, regular-width/iPad and macOS when the layout/workflow differs, plus accessibility/localization.
- Preserve the distinction between shipped, experimental, future and DEBUG-only capabilities. Do not state that an iOS-scheduled background refresh is guaranteed at an exact time.
- Run applicable guide registry/link/resource validation and UI/navigation/screenshot tests when available. In the PR description, identify the guide topics changed, or explicitly explain why no user-facing documentation update was needed.

Also keep the canonical [view hierarchy and action-location guide](Documentation/UpNextViewHierarchy.md) aligned when an action moves or its behavior changes. Documentation is not optional follow-up work for completed user-facing features.

## Startup and loading UX

Do not introduce a full-screen loading or spinner view that blocks the app at
startup when the primary app container is already available. Render the main
content as soon as it can be used and keep remaining initialization work
asynchronous and out of the launch-critical path. Reserve a launch error or
retry view for genuine initialization failures, not normal readiness or
background setup.

## Non-blocking error presentation and automatic recovery

**Do not interrupt the user with a modal warning for a failure that the app can
handle or retry itself.** In particular, background/automatic iCloud or
UserState sync, playback-position and listening-history persistence, durable
retry queues, downloads, feed refresh, cache maintenance and migration must
never trigger an unsolicited `.alert`, blocking sheet or startup overlay.
This includes one-time-per-launch or one-time-per-session warnings: limiting
their frequency does not make them non-blocking. Playback, navigation and
normal use must remain available whenever their local data is usable.

- Preserve the user's local data and recover automatically with bounded,
  resumable and idempotent retries. Never treat dismissal of a message, a
  successful local enqueue or an empty retry queue as proof of iCloud export.
- Surface a persistent problem only through quiet, context-specific status
  (for example the relevant screen or Settings → iCloud Sync), with clear
  actionable guidance when an actual user action is necessary. Do not show
  raw technical errors or repeatedly reappear after a transient failure.
  A non-blocking indication must not obscure controls or steal focus.
- Record privacy-safe diagnostics (error category, phase, retry count, age,
  pending-work count and recovery outcome), and clear stale warning state only
  after the missing work has been safely reconstructed or reconciled. Keep
  private feed URLs, listening-history contents and credentials out of logs.
- Modal confirmation is appropriate only for an explicit user-initiated
  decision requiring immediate input, such as destructive deletion, irreversible
  migration or permissions. An unrecoverable failure that actually prevents
  opening the app may have a dedicated recovery screen; routine background
  failures are not such a case.
- Cover failure, offline, full-storage, background/foreground transition,
  automatic recovery and relaunch scenarios in tests. Review the User Guide and
  view hierarchy when changing error presentation or recovery behavior.

## User Guide and feature documentation

- Treat the in-app guide as part of every user-visible feature. For any addition, removal, rename, placement, gesture, option/default, platform gate, refresh/sync behavior, Siri/App Intent, widget, or error-state change, review the matching topics in `Raul/Features/Help/UserGuideView.swift` in the same change. Update the steps, examples, search aliases, related topics, availability notes, and safe actions, or record why no guide change is needed. Add a topic for each major new feature.
- Keep guide actions aligned with real app navigation and guard actions that need a selected episode, podcast, downloaded file, transcript, or supported OS. Opening help must not perform a destructive or bulk action. Never create arbitrary `upnext://` URLs for guide navigation.
- Use current app terminology and verify behavior in source and the current UI. Mark platform and OS limits plainly; do not describe DEBUG-only, experimental, or planned functionality as generally available.
- Keep examples anonymized and offline. Use screenshots only from reproducible preview/UI-test fixtures with sample titles and transcripts; never capture account state, credentials, private feed URLs, or listening history. Record the source screen, platform/OS, locale, and last-verified app version alongside each screenshot. Do not invent a screenshot of UI that is not present in the app.
- Review `Documentation/UpNextViewHierarchy.md` for hierarchy changes. The guide registry and article content are currently maintained with the SwiftUI guide module. Update the registry, searchable aliases, related-topic IDs, and guide actions together when topics change. Validate that IDs and related links resolve, search covers titles/aliases/article copy, and routes point to supported destinations; run applicable guide and screenshot checks when present.

## Xcode build artifacts

Never create DerivedData, build products, test results, or other generated
Xcode artifacts inside the repository.

Do not use paths such as:

    .derivedData
    .derivedData-*
    build
    build-*

For temporary validation builds, use a directory outside the repository,
preferably under:

    $TMPDIR/PodcastClient/

or:

    ~/Library/Caches/PodcastClient/

Temporary build directories created by an agent must be removed after the
validation run unless they are deliberately being retained for debugging.

## Public broadcaster discovery

- Resolve broadcaster catalogue entries to a validated RSS/Atom feed before
  handing them to the ordinary `PodcastFeed` and subscription flow. Keep
  provider APIs and response models behind the discovery provider.
- Treat publisher and Apple title matches as candidates, not proof. Confirm the
  publisher and complete programme identity, then validate the feed with
  `PodcastFeedResolver`; never substitute a partial or stale feed on title
  similarity alone.
- For ARD Sounds, keep official ARD metadata and publisher-advertised feeds
  ahead of Apple lookups. Only after those sources fail may a verified
  `urn:ard:show:…` be sent to `https://ardsounds.tisba.de/show/{urn}` as a
  silent ordinary-RSS fallback. Parse and validate that response through
  `PodcastFeedResolver`, cache successful resolution briefly, and never make
  this request while browsing. Treat the hosted generator as an external
  dependency and keep its URL and user/library data out of diagnostics.
- Keep discovery network work off catalogue browsing paths. Bound resolution
  requests, propagate cancellation, cache successful results for a limited
  time, and keep diagnostics free of private feed URLs and user identifiers.
- A non-RSS source needs a separate architecture review of podcast/episode
  identity, split SwiftData stores, authoritative CloudKit synchronization,
  restoration, history/bookmarks, playlists, queue, downloads, refresh, and
  OPML before any persisted source change. Never store a fabricated RSS URL.

## User Guide maintenance

- Treat accurate user help as part of every user-visible feature change. Check
  the relevant guide topics, Settings help, and Siri guide in the same change;
  update steps, control labels/locations, outcomes, requirements, aliases,
  cross-links, actions, availability, and fixture-based screenshots where they
  exist. Keep `Documentation/UpNextViewHierarchy.md` aligned when actions move.
- Until the canonical searchable guide under `Documentation/UserGuide/` and its
  app module land, do not create an alternate guide location. Record missing
  topics and content changes in GitHub issue #347, and explain the guide gap in
  the feature PR.
- Guide routes must target real UI and safely handle missing context or
  unsupported platforms. Opening help must never trigger destructive or bulk
  actions. Keep examples offline and anonymized; do not invent screenshots or
  describe experimental or DEBUG-only behavior as generally available.
