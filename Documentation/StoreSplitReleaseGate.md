# Store split release gate

Decision (30 Oct 2026): upgraded devices keep `SharedDatabase.sqlite` as their local library,
with CloudKit off. There is no blocking migration, no copy of the library, and no
stabilization-only release. This narrows epic #394, whose full move to two stores took too
long on a real 4.68 GB library.

## Stores

| Store | Role |
| --- | --- |
| `UserState.sqlite` | The only CloudKit-backed store. Subscriptions, shared preferences, playback state, queue and playlists, bookmarks, listening history and baselines. |
| `SharedDatabase.sqlite` | Upgraded devices: the local library the UI reads and writes. Never attached to CloudKit again. |
| `LibraryRuntime.sqlite` + `PodcastCache.sqlite` | Devices with no legacy store (fresh installs): the same role. The runtime file is derived and built once. Its first build holds every podcast plus Inbox, playlist, bookmarked, downloaded and recently played episodes; the rest comes from a full fetch of each subscribed feed after opening. Saved transcripts then follow from the cache. Until that finishes, routine feed refresh and automatic transcription are off, and an episode with no lines never overwrites cached ones. |

## Startup

A legacy file present means an upgraded device: it opens directly, whatever its earlier state.
No legacy file and evidence of a library fails closed. No legacy file and no evidence means a
fresh install. Readiness depends only on local stores; CloudKit never blocks startup.

## Upgrade

`runDeferredMigrationIfNeeded` copies user data to UserState in checkpointed slices while the
app is open and foreground. A failure stays quiet and resumes next launch. Until it finishes,
nothing is imported back from UserState, because the local library is the more complete record.
Live edits are written to UserState as they happen.

Once the copy finishes, one cleanup tombstones active subscriptions that this library has no
podcast for and that predate its switch to local-only. Older backfills left such rows behind
(475 active against about 55 real on one device), and a new device would restore them all.
A real subscription that exists only on a device not yet updated can be removed by this; it
comes back only when that device updates and writes it again.

## Multiple devices

Only UserState syncs. Each device gets feed data from RSS. These stay on one device: AI
transcripts, AI chapters, downloads, bookmark images and links, and device-local settings.

- An old-version device writes to UserState too but never reads it, so its changes reach
  updated devices and not the reverse, until it updates.
- Merging by stable identity, date and tombstones stops older data overwriting newer data. An
  entry removed before tombstones existed can come back from a long-dormant device.
