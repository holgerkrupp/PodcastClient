# Two Databases on Every Device

Status: proposed, 1 Nov 2026. Nothing here is implemented yet. The file-level audit
below comes from reading schemas and call sites; items marked **verify** still need
checking against the code or a real store before their step ships.

## Goal

Every device ends up with the same two stores, whatever state it starts in:

| Store | Role | iCloud |
| --- | --- | --- |
| `UserState.sqlite` | Small, user-owned state | Syncs |
| `SharedDatabase.sqlite` | The podcast library the UI reads and writes | Never |

`PodcastCache.sqlite` and `LibraryRuntime.sqlite` go away. There is no merge at the end:
`SharedDatabase.sqlite` is the permanent library.

## Where things are today

| Device | Library the UI uses | Also opened at launch |
| --- | --- | --- |
| Upgraded | `SharedDatabase.sqlite` | `UserState`, `PodcastCache` |
| Fresh install, or split-only from an older build | `LibraryRuntime.sqlite`, built from the cache | `UserState`, `PodcastCache` |

Two facts make this tractable:

- `LibraryRuntime.sqlite` is opened with `makeLegacyContainer`, so it already has the same
  schema as `SharedDatabase.sqlite`. A finished runtime file can become the library by being
  moved, with no row copied.
- `PodcastCacheRepository` has no callers outside its own file, so nothing in the UI reads
  through it. **Verify** before removing it.

## The trap: a library file currently means "legacy upgrade"

`StoreBootstrapMode.resolve` treats any `SharedDatabase.sqlite` as `legacyUpgrade`. Simply
creating that file on a split-only device would therefore:

1. Start the deferred copy from the library into UserState, with a possibly incomplete library.
2. Block imports from UserState until that copy finishes.
3. Run `tombstoneSubscriptionsMissingFromLibrary`, which **removes subscriptions from iCloud,
   on all devices,** for any podcast the library doesn't hold yet.

So the first step is recording where a library came from, not creating files:

- New persisted value `libraryOrigin`: `legacy` or `built`.
- It is written **before** a built file appears at the final path. A crash in between leaves
  a value with no file, which is harmless; the reverse would look like a legacy library.
- A file with no recorded origin is `legacy`, which is what every existing upgraded device is.
- `built` libraries skip the deferred copy and the tombstone cleanup, and import from UserState
  normally. They must also never attach to CloudKit; add a test next to the existing
  re-attach guard.

## Every starting state converges

Checked in this order at launch. Each path is resumable and safe to interrupt.

| Starting files | Action | Result |
| --- | --- | --- |
| `SharedDatabase` present | Open it. Origin stays as recorded, otherwise `legacy`. | Library unchanged |
| `LibraryRuntime`, no `SharedDatabase` | Move it into place (below), keep the fill cursor | Built library, fill resumes |
| `UserState` + `PodcastCache` only | Create the library, build it from the cache, then fetch feeds | Built library |
| `UserState` only | Create the library from subscriptions, then fetch feeds | Built library |
| `PodcastCache` only | Build from the cache. Subscriptions still come only from UserState and iCloud, and nothing in the cache is published to UserState. | Built library |
| Nothing, no sign of an earlier library | Create an empty library | Built library |
| No library, but evidence one existed | Keep today's stop screen. "Continue with iCloud Data" then takes one of the rows above. | Built library, by user choice |

The build reuses what exists: `StoreSplitCompatibilityProjectionService`,
`StoreRuntimeProjection.fillFromFeeds` and the backfill cursor.

**Moving a runtime file:** with no container open, run a truncate checkpoint through
`StoreWriteAheadLog`, close, confirm no `-wal` remains, then rename the main file. The rename
is atomic. If a log remains, don't move it; retry next launch and keep using the runtime file.
Copy a file only if a rename is impossible. **Verify** the widget and share extension can't
hold these files open at that moment; the backfill's comment says they can open the store.

**A device with both files:** `SharedDatabase` wins, as it does today, and `discardUnused`
removes the derived runtime file.

Afterwards, delete the branching: `usesInMemoryRuntimeProjection` and
`runtimeProjectsFromCache` (12 uses) disappear, and with them the second code path.

## What happens to each cache table

### Copies of the library: stop writing, then remove

`CachedPodcast`, `CachedEpisode`, `CachedChapter`, `CachedTranscriptLine`,
`CachedTranscriptionRecord`, `CachedDownloadRecord`, `CachedPlaySession`, `CachedRateSegment`,
`CachedHourlyListeningStat`.

