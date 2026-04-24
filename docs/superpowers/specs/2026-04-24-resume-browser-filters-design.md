# Resume Browser — Project / Tag / Sort Filters

**Status:** Draft
**Date:** 2026-04-24
**Scope:** `youcoded/desktop/src/renderer/components/ResumeBrowser.tsx` only — pure renderer change, no IPC, no main-process work, no Android-specific code.

## Problem

The Resume Session browser today supports a single text search and a "Show Complete" toggle. As Destin's session history grows across many project folders, finding a specific past session means scrolling through every project's group or guessing the right substring to type. There's no explicit way to narrow the list to a particular project, to surface flagged sessions only, or to flip the sort order.

## Goal

Add a filter row to the Resume Browser that lets the user explicitly:

1. Filter by **project** (any subset of the projects that have past sessions).
2. Filter by **tag** (Priority, Helpful — extensible to custom tags later).
3. Toggle the **sort direction** (most recent first ↔ oldest first).

All filters compose with the existing search bar and Show Complete toggle.

## Non-goals

- No persistence — every filter selection resets each time the browser opens.
- No new IPC protocol. Filters are derived from the already-loaded `PastSession[]`.
- No new tag concept. Tags == the existing `flags` field on `PastSession`. The filter exposes only `priority` and `helpful` for now; `complete` keeps its dedicated Show Complete toggle.
- No reorder of pre-existing controls (Show Complete stays on the title row; search bar shape unchanged).
- No Android-specific work — the React UI is shared, so the filter row appears on Android automatically.

## Layout

A new pill row sits between the search bar and the session list:

```
┌────────────────────────────────────────────────┐
│ Resume Session            Show Complete ⚪     │  ← title row (unchanged)
│ 🔍 Search sessions...                          │  ← search bar (unchanged)
│ ⟨ Projects ▾ ⟩ ⟨ Tags ▾ ⟩ ⟨ Most recent ↓ ⟩  │  ← NEW filter row
│ --- session list ---                           │
└────────────────────────────────────────────────┘
```

The pill row stays visible while searching (filters can be adjusted mid-search).

## Components

### Pill: Projects (multi-select dropdown)

- **Source of values:** `Array.from(new Set(sessions.map(s => s.projectPath)))` — distinct project paths from the loaded sessions. No `claude.folders.list()` call. The dropdown options are entirely derived from the conversation transcripts already on disk.
- **Display label per row:** last segment of the path (`projectPath.replace(/\\/g, '/').split('/').pop()`), matching the existing group-header convention.
- **Sort:** alphabetical by display label.
- **Dropdown contents:**
  - Top row: `All projects` — a "clear" affordance. Visually checked when `selectedProjects` is empty; clicking it empties the set (returns to "no project filter"). Does *not* set every project's checkbox to checked — the data model treats an empty selection as "filter inactive," so that distinction is invisible to the user.
  - One row per distinct project: checkbox + display label + parenthesized count of that project's sessions in the unfiltered set, e.g. `[✓] youcoded (12)`.
- **Trigger label states (left-to-right, fall through):**
  - 0 selected → `Projects` (muted style).
  - 1 selected → `youcoded` (active style).
  - 2–3 selected → comma-joined display labels: `youcoded, core, dev`.
  - 4+ selected → `Projects (5)`.
- **Filter semantics:** OR — a session is kept if its `projectPath` is in the selected set. When the selection is empty, the filter is inactive (no narrowing).

### Pill: Tags (multi-select dropdown)

- **Dropdown contents:** two checkboxes — `Priority` and `Helpful`. The list is built from a small array (`['priority', 'helpful']` — same `FlagName` type already in `ResumeBrowser.tsx`), so adding custom user-defined tags later is a list extension rather than an architectural change.
- **Trigger label states:**
  - 0 selected → `Tags` (muted style).
  - 1 selected → `Priority` or `Helpful`.
  - 2 selected → `Priority + Helpful`.
- **Filter semantics:** OR — a session is kept if `s.flags?.priority` or `s.flags?.helpful` is true (matching any of the selected tags). When the selection is empty, the filter is inactive.
- **Does not interact with `complete`.** Show Complete remains the sole control for revealing complete sessions, and the Tags pill never lists Complete.

### Pill: Sort (toggle, no dropdown)

- A single click flips the direction.
- Two states:
  - `Most recent ↓` — `lastModified` descending. Default.
  - `Oldest first ↑` — `lastModified` ascending.
