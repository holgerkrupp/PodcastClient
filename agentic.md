# Agentic integration, Siri, Apple Intelligence and App Intents

Last reviewed: 2026-11-11. **Application-neutral guidance for coding agents.** This file documents architecture and review criteria; it is **not** an Apple `SKILL.md` or a deployable skills bundle. Apply only to supported platforms and OS/SDK versions. Read [hig.md](hig.md) for UI conventions.

## Design goal

Make meaningful app content and actions usable through **Siri, Apple Intelligence, Shortcuts, Spotlight and other system experiences** without bypassing permissions, user confirmation, data integrity, or normal app behavior. The app must remain fully useful without AI or Siri.

## Required agent workflow

1. **Discover:** inventory user-recognizable domain entities, actions, search queries, current App Intents, Spotlight integration, deep links, permissions, sharing and UI routes. Identify the top 3–5 useful external workflows, not every internal function.
2. **Model:** define stable `AppEntity` IDs and `EntityQuery`/string-query resolution, clear `AppIntent` parameters, localization, disambiguation and structured results. Reuse the existing domain commands and storage; don't duplicate business logic in an intent.
3. **Integrate:** evaluate App Shortcuts, relevant App Schema domains, `IndexedEntity`/Spotlight, `Transferable`, onscreen entity context, entity/action donations, snippets and open-in-app routes. Add only capabilities justified by user value.
4. **Compose:** build single-purpose **tool intents** first; for complex Siri AI workflows, add narrowly scoped **app skills** that explain how to combine them, which tools to prefer, what to avoid and when to clarify.
5. **Protect:** enforce authorization, entity ownership, scope, explicit confirmations for destructive or sensitive actions, idempotency, cancellation and stale-reference handling in code. Treat skill instructions as advisory, never as security enforcement.
6. **Validate:** unit/integration tests for intents, queries, domain mutations and privacy; Shortcuts and Spotlight tests; Siri AI real-device evaluation when available. Record unsupported devices and preview limitations.

## App Intents architecture

- **Entities:** stable durable IDs, meaningful names, concise display representations, current permissions, and efficient queries. Don't expose hidden/private records merely because they exist in storage. Consider `SyncableEntity` when IDs really remain stable across devices.
- **Actions:** one focused `AppIntent` per meaningful user operation. Use typed parameters, clear summaries and result types, sensible defaults, useful errors, and a direct route to the affected object. Support background execution only when safe; foreground continuation when interaction is necessary.
- **Schema domains:** adopt matching system App Schemas for actions and entities, including related use-case groups when required. Do not misrepresent the app's domain to gain Siri discoverability.
- **Discovery:** index appropriate entities with `IndexedEntity` and Spotlight; update/remove stale records on changes, deletion and permission revocation. Use semantic discovery when supported, without treating indexing as a permission bypass.
- **Context and transfer:** consider `Transferable`, `IntentValueRepresentation`/queries, and view or `NSUserActivity` entity association for references such as “this item.” Provide only the relevant, accessible onscreen content.
- **Donations:** donate meaningful actions/entities for suggestions, respecting user privacy and system controls; avoid noisy blanket donations.
- **Shared architecture:** intents, UI, widgets and external entry points call the same authorized domain layer. Recheck scope/permissions at execution, not only at entity-query time.
- **Reliability:** support offline behavior, missing/stale entities, duplicate invocations, interrupted workflows, sync conflicts and cancellation. Use idempotent operations or explicit confirmation for repeat-sensitive changes.
- **Localization/accessibility:** user-facing titles, prompts, errors, summaries and responses are localized; no voice-only essential workflow.

## App skills for multi-step Siri AI orchestration (developer preview)

Apple's [Orchestrating complex actions with app skills](https://developer.apple.com/documentation/appintents/orchestrating-complex-actions-with-app-skills) explains that Siri AI may use multiple tool intents and entities. An **app skill supplies guidance, not executable code and not a guaranteed sequence**. It cannot enforce deterministic behavior, permissions or confirmations.

### Packaging contract

