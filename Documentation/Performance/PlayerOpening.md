# Full Player Opening Performance

## Instrumentation

The `PlayerOpening` signpost category records these stable events and interval:

- `Mini player tap` and the `Mini player open` interval begin at the shared open-player action.
- `Player presentation requested` records the sheet or regular-width overlay state change.
- `Player first meaningful frame` and `Artwork hero prepared` (or `Artwork hero awaiting image`) record the first `PlayerView` layout.
- `Player transport controls responsive` ends the open interval when the transport controls are present.
- `Player availability query` measures the background SwiftData query used to decide transcript, chapter and AI-action availability.
- `Player availability cache hit` records a repeat open served from the scalar availability cache.
- `Shownote parse` measures parser work; `Shownote visible` records when the shownotes surface enters the view hierarchy.

The signpost payloads contain no episode URLs, titles or shownote content. The query interval is emitted from `PlayerContentAvailabilityModelActor`, not from the main actor.

## Reproduction and measurement

Use a Release build installed on a physical device. In Instruments, record Points of Interest, Time Profiler, SwiftUI, and Animation Hitches together. For each scenario, collect at least 20 opens and report median and p95 for tap-to-first-meaningful-frame and tap-to-responsive-controls. Record main-thread stalls and animation hitch count over the same opens. Keep Instruments and device power/network state consistent between before and after runs.

Run the compact iPhone sheet and regular-width overlay separately. Repeat cold and warm opens, with playback playing and paused. Use fixtures covering no and long transcripts, no and many chapters, short and large shownotes, and cached and uncached artwork. Include normal and increased contrast. Capture a screen recording of the resting and scrolled player when checking the hero and pinned-control behavior.

| Device / OS | Presentation | Fixture | Opens | Median first frame | P95 first frame | Median controls | P95 controls | Main-thread stalls | Hitches |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| Physical iPhone (record model and OS) | Compact sheet | Record fixture | — | — | — | — | — | — | — |
| Slower supported iPhone (record model and OS) | Compact sheet | Record fixture | — | — | — | — | — | — | — |
| Physical iPad (record model and OS) | Regular-width overlay | Record fixture | — | — | — | — | — | — | — |

No physical-device baseline has been recorded in this checkout. Simulator timings are not a substitute for the release-device measurements above.

## Regression matrix

Before release, repeat the timing sample for cold/warm open and playing/paused states. Check compact portrait and landscape, regular-width overlay, and the iPhone Duo layout. Check repeated open/dismiss/open and episode switching during presentation. Then exercise audio, video and live playback; AirPlay and CarPlay artwork; long transcript and large chapter fixtures; large and malformed shownotes; missing artwork; increased contrast; Reduce Motion; VoiceOver; and Dynamic Type.

On standard portrait iPhone and iPhone Duo, capture the resting and scrolled states and confirm that the same artwork grows into the hero, the inline transcript scrolls with content, the primary transport pins at the top with matching insets, and the frosted surface stays continuous. Confirm playback position and audio state are unchanged when opening and closing the player.

Record device model, OS/build, app commit, fixture IDs, cache state, sample count, median and p95 for each timing, hitch/stall counts, and any hardware-only checks that could not be run. Set numeric release budgets from the first physical-device baseline; do not use simulator wall-clock limits in CI.
