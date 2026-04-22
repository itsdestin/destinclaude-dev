# Update Panel Popup — Design

**Date:** 2026-04-21
**Scope:** Desktop renderer + main. Android touched only for IPC-parity invariant.
**Problem:** The status-bar version pill currently either opens a platform-specific installer URL in the user's browser (when an update is available) or opens `CHANGELOG.md` on GitHub (when up to date). Both destinations are outside the app. We want an in-app popup that shows the changelog and lets the user kick off the same download flow from inside YouCoded.

## Goals

- Clicking the version pill opens an in-app popup (not a browser).
- When an update is available: popup shows the changelog entries *since the user's current version* plus an "Update Now: vCURRENT → vLATEST" button that triggers the same `shell.openExternal(download_url)` the pill calls today.
- When up to date: same popup shows the **full** rendered `CHANGELOG.md`, with no Update button.
- Changelog is cached so the up-to-date path is instant and offline-tolerant. Cache invalidates naturally when the user installs an update.

## Non-goals

- No new download / install / auto-update logic. The button triggers the browser just like today.
- No Android UI. Android doesn't render the version pill. The `update:changelog` IPC type still must exist in `SessionService.kt` to satisfy the cross-platform IPC-parity invariant (`docs/PITFALLS.md`), but the handler returns an empty shape.
- No "skip this version" / dismiss-until-next-release tracking.
- No changes to `fetchLatestRelease()`, the 30-minute poll cadence, or the `updateStatus` shape in `status:data`.

## User flow

### Update-available path

1. `updateStatus.update_available === true` → pill glows yellow (unchanged).
2. User clicks pill → `<UpdatePanel>` opens, calls `window.claude.update.changelog({ forceRefresh: true })`.
3. Popup renders:
   - Header: "Update available"
   - Scrollable body: changelog entries where `version > updateStatus.current`, rendered as markdown.
   - Footer: "Update Now: vCURRENT → vLATEST" button.
4. User clicks Update Now → `shell.openExternal(updateStatus.download_url)` → popup closes. Browser handles the file download; user runs the installer. (Unchanged from today.)

### Up-to-date path

1. `updateStatus.update_available === false`, pill shows normally.
2. User clicks pill → `<UpdatePanel>` opens, calls `window.claude.update.changelog({ forceRefresh: false })`.
3. Popup renders:
   - Header: "What's new"
   - Scrollable body: full rendered `CHANGELOG.md`.
   - No Update Now button.
4. User closes via scrim / ESC / close button.

## Architecture

### New IPC surface

