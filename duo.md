# Up Next on iPhone Duo

Analysis date: 2026-09-14. This is a design and implementation plan for the current SwiftUI codebase, not a proposal to fork the app into a separate “Duo mode.”

Revision 2026-09-14 (second pass): re-read the published HIG page and added layout options per surface, control ownership, bar-free surfaces, an explicit open/close transition contract, and the conditional reserved regions. Nothing from the first pass was removed.

## Recommendation in one sentence

Keep the current queue-first experience on the outer display, let the inner display use the app’s existing sidebar hierarchy, and turn the full player into a fold-aware player/content arrangement whose state survives every open, close, rotate, and partial-fold transition.

## Device and platform baseline

Apple’s published hardware sizes are:

| Surface | Hardware size | Pixels | Early @3x layout target | Size-class guidance |
| --- | --- | --- | --- | --- |
| Outer display | 5.4-inch | 1398 × 2034 | about 466 × 678 pt | Compact-width iPhone experience |
| Inner display | 7.6-inch | 1878 × 2670 | about 626 × 890 pt, or 890 × 626 pt when rotated | Regular width and regular height |

The point figures are arithmetic planning targets, not dimensions published by Apple. Read the live scene geometry and safe-area insets; never encode these values as device detection. The usable rectangle is smaller and can be asymmetric because of the vertical system bar, cameras, Split View, and the active folding region.

Building with the iOS 27.1 SDK is the important opt-in. That SDK lets the app reach the full inner display and gives standard navigation, tab, and toolbar containers the new vertical-bar treatment. Keep the iOS 26 deployment target by availability-guarding iOS 27.1-only APIs.

## Apple rules that drive this plan

- Treat Duo as one continuously resizing iPhone app. Build primarily for compact and regular size classes, not six hand-authored pose layouts.
- Preserve functionality, hierarchy, selection, and work in progress across the inner and outer displays. The inner display may reveal one additional hierarchy level.
- Keep foreground controls inside the safe area. Treat the two horizontal insets independently; backgrounds may extend edge to edge.
- A partially folded inner display creates an active division reserved region at the fold. Interactive controls and indivisible content must avoid it. Continuous scrolling content may flow normally.
- Prefer `NavigationSplitView`, `NavigationStack`, `TabView`, `List`, sheets, alerts, and menus because the system adapts them to the fold.
- Use `ArrangementView` for two content views that already have a split or overlay relationship. Keep navigation outside the arrangement.
- Toolbars and tab bars normally move to the trailing vertical edge on the outer display and on the inner display in landscape. Inner-display portrait keeps horizontal bars. Symbols, titles, grouping, overflow, and visibility priority matter.
- Use hinge angle only for an optional effect or interaction. Use size classes, arrangements, safe areas, and reserved regions for layout.

## Current code assessment

The foundation is close, but two conditions currently prevent the best Duo layout:

- `Raul/App/ContentView.swift` selects `SidebarAppShell` only when `PlatformSupport.isPhone == false`. Duo remains an iPhone even when its inner display is regular width, so the open device will incorrectly stay in `CompactAppShell`.
- `Raul/Features/Player/Views/PlayerView.swift` recognizes a wide player only when the phone has compact vertical size and `width > height`. Apple says the inner display is regular in both dimensions and doesn’t honor supported interface orientations in the usual way. The open landscape player can therefore fall into `portraitFullPlayer`.
- `CompactAppShell` already uses a standard `TabView`; `SidebarAppShell` already uses `NavigationSplitView`. `AppNavigationModel` owns section and path state above both shells, which is a strong basis for continuity.
- The mini player has two implementations: `tabViewBottomAccessory` in the compact shell and a custom `PersistentMiniPlayer` below the sidebar. Both must show the same episode, progress, and transport state during a live resize.
- The full player is currently a sheet. Its standard layout includes a fixed scaled media-section height of 360 points, while the wide layout uses a custom `HStack` with a 280–360 point controls pane. Both deserve explicit testing against the short outer display and the fold.
- Queue, Inbox, Library, and Search are standard navigation/list content and should receive much of the platform adaptation automatically.

## Layout by display and pose

