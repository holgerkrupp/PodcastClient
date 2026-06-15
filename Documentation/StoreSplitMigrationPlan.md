# SwiftData Store Split Migration Plan

## Executive decision

Do not change `SharedDatabase.sqlite` in place.

The production store currently contains the complete object graph and uses
`cloudKitDatabase: .automatic`. The first store-split release should therefore
open three independent containers:

1. `legacyContainer`: the existing `SharedDatabase.sqlite`, unchanged and
   CloudKit-backed.
2. `syncContainer`: a new `UserState.sqlite`, CloudKit-backed, containing only
   relationship-free user state.
3. `cacheContainer`: a new `PodcastCache.sqlite`, local-only, containing
   rebuildable feed, episode, chapter, transcript, artwork-reference, and
   download metadata.

The legacy container remains readable throughout the transition. It must not
be deleted, renamed, moved, or silently converted to local-only storage in the
first rollout.

## Current production architecture

`ModelContainerManager.makeContainer()` creates one container at the App Group
URL:

`group.de.holgerkrupp.PodcastClient/SharedDatabase.sqlite`

That container uses CloudKit automatic sync and registers:

- `Podcast`
- `PodcastMetaData`
- `Episode`
- `EpisodeMetaData`
- `Playlist`
- `PlaylistEntry`
- `Marker`
- `Bookmark`
- `RateSegment`
- `PlaySession`
- `ListeningStat`
- `PlaySessionSummary`
- `TranscriptionRecord`

Because the registered graph has relationships to additional model types,
SwiftData also persists related models such as `PodcastSettings` and
`TranscriptLineAndTime`. In practice, all feed data, parsed content, user state,
statistics, and large transcript/chapter data are in the CloudKit-backed graph.

`StoreSplitSyncModels.swift`, `PodcastIdentity.swift`,
`StoreSplitMergePolicy.swift`, and diagnostics/tests are currently foundation
code only. The new sync models are not registered by
`ModelContainerManager`, and no migration or dual-write service is wired in.

## Existing model classification

### Rebuildable or device-local

Move to `PodcastCache.sqlite`:

- `Podcast`: feed title, description, author, artwork URL, funding, social,
  people, alternative feeds, namespace tags, and last build date.
- Feed-refresh fields from `PodcastMetaData`: last refresh, feed update checks,
  and feed failure diagnostics.
- `Episode`: RSS metadata, show notes/content, media URL/type/size, duration,
  publication date, artwork URL, external files, funding/social/people, and
  namespace tags.
- Feed/extracted `Marker` values, chapter images, chapter progress, and
  `shouldPlay` when it is derived from local skip processing.
- Publisher-provided `TranscriptLineAndTime` data and local transcription job
  history in `TranscriptionRecord`.
- Download availability and file references. `DownloadItem` is already
  transient/non-SwiftData; downloaded files are in caches.
- Raw `PlaySession`, `RateSegment`, and hourly `ListeningStat` after summaries
  needed for cross-device statistics have been produced.
- Feed refresh history, search/index data, and widget artwork thumbnails.

### User-owned synchronized state

Move to `UserState.sqlite`:

- Subscription membership and subscription date.
- Episode playback position, maximum position, played/history state, archive
  state, completion date, first/last played date, and skipped state.
- Default queue and every custom manual playlist. The current requested
  `QueueEntrySync` alone is insufficient because the live app supports
  user-created playlists.
- Playlist name, symbol, visibility, order, and smart-playlist definition.
- User bookmarks. Bookmark image data should not sync.
- Global and per-podcast playback/display preferences that users expect on
  another device.
- Compact listening-history events and device-attributed summaries. Raw
  session relationships and rate segments remain outside the new synced store.
- AI-generated transcripts, stored as a small episode manifest plus bounded
  JSON text chunks.
- AI-generated chapter sets without chapter artwork, progress, or skip state.

Favorites are not part of the current product or legacy model. Do not add an
`isFavorite` field to the new schema and do not infer favorites from bookmarks,
playlists, archive state, or history.