- **Type string:** `update:changelog` (request/response).
- **Request payload:** `{ forceRefresh?: boolean }`.
- **Response payload:** `{ markdown: string | null, entries: Array<{ version: string, date?: string, body: string }>, fromCache: boolean, error?: boolean }`.
- **Parity required in:**
  - `desktop/src/main/preload.ts` — expose on `window.claude.update.changelog`.
  - `desktop/src/renderer/remote-shim.ts` — expose the same, route via WebSocket for remote browsers / Android WebView.
  - `desktop/src/main/ipc-handlers.ts` — real handler (fetch + parse + cache).
  - `app/src/main/kotlin/.../runtime/SessionService.kt` — stub handler that responds `{ markdown: null, entries: [], fromCache: false, error: true }`. Dead path (Android pill doesn't render), but required by the IPC-parity invariant in `docs/PITFALLS.md`.

### Main-process logic (`ipc-handlers.ts` + new `changelog-service.ts`)

New module `desktop/src/main/changelog-service.ts`:

- `getChangelog({ forceRefresh }): Promise<ChangelogResult>`:
  1. Read `~/.claude/.changelog-cache.json`.
  2. If `!forceRefresh`, cache exists, and `cache.app_version_at_fetch === app.getVersion()` → return cache with `fromCache: true`.
  3. Else fetch `https://raw.githubusercontent.com/itsdestin/youcoded/master/CHANGELOG.md` (reuse the `User-Agent: YouCoded` / timeout / redirect pattern from `fetchLatestRelease()` in `ipc-handlers.ts:1159-1180`).
  4. Parse markdown → entries.
  5. Write `~/.claude/.changelog-cache.json` with `{ markdown, entries, fetched_at, app_version_at_fetch }`.
  6. Return data with `fromCache: false`.
  7. On fetch failure:
     - If cache exists (even with stale `app_version_at_fetch`) → return stale cache silently.
     - Else → return `{ markdown: null, entries: [], fromCache: false, error: true }`.

- `parseChangelog(markdown: string): Entry[]`:
  - Split on lines matching `/^##\s+\[(\d+\.\d+\.\d+)\](?:\s*[—-]\s*(\S+))?/` (version, optional date).
  - Body is everything between one version header and the next (or EOF).
  - Ignore content before the first version header (the `# Changelog` preamble).
  - Preserve source order (newest first, matching the file).

- `compareVersions()` is reused from the existing implementation in `ipc-handlers.ts:1223-1232`.

### Renderer component

New component: `desktop/src/renderer/components/UpdatePanel.tsx`.

Props:

```ts
interface UpdatePanelProps {
  open: boolean;
  onClose: () => void;
  updateStatus: UpdateStatus;  // current, latest, update_available, download_url
}
```

Behavior:

- L2 popup using `<Scrim layer={2} onClick={onClose} />` + `<OverlayPanel layer={2}>` from `components/overlays/Overlay.tsx`. Pattern-match on `PreferencesPopup.tsx`.
- On `open` flip to true: call `window.claude.update.changelog({ forceRefresh: updateStatus.update_available })`. Local state: `loading`, `data`, `error`.
- ESC + scrim close via the `useEscClose` stack — do NOT add a parallel window-level ESC listener (PITFALLS "Keyboard Routing").
- Reuse the app's existing markdown renderer (same one chat bubbles use).
- When `update_available` and filter returns entries → render those entries. If filter returns zero (changelog lags release, or current tag missing) → fall back to rendering only the newest entry so the popup is never empty with an update clearly available.
- When not `update_available` → render full `markdown`.
- Error/empty state: compact "Couldn't load changelog — [Open on GitHub]" link that invokes existing `shell.openChangelog()`. Update Now button (when applicable) stays visible even in this state — it doesn't depend on the changelog succeeding.

### StatusBar wire-up

`StatusBar.tsx:866-891` (version pill):

- Replace current conditional onClick (`if update_available: openExternal(download_url) else: openChangelog()`) with a single call: `setUpdatePanelOpen(true)`.
- Mount `<UpdatePanel open={updatePanelOpen} onClose={() => setUpdatePanelOpen(false)} updateStatus={updateStatus} />` in the same component tree.
- Yellow-glow styling gated on `updateStatus.update_available` is unchanged.

## Data shapes

### Cache file — `~/.claude/.changelog-cache.json`

```json
{
  "markdown": "# Changelog\n\n## [1.1.2] — 2026-04-21\n...",
  "entries": [
    { "version": "1.1.2", "date": "2026-04-21", "body": "...markdown body..." },
    { "version": "1.1.1", "date": "2026-04-18", "body": "..." }
  ],
  "fetched_at": "2026-04-21T14:02:11.000Z",
  "app_version_at_fetch": "1.1.2"
}
```

### IPC response

```ts
interface ChangelogResult {
  markdown: string | null;      // full file content
  entries: Array<{
    version: string;            // "1.1.2"
    date?: string;              // "2026-04-21"
    body: string;               // markdown body of that version's section
  }>;
  fromCache: boolean;
  error?: boolean;              // true if fetch failed AND no cache
}
```

## Edge cases

| Case | Handling |
|---|---|
| CHANGELOG fetch fails, no cache | Return `{ error: true }`. Popup shows fallback link; Update Now button (if applicable) still works. |
| CHANGELOG fetch fails, stale cache | Return stale cache silently. No spinner flash, no error UI. |
| Parse returns zero entries | Treat as failure → same fallback. |
| Update-available filter returns zero entries | Fall back to rendering the single newest entry. |
| User on a version that predates the first CHANGELOG entry (older than `## [1.0.0]` say) | Filter includes all entries (all newer than current). |
| `updateStatus` refreshes in background while popup is open | Do not auto-rerun; next open picks up new state. |
| User clicks Update Now | `shell.openExternal(download_url)` + `onClose()`. No state persisted — consistent with today's pill behavior. |
| CHANGELOG format changes upstream | Parser anchors on `## [X.Y.Z]` which is stable for Keep-a-Changelog-style files. If Destin changes the format, parser tests fail loudly. |

## Testing

### Unit — `desktop/src/main/__tests__/changelog-parser.test.ts`

- Parses the real checked-in `CHANGELOG.md` into the expected number of version entries with correct version strings and non-empty bodies.
- Ignores preamble before the first version header.
- Handles trailing whitespace / no-trailing-newline.
- `filter-since-current` returns 0/1/N entries in boundary cases (current == latest, current == oldest, current missing from file).
- Malformed input (no `##` headers) returns `[]`.

### Unit — `desktop/src/main/__tests__/changelog-cache.test.ts`

- First call with no cache → fetches, writes, returns `fromCache: false`.
- Second call, same app version, no `forceRefresh` → returns `fromCache: true`, no network call.
- `app_version_at_fetch` mismatch → refetches.
- `forceRefresh: true` → refetches even with valid cache.
- Fetch failure + stale cache → returns stale data, no `error` flag.
- Fetch failure + no cache → returns `{ markdown: null, entries: [], error: true }`.

### Component — `UpdatePanel.test.tsx`

- Renders "Update available" header + Update Now button when `update_available = true`.
- Renders "What's new" header + no Update button when `update_available = false`.
- Update Now button click calls `shell.openExternal(download_url)` then `onClose`.
- Shows fallback link when IPC returns `error: true` and no markdown.
- ESC close flows through the `useEscClose` stack (assert via stack-registration spy, not via direct `window.addEventListener` count).

### Manual verification on dev loop

1. `bash scripts/run-dev.sh`.
2. Temporarily force `updateStatus.update_available = true` in `fetchLatestRelease()` via a `YOUCODED_DEV_FAKE_UPDATE=1` env flag (add a dev-only branch in the fetcher). Click pill → popup opens, changelog entries since current render, Update Now opens browser to `download_url`.
3. Remove the flag, click pill → "What's new" popup with full changelog; confirm second open is cache-hit (no network tab activity).
4. Disconnect network, click pill → cached path still works. Clear `~/.claude/.changelog-cache.json`, disconnect network, click → fallback link visible.
5. Bump `package.json` version locally (simulating post-install), click pill → cache invalidates, refetches once.

### Platforms

- **Desktop (all OS):** full testing per above.
- **Android:** no UI change to verify; confirm via `tests/ipc-channels.test.ts` parity test that `update:changelog` is present in `SessionService.kt`.

## Files touched

**New:**
- `desktop/src/main/changelog-service.ts`
- `desktop/src/main/__tests__/changelog-parser.test.ts`
- `desktop/src/main/__tests__/changelog-cache.test.ts`
- `desktop/src/renderer/components/UpdatePanel.tsx`
- `desktop/src/renderer/components/__tests__/UpdatePanel.test.tsx`

**Modified:**
- `desktop/src/main/preload.ts` — expose `window.claude.update.changelog`.
- `desktop/src/renderer/remote-shim.ts` — mirror the exposure.
- `desktop/src/main/ipc-handlers.ts` — register handler; optional dev-only `YOUCODED_DEV_FAKE_UPDATE` branch.
- `desktop/src/renderer/components/StatusBar.tsx:866-891` — swap pill onClick to open popup; mount popup.
- `app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` — stub `update:changelog` case.
- `tests/ipc-channels.test.ts` — add `update:changelog` to the parity list.

## Risks

- **Parser drift if CHANGELOG format changes.** Mitigation: parser tests run against the checked-in file, so any format change in the repo immediately fails CI until the parser is updated.
- **Cache file on a network-mounted `~/.claude/` (OneDrive)** could cause odd sync behavior. Same risk already exists for `.announcement-cache.json` and `.sync-warnings.json`; treat the same way (just a JSON blob, overwrite on write, no locking needed).
- **Markdown rendering security.** The markdown source is trusted (fetched from our own repo over HTTPS), but the existing app-level markdown renderer's sanitization applies regardless.
