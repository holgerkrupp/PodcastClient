# Optional audio analysis write diagnostics

Rolling ad-detection transcription is compiled into the DEBUG player path. It
creates a temporary CAF snippet before SpeechTranscriber runs. Textual and
semantic detectors share an in-flight transcript request keyed to the same
media revision and window. Successful lines are cached in memory for five
minutes (up to 32 windows), and failed or cancelled writes remove their partial
CAF file. A snippet is capped at five minutes and is streamed as 16 kHz mono,
16-bit PCM, limiting its audio payload to about 9.6 MB even when the source is
stereo float audio at a higher sample rate.
At first use in a process, cleanup removes only regular `AdDetection-*.caf`
files older than 24 hours from the app temporary directory.

Unified logging records snippet duration and byte count, cleanup count, and
whether a snippet write was aborted. It does not record media paths, episode
titles, transcript text, or feed URLs. The measurements describe this optional
feature only; SQLite WAL, CloudKit mirroring, AVFoundation playback, and
publisher-transcript synchronization remain separate write sources.

The 2026-10-26 build-700 `bug_type 145` report remains unattributed: its short
end-of-window AVFAudio stack does not explain the preceding 24-minute dirty
memory total. The matching app-image dSYM was not present in the available
local archives. Physical-device A/B measurements are still required before
assigning the report to this DEBUG-only path or declaring the write budget
verified.
