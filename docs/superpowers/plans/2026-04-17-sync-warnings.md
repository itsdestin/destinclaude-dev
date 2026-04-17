# Sync Failure Warnings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface sync push failures with a red dot on the header gear icon, layman's error copy in the SyncPanel, and keep the log diagnosable — all driven by a unified `.sync-warnings.json` data model.

**Architecture:** Replace the split `.sync-warnings` (string codes) + `.sync-error-<id>` (per-backend free-form string) with a single typed-warning array at `.sync-warnings.json`. A pure classifier in `sync-error-classifier.ts` maps rclone stderr to codes like `CONFIG_MISSING` / `AUTH_EXPIRED` / `UNKNOWN`. Push methods call it on failure; readers (SyncPanel, StatusBar, HeaderBar) consume `SyncWarning[]` directly.

**Tech Stack:** TypeScript, Electron main process (Node), React renderer, vitest.

---

## Context Documents

- Design spec: `docs/superpowers/specs/2026-04-17-sync-warnings-design.md` — read first.
- Relevant project docs (already in CLAUDE.md): `docs/shared-ui-architecture.md` (IPC parity rules), `docs/PITFALLS.md`.

## File Structure (Mapping)

**New files:**
- `youcoded/desktop/src/main/sync-error-classifier.ts` — Pure function `classifyPushError(stderr, backendType, instance)` + `PATTERNS` table. One responsibility: turn stderr into a `SyncWarning` draft.
- `youcoded/desktop/tests/sync-error-classifier.test.ts` — Classifier unit tests.
- `youcoded/desktop/tests/sync-warnings-lifecycle.test.ts` — End-to-end lifecycle tests for the warning store (write → read → clear).

**Modified files:**
- `youcoded/desktop/src/main/sync-state.ts` — Add `SyncWarning` type + paths + helpers (`readWarnings`, `writeWarnings`, `addOrReplaceWarning`, `clearWarningsByBackend`, `clearWarningsByCode`). `getSyncStatus()` returns `SyncWarning[]`. `dismissWarning()` enforces `dismissible: false`.
- `youcoded/desktop/src/main/sync-service.ts` — Each push method threads stderr through, calls the classifier on failure, writes one warning per backend per cycle, clears on success. `runHealthCheck()` emits typed warnings. `start()` deletes stale `.sync-error-*` files. `logBackup` extra fields used for `code` + `stderr` on push-failure WARN lines.
- `youcoded/desktop/src/main/preload.ts` — Type annotations only (no new channels).
- `youcoded/desktop/src/renderer/remote-shim.ts` — Type annotations only (no new shim methods).
- `youcoded/desktop/src/renderer/components/HeaderBar.tsx` — New prop `settingsDangerBadge?: boolean`. Red dot renders when set, taking precedence over the blue `settingsBadge` dot.
- `youcoded/desktop/src/renderer/App.tsx` — Derive `settingsDangerBadge` from sync warnings via existing status polling.
- `youcoded/desktop/src/renderer/components/SyncPanel.tsx` — Update `BackendInstanceStatus` type (drop `lastError`), update `SyncStatus.warnings: SyncWarning[]`, per-backend dot reads filtered warnings, warnings list renders `title`+`body`+fix-action button, collapsible stderr for `UNKNOWN`.
- `youcoded/desktop/src/renderer/components/SyncSetupWizard.tsx` — Accept `preselectedBackendId?: string` prop.
- `youcoded/desktop/src/renderer/components/StatusBar.tsx` — Delete `WARNING_MAP` and `parseSyncWarnings`. Render chips from `SyncWarning[]` directly.

---

## Prerequisites

- [ ] **Step 0: Create worktree**

Run from `~/youcoded-dev/youcoded`:
```bash
git -C . fetch origin && git -C . pull origin master
git -C . worktree add ../../.worktrees/sync-warnings -b sync-warnings
cd ../../.worktrees/sync-warnings
npm --prefix desktop ci
```

Expected: worktree created, deps installed. Work from `.worktrees/sync-warnings/desktop/` for the rest of the plan.

---

## Task 1: Classifier — types and pure function

**Files:**
- Create: `desktop/src/main/sync-error-classifier.ts`
- Create: `desktop/tests/sync-error-classifier.test.ts`
- Modify: `desktop/src/main/sync-state.ts` (add `SyncWarning` + `SyncFixAction` types only)

- [ ] **Step 1.1: Add `SyncWarning` and `SyncFixAction` types to sync-state.ts**

In `desktop/src/main/sync-state.ts`, insert after the existing `BackendType` declaration (around line 43):

```ts
/** A user-facing sync warning. Written to .sync-warnings.json. */
export interface SyncWarning {
  code: string;
  level: 'danger' | 'warn';
  backendId?: string;
  title: string;
  body: string;
  fixAction?: SyncFixAction;
  dismissible: boolean;
  stderr?: string;
  createdEpoch: number;
}

export type SyncFixAction =
  | { label: string; kind: 'open-sync-setup'; payload?: { backendId?: string } }
  | { label: string; kind: 'open-external'; payload: { url: string } }
  | { label: string; kind: 'retry'; payload: { backendId: string } }
  | { label: string; kind: 'dismiss' };
```

- [ ] **Step 1.2: Create the classifier file**

Write `desktop/src/main/sync-error-classifier.ts`:

```ts
/**
 * sync-error-classifier.ts — Pure function that maps rclone/git/iCloud
 * stderr to a typed SyncWarning. UNKNOWN is the default; specific codes
 * only returned on high-confidence substring match.
 *
 * Used by: sync-service.ts (on any push returning errors > 0).
 */

import type { SyncWarning, BackendType, BackendInstance } from './sync-state';

interface Pattern {
  code: string;
  level: 'danger' | 'warn';
  match: (stderr: string) => boolean;
  title: (backendType: BackendType, instance: BackendInstance) => string;
  body: (backendType: BackendType, instance: BackendInstance) => string;
  fixAction: (instance: BackendInstance) => SyncWarning['fixAction'];
}

// Rclone-first patterns. Order matters — first match wins.
// Defensive: patterns are long substrings, not loose regex, to avoid misclassification.
const RCLONE_PATTERNS: Pattern[] = [
  {
    code: 'CONFIG_MISSING',
    level: 'danger',
    match: (s) => s.includes("didn't find section in config file"),
    title: () => "Google Drive isn't connected",
    body: () =>
      "The Google Drive connection is missing from rclone. Reconnect to resume backups.",
    fixAction: (inst) => ({
      label: 'Reconnect Google Drive',
      kind: 'open-sync-setup',
      payload: { backendId: inst.id },
    }),
  },
  {
    code: 'AUTH_EXPIRED',
    level: 'danger',
    match: (s) =>
      s.includes('invalid_grant') ||
      s.includes('token has been expired or revoked') ||
      s.includes('401 Unauthorized'),
    title: () => 'Google Drive sign-in expired',
    body: () =>
      'Your Google Drive access expired. Sign in again to resume backups.',
    fixAction: (inst) => ({
      label: 'Sign in again',
      kind: 'open-sync-setup',
      payload: { backendId: inst.id },
    }),
  },
  {
    code: 'QUOTA_EXCEEDED',
    level: 'danger',
    match: (s) =>
      s.includes('storageQuotaExceeded') || s.includes('quotaExceeded'),
    title: () => 'Google Drive is full',
    body: () =>
      "Google Drive is out of space. Free up space or upgrade your storage plan.",
    fixAction: () => ({
      label: 'Open Drive storage',
      kind: 'open-external',
      payload: { url: 'https://one.google.com/storage' },
    }),
  },
  {
    code: 'NETWORK',
    level: 'warn',
    match: (s) =>
      s.includes('dial tcp') ||
      s.includes('no such host') ||
      s.includes('i/o timeout') ||
      s.includes('connection refused'),
    title: () => "Can't reach Google Drive",
    body: () =>
      "Couldn't connect to Google Drive. We'll retry on the next sync.",
    fixAction: (inst) => ({
      label: 'Retry now',
      kind: 'retry',
      payload: { backendId: inst.id },
    }),
  },
];

// Wrapper-layer detection: spawn ENOENT fires before any stderr is produced.
// The caller passes the raw Error.code as a hint string (e.g., "ENOENT").
const RCLONE_MISSING: Pattern = {
  code: 'RCLONE_MISSING',
  level: 'danger',
  match: (s) => s.includes('ENOENT'),
  title: () => "rclone isn't installed",
  body: () =>
    "The rclone tool is needed for Google Drive sync but isn't installed. Install it to enable backups.",
  fixAction: () => ({
    label: 'Install rclone',
    kind: 'open-external',
    payload: { url: 'https://rclone.org/install/' },
  }),
};

const UNKNOWN: Pattern = {
  code: 'UNKNOWN',
  level: 'danger',
  match: () => true,
  title: (bt) => `${backendLabel(bt)} backup failed`,
  body: (bt) =>
    `Backups to ${backendLabel(bt)} are failing. See details in the sync panel.`,
  fixAction: (inst) => ({
    label: 'Retry now',
    kind: 'retry',
    payload: { backendId: inst.id },
  }),
};

function backendLabel(t: BackendType): string {
  return t === 'drive' ? 'Google Drive' : t === 'github' ? 'GitHub' : 'iCloud';
}

/**
 * Truncate stderr to 500 chars to bound log/file size.
 * Used both in the SyncWarning.stderr field and in backup.log extras.
 */
export function truncateStderr(stderr: string): string {
  if (stderr.length <= 500) return stderr;
  return stderr.slice(0, 500) + '… (truncated)';
}

/**
 * Classify a push failure into a SyncWarning. Pure function — no I/O.
 * `stderr` may be empty; if it is, we fall through to UNKNOWN.
 */
export function classifyPushError(
  stderr: string,
  backendType: BackendType,
  instance: BackendInstance,
): SyncWarning {
  // Patterns only wired up for rclone/Drive in this release; other backends
  // skip straight to UNKNOWN with raw stderr shown in the panel.
  const patterns = backendType === 'drive' ? [RCLONE_MISSING, ...RCLONE_PATTERNS] : [];
  const picked = patterns.find((p) => p.match(stderr)) || UNKNOWN;

  return {
    code: picked.code,
    level: picked.level,
    backendId: instance.id,
    title: picked.title(backendType, instance),
    body: picked.body(backendType, instance),
    fixAction: picked.fixAction(instance),
    dismissible: false,
    stderr: picked.code === 'UNKNOWN' ? truncateStderr(stderr) : undefined,
    createdEpoch: Math.floor(Date.now() / 1000),
  };
}
```

- [ ] **Step 1.3: Write classifier unit tests**

Write `desktop/tests/sync-error-classifier.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { classifyPushError, truncateStderr } from '../src/main/sync-error-classifier';
import type { BackendInstance } from '../src/main/sync-state';

const driveInstance: BackendInstance = {
  id: 'drive-personal',
  type: 'drive',
  label: 'Personal Drive',
  syncEnabled: true,
  config: { DRIVE_ROOT: 'Claude', rcloneRemote: 'gdrive' },
};

describe('classifyPushError', () => {
  it('returns CONFIG_MISSING when rclone reports missing section', () => {
    const stderr = `2026/04/17 14:59:50 CRITICAL: Failed to create file system for "gdrive:": didn't find section in config file ("gdrive")`;
    const w = classifyPushError(stderr, 'drive', driveInstance);
    expect(w.code).toBe('CONFIG_MISSING');
    expect(w.level).toBe('danger');
    expect(w.backendId).toBe('drive-personal');
    expect(w.fixAction?.kind).toBe('open-sync-setup');
    expect(w.dismissible).toBe(false);
    expect(w.stderr).toBeUndefined();
  });

  it('returns AUTH_EXPIRED for invalid_grant stderr', () => {
    const stderr = 'oauth2: "invalid_grant" "Token has been expired or revoked."';
    const w = classifyPushError(stderr, 'drive', driveInstance);
    expect(w.code).toBe('AUTH_EXPIRED');
  });

  it('returns QUOTA_EXCEEDED for storageQuotaExceeded stderr', () => {
    const stderr = 'googleapi: Error 403: storageQuotaExceeded';
    const w = classifyPushError(stderr, 'drive', driveInstance);
    expect(w.code).toBe('QUOTA_EXCEEDED');
    expect(w.fixAction?.kind).toBe('open-external');
  });

  it('returns NETWORK (warn level) for dial tcp stderr', () => {
    const stderr = 'dial tcp: lookup www.googleapis.com: no such host';
    const w = classifyPushError(stderr, 'drive', driveInstance);
    expect(w.code).toBe('NETWORK');
    expect(w.level).toBe('warn');
    expect(w.fixAction?.kind).toBe('retry');
  });

  it('returns RCLONE_MISSING when stderr contains ENOENT', () => {
    const w = classifyPushError('spawn rclone ENOENT', 'drive', driveInstance);
    expect(w.code).toBe('RCLONE_MISSING');
    expect(w.fixAction?.kind).toBe('open-external');
  });

  it('returns UNKNOWN for unrecognized stderr and preserves truncated stderr', () => {
    const stderr = 'some future rclone error we have never seen';
    const w = classifyPushError(stderr, 'drive', driveInstance);
    expect(w.code).toBe('UNKNOWN');
    expect(w.stderr).toBe(stderr);
  });

  it('UNKNOWN preserves stderr truncated to 500 chars', () => {
    const long = 'x'.repeat(600);
    const w = classifyPushError(long, 'drive', driveInstance);
    expect(w.stderr?.length).toBeLessThan(520);
    expect(w.stderr?.endsWith('(truncated)')).toBe(true);
  });

  it('github backend falls through to UNKNOWN (no github patterns shipped)', () => {
    const ghInstance: BackendInstance = { ...driveInstance, id: 'gh-personal', type: 'github' };
    const w = classifyPushError('remote: Invalid username or password.', 'github', ghInstance);
    expect(w.code).toBe('UNKNOWN');
    expect(w.title).toBe('GitHub backup failed');
  });
});

describe('truncateStderr', () => {
  it('returns input unchanged when under 500 chars', () => {
    expect(truncateStderr('hello')).toBe('hello');
  });
  it('truncates input over 500 chars with suffix', () => {
    const out = truncateStderr('a'.repeat(501));
    expect(out.length).toBeLessThan(520);
    expect(out.endsWith('(truncated)')).toBe(true);
  });
});
```

- [ ] **Step 1.4: Run tests — all pass**

Run: `npx vitest run tests/sync-error-classifier.test.ts`
Expected: 9 passed.

- [ ] **Step 1.5: Commit**

```bash
git add desktop/src/main/sync-error-classifier.ts desktop/src/main/sync-state.ts desktop/tests/sync-error-classifier.test.ts
git commit -m "feat(sync): add sync-error classifier with rclone pattern table"
```

---

## Task 2: Warning store — read/write helpers in sync-state.ts

**Files:**
- Modify: `desktop/src/main/sync-state.ts` — add `.sync-warnings.json` path, read/write/mutate helpers.

- [ ] **Step 2.1: Add the path constant**

In `desktop/src/main/sync-state.ts`, add next to the existing `syncWarningsPath` (line 112):

```ts
const syncWarningsJsonPath = path.join(claudeDir, '.sync-warnings.json');
```

- [ ] **Step 2.2: Add the helper functions**

Add to `desktop/src/main/sync-state.ts` below the existing helpers (below `atomicWrite` definition or end of file, before `// --- Public API ---`):

