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

The build-560 candidate `optionalURLs.contains(episode.url)` predicate remains in use and is exercised by SQLite-backed tests. Passing tests show it works in these fixtures on the available simulator; they do not prove it safe on every iOS release or establish incident causality. The nested transcript availability predicate and release-prediction predicate also remain to be isolated on the affected OS. Existing issue history records that an earlier proposed build-550 fix did not resolve a reported Library crash, so this PR is diagnostic hardening rather than a confirmed root-cause fix.

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
