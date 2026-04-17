# Sync Failure Warnings — Design

**Status:** Draft
**Date:** 2026-04-17
**Scope:** Desktop app (Electron + React). Android inherits for free via the shared React UI. Bash statusline is unchanged.

## Problem

Sync has been 100% failing to Google Drive for 3+ days and the user had no UI signal. Every `rclone` push returned a non-zero exit code and the log recorded `"Drive push X failed"` with no detail. Root cause was the user's `rclone.conf` being empty — no `gdrive` remote configured — producing `CRITICAL: Failed to create file system for "gdrive:"` on every call.

Two underlying problems combined to hide the outage:

1. **The push path never surfaces partial failures.** `SyncService.pushDrive()` returns an error count but does not throw. The main sync loop only writes `.sync-error-<backendId>` when a backend **throws**, so a backend returning "17 errors out of 17 pushes" leaves `.sync-error-<id>` empty and `SyncPanel` shows a green dot.
2. **The health check doesn't know about push failures.** `runHealthCheck()` writes `.sync-warnings` codes (`OFFLINE`, `PERSONAL:NOT_CONFIGURED`, `PERSONAL:STALE`, `SKILLS:unrouted:...`, `PROJECTS:N`) but has no code for "the last push failed." `PERSONAL:STALE` would eventually fire after 24h since the marker only updates on full success, but that's coarse and indirect.

Result: StatusBar chip shows nothing, SyncPanel shows green, gear icon is silent, and the user discovers the outage by reading the log manually.

A secondary defect: `logBackup('WARN', 'Drive push X failed')` throws away rclone's stderr, so even when a user does open the log, the error reason is not there.

## Goals

1. Every sync push failure produces a visible warning with layman's copy and an actionable fix path.
2. The header gear icon shows a red dot whenever any danger-level warning is active, so the signal is visible regardless of whether the user has `sync-warnings` StatusBar widget enabled.
3. The backup.log retains enough information (classified code + truncated stderr) for future diagnosis without needing to re-run rclone.
4. Warnings that represent data-loss risk (push failures) cannot be dismissed — they only clear when the condition resolves.

## Non-goals

- **Auto-healing.** The user clicks a "Fix it" button that opens the appropriate UI (e.g., SyncSetupWizard); the app does not re-trigger OAuth silently.
- **Unifying desktop warnings with bash statusline warnings.** `statusline.sh` continues writing the legacy `.sync-warnings` string file for the terminal statusline. The desktop app uses a separate `.sync-warnings.json` — one writer audience per file.
- **High-fidelity classification for GitHub and iCloud backends.** Those ship with `UNKNOWN` as the dominant fallback; rclone patterns ship first because it's where the current outage lives.

## Design

### Data model

A single typed-warning source replaces the split between `.sync-warnings` (string codes) and `.sync-error-<backendId>` (per-backend free-form string):

```ts
// youcoded/desktop/src/main/sync-state.ts
export interface SyncWarning {
  code: string;                 // see taxonomy below
  level: 'danger' | 'warn';
  backendId?: string;           // set for push failures; omitted for global env/hygiene
  title: string;                // StatusBar chip copy (short)
  body: string;                 // SyncPanel explanation copy (1–2 sentences, what happened + what to do)
  fixAction?: SyncFixAction;
  dismissible: boolean;         // false for push-failure warnings
  stderr?: string;              // truncated to 500 chars, only set for UNKNOWN classifications
  createdEpoch: number;
}

export type SyncFixAction =
  | { label: string; kind: 'open-sync-setup'; payload?: { backendId?: string } }
  | { label: string; kind: 'open-external'; payload: { url: string } }
  | { label: string; kind: 'retry'; payload: { backendId: string } }
  | { label: string; kind: 'dismiss' };
```

**Storage:** `~/.claude/.sync-warnings.json` — an array of `SyncWarning`. Written atomically (temp file + rename). Empty array → file is unlinked (consistent with existing `.sync-warnings` behavior).

