# Deprecate `youcoded-core` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the `youcoded-core` repo from YouCoded's architecture. Absorb its one genuinely useful hook (`write-guard.sh`) into the app as a native-bundled hook on both platforms, actively clean up the legacy clone on existing users' machines, remove the clone path and all `youcoded-core`-aware code branches from the app, then archive the repo.

**Architecture:** Staged rollout over two app releases. Release N adds the native-bundled write-guard + launch-time cleanup + stops cloning, while keeping existing dead `youcoded-core`-aware branches in place as no-ops. Release N+1 (after N has been live long enough to verify the cleanup works on real installs) removes all dead branches. After N+1, files inside `youcoded-core` are deleted, surviving specs move to the app repo, and the GitHub repo is archived. Workspace scaffold (`youcoded-dev`) docs get pruned along the way.

**Tech Stack:** Node.js + TypeScript (desktop Electron main process), Kotlin (Android), vitest for desktop unit tests, bash for hook scripts.

**Spec:** `docs/superpowers/specs/2026-04-21-deprecate-youcoded-core-design.md`

**Scope note:** This is a cross-repo plan. It touches three repos: `youcoded-dev` (workspace), `youcoded` (the app — both `desktop/` and `app/`), and `youcoded-core` (the repo being deprecated). All paths in this document are rooted at `C:/Users/desti/youcoded-dev/` unless otherwise specified.

**Phase gates:**
- Phase 1 → Phase 2: Release N has shipped and Destin has run it on his own machine without issues for roughly one to two weeks. Legacy clone is confirmed removed on his machine; write-guard still works.
- Phase 2 → Phase 3: Release N+1 has shipped. A global grep for `youcoded-core` in the `youcoded` repo returns zero matches outside historical changelogs.
- Phase 4 (workspace cleanup) can run in parallel with any other phase after Phase 1 is complete.

---

## Phase 1: Release N — additive changes + active cleanup

### Task 1: Copy `write-guard.sh` into the desktop bundle

**Files:**
- Copy from: `youcoded-core/hooks/write-guard.sh`
- Copy from: `youcoded-core/hooks/lib/hook-preamble.sh`
- Create: `youcoded/desktop/hook-scripts/write-guard.sh`
- Create: `youcoded/desktop/hook-scripts/lib/hook-preamble.sh`

**Context:** `write-guard.sh` conditionally sources `$HOOK_DIR/lib/hook-preamble.sh` at line 8 (the `[[ -f ... ]] &&` check). Keeping the same relative `lib/` path lets us copy both files verbatim without edits.

- [ ] **Step 1: Copy both files with identical content**

```bash
mkdir -p youcoded/desktop/hook-scripts/lib
cp youcoded-core/hooks/write-guard.sh youcoded/desktop/hook-scripts/write-guard.sh
cp youcoded-core/hooks/lib/hook-preamble.sh youcoded/desktop/hook-scripts/lib/hook-preamble.sh
chmod +x youcoded/desktop/hook-scripts/write-guard.sh
chmod +x youcoded/desktop/hook-scripts/lib/hook-preamble.sh
```

- [ ] **Step 2: Ensure Git records the execute bit (Windows git doesn't set this automatically)**

```bash
cd youcoded
git update-index --chmod=+x desktop/hook-scripts/write-guard.sh
git update-index --chmod=+x desktop/hook-scripts/lib/hook-preamble.sh
```

- [ ] **Step 3: Verify the relative-path sourcing will still work**

```bash
grep -n 'hook-preamble' youcoded/desktop/hook-scripts/write-guard.sh
```

Expected: one match at line 8 showing `$HOOK_DIR/lib/hook-preamble.sh`.

- [ ] **Step 4: Update the comment at the top of `write-guard.sh` to reflect new ownership**

Find line ~2 which currently reads:
```bash
# PreToolUse hook: blocks writes to tracked files when another active
# Claude session last modified the file (same-machine concurrency guard).
```

No text change needed — the comment is already app-agnostic. Skip if already correct.

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add desktop/hook-scripts/write-guard.sh desktop/hook-scripts/lib/hook-preamble.sh
git commit -m "feat(hooks): bundle write-guard natively in desktop

Copied verbatim from youcoded-core/hooks/. Next task registers it
via install-hooks.js. Part of youcoded-core deprecation."
```

---

### Task 2: Copy `write-guard.sh` into the Android assets bundle

**Files:**
- Copy from: `youcoded-core/hooks/write-guard.sh`
- Copy from: `youcoded-core/hooks/lib/hook-preamble.sh`
- Create: `youcoded/app/src/main/assets/write-guard.sh`
- Create: `youcoded/app/src/main/assets/lib/hook-preamble.sh`

**Context:** Android's `Bootstrap.installHooks()` opens assets via `context.assets.open("relative/path.sh")`. Nested directories under `assets/` are supported — the existing bundle has a flat layout but there's nothing preventing a `lib/` subdir.

- [ ] **Step 1: Copy both files**

```bash
mkdir -p youcoded/app/src/main/assets/lib
cp youcoded-core/hooks/write-guard.sh youcoded/app/src/main/assets/write-guard.sh
cp youcoded-core/hooks/lib/hook-preamble.sh youcoded/app/src/main/assets/lib/hook-preamble.sh
```

- [ ] **Step 2: Android assets don't need Git's execute bit (assets are copied with `setExecutable(true)` at deploy time by Bootstrap), but commit them anyway**

```bash
cd youcoded
git add app/src/main/assets/write-guard.sh app/src/main/assets/lib/hook-preamble.sh
git commit -m "feat(android): bundle write-guard + preamble in assets

Mirror of desktop/hook-scripts/. Next task wires deployment +
registration in Bootstrap.kt. Part of youcoded-core deprecation."
```

---

### Task 3: Register `write-guard.sh` in `install-hooks.js` (desktop)

**Files:**
- Modify: `youcoded/desktop/scripts/install-hooks.js:114-138` (add new registration block, modeled on title-update)

**Context:** The existing title-update registration block (lines 114-138) is the template. We follow the same pattern: resolve the raw path, swap `app.asar/` → `app.asar.unpacked/` for packaged builds, apply the worktree-safety guard, register on `settings.hooks.PreToolUse` with in-place update semantics and matcher `"Write|Edit"`.

`install-hooks.js` is a self-invoking script (not a module), so unit testing is not established here. Verification is a manual boot + inspect cycle covered in Task 11.

- [ ] **Step 1: Insert the write-guard registration block after the title-update registration**

Open `youcoded/desktop/scripts/install-hooks.js`. Locate the line:

```js
  // --- Remove done-sound.sh (app handles completion sounds natively) ---
```

(Around line 162.) Insert the following new block immediately BEFORE that line:

```js
  // --- Write-guard hook ---
  // PreToolUse on Write|Edit matchers. Blocks concurrent writes to tracked
  // files when another active Claude session last modified them. Absorbed
  // from youcoded-core as part of toolkit deprecation (2026-04).
  const rawWriteGuardPath = path.resolve(__dirname, '..', 'hook-scripts', 'write-guard.sh');
  const unpackedWriteGuardPath = rawWriteGuardPath.replace(`app.asar${path.sep}`, `app.asar.unpacked${path.sep}`);
  const activeWriteGuardPath = fs.existsSync(unpackedWriteGuardPath) ? unpackedWriteGuardPath : rawWriteGuardPath;

  if (!settings.hooks['PreToolUse']) {
    settings.hooks['PreToolUse'] = [];
  }

  const writeGuardCmd = `bash ${JSON.stringify(activeWriteGuardPath)}`;
  const writeGuardEntry = {
    matcher: 'Write|Edit',
    hooks: [{ type: 'command', command: writeGuardCmd, timeout: 10 }],
  };

  const existingWriteGuardIdx = settings.hooks['PreToolUse'].findIndex((matcher) =>
    matcher.hooks?.some((h) => h.command?.includes('write-guard.sh'))
  );

  if (existingWriteGuardIdx >= 0) {
    settings.hooks['PreToolUse'][existingWriteGuardIdx] = writeGuardEntry;
  } else {
    settings.hooks['PreToolUse'].push(writeGuardEntry);
  }
```

- [ ] **Step 2: Verify the worktree-safety guard still protects the new path**

The existing guard at lines 29-36 only checks `RELAY_PATH`. The write-guard path uses the same `path.resolve(__dirname, ...)` pattern, so if it's inside a worktree, so is the relay path — the existing guard covers it. Confirm by reading lines 29-36 and verifying no per-path changes are needed.

- [ ] **Step 3: Update the final log line to mention write-guard**

Locate this line (around line 190):

```js
  console.log('Hooks installed for ' + FIRE_AND_FORGET_EVENTS.length + ' fire-and-forget events + PermissionRequest (blocking) + auto-title + statusline');
```

Replace with:

```js
  console.log('Hooks installed for ' + FIRE_AND_FORGET_EVENTS.length + ' fire-and-forget events + PermissionRequest (blocking) + auto-title + statusline + write-guard');
```

- [ ] **Step 4: Smoke-test the script against a temp settings.json**

```bash
cd youcoded/desktop
node -e "
const fs = require('fs');
const os = require('os');
const path = require('path');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'install-hooks-smoke-'));
const origHome = os.homedir;
os.homedir = () => tmp;
fs.mkdirSync(path.join(tmp, '.claude'), { recursive: true });
require('./scripts/install-hooks.js');
const s = JSON.parse(fs.readFileSync(path.join(tmp, '.claude', 'settings.json'), 'utf8'));
const pt = s.hooks.PreToolUse || [];
const wg = pt.find(e => e.matcher === 'Write|Edit' && e.hooks.some(h => h.command.includes('write-guard.sh')));
console.log(wg ? 'OK: write-guard registered' : 'FAIL: write-guard not found');
os.homedir = origHome;
fs.rmSync(tmp, { recursive: true });
"
```

Expected output: `OK: write-guard registered`

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add desktop/scripts/install-hooks.js
git commit -m "feat(hooks): register bundled write-guard in install-hooks.js

Adds PreToolUse registration for the newly-bundled write-guard.sh
with matcher 'Write|Edit' and timeout 10. In-place update
semantics match the other app-owned hooks. Part of youcoded-core
deprecation."
```

