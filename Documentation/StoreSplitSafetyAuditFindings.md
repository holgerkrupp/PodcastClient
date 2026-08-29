# Store-Split Safety Audit — Findings

Audit of the SwiftData store-split, migration and legacy-compatibility code,
commissioned after the 2026-08-22 duplication incident on a development device.
Branch: `codex/store-split-safety-audit`, from `99070a85`.

Findings are ordered most severe first. Each states the mechanism, the code,
which installations are exposed, whether it is live or dormant today, how it
presents to a user, and what was done about it.

Two of the brief's eleven starting points did **not** reproduce. Those are in
[Corrections to the brief](#corrections-to-the-brief); they matter because they
redirect attention to the mechanism that does reproduce.

---

## Exposure model

Everything below is qualified by which builds carry this code at all.

`main` is at `25ac7f07` (2026-06-12) and does **not** contain
`StoreDevelopmentConfiguration.swift`, `StoreSplitRollout.swift`,
`ModelContainerManager`'s split-store paths, or any `*Sync` model. The entire
store split lives on `codex/database-split`, 60 commits ahead of `main`.
`Config/Version.xcconfig` reads `2026.14` / build `56` on `main` and `2026.15` /
build `219` on the branch.

So the split code is not on `main` — but releases are not cut from `main`.
`codex/database-split` contains `ad639fdd` "appstore release" (2026-06-29) and
`5bd57f5a` "2026.16", both carrying `StoreDevelopmentConfiguration.swift` and the
split containers, both at build 219, which is still the branch's build number.
Build 219 shipped from this branch.

**That is itself a process risk.** Releases are cut from a long-lived feature
branch, so "is it on `main`?" is not a usable proxy for "did it ship?", and a
hazard can reach users while the mainline history shows no sign of it. The
exposure question below had to be answered from CloudKit Dashboard state rather
than from the repository, which is the direct cost of that arrangement.

`StoreSplitReleasePhase.current` is `.dualSyncBackfill`
(`StoreDevelopmentConfiguration.swift:65`). Everything gated on
`.userStateAuthority` — the whole user-state import path — is therefore dormant
in every build that exists today.

**No shipped device has been detached from CloudKit or duplicated.** That is
established, not assumed; see F2. The one remaining way it can happen to the
installed base is the cutover, which is F6 — now the top live risk in this
document.

---

## F1 — The incident-recovery toolkit does not ship

**Decided.** The owner's call is that recovery tooling stays development-only.
This is now enforced by the compiler rather than by where a view happens to be
declared, and the precondition that makes it safe is written next to the gate.

**Mechanism.** `DevelopmentSettingsView.swift:1` opens with `#if DEBUG` and wraps
the file. It is the only caller of `DatabaseBackupExporter.exportStores`
(`:673`), `deduplicateLibrary` (`:659`), `playlistTombstoneReport` (`:685`),
`restorePlaylistTombstones` (`:449`), `rebuildAnalyticsFromRawSessions` (`:340`)
and `approveLegacyCloudReattach` (`:79`). None of them has a non-DEBUG entry
point.

**Consequence.** On a TestFlight or App Store build, a user who hits the
duplication has no remedy and no diagnosis: no dedup, no tombstone recovery, no
analytics rebuild, no store export, and — most sharply — **no way to clear the
legacy CloudKit re-attach block**. If the guard fires on a release build, that
install's library store is detached from CloudKit permanently and silently, and
the only recourse is a new binary.

The store files also sit at the app-group container root, which the device file
service refuses to expose (only `Library`, `Documents`, `tmp`).
`DatabaseBackupExporter` exists precisely to stage a copy under `Library`
(`DatabaseBackupExporter.swift:21-25`) — and it is DEBUG-only, so the support
path it creates does not ship.

**Exposed.** TestFlight and App Store. Dev builds are fine.
**Live or dormant.** Live — it is a property of the build configuration.
**Presents as.** Nothing today: per F2 no shipped device has ever been detached,
so there is no damage for the missing tooling to repair.

**Status. Decided and enforced** — `843ee0bc`. `LibraryDeduplicationService`,
`PlaylistTombstoneRecoveryService`, `DatabaseBackupExporter` and their
`ModelContainerManager` entry points are wrapped in `#if DEBUG`, so a shipping
build cannot reach them even by accident.

**The precondition, stated so it can be re-checked:** shipping without recovery
tooling is safe only while nothing a user can install is able to detach or
re-attach the legacy store. That holds now — the attachment has exactly one
input, `StoreSplitReleasePhase.current`; the remote kill switch cannot reach it
(F2); and no released build has ever changed it. **The cutover breaks this
precondition.** The release that moves the phase constant is the first release a
user can install that detaches their store, and a later release re-attaches it.
That release must ship the recovery tooling, or the argument for leaving it out
no longer holds.

Gating it also fixed the Release configuration, which did not build:
`rebuildAnalyticsFromRawSessions` sat outside every `#if DEBUG` region while the
error type it throws sat inside one. Nobody had built Release from this branch
recently enough to notice — see the process note in the
[Exposure model](#exposure-model).

---

## F2 — The remote kill switch could have detached shipped devices, and never did

**Resolved.** The hazard was real and it shipped. It was never triggered, so no
App Store or TestFlight device was ever detached or duplicated.

**Mechanism.** At `ad639fdd` ("appstore release", 2026-06-29, build 219) a
Release build resolved its store mode from `StoreSplitRollout.resolvedMode`,
which returned `.legacyOnly` whenever
`StoreSplitRemoteConfigStore.forcesLegacyReads` was true — that is, whenever the
CloudKit `RolloutConfig` record carried `forceLegacyReads = true` or a
`minSupportedBuild` above the installed build.
`effectiveLegacyCloudSyncEnabled` was then `cloudSyncSettingsAvailable &&
legacyCloudSyncEnabled`, and `cloudSyncSettingsAvailable` is false for
`.legacyOnly`. So the legacy store opened `cloudKitDatabase: .none`.

Publishing the kill switch would have detached every affected device's library
store. Clearing it, or shipping a build above `minSupportedBuild`, would have
re-attached it — and re-attaching after a detach is what merges identity-less
local rows alongside the re-imported zone. The remote lever documented as the
safe rollback control was also a remote lever for the duplication.

The window is `989ac881` (2026-06-24) to `9c7ddeae` (2026-08-17), and it contains
the "appstore release" commit.

**Why it never fired.** Three independent checks, all verified:

* The CloudKit `store-split-rollout-config` record in the public database reads
  `forceLegacyReads = 0`, `migrationEnabled = 1`, `minSupportedBuild = 0`. It was
  created 2026-06-24 13:55:50 UTC and its Modified timestamp **equals** its
  Created timestamp — it has never been edited. Neither trigger of
  `forcesLegacyReads` was ever engaged.
* `9c7ddeae` (mirroring off) and `0d0f3f77` (mirroring back on) are not ancestors
  of `origin/main` (tip `d18830f8`, 2026-07-09). The unconditional off→on
  sequence — the one that duplicated the development device — has never shipped.
* `Config/Version.xcconfig` still reads `2026.15` / build `219` and has not been
  touched since before 2026-08-15, so no build was cut during the 17–21 August
  detached window.

**Exposed.** Nobody. Build 219 carried the path; the trigger was never pulled.
**Live or dormant.** The code path is gone on both sides: `resolvedMode` no
longer returns `.legacyOnly` and `effectiveLegacyCloudSyncEnabled` is no longer
gated on the mode.
**Presents as.** Nothing. No user was affected.
**Status. Closed.** The code path was removed before this audit; the regression
tests in `UpNextTests/StoreSplitCloudReattachGuardTests.swift` keep it removed —
no store mode may change the legacy store's CloudKit attachment, and the rollout
never resolves to `.legacyOnly`.

**Kept as a design lesson, because the shape recurs.** A remote control whose
documented purpose was "pause the rollout safely" also selected the store mode,
and the store mode also decided CloudKit attachment. No single edit looked
dangerous. The rule that falls out: **what a store is attached to must have
exactly one input, and that input must not be reachable from a control meant for
something else.** F6 is the same rule applied to the cutover, and there it is
still live.

---

## F3 — The re-attach guard fired at most once per install

**Mechanism.** `legacyCloudReattachBlocked`
(`StoreDevelopmentConfiguration.swift:162`) blocks turning the legacy store's
CloudKit mirror back on after a spell with it off. `approveLegacyCloudReattach`
set `legacyCloudReattachApprovedKey` and **nothing ever cleared it**. An install
that approved one re-attach was unprotected against every subsequent one.

The subsequent one is not hypothetical: it is the cutover's rollback path.
Moving `StoreSplitReleasePhase.current` to `.userStateAuthority` sets
`releaseLegacyCloudSyncEnabled` false (`:74`), which opens the legacy store
`cloudKitDatabase: .none` (`ModelContainerManager.swift:1933`). Reverting that
constant re-attaches it. That is exactly the `9c7ddeae` → `0d0f3f77` sequence
that duplicated the development device, applied to whoever installed the cutover
build.

A second, smaller hole: `recordLegacyCloudSyncDecision` was called *before*
`ModelContainer(...)`, so a launch that failed to open the store still recorded a
decision the store never saw — enough to disarm the guard on the next launch.

**Exposed.** Any install that has ever approved a re-attach. Today that is
development devices; it widens the moment a support instruction says "tap
Approve".
**Live or dormant.** Dormant, and dependent on a cutover that has not happened.
**Presents as.** The original incident: duplicated podcasts, an unbounded queue,
inflated lifetime totals. Nothing is deleted; everything is doubled.
**Status. Fixed** — `4cabf2eb`. A recorded detach now clears the approval, so an
approval covers only the divergence window it was granted for, and the decision
is recorded after the container actually opens. Regression tests:
`UpNextTests/StoreSplitCloudReattachGuardTests.swift`. The fix cannot reach an
install detached before the bookkeeping existed — but per F2 there are none.

---

## F4 — Derived listening data was an input to the record it is derived from

**Now structurally impossible.** The cycle needed a synced aggregate to exist.
None does.

**Mechanism, as it was.** A closed loop across two services:

1. `StoreSplitUserStateImporter.applyListeningSummaries` deleted the whole legacy
   `PlaySessionSummary` table and rewrote it from the synced
   `ListeningSummarySync` rows.
2. `StoreSplitMigrationService.processListeningSummaries` read that same legacy
   table and republished it as the authoritative `__legacy_shared__`
   `ListeningSummarySync` record.
3. The republish **max-merged**. A total that went through the loop once could
   never come back down, on any device on the account.

So a local total that was wrong for any reason — including F5 — was promoted to
authoritative and pushed to every device, permanently.

**Exposed.** Dev only; the import leg required `.userStateAuthority`.
**Live or dormant.** Never live outside development.
**Presents as.** Lifetime listening time that grows on its own and cannot be
corrected — the 1069h-instead-of-350h symptom, made permanent.

**Status. Removed, in two steps.** First fixed in `ca00c783` by tagging the
projected rows with a recognisable deterministic id so the migration could skip
them — a valid cut of the loop, but still a loop with a guard on it. Then
eliminated in `ff4d22cb`: the importer no longer writes the legacy summary table
at all, because nothing synced is left to write it from. Summaries are a purely
local derivation from `PlaySession` rows via `rebuildListeningStats`. The
projection-id machinery was deleted with the cycle, because a guard on an
impossible path is just code that has to keep being understood.

The general rule this leaves behind, now enforced by
`UserStateCloudSchemaAudit.permitsAggregateGrowth`: **nothing derived from synced
rows may itself sync.** Derived data that travels becomes evidence, and evidence
that was derived from evidence cannot be corrected — only ratcheted.

---

## F5 — `__legacy_shared__` and the live per-device summaries could overlap

**Now structurally impossible.** There are no per-device summaries to overlap
with.

**Mechanism, as it was.** Lifetime totals were computed by summing
`ListeningSummarySync` rows that shared (feedURL, periodKind, periodStart) and
differed only by `sourceDeviceID` — including the `__legacy_shared__` migration
record. Both the importer and `StatisticsView` did this.

That is only correct if the two sets are disjoint, and the design intended them
to be: `rebuildLiveSummaries` excluded migrated rows because `__legacy_shared__`
already carried them. `apply(_:to:)` broke the disjointness by setting
`record.isLegacyMigrated = false` on **every** update, so a migrated row touched
by a live upsert joined the per-device rollup while `__legacy_shared__` still
accounted for it — and nothing ever subtracts from `__legacy_shared__`.

**Exposed.** Any install that had run the migration and then re-recorded a
session with identical (feed, episode, start, end, positions).
**Live or dormant.** The writer path was live; the double-counted read was behind
`newStoreReadsEnabled`.
**Presents as.** Lifetime listening time roughly doubled for the affected feeds.

**Status. Removed, in two steps.** First fixed in `ca00c783` by preserving
`isLegacyMigrated`. Then, in `ff4d22cb`, the per-device rollups were deleted
outright: the account total is the frozen baseline plus the live sessions, and
the per-device shares are the same sessions grouped by device. One set of rows,
two readings, nothing to reconcile.

**What survives, and why it still matters.** `isLegacyMigrated` is still the rule
that keeps migrated sessions out of a total the baseline already contains — it
went from patching a rollup to being the single documented exclusion, asserted in
`StoreSplitListeningTotalsTests` and expressed in
`AccountListeningTotals.lifetimeSeconds`. The fallback there is deliberate: on a
device with no baseline the migrated rows are the only record of the pre-split
era, so they are counted exactly then and never otherwise.

---

## F6 — Rollback from the cutover is not a rollback

> **This is the top live risk in this document.** Every other detach/re-attach
> path has been closed or shown never to have fired (F2, F3). The cutover is the
> one remaining way the installed base can be detached from CloudKit, it does so
> for everyone in a single release, and no remote control can undo it.

**Mechanism.** Three things move together when `StoreSplitReleasePhase.current`
flips, for the entire installed base at once and with no per-install staging:

| | `.dualSyncBackfill` | `.userStateAuthority` |
| --- | --- | --- |
| legacy store CloudKit | `.automatic` | `.none` |
| `userStateImportEnabled` | false | true |
| read authority | legacy graph | UserState, once the rollout says `.newStoreReads` |

Reverting the constant does **not** restore the first row. With F3 fixed, the
re-attach guard blocks it: every install that took the cutover build recorded a
detach, so the rolled-back build leaves their legacy store detached — and on a
release build there is no UI to approve otherwise (F1). The rolled-back build
also turns the importer off, so UserState stops being projected onto the graph
the app now reads from.

The net effect of a rollback is therefore **cross-device sync silently stops**.
No data is lost and nothing duplicates, which is the right trade — but it is not
"back to how it was", and installs that skipped the cutover build (previous
recorded state `true`, so not blocked) keep legacy sync. The population splits
into two sync topologies with no way to tell them apart from inside the app.

**Does the CloudKit kill switch cover this?** No.
`StoreSplitRemoteConfigStore.migrationPausedRemotely` feeds
`StoreDevelopmentConfiguration.splitStoreHeavyWorkPaused` (`:230`), which gates
migration, reconcile and import *work*. The legacy store's `cloudKitDatabase`
comes from a compile-time constant and is never consulted against remote config.
Note also that the instance-level `splitStoresEnabled` (`:292`) reads
`splitStoreWorkEnabled`, which is hard-coded `true` in release builds — so the
remote kill switch does not reach `newStoreReadsEnabled` or
`userStateImportEnabled` either; only their call sites are separately gated.

**Exposed.** The whole installed base, at whatever moment the cutover ships.
Note that per F2 the installed base has never been detached, so the cutover would
be the first time — there is no prior art on this account, and no device has
demonstrated that its re-attach behaves.
**Live or dormant.** Dormant; it is a property of the transition.
**Presents as.** After a rollback: the second device quietly stops updating. If
the re-attach guard is ever cleared to "fix" that, the original incident,
population-wide.
**Status.** Open by design — this is the product decision the brief reserves.
Analysed here, not performed. See [Hardening plan](#hardening-plan).

---

## F7 — Uniqueness cannot be enforced, and the replacement invariant is uneven

**Mechanism.** Confirmed: no `@Attribute(.unique)` anywhere in the schema. This
is not an oversight that can be corrected — `NSPersistentCloudKitContainer` does
not support unique constraints, and both `SharedDatabase.sqlite` (today) and
`UserState.sqlite` (always) are mirrored. Uniqueness has to be replaced by
convention.

The convention exists for the synced schema: every `*Sync` model derives its `id`
from stable identity keys (`StableIdentityKey`, `EpisodeStableIdentity`,
`PodcastFeedIdentity`), so two devices independently describing the same fact
produce the same row id. Convergence is then enforced **on read**: the importer
sorts newest-first and keeps the first per id
(`StoreSplitUserStateImporter.swift:338-353` for episode states, `:1292` for
subscriptions), and `StoreSplitPlaylistSyncWriter.consolidateEntries` deletes
same-id duplicates outright.

It is uneven. `StoreSplitEpisodeStateSyncWriter.upsertWithoutSaving`
(`:43-55`) fetches `.first` for an id and updates it, leaving any CloudKit-merged
twin untouched — writes and reads can settle on different copies until the next
import collapses them.

The legacy graph has no such convention at all, which is why
`LibraryDeduplicationService` has to exist. `hideDuplicatePodcasts`
(`StoreSplitUserStateImporter.swift:1319`) is not a substitute: it only sets
`isSubscribed = false` on the loser and leaves its episodes, and it operates on
the podcast list captured before the subscription loop may have inserted more.
`modeAllowsDuplicateCleanupDuringProjection` (`:226`) is hard-coded `true`; the
gate is vestigial and should either grow a reason or go.

**Exposed.** All installs.
**Live or dormant.** Live.
**Presents as.** Duplicates that only a manual dedup run collapses.
**Status.** Partly open. Documented; `LibraryDeduplicationService` and its
dry-run plan/apply split remain the mitigation.

---

## F8 — The synced schema was constrained by membership, not by size

**Resolved.** The aggregate is gone from the synced schema and the constraint
that would have caught it is now enforced.

**Mechanism.** `UserStateCloudSchemaAudit` asserted a nine-name allow-list and a
forbidden list, and nothing else. Two gaps:

*The allow-list was not compared to anything.* It is written by hand; the
`Schema` in `makeUserStateContainer` is written by hand. They agreed only until
one of them was edited.

*Membership is the wrong property.* The split exists to produce a **small** store
that syncs quickly. `ListeningSummarySync` passed the allow-list and was
structurally the largest table in it: its identity was (feedURL, periodKind,
periodStart, sourceDeviceID), and `PlaySessionSummaryPeriod` has five cases, so
one feed listened to on one day on one device materialised a day, week, month,
year and forever row — all of it recomputable from `ListeningHistorySync`, which
is itself synced.

**Exposed.** All installs once UserState carried a full history.
**Live or dormant.** Was live — `UserState.sqlite` syncs today.
**Presents as.** Slow first sync on a new device; iCloud storage consumed by
numbers every device could compute for itself.

**Status. Resolved** — `89c33947` and `ff4d22cb`.

`89c33947` added the schema-vs-allow-list comparison, a declared row-growth class
per entity, an inventory of feed-derived fields, and the cardinality arithmetic
as a test. `ff4d22cb` acted on what that measured: `ListeningSummarySync` is out
of the synced schema, replaced by `ListeningBaselineSync` — one frozen row per
feed. `RowGrowth.perFeedPerPeriodPerDevice` is now a *rejected* shape rather than
a described one, `permitsAggregateGrowth` says so, and
`reintroducedRetiredModelNames` fails the audit if the retired entity comes back.

### Payload, before and after

Same library throughout: 40 feeds, five years of listening, 2 devices, ~3
sessions per listening day per device.

| | Before | After |
| --- | ---: | ---: |
| `ListeningSummarySync` | ~170,000 | — |
| `ListeningHistorySync` | ~11,000 | ~11,000 |
| `EpisodeStateSync` | ~10,400 | ~10,400 |
| Subscriptions, preferences, queue, playlists, bookmarks | ~400 | ~400 |
| `ListeningBaselineSync` | — | 41 |
| **Total** | **~192,000** | **~22,000** |

Roughly a **9× reduction**, and the removed table was ~89% of the rows. The
arithmetic is `UserStateCloudSchemaAudit.estimatedAggregateRowCount` and
`estimatedSyncedRowCount`, asserted in `StoreSplitSyncedSchemaAuditTests` so the
next proposal for a synced aggregate has to argue against a number.

### What happens to existing installs

Removing an entity from a store that already has it is a schema change, and the
failure mode is not a wrong number — it is `ModelContainer.init` throwing at
launch, leaving the app with no UserState store at all. This was tested rather
than reasoned about, in `StoreSplitUserStateSchemaUpgradeTests`, against a real
on-disk store in a temporary directory:

* A store written with the retired entity **opens** with the shipping schema.
  Core Data's lightweight migration drops the table.
* Every other entity's rows survive intact — subscriptions, episode state,
  playlists, playlist and queue entries, bookmarks, preferences, and crucially
  the session rows that all listening totals now come from.
* The upgraded store accepts `ListeningBaselineSync` and persists it.
* Reopening is repeatable, not a one-shot migration that works once.

The retired model is redeclared in the test target so this stays under test
without the app shipping a model it no longer uses. SwiftData names the entity
after the type, so the store those tests write is the store an older build wrote.

### What happens to the CloudKit zone

Less tidy, and worth being explicit about.

`CD_ListeningSummarySync` records already in a user's private zone are **not**
deleted by this change. A client can only delete records for entities it still
models, and this one no longer models them. What the change does is stop the
mirroring engine importing them: the records become inert, and a new install
never materialises them locally.

So the local store shrinks immediately and completely; the *iCloud* footprint
does not shrink for anyone whose zone already holds those records. Reclaiming it
needs one of:

* the user-initiated legacy-zone deletion already planned as Phase 4 of
  `StoreSplitCacheCutoverPlan.md`, or
* a drain-then-remove sequence across two releases — release N keeps the entity
  and deletes every row locally, so the deletions export to CloudKit; release N+1
  removes the entity. This is the only in-app way to reclaim the space, and it is
  no longer available for the current zone contents once this change ships.

That ordering constraint is the real cost of the one-release removal and it is a
deliberate trade: correctness and payload for *new* syncs now, versus reclaiming
storage that is already spent. Recorded here because it is the kind of thing that
is obvious in the moment and invisible six months later.

Known feed-derived leaks, inventoried in
`UserStateCloudSchemaAudit.feedDerivedFieldsBySyncedModel`:
`EpisodeStateSync.duration`, `ListeningBaselineSync.podcastName`,
`ListeningHistorySync.podcastName` and `.episodeTitle`. Each has a current
reader; the point of the inventory is that the next one has to be deliberate.

---

## F9 — Orphaned playlist entries accumulate and nothing removes them

**Mechanism.** Established empirically (`StoreSplitSchemaInvariantTests`):

* Deleting a `Playlist` **nullifies** `entry.playlist` and leaves the
  `PlaylistEntry` rows in the store. A nullified entry is reachable from neither
  `playlist.items` nor the `entry.playlist?.id == playlistID` fetch every reader
  uses (`PlaylistModelActor.swift:148-159`). This is the shape the incident
  found: 152 of 154 entries reachable from neither side.
* Deleting an `Episode` nullifies `entry.episode` but leaves the entry **in** the
  playlist, occupying a position that renders as nothing.

Neither is generated by the app's own deletion sites — `PodcastListView.swift:283`
deletes the entries first, and `Playlist.swift:299-331` re-points or deletes them
before removing a duplicate playlist. The generator is CloudKit: a merged
`PlaylistEntry` whose playlist reference is dangling arrives already orphaned.

Nothing sweeps them. `LibraryDeduplicationService` deliberately reports and
preserves them (`:420-427`, and the test at
`LibraryDeduplicationServiceTests.swift:169`) on the grounds that an orphan may
be the only surviving copy of a lost queue — a defensible call that leaves the
rows accumulating and syncing forever.

**Exposed.** All installs with CloudKit mirroring on the legacy store, i.e. all
installs today.
**Live or dormant.** Live.
**Presents as.** Nothing visible; store growth, inflated diagnostics counts, and
a queue whose row count bears no relation to what the user sees.
**Status.** Open — the retention is deliberate. Regression tests added
(`UpNextTests/StoreSplitSchemaInvariantTests.swift`) so the behaviour is at least
pinned. A bounded, reviewable sweeper belongs in
`LibraryDeduplicationService`'s plan/apply model, not in an automatic pass.

---

## F10 — Playlist tombstones are irreversible by design, with one escape hatch

**Mechanism.** `shouldPreserveTombstone`
(`StoreSplitPlaylistSyncWriter.swift:244-256`) refuses to let a local snapshot
revive a tombstoned entry unless the entry was demonstrably added *after* the
removal. That rule is correct for its purpose — it is what stopped finished
episodes reappearing at the top of Up Next — and it means a wrong tombstone
cannot be undone by republishing a correct local playlist. Combined with the
hard deletes `PlayedEpisodePlaylistPruner` performed, a single over-broad pass
on one device removed queue entries on all of them, permanently.

What can create a tombstone: `dequeueFinishedEpisodeAndReturnNext`
(`PlaylistModelActor.swift:264`), explicit removals, playlist deletion, and the
pruner. What can clear one: a snapshot entry with `addedAt > deletedAt`, or
`PlaylistTombstoneRecoveryService.restoreTombstones(deletedOnOrAfter:)` — which
is the escape hatch, and which is DEBUG-only (F1).

The pruner remains disabled behind `playlist.playedEpisodePrunerEnabled`
(`PlayedEpisodePlaylistPruner.swift:60-74`) and logs what it would have removed.
That is the right posture and this audit does not change it.

**Exposed.** All installs, once the pruner is ever enabled.
**Live or dormant.** Dormant (pruner off); the tombstone rules themselves are live.
**Presents as.** Queue entries vanishing across devices with no way to get them
back.
**Status.** Open by design. Preserved as-is.

---

## F11 — `dequeueFinishedEpisodeAndReturnNext` is not a skip path

**Resolved — no defect.** The brief asked whether skip-to-next stamps
`completionDate` on an unplayed episode. It does not.
`dequeueFinishedEpisodeAndReturnNext` (`PlaylistModelActor.swift:264`) has
exactly one caller, `Player.handlePlaybackFinished` (`Player.swift:2048`), which
runs on end-of-media only; confirmed independently by the owner. Skip-to-next
does not reach it, so `markEpisodeFinished` (`:401`) only ever stamps
`completionDate` on genuine end of playback, and only when it is `nil`.

One asymmetry worth naming: `markEpisodeFinished` stamps `completionDate` but not
`isHistory`/`status`, whereas `EpisodeActor.markasPlayed` (`:426`) sets all four.
`Episode.isPlayed` (`Episode.swift:356`) returns true on `completionDate` alone,
so the two paths agree for every consumer checked — including
`PlayedEpisodeQueuePolicy`, which keys off `isPlayed` plus `completionDate`.

**Status. Closed.** Recorded so the question is not re-opened from scratch.
It matters because `PlayedEpisodeQueuePolicy` treats a completion stamp as
authoritative evidence that an episode was listened to; if a skip could produce
one, the pruner's rule would be unsound at its root rather than merely
over-broad.

---

## F12 — The plan documents contradicted each other and the code

**Mechanism.** `FinishStoreSplitMigrationCodexPrompt.md` stated that
`SharedDatabase.sqlite` "is a temporary migration/recovery source only" that
"must be removed after lossless migration verification". It is the permanent,
local-only durable library store. That sentence is a standing instruction to
delete the library, in a file whose entire purpose is to be handed to an agent
as a brief.

`StoreSplitCacheCutoverPlan.md` §Phase 4 stated that the payload had already
shrunk because "the legacy `ModelConfiguration` hard-codes `cloudKitDatabase:
.none`". It does not: the phase constant is `.dualSyncBackfill`, so the legacy
store opens `.automatic` and **both** stores sync today, making the current
iCloud payload larger than before the split. The risk register additionally
claimed the legacy-sync switch is "gate via `RolloutConfig`, reversible"; per F6
the kill switch does not reach that flag.

**Status. Fixed** — `7a8250ff`. The surviving statement is made unambiguous and
the superseded one kept as an explicitly-marked note, because it has already
been acted on.

---

## Corrections to the brief

Two starting points were treated as established. Neither reproduces on the
current schema. Both were tested against in-memory containers; the tests are in
`UpNextTests/StoreSplitSchemaInvariantTests.swift`.

**"`Playlist.items`/`PlaylistEntry.playlist` and `Episode.playlist`/
`PlaylistEntry.episode` have no inverse, so SwiftData maintains them
independently."** It maintains them together. SwiftData synthesises an implicit
inverse when exactly one candidate exists on the far side, which is the case for
both pairs. Writing `entry.playlist = playlist` populates `playlist.items`;
writing `playlist.items = [entry]` populates `entry.playlist`. The writers that
set only one side are therefore correct today.

What is dangerous is that the inverse is **inferred, not declared**. Inference
holds only while each relationship has a single candidate; adding a second
`[PlaylistEntry]` relationship to `Playlist` or `Episode` would withdraw it
silently, and every reader that queries the other half would go blind at once.
The new tests are the alarm for that edit. The 152 unreachable entries are
explained by F9, not by a missing inverse.

**"`Podcast.episodes` cascades while `Episode.podcast` has no inverse, so
deleting a former owner cascades into a re-pointed episode."** `Episode.podcast`
is a plain `var podcast: Podcast?` (`Episode.swift:239`) with no `@Relationship`
attribute — but any property typed as another `@Model` *is* a relationship;
`@Relationship` only customises one. It is the inferred inverse of
`Podcast.episodes`, so assigning the episode to a new podcast removes it from the
old one's array and deleting the old podcast does not touch it. Verified.

The same reasoning applies to `Podcast.settings` (`Podcast.swift:109`, cascade)
and `PodcastSettings.podcast` (`Settings.swift:73`).

---

## Synced-schema classification

The synced entities as they now stand, classified against the purpose (a small
store that syncs quickly) rather than against the allow-list. Growth classes are
declared in `UserStateCloudSchemaAudit.rowGrowthBySyncedModel` and asserted in
`StoreSplitSyncedSchemaAuditTests`.

| Entity | Growth | Verdict |
| --- | --- | --- |
| `SubscriptionSync` | per feed | correct — user-owned, bounded |
| `PodcastPreferenceSync` | per feed | correct |
| `EpisodeStateSync` | per touched episode | correct; carries one feed-derived field (`duration`) |
| `QueueEntrySync` | per membership incl. tombstones | correct |
| `PlaylistSync` / `PlaylistEntrySync` | per membership incl. tombstones | correct |
| `BookmarkSync` | per user action | correct |
| `ListeningBaselineSync` | one frozen row per feed | correct — the one thing sessions cannot reconstruct |
| `ListeningHistorySync` | per session per device, forever | now the largest table; **open** |
| ~~`ListeningSummarySync`~~ | ~~feeds × periods × 5 kinds × devices~~ | **retired** — `ff4d22cb` |

**Should derived aggregates sync at all? No — settled and implemented.** Every
device holds the sessions the aggregates were computed from, and can recompute
them at any time. Syncing them bought nothing and cost the largest table in the
store, the reconciliation problem in F5 and the feedback loop in F4. Removing
them deleted a bug *class* rather than an instance, which is why both findings
are now "structurally impossible" rather than "fixed".

**Did the pre-split history need a frozen record? Yes — checked, not assumed.**
Raw `PlaySession` rows are pruned after 30 days
(`PlaySessionTrackerActor.rawSessionRetentionDays`), so sessions demonstrably do
*not* cover the full history and dropping the aggregates outright would have
silently truncated every long-standing account's lifetime total. Hence
`ListeningBaselineSync`: one frozen row per feed, `feeds + 1` rows rather than
`feeds × periods × 5 × devices`, written once at migration and never
republished, merged or recomputed.

Two properties make it safe, and both are tested:

* **Write-once.** A baseline that already exists is left alone, including one
  that arrived from another device. Re-deriving or max-merging is what let a
  wrong total become permanent; a constant cannot ratchet.
* **Single-tier.** It sums the coarsest legacy period tier present — `.year`
  normally, falling back through `.month`/`.week`/`.day`. Each tier partitions
  all time, so summing *within* one never double-counts; summing *across* them
  would, because a month sits inside a year.

**Statistics are per-account — decided.** Totals aggregate every device, and each
device's share is shown as a percentage. Both readings come out of
`ListeningHistorySync`, which already carries `sourceDeviceID`,
`sourceDeviceName` and `deviceModel`, so the total and the shares are two views
of one set of rows and cannot disagree. The arithmetic lives in
`AccountListeningTotals` rather than in the view, so it is directly testable.

**What does listening history require? Still open.** It is now the largest synced
table and grows without bound with listening time, across devices. The options,
unchanged:

* *Full session records* (today): any statistic, any period, recomputable
  anywhere; payload grows forever.
* *Compact records* — one row per (episode, day, device): roughly an order of
  magnitude fewer rows, keeps per-podcast, per-day and per-device statistics —
  which is everything the confirmed product decision needs — and loses only
  session-level detail (start/end positions, clean-end).
* *Nothing synced*: smallest possible store, but statistics become per-device,
  which the per-account decision rules out.

Given that decision, *compact records* is the only option that reduces the
remaining payload without contradicting it. That is a follow-up, not part of this
change.

**Does `UserStateCloudSchemaAudit` constrain size or only membership?** It now
constrains both, and one more thing besides: `permitsAggregateGrowth` rejects the
multiplicative shape outright, and `reintroducedRetiredModelNames` fails the
audit if `ListeningSummarySync` returns. Membership alone would not have caught
it going in — it passed the allow-list on the way in the first time.

---

## The cutover

`StoreSplitReleasePhase.current` is the whole cutover. Moving it detaches every
install's legacy store from CloudKit and enables the user-state import, for the
entire population, in one release, with no per-install staging and no remote
override (F6).

What makes it recoverable rather than merely careful, in the order it has to
land:

1. **A one-way door has to be recognised as one.** With F3 fixed, the rollback
   path is safe *because* it refuses to re-attach. That means the recovery
   story for a bad cutover is "sync stops until a fixed build ships", and that
   has to be an accepted answer before the flip, not discovered after it.
2. **The kill switch has to reach the flag, or the flag has to stop being a
   compile-time constant.** Today `RolloutConfig` can pause work but cannot
   change what the legacy store is attached to. Either is a design change; both
   are cheaper than the alternative.
3. **The recovery toolkit has to ship (F1).** It is `#if DEBUG` by decision, on
   the explicit precondition that no installable build can detach the legacy
   store. The cutover release is the one that breaks that precondition, so it is
   also the release that has to carry the tooling. A cutover whose failure mode is
   only diagnosable on a developer's device is not staged, it is hoped.
4. **The rollout has an ordering guarantee already, and it holds.**
   `classifyStoreSplitRollout` (`ModelContainerManager.swift:800-855`) only sets
   `.newStoreReads` when the split store has data *and* the slice migration is
   complete (or there was no legacy data to migrate), and
   `resumeMigrationAfterVersionUpgradeIfNeeded` (`:781`) pushes a device back to
   `.migrating` when a version bump adds phases. `newStoreReadsEnabled` does not
   backfill, so this ordering is load-bearing; it was checked and is sound. The
   gap is that a remote pause does not *revert* an install that already reached
   `.newStoreReads`.

**Did any shipped build ever have legacy mirroring off?** No. Builds from
2026-06-24 to 2026-08-17 *could* have been detached by the remote kill switch,
but the `RolloutConfig` record has never been edited since creation and no build
was cut during the unconditional 17–21 August detached window. See F2. The
installed base has never been detached, which means the cutover (F6) would be the
first time it happens — to everyone at once.

---

## Hardening plan

### Must land before any cutover

1. **Ship the recovery toolkit in the cutover release** (F1). It is deliberately
   `#if DEBUG` today, which is sound only while no installable build can detach
   the legacy store. The cutover release is exactly the build that can. At
   minimum: store export, dedup dry-run and apply, and a way to clear the
   re-attach block.
2. **Bring the legacy CloudKit flag under the kill switch** (F6), or accept in
   writing that rollback means "sync stops" and put that in the release notes and
   the runbook.
3. ~~**Decide the `ListeningSummarySync` question** (F8).~~ **Done** — the
   aggregates are out of the synced schema (`ff4d22cb`), for a ~9× reduction in
   synced rows. Note the CloudKit-zone caveat in F8: existing zone records are
   inert but not reclaimed.
4. **Stage the cutover.** The phase constant flips for everyone at once. A
   percentage rollout driven from the existing `RolloutConfig` record, or a
   TestFlight-only phase gate, converts a population-scale one-way door into a
   sampled one.
5. **Add convergence telemetry** to the pre-cutover release, so "phase one has
   converged across the population" is a measurement rather than an assumption.

### Follow-up

6. Consolidate on read in `StoreSplitEpisodeStateSyncWriter` the way
   `StoreSplitPlaylistSyncWriter.consolidateEntries` already does (F7).
7. Add a bounded orphan-entry sweep to `LibraryDeduplicationService`'s plan/apply
   model (F9) — planned and reviewed, never automatic.
8. Give `modeAllowsDuplicateCleanupDuringProjection` a reason or delete it (F7),
   and move `hideDuplicatePodcasts` after the subscription loop so duplicates
   created in the same pass are seen.
9. Decide the listening-history payload shape (F8). It is now the largest
   synced table, and compact per-(episode, day, device) records would cut it by
   roughly an order of magnitude while still satisfying the per-account decision.
10. Consider declaring the inverses on the four inferred relationship pairs
    explicitly. The tests added here catch a regression; a declaration would
    prevent one. It is a schema edit against a CloudKit-mirrored store and needs
    its own migration review, which is why it is not in this branch.

---

## Unresolved / needs a decision

Stated as open questions, not as conclusions.

**Is any real account's baseline actually right?** The capture sums the coarsest
legacy period tier present, which is correct arithmetic on a store whose
`PlaySessionSummary` rows are themselves correct. On the development device they
were not — that is the whole incident — so the first baseline captured there will
freeze whatever that table currently says, permanently and for every device on
the account. *Settled by:* running "Rebuild Analytics from Raw Sessions" and
comparing the legacy `.year` totals against expectation **before** the first
baseline capture on any account whose totals are suspect. Once captured, it is
write-once by design; correcting it means deleting the row, which nothing in the
app does.

**How much of the iCloud footprint is actually reclaimed?** The synced *schema*
shrank ~9×, but `CD_ListeningSummarySync` records already in a user's private
zone are inert rather than deleted (F8). For a user whose zone already holds
them, storage is unchanged; only new syncs and new devices see the benefit.
*Settled by:* the iCloud storage figure for the app before and after, on an
account that had a populated zone. If reclaiming it matters, it needs the
drain-then-remove sequence described in F8, and that opportunity is gone for the
current contents once this ships.

**Would declaring the relationship inverses require a store migration?** Core
Data's relationship version hash may or may not include the delete rule and the
declared inverse; the answer decides whether the change in item 10 is free or
needs a versioned migration. *Settled by:* opening a store created by the current
binary with a build that declares the inverses, on a copy of a real store — which
this audit did not do, being read-only with respect to user data.

**Is the `LibraryDeduplicationService` orphan-retention policy still right?**
Keeping orphans preserves a possible last copy of a lost queue and lets them
accumulate forever. The correct answer depends on whether any recovery has ever
actually used one. *Settled by:* the tombstone-recovery reports from the affected
development device.

**Whether the escape hatch for a wrong tombstone is sufficient** (F10).
`restorePlaylistTombstones(deletedOnOrAfter:)` requires the user to know a
cutoff date and requires a DEBUG build. *Settled by:* deciding whether tombstone
recovery is a support operation or a user-facing one.