**Retired:** `.sync-error-<backendId>` is no longer written. The file is deleted by the SyncService on startup if it exists, to avoid stale state from previous versions.

**Legacy compatibility:** `statusline.sh` continues to write `.sync-warnings` (string codes) for the bash terminal statusline. The desktop app ignores that file going forward.

### Writers

**`runHealthCheck()`** (sync-service.ts) emits env/hygiene warnings as typed objects:

| Code | Level | Dismissible | Title | Body |
|---|---|---|---|---|
| `OFFLINE` | danger | yes | No internet | "Can't reach the network. Syncing will resume automatically when you're back online." |
| `PERSONAL_NOT_CONFIGURED` | danger | no | No sync configured | "Your backups aren't set up. Connect a cloud provider so your data is protected." |
| `PERSONAL_STALE` | warn | yes | Sync is stale | "Backups haven't succeeded in over 24 hours. Check the sync panel for details." |
| `SKILLS_UNROUTED` | warn | yes | Unsynced skills | "Some skills aren't being backed up. Route them through the toolkit to include them." |
| `PROJECTS_UNSYNCED` | warn | yes | Projects excluded | "Some of your code projects aren't being synced. Check the sync panel to include them." |

**Push path** (`pushDrive`, `pushGithub`, `pushiCloud`) — new helper `classifyPushError(stderr, backendType): { code, title, body, fixAction }`. On any push returning `errors > 0`, the push method writes one push-failure warning per backend (not per file). On the next successful push for that backend, all warnings with matching `backendId` are cleared.

The push methods pass `stderr` through from the `rclone()` wrapper (already captured, just not propagated). Each push method captures the stderr from the first per-file call that returns non-zero and reuses it for the cycle's classification — not perfect, but good enough for the common case where all files fail for the same reason (e.g., missing remote). One `SyncWarning` is written at the end of the push cycle if `errors > 0`.

### Classification

`classifyPushError()` is defensive: `UNKNOWN` is the default; specific codes are only returned on high-confidence substring matches. Matching is case-sensitive unless otherwise noted. Patterns live as a table in `sync-error-classifier.ts` so adding new codes is one-line.

Initial rclone patterns:

| Code | Level | stderr substring | Title | Body | Fix action |
|---|---|---|---|---|---|
| `CONFIG_MISSING` | danger | `didn't find section in config file` | Google Drive isn't connected | "The Google Drive connection is missing from rclone. Reconnect to resume backups." | `open-sync-setup` with backendId |
| `AUTH_EXPIRED` | danger | `invalid_grant`, `token has been expired or revoked`, `401 Unauthorized` | Google Drive sign-in expired | "Your Google Drive access expired. Sign in again to resume backups." | `open-sync-setup` with backendId |
| `QUOTA_EXCEEDED` | danger | `storageQuotaExceeded`, `quotaExceeded` | Google Drive is full | "Google Drive is out of space. Free up space or upgrade your storage plan." | `open-external` → drive.google.com storage page |
| `NETWORK` | warn | `dial tcp`, `no such host`, `i/o timeout`, `connection refused` | Can't reach Google Drive | "Couldn't connect to Google Drive. We'll retry on the next sync." | `retry` |
| `RCLONE_MISSING` | danger | exec spawn error `ENOENT` (detected at wrapper layer, not stderr) | rclone isn't installed | "The rclone tool is needed for Google Drive sync but isn't installed. Install it to enable backups." | `open-external` → rclone install docs |
| `UNKNOWN` | danger | anything else | Google Drive backup failed | "Backups to Google Drive are failing. See details in the sync panel." + render `stderr` verbatim (truncated to 500 chars, monospace) | `retry` |

GitHub and iCloud ship with `UNKNOWN` only; patterns are added as specific failure modes are identified.

### Readers

