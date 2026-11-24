# Listening statistics performance for #473

`ListeningStatisticsAggregationActor` owns immutable value snapshots outside
the main actor. Period changes rebucket the cached values instead of fetching
SwiftData again, and a listening-history change notification invalidates the
cache when a session is published, migrated, or synchronized.

The aggregation tests include a 10,000-session fixture and verify stable
identity deduplication, calendar-boundary attribution, DST handling, and
cross-device records. The initial load intentionally remains a complete
history read because all-time totals and legacy baselines must not be
invented or truncated; it runs in the aggregation actor rather than on the
main actor. If profiling on supported hardware shows this load is material,
the next safe optimization is a persisted value snapshot or date-bounded
loads for non-all-time views.

No integrated simulator measurement was available in this checkout because
the full target build is currently blocked by the unresolved `ESADesignKit`
widget dependency. Physical Instruments validation remains appropriate for
large libraries and cross-device sync.
