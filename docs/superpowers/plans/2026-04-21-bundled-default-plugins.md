# Bundled Default Plugins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the YouCoded app so `wecoded-themes-plugin` (Theme Builder) and `wecoded-marketplace-publisher` are auto-installed on every launch if missing, and cannot be uninstalled from the UI.

**Architecture:** Hardcoded bundled-plugin ID list, duplicated across a single shared TypeScript file (`desktop/src/shared/bundled-plugins.ts`, imported by both main and renderer processes) and one Kotlin object (`BundledPlugins.kt`). Desktop and Android each get a new `ensureBundledPluginsInstalled()` method on their `SkillProvider` that wraps the existing idempotent `installMany()`. Called fire-and-forget at startup. UI disables the uninstall button with a hover tooltip; IPC handlers reject uninstall calls for bundled IDs as defense-in-depth.

**Tech Stack:** TypeScript (Electron main + React renderer), Kotlin (Android foreground service), Vitest for desktop unit tests.

**Spec:** `docs/superpowers/specs/2026-04-20-bundled-default-plugins-design.md`

**Spec deviation:** The spec §Architecture calls for three-way duplication (main / renderer / Kotlin). The existing `desktop/src/shared/` directory is already imported by both main and renderer, so this plan uses two copies (one TypeScript file shared across both JS processes, one Kotlin object). The PITFALLS entry reflects this.

---

### Task 1: Add shared bundled-plugin constants

**Files:**
- Create: `youcoded/desktop/src/shared/bundled-plugins.ts`
- Create: `youcoded/app/src/main/kotlin/com/youcoded/app/skills/BundledPlugins.kt`

- [ ] **Step 1: Create TypeScript constants file**

Write the file `youcoded/desktop/src/shared/bundled-plugins.ts`:

```ts
// Bundled plugins are marketplace plugins that ship with YouCoded and cannot
// be uninstalled through the UI. On every launch, if a bundled plugin is
// missing from ~/.claude/plugins/installed_plugins.json, the app reinstalls
// it silently.
//
// PARITY REQUIRED — keep this list in sync with:
//   youcoded/app/src/main/kotlin/com/youcoded/app/skills/BundledPlugins.kt
// If you change the list, also update docs/PITFALLS.md.

export const BUNDLED_PLUGIN_IDS = [
  'wecoded-themes-plugin',
  'wecoded-marketplace-publisher',
] as const;

export const BUNDLED_REASON =
  'Bundled with YouCoded — required for theme customization and publishing.';

export function isBundledPlugin(id: string): boolean {
  return (BUNDLED_PLUGIN_IDS as readonly string[]).includes(id);
}
```

- [ ] **Step 2: Create Kotlin constants file**

Write the file `youcoded/app/src/main/kotlin/com/youcoded/app/skills/BundledPlugins.kt`:

```kotlin
// Bundled plugins are marketplace plugins that ship with YouCoded and cannot
// be uninstalled through the UI. On every launch, if a bundled plugin is
// missing, the app reinstalls it silently.
//
// PARITY REQUIRED — keep this list in sync with:
//   youcoded/desktop/src/shared/bundled-plugins.ts
// If you change the list, also update docs/PITFALLS.md.

package com.youcoded.app.skills

object BundledPlugins {
    val IDS = listOf(
        "wecoded-themes-plugin",
        "wecoded-marketplace-publisher",
    )

    const val REASON =
        "Bundled with YouCoded — required for theme customization and publishing."

    fun isBundled(id: String): Boolean = IDS.contains(id)
}
```

- [ ] **Step 3: Commit**

```bash
cd youcoded && git add desktop/src/shared/bundled-plugins.ts app/src/main/kotlin/com/youcoded/app/skills/BundledPlugins.kt && git commit -m "feat(plugins): add bundled-plugin constants (ts + kotlin)"
```

---

### Task 2: Add `ensureBundledPluginsInstalled()` on desktop

