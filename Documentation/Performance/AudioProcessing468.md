# Audio Processing Benchmark for #468

## Scope

The existing `AudioPlaybackProcessor`, `SpokenWordEnhancer`, `AudioSilenceGapDetector`, and `EqualizerDSP` were audited before the settings work. No working DSP implementation was replaced. The shared Audio & Speed settings surface exposes only controls backed by the current processor: playback speed, pause reduction, voice enhancement, and EQ presets. Normalize is intentionally not exposed because there is no normalize setting or processor stage in this checkout.

## Reproducible benchmark

The following command was run on the development Mac (Apple silicon, macOS 27.2, Swift 6.4.2) using the production `SpokenWordEnhancer` and `AudioSilenceGapDetector` source files:

```sh
xcrun swiftc -O -whole-module-optimization \
  -o /tmp/PodcastClientAgentD-bench/audio-benchmark \
  /tmp/PodcastClientAgentDBenchmark.swift \
  Raul/Features/Player/Services/SpokenWordEnhancer.swift \
  Raul/Features/Player/Services/AudioSilenceGapDetector.swift
/usr/bin/time -l /tmp/PodcastClientAgentD-bench/audio-benchmark
```

The fixture processes a 30-second, 48 kHz, two-channel synthetic speech-tone signal (1,440,000 samples), runs voice enhancement and silence detection for every sample, and prints a checksum and final state to make accidental dead-code elimination visible.

| Run | Samples | Wall time | User CPU | Peak resident set | Output invariant |
|---|---:|---:|---:|---:|---|
| Development Mac, optimized Swift | 1,440,000 | 0.17 s | 0.02 s | 5.7 MB | checksum −3.976495; final gain 3.9525006; detector not reducing |

This is a repeatable algorithmic smoke benchmark, not a release performance budget. It does not measure AVAudioEngine/AVPlayer tap scheduling, device battery, thermal behavior, route changes, streaming, downloaded-media decode, or full EQ throughput. Those require Instruments on physical iPhone/iPad/Mac hardware. The existing deterministic tests continue to cover EQ flat bypass, tonal change, headroom, silence thresholds, voice enhancement, and limiter behavior.

## Settings and persistence notes

`AudioSpeedSettingsSnapshot` is value-based and copies only the five processing fields. Resetting a podcast profile therefore cannot alter queue routing, auto-download policy, retention, chapter rules, or notifications. Existing `PodcastSettings` records and stable podcast/feed identities remain unchanged, so the change does not require a SwiftData migration. Settings writes continue through the existing `PodcastSettingsView` commit and portable UserState publication path.

## Device-only validation remaining

Run Instruments with audio playback on a supported iPhone, iPhone Duo, iPad, and Mac when available. Validate CPU, memory, audio glitches, interruptions, AirPlay/route changes, streaming versus downloaded audio, playback-rate combinations, EQ presets, pause reduction, and large-library settings opening. No physical-device measurements were available in this environment.