---

### Task 4: Deploy + register `write-guard.sh` in `Bootstrap.installHooks()` (Android)

**Files:**
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/Bootstrap.kt:866-1055` (inside `installHooks()` function; add deployment + registration block)

**Context:** The template is the title-update deployment block at lines 979-1017. We deploy `write-guard.sh` + `lib/hook-preamble.sh` from assets to `~/.claude-mobile/hooks/`, mark executable, then register a `PreToolUse` hook with matcher `"Write|Edit"` using the existing `bashPath` and additive merge pattern.

- [ ] **Step 1: Add the asset deployment block after the title-update deployment**

Open `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/Bootstrap.kt`. Locate line 1017 (end of the `if (!titleHookRegistered) { ... }` block). Insert the following block immediately after that closing brace, BEFORE the `// Deploy CLAUDE.md instruction` line at 1019:

```kotlin
        // Write-guard hook: PreToolUse on Write|Edit. Absorbed from
        // youcoded-core as part of toolkit deprecation (2026-04).
        val writeGuardHook = File(mobileDir, "hooks/write-guard.sh")
        val writeGuardPreamble = File(mobileDir, "hooks/lib/hook-preamble.sh")
        writeGuardHook.parentFile?.mkdirs()
        writeGuardPreamble.parentFile?.mkdirs()
        context.assets.open("write-guard.sh").use { input ->
            writeGuardHook.outputStream().use { output -> input.copyTo(output) }
        }
        context.assets.open("lib/hook-preamble.sh").use { input ->
            writeGuardPreamble.outputStream().use { output -> input.copyTo(output) }
        }
        writeGuardHook.setExecutable(true)
        writeGuardPreamble.setExecutable(true)

        val writeGuardCommand = "$bashPath ${writeGuardHook.absolutePath}"
        val preToolUseArray = hooksObj.optJSONArray("PreToolUse") ?: org.json.JSONArray()
        var writeGuardRegistered = false
        for (i in 0 until preToolUseArray.length()) {
            val entry = preToolUseArray.optJSONObject(i)
            val hooks = entry?.optJSONArray("hooks")
            if (hooks != null) {
                for (j in 0 until hooks.length()) {
                    val h = hooks.optJSONObject(j)
                    if (h?.optString("command")?.contains("write-guard.sh") == true) {
                        writeGuardRegistered = true; break
                    }
                }
            }
            if (writeGuardRegistered) break
        }
        if (!writeGuardRegistered) {
            val hookEntry = org.json.JSONObject()
            hookEntry.put("matcher", "Write|Edit")
            val hooksList = org.json.JSONArray()
            val hookDef = org.json.JSONObject()
            hookDef.put("type", "command")
            hookDef.put("command", writeGuardCommand)
            hookDef.put("timeout", 10)
            hooksList.put(hookDef)
            hookEntry.put("hooks", hooksList)
            preToolUseArray.put(hookEntry)
            hooksObj.put("PreToolUse", preToolUseArray)
        }
```

- [ ] **Step 2: Verify the Kotlin compiles**

```bash
cd youcoded
./gradlew :app:compileDebugKotlin
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
cd youcoded
git add app/src/main/kotlin/com/youcoded/app/runtime/Bootstrap.kt
git commit -m "feat(android): deploy + register write-guard hook

Mirror of desktop's install-hooks.js write-guard block. Deploys
write-guard.sh + lib/hook-preamble.sh from assets to
~/.claude-mobile/hooks/ and registers PreToolUse matcher
'Write|Edit'. Part of youcoded-core deprecation."
```

---

### Task 5: Create `legacy-cleanup.ts` (desktop, TDD)

**Files:**
- Create: `youcoded/desktop/src/main/legacy-cleanup.ts`
- Create: `youcoded/desktop/tests/legacy-cleanup.test.ts`

**Context:** The module pattern follows `symlink-cleanup.ts`. Export a `cleanupLegacyYoucodedCore()` function that returns `{ removed: boolean, path?: string }`. It detects `~/.claude/plugins/youcoded-core/` and removes it recursively; non-existence is a no-op; errors are caught and returned in an error field so the caller can log but never crash startup.

Tests use the same `tmpHome` pattern as `symlink-cleanup.test.ts` — `os.homedir` is monkey-patched per-test to point at a temp dir.

- [ ] **Step 1: Write the failing test file**

Create `youcoded/desktop/tests/legacy-cleanup.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

const { cleanupLegacyYoucodedCore } = await import('../src/main/legacy-cleanup');

describe('cleanupLegacyYoucodedCore', () => {
  let tmpHome: string;
  let origHomedir: typeof os.homedir;

  beforeEach(() => {
    tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), 'youcoded-legacy-cleanup-'));
    origHomedir = os.homedir;
    (os as any).homedir = () => tmpHome;
  });

  afterEach(() => {
    (os as any).homedir = origHomedir;
    try { fs.rmSync(tmpHome, { recursive: true, force: true }); } catch {}
  });

  function mkdir(p: string) { fs.mkdirSync(p, { recursive: true }); }
  function write(p: string, content: string) { mkdir(path.dirname(p)); fs.writeFileSync(p, content); }

  it('no-ops and returns removed:false when the legacy directory is absent', () => {
    const result = cleanupLegacyYoucodedCore();
    expect(result.removed).toBe(false);
    expect(result.error).toBeUndefined();
  });

  it('deletes the directory recursively and returns removed:true', () => {
    const legacyDir = path.join(tmpHome, '.claude', 'plugins', 'youcoded-core');
    write(path.join(legacyDir, 'hooks', 'write-guard.sh'), '#!/bin/bash\n');
    write(path.join(legacyDir, 'VERSION'), '1.1.1\n');
    write(path.join(legacyDir, 'nested', 'deep', 'file.txt'), 'content');

    const result = cleanupLegacyYoucodedCore();

    expect(result.removed).toBe(true);
    expect(result.path).toBe(legacyDir);
    expect(fs.existsSync(legacyDir)).toBe(false);
  });

  it('leaves sibling plugin directories alone', () => {
    const legacyDir = path.join(tmpHome, '.claude', 'plugins', 'youcoded-core');
    const siblingDir = path.join(tmpHome, '.claude', 'plugins', 'marketplaces');
    write(path.join(legacyDir, 'VERSION'), '1.1.1\n');
    write(path.join(siblingDir, 'youcoded', 'plugins', 'somepkg', 'plugin.json'), '{}');

    const result = cleanupLegacyYoucodedCore();

    expect(result.removed).toBe(true);
    expect(fs.existsSync(legacyDir)).toBe(false);
    expect(fs.existsSync(siblingDir)).toBe(true);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd youcoded/desktop
npx vitest run tests/legacy-cleanup.test.ts
```