| Configuration | Proposed Up Next layout | Fold behavior |
| --- | --- | --- |
| Closed, outer display | Keep the four-destination `TabView`; queue/list content remains primary. Keep the system tab accessory mini player. | Preserve selected section, navigation path, queue selection, search text, playback, and any editor draft when opening. |
| Fully open, inner landscape | Use `NavigationSplitView`: sidebar for Queue, Inbox, Library, Search, Downloads, Bookmarks, and History; detail for the selected destination. The full player uses player controls plus transcript/shownotes/chapters or Up Next side by side. | Let system columns and an `ArrangementView` balance around an inactive zero-width fold and later around an active division region. |
| Fully open, inner portrait | Keep sidebar/detail where space permits. The system bars become horizontal. In the full player, use a vertical split or the current readable single-column player rather than stretching artwork to the whole width. | No feature or selection changes just because bars change axis. |
| Partially folded like a book | Put the main player in one usable region and transcript/chapters/queue in the other. Prefer the trailing region for a newly presented alert or sheet. | No transport control, scrubber, chapter action, or transcript row may straddle the fold. Avoid moving continuously scrolling transcript text item by item. |
| Tabletop/laptop pose | Put artwork/video/transcript content in the upper, view-at-a-distance region and playback controls, scrubber, speed, and sleep timer in the lower interactive region. | A split arrangement may change from side-by-side to top/bottom without changing content identity. |
| Standing/tent/edge poses | Favor the readable single-region player and large transport controls. Allow the system to choose the usable region; don’t depend on a “tent” boolean. | Avoid centered custom overlays that can land on the fold. |
| Split View or stacked video multitasking | Collapse the sidebar or secondary player content as the scene narrows. Preserve the tab bar before secondary toolbar actions on navigation screens. | Treat every intermediate width as valid, including widths narrower than the outer display. |

## Layout options per surface

The pose table above says what should happen. This section lists the containers that can produce it, so the choice is an explicit decision rather than a side effect of whichever view already existed.

### Browsing (Queue, Inbox, Library, Search)

| Option | Container | When it is right | Cost |
| --- | --- | --- | --- |
| B1 — two columns | `NavigationSplitView` sidebar plus content; episode detail pushes inside the content column | Default for the inner display. Matches the Mail example in the HIG: exactly one more level of hierarchy than the outer display, no more. | Episode detail replaces the list while reading. |
| B2 — three columns | Sidebar, episode list, episode detail | Only when the usable content region is genuinely wide, which in practice means flat inner landscape with no Split View. | Two collapses to manage during a fold, and a high risk of a 200-point detail column. |
| B3 — two columns plus inspector | Sidebar and list, with episode info, chapters, or transcript hits in an inspector | Best where the secondary content is reference material the user consults while the list stays put. | The inspector is one more thing to preserve across a fold. |

Recommended: B1 as the baseline and B3 where the secondary content is reference rather than a destination. Reach for B2 only after measuring real column widths in Device Hub.

### Full player

| Option | Container | When it is right |
| --- | --- | --- |
| P1 — split arrangement | Primary: artwork and transport. Secondary: transcript, chapters, shownotes, or Up Next. | The inner display in any pose. It splits horizontally when wider than tall, vertically when taller, and places one pane per usable region in a book or tabletop pose with no extra code. |
| P2 — overlay arrangement | Primary: expanded player. Secondary: browsing content beneath it. | Only if the mini player ever becomes an inline expanding player instead of a sheet. |
| P3 — bar-free canvas | Full-width player with no toolbar or tab bar. | The HIG explicitly allows this for visual, non-scrolling interfaces and names Calculator as the example. A now-playing screen qualifies. |

P3 deserves a real evaluation rather than an automatic no. The player is the one screen where the chrome carries almost nothing: a close affordance and the transport controls are the interface. A full-width player avoids spending a bar’s width of the short outer display on a rail holding two items. The HIG constraint if it is adopted is that nothing may conflict with the Dynamic Island or the status bar, so keep the artwork’s top edge and any custom close control clear of the outer camera region. The mixed form the HIG recommends fits well here: let artwork or a header span the full width while the scrolling shownotes and transcript stay inset.

### Mini player