### Device-local settings

Keep device-local unless product behavior explicitly says otherwise:

- Downloaded status and cache retention execution state.
- Network-specific auto-download coordination.
- On-device transcription availability and work queue.
- Voice identifiers or hardware-specific processing capability.
- Background refresh timestamps and failure diagnostics.

The existing `PodcastSettings` combines portable preferences with device-local
policy. It needs field-by-field mapping; copying the whole object as a blob
would retain accidental coupling and make CloudKit schema evolution harder.

## Relationships that prevent a direct split

The legacy graph has these cross-boundary relationships:

- `Podcast.episodes`
- `Podcast.metaData`
- `Podcast.settings`
- `Episode.podcast`
- `Episode.metaData`
- `Episode.playlist`
- `Episode.bookmarks`
- `Playlist.items`
- `PlaylistEntry.episode`
- `Bookmark.bookmarkEpisode`
- `Episode.playSessions`

No relationship can cross SwiftData containers. The new models must therefore
contain scalar logical keys only. Local cache objects must not reference sync
objects, and sync objects must not reference cache objects.

The UI should resolve state by stable keys and expose composed value snapshots,
not attach `EpisodeStateSync` to `Episode`.

## Stable identity

### Feed identity

Use a normalized feed URL string:

- trim whitespace;
- remove fragments;
- lowercase scheme and host;
- remove default ports;
- preserve path and query because they may identify a distinct feed.

Feed redirects are a separate alias problem. Store old and new normalized feed
keys in a local `FeedAlias` cache record when a permanent redirect or explicit
feed switch is accepted. Do not silently rewrite every sync record during a
refresh.

### Episode identity

Use this ordered identity:

1. non-empty RSS GUID;
2. normalized playable enclosure URL;
3. normalized episode/link URL;
4. SHA-256 of normalized feed URL plus stable fallback metadata such as title
   and publication date.

Namespace the value (`guid:`, `enclosure:`, `link:`, `hash:`) and use a
collision-safe composite-key encoding. Do not use `PersistentIdentifier`
outside one container.

`EpisodeStableIdentity` is the shared implementation. All migration, playback,
queue, bookmark, widget, watch, and intent code must use the same function.

### Lookup

For a local episode:

1. compute `(feedURL, episodeID)`;
2. fetch `EpisodeStateSync` by its deterministic `id`;
3. overlay the returned value on local RSS metadata;
4. during transition, fall back to legacy `EpisodeMetaData`;
5. otherwise return empty state.

Avoid an `@Query` per episode row. Load state records in batches and build a
dictionary keyed by `EpisodeStableIdentity.key`.

## Proposed sync schema

All CloudKit-backed models must:

- have defaults or optional values for every property;
- avoid relationships;
- avoid SwiftData uniqueness constraints;
- avoid large `Data` values;
- include deterministic logical IDs and explicit `updatedAt`;
- include deletion state where absence could resurrect data after partial sync.

Core models:

- `SubscriptionSync`
  - `id`, `feedURL`, `isSubscribed`, `titleOverride`, `subscribedAt`,
    `unsubscribedAt`, `updatedAt`, `sourceDeviceID`.
- `EpisodeStateSync`
  - `id`, `feedURL`, `episodeID`, `playPosition`, `maxPlayPosition`, `duration`,
    `isPlayed`, `isArchived`, `wasSkipped`, `completedAt`,
    `lastPlayedAt`, `updatedAt`, `sourceDeviceID`.
- `PlaylistSync`
  - stable playlist UUID, title, symbol, kind/filter values, display order,
    deletion tombstone, and timestamps.
- `PlaylistEntrySync`
  - playlist ID plus episode identity, sort index, addition timestamp,
    deletion tombstone, and timestamps.
- `QueueEntrySync`
  - retained as the default queue compatibility model if a separate fast path
    is useful. It must also support tombstones.
- `BookmarkSync`
  - stable bookmark UUID, episode identity, time, title/note, timestamps, and
    deletion tombstone.
