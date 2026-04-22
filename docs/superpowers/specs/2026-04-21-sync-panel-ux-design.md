---
title: Sync panel UX fixes
date: 2026-04-21
status: draft
---

# Sync panel UX fixes

## Problem

The sync management UI surfaces several pieces of information that are confusing, contradictory, or visually mismatched with their actual interactivity:

1. **Raw OS strings leak.** `SyncPanel.tsx:716` renders the secondary line `from {platform} · toolkit {version}` using values written by `sync-service.ts:2063` directly from `process.platform`. The user sees `from win32 · toolkit unknown` rather than something legible.
2. **"unknown toolkit" fallback bleeds through.** When `toolkit_root` is empty or the VERSION file is unreadable, `sync-service.ts:2054` writes the literal string `'unknown'`, which surfaces as "toolkit unknown" in the panel even on healthy syncs. The toolkit is also being deprecated, so the field has no forward value.
3. **Status reads "Synced" while warnings are active.** Two independent derivations disagree:
   - The compact "Sync" row in the settings panel (`SyncPanel.tsx:222-228`) computes its dot color from `lastSyncEpoch` + `syncInProgress` only — warnings are ignored.
   - The per-backend dots in the popup (`SyncPanel.tsx:617-629`) ARE warnings-aware.
   Result: header reads "Last synced 3m ago" with a green dot while the expanded view shows red warnings.
4. **Status bar widget renders one pill per warning.** `StatusBar.tsx:820` maps every warning to its own pill, so 3 warnings produce 3 pills crammed into the status bar with detailed warning copy that isn't readable at that size.
5. **"Synced Data" tiles look clickable but aren't.** `SyncPanel.tsx:789-805` renders categories (Memory, Conversations, Encyclopedia, Skills, System Config, Plans, Specs) as bordered chips with `cursor-help`. The styling and cursor promise interactivity that doesn't exist — detection is filesystem-based (`sync-state.ts:403-425`); the tiles are pure information.

## Goal

Resolve the five issues above with a focused UI-only pass:

- Remove the OS/toolkit metadata line from the panel.
- Centralize sync-status derivation so the compact row, status bar pill, and per-backend dots are mathematically incapable of disagreeing.
- Collapse the status bar widget to at most one pill, with copy that escalates by severity.
- Restyle the "Synced Data" tiles so their visual affordance matches their actual (read-only) behavior.

## Non-goals

The following are explicitly **deferred to separate sessions** and must not be touched in this implementation:

- Renaming "Sync" → "Backup" anywhere in the UI.
- Removing or consolidating the per-backend "Upload" / "Download" buttons.
- Single-click bidirectional sync (push + pull in one click).
- Dropping `--ignore-existing` on conversation pulls or any other change to actual sync engine behavior.
- Deletion propagation across devices.
- Field-level merge for `settings.json` or other multi-writer config.
- Anything that changes what the existing `Sync Now`, `Upload`, or `Download` buttons actually do under the hood.