| Option | When it is right |
| --- | --- |
| M1 — system tab accessory, the current compact behaviour | The outer display and any pose where the tab bar is present. Keep it; the system moves it with the bar. |
| M2 — persistent control below the sidebar, the current regular behaviour | The inner display with a sidebar. Keep it, but drive it from the same state object so a fold never shows two different progress values for a frame. |
| M3 — no mini player | Only while the full player is the visible content. Never hide it as a response to narrow width; that breaks the equal-functionality rule. |

## Concrete changes

### 1. Let regular-width iPhone use the sidebar

Change `ContentView.usesSidebarLayout` to be driven by the current horizontal size class, not by “phone versus non-phone.” Keep the Catalyst/desktop override.

The selected destination must have a single source of truth. `navigation.selectedSection` already provides that. Verify that every compact tab maps to the equivalent sidebar row and that opening/closing doesn’t reset `navigation.pathBinding(for:)`.

Do not preserve a separate compact and regular navigation stack in local view state. If fold testing exposes stack loss, lift any remaining paths or selected episode IDs into `AppNavigationModel`/`SceneStorage`.

### 2. Make the full player an arrangement

The clearest mapping of the current player is:

- Primary: `PlayerControllView` and its media/artwork.
- Secondary: the currently selected shownotes, transcript, chapters, or queue view.
- Style: split when neither pane should obscure the other. This is the same player/Up Next pattern Apple uses when introducing `ArrangementView`.

On iOS 27.1, put `ArrangementView` inside the player’s `NavigationStack`, not the other way around. A wide display splits horizontally, a tall one vertically, and an active fold gives it the correct usable regions. Keep the existing iOS 26 layout as a fallback.

The compact outer player can continue as one scrollable view, but replace the fixed 360-point media section with a proposal derived from the available height, Dynamic Type, and whether inline transcript is visible. The short display must always leave the scrubber and primary transport controls reachable.

### 3. Use an overlay arrangement only for the mini-player relationship

If the design evolves from a sheet into an inline expanded player, model the mini player/full player as foreground over content with an overlay arrangement. Query `overlayArrangementZIndex` only to choose a compact versus expanded representation; don’t use it as a pose detector.

If the player remains a sheet, keep the system sheet. Apple’s sheets already move away from the fold. Verify that the full-player sheet retains the current episode and scroll position as its bar switches between vertical and horizontal.

### 4. Audit vertical bars

- Keep the standard `TabView`, `NavigationStack`, and `.toolbar` containers.
- Every toolbar item needs both a symbol and a title. The title is required for overflow even when the visible representation is icon-only.
- `PlaylistTitleMenu` is a custom principal control and may remain horizontal because its text carries information. Verify it doesn’t compete with navigation controls on the outer display; if it does, show a compact playlist symbol in the bar and move the full title into the content header.
- Give Play/Pause, Queue, and any badge-bearing Inbox control high visibility. Let secondary settings, transcript generation, clip export, and similar actions use the system `ToolbarOverflowMenu`.
- Avoid custom spacing between toolbar items. Keep related controls in `ToolbarItemGroup`.
- On a navigation screen, prefer preserving tabs and overflowing toolbar actions. In the task-oriented full player, prefer transport actions and allow tab chrome to minimize.

### 5. Handle the fold only where custom layout needs it

Lists, scroll views, split views, menus, sheets, and alerts should stay system-managed. Query the division reserved region for custom player media, the scrubber, waveform, and custom overlays. Query occlusion regions for any edge-to-edge media near the camera.

Conceptual iOS 27.1 hook:

```swift
GeometryReader { proxy in
    let fold = proxy.reservedRegions(kind: .division).first?.frame
    PlayerCanvas(foldingRegion: fold)
}
```

Use this geometry to displace indivisible controls as a unit. Do not shift every transcript or queue row, and do not make general layout decisions from `UIScreen.main` or hinge angle.

### 6. Preserve playback and reading continuity

Opening or closing must not restart audio, dismiss the player, change queue, or jump the transcript. Persist or lift:

- selected section and each section’s navigation path;
- current playlist and requested episode;
- presented player state and selected player content tab;
- transcript/chapter scroll anchor and follow-playback mode;
- search query and any settings/edit draft;
- mini-player progress and skip-protection undo state.

