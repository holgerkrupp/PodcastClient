# Add Podcast and Browse performance protocol

This protocol tracks epic #215 and baseline issue #216. It separates network
latency from main-thread work and records device evidence before claiming a
speedup. The source audit baseline was `452afbc03734167339099f38c86c65d7865c5058`.

## Scenarios

Run each scenario in a Release build on a representative 60 Hz iPhone and a
ProMotion iPhone. Repeat with cold and warm artwork caches, and with Artwork,
Adaptive Color, and Uniform styles.

1. Open Add Podcast, type a six-character query, display and scroll 50 results.
2. Open a result, display the first 20 episodes, scroll through at least 200,
   open episode detail, then return.
3. Repeat with local libraries of 0, 500, and 2,000 podcasts.
4. Use feeds with 50, 500, and 5,000 episodes; repeat with RFC 5005 pages,
   malformed-but-repairable XML, and rich Podcasting 2.0 metadata.
5. Switch alternative feeds and regions rapidly; refresh while scrolled; repeat
   after background/foreground and with private authenticated feeds.

Use Time Profiler for CPU attribution, SwiftUI Instruments for body updates,
Core Animation Hitches for frame pacing, Allocations for peak memory, Network
for requests/bytes, and SwiftData/Core Data SQL for fetch counts. Record server
latency separately from feed download duration and parser CPU time.

## Signposts

The `Podcast Discovery` Points of Interest log contains intervals for catalog
search, chart loads, subscription-index construction, browse downloads, and
browse parsing. Counts are public integers only; URLs, query text, credentials,
and feed contents must never be included in signpost messages.

## Regression budgets

- Exactly one subscription-index build per discovery screen entry or library
  membership change; no whole-library query owned by a result row.
- Exactly one XML parse per fetched feed document per browse generation.
- No more than one active page download/parse per feed generation.
- Episode append and duplicate filtering must stay linear in parsed items, with
  constant-time membership checks.
- Record navigation-to-header and navigation-to-first-episode p50/p95, main
  thread time, frame hitches, peak memory, network requests, and SwiftData
  fetches. Establish device-specific numerical latency and memory limits after
  collecting the baseline rather than asserting unmeasured speedups.

## Results log

| Revision | Device / OS | Build | Scenario | p50 / p95 | Hitches | Peak RAM | Network / DB / parse counts |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Baseline | Not recorded yet | Not recorded yet | Not recorded yet | — | — | — | — |
| After | Not recorded yet | Not recorded yet | Not recorded yet | — | — | — | — |

No real-device Instruments capture has been recorded in this workspace yet.
Keep #216 and the parent epic open until the table contains measured baseline
and after values for both device classes.
