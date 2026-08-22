# Store Split — Cache Cutover Plan (Phases 1–4)

Goal of this track: keep **user-generated data** (subscriptions, play state,
playlists, bookmarks) synced through iCloud in the small `UserState.sqlite`, and
keep the **bulky, feed-derivable data** (podcast/episode metadata, chapters,
transcripts) **out of iCloud** in the local-only `PodcastCache.sqlite`, so CloudKit
sync stays small and fast.

This document covers the remaining work. It complements
`Documentation/StoreSplitMigrationPlan.md` (the original architecture) and the
root `StoreSplitMigrationPlan.md` (the condensed version).

## Architecture correction (2026-08-16)

An earlier iteration of this track made the app's runtime SwiftData graph an
**in-memory** rebuild of `PodcastCache.sqlite`, produced fresh on every launch
by `StoreSplitCompatibilityProjectionService.rebuild`. That is what made the
migration visible to users: the container published to the UI was empty, so the
Library and the playlists appeared blank and then filled in gradually as the
projection paged through the cache — and any feed the bounded bootstrap had not
copied yet (15 feeds per launch, 200 overnight) simply did not exist for that
launch, which also silently dropped queue entries pointing at those episodes.

**The runtime store is on disk again.** The split that matters is the *sync*
boundary, not the file boundary:

- the existing App Group SQLite file stays the durable library store, opened
  `cloudKitDatabase: .none` — nothing is copied, nothing is rebuilt, and the
  first frame after an update shows the user's real library;
- `UserState.sqlite` is the only CloudKit-backed store and carries only compact
  user-owned state;
- `PodcastCache.sqlite` stays local-only and now holds what the model graph
  cannot express: migration checkpoints and verification, namespaced feed
  extension elements, AI revision staging, feed aliases, device-local episode
  classification, download index, and prunable raw analytics.

This delivers the product goal directly. Feed-derived data never enters iCloud,
so a new iPad or Mac downloads only the small user-state payload and rebuilds
its library from RSS, while the existing iPhone install keeps working untouched.

`DevelopmentStoreMode.newStoresOnly` still selects the in-memory projection; it
is the experimental endgame track, not a shipping mode. While it is off, the
per-refresh feed mirror and the feed-cache bootstrap are skipped, so switching
into it needs a cache reset first.

## Shipping in two phases (2026-08-17)

`StoreSplitReleasePhase.current` selects what a build does:

| | `dualSyncBackfill` (shipping now) | `userStateAuthority` |
| --- | --- | --- |
| Library store | primary, CloudKit `.automatic` | primary, CloudKit `.none` |
| UserState | written one-way, synced, never read | read authority |
| Importer (UserState → library) | **off** | on |
| `resolvedMode` | always `.splitStores` | follows the rollout |
| iCloud payload | unchanged from today | shrinks |

Phase one exists because cutting straight to phase two would simultaneously stop
syncing the legacy graph and start trusting a store never exercised in
production. Keeping the importer off in phase one also removes the full
projection pass, which was the dominant source of the write volume that got the
app killed for CPU on 2026-08-17.

## Current implementation status (2026-08-16)

Three SwiftData stores exist:

- `SharedDatabase.sqlite` — the durable library store and the migration source.
  CloudKit-backed during `dualSyncBackfill`, local-only from
  `userStateAuthority` onwards.
- `UserState.sqlite` — user-owned state, CloudKit `.automatic`.
- `PodcastCache.sqlite` — local-only (`cloudKitDatabase: .none`).

Key facts that shape the shipped cutover:

- Model-bound surfaces read the durable library store directly. `Podcast`,
  `Episode`, `Playlist`, and `Bookmark` rows are never recreated at launch.
- `PodcastCacheRepository` returns Sendable snapshots for code that wants to
  resolve by logical key; it batches UserState overlays and follows `FeedAlias`.
- `splitStoresEnabled` is frozen at launch. `newStoreReadsEnabled` is evaluated
  live in release builds, so a device that classifies itself during a launch
  starts applying synchronized user state in that same launch instead of the
  next one — this is what lets a fresh iPad populate on first run.
