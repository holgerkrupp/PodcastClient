# Codex Prompt: Finish the Store-Split Migration

Use this prompt from the repository root.

```text
Finish the PodcastClient SwiftData store-split migration in this repository.

Target architecture:

- `UserState.sqlite` is the only CloudKit-backed SwiftData store.
- `PodcastCache.sqlite` is local-only and contains all feed-recoverable and
  device-local data.
- `SharedDatabase.sqlite` is a temporary migration/recovery source only. It is
  not part of the final architecture, must not use CloudKit, and must be
  removed after lossless migration verification and the supported-version
  grace period.

Data that must remain local-only includes podcast and episode RSS metadata,
show notes, chapters, publisher and AI transcript materialization, artwork
references/data, parser extension elements, download indexes, search indexes,
raw play sessions, rate segments, hourly raw statistics, transcription-job
history, and device-specific settings/diagnostics. Do not sync data merely
because it currently exists in the legacy graph.

Data that must remain synchronized includes subscriptions, episode playback
state, archive/played/skipped state, queue entries, custom playlist structure
and entries, bookmarks, portable preferences, compact listening history, and
device-attributed summaries. Preserve active-playlist selection as local
device preference unless the product schema explicitly requires otherwise.

Work autonomously and implement the migration; do not stop at an audit or
proposal. First inspect the repository, the three store-split plan documents,
current model schemas, migration services, all legacy container callers, and
existing tests. Preserve unrelated working-tree changes.

Required implementation:

1. Make the migration lossless for existing users.
   - Read the legacy store in bounded batches.
   - Use the existing stable feed/episode identity functions everywhere.
   - Migrate subscriptions, episode state, playlists, queue, bookmarks,
     portable settings, listening history, and summaries.
   - Preserve deletion tombstones, timestamps, custom playlist order, bookmark
     identity, and conflict semantics.
   - Make every operation idempotent and safe to retry after partial failure.
   - Reconcile after delayed CloudKit delivery and on later launches.

2. Complete the local cache.
   - Finish direct persistence of all parsed/unknown namespace extension
     elements in `CachedFeedExtensionElement`.
   - Materialize validated incoming AI transcript/chapter revisions directly
     into cache models; never copy feed-derived AI content back into the legacy
     graph as the final path.
   - Keep cache projections bounded, versioned, prunable, and recoverable by
     RSS refresh.

3. Add the repository/read layer.
   - Return Sendable value snapshots, never SwiftData model instances.
   - Compose cache metadata with batched UserState overlays.
   - Support legacy fallback only as a temporary migration safety net.
   - Resolve all data by logical feed/episode keys, never PersistentIdentifier
     across stores.

4. Cut over every read and write path.
   - Migrate library, podcast detail, episode detail, playlists, queue,
     bookmarks, player/now-playing, search, statistics, settings, widgets,
     CarPlay, Watch, intents, share extension, and App Group snapshots.
   - Remove hot-path `@Query`/fetches against legacy Podcast/Episode data.
   - Feed refreshes write only to PodcastCache.
   - After the cutover gate, user-state mutations write only to UserState.

5. Remove legacy CloudKit and legacy runtime dependency.
   - Keep the legacy configuration explicitly `cloudKitDatabase: .none`.
   - Remove legacy container/model registration from normal runtime paths.
   - Remove legacy fallback only after migration verification and convergence
     telemetry pass.
   - Do not delete `SharedDatabase.sqlite` or its `-wal`/`-shm` files until a
     final verification proves that all required user state exists in
     UserState and all feed data is available through cache/RSS recovery.
   - Then remove the legacy file and obsolete model definitions in a deliberate
     cleanup step. Never use deletion as migration logic.

Verification requirements:

- Add or update tests for upgrade migration from populated legacy data,
  duplicate CloudKit delivery, delayed sync, partial migration retry,
  unsubscribe/delete tombstones, feed redirects, changed RSS identities,
  custom playlists, bookmarks, playback state, AI content validation, clean
  install with existing CloudKit state, iPhone/macOS paths, and cache rebuild.
- Verify source/destination counts and field-level invariants before cleanup.
- Inspect the CloudKit schema/payload and prove that feed-derived data is not
  synchronized.
- Run the relevant unit tests and a build for the affected app targets. Report
  any environment-limited verification clearly.

Safety rules:

- Never run destructive commands against the workspace or user stores without
  first proving the exact target and completing migration verification.
- Do not silently drop fields, rewrite logical IDs, or replace publisher
  transcripts/chapters with AI content.
- Do not claim completion while any supported runtime path still depends on
  SharedDatabase.sqlite.
- Update `StoreSplitMigrationPlan.md`,
  `Documentation/StoreSplitMigrationPlan.md`, and
  `Documentation/StoreSplitCacheCutoverPlan.md` if implementation status or
  sequencing changes.

At the end, summarize changed files, migration invariants, tests run, remaining
risks, and the exact condition under which legacy SQLite cleanup is safe.
```
