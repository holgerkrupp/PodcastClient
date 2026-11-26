# Build 560 SwiftData SIGTRAP investigation

Incident #348 (2026-10-17, iPhone16,1, iOS 27.0 beta 24A5430a) ends in `Swift._assertionFailure` and SwiftData frames on `NSManagedObjectContext.performAndWait`. The faulting stack contains no Up Next frame, assertion text, or active operation. It does not identify a predicate and does not establish corruption, CloudKit involvement, or the cause of the earlier CPU/watchdog reports.

## Source and archive evidence

The default branch was `main` at `16deaade7b7cdfd590ed08ca5a4407fa4d6c2ce0`. Commit `f796cfa27604f9d8795b73527132b655dfb27501` changes `CURRENT_PROJECT_VERSION` from 553 to 560 and `MARKETING_VERSION` to 2026.32. That corroborates the reported build number, but is not a binary source fingerprint. The available local Up Next archive is from 2026-10-11 and build 540; its dSYM UUID (`814DEA65-F408-30E1-ACB5-5EEB9B55E566`) does not match the incident's app UUID (`4d9d00e9-69f5-34af-a35e-25722f993bd0`). No matching build-560 archive/dSYM was present, so symbolication cannot identify the app call site.

The historical incidents are distinct: #338 documents an uncaught Objective-C `NSSQLGenerator` exception (build 540); #283 includes a CPU kill/watchdog path and a separate playlist SIGTRAP; #165 describes SwiftData materialization SIGTRAP; #74 includes `_InvalidFutureBackingData` and a later query assertion family; #81 describes repeated launch-time query assertions. Neither an Objective-C SQL-generator exception nor a watchdog is established by #348's Swift assertion stack.

## Hardening in this change

- The visible-page helper's optional URL membership fetch now propagates `ModelContext.fetch` failures. Previously `try?` converted a failed read into an empty page, hiding a real error as missing episodes. Podcast Detail reports the failure and retains the last successfully loaded results. A thrown Swift/Objective-C trap is still not recoverable with `do/catch`.
- The current actor implementation resolves the podcast in its owning context and reads its episode relationship instead of compiling the prior optional `Episode.podcast?.feed` predicate. This avoids that predicate translation, but currently materializes the selected podcast's episode relationship within the model actor. No claim is made that this was the incident trigger.
- The visible-page URL lookup records a privacy-safe start/end breadcrumb with an operation UUID, predicate label, requested/unique counts, and elapsed milliseconds. DEBUG Development Settings can copy the persisted breadcrumb buffer after relaunch; an unmatched start helps identify the last operation interrupted by process termination. No feed URL, title, transcript, or token is included.
- Visible pages map fetched models back by persistent ID in the filter actor's original order, so duplicate URLs cannot substitute one row for another. Rows with nil URLs use bounded, single-ID reads only within the visible page (at most 80); rows deleted between filtering and page resolution are skipped. The reopened SQLite regression checks nil and duplicate episode URLs plus duplicate/missing URL inputs against fixture truth.

At the time of this first change the build-560 candidate `optionalURLs.contains(episode.url)` predicate remained in use (removed in the follow-up below) and was exercised by SQLite-backed tests. Passing tests show it works in these fixtures on the available simulator; they do not prove it safe on every iOS release or establish incident causality. The nested transcript availability predicate and release-prediction predicate also remain to be isolated on the affected OS. Existing issue history records that an earlier proposed build-550 fix did not resolve a reported Library crash, so this PR is diagnostic hardening rather than a confirmed root-cause fix.

## Follow-up hardening (Nov 2026)

These changes remove the remaining candidate predicate shapes from the Podcast Detail and transcript-search paths. The root cause is still **not** identified. None of this proves that any removed predicate caused the build-560 assertion.

- **URL membership removed from Podcast Detail.** `ModelContext.episodes(forPageIDs:urls:)` now resolves each visible row (at most one 80-row page) with its own primary-key predicate (`persistentModelID == id`, `fetchLimit = 1`). It keeps the actor's order, skips rows deleted since filtering, and propagates fetch errors. `episodes(forURLs:)` keeps its signature but issues one scalar `episode.url == url` fetch per unique URL (SQL: `ZURL = ?`) instead of `optionalURLs.contains(episode.url)`. It returns every episode sharing a URL, each only once. Nothing in the app calls it any more; tests still do.
- **Nested optional transcript predicates removed.** The podcast scope in `TranscriptSearchActor` (search, availability, live transcripts) and `resolveEpisodePersistentID` no longer compile `line.episode?.podcast?.feed/title` or `episode.podcast?.feed`. They resolve the podcast(s) by the scalar `feed`/`title` key, take their episode IDs via the episode foreign key, then query lines per episode by persistent ID. Search keeps an exact total count and `startTime` paging: once `offset + limit` candidates are held, each later episode fetches only lines starting at or before the current window boundary. Ties at the same `startTime` are now ordered deterministically; before, SQLite's order was undefined.
- **Foreign-key predicate form.** SQLDebug shows that `x?.persistentModelID == id` compiles to `CASE (ZEPISODE IS NOT NULL) WHEN 1 THEN ZEPISODE ELSE ? END = ?`. SQLite cannot use the `ZTRANSCRIPTLINEANDTIME_ZEPISODE_INDEX` / `ZEPISODE_ZPODCAST_INDEX` for that, so every per-episode query was a full table scan. The short-circuiting `x != nil && x!.persistentModelID == id` compiles to `ZEPISODE IS NOT NULL AND ZEPISODE = ?`. It is now used for these per-episode/per-podcast lookups, including `PodcastEpisodeFilterActor`'s transcript match. `if let` and `flatMap` spellings also produce `CASE`.
- **Errors are no longer false-empty.** The filter actor's transcript match now throws instead of `try?` → `false`. Podcast Detail keeps its last known transcript-search availability when that read fails.
- **One fewer Podcast Detail query.** `PodcastEpisodeFilterResult.podcastHasEpisodes` comes from the same relationship read as the episode IDs. The separate `hasEpisodes` actor call is gone; the view awaits the first filter pass before deciding on an initial feed import, and still defaults to "has episodes" on failure.
- **Stale async results.** Each filter pass in Podcast Detail carries a generation number. A pass may publish IDs, the page, the error or the existence flag only while it is both uncancelled and the newest. Transcript availability is also dropped after cancellation.