**Files:**
- Modify: `youcoded/desktop/src/main/skill-provider.ts` (add method to `LocalSkillProvider` class; add import)
- Modify: `youcoded/desktop/src/main/main.ts:120-121` (call new method after `ensureMigrated()`)
- Create: `youcoded/desktop/tests/skill-provider-bundled.test.ts`

- [ ] **Step 1: Write the failing test**

Create `youcoded/desktop/tests/skill-provider-bundled.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { LocalSkillProvider } from '../src/main/skill-provider';
import { BUNDLED_PLUGIN_IDS } from '../src/shared/bundled-plugins';

describe('LocalSkillProvider.ensureBundledPluginsInstalled', () => {
  let provider: LocalSkillProvider;

  beforeEach(() => {
    provider = new LocalSkillProvider();
  });

  it('calls installMany with the bundled IDs', async () => {
    const installMany = vi.spyOn(provider, 'installMany').mockResolvedValue([]);
    await provider.ensureBundledPluginsInstalled();
    expect(installMany).toHaveBeenCalledWith([...BUNDLED_PLUGIN_IDS]);
  });

  it('swallows errors from installMany and resolves void', async () => {
    vi.spyOn(provider, 'installMany').mockRejectedValue(new Error('network'));
    await expect(provider.ensureBundledPluginsInstalled()).resolves.toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test, confirm it fails**

```bash
cd youcoded/desktop && npx vitest run tests/skill-provider-bundled.test.ts
```

Expected: FAIL. Error like `provider.ensureBundledPluginsInstalled is not a function`.

- [ ] **Step 3: Add the method**

Open `youcoded/desktop/src/main/skill-provider.ts`. Near the top with the other imports, add:

```ts
import { BUNDLED_PLUGIN_IDS } from '../shared/bundled-plugins';
```

Inside the `LocalSkillProvider` class, after the existing `installMany` method (around line 845), add:

```ts
/**
 * Install any bundled plugins that are missing. Fire-and-forget on every
 * app launch; silent retry next launch on failure. installMany() is
 * idempotent — already-installed plugins no-op.
 */