- **Release blocker:** with no legacy mirror, failing UserState exports (#395) mean devices
  silently diverge. Its cause has to be known before release.

## Manual checks before App Store release

- Upgrade a real populated App Store install; check everything opens at once and the copy finishes.
- Two devices on one account, both directions, with one updated first.
- Confirm in the CloudKit Console that no schema change needs deploying (UserState is unchanged).
- Listening total against the expected figure. One device showed 1451h against about 400h:
  a 1148h baseline from an older tier or run, plus live sessions the year summaries already
  held. Year summaries there added up to 496h, which the owner considers plausible. Upgraded
  devices now show the sum of their year summaries as the lifetime total.

---

# Earlier release notes (history)


The dual-sync backfill must be exercised with release-equivalent stores before an App Store rollout. The automated coverage lives in `StoreSplitSliceMigrationTests` and must remain green together with the focused HTML, live-podcast, and shownote suites.

## Automated scenarios

- A two-device dual-sync fixture converges after interrupted slice work and a relaunch.
- A failed store-preparation attempt remains deferred and succeeds after retry.
- A CloudKit-busy window and active playback yield without mutating the stores.
- Store-open and CloudKit event diagnostics report per-store operation duration
  and whole-process CPU deltas. Migration-slice health records include rows
  scanned/mutated, save count/duration, CPU delta, footprint, playback state,
  and whether the operation held a BGProcessing grant. CPU deltas are
  correlation evidence because unrelated process work can overlap a sample.
- Opening the usable runtime container records startup readiness independently
  from the longer exporter observation window. Short foreground sessions,
  ordinary backgrounding, and stale export markers never change the legacy
  store's CloudKit attachment. Automatic quarantine remains disabled until a
  reliable incident signal and a data-convergence gate exist; diagnostics and
  a recovery offer may still be recorded without modifying either store.
- Background-processing expiration stops at a slice boundary and resumes later.
- A fresh-install fixture completes without legacy data and without repeated full scans.
- Bootstrap mode selection covers fresh install, local legacy upgrade, and the one-way post-cutover path.
- Heavy migration and cache maintenance policy rejects foreground execution and allows the system processing context and test context.
- Launch and CloudKit import callbacks persist a pending reconcile and arm BGProcessing without invoking the whole-library importer on the foreground runner.
- Queue and playlist projection retains stable identity and order when UserState rows arrive before matching cache metadata.
- Timestamp and tombstone conflict cases preserve newer synchronized state after a resumed migration.
- A 2,679-row listening-summary fixture aggregates in bounded pages, publishes no partial baseline, and preserves total and saved-time components.
- Listening summaries and history are dispatched before the historical episode-state sweep; the overnight policy is local-time and charging gated.
- Unchanged cached history sessions retain their child rows, and source/destination fetch errors leave the phase pending rather than treating it as empty.
- A 14k-episode performance fixture must report scanned rows, pages, saves, active time, idle time, memory, and yield reason per successful system grant; tune production targets from device measurements without weakening watchdog limits.

## Device-history matrix

Run the following cases on physical devices or release-equivalent CloudKit accounts. Record the app build, OS version, device role, migration phase, and result for each case.

| History | Setup and interruption | Expected result |
| --- | --- | --- |
| Fresh account | Install with empty iCloud; add subscriptions and queue entries | No `SharedDatabase.sqlite` is created; UserState and PodcastCache persist the new data. |
| Existing account on new device | Start with no local legacy file; delay CloudKit import and feed refresh | Queue/subscription state remains visible and resolvable as feeds are rebuilt. |
| Local upgrade | Upgrade with a populated legacy store; interrupt each migration phase | Existing library stays usable; each phase resumes from its saved checkpoint without duplicate or rewound user state. |
| Dormant device | Keep a second device offline through newer queue, bookmark, and playback updates; reconnect it during migration | Delayed legacy state does not replace newer UserState records or reorder the queue. |
| Concurrent second device | Add a device while the primary is backfilling; then repeat after cutover | Both devices converge after CloudKit settles; post-cutover bootstrap does not depend on legacy reads. |
| Feed recovery | Exercise queue-first metadata arrival, temporary/permanent feed failure, private credentials, and redirect aliases | UserState references remain intact; recoverable feed failures are reported separately from blocking user-state gaps. |
| Resource interruption | Expire the processing task, reboot, update the app, drop network/power, begin playback, and hold a CloudKit export open | Work yields promptly, stores remain consistent, and the next charging night resumes from durable state. No bulk migration runs during daytime or playback. |
| Large library | Run typical, long-time, and high-row-count history fixtures | Every successful window advances measurable progress within the opportunity targets from issue #198. |

## TestFlight checklist

- Upgrade a populated release build with CloudKit enabled on device A; verify diagnostics report readiness, current phase, progress, blocker, and retry time truthfully.
- Launch device B with the same account while A is migrating; verify both devices converge after export/import settles.
- Suspend and relaunch during each migration phase; verify no duplicate rows and no premature completion.
- Start playback, background the app, and force a CloudKit export; verify playback continues and migration/reconcile work yields.
- Let a background-processing task expire; verify the next foreground or processing window resumes from the durable cursor.
- Confirm the diagnostics health record contains only target host, phase, counts, timing, and redacted errors—never feed URLs, credentials, or payloads.

Record the build number, OS version, fixture name, and result for each run in the release checklist before enabling the migration remotely.


## Issue #390 persistence repair — 2026-10-28

The production phase remains `dualSyncBackfill`. Fresh installations still use
UserState + PodcastCache and an ephemeral compatibility graph; upgrades keep
SharedDatabase as their runtime. This repair does not create a legacy database
on every fresh install or enable the December authority cutover.

### Confirmed mechanisms

- Fresh bootstrap deliberately selected an in-memory library when no legacy
  SQLite file existed. Playlist creation saved that graph, then launched an
  unawaited UserState task: termination could lose an acknowledged playlist.
  Queue publishers also swallowed UserState write failures.
- Initial cache reconstruction imported UserState once. Later successful
  UserState CloudKit events were gated behind the disabled Release authority
  cutover, so delayed records could stay invisible until another launch.
- Reconstructed episodes did not recover availability metadata. Downloads
  filtered by that flag before checking files. CachedDownloadRecord stores the
  flag and local URL, but neither is evidence that a file still exists in the
  current sandbox. Reconstruction and Downloads now check current file paths.
- A failed file-existence check could select a fresh runtime; factories silently
  fell back to memory when the app-group URL was unavailable. Factories now
  throw, bootstrap requires a successful directory read, and known store
  lineage (including earlier successful legacy-open markers) fails closed when
  its file is missing. Required split stores open before exposing the runtime.

These are reproduced source mechanisms, not proof of the reporting customer's
store topology; no customer database or launch diagnostics were supplied.

### Write and recovery behavior

Playlist creation/edits commit UserState synchronously; queue insertion/reorder
awaits a throwing commit. Split-runtime queue writes persist referenced feed
metadata before acknowledgment. Explicit removals/deletions persist tombstones;
failed fetches/commits throw and roll back pending transaction changes. A stale
publisher cannot revive a deleted playlist. Partial/empty imports cannot infer
deletions, and a tombstone arriving before its header cannot create a phantom
Up Next playlist.

Split runtimes hydrate playlists after successful CloudKit imports, foreground
activation, feed-cache completion, and acknowledged local writes. Hydration is
serialized and retries unresolved episode references without depending on a new
UserState timestamp. Failed cache fetches remain failures, and projection
retries add missing data without replacing existing runtime playlists.

### Reproduction and verification

Fixtures use anonymized `example.com` feeds, temporary disk-backed UserState and
PodcastCache databases, and a temporary audio file. Tests release the first
containers, recreate them at the same paths, and reconstruct a new runtime.

| Scenario | Automated evidence |
| --- | --- |
| Fresh/no legacy SQLite | Create and edit manual playlist; queue insert/remove/reorder; recreate both backing stores offline; restore identity/title/order |
| Intact legacy upgrade | Existing durable-store, projection, schema-upgrade and attachment-guard suites remain green |
| Unavailable storage | Nil/nonexistent directory, missing known store, and orphaned legacy WAL fail closed |
| Immediate restart | No CloudKit round trip between acknowledged playlist/queue writes and container recreation |
| Download restart | Existing file restored and visible even with false metadata flag; deleted file reconstructs as unavailable |
| Interrupted write | Inject commit failure; error propagates, context rolls back, reopened store has no phantom rows/tombstones |
| Delayed imports | State before cache; retry with unchanged state timestamps; empty import preserves membership; later explicit tombstone removes it |
| Out-of-order deletion | Tombstone before header does not create a default-queue duplicate; stale publisher cannot revive a deleted ID |

Validation: 127 selected tests passed on iPhone 18 Pro / iOS 27.0 Simulator,
and 127 passed on iPhone Duo / iOS 27.1 Simulator with Swift 6. Release
simulator compilation passed with the iOS 26 deployment target. The guide
registry has 23 unique topic IDs and 63 resolving related-topic links.

A separate disposable iPhone 18 Pro simulator also launched the real app,
terminated it and relaunched under a different process ID. Its app group held
UserState.sqlite + PodcastCache.sqlite (and their WAL/SHM files) without creating
SharedDatabase.sqlite; the relaunched process remained running. This is a
startup/topology smoke check, not a UI-driven playlist creation test. Simulator
UI automation was unavailable through the desktop app controls.

The build also required small existing compile-fixture repairs: isolate the
download stall monitor's actor reads, use SwiftUI's header/footer Section
initializer, use PlaylistEntry's actual initializer, and date a completion after
its queue insertion rather than decades before it.

### Help and limits

The in-app `playlists` and `downloads` topics and action-location guide were
updated. New error alerts have German translations. No help actions or deep
links were added. Settings/Siri guidance remains accurate. There is no guide
screenshot/fixture UI harness or canonical Documentation/UserGuide directory in
this checkout, so no synthetic screenshot was added. Compact-height, iPad,
macOS, VoiceOver and localized alert layout need real UI review. Live
multi-device CloudKit, physical storage protection, iOS 26 execution and
process-kill timing have not been verified here; disk-container recreation and
failure injection do not substitute for that release matrix.

Existing audio and playlists already present in UserState/legacy storage are
recoverable without reinstalling. State that existed only in memory before this
fix cannot be reconstructed. No customer files/stores were reset, removed,
reattached to CloudKit or made authoritative by a migration checkpoint.

### Changed files

- `Documentation/UpNextViewHierarchy.md`
- `Localizable.xcstrings`
- `Raul/App/ModelContainerManager.swift`
- `Raul/App/RaulApp.swift`
- `Raul/Features/Downloads/Services/DownloadManager.swift`
- `Raul/Features/Downloads/Views/DownloadedEpisodesView.swift`
- `Raul/Features/Help/UserGuideView.swift`
- `Raul/Features/Library/Views/Podcasts/PodcastListView.swift`
- `Raul/Features/Playlist/PlaylistLibrary.swift`
- `Raul/Features/Playlist/Views/NewPlaylistSheet.swift`
- `Raul/Features/Playlist/Views/PlaylistSettingsView.swift`
- `Raul/Features/Playlist/Views/PlaylistView.swift`
- `Raul/Features/Playlist/Views/PlaylistsSettingsSections.swift`
- `Raul/Features/Settings/Views/PodcastSettingsView.swift`
- `Raul/Models/Podcast/Episode.swift`
- `Raul/Shared/Actors/EpisodeListQueryActor.swift`
- `Raul/Shared/Actors/PlaylistModelActor.swift`
- `Raul/Shared/Services/StoreSplitCompatibilityProjectionService.swift`
- `Raul/Shared/Services/StoreSplitFeedCacheWriter.swift`
- `Raul/Shared/Services/StoreSplitPlaylistSyncWriter.swift`
- `Raul/Shared/Services/StoreSplitUserStateImporter.swift`
- `UpNextTests/PlaylistLibraryTests.swift`
- `UpNextTests/PlaylistModelActorPlaybackQueueTests.swift`
- `UpNextTests/StoreSplitPlaylistProjectionTests.swift`
- `Documentation/StoreSplitReleaseGate.md`


## Main branch consolidation — 2026-10-28

All local and fetched remote branch tips were merged into main, including the
previously missing `77d59e26` widget, CarPlay and share-extension updates.
CPU attribution, transcription scanning, optional audio-analysis and launch
quarantine branches had already been integrated by squash; merge commits now
record their ancestry without undoing newer code. The durable episode-completion
branch and detached artwork-recovery worktree were already ancestors of main.
The worktrees had no uncommitted changes. Saved localization changes and version
2026.35 (701) were committed, including removal of the obsolete prediction
localization. Branches and worktrees were retained.

Merge conflicts retained #390's persistence/lineage safeguards, the latest
version settings, localized save-error text and the equivalent actor-safe
stall-monitor implementation. The widget file now matches the newer source
branch exactly. The shipping store-split phase is unchanged.

Verification:

- Release arm64 simulator build passed after consolidation.
- A subsequent core-suite run in the normal iPhone Duo / iOS 27.1 simulator
  configuration succeeded: the Xcode result bundle confirms 127 passing test
  cases, zero failures and zero skips.
- Guide registry: 23 unique IDs and 63 valid related-topic links; localization
  JSON and diff whitespace checks pass.
- A full-suite attempt logged hundreds of passing cases and ten failing cases,
  then encountered simulator test-host launch/finalization errors. It did not
  complete successfully.
- Nine of those ten failures reproduce against the isolated pre-consolidation
  `47b6fc3f` source: two automatic-migration scheduling tests; nested smart-playlist
  categories; playback-rate and silence-gap statistics; share-link matching;
  AI transcript tombstone preservation; the old authoritative-playlist test;
  and subscription access-profile persistence. These are not newly introduced
  by merging the branches. The old authoritative-playlist assertion conflicts
  with #390's rule against inferring deletion from absent remote membership.
- The remaining chapter-gap test passed in isolation on pre-consolidation main.
  A merged single-process focused run passed 117 cases but encountered SwiftData
  `No eligible connection available` fixture exceptions in chapter/playlist
  fixtures. These runs do not establish a clean full-suite result.

The retained command logs under `/tmp/podcast-consolidated-*.log` distinguish
full-suite, isolated baseline, focused, core and Release runs. Simulator and
fixture-only build/source directories are temporary and are removed after
validation. No personal device stores were reset. The merged changes retain
their existing in-app share/CarPlay help and action-location updates; visual
head-unit/widget and cross-platform screenshot review remains separate from
these automated checks.
