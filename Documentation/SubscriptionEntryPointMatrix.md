# Subscription entry-point matrix

All user-visible subscribe/unsubscribe transitions must use the same durable
subscription mutation contract. `SubscriptionManifestSync` is a recovery
manifest only; it is not the source of truth.

| Entry point | Current mutation path | Durable state | Immediate UI feedback | Duplicate behavior / test focus |
| --- | --- | --- | --- | --- |
| Podcast Detail | `PodcastModelActor.setSubscriptionStatus` | `SubscriptionSync` plus legacy projection | Pending button, confirmed label, retryable error | One in-flight mutation; idempotent result |
| Browse / discovery | `SubscriptionManager.addToLibrary` | `SubscriptionSync` after shared writer integration | Browse status is read from persisted feed identity | Existing feed is a no-op; import failure is separate |
| OPML import | `SubscriptionManager.subscribe(all:)` / `SubscriptionActor` | Per-feed `SubscriptionSync` result | Per-feed success, validation, or queued-import result | Duplicate URLs collapse by normalized identity |
| Share / deep link / App Intent | App and extension subscription handlers | Shared subscription mutation contract | Refresh affected library/browse state | Never infer success from an optimistic directory flag |
| Feed switch / repair | `PodcastModelActor.switchPodcastFeed` | Preserve subscription state under the new identity | Existing subscription state remains visible | Alias/redirect matching prevents a second active row |
| Library delete | `PodcastModelActor.deletePodcast` | Explicit delete tombstone | Row is removed | Delete is destructive and distinct from unsubscribe |
| Background refresh / CloudKit projection | Refresh and `StoreSplitUserStateImporter` | Newest `SubscriptionSync` record wins | Local projection updates the affected feed | Older manifests/imports cannot resurrect a tombstone |

Subscription persistence and episode ingestion are separate outcomes: a valid
local subscription remains subscribed when an optional feed import fails.