async ensureBundledPluginsInstalled(): Promise<void> {
  try {
    await this.installMany([...BUNDLED_PLUGIN_IDS]);
  } catch (err) {
    console.warn('[bundled-plugins] ensure failed:', err);
  }
}
```

- [ ] **Step 4: Run test, confirm it passes**

```bash
cd youcoded/desktop && npx vitest run tests/skill-provider-bundled.test.ts
```

Expected: PASS, 2/2 tests.

- [ ] **Step 5: Wire into main.ts**

Open `youcoded/desktop/src/main/main.ts`. Around line 120-121 there is:

```ts
const skillProvider = new LocalSkillProvider();
skillProvider.ensureMigrated();
```

Add immediately after:

```ts
// Fire-and-forget: install bundled plugins if missing. Silent retry on
// every launch. See docs/superpowers/specs/2026-04-20-bundled-default-plugins-design.md.
void skillProvider.ensureBundledPluginsInstalled();
```

- [ ] **Step 6: Typecheck**

```bash
cd youcoded/desktop && npm run build
```

Expected: build completes with no TypeScript errors.

- [ ] **Step 7: Commit**

```bash
cd youcoded && git add desktop/src/main/skill-provider.ts desktop/src/main/main.ts desktop/tests/skill-provider-bundled.test.ts && git commit -m "feat(plugins): desktop ensureBundledPluginsInstalled on launch"
```

---

### Task 3: Reject uninstall for bundled IDs in desktop IPC handler

**Files:**
- Modify: `youcoded/desktop/src/main/ipc-handlers.ts:771-779`
- Modify: `youcoded/desktop/tests/ipc-handlers.test.ts`

- [ ] **Step 1: Write the failing test**

Append to the existing `describe('IPC Handlers', ...)` block in `youcoded/desktop/tests/ipc-handlers.test.ts` (or add a new `describe` block at the bottom):

```ts
describe('skills:uninstall bundled-plugin rejection', () => {
  it('rejects uninstall for bundled plugin IDs without calling skillProvider.uninstall', async () => {
    const uninstall = vi.fn();
    const mockSkillProvider = {
      configStore: { getPackages: vi.fn(() => ({})) },
      uninstall,
      install: vi.fn(),
      installMany: vi.fn(),
      ensureBundledPluginsInstalled: vi.fn(),
      ensureMigrated: vi.fn(),
    };
    registerIpcHandlers(
      mockIpcMain as any,
      mockSessionManager as any,
      mockWindow as any,
      mockSkillProvider as any,
    );
    const handler = (mockIpcMain.handle as any).mock.calls.find(
      (c: any) => c[0] === 'skills:uninstall',
    )[1];
    const result = await handler({}, 'wecoded-themes-plugin');
    expect(result).toEqual({ ok: false, error: 'bundled', type: 'plugin' });
    expect(uninstall).not.toHaveBeenCalled();
  });

  it('falls through to skillProvider.uninstall for non-bundled IDs', async () => {
    const uninstall = vi.fn().mockResolvedValue({ type: 'plugin' });
    const mockSkillProvider = {
      configStore: { getPackages: vi.fn(() => ({})) },
      uninstall,
      install: vi.fn(),
      installMany: vi.fn(),
      ensureBundledPluginsInstalled: vi.fn(),
      ensureMigrated: vi.fn(),
    };
    registerIpcHandlers(
      mockIpcMain as any,
      mockSessionManager as any,
      mockWindow as any,
      mockSkillProvider as any,
    );
    const handler = (mockIpcMain.handle as any).mock.calls.find(
      (c: any) => c[0] === 'skills:uninstall',
    )[1];
    await handler({}, 'some-other-plugin');
    expect(uninstall).toHaveBeenCalledWith('some-other-plugin');
  });
});
```

- [ ] **Step 2: Run test, confirm it fails**

```bash
cd youcoded/desktop && npx vitest run tests/ipc-handlers.test.ts
```

Expected: FAIL on the first new test — the current handler calls `skillProvider.uninstall` for every id.

- [ ] **Step 3: Implement the rejection**

Open `youcoded/desktop/src/main/ipc-handlers.ts`. Add the import near the top:

```ts
import { isBundledPlugin } from '../shared/bundled-plugins';
```

Modify the `skills:uninstall` handler (lines 771–779) to:

```ts
ipcMain.handle(IPC.SKILLS_UNINSTALL, async (_event, id: string) => {
  // Defense-in-depth: UI disables the uninstall button for bundled
  // plugins; reject here too so a stale client or direct IPC call can't
  // bypass it.
  if (isBundledPlugin(id)) {
    return { ok: false, error: 'bundled', type: 'plugin' };
  }
  const result = await skillProvider.uninstall(id);
  if (result.type === 'plugin') {
    sessionManager.broadcastReloadPlugins();
  }
  return result;
});
```

- [ ] **Step 4: Run test, confirm it passes**

```bash
cd youcoded/desktop && npx vitest run tests/ipc-handlers.test.ts
```

Expected: PASS, both new tests green; existing tests still pass.

- [ ] **Step 5: Typecheck**

```bash
cd youcoded/desktop && npm run build
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
cd youcoded && git add desktop/src/main/ipc-handlers.ts desktop/tests/ipc-handlers.test.ts && git commit -m "feat(plugins): reject bundled-plugin uninstall in desktop IPC"
```

---

### Task 4: Add `ensureBundledPluginsInstalled()` on Android

**Files:**
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/skills/LocalSkillProvider.kt` (add method, add Log import)
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt:186-213` (call method fire-and-forget)

Android has no unit-test suite for `SessionService`; covered by the manual verification checklist in Task 8.

- [ ] **Step 1: Add the method to `LocalSkillProvider.kt`**

Open `youcoded/app/src/main/kotlin/com/youcoded/app/skills/LocalSkillProvider.kt`. Near the top with other imports, add:

```kotlin
import android.util.Log
```

Inside the `LocalSkillProvider` class, after the existing `installMany` method (around line 400), add:

```kotlin
/**
 * Install any bundled plugins that are missing. Runs fire-and-forget on
 * every launch; silent retry next launch on failure. installMany is
 * idempotent — already-installed plugins no-op.
 */