Expected: FAIL with a module-not-found or import error for `../src/main/legacy-cleanup`.

- [ ] **Step 3: Implement `legacy-cleanup.ts`**

Create `youcoded/desktop/src/main/legacy-cleanup.ts`:

```typescript
import fs from 'fs';
import os from 'os';
import path from 'path';

/**
 * Legacy Cleanup — youcoded-core toolkit deprecation.
 *
 * Prior to the 2026-04 deprecation, the app cloned the youcoded-core repo
 * to ~/.claude/plugins/youcoded-core/ via prerequisite-installer.cloneToolkit()
 * and relied on the HookReconciler to register its hooks into settings.json.
 *
 * Post-deprecation, the one surviving hook (write-guard.sh) ships bundled
 * inside the app. Users who upgraded from a prior version still have the
 * legacy clone on disk with its stale hook entries pointing at it. This
 * module removes that directory on app launch. The subsequent reconcileHooks()
 * call's pruneDeadPluginHooks() pass then strips the orphaned settings.json
 * entries automatically.
 *
 * Non-fatal on error (permission issues, mount issues, etc.) — the caller
 * logs but never throws. Worst case, the legacy dir sits there and its old
 * hooks keep firing until the next successful cleanup attempt.
 */

export interface LegacyCleanupResult {
  removed: boolean;
  path?: string;
  error?: string;
}

export function cleanupLegacyYoucodedCore(): LegacyCleanupResult {
  const legacyPath = path.join(os.homedir(), '.claude', 'plugins', 'youcoded-core');

  if (!fs.existsSync(legacyPath)) {
    return { removed: false };
  }

  try {
    fs.rmSync(legacyPath, { recursive: true, force: true });
    return { removed: true, path: legacyPath };
  } catch (e) {
    return { removed: false, path: legacyPath, error: String(e) };
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd youcoded/desktop
npx vitest run tests/legacy-cleanup.test.ts
```

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add desktop/src/main/legacy-cleanup.ts desktop/tests/legacy-cleanup.test.ts
git commit -m "feat(main): add legacy-cleanup module for youcoded-core removal

Deletes ~/.claude/plugins/youcoded-core/ on app launch. The
subsequent reconcileHooks() pruneDeadPluginHooks() pass strips
orphaned settings.json entries automatically. Non-fatal on
errors. Next task wires into main.ts startup."
```

---

### Task 6: Wire `legacy-cleanup` into `main.ts` startup

**Files:**
- Modify: `youcoded/desktop/src/main/main.ts:1041-1054` (insert legacy-cleanup call before `reconcileHooks`)

**Context:** The ordering matters: legacy-cleanup must run BEFORE `reconcileHooks()` so that `pruneDeadPluginHooks()` sees the now-missing scripts and removes the orphaned entries on the same launch. Ordering AFTER install-hooks.js (which registers the new bundled write-guard) means users never have a window where the concurrency guard is missing.

- [ ] **Step 1: Insert the legacy-cleanup call**

Open `youcoded/desktop/src/main/main.ts`. Locate line 1042 (the comment `// Decomposition v3 §9.2: reconcile plugin hooks-manifest.json...`). Insert immediately BEFORE that comment block:

```typescript
  // Legacy cleanup: youcoded-core was deprecated 2026-04. Users who
  // upgraded from a prior version still have the legacy clone at
  // ~/.claude/plugins/youcoded-core/ with stale settings.json entries
  // pointing into it. Delete the directory; the reconcileHooks() call
  // below prunes the orphaned entries via pruneDeadPluginHooks().
  try {
    const { cleanupLegacyYoucodedCore } = require('./legacy-cleanup');
    const legacyResult = cleanupLegacyYoucodedCore();
    if (legacyResult.removed) {
      log('INFO', 'Main', 'Legacy youcoded-core clone removed', { path: legacyResult.path });
    } else if (legacyResult.error) {
      log('WARN', 'Main', 'Legacy youcoded-core cleanup failed', { path: legacyResult.path, error: legacyResult.error });
    }
  } catch (e) {
    log('ERROR', 'Main', 'Failed to run legacy cleanup', { error: String(e) });
  }

```

- [ ] **Step 2: Verify TypeScript compiles**

```bash
cd youcoded/desktop
npx tsc --noEmit
```

Expected: no errors. (If any unrelated errors exist in the codebase, confirm they pre-dated this change via `git stash` + recompile.)

- [ ] **Step 3: Verify install-hooks.js runs BEFORE the new legacy-cleanup call**

Read `youcoded/desktop/src/main/main.ts` lines 1010-1054. Confirm the order is:
1. `install-hooks.js` invocation (around line 1027)
2. `hookRelay.start()` (line 1037)
3. **Legacy cleanup** (newly inserted)
4. `reconcileHooks()` (around line 1050)

If out of order, adjust placement.

- [ ] **Step 4: Commit**

```bash
cd youcoded
git add desktop/src/main/main.ts
git commit -m "feat(main): wire legacy-cleanup into startup

Runs before reconcileHooks() so that pruneDeadPluginHooks() can
strip the orphaned settings.json entries on the same launch.
Runs after install-hooks.js so users never have a window with
write-guard missing. Part of youcoded-core deprecation."
```

---

### Task 7: Android legacy cleanup in `Bootstrap.kt`

**Files:**
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/Bootstrap.kt` (add `cleanupLegacyYoucodedCore()` method and call it from the appropriate startup path)

**Context:** Android's `Bootstrap` is called by `SessionService` on startup. The pattern is: add a private method that handles the cleanup, then call it before or alongside `installHooks()`. Unlike desktop, Android has no `HookReconciler` driven by manifests (its own `HookReconciler.kt` does something different) — but the legacy clone still shouldn't sit on disk, and Android's own `installHooks()` writes the new write-guard path, superseding anything stale.

- [ ] **Step 1: Add the cleanup method to `Bootstrap.kt`**

Open `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/Bootstrap.kt`. Add a new private method (place it near the other deployment helpers, e.g., just above `installHooks()` at line 866):

```kotlin
    /**
     * Legacy cleanup: youcoded-core toolkit was deprecated 2026-04.
     * Users who upgraded from a prior version may have the legacy clone
     * at ~/.claude/plugins/youcoded-core/ with stale settings.json entries
     * pointing into it. Delete the directory and let installHooks() write
     * the replacement write-guard entry that supersedes the stale one.
     * Non-fatal on error.
     */
    private fun cleanupLegacyYoucodedCore() {
        val legacyDir = File(homeDir, ".claude/plugins/youcoded-core")
        if (!legacyDir.exists()) return
        try {
            legacyDir.deleteRecursively()
            android.util.Log.i("Bootstrap", "Removed legacy youcoded-core clone at ${legacyDir.absolutePath}")
        } catch (e: Exception) {
            android.util.Log.w("Bootstrap", "Failed to remove legacy youcoded-core clone: ${e.message}")
        }
    }
```

- [ ] **Step 2: Invoke the cleanup before `installHooks()`**

Locate the caller of `installHooks()` at line 858. Immediately BEFORE that line, add:

```kotlin
        cleanupLegacyYoucodedCore()
```

- [ ] **Step 3: Also prune stale `settings.json` entries that point into the deleted dir**

The desktop path relies on `HookReconciler.pruneDeadPluginHooks()` to handle this. Android's hook installation is additive (it doesn't prune missing entries). Add a targeted prune in `installHooks()` — at the beginning, after the `existingJson` read but before `hooksObj` is constructed.

Locate line 904:
```kotlin
        val hooksObj = existingJson.optJSONObject("hooks") ?: org.json.JSONObject()
```

Immediately AFTER that line, add:

```kotlin
        // Prune any stale settings.json entries pointing into the deleted
        // legacy youcoded-core clone. Mirrors desktop's pruneDeadPluginHooks().
        val legacyPrefix = File(homeDir, ".claude/plugins/youcoded-core").absolutePath
        val eventKeys = hooksObj.keys().asSequence().toList()
        for (eventKey in eventKeys) {
            val eventArray = hooksObj.optJSONArray(eventKey) ?: continue
            val kept = org.json.JSONArray()
            for (i in 0 until eventArray.length()) {
                val entry = eventArray.optJSONObject(i) ?: continue
                val hooks = entry.optJSONArray("hooks") ?: continue
                val keptHooks = org.json.JSONArray()
                for (j in 0 until hooks.length()) {
                    val h = hooks.optJSONObject(j) ?: continue
                    val cmd = h.optString("command", "")
                    if (!cmd.contains(legacyPrefix)) {
                        keptHooks.put(h)
                    }
                }
                if (keptHooks.length() > 0) {
                    val keptEntry = org.json.JSONObject()
                    keptEntry.put("matcher", entry.optString("matcher", ""))
                    keptEntry.put("hooks", keptHooks)
                    kept.put(keptEntry)
                }
            }
            hooksObj.put(eventKey, kept)
        }