- The read cutover requires **slice-migration completion**. Lossless
  verification is a separate, stricter gate that only controls physically
  retiring the legacy file; making reads wait for it stranded devices behind a
  single unmigratable row.
- The backfill is automatic and needs no user interaction. It is queued at
  launch, on every foreground, and by a `BGProcessingTask` that requires external
  power so it can finish overnight while charging. Scheduling is gated on the
  completed migration version, not on the rollout marker, because a device can
  sit at `newStoreReads` from an older version and still owe the current one
  every phase.
- **Every run is budgeted.** 25s of wall clock in the foreground, 120s inside the
  background task, with 0.75s of idle between slices. It stops on playback and on
  backgrounding. An earlier attempt to keep migrating during playback and on the
  audio session's background time produced ~98% CPU for hours and the process was
  killed by the 80%-over-60s limit; background progress belongs to the metered
  `BGProcessingTask`, which has both a budget and an expiration handler.
- **Reconciles are watermarked.** A full projection pass walks every synchronized
  row and is hundreds of megabytes of SQLite writes on a large library, while
  reconciles are triggered by launch, foreground, and every CloudKit import
  event. The importer now compares the newest `updatedAt` across the synced
  models against the last completed import and skips the pass entirely when
  nothing arrived. Hourly statistics are rebuilt only when history actually
  moved, not after every reconcile.
- **Episode-state republishing is change-gated.** `setPlayPosition` publishes
  every ten seconds during playback; the writer now compares against the stored
  record and returns without writing when nothing material changed, so playback
  no longer produces a synced write and a CloudKit export every tick.
- DEBUG builds keep a `StoreSplitMigrationDebugLog` in App Group defaults and
  post a passive local notification per finished phase, so an overnight
  background pass leaves evidence either way: an empty log after a night on the
  charger means iOS never ran the task, not that the migration found no work.
- Sessions recorded while the runtime graph lived in memory never reached the
  library store and survive only in `ListeningHistorySync`. Because the
  `dualSyncBackfill` importer is off, nothing projects them back on its own — a
  DEBUG "Recover Listening History from Split Stores" action runs that one
  projection on demand (`StoreSplitUserStateImporter.applyListeningHistoryOnly`).
  It deduplicates by canonical aggregation key and by matching equivalent local
  sessions, so repeating it cannot inflate the statistics. Deliberately not wired
  into launch: it is the same projection pass that dominated the write storm.
- Devices returning from the in-memory phase run a one-time additive recovery
  (`StoreSplitCompatibilityProjectionService.recoverMissingLibraryData`) that
  copies cache-only podcasts and episodes back into the durable store. It never
  deletes or overwrites a durable row and is safe to repeat.
- The UserState importer refuses to project a record older than the local row
  (`EpisodeMetaData.stateUpdatedAt`, with playback timestamps as the fallback),
  so a stale CloudKit delivery cannot rewind playback, history, or archive
  state. `maxPlayposition` still merges upwards.
- Remote **kill switch** (`RolloutConfig` record in the CloudKit *public* DB):
  `migrationEnabled=0` pauses all split-store heavy work live. The historical
  `forceLegacyReads=1` flag is also treated as a pause. See
  `Raul/App/StoreSplitRemoteConfig.swift`.

### Done

- **Phase 1 — cache models.** `CachedPodcast` / `CachedEpisode` added to
  `Raul/Shared/Models/StoreSplitCacheModels.swift` (feed-derivable fields only; no
  user state) and registered in `ModelContainerManager.makeCacheContainer`.
- **Phase 2 — cache authority + bootstrap.** `Raul/Shared/Services/StoreSplitFeedCacheWriter.swift`
  writes feed/episode data into the cache: per-feed on refresh via
  `PodcastModelActor.updateDetails` → `updateFeedCache`, plus a bounded
  `bootstrapMissingFeeds` from launch maintenance (15 feeds) and the overnight
  background pass (200). Prunes cache episodes no longer in the feed. Normal
  runtime reads now originate in this cache, either as snapshots or through the
  in-memory compatibility projection. Tests are in
  `UpNextTests/StoreSplitFeedCacheWriterTests.swift`.
