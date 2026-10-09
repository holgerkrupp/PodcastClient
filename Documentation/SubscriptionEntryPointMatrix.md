# Subscription entry-point matrix

All user-visible subscribe/unsubscribe transitions must use the same durable
subscription mutation contract. `SubscriptionManifestSync` is a recovery
manifest only; it is not the source of truth.

| Entry point | Current mutation path | Durable state | Immediate UI feedback | Duplicate behavior / test focus |
| --- | --- | --- | --- | --- |
| Podcast Detail | `PodcastDetailView.toggleSubscriptionStatus` → `PodcastModelActor.setSubscriptionStatus` → shared persistence writer | `SubscriptionSync` plus compatibility metadata | Pending button, confirmed label, retryable error | Per-feed mutation gate and writer idempotence; detail control test coverage remains a follow-up |
| Browse / discovery | `PodcastBrowseViewModel.subscribe` → `SubscriptionManager.addToLibrary` | `SubscriptionSync` plus compatibility metadata | Status uses an indexed per-feed identity lookup | No-op subscribe does not enqueue import; only affected keys are queried |
| OPML import | Active `ImportExportView` route → `SubscriptionManager.subscribe(all:)`; legacy `SubscriptionActor` overload delegates to it | Per-feed `SubscriptionSync` result | Per-feed success, validation, or queued-import result | Repeated normalized feeds share the same idempotent writer |
| Share / deep link / App Intent | `PodcastShareExtension` / `ContentView` pending action and `SubscribeToPodcastIntent` → `PodcastModelActor.createPodcast` or `SubscriptionManager.addToLibrary` | Shared subscription mutation contract | Callers receive success only after local durable commit | App Intent propagates persistence errors; share paths use the same library route |
| Feed switch / repair | `PodcastModelActor.switchPodcastFeed` and `FeedURLRepairSheet` | Existing subscription state is retained while endpoint identity is repaired | Existing subscription state remains visible | Feed aliases are projected by existing identity infrastructure |
| Library delete | `PodcastListViewModel.deletePodcast` → `PodcastModelActor.deletePodcast` | Explicit delete tombstone | Row is removed | Delete remains destructive and distinct from unsubscribe; write failure is surfaced |
| Background refresh / CloudKit projection | Refresh coordinator and `StoreSplitUserStateImporter` | Newest `SubscriptionSync` record wins | Local projection updates the affected feed | Subscription changes share the per-feed gate; import refuses unsubscribed feeds; KVS restore yields to known authoritative rows |

`UpNextTests/StableIdentityTests.swift` covers writer tombstones, idempotent
subscribe/unsubscribe/resubscribe transitions, and rejection of stale writes.
The full UI, CloudKit two-device, delayed background-import and performance
acceptance matrix from issue #308 still requires broader automated coverage and
a device smoke run.

Subscription persistence and episode ingestion are separate outcomes: a valid
local subscription remains subscribed when an optional feed import fails.
