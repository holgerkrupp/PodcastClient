# Live podcast refresh and Podping decision

Status: keep Podping optional; do not make it a prerequisite for live playback.

## Decision

Podcasting 2.0 `podcast:liveItem` metadata in the publisher's RSS feed remains
the authoritative state. Up Next may use Podping as a hint that a subscribed
feed changed, but it must always fetch and parse that feed before showing a
new state or starting a stream. A missing, delayed, duplicated, or malformed
Podping event therefore degrades to the existing foreground/background feed
refresh path.

The client will not maintain a permanently connected Podping subscription.
iOS and iPadOS do not guarantee an always-running background process, and a
long-lived connection would increase battery use while still missing events
when the app is suspended. The current implementation instead prioritizes
feeds with a live item or a pending start window during the bounded refresh
passes. This gives useful near-start discovery without aggressive polling.

## Event and bridge options

Podping events are feed-update hints, not a live-state database. A future
optional bridge could consume the public event stream, match feed URLs against
opaque per-install interests, and send a silent APNs notification containing
only a feed identity. The client would then refresh that feed and trust its RSS
`liveItem.status`. The bridge must not receive a complete subscription export,
and APNs tokens must be scoped, revocable, and expired when the installation is
removed.

The bridge would require rate limiting, duplicate suppression, token lifecycle
management, abuse protection, monitoring, and a privacy review. A CloudKit
public database or a small independently deployable service could be evaluated
later, but neither is necessary for basic live playback.

## Reliability and cost

Client-only targeted refresh has no new service cost and works offline until a
normal feed refresh is possible. Its latency is bounded by the system's
background-task scheduling and the existing refresh window. An optional bridge
could reduce latency when the app is suspended, but delivery would still be
best-effort and the RSS refresh would remain necessary. Operating cost is
therefore justified only if live publishers demonstrate that the bounded
refresh path is insufficient.

## Recommendation

Ship the client-only path first. Keep Podping ingestion and any APNs bridge as
a separate follow-up implementation with an explicit privacy and operations
review. The master “Show Live Podcasts” setting gates all future registration
or processing so disabling the feature remains a complete opt-out.