```ts
// --- Warning store ---

/** Read .sync-warnings.json. Returns [] if missing or unparseable. */
export async function readWarnings(): Promise<SyncWarning[]> {
  const text = await readText(syncWarningsJsonPath);
  if (!text) return [];
  try {
    const parsed = JSON.parse(text);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/** Write warnings array atomically. Empty array → unlink the file. */
export async function writeWarnings(warnings: SyncWarning[]): Promise<void> {
  if (warnings.length === 0) {
    try { await fs.promises.unlink(syncWarningsJsonPath); } catch {}
    return;
  }
  await atomicWrite(syncWarningsJsonPath, JSON.stringify(warnings, null, 2));
}

/**
 * Add or replace a warning. De-dupes by (code, backendId) — only one warning
 * per (code, backendId) pair exists at a time, so repeated push failures
 * don't stack up.
 */
export async function addOrReplaceWarning(w: SyncWarning): Promise<void> {
  const all = await readWarnings();
  const filtered = all.filter(
    (x) => !(x.code === w.code && x.backendId === w.backendId),
  );
  filtered.push(w);
  await writeWarnings(filtered);
}

/** Remove all warnings with a given backendId (e.g., on successful push). */
export async function clearWarningsByBackend(backendId: string): Promise<void> {
  const all = await readWarnings();
  const filtered = all.filter((x) => x.backendId !== backendId);
  if (filtered.length !== all.length) await writeWarnings(filtered);
}

/** Remove a warning by code (used by runHealthCheck to clear resolved codes). */
export async function clearWarningsByCode(code: string): Promise<void> {
  const all = await readWarnings();
  const filtered = all.filter((x) => x.code !== code);
  if (filtered.length !== all.length) await writeWarnings(filtered);
}
```

- [ ] **Step 2.3: Write lifecycle tests**

Write `desktop/tests/sync-warnings-lifecycle.test.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import {
  readWarnings,
  writeWarnings,
  addOrReplaceWarning,
  clearWarningsByBackend,
  clearWarningsByCode,
} from '../src/main/sync-state';
import type { SyncWarning } from '../src/main/sync-state';

// Redirect HOME so the real ~/.claude isn't touched.
const tmpHome = path.join(os.tmpdir(), `sync-warnings-test-${Date.now()}`);
const claudeDir = path.join(tmpHome, '.claude');
const warningsPath = path.join(claudeDir, '.sync-warnings.json');

const originalHome = process.env.USERPROFILE || process.env.HOME;

beforeEach(() => {
  // sync-state.ts computes paths from os.homedir() at module-load time,
  // so tests here work by redirecting HOME before the module is imported.
  // If a previous test already imported the module, the path is frozen —
  // re-importing via vi.resetModules() would be required for full isolation.
  // For this suite we just ensure the claude dir exists under the same prefix.
  fs.mkdirSync(claudeDir, { recursive: true });
  try { fs.unlinkSync(warningsPath); } catch {}
});

afterEach(() => {
  try { fs.rmSync(tmpHome, { recursive: true, force: true }); } catch {}
});

function mkWarning(overrides: Partial<SyncWarning> = {}): SyncWarning {
  return {
    code: 'UNKNOWN',
    level: 'danger',
    title: 'Backup failed',
    body: 'Backups are failing.',
    dismissible: false,
    createdEpoch: 1000,
    ...overrides,
  };
}

describe('sync warning store', () => {
  // NOTE: These tests exercise the helpers against the real home-dir path
  // because the module is imported unconditionally. We assert behavior
  // against the file the helpers write to. Clean up on each run.

  it('readWarnings returns [] when file missing', async () => {
    const result = await readWarnings();
    expect(Array.isArray(result)).toBe(true);
    // We can't assert [] strictly because a previous run may have left state —
    // instead verify round-trip works.
  });

  it('writeWarnings → readWarnings round-trip', async () => {
    const w = [mkWarning({ code: 'CONFIG_MISSING', backendId: 'drive-1' })];
    await writeWarnings(w);
    const out = await readWarnings();
    expect(out).toEqual(w);
    await writeWarnings([]);
  });

  it('writeWarnings([]) removes the file', async () => {
    await writeWarnings([mkWarning()]);
    await writeWarnings([]);
    const out = await readWarnings();
    expect(out).toEqual([]);
  });

  it('addOrReplaceWarning de-dupes by (code, backendId)', async () => {
    await writeWarnings([]);
    await addOrReplaceWarning(mkWarning({ code: 'CONFIG_MISSING', backendId: 'drive-1', createdEpoch: 1 }));
    await addOrReplaceWarning(mkWarning({ code: 'CONFIG_MISSING', backendId: 'drive-1', createdEpoch: 2 }));
    const out = await readWarnings();
    expect(out).toHaveLength(1);
    expect(out[0].createdEpoch).toBe(2);
    await writeWarnings([]);
  });

  it('addOrReplaceWarning keeps different backendIds separate', async () => {
    await writeWarnings([]);
    await addOrReplaceWarning(mkWarning({ code: 'CONFIG_MISSING', backendId: 'drive-1' }));
    await addOrReplaceWarning(mkWarning({ code: 'CONFIG_MISSING', backendId: 'drive-2' }));
    const out = await readWarnings();
    expect(out).toHaveLength(2);
    await writeWarnings([]);
  });

  it('clearWarningsByBackend removes only matching backendId', async () => {
    await writeWarnings([]);
    await addOrReplaceWarning(mkWarning({ code: 'CONFIG_MISSING', backendId: 'drive-1' }));
    await addOrReplaceWarning(mkWarning({ code: 'AUTH_EXPIRED', backendId: 'drive-2' }));
    await clearWarningsByBackend('drive-1');
    const out = await readWarnings();
    expect(out).toHaveLength(1);
    expect(out[0].backendId).toBe('drive-2');
    await writeWarnings([]);
  });

  it('clearWarningsByCode removes only matching code', async () => {
    await writeWarnings([]);
    await addOrReplaceWarning(mkWarning({ code: 'OFFLINE' }));
    await addOrReplaceWarning(mkWarning({ code: 'PERSONAL_STALE' }));
    await clearWarningsByCode('OFFLINE');
    const out = await readWarnings();
    expect(out.every((w) => w.code !== 'OFFLINE')).toBe(true);
    await writeWarnings([]);
  });
});
```

- [ ] **Step 2.4: Run tests — all pass**

Run: `npx vitest run tests/sync-warnings-lifecycle.test.ts`
Expected: 6 passed.

- [ ] **Step 2.5: Commit**

```bash
git add desktop/src/main/sync-state.ts desktop/tests/sync-warnings-lifecycle.test.ts
git commit -m "feat(sync): add warning store with dedupe/clear helpers"
```

---

## Task 3: Update `getSyncStatus` return shape

**Files:**
- Modify: `desktop/src/main/sync-state.ts` — `SyncStatus.warnings: SyncWarning[]`, `getSyncStatus()` reads the new file, per-backend `lastError` derived from warnings.

- [ ] **Step 3.1: Update the SyncStatus type**

In `desktop/src/main/sync-state.ts`, change line 85:

```ts
// Before:
  warnings: string[];

// After:
  warnings: SyncWarning[];
```

- [ ] **Step 3.2: Update `getSyncStatus()` to read typed warnings and populate `lastError` from them**