- `PodcastPreferenceSync`
  - global or feed-scoped portable preferences, represented as explicit scalar
    fields rather than one opaque archive.
- `ListeningSummarySync`
  - feed, period, source device, compact totals, and timestamp.
- `AITranscriptSync`
  - episode identity, revision/content hash, locale, generation timestamp,
    line count, and expected chunk count.
- `AITranscriptChunkSync`
  - transcript/revision identity, ordinal, bounded JSON payload, payload hash,
    and timestamp.
- `AIChapterSetSync`
  - episode identity, revision/content hash, compact JSON chapter boundaries,
    generation timestamp, and source device.

AI transcript revisions are content-addressed and chunked below 128 KiB so a
long transcript is not stored as one oversized CloudKit record. The manifest
is applied only after every chunk has arrived and both line count and SHA-256
hash validate. Partial CloudKit delivery therefore leaves the current local
transcript untouched.

Incoming AI transcripts must not replace publisher-provided transcripts. They
may populate an episode with no transcript or replace a previously applied or
locally generated AI revision when the incoming generation is newer. Incoming
AI chapters replace only `.ai` markers; Podcasting 2.0, Podlove, MP3, MP4, and
publisher chapter data remain intact.

The active playback playlist selection is deliberately absent from the sync
schema. `PlaylistPreferenceKeys.selectedPlaylistID` remains device-local so an
iPhone, iPad, and Mac may each select a different active playlist. Migration
must not copy that preference into `UserState.sqlite`, and incoming playlist
changes must not replace the local selection. If the locally selected playlist
is deleted remotely, resolve a local fallback and update only this device's
`UserDefaults`.

CloudKit may deliver duplicates because SwiftData uniqueness constraints are
not a synchronization primitive. Fetch by logical ID, choose the newest
`updatedAt`, merge monotonic fields where appropriate, and compact duplicates
later.

## Proposed local cache schema

Do not register the existing `Podcast`/`Episode` graph in both active stores.
Introduce cache-owned model names so the legacy graph can remain open:

- `CachedPodcast`
- `CachedPodcastRefreshState`
- `CachedEpisode`
- `CachedChapter`
- `CachedTranscriptLine`
- `CachedTranscriptionRecord`
- `CachedDownloadRecord`
- `CachedFeedExtensionElement`
- `FeedAlias`

Relationships inside the local cache are acceptable. None may target a sync or
legacy model.

The first cache bootstrap can copy currently visible legacy feed/episode data
in bounded batches so the UI is not empty, then refresh subscribed feeds from
RSS. RSS remains the authority for rebuildable fields.

### Extension element storage

Store feed-level and episode-level extension elements together in one
local-only `CachedFeedExtensionElement` table. This includes Podcasting 2.0,
Podlove Simple Chapters, and extension namespaces the app does not know about
yet.

Suggested model:

```swift
@Model
final class CachedFeedExtensionElement {
    var id: String = ""
    var feedURL: String = ""
    var episodeID: String?
    var scopeRawValue: String = "" // feed or episode
    var namespaceURI: String?
    var qualifiedName: String = ""
    var localName: String = ""
    var payload: Data = Data() // canonical encoded NamespaceNode subtree
    var ordinal: Int = 0
    var contentHash: String = ""
    var updatedAt: Date = Date.distantPast
}
```

Use scalar feed/episode logical IDs rather than relationships. A feed-scoped
row has no `episodeID`; an episode-scoped row uses the same stable episode ID
as `EpisodeStateSync`. The deterministic row ID should include scope, owner
identity, qualified name, ordinal, and content hash.

`PodcastParser` currently has typed handling for Podcasting 2.0 optional tags
and separate handling for `psc:chapters`. Keep those typed projections for
runtime features, but also capture the canonical raw namespace subtree in this
table. Replace the known Podcasting 2.0 tag whitelist as the persistence
boundary: every non-core namespaced element must be retained, including
unknown future namespaces. Core RSS and iTunes fields may continue to map
directly to `CachedPodcast` and `CachedEpisode`.