- **Split-first classification.** `ModelContainerManager.classifyStoreSplitRollout`
  now defaults to reading the split store, falling back to legacy only while the
  split store is empty/partial and legacy has data.
- **Phase 3 complete — supplemental cache and read boundary.** Cache-local chapter,
  transcript-line, transcription-history, download-index, and feed-alias models
  are registered. The feed writer projects and prunes the episode-owned rows,
  accepted redirects/switches record aliases, and a per-feed schema version
  revisits existing Phase 2 cache rows exactly once. The parser now preserves
  every namespaced root subtree, and validated incoming AI content materializes
  directly into cache rows while publisher transcript/chapter rows are retained.
  AI revision manifests and payload chunks are registered only in PodcastCache,
  never in the CloudKit-backed UserState schema.
- **Analytics cutover complete.** Raw sessions, rate segments, and hourly
  contributions persist only in PodcastCache. Completed compact history and
  absolute per-device summaries persist in UserState. Runtime statistics and
  Share Pictures rebuild from deduplicated cross-device history with summary
  fallback for pruned legacy periods, apportion sessions across calendar
  boundaries, and expose a listening-by-device section.
- **Playlist upgrade recovery.** The one-time additive legacy playlist/queue
  repair publishes into UserState and is force-projected into the in-memory
  runtime graph during the same launch. Playlist feeds are force-projected
  before generic cache work even if an older version checkpoint exists, and the
  empty state performs one silent reconciliation instead of exposing migration
  status to the user.
- **Inbox preservation.** Cache schema v4 stores device-local inbox and
  suppression classification. Compatibility projection restores it before
  applying synchronized played/archive overlays, so rebuilding the cache graph
  cannot put every RSS episode into Inbox.

## Phase 3 — Read cutover

Move feed/episode **reads** off the legacy graph and onto the cache, overlaying
synced user state and falling back to legacy when the cache is absent. This is
where the payload actually stops depending on the legacy store for reads.

The direct repository surface is implemented. Model-bound screens remain
source-compatible through a temporary in-memory adapter, so their `@Query`
calls query cache/UserState-derived memory rather than `SharedDatabase.sqlite`.
This adapter is removed together with obsolete models only after the grace
period; it is not permission to reopen the disk legacy store.

### 3.0 Additional cache models (prerequisite)

Status: **implemented.** Models, versioned backfill, pruning, feed aliases,
unknown namespace capture, and validated direct AI materialization are covered
by upgrade/cache tests. Signed-device production CloudKit inspection remains a
release verification gate.

Add the remaining local-only models before cutting screens that need them:

- `CachedChapter` (from `Marker`, feed/extracted/AI chapters — keep AI-vs-publisher
  provenance).
- `CachedTranscriptLine` (publisher transcripts) and/or `CachedTranscriptionRecord`.
- `CachedDownloadRecord` (download availability / file references).
- `FeedAlias` (permanent-redirect / feed-switch mapping).

They are registered in `makeCacheContainer`, and `StoreSplitFeedCacheWriter`
populates them (chapters/transcripts remain cache-local and never enter a synced
schema). The cache projection version supplies the matching bounded bootstrap.

### 3.1 Repository layer

Implemented read repositories return **Sendable value snapshots**, not model
instances, so views never bind to a specific store:

- `PodcastCacheRepository` — feed/episode/chapter/transcript reads from cache.
- Compose with the existing user-state overlay so a screen asks for
  "episode view model for id X" and gets cache + synced state + legacy fallback.

Resolve by stable keys (`PodcastFeedIdentity`, `EpisodeStableIdentity`). Load
state in batches keyed by `EpisodeStableIdentity.key`; avoid an `@Query` per row.

### 3.2 Runtime integration cutover (gated by mode)

Every supported split-store surface receives the cache-derived runtime
container or repository/App Group snapshots. Feed refresh persists only to
PodcastCache, and user mutation writers persist only to UserState after the
cutover. The disk source is opened separately only for an incomplete migration.

