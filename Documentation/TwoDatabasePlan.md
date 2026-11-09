# Two Databases on Every Device

Status: the target is approved; implementation is in progress. Fresh installs now build their
durable local library directly at `SharedDatabase.sqlite`. Older split-only installs with
`LibraryRuntime.sqlite` retain a checkpointed promotion path. Cache compatibility and migration
work still prevent full convergence; do not treat this document as an assertion that #394 is
done.

## Target

Every installation uses the same two active durable stores:

| Store | Permanent responsibility | CloudKit |
| --- | --- | --- |
| `UserState.sqlite` | Portable user state: subscriptions and tombstones, podcast preferences, playback/progress, queue and playlists, bookmarks, and portable listening history/baselines/summaries | Yes; the only CloudKit-backed store |
| `SharedDatabase.sqlite` | The local podcast library used directly by feeds, player, downloads, search and other features: podcast/episode metadata, chapters, show notes, local transcripts/AI content, artwork references and device-local information | Never |

`PodcastCache.sqlite` and `LibraryRuntime.sqlite` are historical implementation files, not
parts of the target runtime. Preserve existing files. Do not delete either file as part of
this work; disk reclamation requires a separate decision after replacement paths are proven.

An existing populated `SharedDatabase.sqlite` stays in place and opens locally with CloudKit
disabled. Do not copy the whole library, reattach its legacy CloudKit mirror, or overwrite it
with cache data.

## Current implementation status

- Upgraded installs open their existing `SharedDatabase.sqlite` directly with CloudKit off.
- `libraryOrigin` distinguishes legacy and built libraries. A `SharedDatabase.sqlite` with no
  origin marker is treated as legacy. Built libraries must not run the legacy UserState copy
  or subscription cleanup against an incomplete feed library.
- A fresh install writes the `built` origin before creating `SharedDatabase.sqlite` and builds
  the durable library there. It may open `PodcastCache.sqlite` for first-build compatibility
  hydration and migration; the UI still uses the durable SharedDatabase library.
- An older split-only install with `LibraryRuntime.sqlite` keeps using that durable file until
  its ready state is recorded. At a later launch, promotion checkpoints the SQLite WAL and
  exclusively renames it to `SharedDatabase.sqlite`. If promotion cannot safely complete, the
  runtime file remains available for retry.
- Feed refresh, local edits and playback analytics no longer write normal cache mirrors.
  Cache-backed compatibility hydration, one-time migration and deletion cleanup remain.
- Cache-only alignment/jobs, missing-episode references, settings/bookmark details,
  transcription history and AI transcripts/chapters migrate idempotently into the local
  library. Older AI rows without revision manifests are included, with chapter progress and
  play state retained. Cache rows remain intact as historical recovery data.
- Once cache-local migrations, AI recovery, library backfill and any legacy UserState copy
  complete, direct-library startup skips opening `PodcastCache.sqlite`. A fresh direct build
  uses the cache only while its compatibility hydration/migrations are pending. An older
  `LibraryRuntime` install may need it until the build is ready and promoted.
- Transcript alignment/jobs, unresolved episode retry records, and the cache mirrors for local
  settings/bookmark details now migrate idempotently to the local library; production callers
  use the library. Feed-alias mirroring and unused raw extension-element writes are retired.
  The runtime projection and migration-only cache readers still prevent full convergence.

The promotion step does not complete the epic by itself. The live cache dependencies below
must be migrated before normal app and extension paths can stop opening or modifying the
cache. `LibraryRuntime.sqlite` must remain usable until promotion succeeds; neither historical
file may be discarded as a shortcut.

## Remaining implementation checklist

### Bootstrap and promotion

- [x] Preserve existing `SharedDatabase.sqlite` as the local library and keep CloudKit off.
- [x] Persist a `legacy` or `built` library origin; treat an unmarked existing library as
  `legacy`.
- [x] Add checkpointed, exclusive runtime-file promotion after the projection is ready, with
  retry on a later launch if a safe checkpoint or rename is not possible.
- [x] Confirm origin checks cover crash/relaunch and every app/extension entry point. A built
  library must never trigger old-library-to-UserState copying or
  `tombstoneSubscriptionsMissingFromLibrary` based on incomplete feed data.
- [ ] Validate every starting state: populated legacy library; older split-only runtime;
  UserState plus cache; UserState only; cache only; clean install; and missing/inaccessible
  known library.
  Preserve the existing fail-closed recovery choice when prior library evidence exists.
- [ ] Confirm a completed promotion resumes any unfinished feed-fill cursor and preserves
  queue, playlist, bookmark, playback and history references through interruption/relaunch.

### Move live cache-only data and callers

