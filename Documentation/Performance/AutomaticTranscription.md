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