- Affects both within-group ordering and between-group ordering, so groups don't shuffle out of sync with their contents.
- Priority pinning still wins. Priority sessions stay at the top of their group (or the top of the flat list, in search mode) regardless of sort direction. The sort applies only among non-priority sessions and to the relative order of groups.

### Pill visual treatment

- All three pill triggers use the inset-style frame already in the file (`bg-inset` + `border border-edge-dim`, matching the search input).
- Inactive pill trigger: `bg-inset` border `border-edge-dim`, label `text-fg-muted`.
- Active pill trigger (any non-default state): `bg-accent/10` border `border-accent/40`, label `text-fg`.
- Dropdown panels for Projects and Tags are anchored popovers (no scrim — clicking outside dismisses, like `FolderSwitcher`). They use the `.layer-surface` class directly, which already pulls theme-driven background, border, shadow, and glassmorphism from the overlay tokens. This matches the convention in `docs/shared-ui-architecture.md` → "Overlay Layer System": "anchored popovers that don't need a scrim (dropdowns, context menus, info tooltips), use `.layer-surface` class directly."

## Data flow

State added to `ResumeBrowser`:

```ts
const [selectedProjects, setSelectedProjects] = useState<Set<string>>(new Set());
const [selectedTags, setSelectedTags] = useState<Set<FlagName>>(new Set());
const [sortDir, setSortDir] = useState<'desc' | 'asc'>('desc');
```

All three reset to their defaults whenever `open` transitions to `true` (matching the existing pattern that resets `search`, `expandedId`, etc. in the open-effect at `ResumeBrowser.tsx:100-116`).

The filter pipeline runs in the existing `filtered` and `grouped` / `flatSorted` `useMemo`s:

1. **`base`** (existing): apply Show Complete + stickyComplete.
2. **Project filter (new):** if `selectedProjects.size > 0`, drop sessions whose `projectPath` isn't in the set.
3. **Tag filter (new):** if `selectedTags.size > 0`, drop sessions where none of the selected flags is true.
4. **Search (existing):** substring match on `name` or `projectPath`.
5. **Group/flat (existing, sort-aware):**
   - Grouping condition is unchanged: when search is empty, group by `projectPath`; when search has text, render flat.
   - Within-group sort: priority first, then `lastModified` in `sortDir` direction.
   - Between-group sort: groups ordered by the newest session in each group when `sortDir === 'desc'`, by the oldest when `sortDir === 'asc'`.
   - Flat-search sort: priority first, then `lastModified` in `sortDir` direction.
6. **Single-project edge case:** when exactly one project is selected and search is empty, the grouped view still renders with its (one) project header. Consistency over visual saving.

## Interactions

- **Filters compose with everything as AND:** a session must pass Show Complete, Projects, Tags, and search to be visible.
- **The filter row stays visible during search.** No collapsing.
- **Reset on each open** (no localStorage). Aligns with edge-case 1 from brainstorming and avoids the "where did my sessions go" surprise.

## Components / files touched

Single file: `youcoded/desktop/src/renderer/components/ResumeBrowser.tsx`.

Internal additions:

- A small `<FilterPill>` helper component for the pill trigger button (shared shape across the three pills, plus an `active` boolean for styling).
- Two dropdown panels (Projects and Tags) rendered relative to their pill triggers via `<OverlayPanel layer={2}>`. Outside-click and ESC close them, mirroring the existing `FolderSwitcher` pattern.
- New `useMemo` for `availableProjects` (distinct projectPaths + counts).
- Extended `filtered` / `grouped` / `flatSorted` `useMemo`s to apply the new filters and respect `sortDir`.

No additions to `preload.ts`, `remote-shim.ts`, `ipc-handlers.ts`, or `SessionService.kt`.

## Testing

- Unit tests for the filtering logic (pure functions extracted if practical, or via a small React Testing Library suite that drives the component).
  - All-projects-selected behaves identically to no-selection (filter inactive).
  - Project filter with one selection produces only that project's sessions.
  - Tag filter with `priority` selected returns only priority sessions; with both, returns priority OR helpful.
  - Sort flip reverses both within-group and between-group order; priority pin survives the flip.
  - Filters AND with search and Show Complete.
  - Single-project filter still renders the group header.
- Manual: open the browser, verify pill row appears, exercise each pill, combine with search and Show Complete.

## Out of scope (future work)

- Custom tag strings (the Tags pill is shaped to absorb them later by extending the source array; no UI rewrite needed).
- Persisting filter selection across opens (deferred — current decision is reset-on-open).
- Saving filter "presets" or pinning a default filter to the user's profile.
- Complete-tag filter unification with the Show Complete toggle.