fun ensureBundledPluginsInstalled() {
    try {
        installMany(BundledPlugins.IDS)
    } catch (e: Exception) {
        Log.w("BundledPlugins", "ensure failed", e)
    }
}
```

`BundledPlugins` is in the same package (`com.youcoded.app.skills`), so no additional import is needed.

- [ ] **Step 2: Wire into `SessionService.onCreate()`**

Open `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt`. Find the existing `skillProvider?.ensureMigrated()` line (around line 187, inside `onCreate()`). Add immediately after:

```kotlin
// Fire-and-forget: install bundled plugins if missing. Silent retry on
// every launch. Dispatched on IO so service startup isn't blocked by
// marketplace HTTP.
serviceScope.launch(Dispatchers.IO) {
    skillProvider?.ensureBundledPluginsInstalled()
}
```

If the file doesn't already import `Dispatchers`, add to the imports at the top:

```kotlin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
```

(Check first — `serviceScope.launch` usage elsewhere in the file probably already imports these.)

- [ ] **Step 3: Build to typecheck**

```bash
cd youcoded && ./gradlew assembleDebug
```

Expected: `BUILD SUCCESSFUL`, no Kotlin errors.

- [ ] **Step 4: Commit**

```bash
cd youcoded && git add app/src/main/kotlin/com/youcoded/app/skills/LocalSkillProvider.kt app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt && git commit -m "feat(plugins): android ensureBundledPluginsInstalled on launch"
```

---

### Task 5: Reject uninstall for bundled IDs in Android SessionService

**Files:**
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt:722-728`

- [ ] **Step 1: Replace the `skills:uninstall` case**

Open `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt`. Find the existing `skills:uninstall` case in `handleBridgeMessage()` (lines 722–728). Replace with:

```kotlin
"skills:uninstall" -> {
    val id = msg.payload.optString("id")
    val result = if (BundledPlugins.isBundled(id)) {
        // Defense-in-depth: UI disables the button; reject here too.
        JSONObject()
            .put("ok", false)
            .put("error", "bundled")
            .put("type", "plugin")
    } else {
        skillProvider?.uninstall(id)
            ?: JSONObject().put("ok", false).put("error", "Skill provider not initialized")
    }
    msg.id?.let { bridgeServer.respond(ws, msg.type, it, result) }
}
```

Add the `BundledPlugins` import at the top of the file if not already present:

```kotlin
import com.youcoded.app.skills.BundledPlugins
```

- [ ] **Step 2: Build to typecheck**

```bash
cd youcoded && ./gradlew assembleDebug
```

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 3: Commit**

```bash
cd youcoded && git add app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt && git commit -m "feat(plugins): reject bundled-plugin uninstall in android"
```

---

