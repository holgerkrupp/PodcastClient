# Podcast refresh profiling

The refresh code emits Points of Interest signposts for the full feed refresh,
HEAD preflight, GET/XML parse, and the episode store commit. Refresh log records
include a random run ID and a short SHA-256 feed correlation ID. They do not
include credentials, query strings, or raw feed URLs in the correlation field.

## Deterministic HTTP fixtures

Start a local fixture server:

```sh
python3 Scripts/podcast-refresh-fixture-server.py --feeds 100 --episodes 10
```

Each feed is available at `http://127.0.0.1:8787/<profile>/<number>`. The
profiles are `fast`, `slow-head`, `slow-get`, `unchanged`, `head-unsupported`,
`malformed`, `paged`, `private`, `large`, `dynamic`, `rate-limited`, and `server-error`.
Use `--delay` to set the simulated network delay and `--episodes 5000` for a
large back catalogue. The `private`
fixture expects HTTP Basic credentials `fixture` / `password`. The server logs
method, profile, feed number, page, and status, so HEAD/GET counts can be
compared with Instruments without exposing request secrets.

Configure test subscriptions to a mix of profiles and feed numbers. Capture
Manual Refresh All, one-feed refresh, foreground-quiet refresh, and a background
refresh separately in Instruments using the Points of Interest instrument.
Record total duration, each signpost duration, HEAD/GET counts, episode counts,
save counts, peak resident memory, and CloudKit export activity. Run 10, 50,
and 100-feed sets, repeat each set at least five times, and report median and
p95. Do not use a simulator result as an iPhone or iCloud stress result.

The checked-in fixture and signposts provide reproducible measurement inputs;
no device-specific baseline is claimed by this document.

## Current worker and validator behavior

Foreground Manual Refresh All defaults to four bounded feed operations.
Set the device-local defaults key `PodcastRefreshNetworkConcurrency`
to 1 for the serial fallback, or 2–3 for a reduced worker pool. Their
HEAD, GET and XML work can overlap; `PodcastFeedCommitCoordinator` admits one
SwiftData feed-graph import and cache projection at a time. Automatic background runs retain their existing
small feed counts and time budgets. HTTP requests are limited to two at a time
per origin, and a 429 Retry-After pauses that origin's queued requests.
Tasks canceled while waiting for the writer leave its queue without taking a
permit. A commit that already started finishes its current feed batch and
saves before honoring a background stop request.

The worker pool bounds prepared results to four. Parsed results estimated over
6 MiB spool to an app temporary file while waiting for the writer; the file
is removed when the prepared result is released. The writer reconstructs the
legacy import dictionary only after acquiring its gate. This caps retained
in-memory prepared trees to roughly 24 MiB across waiting workers, apart from
the active writer and transient download/parse buffers.
Validated first-page seeds use the same typed, Sendable handoff so the refresh
can reuse them without a second first-page GET or XML parse; paged feeds still
commit their durable first page before fetching the continuation.
`PodcastRefreshNetworkPreparer` accepts value snapshots for endpoint validation
and page parsing and returns a typed complete or partial prepared feed. The
model actor revalidates the saved feed identity and materializes the legacy
import shape only after acquiring the single writer.
Page cycle detection keeps query parameters, so RFC 5005 continuations such
as `feed.xml?page=2` are distinct from the first page. Access query parameters
are carried forward only when the continuation does not supply that name.
Durable retry checkpoints retain recognized pagination parameters such as
`page` and `cursor`, while omitting credential parameters from the retry file.

A successful GET stages its ETag and Last-Modified headers locally. The
validator is reusable only after the feed import commits successfully. When
HEAD is inconclusive, a regular refresh may use that validator for up to six
hours; a valid 304 leaves the last successful parse time unchanged. Manual
single and due-release/live requests use unconditional GET. Partial imports
invalidate the validator so their retry checkpoint cannot be skipped. Validator
keys also change when a private feed's effective credential changes.

The fixture's `dynamic` profile changes the standard RSS description and a
`podcast:liveItem` from pending to live on consecutive GETs. The simulator
integration test in `ModelContextExistingModelTests` checks a manual single
GET followed by a regular HEAD plus GET updates both stored values, even when
the publisher's HEAD timestamp is stale for a time-sensitive live item. The same suite includes a
50-feed network fixture comparison at concurrency 1 and 4. Start the server
with `--feeds 100 --delay 1` before running either fixture test; they skip
when the server is absent.

On 2026-10-08, the iPhone 18 Pro iOS 27 simulator completed the deterministic
50-feed slow-HEAD fixture (`--delay 1`, one episode per feed) with the two-per-origin
limit: concurrency 1 took 51.96 s and concurrency 4 took 25.31 s, a 51.3%
shorter wall time. Every feed returned an unchanged HEAD result, with zero GETs
or feed-graph commits. Per-feed total p50/p95 were 1.016/1.121 s at
concurrency 1 and 2.020/2.038 s at concurrency 4; parallel workers spend some
time queued behind the per-origin limit while total run time falls.
This is the network-bound fixture result; it does not measure iCloud export,
large XML parsing or device memory pressure.

The HEAD-unsupported fixture also passed an end-to-end check: the first run
issued HEAD 405 then GET 200; the second issued HEAD 405 then conditional GET
304. The successful XML parse timestamp remained unchanged on the 304.

The iPhone Duo simulator passed 71 focused private-feed, endpoint, pagination,
retry, and request-policy tests. Five additional end-to-end fixture tests passed
after the value-snapshot change: query-paged import, live/description updates,
HEAD 405/GET 304 timestamps, repeat-refresh user state, and HTTP failure
timestamps. Three preparation-stage tests passed, including four simultaneous
network/parser preparations without a ModelContext. Debug app builds succeeded for iOS simulator, unsigned iPhone, and
macOS. These results do not include a signed iPhone or iCloud export run.

A 100-feed unchanged run reported all 100 completions, and a ten-feed GET/import
run repeated at four workers retained exactly ten episodes. These checks used
an in-memory simulator store without CloudKit mirroring.

Physical iPhone and iCloud-enabled stress checks are required before treating
the epic's release gate as complete. Simulator timings do not establish that
gate.