On refresh, parse into one value result containing:

- typed feed and episode metadata;
- typed chapter/transcript projections;
- `[ParsedExtensionElement]` for all namespaced extension roots.

Upsert extension rows by deterministic ID and remove stale rows only after a
complete successful parse for that owner. A failed or partial parse must leave
the previous extension rows intact.

### Synced subscription ingestion

A `SubscriptionSync` record arriving from CloudKit must use the exact same feed
resolution, parsing, and cache-writing pipeline as a subscription created on
the current device. Do not create a placeholder cache record through a
separate reduced parser.

Extract the current logic behind
`PodcastModelActor.createPodcast(from:)`/`updatePodcast` into one service, for
example:

```swift
actor PodcastSubscriptionIngestionService {
    enum Source {
        case userInitiated
        case cloudSync
        case manifestRecovery
        case migration
    }

    func ingest(feedURL: URL, source: Source) async throws
}
```

Every source calls the same implementation:

1. normalize and resolve feed redirects/status;
2. call `PodcastParser.fetchPage`;
3. parse full RSS/iTunes metadata;
4. parse Podcasting 2.0, Podlove, and unknown namespace extensions;
5. upsert `CachedPodcast`, `CachedEpisode`, chapters, transcripts, and
   `CachedFeedExtensionElement`;
6. preserve user state in `UserState.sqlite`;
7. run the normal post-refresh actions such as auto-download evaluation;
8. publish diagnostics and refresh UI/widget/watch snapshots.

Add a subscription reconciler that compares active `SubscriptionSync` feed
keys with the local cache. When an active synced subscription has no complete
local cache record, enqueue `ingest(feedURL:source:.cloudSync)`. Deduplicate
in-flight work by normalized feed key and retry with backoff. Marking ingestion
complete is local cache state, not synchronized state.

CloudKit may deliver an unsubscribe before the original subscription or while
an ingestion is running. Re-check the newest `SubscriptionSync` tombstone
before committing post-ingestion subscription side effects. Cached feed data
may remain available locally, but it must not be presented as subscribed.

## Container wiring

Refactor `ModelContainerManager` to expose:

```swift
struct PodcastDataStores {
    let legacy: ModelContainer
    let sync: ModelContainer
    let cache: ModelContainer
}
```

Use App Group URLs:

- `SharedDatabase.sqlite` for legacy, unchanged, CloudKit automatic.
- `UserState.sqlite` for sync, CloudKit automatic.
- `PodcastCache.sqlite` for cache, `cloudKitDatabase: .none`.

Keep SwiftUI's environment `modelContainer` pointed at the legacy container in
the first transition release. Inject sync/cache services separately through
the environment. In the UI cutover release, point feed screens at the cache
container and use an environment state repository for overlays.

Widgets currently consume JSON snapshots from the App Group and do not need
direct SwiftData access. Preserve that boundary. Intents, CarPlay, watch sync,
and the share extension currently call `ModelContainerManager.shared.container`
or receive the legacy container; migrate those callers to repositories only
after dual writes are established.

## Production migration

### Release gate for the quiet foundation rollout

The first end-user release is intentionally additive and invisible:

- the legacy store remains the only UI/read authority;
- `UserState.sqlite` and `PodcastCache.sqlite` open independently and may fail
  without preventing the app from opening;
- migration runs on a utility task, retries failed runs after one hour, and
  rechecks successful runs no more than once per day across app launches;
- migration diagnostics and migration-specific copy compile only in Debug;
- destructive subscription and playlist-entry changes write explicit
  tombstones after ensuring the split stores have had a chance to open;
- legacy bookmark rows are not mutated merely to manufacture identifiers;
- unchanged listening summaries do not produce repeat CloudKit writes;
- the old database and model definitions remain untouched and available.

Before submitting this release:

1. Run the new user-state schema against the Development CloudKit environment.
2. Inspect the generated record types and indexes in CloudKit Dashboard.
3. Deploy that schema to the Production environment before App Store rollout.
4. Verify the archive uses the production App Group and CloudKit entitlements.
5. Test upgrade from an App Store build on at least an iPhone and a Mac using
   the same iCloud account.
6. Test a second device that starts with incomplete or delayed CloudKit data.
7. Start phased release at 1–5% and monitor crashes, container-open failures,
   migration duration, failed item counts, and CloudKit error rates.

Do not enable new-store reads, stop legacy writes, or remove the legacy store
in this release.

The AI-content exception is narrowly scoped: complete validated AI transcript
and chapter revisions may be copied from the synced store into matching legacy
episodes during the transition so they are visible on another device. This
does not make general feed or playback reads depend on the new stores.

### Release A: additive foundation and dual write

1. Keep the legacy container and UI unchanged.
2. Create `UserState.sqlite`.
3. Create `PodcastCache.sqlite`.
4. Start an idempotent migration service after the legacy container opens.
5. Copy user state with deterministic upserts.
6. Copy a bounded local cache snapshot for immediate UI continuity.
7. Route manual subscription and synced subscription discovery through the
   shared ingestion service.
8. Persist all namespaced extension elements in the local extension table.
9. Dual-write mutations to legacy and new sync state.
10. Continue reading legacy state as the UI authority.
11. Never delete a legacy record or store file.

### Release B: overlay reads and local feed writes

1. Read feed/episode/chapter/transcript data from the local cache.
2. Overlay new sync state in batches.
3. Fall back to matching legacy state if new state is absent.
4. Write feed refresh results only to the local cache.
5. Continue dual-writing user state to new sync and legacy stores.
6. Re-run migration after CloudKit import events and foreground activation.

### Release C: new state authority

1. Prefer new sync state for all reads.
2. Keep legacy fallback and incremental import.
3. Stop normal feed/cache writes to the legacy store.
4. Keep conservative legacy user-state writes for one more adoption window if
   rollback support is required.

### Later cleanup release

Only after telemetry shows sustained convergence:

- stop legacy dual writes;
- retain the legacy file for a documented grace period;
- remove legacy model definitions only when no supported app version needs to
  open the old store;
- make deletion a separate, explicit user-visible maintenance decision.

## Idempotent migration algorithm

Do not use one `didMigrate` boolean.

Maintain local migration metadata with:

- migration schema version;
- last started/completed timestamps;
- last successfully scanned legacy model and cursor;
- counts scanned/inserted/updated/skipped/failed;
- bounded failed-item keys and error messages;
- last observed CloudKit import completion.

Each run:

1. Fetch legacy records in bounded pages.
2. Convert each record to a stable logical key.
3. Fetch all destination records for that page's keys.
4. Insert when absent.
5. Merge when present.
6. Save each page independently.
7. Record failures and continue.
8. Re-run later; successful pages remain harmless.

Do not carry SwiftData model instances across actors or containers. Convert
legacy models to `Sendable` value transfer objects first.

### Merge rules

- Prefer the record with newer `updatedAt`.
- Legacy models often lack `updatedAt`; use the best field timestamp:
  `lastPlayed`, `completionDate`, `archivedAt`, `subscriptionDate`,
  `dateAdded`, or bookmark `creationtime`.
- Never replace a non-empty new value with an older/nil legacy value.
- `maxPlayPosition`, aggregate listening time, and completed state are
  monotonic unless an explicit user reset has a newer timestamp.
- Deletions/unsubscriptions require tombstones. Physical absence is ambiguous
  while CloudKit is partially synchronized.
- Equal timestamps use a deterministic tie-breaker such as source device ID or
  canonical encoded payload to avoid devices repeatedly flipping values.
- Deduplicate listening history by the stable session UUID, with a documented
  feed/episode/start/end composite fallback for malformed legacy records.
- Sum per-device summary contributions for global statistics. Migrate legacy
  summaries under one shared legacy source ID so several devices do not
  multiply the same partially synchronized baseline.

### Legacy mapping