### Task 6: Disable uninstall button + tooltip in React

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/SkillDetail.tsx:173-180`

The research located the uninstall button in `SkillDetail.tsx` at lines 173–180. The component receives a `skill` object with an `id` field. Before editing, read the component header (top ~30 lines) to confirm the prop name — the id may be `skill.id` or a separately-destructured variable.

- [ ] **Step 1: Add the import**

At the top of `youcoded/desktop/src/renderer/components/SkillDetail.tsx` with the other imports, add:

```tsx
import { isBundledPlugin, BUNDLED_REASON } from '../../shared/bundled-plugins';
```

- [ ] **Step 2: Modify the uninstall button**

Find the existing button block (around line 173–180):

```tsx
{isInstalled ? (
  <button
    onClick={handleUninstall}
    disabled={installing}
    className="px-4 py-1.5 text-sm font-medium rounded-lg border border-edge text-fg-muted hover:text-fg hover:border-edge-dim transition-colors disabled:opacity-50"
  >
    {installing ? 'Removing...' : 'Uninstall'}
  </button>
```

Replace with:

```tsx
{isInstalled ? (
  (() => {
    // Bundled plugins ship with YouCoded and cannot be removed.
    const bundled = isBundledPlugin(skill.id);
    return (
      <button
        onClick={handleUninstall}
        disabled={installing || bundled}
        title={bundled ? BUNDLED_REASON : undefined}
        className="px-4 py-1.5 text-sm font-medium rounded-lg border border-edge text-fg-muted hover:text-fg hover:border-edge-dim transition-colors disabled:opacity-50"
      >
        {installing ? 'Removing...' : 'Uninstall'}
      </button>
    );
  })()
) : (
```

(If the id variable in the component is something other than `skill.id` — e.g. the prop is destructured as `{ id }` or named `plugin` — substitute accordingly. The typecheck in Step 3 will surface any mismatch.)

- [ ] **Step 3: Typecheck + build web UI**

```bash
cd youcoded/desktop && npm run build
```

Expected: no TypeScript errors. Web UI output lands in `desktop/dist/renderer/`.

- [ ] **Step 4: Commit**

```bash
cd youcoded && git add desktop/src/renderer/components/SkillDetail.tsx && git commit -m "feat(plugins): disable uninstall for bundled plugins with tooltip"
```

---

### Task 7: Add PITFALLS.md entry

**Files:**
- Modify: `docs/PITFALLS.md` (workspace-root docs, not inside a sub-repo)

- [ ] **Step 1: Append the entry**

Open `docs/PITFALLS.md` (at the workspace root). Locate the section header `## Plugin Installation & Claude Code Registries`. Append as a new bullet at the end of that section:

```markdown
- **Bundled plugin list is two-way duplicated.** `BUNDLED_PLUGIN_IDS` lives in `desktop/src/shared/bundled-plugins.ts` (imported by both main and renderer) and `app/src/main/kotlin/com/youcoded/app/skills/BundledPlugins.kt`. Both must stay in sync. The list is intentionally hardcoded, not marketplace-driven: (a) offline-first launches can't fetch a remote list, and (b) a remote config would grant the marketplace repo authority to force-install plugins on every client. Changing the list requires an app release. Also update this PITFALLS entry when the list changes.
```

- [ ] **Step 2: Commit**

```bash
cd /c/Users/desti/youcoded-dev && git add docs/PITFALLS.md && git commit -m "docs(pitfalls): bundled plugin parity requirement"
```

Note: this commit is in the workspace-root repo (`youcoded-dev`), not the `youcoded` sub-repo.

---

### Task 8: Manual verification

No code changes. Run each check in order; if any fail, fix before declaring the implementation complete.

- [ ] **Step 1: Desktop fresh install**

```bash
# Back up current plugin registry
mv ~/.claude/plugins/installed_plugins.json ~/.claude/plugins/installed_plugins.json.bak
# Launch dev app
cd /c/Users/desti/youcoded-dev && bash scripts/run-dev.sh
```

Wait 10–15 seconds for marketplace cache + install. Open the Skills panel. Verify:
- `wecoded-themes-plugin` appears in the installed list.
- `wecoded-marketplace-publisher` appears in the installed list.

Close the dev app. Restore the backup:

```bash
mv ~/.claude/plugins/installed_plugins.json.bak ~/.claude/plugins/installed_plugins.json
```

- [ ] **Step 2: Desktop uninstall disabled + tooltip**

Relaunch dev app. Open the Skills panel, click into the detail view for `wecoded-themes-plugin`. Verify:
- The Uninstall button is disabled (renders with `opacity-50`, does not respond to click).
- Hovering the button shows the tooltip: `Bundled with YouCoded — required for theme customization and publishing.`

Repeat for `wecoded-marketplace-publisher`.

- [ ] **Step 3: Desktop partial-missing**

Close dev app. Edit `~/.claude/plugins/installed_plugins.json` and delete **only** the `wecoded-themes-plugin` entry (keep the publisher entry intact). Save. Relaunch dev app. Wait 10–15 seconds. Verify:
- `wecoded-themes-plugin` reappears in the installed list.
- `wecoded-marketplace-publisher` entry in `installed_plugins.json` is unchanged (same `installedAt`, same version).

- [ ] **Step 4: Desktop offline**

Disconnect from network (airplane mode / unplug ethernet). Back up and clear the installed plugins:

```bash
mv ~/.claude/plugins/installed_plugins.json ~/.claude/plugins/installed_plugins.json.bak2
```

Launch dev app. Verify:
- No error toast, modal, or banner.
- Skills panel shows neither bundled plugin installed.
- App is otherwise usable.

Reconnect network, relaunch. Verify both install. Restore backup if needed.

- [ ] **Step 5: Desktop force-uninstall via devtools**

In the running dev app, open devtools (Ctrl+Shift+I on Windows). In the console, run:

```js
await window.claude.skills.uninstall('wecoded-themes-plugin')
```

Verify:
- Returned value is `{ ok: false, error: 'bundled', type: 'plugin' }`.
- Plugin still appears in the Skills panel.
- No entry removal in `~/.claude/plugins/installed_plugins.json`.

- [ ] **Step 6: Android fresh install**

Build and install the debug APK:

```bash
cd /c/Users/desti/youcoded-dev/youcoded && ./scripts/build-web-ui.sh && ./gradlew installDebug
```

Launch the app on device/emulator. Complete bootstrap + tier picker if this is a clean install. Wait for skill provider init (~20–30s). Open the Skills panel. Verify:
- Both bundled plugins appear installed.
- Uninstall is disabled + tooltip shows the bundled reason.

- [ ] **Step 7: Android force-uninstall via remote browser**

Enable remote access in the Android app. From a desktop browser on the same network, open the remote URL shown by the app. Open browser devtools console and run:

```js
await window.claude.skills.uninstall('wecoded-marketplace-publisher')
```

Verify:
- Response is `{ ok: false, error: 'bundled', type: 'plugin' }`.
- Plugin still present in the Android Skills panel after a refresh.

- [ ] **Step 8: Confirm no regressions**

Quick sanity sweep in both apps:
- Install any non-bundled plugin from the marketplace. Verify Uninstall is enabled and works (click → plugin removed from list).
- Confirm the app launch time feels normal — the fire-and-forget install should not delay the UI becoming interactive.

If all eight steps pass, the implementation is complete. Create a final commit on the feature branch, push, and hand off for PR.

---

## Self-Review

**1. Spec coverage:**

| Spec section | Implementing task(s) |
|---|---|
| Architecture — entry point (`ensureBundledPluginsInstalled`) | Tasks 2 (desktop), 4 (Android) |
| Architecture — trigger (fire-and-forget at startup) | Tasks 2 Step 5, 4 Step 2 |
| Architecture — shared constant | Task 1 |
| Components — desktop SkillProvider | Task 2 |
| Components — desktop IPC rejection | Task 3 |
| Components — Android LocalSkillProvider | Task 4 |
| Components — Android SessionService rejection | Task 5 |
| Components — renderer disabled button + tooltip | Task 6 |
| Data Flow — install-if-missing path | Tasks 2, 4 (idempotent installMany) |
| Data Flow — uninstall rejection path | Tasks 3, 5, 6 |
| Error Handling — silent retry | Tasks 2, 4 (try/catch + log) |
| Testing — unit tests | Tasks 2 & 3 |
| Testing — manual checklist | Task 8 |
| Documentation updates — PITFALLS | Task 7 |

All spec sections are covered. No gaps.

**2. Placeholder scan:** No TBDs, no "implement later", no vague instructions. Task 6 includes a deliberate hedge on the prop name (`skill.id`) with a typecheck step that will surface any mismatch — this is a real implementation detail, not a placeholder.

**3. Type consistency:**
- `BUNDLED_PLUGIN_IDS` (TS) / `BundledPlugins.IDS` (Kotlin) — used consistently.
- `isBundledPlugin(id)` (TS) / `BundledPlugins.isBundled(id)` (Kotlin) — used consistently.
- `BUNDLED_REASON` / `BundledPlugins.REASON` — used consistently.
- Rejection response shape `{ ok: false, error: 'bundled', type: 'plugin' }` — identical across desktop IPC (Task 3) and Android SessionService (Task 5).
- `ensureBundledPluginsInstalled()` — same signature on both platforms.
