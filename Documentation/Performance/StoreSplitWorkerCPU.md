# Store split worker CPU attribution

`StoreSplitWorkCoordinator` records one privacy-safe completion entry for each
UserState reconcile. The entry includes the trigger, local and UserState store
names, start lifecycle state, end lifecycle state, elapsed time, process CPU
delta, cancellation state and outcome. The trigger is an internal reason such
as `cloud_import_foreground` or `manual`; it must not contain user or feed data.

`StoreSplitUserStateImporter` also records the podcast index fetch and fallback
episode feed scans with record counts, elapsed time, process CPU delta,
lifecycle state and cancellation. Compare those entries with the worker record
to distinguish a long reconcile from a specific expensive query or repeated
scan. These records measure the whole process, so concurrent work can
contribute to the CPU delta.

The build 741 incident report's app code image UUID is
`A6ED85DE-CD6B-346D-83A4-709248FF95AB`; the local Xcode archive set did not
contain a matching Up Next dSYM or incident report. The exact worker method and
query therefore remain unknown, and no physical-device before/after profile
was available in this checkout. Do not treat the worker instrumentation as
proof that reconciliation caused the incident or that the CPU threshold has
been fixed. Use a matching release dSYM and a populated physical iPhone to
correlate these records with Time Profiler and repeat the triggering workload
across the 60-second resource window.