```

- [ ] **Step 4: Compile**

```bash
cd youcoded
./gradlew :app:compileDebugKotlin
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add app/src/main/kotlin/com/youcoded/app/runtime/Bootstrap.kt
git commit -m "feat(android): add legacy-cleanup + stale-entry prune

Removes ~/.claude/plugins/youcoded-core/ and strips any stale
settings.json hook entries pointing into it. installHooks()
below writes the replacement bundled write-guard entry. Mirrors
the desktop cleanup path. Part of youcoded-core deprecation."
```

---

### Task 8: Remove `cloneToolkit()` from `prerequisite-installer.ts`

**Files:**
- Modify: `youcoded/desktop/src/main/prerequisite-installer.ts:440-483` (delete `cloneToolkit` function)
- Modify: `youcoded/desktop/src/main/prerequisite-installer.ts` (delete `detectToolkit` function at lines ~253-269)
- Modify: `youcoded/desktop/src/main/prerequisite-installer.ts:260` (remove `'youcoded-core'` from prerequisite list)

**Context:** After this task, new users won't get the clone. Existing users have the legacy-cleanup handling their old clone. Both paths converge on "no youcoded-core directory on disk."

- [ ] **Step 1: Find and document the current usage of `cloneToolkit` and `detectToolkit`**

```bash
cd youcoded
grep -rn "cloneToolkit\|detectToolkit" desktop/src desktop/tests
```

Expected matches: the declarations themselves, any re-exports, and any call sites in setup-wizard / first-run flows. Record the call sites — they all need updating.

- [ ] **Step 2: Delete `cloneToolkit()` (lines ~440-483) and `detectToolkit()` (lines ~253-269)**

Open `youcoded/desktop/src/main/prerequisite-installer.ts`.

Delete the full `detectToolkit` function:
```typescript
/** Detect YouCoded toolkit by checking for VERSION file. No command execution. */
export async function detectToolkit(): Promise<DetectionResult> {
  try {
    const versionFile = path.join(
      os.homedir(),
      '.claude',
      'plugins',
      'youcoded-core',
      'VERSION',
    );
    const version = fs.readFileSync(versionFile, 'utf8').trim();
    log('INFO', 'prereq', `Toolkit detected: ${version}`);
    return { installed: true, version, path: versionFile };
  } catch {
    return { installed: false, error: 'Toolkit not found' };
  }
}
```

Delete the full `cloneToolkit` function:
```typescript
/** Clone the YouCoded toolkit into ~/.claude/plugins/youcoded-core. */
export async function cloneToolkit(): Promise<{ success: boolean; error?: string }> {
  try {
    const targetDir = path.join(
      os.homedir(),
      '.claude',
      'plugins',
      'youcoded-core',
    );
    // ... (full body through closing brace)
  }
}
```

- [ ] **Step 3: Remove `'youcoded-core'` from the prerequisite list at line ~260**

Find the array literal that contains `'youcoded-core'` alongside other prerequisite identifiers (near line 260). Remove only the `'youcoded-core'` entry and its trailing comma (or leading comma if it's the last element). Surrounding entries (likely `'node'`, `'git'`, `'claude'`, `'auth'`) stay.

- [ ] **Step 4: Update every call site found in Step 1**

For each call site identified in Step 1, remove the call. If a call site was inside a conditional block (e.g., "if toolkit not installed, clone it"), remove the block entirely — the work is no longer needed. If a call site was part of a Promise.all array, replace with the remaining items.

If a call site lives in a first-run flow that's now obsolete (e.g., "toolkit detection → clone decision"), delete the whole flow.

- [ ] **Step 5: Compile**

```bash
cd youcoded/desktop
npx tsc --noEmit
```

Expected: no TypeScript errors. If there are errors about missing `cloneToolkit` / `detectToolkit` exports, the call site sweep in Step 4 missed one — find via `grep -rn "cloneToolkit\|detectToolkit" desktop/src` and fix.

- [ ] **Step 6: Run the full desktop test suite**

```bash
cd youcoded/desktop
npm test
```

Expected: all tests pass. If any test depends on `cloneToolkit`/`detectToolkit`, delete those tests (the functions are gone, the tests are stale).

- [ ] **Step 7: Commit**

```bash
cd youcoded
git add desktop/src/main/prerequisite-installer.ts desktop/tests/
# Add any other files modified by the call-site sweep
git commit -m "feat(prereq): stop cloning youcoded-core on setup

Deletes cloneToolkit() and detectToolkit() and removes
'youcoded-core' from the prerequisite list. New users get
write-guard from the app's own bundle via install-hooks.js.
Existing users' legacy clones are removed by legacy-cleanup.ts
on first launch after upgrade. Part of youcoded-core
deprecation."
```

---

### Task 9: Update the `hook-reconciler-prune` test fixture (desktop)

**Files:**
- Modify: `youcoded/desktop/tests/hook-reconciler-prune.test.ts`

**Context:** Any fixture in this test that seeds `~/.claude/plugins/youcoded-core/` with a hooks-manifest.json was modeling the pre-deprecation world. Post-deprecation, no fixture should seed youcoded-core — but the reconciler's pruneDeadPluginHooks behavior itself is unchanged and still needs coverage. Update fixtures to use a generic marketplace-plugin shape (e.g., a plugin named `"test-plugin"` at `~/.claude/plugins/marketplaces/youcoded/plugins/test-plugin/`).

- [ ] **Step 1: Read the current test file and identify fixtures that seed `youcoded-core`**

```bash
cd youcoded
grep -n "youcoded-core" desktop/tests/hook-reconciler-prune.test.ts
```

- [ ] **Step 2: For each match, rename the plugin identifier to `"test-plugin"` and adjust the seeded directory to a marketplace-style path**

Example rewrite:

Before:
```typescript
const pluginRoot = path.join(tmpHome, '.claude', 'plugins', 'youcoded-core');
```

After:
```typescript
const pluginRoot = path.join(tmpHome, '.claude', 'plugins', 'marketplaces', 'youcoded', 'plugins', 'test-plugin');
```

- [ ] **Step 3: If any fixture specifically tested "toolkit-clone-layout" behavior that no longer exists, delete that test**

Rationale: post-deprecation, the reconciler only sees marketplace plugins. Tests exercising the old clone-layout-specific paths are modeling defunct code.

- [ ] **Step 4: Run the test file**

```bash
cd youcoded/desktop
npx vitest run tests/hook-reconciler-prune.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add desktop/tests/hook-reconciler-prune.test.ts
git commit -m "test(hook-reconciler): update fixtures for post-core layout

No more youcoded-core clone seeding; fixtures use a generic
marketplace-plugin layout. Behavior under test (prune orphaned
entries whose script file is missing) is unchanged."
```

---

### Task 10: Update the `skill-scanner` test (desktop)

**Files:**
- Modify: `youcoded/desktop/tests/skill-scanner.test.ts`

**Context:** Any test case explicitly exercising `inferredSource: 'youcoded-core'` was covering a branch we'll delete in Phase 2. For Phase 1, leave the branch in place as a no-op (unused) but update the test file so it doesn't rely on the seeding producing that source.

- [ ] **Step 1: Read the current test file and identify `youcoded-core`-specific cases**

```bash
cd youcoded
grep -n "youcoded-core" desktop/tests/skill-scanner.test.ts
```

- [ ] **Step 2: For each case that seeded a `youcoded-core` directory expecting `inferredSource === 'youcoded-core'`, convert the seeding to a marketplace-plugin shape and update the expectation to `'plugin'`**

The exact marketplace-plugin shape: `~/.claude/plugins/marketplaces/youcoded/plugins/<name>/` with a `plugin.json` at the root and skills under `skills/<skill-name>/SKILL.md`.

- [ ] **Step 3: Run the test file**

```bash
cd youcoded/desktop
npx vitest run tests/skill-scanner.test.ts
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd youcoded
git add desktop/tests/skill-scanner.test.ts
git commit -m "test(skill-scanner): drop youcoded-core-specific fixtures