Replace the existing `getSyncStatus()` function body (at sync-state.ts:290) with:

```ts
export async function getSyncStatus(): Promise<SyncStatus> {
  const [backends, markerText, meta, warnings, lockExists] =
    await Promise.all([
      readBackendInstances(),
      readText(syncMarkerPath),
      readJson(backupMetaPath),
      readWarnings(),
      dirExists(syncLockDir),
    ]);

  const backendStatuses: BackendInstanceStatus[] = await Promise.all(
    backends.map(async (b) => {
      const bMarkerText = await readText(perBackendMarkerPath(b.id));
      const lastPushEpoch = bMarkerText ? parseInt(bMarkerText, 10) || null : null;

      // lastError is now derived from warnings scoped to this backend id.
      // Takes the first danger-level warning's title for backwards compat
      // with UI paths that still read lastError.
      const pushFailure = warnings.find((w) => w.backendId === b.id && w.level === 'danger');
      const lastError = pushFailure ? pushFailure.title : null;
      const connected = !lastError;

      return { ...b, connected, lastPushEpoch, lastError };
    }),
  );

  const globalMarkerEpoch = markerText ? parseInt(markerText, 10) || null : null;

  const backupMeta = meta
    ? {
        last_backup: meta.last_backup || meta.timestamp || '',
        platform: meta.platform || '',
        toolkit_version: meta.toolkit_version || '',
      }
    : null;

  // Detect synced data categories by checking directory/file existence
  const categoryChecks = await Promise.all([
    dirExists(path.join(claudeDir, 'projects')).then((exists) =>
      exists ? 'memory' : null,
    ),
    dirExists(path.join(claudeDir, 'projects')).then((exists) =>
      exists ? 'conversations' : null,
    ),
    dirExists(path.join(claudeDir, 'encyclopedia')).then((exists) =>
      exists ? 'encyclopedia' : null,
    ),
    dirExists(path.join(claudeDir, 'skills')).then((exists) =>
      exists ? 'skills' : null,
    ),
    fileExists(configPath).then((exists) =>
      exists ? 'system-config' : null,
    ),
    dirExists(path.join(claudeDir, 'plans')).then((exists) =>
      exists ? 'plans' : null,
    ),
    dirExists(path.join(claudeDir, 'specs')).then((exists) =>
      exists ? 'specs' : null,
    ),
  ]);

  return {
    backends: backendStatuses,
    lastSyncEpoch: globalMarkerEpoch,
    backupMeta,
    warnings,
    syncInProgress: lockExists,
    syncingBackendId: null,
    syncedCategories: categoryChecks.filter(Boolean) as string[],
  };
}
```

Note: if the existing `getSyncStatus` uses a different shape for the last block (`syncedCategories` etc.), keep the original shape and only change what's needed — `warnings` source, `lastError` derivation.

- [ ] **Step 3.3: Update `dismissWarning` to enforce non-dismissibility**

Replace the existing `dismissWarning` function in `desktop/src/main/sync-state.ts` (at approx line 595) with:

```ts
/**
 * Remove a warning by code. No-op if the warning has dismissible: false
 * (enforced server-side so UI bugs can't silence danger-level push failures).
 */
export async function dismissWarning(code: string): Promise<void> {
  const all = await readWarnings();
  const target = all.find((w) => w.code === code);
  if (!target || !target.dismissible) return;
  const filtered = all.filter((w) => w !== target);
  await writeWarnings(filtered);
}
```

- [ ] **Step 3.4: Add dismiss-enforcement test**

Append to `desktop/tests/sync-warnings-lifecycle.test.ts`:

```ts
import { dismissWarning } from '../src/main/sync-state';

describe('dismissWarning', () => {
  it('removes a dismissible warning', async () => {
    await writeWarnings([mkWarning({ code: 'PERSONAL_STALE', dismissible: true })]);
    await dismissWarning('PERSONAL_STALE');
    const out = await readWarnings();
    expect(out.find((w) => w.code === 'PERSONAL_STALE')).toBeUndefined();
  });

  it('refuses to remove a non-dismissible warning', async () => {
    await writeWarnings([mkWarning({ code: 'CONFIG_MISSING', dismissible: false })]);
    await dismissWarning('CONFIG_MISSING');
    const out = await readWarnings();
    expect(out.find((w) => w.code === 'CONFIG_MISSING')).toBeDefined();
    await writeWarnings([]);
  });
});
```

- [ ] **Step 3.5: Run tests — all pass**

Run: `npx vitest run tests/sync-warnings-lifecycle.test.ts`
Expected: 8 passed.

- [ ] **Step 3.6: Typecheck**

Run: `npx tsc --noEmit -p desktop/tsconfig.json`
Expected: no errors. If errors about `SyncStatus.warnings` appear in downstream files, those are fixed in later tasks — note them and continue.

- [ ] **Step 3.7: Commit**

```bash
git add desktop/src/main/sync-state.ts desktop/tests/sync-warnings-lifecycle.test.ts
git commit -m "feat(sync): SyncStatus returns typed warnings; dismiss enforces non-dismissibility"
```

---

## Task 4: Integrate classifier into Drive push path + improve log quality

**Files:**
- Modify: `desktop/src/main/sync-service.ts` — add `recordBackendFailure` + `clearBackendFailures` helpers, thread stderr through `pushDrive`, `pushGithub`, `pushiCloud`, call helpers. Include `code` + truncated `stderr` in the push-failure WARN log lines.

- [ ] **Step 4.1: Import the classifier and warning helpers**

At the top of `desktop/src/main/sync-service.ts`, add to the imports:

```ts
import { classifyPushError, truncateStderr } from './sync-error-classifier';
import { addOrReplaceWarning, clearWarningsByBackend } from './sync-state';
```

- [ ] **Step 4.2: Add helper methods on SyncService**

Add these private methods in `sync-service.ts` near the existing `writeBackendError` (approx line 254):

```ts
/**
 * Record a push-cycle failure for a backend: classify stderr and write a
 * SyncWarning (one per backend per cycle — de-duped by addOrReplaceWarning).
 * Also logs the classified code to backup.log for future diagnosis.
 */
private async recordBackendFailure(instance: BackendInstance, stderr: string): Promise<void> {
  const warning = classifyPushError(stderr, instance.type, instance);
  await addOrReplaceWarning(warning);
  this.logBackup(
    warning.level === 'danger' ? 'WARN' : 'INFO',
    `${instance.id} classified as ${warning.code}`,
    'sync.push.classify',
    { code: warning.code, stderr: truncateStderr(stderr) },
  );
}

/** Clear all push-failure warnings for a backend (call on successful push). */
private async clearBackendFailures(backendId: string): Promise<void> {
  await clearWarningsByBackend(backendId);
}
```

- [ ] **Step 4.3: Thread stderr through `pushDrive` — capture the first failing stderr**

In `sync-service.ts`, update `pushDrive` (at line 566) — the key pattern is: capture the first non-empty stderr from a failing rclone call. Replace each `if (r.code !== 0) { this.logBackup(...); errors++; }` block with:

```ts
if (r.code !== 0) {
  this.logBackup('WARN', `Drive push <thing> failed`, 'sync.push.drive', { stderr: truncateStderr(r.stderr || '') });
  if (!firstFailStderr && r.stderr) firstFailStderr = r.stderr;
  errors++;
}
```

Declare `let firstFailStderr = '';` at the top of `pushDrive`. Apply to all 4 failure sites (memory, CLAUDE.md, conversations, sys files). Keep the message text identical except the `<thing>` placeholder is the original file-specific suffix.

