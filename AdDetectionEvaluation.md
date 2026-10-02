# Advertisement detection evaluation

The detector consumes compact, synthetic fixtures rather than complete third-party episodes. A fixture records an episode identity, expected advertisement ranges, and the signal observations produced for those ranges. Test cases cover produced commercials, host reads, intros/outros, cross-promotion, membership messages, editorial product discussions, news/business language, multiple languages, and missing transcript/chapter data.

The evaluation reports segment precision and recall, boundary error, false-positive duration, detection lead time, and the cost of each provider. The quality gate for experimental automatic skipping is a precision target of 0.98, recall of 0.80, and median boundary error below 3 seconds on the annotated fixture set. Automatic skipping stays disabled by default until those measurements are available on the target device families.

Diagnostics retain only timestamped source, confidence, and short explanations. Raw audio, transcript windows, and fingerprints are not persisted by the diagnostics sink. Fingerprints are bounded, expire, and are keyed by a local podcast identity rather than episode timestamps.

