# Store Split Migration — Canonical Plan

This is the canonical statement of the store-split target. The detailed
implementation checklist is in `Documentation/StoreSplitMigrationPlan.md`,
and the cache read-cutover checklist is in
`Documentation/StoreSplitCacheCutoverPlan.md`.

## Final architecture (revised 2026-08-16)

The split is a **synchronization** boundary, not a file migration. The app must
have exactly one CloudKit-backed SwiftData store:

- `UserState.sqlite` — compact, relationship-free, user-owned state only.
  CloudKit `.automatic`. This is the only store that leaves the device.
- `SharedDatabase.sqlite` — the durable local library graph the UI binds to.
  Read-write, always `cloudKitDatabase: .none`. It is not a temporary migration
  artifact: keeping it in place is what makes the upgrade invisible, because no
  user data has to be copied or rebuilt before the first frame.
- `PodcastCache.sqlite` — local-only, for data the model graph cannot express:
  migration checkpoints/verification, namespaced feed extension elements, AI
  revision staging, feed aliases, device-local episode classification, download
  index, and prunable raw analytics.

The earlier plan to empty and delete `SharedDatabase.sqlite`, projecting the
library into memory from `PodcastCache.sqlite` at every launch, is retained only
as the experimental `DevelopmentStoreMode.newStoresOnly` track. Shipping it made
the migration visible: the Library and playlists were empty at launch and filled
in gradually, and feeds the bounded cache bootstrap had not reached were missing
entirely.

Only data that cannot be reconstructed from podcast feeds or local device
state belongs in `UserState.sqlite`: subscriptions, playback state, queue and
playlist structure, bookmarks, portable preferences, and compact listening
history/summaries. Feed metadata, episodes, show notes, chapters, publisher
transcripts, AI materialized content, artwork references, download indexes,
parser extensions, search indexes, raw sessions, rate segments, and device
diagnostics belong in `PodcastCache.sqlite` or ordinary local caches.

The stores must not share SwiftData relationships. Cross-store references use
normalized feed keys and stable episode identity keys only.

## Lossless migration requirements

Current users must retain all user-owned data, and must never see the migration.
Migration must:

1. Read the library store in bounded pages as the migration source. It stays the
   live store throughout; migration only *publishes* a copy of user state.
2. Import every user-state category with deterministic logical IDs,
   timestamps, tombstones, and newest-wins conflict handling.
3. Preserve custom playlists, queue order, bookmarks, subscriptions, playback
   state, portable settings, and listening summaries.
4. Never empty, rebuild, or block the library graph. A migration that has not
   run yet, is paused, or has failed must be indistinguishable from a completed
   one as far as the Library, queue, and playlists are concerned.
5. Reconcile again after delayed CloudKit delivery and on the next launch,
   refusing to project a record older than the local row.
6. Verify source/destination counts and representative field-level hashes.
   Verification gates *cleanup*, not reads: a single unmigratable row must not
   strand a device before the read cutover.

Deletion of `SharedDatabase.sqlite` must never be used as migration logic. Under
the revised architecture it is not deleted at all.

## Implemented cutover status (2026-08-15)

- `UserState.sqlite` is the only configuration that may use CloudKit;
  `PodcastCache.sqlite` and the temporary legacy configuration are explicitly
  `.none`.
- The v7 migration pages every phase and idempotently migrates subscriptions,
  episode state, custom playlists/queue order, bookmarks, portable settings,
  compact history, and device-attributed summaries. Newer destination records
  and deletion timestamps win.
- The local cache additionally persists flat raw play sessions, rate segments,
  and idempotent per-session/hour contributions. Incomplete sessions survive a
  restart for recovery; completed raw rows are prunable after compact history
  and device summaries are safely in UserState.
