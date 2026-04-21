---
title: Drawer and marketplace polish plus plugin grouping
date: 2026-04-21
status: draft
supersedes: 2026-04-21-skill-card-plugin-badge-design.md
---

# Drawer and marketplace polish plus plugin grouping

## Problem

The recent favorite-toggle addition (`FavoriteStar + InstallingPill primitives`, `card star + installing pill`) introduced several regressions and gaps in the CommandDrawer and Marketplace UIs:

- CommandDrawer tiles are no longer uniformly sized — previously the grid was perfectly regular, now tile heights vary because the FavoriteStar was added via an outer wrapper `div` that distorts the flex layout.
- There's no favorite star on tiles that aren't installed yet — but there's also no obvious affordance to install one from the grid; users have to click through the detail overlay.
- The `Installed` badge sits in a position where it's visually occluded by the floating favorite star rather than reading alongside it.
- Integrations render through a separate `IntegrationCard` component with a horizontal layout that doesn't match the rest of the marketplace grid, and they don't use the shared click-to-expand detail overlay.

Separately, the browse views in all three surfaces (CommandDrawer, Marketplace, Library) currently flatten plugins into individual skill cards — a plugin that bundles 5 skills produces 5 tiles. This clutters the grids and makes it hard to discover that those skills are siblings. The ask is to group installed skills/commands under their parent plugin in browse, while keeping search in the CommandDrawer mixed (matches can be individual skills OR whole plugins).

## Goal

Fix the recent layout regressions, add a floating install affordance on marketplace tiles, unify integrations into the shared card component, and restructure the browse grids so each plugin renders as one card (with search as the exception in the CommandDrawer).

## Non-goals

- Plugin-level favorites (favorites remain skill-level, but a plugin card's star favorites the plugin-as-a-whole — see Design §5 for what that means in terms of what's stored)
- Renaming `DetailTarget.kind: "skill"` — legacy naming, unrelated cleanup
- Changes to the marketplace install flow itself (plugin-installer, registries) — only the tile affordance changes
- Theme changes beyond card layout
- The earlier plugin-name-badge design (committed as `2026-04-21-skill-card-plugin-badge-design.md`) is subsumed by grouping: once each card IS a plugin, there's no separate plugin-name badge needed. That spec is marked superseded.

## Design

### 1. Tile sizing regression fix

The drawer variant of `SkillCard` becomes `position: relative` directly (rather than being wrapped by a `relative` div in `CommandDrawer.renderDrawerCard`). `FavoriteStar` and the new install-icon primitive (§2) render as absolutely-positioned children *inside* the `SkillCard` button element, not as siblings outside it. This restores the uniform flex-grid sizing the drawer had before the recent commit.

The `CommandDrawer.tsx` wrapper div introduced in commit `90a2b93` is removed; the favorite star is moved into `SkillCard` itself, gated by a prop (`showFavorite?: boolean`) so the card stays reusable in contexts that don't want a star overlay.

Same treatment for the marketplace variant — the star is an absolutely-positioned child of the card root.

### 2. Marketplace install icon state machine

Each marketplace tile has a single corner slot (top-right, the same coordinates `FavoriteStar` uses today). The slot renders one of three states based on the plugin's install status:

1. **Not installed** — a download-arrow icon button (e.g., `↓` or `⬇` — whatever the existing icon set provides). Clicking it kicks off `window.claude.skills.install(id)`.
2. **Installing** — a braille-spinner animation (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏` cycling) replaces the icon. Non-interactive during this state.
3. **Installed** — becomes a `FavoriteStar`, defaulting to **unfavorited**. User clicks again to favorite.

All three variants live in the same corner coordinate; swapping between them does not shift adjacent content. Lives in a new primitive `components/marketplace/InstallFavoriteCorner.tsx` that encapsulates the state machine. `MarketplaceCard` renders this primitive; `SkillCard` (drawer variant) renders only `FavoriteStar` directly since items in the drawer are always installed.

The install state is read from the same data the existing `installed` prop uses. The "installing" phase is tracked via the existing in-flight install map (already used by `InstallingPill` — read but not re-implemented here).

### 3. `Installed` badge placement

Today the `Installed` badge sits near the bottom of the card (`SkillCard.tsx:74-89`). On marketplace tiles where the star overlays the top-right, the badge reads as being "hidden behind" because the star visually dominates the corner. The fix:

- Keep the badge where it is (bottom-of-card, below the "Get" button slot), but ensure z-ordering places it on top of anything that might overlap.
- For multi-slot plugin cards (grouped plugins with multiple skills), the same `Installed` badge renders — it's a plugin-level badge, indicating the plugin itself is installed (regardless of how many skills it bundles).

No change to badge visual style — purely a layout/z-order correction.

### 4. Integrations parity

Retire `IntegrationCard` as a separate visual component. Integration tiles render via the standard `MarketplaceCard` with two additional props:

- `iconUrl?: string` — optional external (raw.githubusercontent) URL for a custom brand icon, currently only used by integrations. MarketplaceCard renders it in a top-left badge when present.
- `accentColor?: string` — optional border accent, applied via the existing `style={{ borderColor }}` pattern from `IntegrationCard.tsx:54`.

The integrations rail in `MarketplaceScreen.tsx:252-270` stays as a dedicated rail (integrations are a first-class category), but the cards themselves are now standard plugin cards. Clicking an integration tile opens `MarketplaceDetailOverlay` with the same `{ kind: "skill", id }` shape as every other plugin. The overlay already handles "What's inside" — no new detail UI for integrations.

### 5. Plugin-level grouping in browse views

**Data source change.** `marketplace-context.tsx` currently exposes `installedSkills` and `skillEntries` as flattened per-skill lists. We add **plugin-grouped** views:

- `installedPlugins: PluginEntry[]` — one entry per installed plugin, including a `skills: SkillEntry[]` field listing the bundled skills
- `marketplacePlugins: PluginEntry[]` — one entry per marketplace plugin, with a `skills: SkillEntry[]` field

The existing per-skill arrays remain for search and other call sites that still need them, but browse grids switch to the plugin-grouped arrays.

**Consumers:**

- **Marketplace grid** (`MarketplaceScreen.tsx`): iterates `marketplacePlugins` instead of `skillEntries`. One card per plugin.
- **Library Skills tab** (`LibraryScreen.tsx`): iterates `installedPlugins`. One card per plugin.
- **CommandDrawer browse** (`CommandDrawer.tsx`): iterates `installedPlugins`. One card per plugin.

**Card contents (all three surfaces):** Plugin `displayName`, plugin `description`, and a compact row of skill-name chips showing what's bundled inside (borrowed from the earlier badge-spec idea). Single-skill plugins show no chip row — the card is functionally a single-skill card.

**Click behavior in browse:**

- **Marketplace and Library** — click card → opens `MarketplaceDetailOverlay` with `{ kind: "skill", id: plugin.id }`. The overlay's existing "What's inside" section lists the bundled skills with their descriptions; clicking a skill there runs whatever it runs today (the existing overlay behavior is unchanged).
- **CommandDrawer** — click card has a split behavior:
  - Single-skill plugin: click invokes that skill immediately (same as today for a single-skill tile).
  - Multi-skill plugin: click invokes the plugin's **prompt** (its `prompt` field from `marketplace.json`, e.g. `/civic-report`) when one is defined. If no plugin-level prompt exists, the click opens `MarketplaceDetailOverlay` inline over the drawer so the user can pick a specific skill.
  - A skill chip in the card is independently clickable: click a chip → invoke that specific skill. Stops propagation so it doesn't also trigger the card click.

**Favorites on grouped plugin cards:** The favorite star on a plugin card favorites the **plugin as a whole**. Storage: the existing favorites mechanism already accepts a plugin ID (see existing `setFavorite` call sites that accept either skill ID or plugin name, per earlier research). No new storage; just wire the plugin card's star to the plugin ID.

### 6. CommandDrawer search exception

When the user is in the drawer's search mode, the result list is **mixed**: matches can be individual skills OR whole plugins, in whatever rank order the search scorer produces.

- Query matches a plugin's `displayName` or `description` → plugin card appears in results.
- Query matches an individual skill's `displayName` or `description` → skill card appears in results (even if its parent plugin also matched — both show).

Implementation: the search filter walks both the flattened `skillEntries` list and the `marketplacePlugins` list, returning a mixed array tagged by entry type so the renderer picks the right card component. In practice this is one pass over each list with `.filter()` and concatenation; the renderer switches on an `entry.kind` discriminator.

Search results render with the same tile styling as browse; they just aren't grouped.

## Data model additions

- `PluginEntry` type: `{ id, displayName, description, category, source, prompt?, iconUrl?, accentColor?, skills: SkillEntry[] }` — lives alongside `SkillEntry` in `desktop/src/shared/types.ts`.
- `installedPlugins` and `marketplacePlugins` selectors in `marketplace-context.tsx` — derived from existing data (group-by `pluginName` on the flattened lists, enriched with registry metadata).

## Cross-platform parity

The React UI is shared between desktop and Android. Both platforms' skill providers already return SkillEntry shapes that include `pluginName`; no new IPC surface is required. Grouping is derived on the renderer from the existing data; the main-side provider doesn't need to change.

The braille-spinner install state uses client-side animation driven by the existing in-flight install tracking — no new IPC event.

## Success criteria

- CommandDrawer tiles are uniformly sized, matching their pre-regression layout. Favorite star floats in the top-right without affecting tile height.
- Marketplace tiles show a download-arrow icon in the top-right when not installed; clicking starts install; the icon cycles through a braille spinner during install; on completion the slot becomes an unfavorited `FavoriteStar`.
- `Installed` badge renders fully visible on marketplace tiles, not occluded by the favorite star.
- Integrations render with the same vertical card styling as other plugins, keep their custom icon and accent color, and open the same `MarketplaceDetailOverlay` on click.
- Marketplace grid, Library Skills tab, and CommandDrawer browse all show one card per plugin.
- CommandDrawer search returns a mixed list of individual skills and whole plugins.
- Android and desktop render identically — no parity drift.