1. Podcast list / Library.
2. Podcast detail + episode list.
3. Episode detail (show notes, chapters, transcript).
4. Playlist / queue views.
5. Bookmarks.
6. Player + now-playing.
7. Widgets, CarPlay, Watch, Intents, Inbox count — these read the container or App
   Group snapshots directly; repoint them last.

### 3.3 Fresh-device continuity

A device reading from cache must not show empty UI before RSS arrives. Covered by:

- Phase 2 bootstrap (copies existing legacy feed data into cache), and
- the importer's existing `feedsToBootstrap` RSS refresh for feeds present as a
  `SubscriptionSync` but missing from the cache.

Verify both on a clean install signed into an account with existing iCloud data.

### 3.4 Exit criteria for Phase 3

- All normal read paths resolve from cache + overlay; legacy fallback is opt-in
  migration safety only and is never the injected runtime store.
- Fresh-device bootstrap proven on iPhone and Mac.
- No disk-legacy `@Query`/`PersistentIdentifier` reads remain on hot paths.
  Cross-store resolution uses only feed/episode logical keys.

## Phase 4 — iCloud payload retirement

**Not done.** `StoreSplitReleasePhase.current` is `.dualSyncBackfill`, so
`releaseLegacyCloudSyncEnabled` is `true` and `makeLegacyContainer` opens
`SharedDatabase.sqlite` with `cloudKitDatabase: .automatic`. Both stores are
CloudKit-backed today, which makes the current iCloud payload *larger* than
before the split, not smaller. The reduction arrives only when the phase
constant moves to `.userStateAuthority`; present-day sync behaviour is not
evidence that the payload work is finished.

What is **not** done, and is the last real task on this track:

1. The user's old CloudKit private-database zone still holds the full legacy
   object graph from the pre-split versions. Nothing downloads it any more, but
   it still consumes iCloud storage. Reclaiming it means deleting the legacy
   Core Data zone — irreversible, so it must stay an explicit, user-initiated
   action behind the verification gate, never automatic migration logic.
2. The local `SharedDatabase.sqlite` file itself is now permanent, not a
   migration artifact. `StoreSplitLegacyCleanupService` and
   `LegacyStoreCleanupGate` therefore only apply if the experimental
   `newStoresOnly` track is ever finished and shipped.

### Sequencing / safety

- Rollback during migration uses the `migrationEnabled` remote switch; the
  library store is untouched by it, so a pause can never empty the UI.
- Watch out for: large chapter/transcript payloads must stay out of the synced
  schema (`UserStateCloudSchemaAudit` asserts the allow-list); stable episode
  identity must survive feed re-parse; extensions/widgets read the same durable
  container as the app.

## Risk register (delta from the original plan)

| Risk | Detection | Mitigation |
| --- | --- | --- |
| Runtime graph rebuilt before backfill completes | empty/partial Library and playlists after an update | keep the durable on-disk library store as the runtime container; only `newStoresOnly` rebuilds |
| Stale CloudKit record rewinds local playback | position/history/archive regress after a reconcile | `EpisodeMetaData.stateUpdatedAt` guard in the importer; monotonic fields still merge upwards |
| Verification blocked by one unmigratable row | rollout never reaches `newStoreReads` | read cutover gated on slice completion; verification gates cleanup only |
| Large transcript/chapter data leaks into a synced store | CloudKit payload does not shrink | keep chapters/transcripts in cache schema only; audit synced schema |
| Feed redirect breaks identity after cutover | state/feed missing after redirect | `FeedAlias` + explicit feed-switch handling |
| Extensions read stale/legacy data | widget/watch/intents wrong after Phase 4 | repoint to cache/App-Group snapshots in 3.2 before Phase 4 |
| Legacy sync disabled too early | second device missing data | disable only after convergence telemetry. **Not reversible via `RolloutConfig`:** the kill switch drives `splitStoreHeavyWorkPaused` only, while the legacy store's `cloudKitDatabase` comes from the compile-time `StoreSplitReleasePhase.current`. Undoing it needs a release, and that release re-attaches every detached store — the operation that duplicated the development device. |