**Header gear icon (`HeaderBar.tsx`):** small red dot overlay (6px) at top-right of the gear SVG whenever `syncStatus.warnings.some(w => w.level === 'danger')`. Uses the existing `useSyncStatus` polling the SettingsPanel already drives — no new IPC. Dot is purely decorative; click continues to open SettingsPanel.

**SettingsPanel Sync row:** already visible; keeps existing behavior — this design does not add a second dot inside SettingsPanel.

**SyncPanel.tsx:**
- Per-backend dot color derives from filtering warnings by `backendId`: red if any danger-level push-failure warning matches, yellow if only warn-level, green otherwise. Replaces the existing `lastError`-driven logic.
- The general warnings section (already present at the top of SyncPanel) renders `{title} — {body}` for each warning. If `fixAction` exists, render a button with `action.label`; on click, dispatch to the right handler. If `dismissible`, also render a small dismiss X.
- For `UNKNOWN` codes, the `stderr` field is shown in a collapsible `<details>` block labeled "Show error details."

**StatusBar `sync-warnings` widget:** renders chips using `warning.title` directly — the hardcoded `WARNING_MAP` in StatusBar.tsx and the `parseSyncWarnings` prefix-matcher are removed. `danger` level uses the existing red chip style, `warn` uses amber. Clicking still opens the SyncPanel via `onOpenSync`.

### Fix-action handlers

All handlers live in SyncPanel.tsx (the primary reader); StatusBar chips dispatch through to SyncPanel by opening it.

- `open-sync-setup` — opens `SyncSetupWizard` with the given `backendId` preselected so the user lands on the reconnect flow for Drive (not the full provider picker). Requires a small prop addition to SyncSetupWizard to accept `preselectedBackendId`.
- `open-external` — `window.claude.shell.openExternal(url)`.
- `retry` — calls `window.claude.sync.pushBackend(backendId)` and shows a brief spinner. If the retry succeeds, the warning clears naturally from the next status read.
- `dismiss` — calls `window.claude.sync.dismissWarning(code)` (extended to accept the new format — see IPC changes below).

### Log quality

The `pushDrive` / `pushGithub` / `pushiCloud` WARN log lines gain two structured fields:

```json
{"ts":"...", "level":"WARN", "op":"sync.push.drive", "sid":"",
 "msg":"Drive push memory/X failed",
 "code":"CONFIG_MISSING",
 "stderr":"2026/04/17 14:59:50 CRITICAL: Failed to create file system..."}
```

`stderr` is truncated to the first 500 characters. `code` is the classifier output. This is a per-file log line (unchanged cadence); the classification is computed once per push cycle and reused for all failing files in that cycle.

`logBackup()` is extended to accept a structured `extra` object (the signature already exists — `extra?: Record<string, any>` at sync-service.ts:463 — just currently unused by callers).

### IPC changes

`window.claude.sync.getStatus()` already returns `SyncStatus.warnings: string[]`. Change the field type to `SyncWarning[]` and update `preload.ts` and `remote-shim.ts` in lockstep (shared-UI-architecture parity invariant). Downstream readers (StatusBar, SyncPanel) update to consume the new shape.

`window.claude.sync.dismissWarning(warning: string)` — change parameter to `(code: string)`. `dismissWarning()` in sync-state.ts scans the JSON array, removes the matching warning if `dismissible: true`, and re-writes the file. Push-failure warnings with `dismissible: false` are no-ops (server-side enforcement, not UI-only).

No new IPC channels are added.

### Startup migration

On `SyncService.start()`:
1. If `.sync-error-*` files exist, delete them (stale state from the previous version).
2. If the old string-format `.sync-warnings` file exists and no `.sync-warnings.json` does, leave the old file alone — `statusline.sh` still writes it for the bash statusline, so we must not delete it. We just stop reading it from the desktop side.

No schema version field on `.sync-warnings.json` — the file is fully regenerated on every health-check and push cycle, so old readers against new writers (or vice versa) simply see an empty state on first run after upgrade. If format evolves later, we add a version field then.

