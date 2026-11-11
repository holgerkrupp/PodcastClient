# Apple Human Interface Guidelines — Cross-platform agent checklist

Last reviewed: 2026-11-11. **Application-neutral**. This is an actionable interpretation of Apple's guidance, not a replacement for the current official HIG. Recheck linked pages and SDK availability before using newer APIs. Do not infer a platform is supported merely because it appears here.

## Operating contract for coding agents

1. Inspect app targets, minimum OS, UX flows, supported input modes, and the existing design system. Do not add targets, entitlements, packages, or optional features without an explicit product decision.
2. Inventory all screens, windows, menus, navigation paths, modal presentations, custom controls, empty/loading/error states, and system entry points. Record violations and proposed native replacements.
3. Design responsively from *available window/view geometry* and size classes, not the device name or a fixed screen dimension. Check layout while it changes, not only at launch.
4. Prefer native SwiftUI/AppKit/UIKit components and semantic roles; reuse shared domain logic while allowing truly platform-specific UI. Preserve user work, focus, selection, navigation state, and undo.
5. Prioritize clarity and content over toolbar density. Put primary actions where expected; provide discoverable secondary actions through native menus, inspectors, contextual commands, or progressive disclosure. Avoid duplicate navigation controls.
6. Accessibility, localization, privacy, and input alternatives are acceptance requirements. Do not call a feature complete on visual inspection alone.
7. Validate the actual supported targets and configurations. Report each changed surface, tests, remaining limitations, and any guideline exceptions.

## Cross-platform rules

- **Hierarchy and navigation:** clear titles and destinations; predictable back/close behavior; standard tab bars, sidebars, navigation stacks, split views, inspectors, search, sheets and popovers. Don't turn every setting or reference into a permanent toolbar action.
- **Layout:** use flexible constraints, safe areas, margins, system spacing, adaptive columns, and readable content width. Avoid fixed screen-size assumptions and clipping under window controls, cameras, home indicators, or folds. Support small windows and large accessibility text.
- **Materials and appearance:** use platform-standard materials, semantic colors, SF Symbols where appropriate, and system control appearance (including contemporary Liquid Glass where the SDK and component support it). Don't recreate system chrome in custom views or use decorative material that reduces contrast.
- **Typography:** system text styles and Dynamic Type where applicable; clear heading levels, proper line length, text wrapping, locale-aware formatting, and sufficient contrast.
- **Input:** touch, pointer, keyboard, trackpad, Pencil, remote, voice, Digital Crown, eye/hand gestures as applicable. Never rely on hover, a gesture, a color, or an icon alone to disclose a critical action.
- **Accessibility:** VoiceOver and labels/traits, logical focus order, contrast, text enlargement, Reduce Motion, Increase Contrast, alternative interaction paths, hit targets, and accessible notifications/status. Test with assistive technologies.
- **Feedback:** immediate acknowledgement of actions, nonblocking loading/progress, useful empty/error states, cancellation, recovery, and confirmation for irreversible destructive actions. Preserve scroll/edit positions through resize, background/foreground, and window restoration.
- **Locale and direction:** longer translations, right-to-left layout, meaningful symbol mirroring, date/number conventions, and content-specific language selection.
- **Performance:** don't block UI during layout, indexing, downloads or heavy computation; minimize layout thrash and unnecessary animations; preserve responsiveness while multitasking.
- **Files and system:** use standard document pickers, share sheets, drag/drop, menus, clipboard, commands, Spotlight, Quick Look and platform integration only where relevant and authorized.

## Platform adaptations

### iPhone / iOS
- One clear primary task per compact screen; short paths to key actions, readable content, predictable gesture/back behavior, standard bottom/side controls as placed by the system.
- Safe areas, orientation, Dynamic Type, one-handed reachability, interruptions, keyboard appearance, and portrait/landscape resizing must work. Keep full functionality accessible if secondary controls overflow.
- Use compact navigation stacks/tabs rather than forcing desktop sidebars into narrow windows.

