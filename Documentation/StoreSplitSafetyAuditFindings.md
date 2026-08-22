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

So the split code is not on `main`. It does **not** follow that it never
shipped: `codex/database-split` contains `ad639fdd` "appstore release"
(2026-06-29) and `5bd57f5a` "2026.16", both carrying
`StoreDevelopmentConfiguration.swift` and the split containers, and both at build
219 — the branch's current build number. Release builds have plainly been cut
from this branch. Whether they reached the App Store or only TestFlight is not
answerable from the repository; see [Unresolved](#unresolved--needs-a-decision).
Every exposure statement below is qualified by that.

`StoreSplitReleasePhase.current` is `.dualSyncBackfill`
(`StoreDevelopmentConfiguration.swift:65`). Everything gated on
`.userStateAuthority` — the whole user-state import path — is therefore dormant
in every build that exists today.

---

## F1 — The entire incident-recovery toolkit is `#if DEBUG`

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
**Live or dormant.** Live — it is a property of the current build configuration.
**Presents as.** Silent, unfixable divergence: the user's second device stops
receiving library changes and nothing in the UI says so.
**Status.** Open. Product decision (what a non-developer build should expose).

---

## F2 — A shipped build could be detached from CloudKit by the remote kill switch

**Mechanism.** The exact incident mechanism, remotely triggerable, in a build
labelled "appstore release".

At `ad639fdd` ("appstore release", 2026-06-29, build 219) a Release build
resolved its store mode from `StoreSplitRollout.resolvedMode`, which returned
`.legacyOnly` whenever `StoreSplitRemoteConfigStore.forcesLegacyReads` was true —
that is, whenever the CloudKit `RolloutConfig` record carried
`forceLegacyReads = true` or a `minSupportedBuild` above the installed build.
`effectiveLegacyCloudSyncEnabled` was then `cloudSyncSettingsAvailable &&
legacyCloudSyncEnabled`, and `cloudSyncSettingsAvailable` is false for
`.legacyOnly`. So the legacy store opened `cloudKitDatabase: .none`.

Publishing the kill switch detached every affected device's library store.
Clearing it, or shipping a build above `minSupportedBuild`, re-attached it — and
re-attaching after a detach is what merges identity-less local rows alongside the
re-imported zone. The remote lever documented as the safe rollback control was
also a remote lever for the duplication.

The window is `989ac881` (2026-06-24) to `9c7ddeae` (2026-08-17), and it
contains the "appstore release" commit. The current code closes it on both
sides: `resolvedMode` no longer returns `.legacyOnly` and
`effectiveLegacyCloudSyncEnabled` is no longer gated on the mode.

**Residual exposure, and it is not covered by F3's fix.** A device that ran a
build from that window and was detached has *no recorded previous state* —
`recordLegacyCloudSyncDecision` did not exist yet. `legacyCloudReattachBlocked`
therefore returns false for it, and updating to a current build re-attaches it
unguarded. The guard cannot detect a detach that predates its own bookkeeping.

**Exposed.** Any install of a build from 2026-06-24 to 2026-08-17 — which,
per the [Exposure model](#exposure-model), is a TestFlight question the
repository cannot answer — **and only if the `RolloutConfig` record was ever set
to a killing value**.
**Live or dormant.** The code path is gone. The consequence is live for any
device that was caught by it.
**Presents as.** Duplicated podcasts, an inflated queue and inflated totals, on
the next launch after the kill switch is lifted or a newer build is installed.
**Status.** Code path closed before this audit. Regression tests added
(`UpNextTests/StoreSplitCloudReattachGuardTests.swift`) pinning that no store
mode can change the legacy store's CloudKit attachment and that the rollout never
resolves to `.legacyOnly`. Whether any device was actually caught is a question
about CloudKit Dashboard history, not about this repository — see
[Unresolved](#unresolved--needs-a-decision).

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
`UpNextTests/StoreSplitCloudReattachGuardTests.swift`. The fix does not reach
installs detached before the bookkeeping existed; see F2.

---

## F4 — Derived listening data is an input to the record it is derived from

**Mechanism.** A closed loop across two services:

1. `StoreSplitUserStateImporter.applyListeningSummaries`
   (`StoreSplitUserStateImporter.swift:1013`) deletes the whole legacy
   `PlaySessionSummary` table (`:1098`) and rewrites it from the synced
   `ListeningSummarySync` rows.
2. `StoreSplitMigrationService.processListeningSummaries` reads that same legacy
   table and republishes it as the authoritative `__legacy_shared__`
   `ListeningSummarySync` record (`:1642`, `:1679`).
3. The republish **max-merges** (`:1590-1620`). A total that has been through the
   loop once can never come back down, on any device on the account.

So a local total that is wrong for any reason — including F5 below — is promoted
to authoritative and pushed to every device, permanently.

**Exposed.** Dev today; every install once `.userStateAuthority` ships, because
that is what enables `userStateImportEnabled`
(`StoreDevelopmentConfiguration.swift:135`).
**Live or dormant.** Dormant. The DEBUG "Rebuild Listening Summaries" action can
drive step 2 today.
**Presents as.** Lifetime listening time that grows on its own and cannot be
corrected — the 1069h-instead-of-350h symptom, made permanent.
**Status. Fixed** — `ca00c783`. The importer stamps a deterministic,
recognisable id on rows it projects (`PlaySessionSummary.splitStoreProjectionID`)
and the migration skips them (`StoreSplitMigrationService.swift:1558`). The
cycle is broken at the point where derived data would re-enter as evidence.

The remaining half of the mitigation was already in place and is preserved:
"Rebuild Analytics from Raw Sessions" recomputes from `PlaySession` rows and is
the correct action after a bad merge, as its comment says
(`ModelContainerManager.swift:1195-1205`).

---

## F5 — `__legacy_shared__` and the live per-device summaries could overlap

**Mechanism.** Lifetime totals are computed by summing `ListeningSummarySync`
rows that share (feedURL, periodKind, periodStart) and differ only by
`sourceDeviceID` — including the `__legacy_shared__` migration record. Both the
importer (`StoreSplitUserStateImporter.swift:1090`) and the reader
(`StatisticsView.swift:1847`) do this.

That is only correct if the two sets are disjoint, and the design says they are:
`rebuildLiveSummaries` deliberately excludes migrated rows
(`StoreSplitListeningHistorySyncWriter.swift:130`) because `__legacy_shared__`
already carries them.

`apply(_:to:)` broke the disjointness by setting `record.isLegacyMigrated = false`
on **every** update. A migrated row touched by a live upsert joined this device's
per-device rollup while `__legacy_shared__` still accounted for it — and nothing
ever subtracts from `__legacy_shared__`.

`StatisticsView` has a partial mitigation: when a `.forever` set contains no
`__legacy_shared__` row it adds the migrated history separately
(`:1850-1858`). That handles the *absent* case. It does not help when both are
present, which is the case this defect creates.

**Exposed.** Any install that has run the migration and then re-recorded a
session with identical (feed, episode, start, end, positions) — plausible after
an analytics rebuild.
**Live or dormant.** The writer path is live; the double-counted *read* is behind
`newStoreReadsEnabled`, so the visible symptom is dormant.
**Presents as.** Lifetime listening time roughly doubled for the affected feeds.
**Status. Fixed** — `ca00c783`. `isLegacyMigrated` is preserved on update.
Regression tests: `UpNextTests/StoreSplitListeningTotalsTests.swift`, including
the contrast case that a never-migrated row still counts.

---

## F6 — Rollback from the cutover is not a rollback

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
**Live or dormant.** Dormant; it is a property of the transition.
**Presents as.** After a rollback: the second device quietly stops updating.
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

**Mechanism.** `UserStateCloudSchemaAudit` (`StoreSplitMigrationVerifier.swift:465`)
asserted a nine-name allow-list and a forbidden list, and nothing else. Two gaps:

*The allow-list was not compared to anything.* It is written by hand; the
`Schema` in `makeUserStateContainer` (`ModelContainerManager.swift:1974`) is
written by hand. They agreed only until one of them was edited.

*Membership is the wrong property.* The split exists to produce a **small** store
that syncs quickly. `ListeningSummarySync` passes the allow-list and is
structurally the largest table in it: its identity is (feedURL, periodKind,
periodStart, sourceDeviceID) and `PlaySessionSummaryPeriod` has five cases, so
one feed listened to on one day on one device materialises a day, week, month,
year and forever row. For 40 feeds, five years of listening and two devices the
estimate is ≈ 40 × (1825 + 261 + 61 + 5 + 1) × 2 ≈ **170,000 rows** — more than
every other synced entity combined, for data every device can already recompute
from `ListeningHistorySync`, which is itself synced.

**Exposed.** All installs once UserState carries a full history.
**Live or dormant.** Live — `UserState.sqlite` syncs today.
**Presents as.** Slow first sync on a new device; iCloud storage consumed by
numbers that could have been computed locally.
**Status. Partly fixed** — `89c33947` adds the schema-vs-allow-list comparison, a
declared row-growth class per entity, an inventory of feed-derived fields that
leaked into synced records, and the cardinality arithmetic as a test. Removing
the aggregates from the synced schema is a product decision; see
[Unresolved](#unresolved--needs-a-decision).

Known feed-derived leaks, now inventoried in
`UserStateCloudSchemaAudit.feedDerivedFieldsBySyncedModel`:
`EpisodeStateSync.duration`, `ListeningSummarySync.podcastName`,
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

## F11 — `dequeueFinishedEpisodeAndReturnNext` was checked and is not a skip path

The brief asked whether skip-to-next stamps `completionDate` on an unplayed
episode. It does not. `dequeueFinishedEpisodeAndReturnNext`
(`PlaylistModelActor.swift:264`) has exactly one caller,
`Player.handlePlaybackFinished` (`Player.swift:2048`), which runs on end-of-media
only. `markEpisodeFinished` (`:401`) sets `completionDate` only when it is `nil`.

One asymmetry worth naming: `markEpisodeFinished` stamps `completionDate` but not
`isHistory`/`status`, whereas `EpisodeActor.markasPlayed` (`:426`) sets all four.
`Episode.isPlayed` (`Episode.swift:356`) returns true on `completionDate` alone,
so the two paths agree for every consumer checked — including
`PlayedEpisodeQueuePolicy`, which keys off `isPlayed` plus `completionDate`.

**Status.** No defect found. Recorded so the question is not re-opened from
scratch.

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

The nine synced entities, classified against the purpose (a small store that
syncs quickly), not merely against the allow-list. The growth classes are now
declared in `UserStateCloudSchemaAudit.rowGrowthBySyncedModel`.

| Entity | Growth | Verdict |
| --- | --- | --- |
| `SubscriptionSync` | per feed | correct — user-owned, bounded |
| `PodcastPreferenceSync` | per feed | correct |
| `EpisodeStateSync` | per touched episode | correct; carries one feed-derived field (`duration`) |
| `QueueEntrySync` | per membership incl. tombstones | correct |
| `PlaylistSync` / `PlaylistEntrySync` | per membership incl. tombstones | correct |
| `BookmarkSync` | per user action | correct |
| `ListeningHistorySync` | per session per device, forever | **product question** |
| `ListeningSummarySync` | feeds × periods × 5 kinds × devices | **should not sync** |

**Should derived aggregates sync at all?** No. Every device already holds the
history the aggregates are computed from, and the aggregates are recomputable
locally at any time. Syncing them buys nothing and costs the largest table in the
store, the reconciliation problem in F5, and the feedback loop in F4. Removing
them from the synced schema deletes a bug *class* rather than fixing an instance.
The one thing they currently provide is a lifetime total for periods whose raw
sessions were pruned — the `__legacy_shared__` row. That is a single row per
feed, not five per period per device, and it can be kept as an explicit
"pre-split baseline" record without syncing the rest.

**What does listening history require?** This is the per-account versus
per-device statistics question and it is not the audit's to settle. The trade:

* *Full session records* (today): every device can recompute any statistic and
  any period; payload grows without bound with listening time, across devices.
* *Compact records* — one row per (episode, day, device) instead of per session:
  roughly an order of magnitude fewer rows, keeps per-podcast and per-day
  statistics, loses session-level detail (start/end positions, clean-end).
* *Nothing synced*: statistics become per-device. Smallest possible store. The
  user sees different numbers on iPhone and iPad, which for a "lifetime
  listening" figure is likely to read as a bug.

**Does `UserStateCloudSchemaAudit` constrain size or only membership?** Only
membership, and it did not even constrain that against the real container. Both
gaps are closed in `89c33947`.

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
3. **The recovery toolkit has to ship (F1).** A cutover whose failure mode is
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

**Did any shipped build ever have legacy mirroring off?** Yes, conditionally —
see F2. Builds from 2026-06-24 to 2026-08-17, which include the two release
commits on this branch, opened the legacy store `cloudKitDatabase: .none`
whenever the remote kill switch was engaged. Separately, the branch had it
unconditionally off from `9c7ddeae` (2026-08-17) to `0d0f3f77` (2026-08-21),
which is the development-device window. Users are already exposed if — and only
if — the `RolloutConfig` record ever carried a killing value while such a build
was installed.

---

## Hardening plan

### Must land before any cutover

1. **Answer the `RolloutConfig` history question** (F2). Until it is answered, no
   build that re-attaches the legacy store should ship: any device the kill
   switch detached would merge on first launch, with no recovery UI.
2. **Ship the recovery toolkit** (F1). At minimum: store export, dedup dry-run
   and apply, and a way to clear the re-attach block. Behind a support-only
   entry point if necessary, but present in the binary.
3. **Bring the legacy CloudKit flag under the kill switch** (F6), or accept in
   writing that rollback means "sync stops" and put that in the release notes and
   the runbook.
4. **Decide the `ListeningSummarySync` question** (F8). Cutting the derived
   aggregates from the synced schema before the payload becomes a user-visible
   sync time is much cheaper than cutting them after.
5. **Stage the cutover.** The phase constant flips for everyone at once. A
   percentage rollout driven from the existing `RolloutConfig` record, or a
   TestFlight-only phase gate, converts a population-scale one-way door into a
   sampled one.
6. **Add convergence telemetry** to the pre-cutover release, so "phase one has
   converged across the population" is a measurement rather than an assumption.

### Follow-up

7. Consolidate on read in `StoreSplitEpisodeStateSyncWriter` the way
   `StoreSplitPlaylistSyncWriter.consolidateEntries` already does (F7).
8. Add a bounded orphan-entry sweep to `LibraryDeduplicationService`'s plan/apply
   model (F9) — planned and reviewed, never automatic.
9. Give `modeAllowsDuplicateCleanupDuringProjection` a reason or delete it (F7),
   and move `hideDuplicatePodcasts` after the subscription loop so duplicates
   created in the same pass are seen.
10. Decide the listening-history payload shape (F8).
11. Consider declaring the inverses on the four inferred relationship pairs
    explicitly. The tests added here catch a regression; a declaration would
    prevent one. It is a schema edit against a CloudKit-mirrored store and needs
    its own migration review, which is why it is not in this branch.

---

## Unresolved / needs a decision

Stated as open questions, not as conclusions.

**Has any TestFlight build carried the store-split code?** The repository says
the code is branch-only and that the branch's build number is 163 ahead of
`main`'s, which is consistent with — but not evidence of — TestFlight
distribution from the branch. *Settled by:* App Store Connect build history for
2026.15 and the branch each TestFlight build was cut from. Every "TestFlight
exposure" statement above depends on this.

**Was the `RolloutConfig` record ever set to a killing value?** This decides
whether F2 is a closed code path or a population that is already duplicated.
`forceLegacyReads = true`, or `minSupportedBuild` above an installed build, at
any time between 2026-06-24 and 2026-08-17. *Settled by:* the CloudKit Dashboard
history of the `store-split-rollout-config` record in the public database of
`iCloud.de.holgerkrupp.PodcastClient`, and the TestFlight/App Store build list
for the same period. Until that is checked, no build should ship that re-attaches
the legacy store — the affected devices would merge on first launch, with no
recovery UI (F1).

**Are per-device summaries and `__legacy_shared__` provably disjoint now?** They
are disjoint *by construction* given F5's fix, because the only mechanism that
moved a row between the sets is gone. That is an argument, not a proof: it
assumes no other writer clears `isLegacyMigrated` and that the migration never
emits a live-device summary. Both hold in the current code. *Settled by:* a
device-level audit that sums `ListeningHistorySync` grouped by
`isLegacyMigrated` and compares it against the summaries, on a real store.

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
