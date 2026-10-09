# Advertisement Detection Release Gate

This gate is required before enabling PCM advertisement detection broadly. The
application default remains opt-in. The automated stream-provider test verifies
single-pipeline consumption and cancellation; it does not replace profiling on
physical devices.

## Device matrix

Run a Release build on the oldest supported iPhone and a current-generation
iPhone. Profile local MP3 and M4A files with 30-minute, 1-hour, and 3-hour
durations. Repeat with incomplete or incorrect duration metadata. Run once with
the app active and once during background audio; include Low Power Mode and
screen-locked runs.

## Measurements to capture

- Peak `phys_footprint` and the `ad_detection_pcm_finished` breadcrumb counters.
- Maximum simultaneously retained decoded samples (must stay within two
  configured windows per combined PCM pipeline).
- CPU over every 60-second interval, Energy Log, decoded frames, read count,
  cache download bytes, and time from cancellation request to task exit.
- Continuous playback, user-enabled automatic skip behavior, and detection
  timestamps compared with the deterministic fixture baseline.

Attach Instruments traces and device/OS/build identifiers to issue #290. Any
increase in fixture boundary error, playback interruption, analysis outside
the active foreground/local-file policy, or unbounded memory growth blocks
release. This repository does not contain real-device measurements or approved
numeric CPU/energy budgets; record agreed limits with the attached run before
marking the hardware gate complete.

## Reproducible simulator checks

Run `AdDetectionTests` and `StoreSplitPlaylistProjectionTests` in the Release
configuration after selecting an iOS Simulator destination. The checks cover
provider pipeline count, policy deferral, sorted immutable snapshots, and
multi-context playlist writes. Simulator results do not satisfy the physical
device portion of this release gate.