Coverage of inferredSource:'plugin' for marketplace-installed
plugins is preserved. The 'youcoded-core' inferredSource branch
still exists in the production code (unused); Phase 2 removes
it along with the test."
```

---

### Task 11: Smoke-test Release N manually

**Files:** None (manual verification)

**Context:** Install-hooks.js and Android Bootstrap are not covered by automated tests; rely on manual boot + inspect. Do this on a dev build before tagging a release.

- [ ] **Step 1: Start the desktop dev instance**

```bash
cd C:/Users/desti/youcoded-dev
bash scripts/run-dev.sh
```

Note: dev mode sets `YOUCODED_PROFILE=dev` which skips `install-hooks.js` intentionally (see main.ts:1010). For this smoke test, you need a clean start WITHOUT the profile variable set, which means running the packaged dev build or temporarily disabling the guard. Easiest path: run the packaged app after `npm run build` rather than dev mode.

**Alternative (packaged build smoke):**

```bash
cd youcoded/desktop
npm ci
npm run build
npm run electron:dist  # or whatever the packaging script is — check package.json
# Launch the built app from dist/
```

- [ ] **Step 2: Verify `~/.claude/plugins/youcoded-core/` is gone**

```bash
ls ~/.claude/plugins/ 2>&1 | grep youcoded-core
```

Expected: no output (directory was removed by legacy-cleanup).

- [ ] **Step 3: Verify `~/.claude/settings.json` has the new write-guard entry pointing inside the app bundle**

```bash
cat ~/.claude/settings.json | python -c "
import json, sys
s = json.load(sys.stdin)
pt = s.get('hooks', {}).get('PreToolUse', [])
for e in pt:
    for h in e.get('hooks', []):
        if 'write-guard' in h.get('command', ''):
            print('Write-guard path:', h['command'])
            print('Matcher:', e.get('matcher'))
