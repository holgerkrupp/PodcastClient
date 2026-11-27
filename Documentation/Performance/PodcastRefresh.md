# Podcast refresh profiling and regression suite

Refresh emits Points of Interest signposts for the full feed refresh, HEAD
preflight, GET/XML parse, episode-store commit, and per-feed completion. The
completion event includes a run ID, hashed feed ID, scheduled/completion
ordinals, result, update/new-episode counts, feed wall time, cumulative process
CPU, and process physical footprint. Writer acquire/release/cancel events add
queue depth, wait time, and permit hold time. These fields intentionally omit
raw feed URLs, query strings, credentials, titles, and listening-history data.

Use `Instruments` to attribute allocations, SQL work, and writer wait/hold to
individual stages. Process CPU and memory are run-level samples; they do not
prove that one feed retained memory or consumed a particular amount of CPU.

## Deterministic fixture server

Start the local server from the repository root:

```sh
python3 Scripts/podcast-refresh-fixture-server.py --feeds 100 --episodes 10 --delay 0.05
```

Every feed endpoint is `http://127.0.0.1:8787/<profile>/<number>`. The server
also provides `POST /__reset` and `GET /__stats`; stats contain only method,
profile, feed number, page, status, and server-side duration. Query parameters
can override `episodes`, `delay`, and (for the changing fixtures) `revision`.

Profiles used by the automated suite are:

| Profile | Behavior covered |
| --- | --- |
| `fast`, `slow-head`, `slow-get` | Baseline, delayed HEAD, delayed GET, and cancellation timing |
| `unchanged` | Stale/unchanged HEAD that should avoid a GET |
| `head-unsupported` | HEAD 405 followed by GET; later conditional GET 304 |
| `changed` | A body whose description changes on each GET |
| `stale-last-modified` | Changing RSS with an intentionally stale HEAD timestamp |
| `paged` | Two-page RSS with a continuation and `Link` header |
| `large`, `large-history` | Larger catalogs and retained playback/archive state |
| `private` | HTTP Basic `fixture` / `password` authentication |
| `rate-limited` | One 429 with configurable `Retry-After`, then 200 |
| `malformed`, `server-error` | Parse and HTTP failure paths |
| `redirect-301`, `redirect-302`, `redirect-307`, `redirect-308` | Redirect to `/fast/<number>`; the stored feed URL must not change |
| `gone`, `missing` | 410 and 404; the subscription stays with a feed-health status |

The fixture server is local and deterministic, but it is still an HTTP server:
the app's per-origin limit of two requests can affect wall time when four
workers are selected. Reset it between independent scenarios.

## Automated checks

`UpNextTests/PodcastRefreshPerformanceRegressionTests.swift` separates
correctness from timing:

- `testFixtureCorrectnessMatrixPreservesStateAndHTTPSemantics` covers unchanged
  HEAD, HEAD 405, GET 304, changed RSS, stale Last-Modified, paginated imports,
  a larger history-bearing import, 429/Retry-After recovery, and private-feed
  authentication. It asserts episode identity/counts, no duplicate page rows,
  playback position/archive state, and successful-parse timestamp behavior.
- `testFixtureCancellationLeavesNoPartialImport` interrupts a delayed GET and
  checks that no incomplete feed graph or successful-parse timestamp remains.
- `testPlaybackActiveBackgroundRefreshPolicyIsSerialAndBounded` covers the
  headless policy boundary supported by the test target: playback permits one
  feed and one worker. It does not start real audio.
- `testFixtureRefreshPerformanceMatrixAndOrderEffect` is opt-in. It runs five
  sorted and five deterministic shuffled repetitions for 10, 50, and 100 feeds
  with one and four workers. It prints p50/p95 and sorted-vs-shuffled p50, then
  applies only a broad order-delta guard to detect a fast-first/slow-last
  effect. It does not establish a hardware baseline.
