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
behavior. Those require the separate device validation gate. No measurements
are recorded here until a reproducible command is run on a named environment.

## Current refresh behavior relevant to profiling

Foreground Manual Refresh All defaults to four bounded feed operations. Set the
device-local `PodcastRefreshNetworkConcurrency` default to `1` for the serial
fallback or to `2`/`3` for a reduced pool. Network and parser work can overlap;
`PodcastFeedCommitCoordinator` admits one SwiftData feed-graph import at a
time. The per-origin HTTP limit is two. A 429 `Retry-After` pauses queued work
for that origin without stalling other hosts, and canceled writer/network
waiters are removed.

Feed graph saves release the writer before Inbox, smart-playlist, Spotlight,
and deferred automatic-download work. Feed invalidations are coalesced. A
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
