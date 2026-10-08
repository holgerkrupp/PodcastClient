# Store split release gate

The dual-sync backfill must be exercised with release-equivalent stores before an App Store rollout. The automated coverage lives in `StoreSplitSliceMigrationTests` and must remain green together with the focused HTML, live-podcast, and shownote suites.

## Automated scenarios

- A two-device dual-sync fixture converges after interrupted slice work and a relaunch.
- A failed store-preparation attempt remains deferred and succeeds after retry.
- A CloudKit-busy window and active playback yield without mutating the stores.
- Background-processing expiration stops at a slice boundary and resumes later.
- A fresh-install fixture completes without legacy data and without repeated full scans.
- Bootstrap mode selection covers fresh install, local legacy upgrade, and the one-way post-cutover path.
- Heavy migration and cache maintenance policy rejects foreground execution and allows the system processing context and test context.
- Launch and CloudKit import callbacks persist a pending reconcile and arm BGProcessing without invoking the whole-library importer on the foreground runner.
- Queue and playlist projection retains stable identity and order when UserState rows arrive before matching cache metadata.
- Timestamp and tombstone conflict cases preserve newer synchronized state after a resumed migration.

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
| Resource interruption | Expire the processing task, reboot, update the app, drop network/power, begin playback, and hold a CloudKit export open | Work yields promptly, stores remain consistent, and the next eligible window resumes from durable state. |
| Large library | Run typical, long-time, and high-row-count history fixtures | Every successful window advances measurable progress within the opportunity targets from issue #198. |

## TestFlight checklist

- Upgrade a populated release build with CloudKit enabled on device A; verify diagnostics report readiness, current phase, progress, blocker, and retry time truthfully.
- Launch device B with the same account while A is migrating; verify both devices converge after export/import settles.
- Suspend and relaunch during each migration phase; verify no duplicate rows and no premature completion.
- Start playback, background the app, and force a CloudKit export; verify playback continues and migration/reconcile work yields.
- Let a background-processing task expire; verify the next foreground or processing window resumes from the durable cursor.
- Confirm the diagnostics health record contains only target host, phase, counts, timing, and redacted errors—never feed URLs, credentials, or payloads.

Record the build number, OS version, fixture name, and result for each run in the release checklist before enabling the migration remotely.