Avoid attaching these solely to a compact-only or regular-only subtree. Use stable IDs and `@SceneStorage` for scene-local navigation/reading position; keep audio state in the existing shared `Player`.

### 7. Keep each control with the content it affects

The HIG is explicit that controls belonging to a content area other than the trailing one stay with that area: in Mail, the controls that act on the message list sit above the list pane rather than in the side bar, because the side bar reads as belonging to the trailing content. Up Next has three groups that need sorting by owner.

- List-owned: playlist selection, queue sort and filter, Edit, Mark all played, and the search field. These belong to the queue or list column. Attach `.searchable` to the list column rather than to the split view root, or the field follows the detail pane.
- Detail-owned: Download, Add to queue, Share, Bookmark, transcript generation. These belong to the episode view’s own toolbar.
- Player-owned: speed, sleep timer, output route, chapter list. These belong to the player and never to the browsing chrome.

`PlaylistTitleMenu` is currently a principal item. On the inner display it acts on the list, so its natural home is the head of the list column, not the trailing vertical bar. On the outer display, where there is only one content area, the bar is the correct place for it.

### 8. Reduce text-only bar buttons

Labels that include text stay in a horizontal bar; only symbols move to the vertical axis. Up Next has roughly a dozen text-only toolbar buttons across its editors and sheets. Each one that cannot be expressed as a symbol forces a horizontal bar to remain, which costs vertical space on the display that has the least of it.

- Give every item that is not deliberately text-only both a symbol and a title with `Label`, so the system can choose the representation and still have a title for overflow.
- Keep genuinely text-only items to the small set where a symbol would be ambiguous. A modal’s confirm action is the usual legitimate case.
- Use `ToolbarItemGroup` instead of manual spacing. The system inserts the vertical gap that keeps items originating from the top and bottom bars distinct.
- Do not override the default placement to force a bar back to horizontal. Vertical bars are one of this device’s core patterns, and overriding them makes the app read as foreign.

## The open and close transition

Everything above describes states. This section describes the event between them, because most of what will feel wrong on this device happens in the two or three seconds while the scene is resizing.

### Promotion and demotion

Opening the device promotes a pushed screen into a column; closing demotes a column back onto a stack. Decide this mapping once in `AppNavigationModel` instead of letting each shell rebuild from whatever it happens to own.

| Outer display (compact) | Inner display (regular) | Rule on transition |
| --- | --- | --- |
| Tab selected, path empty | Sidebar row selected, detail shows that destination | Selection maps one to one. Nothing changes but the chrome. |
| Tab selected, one episode pushed | Sidebar row selected, list shows that episode as selected, detail shows the episode | The push becomes the selection. Closing again must re-push, not leave the user at the list. |
| Path two or more levels deep | Same destination in the detail column with the remaining path intact | Only the first level is absorbed. Everything deeper stays a stack inside the column. |
| Full-player sheet presented | Player as detail content or the same sheet, per the decision above | The episode, playback position, selected player tab, and transcript anchor are identical before and after. |
| Search tab with a query and results | Sidebar Search selected, query and results intact | Never clear the query because the field moved. |

### What may move and what may not

The HIG asks for small adjustments rather than rearrangement, because controls that disappear or shift dramatically are hard to find and track. In practice that is a budget.

- May change: the number of visible columns, the bar axis, grid column counts, artwork size, and whether the transcript is a pane or a pushed screen.
- May not change: which episode is playing, where the transcript is scrolled, which player tab is selected, the queue’s scroll anchor, the search query, the presence of the mini player, or the identity of whatever has focus.
- Preserve scroll by anchor, not by offset. A fold changes the height available to every row, so a stored content offset lands somewhere else. Store the top-most visible episode ID and restore it with `ScrollViewReader` or `scrollPosition`.

### Interactions that are in flight when the device moves

These are the cases a static screenshot pass will never catch.

