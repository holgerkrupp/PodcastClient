# Automatic transcription performance and release gates

## Unified transcript release gate (#493)

Status (2026-11-24): repository-side validation procedure for
[#493](https://github.com/holgerkrupp/PodcastClient/issues/493), part of
[#486](https://github.com/holgerkrupp/PodcastClient/issues/486). The matrices below
are acceptance checks, not recorded passes or proof that all integration work
has shipped. Physical iOS 26 and iOS 27 results are still required before closing
#493 or judging the cost of automatic activation. Historical measurements later
in this document describe different workloads and do not satisfy this gate.

### Correctness and fallback matrix

Use synthetic publisher text and locally generated speech with known media
times. Keep the original decoded publisher wording as the comparison fixture;
timing improvements must not substitute recognition output for that wording.
For each applicable row, check the inline card, full Transcript view, follow
playback, word/line highlighting, tap-to-seek, search, selection/copy, and clip
preview/export. Check both while enrichment runs and after cancellation/relaunch.
Record unsupported or unimplemented paths as such rather than passing them.

| Fixture / condition | Required observable result | Existing local evidence to run; remaining integration check |
| --- | --- | --- |
| Publisher VTT with inline word timing; SRT or VTT with cue timing | Preserve text, speakers, Unicode ranges and available native timing through import and reopen. Highlight actual timed ranges only; ordinary SRT cues do not imply word timing. | `TranscriptDecoderTests`, `TranscriptSegmentBuilderTests`; verify import from Episode Detail and playback in the app. |
| Publisher transcript with cue timing only | Full text is immediately readable. Enrichment adds verified word timing where available; elsewhere keep usable cue timing without inventing word intervals. | `TranscriptPresentationSnapshotTests`, `PublisherTranscriptWordMatcherTests`; verify automatic scheduling and view adoption. |
| One inserted sponsor / multiple offset changes | Use piecewise timing, stop highlighting in confirmed gaps, and seek to matched speech. Never stretch a word/caption across an inserted ad or caption unverified speech. | `TranscriptSynchronizationTests`, `PublisherTranscriptWordMatcherTests`, `ClipCaptionTimelineTests`; play fixtures with one and two insertions. |
| Publisher typo, punctuation/case differences, emoji and combining marks; repeated phrases | Preserve publisher spelling and punctuation in display, search/copy and exported captions. Apply UTF-16 ranges only to the matching revision; leave uncertain or repeated words unmapped. | `PublisherTranscriptWordMatcherTests`, `TranscriptPresentationSnapshotTests`; verify selection/copy and clip wording in the app. |
| Stored generated transcript only | Use the complete generated document and its real timing. A partial live result must not replace it. | `TranscriptPresentationSnapshotTests`, `TranscriptSearchServiceTests`; verify seek/copy and export. |
| Partial live transcript only | Show partial coverage honestly; do not imply a complete transcript or fill gaps. Preserve finalized coverage across relaunch; tentative recognition is not durable coverage. | `LiveTranscriptStateTests`, `TranscriptPresentationSnapshotTests`; verify partial search, view and clip behavior. |
| Publisher text arrives while full/live recognition is running | Publisher text becomes canonical and remains canonical after the older job completes. Search, copy and captions must agree with the visible document. | Snapshot precedence is covered locally; exercise the asynchronous write/completion race in the app. |
| Unsupported language or publisher/Speech language mismatch | Keep readable text and existing timing; skip enrichment safely without a repeated job loop. Current word matcher supports English and German, independently of Speech's language availability. | `PublisherTranscriptWordMatcherTests`; verify runtime eligibility and recovery. |
| Speech model missing, download fails, permission denied or offline | Playback and publisher text remain usable. Retain earlier valid timing, fall back to cues where possible, and keep optional failure non-blocking. | Inject/model-test unavailable assets without a personal account; runtime model download, permissions and recovery need app/device checks. |
| Remote-only media | Publisher or saved text remains available without forcing a whole-media download for optional enrichment. Where downloaded audio is required, skip enrichment and preserve the baseline workflow. | App check with synthetic localhost media; the stream probe below measures delivery only, not a shipped streamed-recognition path. |
| Episode identity, downloaded media fingerprint or publisher revision changes | Reject all mismatched derived timing, including after relaunch. Keep canonical text intact and rebuild timing only for the current identities. | `TranscriptPresentationSnapshotTests`, `PublisherTranscriptTimingOverlayTests`, `TranscriptSynchronizationTests`; verify replacement while a job is in flight. |
| Timing cache absent, evicted or unwritable; persistence/full-storage failure | Reading text and playing audio remain possible. Existing durable coverage survives failed writes; disposable timing can be reconstructed without touching the library. | `PublisherTranscriptTimingOverlayTests`, `LiveTranscriptStateTests` cover selected missing-file/write failures; real full-storage and recovery remain device checks. |
| Enrichment cancelled, fails or is interrupted by background/lock | Publisher text stays visible, playback continues and valid line/cue timing remains available. No unsolicited modal alert or startup overlay. Relaunch must not erase text or reuse stale evidence. | App/device check at recognition, match and persistence boundaries; unit cancellation is not lifecycle evidence. |
| Clip export with partial/no word coverage or failed enrichment | Export remains possible using trustworthy coarser timing where available; omit unsupported caption intervals without blocking the underlying audio/video export. Never fabricate timing or replace publisher wording with Speech output. | `ClipCaptionTimelineTests` covers timeline identity, gaps and clipping; verify the full exporter, caption fallback and resulting playable file separately. |

### Resource and lifecycle matrix (physical devices required)

Run on at least one physical iOS 26 device and one physical iOS 27 device; record
the exact model, OS build, app build/commit and configuration. Use the same local
fixture and initial cache/model state for paired runs. Separate model installation
from steady-state recognition. Compare playback with the transcript UI hidden,
visible with existing timing, and visible during active enrichment. Also leave
the UI hidden after starting enrichment to establish its actual resource policy.
Use Instruments Time Profiler, Allocations and the available energy instruments,
plus privacy-safe aggregate queue/cache diagnostics. A simulator CPU percentage
or Mac recognition result cannot establish iPhone power or thermal behavior.

| Workload / transition | Record | Acceptance check |
| --- | --- | --- |
| 30-minute and 2-hour audio at 1× and 2×; include 5,000+ transcript lines | CPU in each UI/enrichment state; memory before, peak and after listening; energy/battery trend; thermal state and ambient/charging conditions | No crash, watchdog, sustained unbounded memory growth or runaway work. Record the measured incremental cost before deciding automatic activation/settings. |
| Repeated forward/back seeks, including across ad gaps and previously covered ranges | Recognition starts, cancellations, simultaneous Speech jobs, queue wait, cache reuse and highlight recovery | No duplicate full/live/enrichment recognition; obsolete windows stop and bounded work resumes at the new position. Coverage reuse avoids repeated recognition of the same valid range. |
| Transcript hidden/visible and repeated tab switches with 5,000+ lines | First usable tab time, subsequent switch latency, main-thread stacks and allocation activity during playback ticks | #484 remains immediate; #485 does not regress to O(n²) scans. No transcript-wide rebuild/materialization on each playback tick. |
| Background/foreground, screen lock/unlock, Control Center and supported CarPlay transitions | Scene transition duration, playback continuity, task cancellation/resume and CPU after leaving foreground | No scene-update or background CPU watchdog; no sustained orphan Speech job. Preserve text and valid coverage. Mark unavailable routes as untested. |
| Long listening, repeated seeks, relaunch and cache eviction | Overlay file count/bytes before and after, in-memory retention, cold/warm cache behavior | Cache growth and reads stay bounded; eviction affects only derived timing. Verify the current configured bounds rather than assuming a file-count limit also proves a byte limit. |
| Low Power Mode, serious thermal pressure, memory pressure, offline and storage failure | Admission/pause decisions, retries, pending work and recovery outcome | Playback/navigation remain usable, retries stay bounded, and optional analysis yields resources. No repeated warning or modal interruption. |

Use a full 30-minute and 2-hour listening pass for the duration checks; short
samples can diagnose problems but do not replace long-session memory/cache
evidence. Repeat the same seek/transition sequence in paired runs. The current
overlay cache defaults to 512 chunks of 128 tokens; this is a source-level bound,
not a measured memory, disk-byte or energy result. Record actual bytes and peaks.
Do not invent numeric CPU, battery or latency pass thresholds from simulator
results: attach paired hardware measurements and explain any material regression.
No P0/P1 crash/performance regression is acceptable.

### Local checks without private data

The existing XCTest fixtures use synthetic text and isolated temporary/in-memory
stores. They can test timing arithmetic, canonical selection, Unicode ranges,
identity invalidation, coverage and bounded cache behavior without a personal
library, feeds, credentials or CloudKit account. These are useful prerequisites;
they do not exercise the complete runtime scheduling, UI or physical-device gate.
No additional wrapper test is needed just to invoke these existing assertions.

From the repository root, list installed destinations and run the focused suites
on an available simulator. The example destination was available on 2026-11-24;
substitute one actually installed. DerivedData, logs and results stay outside
the repository and are removed on exit. Review aggregate results before cleanup;
retain a sanitized copy outside the repository only when debugging requires it.

```sh
xcodebuild -version
xcrun simctl list devices available
```

```sh
(
  validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/PodcastClient-unified-gate.XXXXXX")" || exit 1
  trap 'rm -rf -- "$validation_dir"' EXIT
  xcodebuild test -project 'Up Next.xcodeproj' -scheme UpNext \
    -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2' \
    -derivedDataPath "$validation_dir/DerivedData" \
    -resultBundlePath "$validation_dir/TranscriptGate.xcresult" \
    -only-testing:UpNextTests/TranscriptDecoderTests \
    -only-testing:UpNextTests/TranscriptSegmentBuilderTests \
    -only-testing:UpNextTests/TranscriptPresentationSnapshotTests \
    -only-testing:UpNextTests/PublisherTranscriptWordMatcherTests \
    -only-testing:UpNextTests/PublisherTranscriptTimingOverlayTests \
    -only-testing:UpNextTests/TranscriptSynchronizationTests \
    -only-testing:UpNextTests/LiveTranscriptStateTests \
    -only-testing:UpNextTests/TranscriptSearchServiceTests \
    -only-testing:UpNextTests/ClipCaptionTimelineTests \
    > "$validation_dir/xcodebuild.log" 2>&1
  test_status=$?
  tail -n 80 "$validation_dir/xcodebuild.log"
  exit "$test_status"
)
```

`-only-testing` selects execution, but Xcode still compiles the test target.
An unrelated test compile failure is **blocked**, not a transcript test pass.
At this documentation review, `xcrun swiftc -frontend -parse
UpNextTests/ListeningStatisticsBenchmarkTests.swift` failed at line 47 with an
unterminated string/interpolation; no full XCTest run was made for this slice.
Fix that outside this documentation scope before collecting XCTest results.
Syntax parsing alone does not validate types, linkage or runtime behavior.

For UI smoke checks, use an isolated simulator with anonymized fixtures. Check
standard portrait and compact-height iPhone, iPhone Duo and regular-width/iPad;
review macOS separately where the workflow differs. Verify search/copy, caption
preview/export and the existing hero/transcript/pinned-control interaction at
rest and after scrolling. Include Dynamic Type/VoiceOver and the languages used
by the fixtures. A build or pure-model test does not prove these UI behaviors.
If the fixture cannot reach a runtime state, record it as untested rather than
using a personal library or an invented screenshot.

The optional `TranscriptSearchPerformanceTests` uses synthetic canonical stores
but is a separate, opt-in library-search benchmark (100k–1m rows); it does not
measure Transcript tab latency or playback tick work. The localhost stream
probe described below likewise cannot sign off recognition, Bluetooth, AirPlay,
CarPlay, lock-screen execution, thermal state or battery impact. Missing Speech
assets in the simulator are a fallback check, not a successful recognition run.

### Evidence and sign-off

Record each result as **pass**, **fail**, **blocked** or **not run**, with fixture
ID, commit plus any uncommitted changes, app/Xcode/OS build, device or simulator,
model/language/cache state, workload duration, expected/observed result and the
sanitized evidence location. Record baseline/enrichment metrics together. Use
synthetic titles/transcripts and aggregate counts; do not attach private media or
feed URLs, credentials, listening history, personal screenshots or raw logs from
a personal library. Review Instruments traces and result bundles before sharing.

| Evidence lane | Status at this repository-side review (2026-11-24) |
| --- | --- |
| Matrix and existing test/source coverage | Reviewed; instructions added here. This does not mark individual acceptance rows passed. |
| Focused XCTest execution | Not run for this slice; known test-target syntax blocker reproduced with the parser. |
| Integrated UI/export/lifecycle checks | Not run for this slice. |
| Physical iOS 26 / iOS 27 resource measurements | Not supplied by this slice; pending device evidence. |
| Automatic activation / setting decision | Pending paired physical measurements and correctness/fallback evidence. |

Link the completed evidence and remaining failures to
[#493](https://github.com/holgerkrupp/PodcastClient/issues/493) and
[#402](https://github.com/holgerkrupp/PodcastClient/issues/402). Closing the
repository-side documentation work alone must not close the physical-device
gate. Sign-off requires preserved baseline transcript UX, useful word enrichment,
bounded measured resource cost, an evidence-based setting decision, and no P0/P1
crash/performance regression.

## Live transcript input evaluation (2026-11-17)

The downloaded-audio live path uses a maximum seven-second local PCM window.
On iOS 26 it converts that bounded window with `AVAudioConverter` and sends
time-coded `AnalyzerInput`; on iOS 27 it uses `AnalyzerInputConverter` for the
same bounded buffers. Window timestamps start at zero and are translated to
episode time once. The `timeIndexedProgressiveTranscription` preset emits
tentative text for display; only final results enter saved coverage.

Apple's iOS 27 [AssetInputSequenceProvider](https://developer.apple.com/documentation/speech/assetinputsequenceprovider)
can read an asset track directly. Its published interface supplies a sequence
for the asset, rather than a bounded window with the seeking and cancellation
behavior needed here, so the local window path remains in use. The
[AnalyzerInputConverter](https://developer.apple.com/documentation/speech/analyzerinputconverter)
is evaluated only for decoded local PCM in this implementation.

Apple documents an iOS 27 mixed-output audio tap for unprotected HLS and a
sample-buffer output that can scan ahead in its [HLS update](https://developer.apple.com/streaming/Whats-new-HLS.pdf).
The existing Up Next processing tap is attached to a specific track and does
not currently export buffers or their timestamps to speech recognition. A
debug-only, fixed-capacity probe was exercised on the iOS 27.2 iPhone 18 Pro
simulator with synthetic speech served from a local HTTP fixture. Progressive
MP3 playback delivered 22.05 kHz PCM and media timestamps; a backward seek
was detected as a timestamp discontinuity. A deliberately throttled response
produced waiting states and playback resumed, with no buffer truncation in the
sample. The simulator had no installed English speech model, so recognition
latency and whether it can keep up could not be measured.

The separate unprotected HLS fixture played and reloaded a changing playlist
with a synthetic inserted segment, but its iOS 27 mixed-output tap delivered
no buffers or timestamps in this simulator run, including after a seek. This
does not establish behavior on hardware or other routes. Bluetooth, AirPlay,
real network stalls, and dynamic publisher ad variants remain unmeasured. No
streamed live-caption workflow is enabled: the probe only sees audio as it is
played, so any result from it would be delayed rather than ahead of playback.
Streamed episodes continue to use publisher or previously downloaded transcripts.

To repeat the simulator probe, run `python3 Scripts/stream-transcript-fixture.py`
on the Mac (requires `say` and `ffmpeg`), then run the `StreamAudioProbeTests`
test class on an iOS 27 simulator. The server creates anonymized synthetic
audio in a temporary directory and listens only on localhost. Stop it after
testing; without the fixture server, the network probes are skipped. The
probe does not establish Bluetooth or physical-device behavior.

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
