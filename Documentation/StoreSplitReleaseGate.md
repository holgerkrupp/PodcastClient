# Store split release gate

The dual-sync backfill must be exercised with release-equivalent stores before an App Store rollout. The automated coverage lives in `StoreSplitSliceMigrationTests` and must remain green together with the focused HTML, live-podcast, and shownote suites.

## Automated scenarios

- A two-device dual-sync fixture converges after interrupted slice work and a relaunch.
- A failed store-preparation attempt remains deferred and succeeds after retry.
- A CloudKit-busy window and active playback yield without mutating the stores.
- Background-processing expiration stops at a slice boundary and resumes later.
- A fresh-install fixture completes without legacy data and without repeated full scans.

## TestFlight checklist

- Upgrade a populated release build with CloudKit enabled on device A; verify diagnostics report readiness, current phase, progress, blocker, and retry time truthfully.
- Launch device B with the same account while A is migrating; verify both devices converge after export/import settles.
- Suspend and relaunch during each migration phase; verify no duplicate rows and no premature completion.
- Start playback, background the app, and force a CloudKit export; verify playback continues and migration/reconcile work yields.
- Let a background-processing task expire; verify the next foreground or processing window resumes from the durable cursor.
- Confirm the diagnostics health record contains only target host, phase, counts, timing, and redacted errors—never feed URLs, credentials, or payloads.

Record the build number, OS version, fixture name, and result for each run in the release checklist before enabling the migration remotely.