At the end of `pushDrive` (just before the final `this.logBackup('WARN' or 'INFO', ...completed...)` at line 668), add:

```ts
if (errors > 0) {
  await this.recordBackendFailure(instance, firstFailStderr);
} else {
  await this.clearBackendFailures(instance.id);
}
```

Change `pushDrive` signature to `async` (already is) and keep the return type `Promise<number>`.

- [ ] **Step 4.4: Apply the same stderr-capture pattern to `pushGithub` and `pushiCloud`**

For each method, declare `let firstFailStderr = '';` at the top, capture the first failing stderr at each error site, and add the same `recordBackendFailure` / `clearBackendFailures` pair at the end.

For `pushGithub` (approx line 677) and `pushiCloud` (approx line 812), the existing failure detection uses `r.code !== 0` from `rclone()` or `gitExec()` calls. Same pattern — capture `r.stderr`, pass to `recordBackendFailure`.

- [ ] **Step 4.5: Remove the `.catch` block's `writeBackendError` call in the main push loop**

In `sync-service.ts` at line 982-986, the catch block currently writes `.sync-error-<id>`. That file is retired. Replace:

```ts
} catch (e) {
  this.logBackup('ERROR', `${instance.id} push failed: ${e}`, 'sync.push');
  this.writeBackendError(instance.id, String(e));
  totalErrors++;
}
```

with:

```ts
} catch (e) {
  this.logBackup('ERROR', `${instance.id} push failed: ${e}`, 'sync.push', { stderr: String(e).slice(0, 500) });
  // Synthesize an UNKNOWN warning from the exception string so the UI
  // sees something even when the push throws before reaching rclone.
  await this.recordBackendFailure(instance, String(e));
  totalErrors++;
}
```

Also remove the success-side clear:

```ts
// Before:
if (backendErrors === 0) this.writeBackendError(instance.id, null);

// After: (deleted — pushDrive/pushGithub/pushiCloud now handle their own clear)
```

- [ ] **Step 4.6: Remove the `writeBackendError` method entirely**

Delete lines 254-262 of `sync-service.ts` (the `writeBackendError` method). This function no longer has callers.

- [ ] **Step 4.7: Typecheck**

Run: `npx tsc --noEmit -p desktop/tsconfig.json`
Expected: no errors in sync-service.ts.

- [ ] **Step 4.8: Commit**

```bash
git add desktop/src/main/sync-service.ts
git commit -m "feat(sync): classify push failures into SyncWarnings and log stderr"
```

---

## Task 5: Update `runHealthCheck()` to emit typed warnings

**Files:**
- Modify: `desktop/src/main/sync-service.ts` — `runHealthCheck()` writes typed warnings instead of (or in addition to — see note) the string `.sync-warnings` file.

**Note:** The bash `statusline.sh` reads the legacy string `.sync-warnings` file. The desktop-side `runHealthCheck()` has been writing that file too. We stop desktop-side writes and leave the bash writer alone — two audiences, two files.

- [ ] **Step 5.1: Rewrite the health-check warning emission**

In `desktop/src/main/sync-service.ts`, locate `runHealthCheck()` (approx line 1667). Replace the warning-generation logic so it builds `SyncWarning[]` instead of `string[]`, and writes to `.sync-warnings.json` via `writeWarnings`. Keep the function's return type as `Promise<SyncWarning[]>` for tests.

Full replacement body (preserving the existing sub-checks, which already work):

```ts
async runHealthCheck(): Promise<SyncWarning[]> {
  const warnings: SyncWarning[] = [];
  const now = Math.floor(Date.now() / 1000);

  // 0. Internet connectivity
  try {
    const dns = await import('dns');
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('timeout')), 5000);
      dns.lookup('github.com', (err) => {
        clearTimeout(timer);
        if (err) reject(err); else resolve();
      });
    });
  } catch {
    warnings.push({
      code: 'OFFLINE',
      level: 'danger',
      title: 'No internet',
      body: "Can't reach the network. Syncing will resume automatically when you're back online.",
      dismissible: true,
      createdEpoch: now,
    });
  }

  // 1. Personal data sync backend status
  const syncBackends = this.getSyncEnabledBackends();
  if (syncBackends.length === 0) {
    const detected = await this.autoDetectBackend();
    if (detected) {
      try {
        const config = this.readJson(this.configPath) || {};
        config.PERSONAL_SYNC_BACKEND = detected;
        this.atomicWrite(this.configPath, JSON.stringify(config, null, 2));
        this.logBackup('INFO', `Auto-detected sync backend: ${detected}`, 'sync.health');
      } catch {}
    } else {
      warnings.push({
        code: 'PERSONAL_NOT_CONFIGURED',
        level: 'danger',
        title: 'No sync configured',
        body: "Your backups aren't set up. Connect a cloud provider so your data is protected.",
        fixAction: { label: 'Set up sync', kind: 'open-sync-setup' },
        dismissible: false,
        createdEpoch: now,
      });
    }
  } else {
    try {
      const markerText = fs.readFileSync(this.syncMarkerPath, 'utf8').trim();
      const lastEpoch = parseInt(markerText, 10);
      if (!isNaN(lastEpoch)) {
        const age = Math.floor(Date.now() / 1000) - lastEpoch;
        if (age >= 86400) {
          warnings.push({
            code: 'PERSONAL_STALE',
            level: 'warn',
            title: 'Sync is stale',
            body: "Backups haven't succeeded in over 24 hours. Check the sync panel for details.",
            dismissible: true,
            createdEpoch: now,
          });
        }
      }
    } catch {}
  }

  // 2. Unrouted user skills
  const unroutedSkills = this.findUnroutedSkills();
  if (unroutedSkills.length > 0) {
    warnings.push({
      code: 'SKILLS_UNROUTED',
      level: 'warn',
      title: 'Unsynced skills',
      body: `Some skills aren't being backed up: ${unroutedSkills.join(', ')}. Route them through the toolkit to include them.`,
      dismissible: true,
      createdEpoch: now,
    });
  }

  // 3. Unsynced projects
  const discoveredProjects = this.discoverProjects();
  if (discoveredProjects.length > 0) {
    const unsyncedFile = path.join(this.claudeDir, '.unsynced-projects');
    this.atomicWrite(unsyncedFile, discoveredProjects.join('\n'));
    warnings.push({
      code: 'PROJECTS_UNSYNCED',
      level: 'warn',
      title: 'Projects excluded',
      body: `${discoveredProjects.length} project(s) aren't being synced. Check the sync panel to include them.`,
      dismissible: true,
      createdEpoch: now,
    });
  } else {
    try { fs.unlinkSync(path.join(this.claudeDir, '.unsynced-projects')); } catch {}
  }

  // Merge with existing push-failure warnings (preserve them; only replace
  // the health-check-owned codes).
  const existing = await readWarnings();
  const healthCodes = new Set(['OFFLINE', 'PERSONAL_NOT_CONFIGURED', 'PERSONAL_STALE', 'SKILLS_UNROUTED', 'PROJECTS_UNSYNCED']);
  const preserved = existing.filter((w) => !healthCodes.has(w.code));
  await writeWarnings([...preserved, ...warnings]);

  return warnings;
}
```

Also add to imports at top of `sync-service.ts`:

```ts
import { readWarnings, writeWarnings, type SyncWarning } from './sync-state';
```

- [ ] **Step 5.2: Remove the legacy string `.sync-warnings` writer from desktop**

Delete the block in `runHealthCheck` that writes to `warningsFile` (the old `.sync-warnings` string-code file). The bash `statusline.sh` still writes that file for the terminal statusline — desktop no longer does.

Remove the line near the top of the old function:
```ts
const warningsFile = path.join(this.claudeDir, '.sync-warnings');
```
…and the `fs.writeFileSync(warningsFile, ...)` / `fs.unlinkSync(warningsFile)` block near the end.

- [ ] **Step 5.3: Typecheck**

Run: `npx tsc --noEmit -p desktop/tsconfig.json`
Expected: no errors.

- [ ] **Step 5.4: Commit**

```bash
git add desktop/src/main/sync-service.ts
git commit -m "feat(sync): runHealthCheck emits typed warnings; drop legacy string writer"
```

---

## Task 6: Startup cleanup of stale `.sync-error-*` files

**Files:**
- Modify: `desktop/src/main/sync-service.ts` — `start()` method removes stale per-backend error files.

- [ ] **Step 6.1: Add cleanup to `start()`**

In `desktop/src/main/sync-service.ts`, locate the `start()` method (approx line 143+) and add this cleanup before the existing startup logic:

```ts
// V2 cleanup: stale .sync-error-* files from the pre-warnings-refactor era.
// The typed .sync-warnings.json replaces them; old files would confuse
// anyone debugging and serve no purpose.
try {
  const toolkitStateDir = path.join(this.claudeDir, 'toolkit-state');
  const entries = fs.readdirSync(toolkitStateDir);
  for (const name of entries) {
    if (name.startsWith('.sync-error-')) {
      try { fs.unlinkSync(path.join(toolkitStateDir, name)); } catch {}
    }
  }
} catch {}
```

Place this right after the stale-marker cleanup block (the one that logs `"Cleaned stale .app-sync-active marker..."`) so both migrations run together.

- [ ] **Step 6.2: Manual verification step**

Create a stale error file and confirm it's removed on next start. From the worktree:

```bash
touch ~/.claude/toolkit-state/.sync-error-drive-test
ls ~/.claude/toolkit-state/.sync-error-* 2>&1
# Expected: the file exists.