- After implementing the relevant tool intents, create **one `Skills.skillsbundle` per app target** using Xcode's Skills Bundle template; include it in the target's **Copy Bundle Resources**. Don't create one just to satisfy this guidance.
- Layout: `Skills.skillsbundle/Skills/<skill-name>/SKILL.md`. Each skill folder contains **only** `SKILL.md`. Skill names must be unique across the app, its extensions and embedded frameworks.
- Each skill has YAML frontmatter with **`name`** (required, 1–64 lowercase letters/digits/hyphens, no leading/trailing hyphen or double hyphen, matches directory) and **`description`** (required, one line, max 1,024 characters).
- Body: Markdown, **at most 10,000 characters**. Describe intent selection, sequence preferences, disambiguation, domain-specific constraints, clarification, recovery and safety. Refer to tools by their purpose rather than hard-coded Swift type names. Don't repeat intent metadata.
- Siri AI reads metadata to match a request and reads the body when the skill is selected. Skills can guide but cannot force Siri to execute a prescribed series of steps.
- Xcode validates and compiles skills into the app; check build diagnostics. The **Siri AI Developer Preview** is limited to Apple Intelligence-capable devices and supported OS releases, and APIs/behavior may change.

### Generic example (illustrative only; not a shipped skill)

```markdown
---
name: organize-items
description: Helps organize existing items into a collection and checks the result.
---
Find the intended collection and items first. If multiple results match, ask
which ones the person means. Prefer moving existing items rather than creating
duplicates. Explain any inaccessible items. Before a destructive replacement,
request confirmation through the app's supported action. After applying changes,
retrieve the updated collection and report what succeeded or failed.
```

## Safety boundaries

- **Read-only vs writes:** prefer read-only lookup and previews first. Mutations must respect the same authorization and undo/recovery as in-app edits.
- **Shared/sensitive objects:** evaluate `OwnershipProvidingEntity` and ownership-aware confirmation where supported; do not leak another collaborator's private content. Never rely on skill text alone for a security boundary.
- **Destructive or irreversible actions:** explicit confirmation and an app-level safe path; no implicit mass deletion, publishing, payment or external transmission. For high-risk operations, open the app for review.
- **Cross-app workflows:** pass only required content, check access and consent, and clearly communicate transfers. Don't claim autonomous access to arbitrary apps or files.
- **Agentic limits:** a skill is orchestration *guidance*, not a background autonomous agent, persistent planner, general-purpose MCP server or guarantee of Siri availability. Additional integrations need their own product/security decisions.

## Acceptance checklist

- [ ] User-value workflow inventory and a platform/OS capability matrix exist.
- [ ] Each exposed action has a typed intent, domain-backed entity resolution, useful results and error handling.
- [ ] Privacy/ownership, cancellation, duplicate invocation and destructive confirmation tests pass.
- [ ] Spotlight, Shortcuts, Siri, onscreen context and cross-app transfer are tested only where implemented.
- [ ] Each app skill maps to real, implemented tool intents and compiles with a valid skills bundle.
- [ ] Siri AI skill testing uses a **physical supported device** (or internal TestFlight); vary phrasing, foreground/background context, ambiguous entities and multi-step requests. Use Siri evaluations where available. Simulator-only results are not proof of skill execution.
- [ ] No new target, entitlement, extension, permission or feature was added solely because this guide mentions it.

## Apple documentation

- [App Intents](https://developer.apple.com/documentation/appintents)
- [Getting started with App Intents](https://developer.apple.com/documentation/appintents/getting-started-with-the-app-intents-framework)
- [Apple Intelligence and Siri AI](https://developer.apple.com/documentation/appintents/apple-intelligence-and-siri-ai)
- [Orchestrating complex actions with app skills](https://developer.apple.com/documentation/appintents/orchestrating-complex-actions-with-app-skills)
- [Making actions and content discoverable by Apple Intelligence](https://developer.apple.com/documentation/appintents/making-actions-and-content-discoverable-by-apple-intelligence)
- [Providing contextual cues to Apple Intelligence and Siri](https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri)
- [App Intents updates](https://developer.apple.com/documentation/updates/appintents)
- [WWDC26: Build intelligent Siri experiences with App Schemas](https://developer.apple.com/videos/play/wwdc2026/240/)

This guide is intentionally reusable across apps. Product-specific intent/entity inventories, skill definitions, authorization and workflow priorities belong in each app's own implementation issues and source.