- Cache schema v4 stores podcast/episode metadata, chapters, publisher and AI
  transcript materialization, transcription history, download records, feed
  aliases, and canonical known/unknown namespace subtrees. Feed refresh commits
  these projections only to the local cache. AI revision manifests/chunks are
  also cache-local staging records and are absent from the UserState schema.
- Device-local inbox membership and suppression classification are restored
  from PodcastCache before synchronized overlays are applied. Feeds referenced
  by queue/custom-playlist rows are force-projected ahead of generic cache work,
  even when an older per-feed checkpoint claimed that feed was complete.
- `PodcastCacheRepository` exposes Sendable snapshots and joins cache rows to
  bounded UserState overlays by logical feed/episode keys. Legacy fallback is
  opt-in only.
- Normal launches inject the durable on-disk library container. Split-store
  preparation, migration slices, and user-state reconciliation all run off the
  launch path, so a slow or failed split-store open can never blank the UI.
- Devices upgrading from the in-memory build run one additive recovery pass that
  copies cache-only podcasts and episodes back into the durable store. It never
  deletes or overwrites a durable row and is safe to repeat.
- Source/destination counts, logical-field invariants, digests, and cache/RSS
  recoverability are persisted as a versioned verification record. Cleanup is
  refused unless verification, fallback-disablement, convergence telemetry,
  recovery, and the supported-version grace period all pass.
- Every completed session publishes a compact `ListeningHistorySync` row and
  recomputes absolute day/week/month/year/forever summary rows for its source
  device. Sessions crossing a calendar boundary are apportioned into every
  affected period while their lifetime total remains exact. Statistics and
  Share Pictures rebuild from the deduplicated, cross-device projection; the UI
  exposes totals grouped by device.
- A persisted `newStoreReads` rollout marker is version-scoped in practice: if
  the current migration version has phases left and the library store still has
  data, launch re-enters the bounded migration. A completed playlist repair is
  immediately force-projected into the runtime graph instead of waiting behind
  the normal reconciliation debounce.
- Migration v8 re-publishes local user state after the runtime store returned to
  disk, so changes made while a device read the in-memory graph — or while it
  was rolled back to local-only reads — still reach `UserState.sqlite`.
- Playlist recovery is silent in the normal UI; migration status remains a
  diagnostic concern rather than replacing the playlist empty state.

SQLite cleanup does not run and, under the revised architecture, does not need
to: the library file is the permanent local store. `LegacyStoreCleanupGate`
remains only for the experimental `newStoresOnly` track.

## Required end state

- The library graph is durable on disk and never rebuilt at launch.
- User mutations dual-write to `UserState.sqlite`; it is the read authority for
  user state once the rollout classifies the device.
- Feed refresh writes feed-derived data only to the local library store (plus
  namespaced extension subtrees in `PodcastCache.sqlite`); none of it reaches
  CloudKit.
- `SharedDatabase.sqlite` is never configured with `cloudKitDatabase:
  .automatic`.
- CloudKit schema contains only compact user-state record types
  (`UserStateCloudSchemaAudit.allowedModelNames`).
- Library loss is recoverable by RSS refresh; user-state loss is prevented by
  migration publication and CloudKit sync.

## Completion gates

The split is complete when all of these are true:

- no feed-derived model is registered in the CloudKit-backed store;
- no normal code path writes feed-derived data to a CloudKit-backed store;
- an update from an App Store build shows a fully populated Library, queue, and
  playlists on the first frame, with no migration-dependent empty state;
- a fresh install on a second device with the same iCloud account reaches the
  same subscriptions, queue, playback positions, playlists, and bookmarks after
  RSS bootstrap, without downloading a full object graph from iCloud;
- delayed-sync, duplicate-delivery, unsubscribe-tombstone, feed-redirect, and
  interrupted-migration retry paths are covered by tests;
- CloudKit production schema and payload inspection confirm that feed-derived
  data is absent.

Reclaiming the legacy CloudKit zone left behind by pre-split versions is a
separate, irreversible, explicitly user-initiated action — never automatic.