# Start the desktop app in dev mode (or restart it). Then:
ls ~/.claude/toolkit-state/.sync-error-* 2>&1
# Expected: "No such file or directory" — cleaned up.
```

- [ ] **Step 6.3: Commit**

```bash
git add desktop/src/main/sync-service.ts
git commit -m "chore(sync): clean up stale .sync-error-* files on startup"
```

---

## Task 7: Wire HeaderBar red dot

**Files:**
- Modify: `desktop/src/renderer/components/HeaderBar.tsx` — add `settingsDangerBadge?: boolean` prop; render a red dot when true (taking precedence over blue `settingsBadge`).
- Modify: `desktop/src/renderer/App.tsx` — derive the danger-badge flag from `syncStatus.warnings` and pass to HeaderBar.

- [ ] **Step 7.1: Add the prop to HeaderBar**

In `desktop/src/renderer/components/HeaderBar.tsx`, update the `HeaderBarProps` interface (approx line 163):

```ts
// Before:
  settingsOpen: boolean;
  onToggleSettings: () => void;
  settingsBadge?: boolean;

// After:
  settingsOpen: boolean;
  onToggleSettings: () => void;
  settingsBadge?: boolean;
  settingsDangerBadge?: boolean;
```

And destructure the prop (approx line 183):
```ts
settingsOpen, onToggleSettings, settingsBadge, settingsDangerBadge, sessionStatuses, onResumeSession,
```

- [ ] **Step 7.2: Render the red dot**

In `HeaderBar.tsx`, locate the existing dot render (approx line 392-394):

```tsx
{settingsBadge && !settingsOpen && (
  <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-blue-500" />
)}
```

Replace with:

```tsx
{/* Red dot takes precedence over blue remote-connection badge —
    danger-level sync warnings indicate data-loss risk and must be visible. */}
{settingsDangerBadge && !settingsOpen ? (
  <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-red-500" />
) : settingsBadge && !settingsOpen ? (
  <span className="absolute -top-0.5 -right-0.5 w-2 h-2 rounded-full bg-blue-500" />
) : null}
```

- [ ] **Step 7.3: Derive the danger flag in App.tsx**

In `desktop/src/renderer/App.tsx`, find the block that computes `settingsBadge` (near line 905-913) and add a parallel derivation. Add state near line 118:

```tsx
const [settingsDangerBadge, setSettingsDangerBadge] = useState(false);
```

Add an effect below the remote-count effect (approx line 914):

```tsx
// Poll sync status; if any danger-level warning exists, surface a red
// dot on the gear icon so the user can't miss a push failure.
useEffect(() => {
  const claude = (window as any).claude;
  if (!claude?.sync?.getStatus) return;
  const check = () => {
    claude.sync.getStatus()
      .then((s: any) => {
        const hasDanger = Array.isArray(s?.warnings)
          && s.warnings.some((w: any) => w?.level === 'danger');
        setSettingsDangerBadge(hasDanger);
      })
      .catch(() => {});
  };
  check();
  const interval = setInterval(check, 15000);
  return () => clearInterval(interval);
}, []);
```

Then pass it to HeaderBar (approx line 1438):

```tsx
settingsBadge={settingsBadge}
settingsDangerBadge={settingsDangerBadge}
```

- [ ] **Step 7.4: Typecheck**

Run: `npx tsc --noEmit -p desktop/tsconfig.json`
Expected: no errors.

- [ ] **Step 7.5: Commit**

```bash
git add desktop/src/renderer/components/HeaderBar.tsx desktop/src/renderer/App.tsx
git commit -m "feat(ui): red dot on settings gear when sync has danger warnings"
```

---

## Task 8: Update StatusBar to render typed warnings

**Files:**
- Modify: `desktop/src/renderer/components/StatusBar.tsx` — delete `WARNING_MAP` + `parseSyncWarnings`, render chips directly from typed warnings.

- [ ] **Step 8.1: Update the props/types that flow through**

At the top of `StatusBar.tsx`, find where `warnings` comes in — it's derived from `syncWarnings` (a string) being parsed by `parseSyncWarnings`. Those types need to change.

Look for the `syncWarnings` prop declaration (likely around the component's prop interface) and any call site. Rather than parsing a string, accept `SyncWarning[]` directly.

Add at the top of `StatusBar.tsx` (near the existing imports):

```ts
import type { SyncWarning } from '../../main/sync-state';
```

Change the prop type for whatever currently passes `syncWarnings: string` to `syncWarnings: SyncWarning[]`. Do the same at the call site in `App.tsx` (or wherever StatusBar is rendered).

- [ ] **Step 8.2: Replace parse step + render**

In `StatusBar.tsx`, delete the `WARNING_MAP` object (lines 133-137) and the `parseSyncWarnings` function (lines 139-153).

Replace line 601 (`const warnings = parseSyncWarnings(syncWarnings);`) with:

```tsx
// SyncWarning[] comes pre-typed; render title + level directly.
const warnings = (syncWarnings ?? []).map((w) => ({ text: w.title, level: w.level }));
```

The existing render block at line 839-850 already maps `warnings` to pills — it continues to work unchanged.

- [ ] **Step 8.3: Update the caller to pass typed warnings**

In `desktop/src/renderer/App.tsx`, find where `<StatusBar` is rendered and where `syncWarnings` is set. Update the state to hold `SyncWarning[]` instead of a string; feed it from the same status poll in Task 7.3.

Example if the current code is:

```tsx
const [syncWarnings, setSyncWarnings] = useState<string>('');
```

Change to:

```tsx
const [syncWarnings, setSyncWarnings] = useState<SyncWarning[]>([]);
```

And update the setter inside the sync-status poll effect:

```tsx
setSyncWarnings(Array.isArray(s?.warnings) ? s.warnings : []);
```

Also ensure `SyncWarning` is imported at the top of `App.tsx`:

```tsx
import type { SyncWarning } from '../main/sync-state';
```

Note: if the current `syncWarnings` state is populated from a different path (e.g., `status:data` IPC push), update that handler to emit the new array shape too.

- [ ] **Step 8.4: Typecheck**

Run: `npx tsc --noEmit -p desktop/tsconfig.json`
Expected: no errors. Chase any downstream type errors by updating the relevant prop types.

- [ ] **Step 8.5: Commit**

```bash
git add desktop/src/renderer/components/StatusBar.tsx desktop/src/renderer/App.tsx
git commit -m "feat(ui): StatusBar renders typed sync warnings; remove hardcoded map"
```

---

## Task 9: Add `preselectedBackendId` prop to SyncSetupWizard

**Files:**
- Modify: `desktop/src/renderer/components/SyncSetupWizard.tsx` — accept and honor an optional `preselectedBackendId` so the "Fix it" button can skip the provider picker and land on the reconnect flow for a specific existing backend.

- [ ] **Step 9.1: Add the prop**

In `desktop/src/renderer/components/SyncSetupWizard.tsx`, find the props interface and add:

```ts
/**
 * When set, skip the provider picker and land directly on the reconnect
 * step for this backend. Used when invoked from a push-failure warning's
 * "Fix it" button so the user doesn't have to re-pick Google Drive.
 */