## Error handling

- **Classifier misclassifies a real error as `CONFIG_MISSING` when it's actually something else.** Impact: user sees misleading copy, clicks "Reconnect Drive", the wizard succeeds (or fails in a way that produces a new warning). Worst case: wasted clicks. Mitigation: patterns are defensive (long, specific substrings), and `UNKNOWN` is the default — we lean toward under-classifying.
- **`.sync-warnings.json` corrupt or unparseable.** Treat as empty array and re-write on next cycle. Same behavior as existing `.sync-warnings` when readText fails.
- **Warning file becomes large (runaway push failures).** Warning count is bounded by (# backends × # push cycles), and push-failures deduplicate per-backend (only one `PUSH_FAILING` per `backendId` at a time). No unbounded growth.
- **Race: status read happens mid-push.** The file is written atomically; readers either see the pre-push state or the post-push state, never a partial write.

## Testing

Tests live alongside existing sync tests (`youcoded/desktop/tests/sync-*.test.ts`).

1. **Classifier unit tests** — feed known rclone stderr samples to `classifyPushError()` and assert the returned `code`. Covers all 6 initial patterns + an `UNKNOWN` case with stderr passthrough.
2. **Push-failure warning lifecycle test** — `pushDrive()` called with a mocked rclone that fails with `CONFIG_MISSING`-pattern stderr; assert one `SyncWarning` written to `.sync-warnings.json` with the right `backendId` and `code`; subsequent successful push clears it.
3. **Dismiss enforcement test** — call `dismissWarning('CONFIG_MISSING')` for a push-failure warning; assert the file is unchanged (non-dismissible enforced server-side).
4. **Health-check warning migration test** — `runHealthCheck()` no longer writes `.sync-warnings` (string codes) from the desktop side; only `.sync-warnings.json`. Bash side is not tested from the desktop suite.
5. **IPC parity test** — `getStatus()` return shape via both Electron preload and WebSocket shim yields identical `SyncWarning[]` objects.

Manual verification: temporarily empty `rclone.conf`, run a sync, confirm red dot appears on gear icon, SyncPanel shows "Google Drive isn't connected" with a Reconnect button that opens SyncSetupWizard pre-targeted at the Drive backend.

## Rollout

- Desktop-only change; ships in the next desktop release.
- No toolkit-side changes required. Bash `statusline.sh` is untouched.
- Users on older desktop versions continue using `.sync-error-<id>` + string `.sync-warnings`; on upgrade, stale per-backend error files are cleaned up on first SyncService start.
- No user-facing setting to toggle the behavior — the red dot and unified warnings replace the previous (invisible) state unconditionally.

## Files touched (approximate)

- `youcoded/desktop/src/main/sync-state.ts` — `SyncWarning` type, new dismissWarning, status shape change, retire `.sync-error-<id>` reads.
- `youcoded/desktop/src/main/sync-service.ts` — push methods thread stderr through, call classifier, write typed warnings, log quality improvement, startup cleanup of stale `.sync-error-*` files.
- `youcoded/desktop/src/main/sync-error-classifier.ts` — new file, pure `classifyPushError()` function + pattern table.
- `youcoded/desktop/src/main/preload.ts` + `src/renderer/remote-shim.ts` — type update for warnings, no new channels.
- `youcoded/desktop/src/renderer/components/HeaderBar.tsx` — red dot on gear when any danger warning is active.
- `youcoded/desktop/src/renderer/components/SyncPanel.tsx` — per-backend dot derivation from warnings, fix-action buttons, `UNKNOWN` stderr display.
- `youcoded/desktop/src/renderer/components/SyncSetupWizard.tsx` — accept `preselectedBackendId` prop.
- `youcoded/desktop/src/renderer/components/StatusBar.tsx` — remove hardcoded `WARNING_MAP` and `parseSyncWarnings`, render from typed warnings.
- `youcoded/desktop/tests/sync-*.test.ts` — new tests as described above.