"
```

Expected output:
- Write-guard command path contains the app installation directory (e.g., `app.asar.unpacked/hook-scripts/write-guard.sh`), NOT `~/.claude/plugins/youcoded-core/hooks/write-guard.sh`.
- Matcher is `Write|Edit`.

- [ ] **Step 4: Verify no stale hook entries remain pointing into the deleted directory**

```bash
grep -i "youcoded-core" ~/.claude/settings.json
```

Expected: no matches. If any match appears, `pruneDeadPluginHooks()` failed to clean something up — investigate before shipping.

- [ ] **Step 5: Exercise write-guard in a two-session scenario**

Open two parallel Claude Code sessions (two terminal windows, or a terminal + the app's built-in chat). In session A, edit `~/.claude/memory/some-file.md` (or any tracked file). In session B, attempt to edit the same file.

Expected: session B receives a `WRITE BLOCKED: ...` message from write-guard.

- [ ] **Step 6: Android smoke (if an Android build can be produced)**

Build and install the APK on a test device:
```bash
cd youcoded
./scripts/build-web-ui.sh
./gradlew assembleDebug
# Install the debug APK on device, launch it, start a session
```

Inside the Termux env of the Android session, verify:
```bash
ls ~/.claude/plugins/ | grep youcoded-core  # should be empty
cat ~/.claude/settings.json | grep write-guard  # should find a matcher
```

- [ ] **Step 7: If all checks pass, tag a release**

Follow the normal release flow in `docs/build-and-release.md` — bump `versionCode` + `versionName` in `app/build.gradle.kts`, tag `vX.Y.Z`, push. Both android-release.yml and desktop-release.yml trigger and build artifacts.

- [ ] **Step 8: No code commit; this task is manual. Record the release version in the plan's execution log for the Phase 2 gate.**

---

## Phase 2: Release N+1 — dead-branch cleanup

**Gate:** Release N has been live long enough that Destin has run it on his own machine without issues, typically one to two weeks. Verify before starting Phase 2: on Destin's machine, `ls ~/.claude/plugins/ | grep youcoded-core` returns empty, write-guard still works in a two-session test, no regressions have been reported.

### Task 12: Remove `youcoded-core` branches from `plugin-installer.ts`

**Files:**
- Modify: `youcoded/desktop/src/main/plugin-installer.ts:53` (remove `'youcoded-core'` condition)
- Modify: `youcoded/desktop/src/main/plugin-installer.ts:60` (remove `'youcoded-core'` condition)

**Context:** Per the spec (§3b), the current checks are `sourceMarketplace === 'youcoded' || sourceMarketplace === 'youcoded-core'`. Only the `'youcoded-core'` disjunct goes; `'youcoded'` stays.

- [ ] **Step 1: Read both lines and their enclosing function**

```bash
cd youcoded
sed -n '45,70p' desktop/src/main/plugin-installer.ts
```

- [ ] **Step 2: On each of lines 53 and 60, remove the `|| sourceMarketplace === 'youcoded-core'` disjunct**

Before:
```typescript
if (sourceMarketplace === 'youcoded' || sourceMarketplace === 'youcoded-core') {
```

After:
```typescript
if (sourceMarketplace === 'youcoded') {
```

- [ ] **Step 3: Compile + run tests**

```bash
cd youcoded/desktop
npx tsc --noEmit
npm test -- plugin-installer
```

Expected: compile clean, tests pass.

- [ ] **Step 4: Commit**

```bash
cd youcoded
git add desktop/src/main/plugin-installer.ts
git commit -m "refactor(plugin-installer): drop youcoded-core sourceMarketplace branch

No marketplace plugins carry sourceMarketplace:'youcoded-core'
any more — that value was only used by the deprecated toolkit's
own entries. Part of youcoded-core deprecation phase 2."
```

---

### Task 13: Remove `inferredSource: 'youcoded-core'` handling from `skill-scanner.ts`

**Files:**
- Modify: `youcoded/desktop/src/main/skill-scanner.ts:31` (type member removal)
- Modify: `youcoded/desktop/src/main/skill-scanner.ts:83` (comment)
- Modify: `youcoded/desktop/src/main/skill-scanner.ts:89` (prefix check)
- Modify: `youcoded/desktop/src/main/skill-scanner.ts:140` (comment)
- Modify: `youcoded/desktop/src/main/skill-scanner.ts:155` (prefix check)

**Context:** The type `inferredSource: 'youcoded-core' | 'self' | 'plugin'` narrows to `'self' | 'plugin'`. The `startsWith('youcoded')` prefix check and its associated comments describing the old layered layout all go.

- [ ] **Step 1: Read the file to understand the surrounding logic**

```bash
cd youcoded
sed -n '25,160p' desktop/src/main/skill-scanner.ts
```

- [ ] **Step 2: Change the type definition at line 31 from the 3-valued union to the 2-valued one**

Before:
```typescript
inferredSource: 'youcoded-core' | 'self' | 'plugin',
```

After:
```typescript
inferredSource: 'self' | 'plugin',
```

- [ ] **Step 3: Update line 89**

The current logic around line 89 determines `source` based on `pluginEntry.name.startsWith('youcoded')`. Since the only plugin whose name started with `'youcoded'` was `youcoded-core`, this check was a de-facto toolkit test. With the toolkit gone, every installed plugin's source is simply `'plugin'`. Replace the conditional assignment with a direct `const source = 'plugin';` or inline the value.

Before:
```typescript
const source = pluginEntry.name.startsWith('youcoded') ? 'youcoded-core' : 'plugin';
```

After:
```typescript
const source = 'plugin';
```

- [ ] **Step 4: Remove the explanatory comments that described the old behavior (lines 83, 140, 155)**

These comments reference the `youcoded-core-*` prefix convention that no longer applies. Delete them; the code is self-explanatory without them.

- [ ] **Step 5: Check for other `'youcoded-core'` string literals elsewhere in the file**

```bash
cd youcoded
grep -n "youcoded-core" desktop/src/main/skill-scanner.ts
```

Expected: no remaining matches. Any that appear need case-by-case judgment.

- [ ] **Step 6: Compile + run skill-scanner test**

```bash
cd youcoded/desktop
npx tsc --noEmit
npx vitest run tests/skill-scanner.test.ts
```

Expected: compile clean, tests pass. If any test still expects `inferredSource === 'youcoded-core'`, update those expectations to `'plugin'`.

- [ ] **Step 7: Commit**

```bash
cd youcoded
git add desktop/src/main/skill-scanner.ts desktop/tests/skill-scanner.test.ts
git commit -m "refactor(skill-scanner): drop youcoded-core inferredSource

Post-deprecation, no plugin ships with source 'youcoded-core'.
Type narrows to 'self' | 'plugin'. Comments describing the old
layered core/life/productivity layout also removed. Part of
youcoded-core deprecation phase 2."
```

---

### Task 14: Remove `youcoded-core` dedup branches from `sync-service.ts`

**Files:**
- Modify: `youcoded/desktop/src/main/sync-service.ts:1962-1985` (delete youcoded-core-prefixed dedup block)

**Context:** The block at these lines walks "any youcoded-core-prefixed plugin" to decide whether a skill under `~/.claude/skills/` is a toolkit copy vs a user-authored skill. With no toolkit-prefixed plugins existing, the whole walk is dead.

- [ ] **Step 1: Read the surrounding function**

```bash
cd youcoded
sed -n '1950,1990p' desktop/src/main/sync-service.ts
```

Understand what the enclosing function was doing overall. Is the dedup logic still needed for non-toolkit plugins, or was it specifically toolkit-only?

- [ ] **Step 2: Delete the `startsWith('youcoded-core')` branch**

The exact change depends on the function structure — either remove an `if` block entirely, or narrow a condition to always-false (preferred: remove the block).

- [ ] **Step 3: If removing the block leaves a helper function unreachable, delete that helper too**

Look for the function whose only caller was the block you just removed.

- [ ] **Step 4: Compile + run sync-service-related tests**

```bash
cd youcoded/desktop
npx tsc --noEmit
npm test -- sync-service
```

Expected: compile clean, tests pass.

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add desktop/src/main/sync-service.ts
git commit -m "refactor(sync-service): drop youcoded-core-prefixed dedup branch

No plugins carry the youcoded-core- prefix any more. Dedup logic
for other plugin prefixes (if any) preserved. Part of
youcoded-core deprecation phase 2."
```

---

### Task 15: Simplify `marketplace-file-reader.ts`

**Files:**
- Modify: `youcoded/desktop/src/main/marketplace-file-reader.ts` (remove comments + depth-4 walk tuning for the old 3-layer core/life/productivity prefixes)

**Context:** The file currently has comments explaining that depth-4 walks cover `core/skills/...`, `life/skills/...`, `productivity/skills/...`. That layered layout existed only inside youcoded-core. Marketplace plugins use a flat `<plugin>/skills/<skill>/SKILL.md` layout (depth 2 under the plugin root).

- [ ] **Step 1: Read the current file**

```bash
cat youcoded/desktop/src/main/marketplace-file-reader.ts
```

- [ ] **Step 2: Remove or update comments that reference the layered layout**

Lines 6, 34, 51, 79 per the grep earlier. Keep the file behavior (the glob/walk still finds skills under marketplace plugins) but simplify if the `maxDepth` parameter was only set high to accommodate the layered layout.

If the walk depth was 4 to handle `<plugin>/life/skills/<name>/`, reduce to 2 to handle just `<plugin>/skills/<name>/`. Check whether any currently-installed marketplace plugin uses a deeper layout before reducing — if any do, keep depth 4 but update the comments to reflect current reality.

- [ ] **Step 3: Compile + run any related tests**

```bash
cd youcoded/desktop
npx tsc --noEmit
npm test -- marketplace
```

Expected: compile clean, tests pass.

- [ ] **Step 4: Commit**

```bash
cd youcoded
git add desktop/src/main/marketplace-file-reader.ts
git commit -m "refactor(marketplace-file-reader): drop core/life/productivity layout notes

Comments referenced the old youcoded-core layered structure.
Marketplace plugins use a flat layout. Part of youcoded-core
deprecation phase 2."
```

---

### Task 16: Rename the output-styles config file + migration read

**Files:**
- Modify: `youcoded/desktop/src/main/skill-provider.ts:818-830` (rename file + add migration read)

**Context:** The config at `~/.claude/youcoded-config/youcoded-core-output-styles.json` becomes `~/.claude/youcoded-config/youcoded-output-styles.json`. We need a one-time migration: on load, if the new file doesn't exist but the old one does, read the old file and write it under the new name, then delete the old.

- [ ] **Step 1: Read the surrounding code at line 818-830**

```bash
cd youcoded
sed -n '810,835p' desktop/src/main/skill-provider.ts
```

- [ ] **Step 2: Rename the primary filename constant**

Find:
```typescript
const configFile = path.join(configDir, 'youcoded-core-output-styles.json');
```

Replace with:
```typescript
const configFile = path.join(configDir, 'youcoded-output-styles.json');
```

- [ ] **Step 3: Add a one-shot migration at module initialization or before the first read**

At the top of the function (or wherever the config load happens), add:

```typescript
  // Migration: youcoded-core deprecation (2026-04) renamed the config file.
  // Remove this block after release Y (estimated 3 releases after N+1).
  const legacyConfigFile = path.join(configDir, 'youcoded-core-output-styles.json');
  try {
    if (!fs.existsSync(configFile) && fs.existsSync(legacyConfigFile)) {
      fs.renameSync(legacyConfigFile, configFile);
      log('INFO', 'SkillProvider', 'Migrated output-styles config to new filename');
    } else if (fs.existsSync(legacyConfigFile)) {
      // Both exist — new wins. Delete the legacy copy so we don't keep
      // migrating forever.
      fs.unlinkSync(legacyConfigFile);
    }
  } catch (e) {
    log('WARN', 'SkillProvider', 'Output-styles config migration failed', { error: String(e) });
  }
```

- [ ] **Step 4: Compile + run skill-provider tests**

```bash
cd youcoded/desktop
npx tsc --noEmit
npm test -- skill-provider
```

Expected: compile clean, tests pass.

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add desktop/src/main/skill-provider.ts
git commit -m "refactor(skill-provider): rename output-styles config file

youcoded-core-output-styles.json → youcoded-output-styles.json.
One-time migration read preserves user's existing config.
Migration block flagged for removal 3 releases out. Part of
youcoded-core deprecation phase 2."
```

---

### Task 17: Update `hook-reconciler.ts` docstrings

**Files:**
- Modify: `youcoded/desktop/src/main/hook-reconciler.ts:57` (remove stale example path)

**Context:** The mechanism itself stays — we still need the reconciler for marketplace plugins that ship `hooks-manifest.json`. Only the stale youcoded-core example in the docstring needs updating.

- [ ] **Step 1: Read the docstring comment at line 57**

```bash
cd youcoded
sed -n '54,65p' desktop/src/main/hook-reconciler.ts
```

- [ ] **Step 2: Replace the youcoded-core example with a generic marketplace-plugin example**

Before (around line 57):
```typescript
 * `bash ~/.claude/plugins/youcoded-core/hooks/session-start.sh` the
 * identity is `session-start.sh`.
```

After:
```typescript
 * `bash ~/.claude/plugins/marketplaces/youcoded/plugins/example/hooks/foo.sh`
 * the identity is `foo.sh`.
```

- [ ] **Step 3: Search for any other `youcoded-core` references in the file**

```bash
cd youcoded
grep -n "youcoded-core" desktop/src/main/hook-reconciler.ts
```

Expected: no remaining matches, or only docstring/historical-note references that are safe to keep.

- [ ] **Step 4: Commit**

```bash
cd youcoded
git add desktop/src/main/hook-reconciler.ts
git commit -m "docs(hook-reconciler): update docstring example to marketplace-plugin layout

Mechanism unchanged. Example path no longer points at the
deprecated toolkit. Part of youcoded-core deprecation phase 2."
```

---

### Task 18: Remove `youcoded-core` from bundled plugin lists

**Files:**
- Modify: `youcoded/desktop/src/shared/bundled-plugins.ts` (check `BUNDLED_PLUGIN_IDS`)
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/skills/BundledPlugins.kt` (mirror)

**Context:** Per `docs/PITFALLS.md → Plugin Installation`, these two lists must stay in sync between platforms. If `youcoded-core` appears in either, it's a stale entry.

- [ ] **Step 1: Check both files**

```bash
cd youcoded
grep -n "youcoded-core" desktop/src/shared/bundled-plugins.ts app/src/main/kotlin/com/youcoded/app/skills/BundledPlugins.kt
```

- [ ] **Step 2: Remove `'youcoded-core'` from both lists if present**

Identical edit in both files: drop the `'youcoded-core'` entry from the `BUNDLED_PLUGIN_IDS` array. Keep the trailing comma conventions consistent with existing formatting.

- [ ] **Step 3: Compile both platforms**

```bash
cd youcoded/desktop && npx tsc --noEmit
cd youcoded && ./gradlew :app:compileDebugKotlin
```

Expected: no errors.

- [ ] **Step 4: Update the PITFALLS entry if it references `youcoded-core`**

Open `C:/Users/desti/youcoded-dev/docs/PITFALLS.md`. Locate the "Plugin Installation & Claude Code Registries" section's note about bundled plugin list duplication. If the note mentions `youcoded-core` as an example, update to a different example or remove the specific reference.

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add desktop/src/shared/bundled-plugins.ts app/src/main/kotlin/com/youcoded/app/skills/BundledPlugins.kt
git commit -m "refactor(bundled-plugins): remove youcoded-core entry

Desktop + Android lists stay in sync per PITFALLS. Part of
youcoded-core deprecation phase 2."

cd C:/Users/desti/youcoded-dev
git add docs/PITFALLS.md
git commit -m "docs(pitfalls): refresh bundled-plugin example

youcoded-core is no longer a bundled plugin. Example updated."
```

---

### Task 19: Smoke-test Release N+1 and ship

**Files:** None (manual verification)

- [ ] **Step 1: Full desktop test suite**

```bash
cd youcoded/desktop
npm ci && npm test && npm run build
```

Expected: all green.

- [ ] **Step 2: Full Android compile**

```bash
cd youcoded
./scripts/build-web-ui.sh && ./gradlew assembleDebug && ./gradlew test
```

Expected: all green.

- [ ] **Step 3: Launch the built app and verify nothing broke**

- Settings panel opens
- Skills panel lists installed plugins correctly
- Syncing (if configured) works
- Write-guard still blocks on two-session conflict
- No error logs mentioning missing `youcoded-core` file / function / type

- [ ] **Step 4: Global grep for remaining `youcoded-core` references**

```bash
cd youcoded
grep -rn "youcoded-core" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.kt" desktop/src desktop/scripts app/src
```

Expected: minimal or zero matches. Any match should be a deliberate historical-note reference (CHANGELOG, etc.) or a test fixture name that's safe. No live code paths.

- [ ] **Step 5: Tag the release per `docs/build-and-release.md`**

---

## Phase 3: Archive the `youcoded-core` repo

**Gate:** Phase 2 has shipped and been running cleanly for at least a few days. No regressions reported.

### Task 20: Delete files inside `youcoded-core` per spec §1

**Files:** Files inside `youcoded-core/` — see spec §1 for the full list

**Context:** All deletions happen on master, then we commit. The archive happens AFTER the delete commit, so the final state shows the tombstone repo content.

- [ ] **Step 1: Delete skills, commands, hooks, bootstrap, scripts, templates, data, docs**

```bash
cd C:/Users/desti/youcoded-dev/youcoded-core
git rm -r skills/ commands/ hooks/ bootstrap/ scripts/ templates/ data/ docs/
```

- [ ] **Step 2: Delete defunct specs**

```bash
git rm specs/destintip-spec.md \
       specs/worktree-guard-spec.md \
       specs/youcoded-core-spec.md \
       specs/specs-system-spec.md \
       specs/system-architecture-spec.md \
       specs/INDEX.md
```

- [ ] **Step 3: Verify `specs/landing-page-spec.md` before deciding its fate**

```bash
head -30 specs/landing-page-spec.md
```

If it describes a live project website, skip deletion and move it in Task 21. If defunct, delete it:
```bash
git rm specs/landing-page-spec.md
```

- [ ] **Step 4: Delete top-level metadata that's no longer meaningful**

```bash
git rm plugin.json mcp-manifest.json VERSION .private-manifest
```

Keep: `LICENSE` (required by GitHub), `README.md` (rewriting in Task 23), `CHANGELOG.md` (historical record).

- [ ] **Step 5: Commit the deletions**

```bash
cd C:/Users/desti/youcoded-dev/youcoded-core
git commit -m "deprecate: remove files superseded by the YouCoded app

The YouCoded app now owns setup, hooks (write-guard bundled
natively on both platforms), sync, skills, and all user-facing
behavior. See docs/superpowers/specs/2026-04-21-deprecate-
youcoded-core-design.md in the youcoded-dev workspace for the
full decomposition."
```

---

### Task 21: Move surviving specs into the `youcoded` app repo

**Files:**
- Move: `youcoded-core/specs/write-guard-spec.md` → `youcoded/docs/write-guard-spec.md`
- Move: `youcoded-core/specs/remote-access-spec.md` → `youcoded/docs/remote-access-spec.md`
- Move: `youcoded-core/specs/statusline-spec.md` → `youcoded/docs/statusline-spec.md`
- Conditionally move: `specs/memory-system-spec.md`, `specs/output-styles-spec.md`

**Context:** These specs describe app behavior. Before moving, spot-check each to confirm it still describes current behavior — if a spec describes a feature that's been reworked, it's misleading and should be updated or dropped during the move.

- [ ] **Step 1: Spot-check `write-guard-spec.md`**

```bash
head -40 youcoded-core/specs/write-guard-spec.md
```

Confirm it matches the current `write-guard.sh` behavior. If stale, update text during the move.

- [ ] **Step 2: Move the three confirmed specs**

```bash
mv youcoded-core/specs/write-guard-spec.md youcoded/docs/
mv youcoded-core/specs/remote-access-spec.md youcoded/docs/
mv youcoded-core/specs/statusline-spec.md youcoded/docs/
```

- [ ] **Step 3: Review `memory-system-spec.md` and `output-styles-spec.md`**

```bash
head -40 youcoded-core/specs/memory-system-spec.md
head -40 youcoded-core/specs/output-styles-spec.md
```

For each: if it describes current app behavior, move to `youcoded/docs/`. If it describes a defunct subsystem, delete. If it's half-accurate, move and flag inaccuracies in a follow-up TODO comment at the top of the file.

- [ ] **Step 4: Remove the now-empty `specs/` directory (and `data/` if empty) from youcoded-core**

```bash
cd C:/Users/desti/youcoded-dev/youcoded-core
rmdir specs 2>/dev/null  # only succeeds if empty
git add -A  # stages empty-dir removal and any remaining file removals
```

- [ ] **Step 5: Commit in both repos**

```bash
cd C:/Users/desti/youcoded-dev/youcoded
git add docs/write-guard-spec.md docs/remote-access-spec.md docs/statusline-spec.md
# Plus memory-system / output-styles if moved
git commit -m "docs(specs): absorb surviving specs from youcoded-core

write-guard, remote-access, statusline (and optionally memory-
system, output-styles) now live in the app repo alongside their
implementations. Part of youcoded-core deprecation phase 3."

cd C:/Users/desti/youcoded-dev/youcoded-core
git commit -m "deprecate: move surviving specs to app repo

See matching commit in the youcoded repo."
```

---

### Task 22: Rewrite `youcoded-core/README.md` as a tombstone

**Files:**
- Modify: `youcoded-core/README.md` (full rewrite)
- Create: `youcoded-core/DEPRECATED.md`

- [ ] **Step 1: Rewrite `README.md`**

Replace the full file content with:

```markdown
# YouCoded Core (Deprecated)

This repo was the `youcoded-core` toolkit — a Claude Code plugin that
extended YouCoded users' environment with hooks, skills, and commands.

**It is no longer maintained.** All functionality has been absorbed into
the YouCoded app itself:

- Write-guard (cross-session concurrency protection) ships bundled in the
  app on both desktop and Android — no separate install required.
- Setup, sync, skills, themes, and announcements are managed by the app.
- Marketplace plugins (journaling, encyclopedia, inbox, etc.) live at
  [wecoded-marketplace](https://github.com/itsdestin/wecoded-marketplace).

See the [YouCoded app](https://github.com/itsdestin/youcoded) for the
current project.

## Why archived?

See `DEPRECATED.md` in this repo for the migration story and the
design rationale.

## License

MIT — see `LICENSE`.
```

- [ ] **Step 2: Create `DEPRECATED.md`**

```markdown
# Deprecated

`youcoded-core` was deprecated on 2026-04 and archived after two
coordinated app releases migrated its last responsibilities into the
YouCoded app itself.

## Final state

- The one hook with general-purpose value (`write-guard.sh`) is now
  bundled inside the app on both desktop and Android.
- Setup-wizard, remote-setup, and all slash commands are handled by the
  app's onboarding UI.
- Hooks-manifest mechanism survives in the app for marketplace plugins
  that ship their own hooks.

## History

- See `CHANGELOG.md` for the historical release log.
- See the YouCoded app's `CHANGELOG.md` for migration releases.
- Full design rationale: `docs/superpowers/specs/2026-04-21-deprecate-
  youcoded-core-design.md` in the `youcoded-dev` workspace repo.
```

- [ ] **Step 3: Commit**

```bash
cd C:/Users/desti/youcoded-dev/youcoded-core
git add README.md DEPRECATED.md
git commit -m "docs: rewrite README as tombstone + add DEPRECATED.md

Points users to the YouCoded app. Final commit before GitHub
archive."
```

---

### Task 23: Push final state and archive on GitHub

- [ ] **Step 1: Push master to origin**

```bash
cd C:/Users/desti/youcoded-dev/youcoded-core
git push origin master
```

- [ ] **Step 2: Archive the repo on GitHub**

Navigate to https://github.com/itsdestin/youcoded-core in a browser. Settings → scroll to "Danger Zone" → "Archive this repository" → confirm.

The repo goes read-only. All content (including CHANGELOG) remains accessible. Issues and PRs are locked.

- [ ] **Step 3: Verify the archive**

```bash
curl -s https://api.github.com/repos/itsdestin/youcoded-core | python -c "import json, sys; print('archived:', json.load(sys.stdin).get('archived'))"
```

Expected: `archived: True`.

- [ ] **Step 4: No local commit; this task completes Phase 3.**

---

## Phase 4: Workspace scaffold (`youcoded-dev`) cleanup

**Gate:** Can run at any point after Phase 1 completes. Ideally before Phase 2 so workspace docs reflect the direction.

### Task 24: Update `setup.sh`

**Files:**
- Modify: `C:/Users/desti/youcoded-dev/setup.sh`

**Context:** The script currently clones `youcoded-core` alongside the other repos. Remove that clone.

- [ ] **Step 1: Read the script**

```bash
cat C:/Users/desti/youcoded-dev/setup.sh
```

- [ ] **Step 2: Remove the `youcoded-core` clone block**

Find the block that clones `https://github.com/itsdestin/youcoded-core.git` (or similar). Delete it, including any comments or error-handling specifically for that repo. Keep clones for the other 4 repos.

- [ ] **Step 3: Verify the script still runs against a clean dir**

```bash
# In a scratch directory
mkdir /tmp/setup-test && cd /tmp/setup-test
bash ~/youcoded-dev/setup.sh
ls
```

Expected: the four remaining repos (`youcoded`, `youcoded-admin`, `wecoded-themes`, `wecoded-marketplace`) are cloned; no `youcoded-core` dir.

- [ ] **Step 4: Commit**

```bash
cd C:/Users/desti/youcoded-dev
git add setup.sh
git commit -m "chore(setup): drop youcoded-core clone

Repo was deprecated and archived. Part of the workspace
scaffold cleanup for youcoded-core deprecation."
```

---

### Task 25: Update `CLAUDE.md` (workspace root)

**Files:**
- Modify: `C:/Users/desti/youcoded-dev/CLAUDE.md`

- [ ] **Step 1: Remove the `youcoded-core` row from the Workspace Layout table**

Find the markdown table under "## Workspace Layout". Delete the row for `youcoded-core/`.

- [ ] **Step 2: Update the "Cross-Repo Relationships" section**

Delete or edit any bullet that references `youcoded-core`. The bullet that says "youcoded-core is the plugin toolkit installed at `~/.claude/plugins/youcoded-core/`" goes entirely.

- [ ] **Step 3: Commit**

```bash
cd C:/Users/desti/youcoded-dev
git add CLAUDE.md
git commit -m "docs(workspace): remove youcoded-core from layout

Repo deprecated. Part of workspace scaffold cleanup."
```

---

### Task 26: Delete workspace-level docs that are now obsolete

**Files:**
- Delete: `C:/Users/desti/youcoded-dev/docs/toolkit-structure.md`
- Delete: `C:/Users/desti/youcoded-dev/.claude/rules/youcoded-toolkit.md`
- Delete: `C:/Users/desti/youcoded-dev/.claude/skills/context-toolkit/SKILL.md` (and empty parent dir)

- [ ] **Step 1: Delete the files**

```bash
cd C:/Users/desti/youcoded-dev
git rm docs/toolkit-structure.md
git rm .claude/rules/youcoded-toolkit.md
git rm -r .claude/skills/context-toolkit/
```

- [ ] **Step 2: Remove the `@docs/toolkit-structure.md` reference from `CLAUDE.md`**

Open `C:/Users/desti/youcoded-dev/CLAUDE.md`, find the line `@docs/toolkit-structure.md` under "## Subsystem References", and delete it.

- [ ] **Step 3: Commit**

```bash
cd C:/Users/desti/youcoded-dev
git add CLAUDE.md
git commit -m "docs(workspace): remove toolkit-specific rules and skill

toolkit-structure.md described a defunct 3-layer structure.
context-toolkit skill has no toolkit to load context for.
youcoded-toolkit rule is obsolete. Part of workspace scaffold
cleanup for youcoded-core deprecation."
```

---

### Task 27: Prune `youcoded-core` mentions from `PITFALLS.md` and other workspace docs

**Files:**
- Modify: `C:/Users/desti/youcoded-dev/docs/PITFALLS.md`
- Modify: `C:/Users/desti/youcoded-dev/docs/build-and-release.md`
- Modify: `C:/Users/desti/youcoded-dev/docs/registries.md`
- Modify: `C:/Users/desti/youcoded-dev/.claude/hooks/context-inject.sh` (if toolkit-specific injection)

- [ ] **Step 1: Find every remaining `youcoded-core` reference in workspace docs**

```bash
cd C:/Users/desti/youcoded-dev
grep -rn "youcoded-core" docs/ .claude/ CLAUDE.md GEMINI.md 2>/dev/null
```

- [ ] **Step 2: For each match, decide: delete the line, or rewrite it**

- In `PITFALLS.md`: the "Toolkit & Hooks" section should be shrunk to retain only the hook-manifest guidance (still true for marketplace plugins), drop the youcoded-core-specific bullets. The "Plugin Installation" section's youcoded-core exception (`~/.claude/plugins/youcoded-core/`) goes. The "Announcements" section's historical note can stay as context but remove any active-behavior claims.
- In `build-and-release.md`: the "Toolkit (youcoded-core)" release flow section goes entirely.
- In `registries.md`: any stale references go.
- In `context-inject.sh`: if it injects toolkit-specific context, remove that injection. If it's generic, leave alone.

- [ ] **Step 3: Verify no active claims about youcoded-core remain**

```bash
cd C:/Users/desti/youcoded-dev
grep -rn "youcoded-core" docs/ .claude/ CLAUDE.md GEMINI.md 2>/dev/null
```

Expected: matches are limited to historical CHANGELOG/plan notes that are allowed to remain as history.

- [ ] **Step 4: Commit**

```bash
cd C:/Users/desti/youcoded-dev
git add docs/ .claude/ CLAUDE.md
git commit -m "docs(workspace): prune youcoded-core from live-guidance docs

PITFALLS, build-and-release, registries, and the context-inject
hook cleaned. Historical references in plans/specs stay as
record. Part of workspace scaffold cleanup."
```

---

## Self-review checklist (for the plan author)

- [x] Every task has explicit file paths
- [x] Every code-editing step contains the actual code or the exact edit
- [x] Every test has a run command with expected output
- [x] Every task ends with a commit
- [x] No "TBD", "add appropriate error handling", or equivalent placeholders
- [x] Type names used later match type names defined earlier (`cleanupLegacyYoucodedCore` consistent across tasks 5 and 6; `LegacyCleanupResult` used consistently)
- [x] Phase gates stated explicitly
- [x] Every spec section maps to at least one task

## Execution notes

- All desktop work can be done in a single worktree off the `youcoded` repo. All Android work is in the same repo.
- Phase 3 touches `youcoded-core` for the first time — consider creating a separate worktree there to avoid mixing with any in-flight work.
- Phase 4 workspace-scaffold cleanup happens in `youcoded-dev` itself. Main branch work on this repo is fine since nothing lands in code — just docs.