These stay the source for building a library on the split-only states above, until that
device's build has finished. **Verify** the transcript and analytics fields round-trip, because
saved transcripts and listening history can't be refetched from feeds.

### Only here: move into the library

| Table | Why it stays | Check |
| --- | --- | --- |
| `CachedTranscriptAlignment`, `CachedTranscriptSynchronizationJob` | Live feature; `TranscriptSynchronization` uses them | Your uncommitted edits touch this file |
| `FeedAlias` | Redirected feed URLs | |
| `CachedMissingEpisodeReference` | Queue and playlist entries whose episode isn't local yet | |
| `CachedPodcastLocalSettings`, `CachedBookmarkDetail` | Read by the UserState importer | **Verify** whether `PodcastSettings` and `Bookmark` already hold everything; if so, drop instead |
| `CachedFeedExtensionElement` | Written on feed refresh | **Verify** anyone reads it; if not, drop |

Adding tables changes the library's schema, so the first launch after that update runs a
Core Data migration on a store of up to about 5 GB. **Measure this on a copy of a real store
before shipping.** If it's slow, it needs the existing progress screen or a smaller design.

### AI content: probably unnecessary

`AITranscriptSync`, `AITranscriptChunkSync`, `AIChapterSetSync`, `AppliedAIContentRevision`.

Despite the names these live in the local-only cache, and AI content stays on one device by
design. **Verify:** if the library already holds these transcripts and chapters, this copy
serves no purpose. Removing that phase would also finish the copy on devices stuck at
`ai_transcripts`, including the subscription cleanup that waits behind it.

### Migration bookkeeping: remove once the copy is finished everywhere

`StoreSplitMigrationCheckpoint`, `StoreSplitMigrationVerification`,
`StoreSplitFeedCacheCheckpoint`, `CachedListeningBaselineAggregate`,
`CachedListeningBaselineSource`.

Upgraded devices still need these while their copy runs. The migration service reads the cache
in many places, so it's rewritten last.

## Order of work

Each step ships alone and leaves every device working.

1. **Faster launch now.** Run `LegacyStoreIndexBackfill` only until it has succeeded once, so
   launch stops opening a separate connection; closing that connection can merge the whole log.
   Measure each step using the logging from `a129bb51`. Also find out what fills 4.7 GB;
   Core Data's old CloudKit history tables are one candidate, unconfirmed.
2. **Record `libraryOrigin`.** No behaviour change, but every later step depends on it.
3. **Decide on the AI copy** from the check above.
4. **Converge fresh and split-only devices** using the table above, with one code path.
5. **Move the unique tables** into the library and read them from there.
6. **Stop writing the copied tables**, then stop opening `PodcastCache` once a device's build
   and copy are complete.
7. **Reclaim the disk space.** See the decision below.

## Launch target

Normal launch: library visible in under 2 seconds on a recent iPhone. This is a target, not a
measurement. Removing the cache removes one of three store opens, but the size of the
library's log and the index check may matter more, which is why step 1 comes first.

## Tests

- One fixture per row of the state table, asserting the same two stores and no lost
  subscriptions, queue entries, bookmarks, transcripts or listening history.
- Interrupt each path at each step and relaunch.
- A built library never runs `tombstoneSubscriptionsMissingFromLibrary` or attaches to CloudKit.
- Unset `libraryOrigin` with an existing file still behaves as `legacy`.
- By hand, on real devices: one populated upgrade, one split-only device, one fresh install,
  two devices on one account. Simulator tests can't stand in for these.

## Risks

- **Downgrades:** an older build sees `SharedDatabase.sqlite` and treats it as a legacy store,
  which could attach it to CloudKit. The App Store doesn't offer downgrades, but TestFlight
  can. Earlier re-attachment duplicated most of a library; see
  `StoreSplitCloudReattachGuardTests`.
- **Older devices on one account:** they keep writing UserState as they do now. This plan
  doesn't change the UserState schema, so it needs no CloudKit schema deploy of its own.
- **#395:** failing exports remain a separate release blocker.

## Decisions needed

1. **Deleting `PodcastCache.sqlite` (step 7).** Standing rule so far: never delete user
   databases. Proposal: stop using it first, leave it in place for one full release, and delete
   it only after a separate go-ahead. Until then the device keeps about 1 GB it doesn't need.
2. **Filename.** Proposal: keep `SharedDatabase.sqlite` everywhere. Renaming a 4.7 GB store on
   every upgraded device adds risk and only tidies a name. A new name would avoid the downgrade
   risk on fresh devices but not on upgraded ones.