- `testFixturePerFeedTimingEarlyVersusLateInShuffledOrder` is opt-in (#430).
  It shuffles 10/50/100 feeds (every fourth is `slow-head`) for five
  repetitions per worker count, in a HEAD-only mode and a GET + first-import
  mode. `refreshAllPodcasts(feedTiming:)` reports each feed's value-only
  duration and scheduled ordinal; the test prints per-feed p50/p95 for the
  first and last third of the schedule plus the median same-feed
  late-minus-early delta.

`UpNextTests/PodcastRefreshLargeCatalogTests.swift` (opt-in, #432) imports
10/1k/5k-episode feeds into an on-disk store and times the first import (with
and without feed durations), a refresh where every parsed episode is known,
an untrimmed re-import that matches every row through the bounded GUID/URL
lookup, and relationship traversal versus a scoped fetch for collecting known
identities.

`UpNextTests/PodcastRefreshLifetimeTests.swift` (#433) checks that prepared-feed
spool files are removed after success, error and cancellation, that stale
spool files are swept, that cancelled writer waiters neither keep nor consume
the permit, and that an abandoned refresh flight is cancelled and never
handed to a new caller.

The correctness suite skips when the fixture server is not running. Run the
focused correctness checks with build products outside the repository:

```sh
DERIVED_DATA="$TMPDIR/PodcastClient/DerivedData"
xcodebuild test \
  -project 'Up Next.xcodeproj' \
  -scheme UpNext \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:UpNextTests/PodcastRefreshPerformanceRegressionTests
```

Run the timing matrix separately. Five repetitions per order, feed count, and
worker count are intentional; expect it to take materially longer than the
correctness checks:

```sh
PODCAST_REFRESH_PERFORMANCE=1 \
PODCAST_REFRESH_FIXTURE_DELAY=0.01 \
xcodebuild test \
  -project 'Up Next.xcodeproj' \
  -scheme UpNext \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath "$TMPDIR/PodcastClient/DerivedData" \
  -only-testing:UpNextTests/PodcastRefreshPerformanceRegressionTests/testFixtureRefreshPerformanceMatrixAndOrderEffect
```

If the named simulator is unavailable, select an installed iOS simulator with
`xcrun simctl list devices available`. Do not substitute simulator timings for
physical-device or iCloud measurements. Keep any derived data and test results
under `$TMPDIR/PodcastClient/` or another directory outside the repository.

Environment variables reach the test runner with the `TEST_RUNNER_` prefix,
for example `TEST_RUNNER_PODCAST_REFRESH_PERFORMANCE=1 xcodebuild test ...`.
If parallel test clones hang at launch (the host blocked in a synchronous
`UNUserNotificationCenter` call), run the focused classes with
`-parallel-testing-enabled NO`.

## How to interpret timing output

The timing test prints one line per feed count and worker count, including all
samples' p50/p95 and the sorted/shuffled p50 values. Preserve the raw test
output with the simulator model, OS, Xcode/Swift version, commit, fixture
arguments, and whether the run was cold or warm. Do not turn those numbers
into a product baseline without repeating them on the target hardware.

An order effect is a regression signal only when the sorted versus shuffled
difference exceeds the test's broad tolerance and reproduces across the five
repetitions. Inspect signposts and `/__stats` request sequence before
attributing it to SwiftData retention: slow fixtures, the two-request
per-origin limit, parser work, the serialized writer, and trailing invalidation
work can all change the tail.

The suite does not claim physical-device RSS, CloudKit export/import,
Instruments SQL/fault counts, scrolling, or real playback-interruption
behavior. Those require the separate device validation gate (#438).

## Recorded fixture results (simulator)

Environment: iPhone 17 simulator, iOS 27.2 SDK, Xcode 27.2 (27B52), Debug
build, warm runs on 26 November 2026 at base commit `d16fedbb` plus the
uncommitted #430/#432/#433 changes. Fixture server:
`--feeds 100 --episodes 1 --delay 0.05`; tests use `delay=0.01` and
`episodes=10` per feed. These numbers show shape and scaling only, not a
device baseline.

Per-feed time by schedule position, five shuffled runs each (ms):

| Mode | Feeds | Workers | Feed p50/p95 | Early third p50/p95 | Late third p50/p95 | Same feed late−early (median) | Run wall p50 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| HEAD only | 10 | 1 | 6 / 21 | 7 / 21 | 6 / 20 | 0 | 97 |
| HEAD only | 10 | 4 | 10 / 24 | 10 / 24 | 13 / 21 | −3 | 42 |
| HEAD only | 50 | 1 | 6 / 22 | 6 / 22 | 6 / 22 | 0 | 517 |
| HEAD only | 50 | 4 | 11 / 25 | 11 / 24 | 11 / 27 | −2 | 181 |
| HEAD only | 100 | 1 | 6 / 22 | 6 / 22 | 6 / 22 | 0 | 1058 |
| HEAD only | 100 | 4 | 10 / 25 | 10 / 26 | 10 / 25 | 0 | 366 |
| GET + import | 10 | 1 | 32 / 46 | 33 / 45 | 31 / 42 | −2 | 343 |
| GET + import | 10 | 4 | 80 / 101 | 59 / 103 | 78 / 83 | 1 | 215 |
| GET + import | 50 | 1 | 32 / 47 | 32 / 46 | 32 / 47 | 1 | 1763 |
| GET + import | 50 | 4 | 83 / 91 | 82 / 98 | 84 / 88 | 2 | 1058 |
| GET + import | 100 | 1 | 32 / 48 | 32 / 47 | 32 / 48 | 1 | 3567 |
| GET + import | 100 | 4 | 84 / 91 | 83 / 89 | 86 / 92 | 2 | 2151 |

On identical fixture inputs, a feed scheduled late is not slower than the same
feed scheduled early (median delta at most 3 ms). The gap between early and
late p50 in the 10-feed, four-worker GET run comes from four feeds starting
before the writer queue fills, not from slowdown over time. With four workers,
per-feed GET time is about 2.6 times the serial time because imports wait for
the single feed writer and the two-request per-origin limit. The whole run
still finishes 1.7 times faster. In this harness, a "later feeds are slower"
impression matches completion order and writer queueing, not degradation
over time.

Large back catalog, single feed on an on-disk store (ms):

| Episodes | First import | First import, feed has durations | Refresh, all known | Untrimmed re-import (all matched) | Known IDs via relationship | Known IDs via scoped fetch |
| --- | --- | --- | --- | --- | --- | --- |
| 10 | 560 | 169 | 46 | 21 | 1.1 | 1.4 |
| 1,000 | 7,186 | 4,097 | 63 | 142 | 36 | 37 |
| 5,000 | 34,753 | 31,858 | 177 | 543 | 143 | 120 |

- A changed feed whose parsed episodes are all known costs about 0.03 ms per
  stored episode. Most of that is collecting known identities, which still
  visits every stored episode once. A scoped fetch with `propertiesToFetch` is
  no faster than the relationship traversal, so that code was left unchanged
  (documented exception).
- The bounded GUID/URL lookup matches 5,000 parsed items in about 0.5 s.
- First imports cost about 6 ms per new episode, even when the feed provides
  durations. Each inserted episode runs two unscoped, unindexed fetches
  (`existingEpisodeURL`, by `guid` and by `url`) across the whole Episode
  table. Indexing those columns needs a schema change plus the existing-store
  index backfill, so it is left for a separate change.
- New episodes without `itunes:duration` used to read the remote MP3 while
  holding the feed writer. That read now runs after the writer is released,
  so other feeds' imports no longer queue behind those network requests.

## Current refresh behavior relevant to profiling

Foreground Manual Refresh All defaults to four bounded feed operations. Set the
device-local `PodcastRefreshNetworkConcurrency` default to `1` for the serial
fallback or to `2`/`3` for a reduced pool. Network and parser work can overlap;
`PodcastFeedCommitCoordinator` admits one SwiftData feed-graph import at a
time. Prepared feeds above 6 MiB wait for the writer as a temporary spool file
that is deleted when the prepared value is released; Manual Refresh All also
removes spool files older than a day, which are left behind only when the
process was terminated. The per-origin HTTP limit is two. A 429 `Retry-After` pauses queued work
for that origin without stalling other hosts, and canceled writer/network
waiters are removed.

Feed graph saves release the writer before remote MP3 duration reads for new
episodes, Inbox, smart-playlist, Spotlight, and deferred automatic-download
work. Feed invalidations are coalesced. A
durable first-page seed is published before a paginated continuation is
fetched, and a partial import invalidates its validator so a retry cannot be
mistaken for a successful refresh.

Successful GET validators are committed only after the feed import commits.
HEAD is advisory: a 405, missing header, or stale Last-Modified is allowed to
fall through to a GET when the request policy requires it. Regular refreshes
may use a committed ETag/Last-Modified validator for a bounded period; a valid
304 leaves the last successful parse time unchanged. Manual single and due
release requests use an unconditional GET.

The refresh changes covered here are internal performance/correctness work;
they do not change user-facing controls or guide navigation, so no in-app User
Guide topic is required for this test-only documentation update.
