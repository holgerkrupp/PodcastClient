# Store Split — Cache Cutover Plan (Phases 1–4)

Goal of this track: keep **user-generated data** (subscriptions, play state,
playlists, bookmarks) synced through iCloud in the small `UserState.sqlite`, and
keep the **bulky, feed-derivable data** (podcast/episode metadata, chapters,
transcripts) **out of iCloud** in the local-only `PodcastCache.sqlite`, so CloudKit
sync stays small and fast.

This document covers the remaining work. It complements
`Documentation/StoreSplitMigrationPlan.md` (the original architecture) and the
root `StoreSplitMigrationPlan.md` (the condensed version).

## Current state (as of this branch)

Three SwiftData stores exist:

- `SharedDatabase.sqlite` (legacy) — full object graph, CloudKit `.automatic`.
  **Still the UI read surface, and still syncs the bulky feed data to iCloud.**
- `UserState.sqlite` — user-owned state, CloudKit `.automatic`.
- `PodcastCache.sqlite` — local-only (`cloudKitDatabase: .none`).

Key facts that shape everything below:

- The UI reads the **legacy graph** (`Podcast`/`Episode`/`Playlist`/`Bookmark`).
  No view reads the `*Sync` models directly; `StoreSplitUserStateImporter`
  projects synced user state *onto* the legacy graph.
- `resolvedMode` is frozen at launch, so any rollout/mode change applies on the
  **next launch**.
- `newStoreReads` mode does the user-state projection but does **NOT** run the
  legacy→split backfill — only `migrating` does. Never switch a device to split
  reads before its legacy data is backfilled (or is empty).
- Remote **kill switch** (`RolloutConfig` record in the CloudKit *public* DB):
  `migrationEnabled=0` pauses all split-store heavy work live; `forceLegacyReads=1`
  reverts reads to legacy on next launch. See `Raul/App/StoreSplitRemoteConfig.swift`.

### Done

- **Phase 1 — cache models.** `CachedPodcast` / `CachedEpisode` added to
  `Raul/Shared/Models/StoreSplitCacheModels.swift` (feed-derivable fields only; no
  user state) and registered in `ModelContainerManager.makeCacheContainer`.
- **Phase 2 — dual-write + bootstrap.** `Raul/Shared/Services/StoreSplitFeedCacheWriter.swift`
  mirrors feed/episode data into the cache: per-feed on refresh via
  `PodcastModelActor.updateDetails` → `updateFeedCache`, plus a bounded
  `bootstrapMissingFeeds` from launch maintenance (15 feeds) and the overnight
  background pass (200). Prunes cache episodes no longer in the feed. **Nothing
  reads the cache yet.** Tests in `UpNextTests/StoreSplitFeedCacheWriterTests.swift`.
- **Split-first classification.** `ModelContainerManager.classifyStoreSplitRollout`
  now defaults to reading the split store, falling back to legacy only while the
  split store is empty/partial and legacy has data.

## Phase 3 — Read cutover (the large one)

Move feed/episode **reads** off the legacy graph and onto the cache, overlaying
synced user state and falling back to legacy when the cache is absent. This is
where the payload actually stops depending on the legacy store for reads.

Scope reality: ~17 files use `@Query` on `Podcast`/`Episode`, ~59 files reference
`Episode`. This cannot be one PR — do it screen by screen, each shippable.

### 3.0 Additional cache models (prerequisite)

Add the remaining local-only models before cutting screens that need them:

- `CachedChapter` (from `Marker`, feed/extracted/AI chapters — keep AI-vs-publisher
  provenance).
- `CachedTranscriptLine` (publisher transcripts) and/or `CachedTranscriptionRecord`.
- `CachedDownloadRecord` (download availability / file references).
- `FeedAlias` (permanent-redirect / feed-switch mapping).

Register them in `makeCacheContainer`. Extend `StoreSplitFeedCacheWriter.upsert`
to populate them (chapters/transcripts are large — keep them cache-local and never
in any synced schema). Add a matching migration/bootstrap slice.

### 3.1 Repository layer

Introduce read repositories that return **Sendable value snapshots**, not model
instances, so views never bind to a specific store:

- `PodcastCacheRepository` — feed/episode/chapter/transcript reads from cache.
- Compose with the existing user-state overlay so a screen asks for
  "episode view model for id X" and gets cache + synced state + legacy fallback.

Resolve by stable keys (`PodcastFeedIdentity`, `EpisodeStableIdentity`). Load
state in batches keyed by `EpisodeStableIdentity.key`; avoid an `@Query` per row.

### 3.2 Screen-by-screen cutover (gated by mode)

Gate each screen on the resolved mode (`splitStoreReads`/`newStoresOnly` → cache;
otherwise legacy) so it's reversible via the kill switch. Suggested order:

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

- All read paths above resolve from cache + overlay, with legacy only as fallback.
- Fresh-device bootstrap proven on iPhone and Mac.
- No `@Query`/`PersistentIdentifier` reads of feed data remain on the hot paths.

## Phase 4 — Stop legacy feed writes, then disable legacy CloudKit sync

This is the step that **actually shrinks the iCloud payload**.

1. Stop writing feed/episode data to the legacy store (feed refresh writes only to
   the cache). Keep user-state dual-writes for one adoption window if rollback is
   still desired.
2. Flip the legacy container to `cloudKitDatabase: .none`. Today
   `legacyCloudSyncEnabled` is hardcoded `true` in release and only toggleable in
   DEBUG — wire it to a **new `RolloutConfig` field** (e.g. `legacyCloudSyncEnabled`)
   so it can be rolled out gradually and rolled back from the CloudKit Dashboard
   without a release, alongside the existing kill switch.
3. Keep the legacy `.sqlite` file intact for a documented grace period. Do not
   delete it or remove legacy model definitions until no supported app version
   needs to open it; deletion is a separate, explicit, user-visible decision.

### Sequencing / safety

- Each phase is a separate release; the sync-size win lands only at Phase 4.
- Kill switch remains the rollback throughout (`forceLegacyReads`,
  `migrationEnabled`, and the new `legacyCloudSyncEnabled`).
- Watch out for: large chapter/transcript payloads must stay cache-local; stable
  episode identity must survive feed re-parse; extensions/widgets must be repointed
  before they can be trusted to read the cache.

## Risk register (delta from the original plan)

| Risk | Detection | Mitigation |
| --- | --- | --- |
| Cache read before backfill complete | empty/partial UI on a device | gate reads on migration-complete; Phase 2 bootstrap + RSS bootstrap |
| Large transcript/chapter data leaks into a synced store | CloudKit payload does not shrink | keep chapters/transcripts in cache schema only; audit synced schema |
| Feed redirect breaks identity after cutover | state/feed missing after redirect | `FeedAlias` + explicit feed-switch handling |
| Extensions read stale/legacy data | widget/watch/intents wrong after Phase 4 | repoint to cache/App-Group snapshots in 3.2 before Phase 4 |
| Legacy sync disabled too early | second device missing data | disable only after convergence telemetry; gate via `RolloutConfig`, reversible |
