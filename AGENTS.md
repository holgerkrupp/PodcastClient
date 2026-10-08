# Repository Instructions

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

## Startup and loading UX

Do not introduce a full-screen loading or spinner view that blocks the app at
startup when the primary app container is already available. Render the main
content as soon as it can be used and keep remaining initialization work
asynchronous and out of the launch-critical path. Reserve a launch error or
retry view for genuine initialization failures, not normal readiness or
background setup.

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
