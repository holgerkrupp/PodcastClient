# Store Split Migration Plan

This app is being migrated from one CloudKit-backed SwiftData store to a split-store architecture.

## Goal

- Reduce CloudKit sync volume.
- Keep user-owned state synchronized across devices.
- Keep rebuildable feed/cache data local-only.
- Avoid cross-store SwiftData relationships.
- Use stable logical identifiers instead of `PersistentIdentifier`.

## Current direction

### Synced store

- `SubscriptionSync`
- `EpisodeStateSync`
- `QueueEntrySync`
- `BookmarkSync`
- `ListeningSummarySync`

### Local-only store

- `Podcast`
- `PodcastMetaData`
- `Episode`
- `EpisodeMetaData`
- `PodcastSettings`
- `Playlist`
- `PlaylistEntry`
- `Marker`
- `TranscriptLineAndTime`
- `TranscriptionRecord`
- `PlaySession`
- `RateSegment`
- `ListeningStat`
- `PlaySessionSummary`

## Listening history rule

- Detailed playback logs remain local-only.
- Only compact summary rows are synchronized.
- A summary row is scoped by:
  - `feedURL`
  - `periodKind`
  - `periodStart`
  - `sourceDeviceID`
- Devices write their own summary row and merge at read time.
- UI should aggregate all rows with the same `feedURL + periodKind + periodStart` and sum counters.
- This avoids duplicate user-visible history while keeping CloudKit payloads small.

## Merge behavior

- Upserts must be keyed by stable logical IDs.
- If two records conflict, prefer the newer `updatedAt`.
- Partial sync is expected.
- Migration must be repeatable and safe to run multiple times.

## Rollout stages

1. Stage 1
   - Add the new models.
   - Keep the old store readable.
   - Write new synced state alongside legacy reads.
   - Do not delete the old store.
2. Stage 2
   - Switch app reads to the split stores.
   - Keep legacy fallback reads only as a safety net.
3. Stage 3
   - Remove legacy fallbacks after the rollout is stable.
   - Consider old-store cleanup only after a later release.

## Risks

- Duplicate summary rows from multiple devices.
  - Prevented by device-scoped summary IDs and aggregation at read time.
- Missing data during partial sync.
  - Mitigated by merge-on-read and fallback to legacy data during transition.
- Cross-store relationship breakage.
  - Avoided by using logical identifiers only.
