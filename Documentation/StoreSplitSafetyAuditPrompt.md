# Agent Prompt: Store-Split Safety Audit

Written after the 2026-08-22 duplication incident on a development device.
Use this prompt from the repository root. It is an **audit and hardening**
brief, not a migration brief — for the latter see
`FinishStoreSplitMigrationCodexPrompt.md`.

```text
Audit the SwiftData store-split, migration, and legacy-compatibility code in
this repository for data-integrity hazards, with particular attention to what
would happen on App Store installations. Produce findings and a hardening
plan. Do not perform destructive operations on any store.

## Why this audit exists

On 2026-08-22 a development device (iPhone 15 Pro, dual-write mode) was found
with most podcasts duplicated, 154 PlaylistEntry rows for a queue of about 8,
and a lifetime listening total of 1069h instead of roughly 350h. Nothing had
been deleted; everything had been duplicated.

Root cause, confirmed from git history and the container configuration:
CloudKit mirroring on the legacy store `SharedDatabase.sqlite` was disabled by
commit 9c7ddeae (2026-08-17) and re-enabled by commit 0d0f3f77 (2026-08-21),
via `StoreDevelopmentConfiguration.releaseLegacyCloudSyncEnabled`, which feeds
`cloudKitDatabase: .automatic | .none` in ModelContainerManager. The device
spent four days writing to a detached store; re-attaching re-imported the
CloudKit zone and merged it alongside rows that had no matching CloudKit
identity. With no `@Attribute(.unique)` anywhere in the schema, nothing
collapsed the copies.

The critical property: that flag change is a no-op for anyone who never had
mirroring off, and destructive for anyone who did. Reading the commit in
isolation does not reveal the hazard.

## Findings already established — verify, then widen

Treat these as starting points, not conclusions. Confirm each, find every
other instance of the same class, and assess App Store impact.

1. No model uses `@Attribute(.unique)`. Deduplication is manual
   (`hideDuplicatePodcasts`) and gated on
   `modeAllowsDuplicateCleanupDuringProjection`, which is now hardcoded
   `true`, making the gate vestigial. Determine whether uniqueness can be
   enforced at all under CloudKit mirroring, and if not, what invariant
   replaces it and where it is checked.

2. Unlinked relationship pairs. `Playlist.items` and `PlaylistEntry.playlist`
   are two `@Relationship` properties with no inverse between them; likewise
   `Episode.playlist` and `PlaylistEntry.episode`. SwiftData maintains them
   independently, so writers that set one side produce rows invisible to
   readers of the other. 152 of the 154 entries on the affected device were
   reachable from neither side. Contrast with `PlaySession.episode` and
   `Episode.metaData`, which do declare inverses. Inventory every relationship
   in the schema, classify by whether an inverse exists, and identify each
   writer that maintains only one side.

3. `Podcast.episodes` cascades on delete while `Episode.podcast` has no
   inverse. Re-pointing an episode without also removing it from the former
   owner's array means deleting that owner cascades into the episode. Find
   every site that deletes a Podcast (or any cascading parent) and check it.

4. Listening-summary aggregation double-counts.
   `StoreSplitUserStateImporter.applyListeningSummaries` groups
   `ListeningSummarySync` by (feedURL, periodKind, periodStart) and sums
   `totalSeconds` across rows that differ only by `sourceDeviceID` — including
   the `__legacy_shared__` migration record, which can cover the same sessions
   as the per-device rows. Introduced in 9c7ddeae. Currently dormant because
   `userStateImportEnabled` requires `.userStateAuthority`. Establish whether
   per-device summaries and `__legacy_shared__` are provably disjoint; if they
   are not, summing is wrong and needs a different reconciliation.

5. `StoreSplitListeningHistorySyncWriter.apply(_:to:)` sets
   `record.isLegacyMigrated = false` on every update. A migrated row touched by
   a live upsert therefore joins the live per-device summaries while
   `__legacy_shared__` still accounts for it. Confirm and assess.

6. Derived-data feedback loop. The importer deletes and rewrites the legacy
   `PlaySessionSummary` table from its computed sums, and
   `StoreSplitMigrationService.rebuildListeningSummaries` reads that same
   table and republishes it as the synced `__legacy_shared__` record. A
   corrupted local total can therefore be promoted to authoritative and
   propagated to every device. Map every path where derived data becomes an
   input to a synced record and break the cycles.

7. `PlayedEpisodePlaylistPruner` (uncommitted at the time of writing, now
   disabled by default) hard-deleted legacy playlist rows and wrote CloudKit
   tombstones, ran at every launch and after every import, and used a rule
   that treats "played with no completionDate" and "entry with no dateAdded"
   as unconditionally stale. Combined with `shouldPreserveTombstone` in
   `StoreSplitPlaylistSyncWriter`, which stops a correct local playlist from
   clearing a tombstone, its removals are irreversible and cross-device.
   Review the whole tombstone design: what can create one, what can clear one,
   and whether any single-device mistake can be undone.

8. `PlaylistModelActor.dequeueFinishedEpisodeAndReturnNext` calls
   `markEpisodeFinished`, stamping `completionDate`. Determine every caller —
   in particular whether skip-to-next marks an unplayed episode finished, and
   what downstream rules then act on that stamp.

9. Rollout and read authority. `StoreSplitRollout.resolvedMode` and
   `newStoreReadsEnabled` decide which store is authoritative. A device that
   switches to split-first reads before its backfill completes reads a store
   that was never populated, and the split-first path does not backfill.
   Verify the ordering guarantees and what happens on a rollback.

10. Operational visibility. Development diagnostics reported bare row counts
    with no live/tombstoned split and no legacy-versus-UserState comparison,
    and read-only actions were disabled by `splitStoreActionDisabled` in
    exactly the store modes worth diagnosing. The stores also live at the app
    group container root, which the device file service refuses to expose
    (only Library, Documents, tmp), so no support path can retrieve them.
    Assess what a support engineer or a user can actually observe and extract
    on an App Store build.

11. Contradictory standing instructions in the documentation.
    `FinishStoreSplitMigrationCodexPrompt.md` states that
    `SharedDatabase.sqlite` "is a temporary migration/recovery source only",
    "must not use CloudKit", and "must be removed after lossless migration
    verification". `StoreSplitCacheCutoverPlan.md` line 270 states the opposite:
    the file "is now permanent, not a migration artifact". The second matches
    the confirmed product strategy. The first is a standing instruction to
    delete the durable library store. Reconcile the documents and make the
    surviving statement unambiguous; treat this as a correctness issue, because
    an agent acting on the stale instruction destroys the library.

## Workstream: synced-schema classification

The confirmed product strategy is: everything reconstructible from podcast
feeds lives in local-only stores (`SharedDatabase.sqlite` as the durable
library store, `PodcastCache.sqlite` as the feed/device cache), and only
user-owned state lives in `UserState.sqlite`. The purpose of the split is a
*small* synchronized store that syncs quickly between devices. Audit the
current classification against that purpose, not merely against the allow-list.

The synced schema is nine entities: SubscriptionSync, EpisodeStateSync,
QueueEntrySync, PlaylistSync, PlaylistEntrySync, BookmarkSync,
PodcastPreferenceSync, ListeningSummarySync, ListeningHistorySync.

Answer these:

- `ListeningSummarySync` is derived data. It is computed from
  `ListeningHistorySync`, which is itself synced, and its identity is
  (feedURL, periodKind, periodStart, sourceDeviceID). `PlaySessionSummaryPeriod`
  has five cases, so each feed listened to on a given day produces day, week,
  month, year and forever rows — per device. Estimate its real cardinality for
  a multi-year, multi-device library and compare it against the other eight
  entities. Determine whether it is the largest table in the store the split
  exists to keep small.
- Establish the general rule: should derived aggregates sync at all, when every
  device already holds the history needed to recompute them locally? Note that
  the cross-device summing of these aggregates is the defect that produced the
  incorrect lifetime total in the incident, so removing them from the synced
  schema would eliminate a bug class rather than fix one instance.
- Decide what listening history requires: full session records, compact
  records, or nothing synced at all. This is a product question about whether
  statistics are per-account or per-device. Surface the trade-off and its
  payload consequences; do not silently pick one.
- Check for feed-derivable fields that leaked into synced entities.
  `EpisodeStateSync.duration` is one known instance. Find the rest.
- `UserStateCloudSchemaAudit` asserts an allow-list of synced types. Determine
  whether it constrains payload *size and cardinality* or only type membership,
  and extend it to whichever it does not cover.

Note for context: during `dualSyncBackfill` both `SharedDatabase.sqlite` and
`UserState.sqlite` are CloudKit-backed, so the current iCloud payload is larger
than before the split. The intended reduction only materialises at the
cutover. Do not read present-day sync behaviour as evidence the design works.

## The question that matters most

`StoreSplitReleasePhase.current` is the cutover constant. Moving it from
`.dualSyncBackfill` to `.userStateAuthority` simultaneously detaches
`SharedDatabase.sqlite` from CloudKit and enables `userStateImportEnabled`,
for the entire installed base at once.

Analyse that transition in depth, and specifically:

- What a rollback would do. Reverting `.userStateAuthority` to
  `.dualSyncBackfill` re-attaches every user's legacy store to CloudKit after
  a period detached. That is precisely the operation that duplicated the
  development device, applied to the whole population. Determine whether this
  is true, and if so, whether a rollback is safe under any circumstances.
- Whether the shipped-version history ever put an App Store build in a state
  where legacy mirroring was off, which would mean users are already exposed.
- Whether the CloudKit RolloutConfig kill switch covers this flag, or only the
  read-authority rollout.
- What ordering, gating, or one-way-door protection makes the cutover
  recoverable rather than merely careful.

## Deliverables

1. A findings document, most severe first. For each: the mechanism, the
   affected code with file and line references, which installations are
   exposed (dev, TestFlight, App Store), whether it is currently live or
   dormant, and how it would present to a user.
2. A hardening plan, separating changes that must land before any cutover from
   changes that are follow-up.
3. Regression tests for each confirmed hazard, written against in-memory
   containers in the style of the existing UpNextTests suite.
4. An explicit statement of what remains uncertain and what evidence would
   settle it. Do not present inference as confirmation.

## Constraints

- Read-only with respect to user data. Do not run migrations, imports,
  deduplication, or any destructive development action against real stores.
- Preserve unrelated working-tree changes; the tree contains in-progress
  playlist work and incident mitigations.
- Existing known-failing tests: three in ShownotesChapterExtractorTests fail
  on clean HEAD and are unrelated to this area.
- Mitigations already in place, to build on rather than redo: the legacy
  CloudKit re-attach guard in StoreDevelopmentConfiguration, the disabled
  PlayedEpisodePlaylistPruner, LibraryDeduplicationService with its dry-run
  plan/apply split, PlaylistTombstoneRecoveryService, DatabaseBackupExporter,
  and the "Rebuild Analytics from Raw Sessions" action.
```