Audit each model and its production readers/writers before changing schemas or deleting code.
Move required device-local data into `SharedDatabase.sqlite` or an appropriate local record,
then switch all callers before stopping cache writes:

- [x] `CachedTranscriptAlignment` and `CachedTranscriptSynchronizationJob`: transcript
  alignment and its durable sync work.
- [x] `CachedMissingEpisodeReference`: unresolved queue and playlist episode references.
- [x] `FeedAlias`: redirected feed identity has no product reader; endpoint changes persist
  directly on the local Podcast and publish the current subscription manifest.
- [x] `CachedPodcastLocalSettings` and `CachedBookmarkDetail`: canonical settings and bookmark
  fields are preserved; missing values are backfilled from cache before its row is retired.
- [x] `CachedFeedExtensionElement`: no product reader consumes raw extensions; typed namespace
  fields are already stored on the canonical podcast/episode models, so normal projection no
  longer writes duplicate raw rows.
- [x] Migrate existing AI transcripts, AI chapters and their progress to the local library,
  including older materialized rows without revision manifests. The migration does not write
  this content to UserState/CloudKit; cache source rows remain intact until separate cleanup.
- [x] Stop normal feed/edit/playback flows from mirroring podcasts, episodes, chapters,
  transcripts and analytics into cache. Cache projection is retained only for compatibility
  hydration, migration and recovery.
- [ ] Keep legacy copy/checkpoint readers only while an unfinished upgraded-device UserState
  copy needs them. Resume partial copies without double-counting history or reviving deletions.
- [ ] Audit RSS refresh, chapters, transcripts, downloads, search, playback, widgets, Watch,
  CarPlay, App Intents and share extension reads/writes against the permanent library.

Any necessary SwiftData schema change must be checked on a copy of a large real
`SharedDatabase.sqlite` first. Avoid an unexpected multi-gigabyte migration or first-launch
stall. Tests should use anonymized fixtures, never a user's database or private feed data.

### Retire obsolete infrastructure after the caller audit

- [x] Route normal feed parsing/refresh and local chapter, transcript and download metadata
  through the active durable library. Portable user changes continue to commit durably to
  `UserState.sqlite` and reconcile by stable identity.
- [ ] Remove cache mirroring/backfill/rebuild tasks, `StoreSplitFeedCacheWriter`,
  `PodcastCacheRepository`, obsolete cache-only migration slices and projection flags only
  after their callers and retained data are handled.
- [ ] Stop opening `PodcastCache.sqlite` and `LibraryRuntime.sqlite` in ordinary app or
  extension startup after their first-build, migration and old-install recovery roles are
  retired. Missing or corrupt obsolete files must not block a usable library.
- [ ] Update `AGENTS.md`, user help, diagnostics and architecture/release documentation to
  describe the shipped two-store behavior. Mark older `PodcastCache`/`LibraryRuntime`
  end-state proposals as superseded history.

## Validation before calling #394 complete

- [ ] Existing populated upgrade preserves subscriptions, library/episodes, playlist order,
  playback progress, bookmarks, downloads, transcripts and listening totals, with no whole-
  library copy and no legacy CloudKit reattachment.
- [ ] Existing split-only and fresh installs converge to the same two active stores. A second
  device receives UserState changes and rebuilds local feed data without empty or stale
  tombstones.
- [ ] Interrupt promotion/backfill, relaunch and retry; verify SQLite/WAL consistency, origin,
  late-arriving references and exactly-once portable history totals.
- [ ] Cover background/foreground transitions and player, widget, Watch, CarPlay, App Intent
  and share-extension entry points with focused tests.
- [ ] Confirm ordinary launch remains usable and does not repeatedly scan or copy the whole
  library. The under-two-second target in this plan is aspirational, not a release assertion.
- [ ] Confirm normal app/extension paths no longer open or modify `PodcastCache.sqlite` or
  `LibraryRuntime.sqlite` once first-build, migration and older split-only recovery are
  complete. Preserve their files pending a separate cleanup decision.
- [ ] Record physical-device and two-device checks tracked separately by #402; do not claim
  those checks passed without evidence.

## Safety constraints and separate work

- Never reattach `SharedDatabase.sqlite` to CloudKit, purge CloudKit metadata, reset a user's
  library, or copy an unverified cache over newer local/user state.
- Preserve queue/playlist identities, deletion tombstones, listen history and downloaded-file
  paths. Missing or late episodes must not delete queued or synced intent.
- Do not add a third persistent authority, a generic persistence framework, or a blocking
  foreground migration screen. A usable local library opens promptly.
- Keep obsolete database files intact. Stop using them first; any later file deletion needs a
  separate explicit decision and validated recovery.
- #395 (UserState CloudKit export evidence) and #359 (portable playlist identity) remain
  separate issues. This plan does not close them or claim their work is complete.