- Waveform scrubbing. `WaveformView` tracks a raw horizontal drag and maps x to a time. If the view’s width changes mid-gesture, the same finger position now means a different timestamp and the user has silently seeked. Convert x to a proportion of the current width on every change, and if the width changes while a scrub is active, either end the gesture at the last committed value or recompute so the audio position stays put.
- Sheets, alerts, menus, and popovers reposition themselves away from the fold automatically. Their content does not: a sheet with a fixed detent can lose its Save button when the region becomes short.
- Keyboard and focus. The search field and any editor keep focus through a resize only if the field’s identity is stable. If it lives in a branch that is replaced when the size class changes, focus and the keyboard are lost mid-word.
- Audio never pauses, restarts, re-buffers, or re-announces for a layout reason. Keep playback in the shared `Player`, never tied to a view’s lifetime.

## Reserved regions that come and go

Three of the four reserved regions on this device are conditional, so a layout that is correct at one moment can be wrong a second later with no user navigation at all.

| Region | When present | What Up Next must do |
| --- | --- | --- |
| Outer front-facing camera | Always, on the outer display | Never pin custom chrome to the very top of the vertical axis. The system already arranges bar items around it. |
| Dynamic Island expansion | While a Live Activity is running | Up Next has no ActivityKit target today. If a playback Live Activity is added, which is the natural candidate, the top of the outer display’s vertical axis grows, and any custom header or artwork that assumed a fixed top inset gets clipped. Lay out the player’s top edge against the live safe area now so that feature stays additive. |
| Inner front-facing camera | Only while the camera is active | Not applicable here. Do not reserve space for it speculatively. |
| Folding region | Only while partially open | Zero-width when flat. Query it; never assume it. |

## Implementation order

1. Rebuild with Xcode 27.1/iOS 27.1 SDK and remove the `isPhone == false` gate from regular-width navigation.
2. Add resize tests for the shell and assert section/path continuity across compact ↔ regular changes.
3. Replace player orientation detection with adaptive layout/arrangement behavior.
4. Audit the mini player, playlist title control, and player toolbars in vertical-bar screenshots.
5. Add reserved-region avoidance to the custom media, waveform, and transport layout.
6. Tune outer-display heights and Dynamic Type after behavior is correct.

## Verification matrix

Run the app in Device Hub and exercise open, close, rotate, and fold controls while audio is playing.

- Outer portrait and rotated outer display: all tabs, queue settings, search field, mini player, and full-player transport remain reachable.
- Inner landscape and portrait: regular shell appears; sidebar selection maps to the former tab; player chooses the intended layout.
- Slowly fold from flat to book and tabletop positions: no scrubber thumb, waveform marker, playback button, sheet button, or menu crosses the active fold.
- Close while viewing an episode, transcript, or settings sheet; reopen and confirm identical semantic state.
- Test compact/regular transitions with VoiceOver, Reduce Motion, Bold Text, and the largest accessibility text sizes.
- Test right-to-left layout. Duo’s hardware-aligned vertical bar stays on the same physical side, so content must follow the reported safe area instead of assuming “trailing inset equals leading inset.”
- Test Split View beside another app and the video/app stacked layout at every divider position.
- Snapshot planning sizes: 466 × 678, 678 × 466, 626 × 890, and 890 × 626 points. These catch fixed-size regressions but do not replace Device Hub’s fold simulation.

### Additional checks from the second pass

- Start a waveform scrub and fold the device without lifting the finger. The playback position must not jump.
- Open the device while the search field has focus and a partial query. Keyboard, query, and caret position all survive.
- Fold while a chapter menu, a sleep-timer menu, and a confirmation alert are open. Each moves clear of the fold and none dismiss.
- Compare the two mini-player implementations across the transition. They must never disagree about episode, progress, or transport state, even for one frame.
- Confirm every toolbar item has a title in the overflow menu, including items that render as a symbol only.
- Count the text-only buttons in each toolbar. Where the count is high, confirm the horizontal bar is intentional.
- If a playback Live Activity exists by then, repeat the fold test with it active and confirm the expanded Dynamic Island never covers player content.

## Sources

- [Designing for iPhone Duo — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [iPhone Duo technical specifications](https://www.apple.com/iphone-duo/specs/)
- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)
- [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/)
- [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)
- [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/)
- [Leverage multiple displays and scenes on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111464/)
