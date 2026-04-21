---
title: Skill card plugin badge
date: 2026-04-21
status: draft
---

# Skill card plugin badge

## Problem

When a plugin bundles multiple skills (e.g., `youcoded-encyclopedia` bundles 5 skills: compile, update, interviewer, librarian, journaling), the CommandDrawer and LibraryScreen show every skill as its own card with a generic source tag — `YC`, `Plugin`, `Prompt`, or `Self`. The cards give no indication that several of them belong to the same plugin, and nothing on the card lets the user jump to the plugin's marketplace page to read about it, see siblings, or uninstall the whole plugin at once.

## Goal

Each skill card displays the name of the plugin it belongs to as a badge, and clicking that badge opens the plugin's existing marketplace detail overlay.

## Non-goals

- Grouping skills visually under per-plugin sections (earlier idea, dropped — flat list stays)
- Plugin-level favorites
- New marketplace detail UI — the existing `MarketplaceDetailOverlay` is already plugin-keyed (the `DetailTarget.kind: "skill"` naming is misleading; the overlay renders plugin info)
- Renaming `DetailTarget.kind` — cleanup unrelated to this feature
- Changing search behavior in the CommandDrawer — search continues to match individual skills (and plugin-typed entries) as it does today

## Design

### Badge content

The badge label on each skill card is the **marketplace `displayName`** of the plugin the skill belongs to — e.g., `"Encyclopedia"`, `"Civic Report"`, `"YouCoded Core"` — taken verbatim from the plugin's entry in the marketplace registry (`wecoded-marketplace/marketplace.json`).

For skills with no marketplace parent plugin (source `'self'`, or any skill whose `pluginName` can't be resolved against the marketplace registry), the existing source badge stays as it is today (`Self`, `Prompt`, or `Plugin`) and is **non-clickable**. No change for standalone skills.

The badge replaces the existing source badge on plugin-owned skills — we do not stack two badges on one card. Rationale: the plugin name subsumes the information the source tag was carrying (`youcoded-core` is now just "YouCoded Core" spelled out, `plugin` is now the actual plugin name), so one tag is strictly more informative and keeps visual density low.

### Badge click behavior

Clicking a plugin-name badge:

1. Closes the current surface if it's an overlay/drawer (CommandDrawer closes; LibraryScreen stays mounted since the marketplace is reachable from it).
2. Navigates to the Marketplace screen.
3. Opens `MarketplaceDetailOverlay` for the plugin, keyed by `{ kind: "skill", id: skill.pluginName }` (reusing the existing detail-target shape — the overlay already renders plugin-level info; only the routing naming is legacy).

Non-plugin badges (`Self`, `Prompt`, fallback `Plugin`) are plain text with no click handler.

### Where the badge appears

Both variants of `SkillCard` render the new badge:

- **Drawer variant** (CommandDrawer) — the existing bottom-of-card badge at `SkillCard.tsx:114-119` is replaced.
- **Marketplace variant** (LibraryScreen, MarketplaceScreen grid) — the existing top-right badge at `SkillCard.tsx:51-56` is replaced.

In the **MarketplaceScreen grid** itself, cards already *are* plugin cards (one card per plugin). The badge is technically redundant there but behaves consistently: it shows the plugin's own displayName and clicks open the same detail overlay (the card itself already opens the overlay, so the badge click is a no-op-equivalent path — still cheap to keep uniform across variants).

### Data flow

The skill card needs to know the plugin's marketplace `displayName`. Two paths considered:

- **A — Enrich SkillEntry at scan time.** The main process resolves `pluginName` → marketplace `displayName` when building SkillEntry objects, and adds `pluginDisplayName?: string` to the SkillEntry type. The renderer just renders `skill.pluginDisplayName ?? fallback`.
- **B — Look up in the renderer from a marketplace-registry context.** A context provider exposes a `pluginId → displayName` map; the card reads from it at render time.

**Chosen: A.** Matches the pattern already used by `skill-scanner.ts:49` (which titlecases pluginName as a fallback displayName today), keeps the card pure, avoids a new context subscriber on every skill card, and keeps the renderer working the same on desktop and Android (where the WebView has no direct access to the marketplace registry — the Android main side already does the scanning in Kotlin).

**Fallback:** If the marketplace registry hasn't loaded yet or the plugin isn't in it, `pluginDisplayName` is left `null` and the existing source-badge fallback renders instead. No blank badges.

### Cross-platform parity

The React UI is shared between desktop and Android. Both platforms' skill providers must populate the new `pluginDisplayName` field:

- Desktop: `desktop/src/main/skill-scanner.ts` / `skill-provider.ts` — look up in the marketplace-registry cache the main process already maintains.
- Android: `app/src/main/kotlin/com/youcoded/app/skills/LocalSkillProvider.kt` — same lookup, Kotlin side. The WebView receives the enriched JSON verbatim.

Message-type strings are unchanged (no new IPC surface). The change is additive on the SkillEntry payload — older clients that don't know the field simply ignore it.

## Success criteria

- CommandDrawer skill cards show the plugin's marketplace displayName (e.g., "Encyclopedia") instead of "YC" or "Plugin" when the skill belongs to a plugin in the marketplace.
- LibraryScreen Skills-tab cards show the same.
- Clicking the badge anywhere navigates to the Marketplace screen and opens the detail overlay for that plugin.
- Self-authored skills continue to show the `Self` badge, non-clickable.
- Android and desktop render identically — no parity drift.
- Search in the CommandDrawer continues to match individual skills as it does today.