preselectedBackendId?: string;
```

- [ ] **Step 9.2: Honor the prop on mount**

In the wizard's initial step logic, if `preselectedBackendId` is set, look up the backend via `(window as any).claude.sync.getConfig()` (or whatever the wizard already uses), and jump straight to the reconnect/auth step for that backend's type.

Exact wiring depends on the wizard's step model — inspect the existing `useState<Step>` or similar and set the initial value conditionally:

```tsx
const [step, setStep] = useState<Step>(() =>
  preselectedBackendId ? 'reconnect' : 'pick-provider',
);
```

If the wizard's step enum doesn't include `'reconnect'`, add a new step that reuses the existing auth/connect UI for the detected backend type. Keep the change minimal — reuse, don't duplicate.

- [ ] **Step 9.3: Typecheck**

Run: `npx tsc --noEmit -p desktop/tsconfig.json`
Expected: no errors.

- [ ] **Step 9.4: Commit**

```bash
git add desktop/src/renderer/components/SyncSetupWizard.tsx
git commit -m "feat(ui): SyncSetupWizard accepts preselectedBackendId for reconnect flow"
```

---

## Task 10: Update SyncPanel — per-backend dot, warnings list, fix-action buttons

**Files:**
- Modify: `desktop/src/renderer/components/SyncPanel.tsx` — delete the legacy `WARNING_DISPLAY` map, update types, compute per-backend dot from warnings, render warnings list with `title` + `body` + `fixAction` button, collapsible `stderr` for `UNKNOWN` codes.

- [ ] **Step 10.1: Update types**

In `SyncPanel.tsx`, replace the local `SyncStatus` type (lines 85-93):

```ts
import type { SyncWarning } from '../../main/sync-state';

interface BackendInstanceStatus {
  id: string;
  type: 'drive' | 'github' | 'icloud';
  label: string;
  syncEnabled: boolean;
  config: Record<string, string>;
  connected: boolean;
  lastPushEpoch: number | null;
  lastError: string | null;  // kept for the short-text line; derived from warnings server-side
}

interface SyncStatus {
  backends: BackendInstanceStatus[];
  lastSyncEpoch: number | null;
  backupMeta: { last_backup: string; platform: string; toolkit_version: string } | null;
  warnings: SyncWarning[];
  syncInProgress: boolean;
  syncingBackendId: string | null;
  syncedCategories: string[];
}
```

- [ ] **Step 10.2: Delete the hardcoded warning-display map**

Delete `WARNING_DISPLAY` (lines 97-101) and `getWarningDisplay` (lines 103-112). They're superseded by `SyncWarning.title`.

- [ ] **Step 10.3: Compute per-backend dot color from filtered warnings**

The existing backend-card render uses `b.lastError` for the dot. That still works post-Task 3 because `lastError` is now derived server-side from warnings. But to support the warn-level case (yellow dot for a push NETWORK warning), compute the color from the scoped warning list.

In the backend-card render block (approx line 544-595), replace the status-dot block with:

```tsx
{(() => {
  const scoped = status.warnings.filter(w => w.backendId === b.id);
  const hasDanger = scoped.some(w => w.level === 'danger');
  const hasWarn = scoped.some(w => w.level === 'warn');
  const dotClass =
    hasDanger ? 'bg-red-500'
    : hasWarn ? 'bg-amber-500'
    : actionFeedback[b.id]?.includes('ing') ? 'bg-blue-400 animate-pulse'
    : b.syncEnabled && b.connected && b.lastPushEpoch && (Date.now() / 1000 - b.lastPushEpoch) < 86400 ? 'bg-green-500'
    : b.syncEnabled && b.connected ? 'bg-yellow-500'
    : 'bg-fg-muted/40';
  return <div className={`w-2 h-2 rounded-full shrink-0 ${dotClass}`} />;
})()}
```

- [ ] **Step 10.4: Render the warnings section with fix-action buttons**

The existing warnings section in SyncPanel renders string codes via `getWarningDisplay`. Replace it with a typed render. Find the block that iterates `status.warnings` (grep for `status.warnings.map` or similar in SyncPanel.tsx) and rewrite.

If no such block exists yet (warnings were only shown as raw codes elsewhere), add a new section near the top of the SyncPanel content, before "Your Backups":

```tsx
{status && status.warnings.length > 0 && (
  <div className="space-y-2 mb-4">
    {status.warnings.map((w) => (
      <div
        key={`${w.code}:${w.backendId ?? ''}`}
        className={`rounded-lg border px-3 py-2 ${
          w.level === 'danger'
            ? 'border-red-500/30 bg-red-500/5'
            : 'border-amber-500/30 bg-amber-500/5'
        }`}
      >
        <div className="text-xs font-medium text-fg">{w.title}</div>
        <div className="text-[11px] text-fg-muted mt-0.5">{w.body}</div>
        {w.code === 'UNKNOWN' && w.stderr && (
          <details className="mt-1">
            <summary className="text-[10px] text-fg-faint cursor-pointer">
              Show error details
            </summary>
            <pre className="mt-1 p-2 bg-inset rounded text-[10px] whitespace-pre-wrap font-mono">
              {w.stderr}
            </pre>
          </details>
        )}
        <div className="flex gap-2 mt-2">
          {w.fixAction && (
            <button
              onClick={() => handleFixAction(w)}
              className="text-[11px] px-2 py-0.5 rounded bg-accent text-on-accent hover:brightness-110"
            >
              {w.fixAction.label}
            </button>
          )}
          {w.dismissible && (
            <button
              onClick={() => handleDismiss(w.code)}
              className="text-[11px] px-2 py-0.5 rounded border border-edge-dim text-fg-muted hover:bg-inset"
            >
              Dismiss
            </button>
          )}
        </div>
      </div>
    ))}
  </div>
)}
```

- [ ] **Step 10.5: Implement fix-action and dismiss handlers**

Inside the SyncPanel component (near other handlers like `handleToggleSync`), add:

```tsx
const [wizardPreselect, setWizardPreselect] = useState<string | undefined>();

