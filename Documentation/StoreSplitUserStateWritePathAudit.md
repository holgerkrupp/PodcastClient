# Store Split — UserState Write-Path Audit

Audit date: 2026-09-27

This is the release-gate inventory for issue #44. User-owned state crosses the
store boundary through logical feed/episode/playlist IDs and is written to
`UserState.sqlite`. Feed-derived content and device-local diagnostics stay in
the durable local library graph or `PodcastCache.sqlite`; they are not written
to the CloudKit-backed schema.

| Mutation surface | Authoritative UserState rows | Local compatibility/cache work |
| --- | --- | --- |
| Subscribe / unsubscribe (`SubscriptionActor`, `PodcastModelActor`) | `SubscriptionSync`, including unsubscribe tombstones | Podcast/feed metadata stays local; feed refresh is projected to `PodcastCache.sqlite`. |
| Playback position, played/archive/skipped (`EpisodeActor`) | `EpisodeStateSync` keyed by `EpisodeStableIdentity.key` | Episode metadata, chapters, transcripts and artwork stay local/cache. |
| Up Next and custom playlists (`PlaylistModelActor`, `PlaylistLibrary`, playlist settings) | `PlaylistSync`, `PlaylistEntrySync`, `QueueEntrySync`, with stable order and tombstones | Runtime playlist graph is a compatibility projection only. |
| Bookmarks (`EpisodeActor`) | `BookmarkSync`, including delete tombstones | Bookmark UI joins by logical episode identity; no SwiftData relationship crosses stores. |
| Podcast playback preferences (`PodcastSettingsModelActor`, settings views) | `PodcastPreferenceSync`, keyed by normalized feed URL | Full `PodcastSettings` remains in the local library graph. |
| Completed listening sessions (`PlaySessionTrackerActor`) | `ListeningHistorySync` and required `ListeningBaselineSync` | Raw sessions, rate segments and derived totals remain local/cache. |
| Watch, widgets, intents, CarPlay and app-group snapshots | Route user mutations through the same writers or publish immutable snapshots to the main app | Extensions do not register feed-derived models in `UserState.sqlite`. |
| Upgrade/reconciliation (`StoreSplitUserStateImporter`) | Explicit migration/import source writes the same UserState rows with newest-wins timestamps | Its legacy container is an upgrade source, not a normal-runtime read fallback. |

## Invariants

- Every synchronized row has a stable logical ID: normalized feed key,
  `EpisodeStableIdentity.key`, playlist sync ID, queue entry ID, or bookmark ID.
- Timestamps and tombstones are retained in UserState; a delayed CloudKit row
  cannot replace newer local state.
- `PersistentIdentifier` is used only inside one SwiftData context. It is never
  serialized into a UserState row or used as a cross-store join key.
- Feed refresh, parser extensions, publisher/AI transcripts, chapters, artwork,
  downloads, search indexes, raw sessions and diagnostics are excluded from the
  UserState schema.
- During the migration window, the local library may receive the minimum
  compatibility projection required to keep existing screens populated. That
  projection is not the synchronized authority.

## Regression coverage

The schema allow-list and feed-derived exclusion are enforced by
`StoreSplitSyncedSchemaAuditTests`. Stable logical identity and mutation
semantics are covered by the Store Split writer, migration, playlist, bookmark,
episode-state and listening-history test suites. The AI/cache migration tests
also prove that a cache miss is repaired by projecting into `PodcastCache` and
does not materialize generated content back into `SharedDatabase.sqlite`.