### iPhone Duo / iOS 27.1+
- **Still an iPhone**, not a new target or bespoke 'Duo mode'. Build with the appropriate modern SDK to take advantage of full-display resizing; preserve older deployment targets with availability gates.
- Outer display is generally compact-width; inner display can support regular-width navigation and multiple columns. Use *live size classes*, safe areas, and reserved regions; don't hard-code published pixel/point values or infer pose from device idiom/orientation.
- Opening, closing, partially folding, rotating, and Split View multitasking must retain draft content, playback/session state, navigation, selection, focus, and affordances. Never recreate data models on resize.
- The fold can create a **reserved central region**; avoid placing indivisible controls across it. Prefer adaptive NavigationSplitView, TabView, system sheets/menus and, where appropriate/available, split or overlay arrangement views. Keep navigation containers outside arrangements.
- System toolbars/tab bars can move to the **vertical edge** on the outer screen and inner landscape; inner portrait uses horizontal controls. Use toolbar groups, semantic symbols, system overflow, and visibility priority instead of fixed bar height, manual spacers, or hard-coded top/bottom placement. Respect asymmetry and camera/Dynamic Island regions.
- Review UIScreen.main / main-screen bounds, device-type branching, fixed frames, assumed portrait geometry, cached sizes, rigid orientation locks, custom chrome/overlays, and fixed-column layouts.
- Validate outer closed, inner open portrait/landscape, partially folded, tabletop/tent poses as available in simulator/device, and multitasking at intermediate widths. The app must preserve capability and work in progress during transitions.

### iPad / iPadOS
- Use resizable windows and multitasking; avoid full-screen-only assumptions. Expand hierarchy naturally with NavigationSplitView, sidebars and inspectors; collapse appropriately in narrow windows.
- Support keyboard shortcuts, command menus, trackpad/pointer, Apple Pencil for relevant workflows, drag-and-drop and selection. Preserve pane sizes, focus and window state where practical.
- Prefer content-first layouts and contextual inspectors over dense permanent controls. Test Stage Manager/window resizing, portrait/landscape, external displays and accessibility text.

### Mac / macOS
- Native menu bar with full command coverage, keyboard shortcuts, mouse/trackpad selection, contextual menus, undo/redo, search and standard multiwindow/document behaviors. Support resizable windows, full screen, multiple displays and window restoration.
- Use toolbars sparingly and support personalization/hide/show where useful. Keep critical information reachable in small windows; don't anchor essential controls at the bottom edge.
- Macs with touch input: keep desktop information density and pointer/keyboard efficiency, but use sufficiently large tappable targets and the system's touch-aware behavior for brief intentional interaction. Do not create a separate 'tablet Mac' layout.

### Touch on Mac — native macOS with direct touchscreen input (Xcode 27.3 beta and newer)

Apple's [Get ready for Touch on Mac](https://developer.apple.com/touch-on-mac/) and companion sessions [Design for Touch on Mac](https://developer.apple.com/videos/play/tech-talks/111456/) and [Bring Touch to your Mac app](https://developer.apple.com/videos/play/tech-talks/111468/) describe touch as **an additional input method for Mac apps**, not a reason to replace the desktop interface with an iPad interface.

- Prefer standard SwiftUI/AppKit controls: use their system touch behavior, including expansion of steppers, dials and sliders where supported. Preserve precise pointer, keyboard, hover and context-menu paths; reveal hover-only commands through touch-accessible alternatives.
- Audit custom controls and hit testing. Make targets comfortable for direct fingers while keeping visually compact Mac density; Apple illustrates an expanded **36-point minimum per axis** for custom touch hit regions in its sample, not a blanket minimum for every Mac control. Do not hardcode a universal 44-point iOS rule onto macOS.
- Replace custom mouse-event tracking loops with semantic control events or gesture recognizers when appropriate. For AppKit touch gestures, consider recognizers such as `NSPanGestureRecognizer` with `allowedTouchTypes = .direct`; preserve existing mouse and trackpad behavior.
- Support direct touch scrolling, tap, drag, selection and appropriate multitouch interactions. Explicitly decide gesture precedence with scroll views and system gestures; avoid disabling system gestures globally. Use touch-only gesture overrides and system-gesture suppression only for a narrowly justified interaction.
- Review touch drag/drop, scrolling vs drawing conflicts, zoom/pinch and text selection/caret handles where applicable. Provide discoverable non-gesture alternatives; don't assume touch input implies Apple Pencil support on macOS.
- **Touch-native declaration:** Apple documents `NSIsTouchNative` in Info.plist. Evaluate it after actual touch-specific implementation and validation; don't enable it merely to claim compatibility. Verify deployment and API availability before adoption.
- **Testing:** standard mouse/trackpad and keyboard; direct finger tap, scrolling, drag/drop, multitouch, system edge gestures, hover-only discovery, small custom targets, screen resizing, and accessibility. Record simulator/physical hardware coverage separately. Touch is optional and must not change the experience for non-touch Macs.