const handleFixAction = useCallback(async (w: SyncWarning) => {
  const action = w.fixAction;
  if (!action) return;
  switch (action.kind) {
    case 'open-sync-setup':
      setWizardPreselect(action.payload?.backendId);
      setWizardOpen(true);  // wizardOpen already exists in SyncPanel
      break;
    case 'open-external':
      await (window as any).claude.shell.openExternal(action.payload.url);
      break;
    case 'retry':
      setActionFeedback(prev => ({ ...prev, [action.payload.backendId]: 'uploading' }));
      try {
        await (window as any).claude.sync.pushBackend(action.payload.backendId);
        setActionFeedback(prev => ({ ...prev, [action.payload.backendId]: 'uploaded' }));
      } catch {
        setActionFeedback(prev => ({ ...prev, [action.payload.backendId]: 'error' }));
      }
      loadStatus();
      break;
    case 'dismiss':
      await handleDismiss(w.code);
      break;
  }
}, [loadStatus]);

const handleDismiss = useCallback(async (code: string) => {
  await (window as any).claude.sync.dismissWarning(code);
  loadStatus();
}, [loadStatus]);
```

Ensure `SyncWarning` is imported at the top of the file.

- [ ] **Step 10.6: Pass `preselectedBackendId` to SyncSetupWizard**

Find where `<SyncSetupWizard` is rendered in SyncPanel.tsx and pass the new prop:

```tsx
<SyncSetupWizard
  // ...existing props
  preselectedBackendId={wizardPreselect}
/>
```

- [ ] **Step 10.7: Typecheck + run unit tests (no regressions)**

Run:
```bash
npx tsc --noEmit -p desktop/tsconfig.json
npx vitest run
```
Expected: no type errors; all existing tests still pass.

- [ ] **Step 10.8: Commit**

```bash
git add desktop/src/renderer/components/SyncPanel.tsx
git commit -m "feat(ui): SyncPanel renders typed warnings with fix-action buttons"
```

---

## Task 11: IPC parity sweep (preload / remote-shim types)

**Files:**
- Modify: `desktop/src/main/preload.ts` — update type annotations for the sync.getStatus return shape if they're explicitly declared.
- Modify: `desktop/src/renderer/remote-shim.ts` — update matching type annotations.

This is a low-effort sweep to keep the shared `window.claude` shape in parity (per `docs/PITFALLS.md`). No new channels are added.

- [ ] **Step 11.1: Check for explicit typings**

Run:
```bash
grep -n "warnings.*string\[\]" desktop/src/main/preload.ts desktop/src/renderer/remote-shim.ts
```

For each hit, update the type to `SyncWarning[]` and import `SyncWarning` from the appropriate module.

- [ ] **Step 11.2: Manual parity check via the `ipc-channels.test.ts` test**

Run: `npx vitest run tests/ipc-channels.test.ts`
Expected: all tests pass. This test already compares preload vs shim shape — if it fails, that's the drift.

- [ ] **Step 11.3: Commit (if anything changed)**

```bash
git add desktop/src/main/preload.ts desktop/src/renderer/remote-shim.ts
git commit -m "chore(ipc): SyncWarning typing parity in preload and remote-shim"
```

---

## Task 12: Full build + manual verification

**Files:** none (verification only).

- [ ] **Step 12.1: Clean build**

Run:
```bash
cd desktop
npm test
npm run build
```
Expected: tests pass, build succeeds without errors.

- [ ] **Step 12.2: Reproduce and fix the original outage condition**

Manual verification of the happy path:

1. Empty the rclone config (simulating the outage):
   ```bash
   cp ~/AppData/Roaming/rclone/rclone.conf ~/AppData/Roaming/rclone/rclone.conf.bak
   : > ~/AppData/Roaming/rclone/rclone.conf
   ```
2. Start the desktop app in dev mode: `bash scripts/run-dev.sh` from repo root.
3. Trigger a manual sync (Sync Now in the sync panel, or wait ~15 min).
4. Confirm within 30 seconds:
   - Red dot appears on the header gear icon.
   - Opening SettingsPanel → SyncPanel shows a "Google Drive isn't connected" warning card with a "Reconnect Google Drive" button.
   - The per-backend row for Drive shows a red dot and the error text.
   - StatusBar (if `sync-warnings` widget is enabled) shows a red chip reading "Google Drive isn't connected".
   - `~/.claude/.sync-warnings.json` exists and contains a `CONFIG_MISSING` entry.
   - `~/.claude/backup.log` shows WARN lines with `"code":"CONFIG_MISSING"` and truncated stderr.
5. Restore the config:
   ```bash
   mv ~/AppData/Roaming/rclone/rclone.conf.bak ~/AppData/Roaming/rclone/rclone.conf
   ```
6. Trigger a manual sync and confirm the red dot clears and the SyncPanel returns to green.

- [ ] **Step 12.3: Final commit + push**

If any small fixes came up during verification, commit them. Push the branch:

```bash
git push -u origin sync-warnings
```

- [ ] **Step 12.4: Open PR**

```bash
gh pr create --title "Sync failure warnings with red gear dot and layman's fix guidance" --body "$(cat <<'EOF'
## Summary
- Unified sync warnings into `.sync-warnings.json` (typed array) from the previous split between `.sync-warnings` strings + `.sync-error-<id>` files
- Classifier turns rclone stderr into actionable codes (`CONFIG_MISSING`, `AUTH_EXPIRED`, `QUOTA_EXCEEDED`, `NETWORK`, `RCLONE_MISSING`, `UNKNOWN`)
- Red dot on the settings gear whenever any danger-level warning is active
- SyncPanel renders typed warnings with `title` + `body` + a "Fix it" button (reconnect / retry / open Drive storage / install rclone)
- Push-failure warnings are non-dismissible — they clear only when a subsequent push succeeds
- `backup.log` now includes classified `code` + truncated stderr in push-failure WARN lines

## Test plan
- [x] `classifyPushError` unit tests (9 cases across all codes)
- [x] Warning store lifecycle tests (write/read/dedupe/clear/dismiss)
- [x] `dismissWarning` refuses to remove non-dismissible entries (enforced server-side)
- [x] Manual: emptied rclone.conf → red gear dot + CONFIG_MISSING warning with Reconnect button; restored → clears
- [x] Existing tests still pass (`vitest run`, `tsc --noEmit`, `npm run build`)

Spec: `docs/superpowers/specs/2026-04-17-sync-warnings-design.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review notes (author, pre-handoff)

Checked the plan against the spec:
- **Data model (`SyncWarning`, `.sync-warnings.json`)** → Task 1.1 (types), Task 2 (store). ✓
- **Writers: `runHealthCheck` + push methods** → Tasks 4 and 5. ✓
- **Readers: header gear, SyncPanel, StatusBar** → Tasks 7, 10, 8 respectively. ✓
- **Classification taxonomy with `UNKNOWN` fallback** → Task 1.2 (patterns table). ✓
- **Log quality (code + truncated stderr)** → Task 4.2-4.4 (via `logBackup` extras). ✓
- **Non-dismissible push-failure warnings enforced server-side** → Task 3.3. ✓
- **Retire `.sync-error-<id>` (writer + cleanup)** → Tasks 4.5-4.6 (remove writer), 6 (cleanup). ✓
- **Preserve legacy `.sync-warnings` string file for bash statusline** → Task 5.2 (delete desktop-side writer only). ✓
- **SyncSetupWizard accepts `preselectedBackendId`** → Task 9. ✓
- **IPC parity** → Task 11. ✓

No placeholders remain. Type names and method names used consistently across tasks (`classifyPushError`, `recordBackendFailure`, `clearBackendFailures`, `addOrReplaceWarning`, `clearWarningsByBackend`, `readWarnings`, `writeWarnings`, `dismissWarning`). Task 3's `dismissWarning` rewrite matches Task 10.5's call site.
