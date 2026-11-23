# #438 podcast refresh validation gate

This document is the device-validation handoff for [#438](https://github.com/holgerkrupp/PodcastClient/issues/438), the physical-iPhone and reliability gate for [#429](https://github.com/holgerkrupp/PodcastClient/issues/429). It extends the deterministic setup in [PodcastRefresh.md](PodcastRefresh.md); it does not replace that guide or claim a device result.

The checked-in automated tests are useful evidence for data integrity and recovery, but they do not substitute for a signed build on a physical iPhone, an iCloud account, or Instruments. Leave every device result blank until the run has actually been performed. Simulator timings are simulator results only.

## Reproducible fixture configurations

Start one fixture server for each run. The server exposes the same feed-number range for every profile and logs only method, profile, feed number, page, and status.

```sh
python3 Scripts/podcast-refresh-fixture-server.py \
  --feeds 100 --episodes 10 --delay 1
```

Use the following deterministic subscription sets. The feed numbers are the path component after the profile; keep the same mapping for before/after runs and shuffle only the scheduling order.

| Set | Feed count | Required mix | Purpose |
| --- | ---: | --- | --- |
| S10 | 10 | `fast/0`, `unchanged/1`, `slow-head/2`, `slow-get/3`, `head-unsupported/4`, `paged/5`, `dynamic/6`, `rate-limited/7`, `server-error/8`, `private/9` | Fast smoke and failure recovery |
| S50 | 50 | Five repetitions of the S10 profile mix, feed numbers 0–49 | Completion-order and writer cohorts |
| S100 | 100 | Ten repetitions of the S10 profile mix, feed numbers 0–99 | Long-run memory and SQL trend |

For a large-catalog run, restart the server with `--feeds 100 --episodes 5000 --delay 1` and use `large/0` as the 5,000-episode feed. A separate `--episodes 1000` run is useful for the 1k catalog case. The fixture server's `private` profile uses the documented fixture credentials only; do not use a real private feed in an attached artifact.

Run each set at least five times with the device-local `PodcastRefreshNetworkConcurrency` value set to `1` and `4`. Capture the exact value and the feed order in the report. The default is four workers; one is the required serial fallback. Do not infer a worker setting from completion order.

For each worker setting, run these phases separately:

1. Manual Refresh All with the app foregrounded and idle.
2. The same run while audio is playing and the Inbox or Library is scrolling.
3. The same run with a foreground/background transition during the run.
4. A failed or interrupted run followed by relaunch and retry.

Use a fixture-only install and anonymized titles. Do not reset a user's library to create a test case. Record whether UserState CloudKit mirroring was enabled; never treat local save or an empty retry queue as proof of CloudKit export.

## Instruments commands

List the connected device and templates before recording. The commands below write outside the repository.

```sh
export DEVICE_UDID='replace-with-physical-device-udid'
export REPORT_DIR="$TMPDIR/PodcastClient/438-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$REPORT_DIR"

xcrun xctrace list devices
xcrun xctrace list templates
```

Record signposts and Points of Interest for the full refresh window. `Logging` is the command-line template that contains the `Points of Interest` instrument; select the `os_signpost` and `Points of Interest` lanes when reviewing the trace.

```sh
xcrun xctrace record \
  --device "$DEVICE_UDID" \
  --template 'Logging' \
  --instrument 'Points of Interest' \
  --all-processes \
  --time-limit 15m \
  --output "$REPORT_DIR/refresh-poi.trace"
```

Record CPU attribution, allocations, and persistence separately when practical. Keep the same fixture phase and time window for matched before/after runs.

```sh
xcrun xctrace record --device "$DEVICE_UDID" --template 'Time Profiler' \
  --all-processes --time-limit 15m --output "$REPORT_DIR/time-profiler.trace"

xcrun xctrace record --device "$DEVICE_UDID" --template 'Allocations' \
  --all-processes --time-limit 15m --output "$REPORT_DIR/allocations.trace"

xcrun xctrace record --device "$DEVICE_UDID" --template 'Data Persistence' \
  --all-processes --time-limit 15m --output "$REPORT_DIR/data-persistence.trace"
```

Use the app's Points of Interest trace to measure the existing refresh stages: full refresh, HEAD preflight, endpoint resolution, GET/XML parse, feed-store commit, per-feed completion, writer acquire/release/cancel, and post-commit work. Use Data Persistence/Core Data and SQL views for fetch/fault/save activity; do not treat a process-wide CPU or RSS sample as feed-attributed without a matching timeline.

Export a table of contents and preserve the raw traces privately. Attach only sanitized screenshots or redacted exports to the report.

```sh
for trace in "$REPORT_DIR"/*.trace; do
  xcrun xctrace export "$trace" --toc \
    --output "${trace%.trace}-toc.xml"
done
```

If a template, instrument, or export is unavailable on the installed Xcode/OS, record that limitation and use the closest available Instruments view. Do not silently substitute a simulator run for a physical-device measurement.

## Measurements and report template

Copy this block once per matched fixture/worker run. Use a local report ID rather than a feed URL, account ID, episode title, or listening-history value.

```text
Report ID: 438-<local-id>
Run role: before | after
App revision: <git SHA or TestFlight build>
Device: <model>
iOS: <version/build>
Xcode/Instruments: <version>
Store mode: UserState CloudKit on/off; SharedDatabase local
Fixture command: <exact command, with no secrets>
Fixture set: S10 | S50 | S100 | large-1k | large-5k
Worker setting: 1 | 4
Order seed: <redacted local seed>
Network conditions: <Wi-Fi/cellular, reachability, throttling if used>

Stage / metric                         p50       p95       units       source
Full Refresh All                       <value>   <value>   seconds     POI
HEAD preflight                         <value>   <value>   milliseconds POI
GET + XML parse                        <value>   <value>   milliseconds POI
Feed-store commit                      <value>   <value>   milliseconds POI
Writer wait                            <value>   <value>   milliseconds POI
Writer hold                            <value>   <value>   milliseconds POI
Process CPU                            <value>   <value>   seconds     Time Profiler/POI
Peak resident footprint                <value>   <value>   MiB         Allocations/POI
Post-completion footprint              <value>   <value>   MiB         Allocations/POI
SQL/fault/fetch/save counts            <value>   <value>   count       Data Persistence

Same-feed early/late cohort comparison: <result>
Failure/cancellation/relaunch result: <result>
CloudKit export/import observation: <result or not run>
UI/playback/background observation: <result or not run>
Outliers and measured cause: <result>
```

Privacy review before sharing:

- [ ] No raw feed URLs, query tokens, credentials, headers, account identifiers, episode titles, transcript text, or listening history.
- [ ] Hashed feed IDs are retained only when needed to compare the same fixture feed; fixture names and numbers are sufficient for most reports.
- [ ] Screenshots show only fixture data and redact device/account identifiers where unnecessary.
- [ ] Raw `.trace` bundles remain private because they can contain process and device details.

## Release-gate criteria

The #438 gate is complete only when all applicable rows have recorded evidence from a signed physical-iPhone run and the evidence is linked to #402. A blank, skipped, or simulator-only row remains outstanding.

### Performance and attribution

- [ ] S10, S50, and S100 are each repeated five times at one and four workers with the specified mixed profiles.
- [ ] A 1k/5k large-catalog run and a shuffled-order run are recorded.
- [ ] The same feed is compared in early and late completion cohorts; the report distinguishes slow hosts, HTTP 429/Retry-After, HEAD fallback, parser/import work, writer wait/hold, and UI/post-commit work.
- [ ] Before/after p50 and p95 values, total wall time, CPU, peak/post-completion RSS, writer wait/hold, and SQL/fault/save activity are present. Any regression is explained or blocks release.
- [ ] Post-completion memory is bounded or reaches a documented stable plateau; no steadily increasing identical-feed SQL/commit cost is left unexplained.

### Integrity and recovery

- [ ] No duplicate or missing episode identities after repeat refresh, paged continuation, failure, cancellation, and relaunch.
- [ ] Playback position, archive/inbox state, queue/playlist references, and last-successful timestamps survive the run and relaunch.
- [ ] A paged feed's first-page seed is visible before later pages finish; smart playlists, Spotlight, notifications, and automatic download policy receive the committed result.
- [ ] Cancellation releases queued writer/network work, removes temporary spools, preserves resumable retry state, and does not make an incomplete import look successful.
- [ ] A relaunch after failure or termination resumes from a durable checkpoint without whole-library replacement or stale tombstone inference.

### Device behavior

- [ ] CloudKit-enabled representative runs show no unexplained export backlog or stale UserState after recovery; local acknowledgment is not used as export evidence.
- [ ] Playback remains controllable, scrolling has no measured main-thread stall, and foreground/background transition does not lose or duplicate work.
- [ ] The result is attached to the matching #402 checklist item with device, OS, build, fixture, and redacted diagnostics.

## Transfer checklist to #402

1. Attach the sanitized report and list the exact app revision, device/OS, fixture command, worker setting, and run count.
2. Link the report to the relevant #402 validation row; keep #429 performance conclusions and #402 device evidence cross-referenced.
3. Mark only checks that were actually observed. Keep physical-device, CloudKit, and two-device checks open when they were not run.
4. Record remaining outliers, unavailable Instruments views, failed or skipped fixture profiles, and any follow-up issue needed for a reproducible defect.
5. Confirm that no GitHub issue was edited by the validation runner. Issue updates are a maintainer integration step after evidence review.

Current status for this checkout: the framework and automated checks are prepared; no physical iPhone, CloudKit, or Instruments result is claimed here.