These are real engineering projects that the user wants speced and implemented separately. Touching them here would either silently break workflows (if labels imply behavior we haven't built) or expand scope beyond a UI cleanup.

## Design

### 1. Remove the OS/toolkit metadata line

In `SyncPanel.tsx:714-718`, delete the entire conditional block that renders `from {platform} · toolkit {version}` under the "Last synced…" caption inside the Sync Now bar. The secondary line goes away entirely; no replacement.

`backup-meta.json` continues to store `platform` and `toolkit_version` fields (cheap, occasionally useful for diagnosing a backup file by hand). The writer at `sync-service.ts:2054-2063` is unchanged. The render layer simply stops surfacing those fields.

No platform-string mapping helper is introduced. No "unknown toolkit" fallback handling is needed. The line is gone, so the values it would have rendered no longer matter.

### 2. Centralized status derivation

Introduce a single helper — `deriveSyncState(status: SyncStatus, scope?: { backendId: string }): SyncDisplayState` — that returns one of six states. Both the panel-wide compact row and per-backend dots in the popup call this same helper. The status bar pill (Section 3) consumes a subset.

```ts
type SyncDisplayState =
  | { kind: 'unconfigured' }
  | { kind: 'syncing' }
  | { kind: 'failing'; warningCount: number }
  | { kind: 'attention'; warningCount: number; lastSyncEpoch: number | null }
  | { kind: 'synced'; lastSyncEpoch: number }
  | { kind: 'stale'; lastSyncEpoch: number };
```

Resolution order, top-down (first match wins):

| State | Trigger | Dot color | Compact-row label |
|---|---|---|---|
| `unconfigured` | no backends configured (or, when scoped, the backend doesn't exist) | grey | "Not configured" |
| `syncing` | `status.syncInProgress === true` | blue, pulsing | "Syncing…" |
| `failing` | any warning with `level: 'danger'` (filtered to `backendId` when scoped) | red | "Sync Failing" |
| `attention` | only warnings with `level: 'warn'` | green | "Last synced Xm ago" + small amber pill with warning count |
| `synced` | no warnings, `lastSyncEpoch` within 24h | green | "Last synced Xm ago" |
| `stale` | no warnings, `lastSyncEpoch` ≥ 24h old (or never) | yellow | "Last synced Xm ago" or "Never synced" |

Severity comes from the existing `level: 'danger' | 'warn'` field on `SyncWarning`. No data-shape changes are required. The danger codes are already the push-failure family (`AUTH_EXPIRED`, `QUOTA_EXCEEDED`, `NETWORK`, `RCLONE_MISSING`, `UNKNOWN` push-path) plus `OFFLINE` and `PERSONAL_STALE`. The warn codes are housekeeping (`SKILLS_UNROUTED`, `PROJECTS_UNSYNCED`, `PERSONAL_NOT_CONFIGURED`).

The helper lives in `desktop/src/renderer/state/sync-display-state.ts` (new file) so it is unit-testable in isolation and reusable by the status bar (Section 3). It does NOT live in `desktop/src/main/sync-state.ts` — that file is a Node-only module, and the helper has to be importable from React.

Replace `SyncPanel.tsx:222-228` (compact-row dot derivation) and `SyncPanel.tsx:617-629` (per-backend dot derivation) with calls to the helper. Replace the compact-row label assembly at `SyncPanel.tsx:242-260` with rendering driven off the returned state.

### 3. Status bar widget: at most one pill

Replace the per-warning map at `StatusBar.tsx:819-831` with a single derived pill driven by `deriveSyncState`:

```tsx
{show('sync-warnings') && (() => {
  const state = deriveSyncState({ warnings: syncWarnings ?? [], /* … */ });
  if (state.kind !== 'failing' && state.kind !== 'attention') return null;
  const isFailing = state.kind === 'failing';
  return (
    <button
      onClick={onOpenSync || onRunSync}
      className={`px-1.5 py-0.5 rounded-sm border text-[9px] sm:text-[10px] ${
        isFailing ? warnStyles.danger : warnStyles.warn
      } cursor-pointer hover:brightness-125 transition-all`}
    >
      {isFailing ? 'Sync Failing' : 'Sync Warning'}
    </button>
  );
})()}
```

Rules:

- Render exactly **zero or one** pill, never more.
- `failing` → red pill labeled **"Sync Failing"**.
- `attention` → orange/amber pill labeled **"Sync Warning"**.
- All other states (`unconfigured`, `syncing`, `synced`, `stale`) → no pill at all.
- Click → existing `onOpenSync` handler. The full descriptive copy lives in the panel; the status bar pill is just a beacon.

The widget's `id`, `label`, and `description` in the WIDGETS catalog at `StatusBar.tsx:279-283` stay as-is — the user-facing widget toggle still says "Sync Warnings."

### 4. "Synced Data" tile affordance

Replace the chip cluster at `SyncPanel.tsx:789-805` with a single inline read-only sentence:

```tsx
{status && status.syncedCategories.length > 0 && (
  <div>
    <span className="text-[10px] font-medium text-fg-muted tracking-wider uppercase">Includes </span>
    <span className="text-[11px] text-fg-dim">
      {status.syncedCategories.map(cat => (
        <span key={cat} title={CATEGORY_DESCRIPTIONS[cat] || ''}>
          {CATEGORY_LABELS[cat] || cat}
        </span>
      )).reduce((acc, el, i) => i === 0 ? [el] : [...acc, ' · ', el], [] as React.ReactNode[])}
    </span>
  </div>
)}
```

- Drop the chip border, the bordered container, and `cursor-help`.
- Default cursor everywhere — no interactivity affordance.
- Items are joined by ` · ` separators within a single line; the list wraps naturally.
- Per-item tooltips via `CATEGORY_DESCRIPTIONS` stay (each item gets a `title` attribute), but the default cursor stays. Tooltips on plain text with a default cursor don't promise interactivity the way `cursor-help` did — they're a passive "extra info on hover" affordance that matches the read-only nature of the list.

## Implementation surface

| File | Change |
|---|---|
| `desktop/src/renderer/state/sync-display-state.ts` (new) | `deriveSyncState()` helper + `SyncDisplayState` type |
| `desktop/src/renderer/components/SyncPanel.tsx` | Remove platform/toolkit line; replace compact-row + per-backend dot derivation with helper; replace tile chips with inline list (tooltips retained, chips removed) |
| `desktop/src/renderer/components/StatusBar.tsx` | Replace `warnings.map(...)` block at line 819-831 with single derived pill |
| Tests (new) | Unit tests for `deriveSyncState` covering all six state branches and the warning-severity precedence rules |

No changes to:

- `desktop/src/main/sync-service.ts` (writer-side platform/toolkit fields stay)
- `desktop/src/main/sync-state.ts` (`SyncWarning` shape, push/pull behavior)
- `desktop/src/main/preload.ts` or `desktop/src/renderer/remote-shim.ts` (no IPC changes)
- Android `SessionService.kt` (no IPC changes)

Because no IPC surface changes, no `cc-dependencies.md` update is needed and no Android parallel work is required for this spec. The shared React UI picks up the new derivation on Android automatically.

## Testing

Unit tests for `deriveSyncState` covering:

- No backends → `unconfigured`.
- `syncInProgress === true` overrides everything else (even with active warnings).
- Mixed danger + warn warnings → `failing` (danger wins).
- Only warn warnings + recent sync → `attention` with warning count.
- No warnings + sync within 24h → `synced`.
- No warnings + sync older than 24h → `stale`.
- Scoped-to-backendId mode filters warnings by `backendId` field before classifying.

Manual verification:

- Open the settings panel with no warnings present → compact row is green and reads "Last synced Xm ago"; status bar shows no sync pill.
- Trigger a `PROJECTS_UNSYNCED` (warn) state → compact row stays green with amber count badge; status bar shows orange "Sync Warning" pill; clicking the pill opens the sync panel.
- Trigger an `AUTH_EXPIRED` (danger) state → compact row turns red with "Sync Failing"; status bar shows red "Sync Failing" pill.
- Trigger BOTH a danger and a warn warning → both surfaces show the danger state (red, "Sync Failing"); only the worst severity surfaces.
- Open the popup with multiple backends, only one of which has a danger warning → that backend's dot is red; others reflect their own scoped state.
- Confirm the platform/toolkit line is gone from the Sync Now bar in the popup.
- Confirm the "Synced Data" section renders as `Includes memory · conversations · encyclopedia · skills · system config · plans · specs` with no chip borders and no `cursor-help`.

## Out-of-scope follow-ups

These are noted here so they aren't lost when the engine work is taken up in a later session:

- The "Sync" terminology assumes future work will make the system truly bidirectional. Until then, "Sync Now" still does a one-direction push with mtime-aware `--update`.
- "Upload" and "Download" buttons remain as-is despite their overlap with "Sync Now."
- Conversation pulls still skip files that exist locally (`--ignore-existing`), so cross-device conversation propagation is incomplete.
- Deletion propagation across devices is not implemented.
- `settings.json` and similar multi-writer config files do not field-merge.