### Apple Watch / watchOS
- Glanceable, focused, short interactions; shallow navigation; Digital Crown, complications/widgets, notifications, Always On considerations and independence where relevant. No wholesale shrink of the phone UI.

### Apple TV / tvOS
- Distance legibility and safe margins, focus-engine navigation and clear focus state, Siri Remote/controller input, cinematic content, unobstructed overscan-safe primary UI, and fast back/exit behavior.

### Vision Pro / visionOS
- Start with comfortable windowed UI; introduce immersive elements only when valuable. Eye/hand input, large enough targets, spatial ergonomics, visual comfort, stable motion, and accessible alternatives. Avoid forced head/arm movement.

### CarPlay
- **Only supported app categories and Apple-provided templates.** Optimize short, low-distraction tasks and glanceability; let the car system adapt display size/input. Never require phone interaction while driving or build a freeform phone-style dashboard.

### Widgets, Live Activities and other surfaces
- Each is a focused glanceable surface, not a miniature copy of the app. Follow the surface's size, privacy, interaction and relevance constraints; use appropriate system APIs.

## Agent implementation workflow

1. **Audit:** produce a table per screen (platform, current component, violated principle, severity P0–P3, proposed replacement, evidence).
2. **Architecture:** select responsive containers and a state owner independent of size changes. Separate screen content, navigation, inspectors, and transient overlays.
3. **Implement:** small, independently reviewable changes; prefer existing APIs and dependency-free native components. Use availability checks for new APIs.
4. **Validate:** compile actual targets; run focused tests; exercise the matrix below. Record untested hardware-specific cases instead of claiming coverage.
5. **Review:** verify no clipped actions, excessive toolbar items, duplicated commands, lost focus/drafts, blocked loading, or divergence between keyboard/touch/assistive paths.

| Validation dimension | Minimum scenarios |
| --- | --- |
| Width and windowing | Narrow, medium, wide; live resize; foreground/background; multiple windows where supported |
| Duo | Closed/open, fold transitions, reserved center region, vertical/horizontal bars, split multitasking |
| Text and direction | Largest supported text, long localized strings, RTL, high contrast |
| Appearance | Light/dark, reduced transparency/motion, keyboard shown, sidebars/inspectors hidden/shown |
| Input | Touch on Mac (direct touch, scrolling, gesture conflicts, custom hit regions), mouse, keyboard-only, Pencil, focus/remote/Crown/eyes where supported |
| Safety | Cancel loading, undo, recovery after failure, offline/sync conflict, state restoration |

**Definition of done:** each supported platform remains familiar and fully usable; system-native controls and input paths work; layout does not depend on fixed screen geometry; no user work is lost on transitions; accessibility and localization pass; changes and exceptions are documented.

## Official sources (recheck regularly)

- [HIG index](https://developer.apple.com/design/human-interface-guidelines/)
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios)
- [iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [iPhone Duo preparation](https://developer.apple.com/iphone-duo/prepare/)
- [iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados)
- [macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Touch on Mac](https://developer.apple.com/touch-on-mac/)
- [Design for Touch on Mac](https://developer.apple.com/videos/play/tech-talks/111456/)
- [Bring Touch to your Mac app](https://developer.apple.com/videos/play/tech-talks/111468/)
- [watchOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-watchos)
- [tvOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-tvos)
- [visionOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos)
- [CarPlay](https://developer.apple.com/design/human-interface-guidelines/carplay)

Apple's HIG mixes principles, recommendations and API-specific behavior; this document is an engineering checklist, **not a claim that every recommendation is mandatory**, and optional platforms do not need to be added.