Still hypothesis or open: the triggering action and assertion text of #348; whether any removed predicate, overlapping-context invalidation or the release-prediction path was involved; behaviour on physical iOS 27.0 beta 24A5430a / iOS 26.7.1 devices; optimized (Release) test execution. The `existingModel`/`existingModels` helpers still use `try?` (unchanged callers outside this scope).

### Disk-backed stress coverage (#291, automated part)

`UpNextTests/SwiftDataDiskStressTests.swift`:

- `testReopenedSQLiteQueriesMatchFixtureTruthAtScale` writes and then reopens an on-disk SQLite store (`cloudKitDatabase: .none`) at 0, 1, 100 and 1,000 selected-podcast episodes. Set `TEST_RUNNER_SWIFTDATA_STRESS_10K=1` to add the 10,000-episode case. Fixtures include nil and duplicate URLs, URLs shared with another podcast, a podcast-less episode with a transcript, an orphan transcript line and nil publish dates. Expected results come from unfiltered fetches walked in memory, and the test compares them exactly: URL lookup (dedup, missing URL, cross-podcast matches), filter IDs and `podcastHasEpisodes`, newest/oldest/title ordering, first and second page identity, podcast-scope availability, podcast-scope total and offset pages, and episode scope.
- `testOverlappingQueueAndRefreshContextsStayConsistent` runs 40 deterministic interleavings on one reopened on-disk store. Each one combines a queue insert/reorder/remove/snapshot on a long-lived context, a delete/insert/rename "refresh" on a second context, a stale visible page resolved after the delete, and fresh filter/transcript actor reads. Each step is checked against a fresh-context truth. This is sequential interleaving, not true parallel execution; parallel timing races remain for device sessions (#402/#455).

Verified 2026-11-26 on the iPhone 17e simulator (Debug, non-parallel): `SwiftDataDiskStressTests` (2), `SwiftDataRelationshipSafetyTests` (3) and `TranscriptSearchServiceTests` (4) pass. The opt-in 10k disk case passes in about 25 s. In the `RUN_TRANSCRIPT_SEARCH_PERFORMANCE` benchmark, podcast-scope search takes about 158 ms for 100k lines and 0.6 s for 500k, against 82 ms and 307 ms for library scope. With the `CASE` form it took 17 s at 500k; the old nested predicate's latency was not measured. A Release-configuration simulator build succeeds; Release *test execution* was not attempted.

## Validation and remaining evidence

Run the focused suite from the repository root:

```sh
xcodebuild test -project 'Up Next.xcodeproj' -scheme UpNext \
  -destination 'platform=iOS Simulator,id=<available-iOS-27-simulator>' \
  -derivedDataPath "$TMPDIR/PodcastClient/DerivedData" \
  -only-testing:UpNextTests/SwiftDataRelationshipSafetyTests

xcodebuild test -configuration Release ENABLE_TESTABILITY=YES \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG $(inherited)' \
  -project 'Up Next.xcodeproj' -scheme UpNext \
  -destination 'platform=iOS Simulator,id=<available-iOS-27-simulator>' \
  -derivedDataPath "$TMPDIR/PodcastClient/DerivedData" \
  -only-testing:UpNextTests/SwiftDataRelationshipSafetyTests
```

The persisted/reopened SQLite test covers 120 episodes, nil/duplicate URLs, transcript availability, actor filtering, page identity/order, empty/single podcasts, and release prediction. The existing 0/100/1,000/10,000 fixture is in-memory. The Release configuration retains `-O` while enabling `DEBUG` because the existing test target references development-only APIs. In this environment the optimized test build reached simulator launch but produced no test cases; the app process remained suspended and the run was interrupted after more than six minutes. Treat Release test execution as unavailable, not passing. The available simulator is iPhone 18 Pro / iOS 27.0, not a physical affected device; no physical iOS 27.0 beta 24A5430a, iOS 26.7.1, or real CloudKit account run is claimed here. There was no reproduction with an Objective-C exception breakpoint or captured assertion reason. To establish the original cause, collect a fresh post-change `.ips` plus exact build archive/dSYM and persisted breadcrumbs, then reproduce on the target OS with `Swift Error Breakpoint` and Objective-C exception breakpoints while isolating the candidate fetches independently.

The final Debug run from a clean worktree passed all three `SwiftDataRelationshipSafetyTests` cases on iPhone 18 Pro / iOS 27.0 simulator. The 10,000-episode in-memory case took 16.4 seconds in that run; no absolute timing gate is asserted. The focused reopened SQLite case passed in 0.15 seconds.

Related history: [#348](https://github.com/holgerkrupp/PodcastClient/issues/348), [#338](https://github.com/holgerkrupp/PodcastClient/issues/338), [#291](https://github.com/holgerkrupp/PodcastClient/issues/291).
