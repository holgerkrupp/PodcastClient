# Automatic transcription candidate scans

Automatic on-device transcription is optional background work. Candidate
selection now enters through the process-wide CPU admission budget and emits a
privacy-safe unified-log summary with scan count, candidate count, and elapsed
time. The summary contains no episode names, media URLs, or feed identifiers.

The scan is bounded to 200 episodes per playlist and uses newest-first indexed
fetches for smart-playlist candidates. Per-podcast transcript-publication
checks inspect at most 64 recent episodes. If the sample fills without finding
a publisher transcript, publication status is treated as unknown and optional
on-device analysis is skipped for that podcast. This trades some discovery
coverage for a firm bound on SwiftData materialization and CPU; episodes beyond
that sample are not automatically analyzed by this selection pass.

The build-691 report's app-image UUID was not present in local archives, so its
exact hot function remains unknown. The bounded candidate query is a source
audit finding and a mitigation, not a claim that this code produced the
reported stack. Physical-device background runs with the matching dSYM remain
necessary to verify the watchdog acceptance criteria.

## Workload rules

These came from a source audit on 2026-11-01. The reductions below are derived
from the code, not measured on a device.

- Exactly one language-model pass per episode. `GeneratedChapterWorkRegistry`
  joins the automatic and the requested pass, and an identical result is not
  rewritten.
- Chapter generation runs inside the transcription job. It holds the analyzer
  turn, so the model and the next analyzer never overlap, and it ends with the
  job. CloudKit export and playback stop analysis but not this stage; a cancelled
  background pass stops both.
- Prompts merge transcript cues into blocks of 6-20 seconds, so ad boundaries from
  the model have that granularity. Token counts come from one calibrated sample
  rather than one call per line, with the context-window split as the backstop.
- Shownotes only reach the model when they contain at least two timestamps and
  automatic chapter generation is on.
- Throttled runs save finished segments to `Caches/TranscriptionCheckpoints` at
  most once a minute and on cancellation, then resume at the last saved position.
  SpeechAnalyzer was checked on macOS: buffers fed from an offset report absolute
  times. A deferred episode can be retried after ten minutes.
- Automatic analysis does not start in Low Power Mode or under serious thermal
  pressure, and it pauses between chunks while under thermal or memory pressure.
  A sweep that found nothing is not repeated for 15 minutes unless the permission
  to use the analyzer changed.
- Transcript rows are saved in batches of 500, and publisher-sync snippets are
  written as 16 kHz mono 16-bit (about 224 KB instead of up to 2.5 MB).

- The throttle measures the analyzer. Each 15-second chunk gets a cycle of 5 to
  18 seconds with a 25% busy target. The busy time is scaled from the audio the
  analyzer has reported, because the end of a chunk can wait for the next one.
- Buffer times count frames fed to the analyzer, not the source file position.
  Resampled buffers vary in length, and a file-based time made the analyzer fail
  with SFSpeechErrorDomain 17 ("timestamp overlaps or precedes prior audio input").
- A chapter pass stopped by a model rate limit, busy model, missing assets or a
  cancelled window goes into `GeneratedChapterRetryQueue`. It retries with backoff
  from 30 minutes, gives up after five failures, and cancellations cost no attempt.
  Retries run after a background pass and an idle foreground sweep, one at a time
  and never alongside an analyzer. A pass the user cancels is not retried. Automatic
  triggers skip episodes that already have generated chapters.

## Results

macOS 27 on Apple Silicon, using the app's `AITranscripts` with the real analyzer
and a 195-second spoken file:

| Check | Result |
| --- | --- |
| Throttled run before the timestamp fix | Failed with error 17 at the 30-second chunk |
| Full throttled run | 68 s (the old fixed pause would take at least 216 s), 272 segments |
| Estimated busy time per chunk | 0.3-0.5 s, so the 5-second cycle applied |
| Cancel after 15 s, then resume | Resumed at 38.5 s, finished in 53 s, 272 segments |
| Resumed against full transcript | Same word count, ordered times, checkpoint removed |

No physical iPhone was measured. Check `transcription_finished` and
`average_cycle_seconds` in the `TranscriptionIO` log and the CPU report there. If
the background monitor reacts, lower `targetDutyCycle` or raise
`minimumCycleSeconds` in `AITranscripts.Throttle.backgroundFriendly`.
