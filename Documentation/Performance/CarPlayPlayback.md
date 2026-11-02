# CarPlay playback system pressure and diagnostics

Issue #396 followed a 2026-11-02 report in which the whole CarPlay interface
froze during Up Next playback on iOS 27.2 (24B119). The three Jetsam reports
from that morning do not show an Up Next crash or an out-of-memory kill: Up
Next, CarPlay and CarPlayTemplateUIHost kept the same process IDs in all three,
with no Jetsam reason. `linkd` and other daemons reached their high-water
limits under system memory pressure. None of this establishes a root cause, so
the changes below reduce avoidable work and make a recurrence diagnosable. They
do not claim to fix a system or head-unit defect.

## What playback asks of the system

- **Widgets.** The playback snapshot in the app group is still written about
  once a minute while playing, but `WidgetPlaybackReloadPolicy` reloads the Now
  Playing widget for progress alone at most every five minutes. The widget
  advances progress itself with one dated timeline entry per minute. Episode,
  play/pause, seek (more than 20 seconds from the expected position), speed,
  artwork and skip-interval changes reload it at once. The Play Next Queue
  widget reloads only for episode or play/pause changes and otherwise picks up
  progress on its own 15-minute timeline.
- **CarPlay queue.** Text rows are published first. Artwork is requested for
  the first 24 rows only, with at most four loads at a time. Notification
  bursts are coalesced into one update after 500 ms, and an update that would
  publish the same rows is skipped, so the host gets no repeated
  `updateSections` or `setImage` calls.
- **Now Playing artwork.** Every image handed to `MPNowPlayingInfoCenter` is a
  scale-1 bitmap of at most 1024 pixels on its longest edge, whatever decoded
  it (remote, chapter, or embedded-file artwork). An image without usable
  dimensions is dropped, and the same image is not re-wrapped on later
  updates.

## Diagnosing a recurrence

Unified logging category `CarPlayScene` records, without titles, URLs or
artwork:

- connection, container preparation time, root template result and total
  time to the queue (`carplay_connected`, `carplay_container_slow` after 10 s,
  `carplay_container_failed`, `carplay_root_published`, `carplay_disconnected`);
- queue template publishes with row count and elapsed time, and artwork
  handoffs with images handed off, images requested, cancellation and elapsed
  time.

The connection events are also written to the crash breadcrumbs shown in
Support Diagnostics, each with the last remote command and the last
play/pause change and their ages. Remote commands themselves are kept in
memory only.

When the whole car UI freezes again, record whether only Up Next or the entire
CarPlay interface hung, and collect a sysdiagnose or Console log covering
`CarPlay`, `CarPlayTemplateUIHost`, `carkitd`, `mediaremoted`, `linkd` and
`UpNext`. If it happens with Up Next idle or not running, report it through
Feedback Assistant and track it in #364.

Verified so far: unit tests for the reload policy and the artwork bound, an iOS
simulator build and a macOS build. Not yet checked in the CarPlay Simulator or
on a head unit.