- `Podcast.metaData.isSubscribed` -> `SubscriptionSync.isSubscribed`.
- `Podcast.metaData.subscriptionDate` -> `subscribedAt`.
- `EpisodeMetaData.playPosition` -> `EpisodeStateSync.playPosition`.
- `EpisodeMetaData.maxPlayposition` -> `maxPlayPosition`.
- history/status/completion -> `isPlayed`.
- archive/status/archivedAt -> archive fields.
- `wasSkipped`, first/last listen dates -> corresponding episode state.
- every manual `Playlist` -> `PlaylistSync`.
- every manual `PlaylistEntry` -> `PlaylistEntrySync`.
- `Bookmark.uuid` -> `BookmarkSync.id`; generate and write back a UUID only
  when the legacy value is missing.
- raw sessions/stats -> local cache, plus compact `ListeningSummarySync`.

Do not migrate `PlaylistPreferenceKeys.selectedPlaylistID`; it is intentionally
device-local. The current model has no favorite property, so no favorite field
or migration exists.

## Write-path changes

Introduce repositories rather than passing multiple containers into views:

- `SubscriptionStateRepository`
- `EpisodeStateRepository`
- `PlaylistStateRepository`
- `BookmarkRepository`
- `PodcastCacheRepository`
- `ListeningSummaryRepository`

Priority call sites:

- `EpisodeActor` playback/archive/history/bookmark methods.
- `Player.saveCurrentPlaybackState`, pause/background/switch/finish paths.
- `PlaylistModelActor` add/remove/reorder and playlist creation/deletion.
- `PodcastModelActor.setSubscriptionStatus` and `SubscriptionActor`.
- `SubscriptionManifestSync`, which becomes recovery/bootstrap support rather
  than the subscription authority.
- the subscription reconciler, which invokes the shared ingestion service for
  newly arrived `SubscriptionSync` records.
- `PodcastModelActor` and `SubscriptionManager` feed refresh writes.
- `BookmarkListView`, currently filtered by `PersistentIdentifier`.
- `PodcastSettingsModelActor` and settings views.
- widget snapshot generation, watch sync, CarPlay, intents, and inbox count.

Persistent identifiers are acceptable only for short-lived navigation within
one container. Replace stored/cross-service use with feed keys, episode keys,
playlist UUIDs, and bookmark UUIDs.

## Playback write reduction

Current behavior:

- foreground progress cache updates every 10 seconds;
- background cache updates every 45 seconds;
- forced persistence occurs on pause, backgrounding, switching, and finish;
- `EpisodeActor.setPlayPosition` saves on 10-second deltas.

The defaults cache is useful crash protection and should remain local. The new
CloudKit writer should coalesce updates:

- save synced progress every 20-30 seconds while playing;
- always flush on pause, background, episode switch, seek followed by pause,
  and playback completion;
- do not sync chapter progress or feed-derived values;
- skip saves when position/state has not materially changed;
- serialize writes per episode key to prevent stale tasks overwriting newer
  values.

## Diagnostics

Add a DEBUG diagnostics screen with separate source/destination counts:

- legacy subscribed podcasts;
- `SubscriptionSync` active/tombstoned;
- legacy episodes and episodes with meaningful state;
- `EpisodeStateSync`;
- legacy/new playlists and entries;
- legacy/new bookmarks;
- legacy raw statistics, new compact listening history, and new summaries;
- cache podcast/episode/chapter/transcript counts;
- last run start/completion, pages, failures, and last CloudKit import event.

Use `Logger`/`BasicLogger` and `CrashBreadcrumbs` around container open,
migration start/page/end, and errors. Migration failure must not prevent the
legacy UI from opening.

`StoreSplitMigrationDiagnostics.snapshot` accepts the legacy, user-state, and
cache contexts separately so source/destination counts cannot accidentally be
queried from the wrong store.

## Tests

Foundation tests:

- feed and episode identity normalization;
- GUID/enclosure/link/hash precedence;
- deterministic hash fallback and collision inputs;
- merge decision and equal-timestamp tie-breaking;
- queue sorting and reordering;
- duplicate logical-ID compaction.
- parser capture of known Podcasting 2.0, Podlove, and unknown namespace
  elements into the same local extension table.
- AI transcript chunk sizing, complete revision reconstruction, hash failure,
  and partial-delivery behavior.
- publisher transcripts are not replaced by incoming AI transcripts.
- incoming AI chapters replace only AI-generated chapter markers.
- extension refresh replacement only after a complete successful parse.
- active playlist selection remains local when synced playlists arrive.

Migration tests with in-memory legacy/sync/cache containers:

- insert, repeat, and partial-failure retry;
- newer destination wins;
- newer legacy source wins;
- nil legacy fields do not erase destination values;
- tombstones prevent resurrection;
- late legacy records are imported on a later run;
- bookmark UUID stability;
- custom playlist and queue preservation;
- synced subscription discovery invokes the same ingestion implementation as
  a manual subscription;
- duplicate synced subscription events coalesce into one in-flight ingestion;
- unsubscribe tombstones suppress late ingestion completion;
- state lookup prefers sync, then legacy, then empty.

## Risk register

| Risk | Detection | Mitigation |
| --- | --- | --- |
| Late CloudKit records missed | source/destination count drift after import | repeat migration after imports and foregrounding |
| Duplicate sync records | duplicate logical-ID diagnostics | deterministic IDs, newest-wins reads, later compaction |
| Unsubscribe/delete resurrection | active record reappears | tombstones with timestamps |
| Empty UI after update | cache episode count is zero | bounded legacy cache copy, then RSS bootstrap |
| Synced feed uses reduced parsing | Podcasting 2.0/Podlove data missing on second device | one ingestion service for manual, sync, manifest, and migration sources |
| Unknown extension data is discarded | extension diagnostics differ from source XML | capture every non-core namespaced subtree in one local table |
| Feed redirect breaks identity | state missing after redirect | local feed aliases and explicit feed-switch migration |
| GUID changes or is reused | multiple/missing state matches | namespaced fallback IDs and conflict diagnostics |
| Stale async playback write wins | position moves backward | per-key serialization and `updatedAt` compare |
| Settings are silently lost | legacy/new preference diff | field-by-field migration and legacy fallback |
| Statistics double count | totals exceed raw source | device-attributed summaries and idempotent period keys |
| Extension reads wrong store | widget/watch/intents stale | repository APIs and App Group snapshot compatibility |
| Remote playlist changes replace local active playlist | device starts playing from an unexpected list | never sync selected playlist ID; validate local selection after playlist merges |
| New container fails to open | launch diagnostics | open legacy first; make new stores non-blocking in Release A |
| CloudKit schema incompatibility | development schema/test failure | additive record types, defaults/optionals, no relationships or unique constraints |

## Apple platform constraints

Relevant Apple documentation:

- [Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
- [ModelConfiguration](https://developer.apple.com/documentation/swiftdata/modelconfiguration)
- [CloudKitDatabase.none](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct/none)

Before shipping Release A, exercise the exact production CloudKit container in
a development environment and deploy only additive schema changes. Do not
remove legacy record types or fields.

## Recommended patch sequence

1. Harden stable IDs and make proposed sync models CloudKit-compatible.
2. Add `PodcastDataStores` and open new stores without changing UI behavior.
3. Add migration transfer objects, upsert services, and multi-store diagnostics.
4. Extract one subscription ingestion/parser pipeline and add the subscription
   reconciler.
5. Add the unified local extension-element table and parser capture.
6. Add dual writes for subscriptions and episode state.
7. Add playlist/bookmark/settings dual writes while keeping active playlist
   selection local.
8. Add remaining local cache models and bounded bootstrap.
9. Switch feed refresh to cache.
10. Switch UI reads to cache plus state overlays and legacy fallback.
11. Migrate app extensions and system integrations.
12. Reduce or stop legacy writes only after convergence telemetry.
