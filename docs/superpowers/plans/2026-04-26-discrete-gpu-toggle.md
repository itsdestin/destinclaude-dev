# Discrete GPU Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Performance section to YouCoded's Settings exposing a single `preferPowerSaving` toggle that flips Chromium's `force-high-performance-gpu` (default) vs `force-low-power-gpu` switch at startup, with an info popup explaining the GPU framing and listing OS-level overrides.

**Architecture:** A small new `performance-config.ts` module in the Electron main process synchronously reads `~/.claude/youcoded-performance.json` before `app.whenReady()` and applies the appropriate Chromium switch. After `whenReady`, it asynchronously caches the GPU device list via `app.getGPUInfo('complete')`. Three new IPC channels expose state to the renderer; an Android stub keeps cross-platform parity. The renderer adds a `usePerformanceConfig` hook and a `Performance` section to `SettingsPanel.tsx` that's hidden when only one GPU is detected.

**Tech Stack:** Electron 33+, React 18, TypeScript, Vitest, Kotlin (Android stub).

**Spec:** `docs/superpowers/specs/2026-04-26-discrete-gpu-toggle-design.md`

**Worktree:** Create one before starting:

```bash
cd ~/youcoded-dev/youcoded
git worktree add ../youcoded-worktrees/discrete-gpu-toggle -b feat/discrete-gpu-toggle
cd ../youcoded-worktrees/discrete-gpu-toggle
npm --prefix desktop ci
```

All paths in the tasks below are relative to the worktree root (`youcoded/`).

---

## File structure

| File | Action | Responsibility |
|------|--------|----------------|
| `desktop/src/main/performance-config.ts` | Create | Read/write `~/.claude/youcoded-performance.json`, parse + validate, expose `loadConfigSync()`, `writeConfig()`, `cacheGpuInfo()` |
| `desktop/src/main/performance-config.test.ts` | Create | Unit tests for read/parse/validate/write |
| `desktop/src/main/main.ts` | Modify | Call `loadConfigSync()` and `app.commandLine.appendSwitch()` before `app.whenReady()`; call `cacheGpuInfo()` after |
| `desktop/src/shared/types.ts` | Modify | Add `PERFORMANCE_GET_CONFIG`, `PERFORMANCE_SET_CONFIG`, `APP_RESTART` channel constants and shared types |
| `desktop/src/main/preload.ts` | Modify | Expose `window.claude.performance.{get,set}()` and `window.claude.app.restart()` |
| `desktop/src/renderer/remote-shim.ts` | Modify | Mirror the new APIs over WebSocket |
| `desktop/src/main/ipc-handlers.ts` | Modify | Implement the three handlers |
| `app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` | Modify | Add Android no-op stubs for parity |
| `desktop/src/renderer/hooks/usePerformanceConfig.ts` | Create | Renderer hook: load config on mount, expose `setPreferPowerSaving`, `restart`, `saved`, `appliedAtLaunch`, `multiGpuDetected`, `gpuList` |
| `desktop/src/renderer/components/PerformanceSection.tsx` | Create | The `Performance` section UI (header, toggle row, inline restart notice, detected GPUs line) |
| `desktop/src/renderer/components/PerformancePopup.tsx` | Create | The `(i)` info popup with intro + sections (matches `REMOTE_ACCESS_EXPLAINER` pattern) |
| `desktop/src/renderer/components/SettingsPanel.tsx` | Modify | Render `<PerformanceSection />` between Appearance and Sync in both AndroidSettings and DesktopSettings |
| `desktop/tests/ipc-channels.test.ts` | Modify | Add a `describe('performance:* and app:restart parity')` block with three `it()` assertions (preload, remote-shim, SessionService) |

Two utility helpers in `performance-config.ts` are reused across tasks: `loadConfigSync(): { preferPowerSaving: boolean, raw: Record<string, unknown> }` (raw is preserved on rewrite for forward-compat) and `writeConfig(next: { preferPowerSaving: boolean })` (merges into raw, writes atomically).

---

### Task 1: PerformanceConfig module

**Files:**
- Create: `desktop/src/main/performance-config.ts`
- Test: `desktop/src/main/performance-config.test.ts`

- [ ] **Step 1: Write the failing tests**

```typescript
// desktop/src/main/performance-config.test.ts
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { loadConfigSync, writeConfig, _setConfigPathForTesting } from './performance-config';

const TMP = path.join(os.tmpdir(), `yc-perf-${Date.now()}-${Math.random()}`);
const FILE = path.join(TMP, 'youcoded-performance.json');

beforeEach(() => {
  fs.mkdirSync(TMP, { recursive: true });
  _setConfigPathForTesting(FILE);
});

afterEach(() => {
  fs.rmSync(TMP, { recursive: true, force: true });
});

describe('performance-config', () => {
  it('returns default when file is missing', () => {
    const cfg = loadConfigSync();
    expect(cfg.preferPowerSaving).toBe(false);
    expect(cfg.raw).toEqual({});
  });

  it('returns default when file is unparseable JSON', () => {
    fs.writeFileSync(FILE, '{ not valid json');
    const cfg = loadConfigSync();
    expect(cfg.preferPowerSaving).toBe(false);
    expect(cfg.raw).toEqual({});
  });

  it('reads valid preferPowerSaving=true', () => {
    fs.writeFileSync(FILE, JSON.stringify({ preferPowerSaving: true }));
    const cfg = loadConfigSync();
    expect(cfg.preferPowerSaving).toBe(true);
  });

  it('reads valid preferPowerSaving=false', () => {
    fs.writeFileSync(FILE, JSON.stringify({ preferPowerSaving: false }));
    const cfg = loadConfigSync();
    expect(cfg.preferPowerSaving).toBe(false);
  });

  it('coerces non-boolean preferPowerSaving to false', () => {
    fs.writeFileSync(FILE, JSON.stringify({ preferPowerSaving: 'yes' }));
    const cfg = loadConfigSync();
    expect(cfg.preferPowerSaving).toBe(false);
  });

  it('preserves unknown keys on the raw object', () => {
    fs.writeFileSync(FILE, JSON.stringify({ preferPowerSaving: true, futureKey: 'keep me' }));
    const cfg = loadConfigSync();
    expect(cfg.raw).toEqual({ preferPowerSaving: true, futureKey: 'keep me' });
  });

  it('writeConfig merges into existing raw and persists', () => {
    fs.writeFileSync(FILE, JSON.stringify({ futureKey: 'keep me', preferPowerSaving: false }));
    writeConfig({ preferPowerSaving: true });
    const onDisk = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    expect(onDisk).toEqual({ futureKey: 'keep me', preferPowerSaving: true });
  });

  it('writeConfig creates the file when missing', () => {
    writeConfig({ preferPowerSaving: true });
    const onDisk = JSON.parse(fs.readFileSync(FILE, 'utf8'));
    expect(onDisk).toEqual({ preferPowerSaving: true });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd desktop && npx vitest run src/main/performance-config.test.ts
```
Expected: FAIL with "Cannot find module './performance-config'".

- [ ] **Step 3: Implement the module**

```typescript
// desktop/src/main/performance-config.ts
import fs from 'fs';
import os from 'os';
import path from 'path';

// Lives alongside youcoded-remote.json, youcoded-favorites.json. Single source
// of truth for performance-related prefs that need to be readable by main
// before the renderer exists.
let configPath = path.join(os.homedir(), '.claude', 'youcoded-performance.json');

// Test seam — production code must NOT call this.
export function _setConfigPathForTesting(p: string) {
  configPath = p;
}

export interface PerformanceConfig {
  preferPowerSaving: boolean;
  // The full parsed object, preserved so writeConfig can keep unknown keys
  // for forward-compat. Keys that don't appear in the schema today still
  // round-trip through a save.
  raw: Record<string, unknown>;
}

// Sync read because it must run before app.whenReady(). Tiny file, single
// startup call — no perf concern. Failures are silently swallowed (defaults
// to preferPowerSaving:false) since user pref absence is normal on first launch.
export function loadConfigSync(): PerformanceConfig {
  let raw: Record<string, unknown> = {};
  try {
    const text = fs.readFileSync(configPath, 'utf8');
    const parsed = JSON.parse(text);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      raw = parsed as Record<string, unknown>;
    }
  } catch (err: unknown) {
    // Missing file is normal — no warning. Other failures (malformed JSON,
    // permission denied) are interesting but non-fatal.
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.warn('[performance-config] failed to read', configPath, err);
    }
  }
  const preferPowerSaving = raw.preferPowerSaving === true;
  return { preferPowerSaving, raw };
}

export function writeConfig(next: { preferPowerSaving: boolean }): void {
  const current = loadConfigSync();
  const merged = { ...current.raw, preferPowerSaving: next.preferPowerSaving };
  const dir = path.dirname(configPath);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(configPath, JSON.stringify(merged, null, 2), 'utf8');
}

// Cached after app.whenReady() resolves app.getGPUInfo('complete'). Kept here
// so other startup code can pull the cached value without re-querying.
let cachedGpuList: string[] = [];
let cachedMultiGpu = false;
let appliedAtLaunch = false;

export function setAppliedAtLaunch(value: boolean) { appliedAtLaunch = value; }
export function getAppliedAtLaunch(): boolean { return appliedAtLaunch; }

export function setCachedGpu(list: string[]) {
  cachedGpuList = list;
  cachedMultiGpu = list.length > 1;
}

export function getCachedGpu(): { multiGpuDetected: boolean; gpuList: string[] } {
  return { multiGpuDetected: cachedMultiGpu, gpuList: cachedGpuList };
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd desktop && npx vitest run src/main/performance-config.test.ts
```
Expected: 8 passed.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/performance-config.ts desktop/src/main/performance-config.test.ts
git commit -m "feat(performance): add performance-config module for GPU pref persistence"
```

---

### Task 2: Wire startup switch in main.ts

**Files:**
- Modify: `desktop/src/main/main.ts` (add imports near top, add switch logic before `app.whenReady()` at ~line 994, add GPU cache call after `app.whenReady()`)

- [ ] **Step 1: Add the imports near the existing imports**

Add at the bottom of the import block (around line 30, after the existing `runAnalyticsOnLaunch` import):

```typescript
import { loadConfigSync, setAppliedAtLaunch, setCachedGpu } from './performance-config';
```

- [ ] **Step 2: Apply the Chromium switch BEFORE app.whenReady()**

Insert this block immediately after the existing top-level platform-specific code (around line 56, after the macOS/Linux PATH munging closes). It must run BEFORE `app.whenReady()` is called — Chromium switches are read at app initialization.

```typescript
// Apply GPU preference. Reads ~/.claude/youcoded-performance.json synchronously.
// Default (file missing OR preferPowerSaving=false) → request the discrete GPU.
// preferPowerSaving=true → request the integrated GPU.
// These are hints to Chromium; the OS may still override (Windows Settings →
// Graphics, NVIDIA Control Panel). The "Restart to apply" notice in
// SettingsPanel uses appliedAtLaunch — set here — to know whether the running
// process matches the on-disk config.
{
  const perf = loadConfigSync();
  if (perf.preferPowerSaving) {
    app.commandLine.appendSwitch('force-low-power-gpu');
  } else {
    app.commandLine.appendSwitch('force-high-performance-gpu');
  }
  setAppliedAtLaunch(perf.preferPowerSaving);
}
```

- [ ] **Step 3: Cache GPU info after app.whenReady()**

Inside the existing `app.whenReady().then(async () => { ... })` block (starts at ~line 994), add this near the top of the async function — early enough that the cache is populated before any IPC handler can be called, but after the app is ready:

```typescript
  // Cache the GPU device list once. Used by the Performance section in
  // SettingsPanel to decide whether to render (hidden on single-GPU systems)
  // and to surface a "Detected GPUs: ..." line under the toggle. Async
  // because getGPUInfo can take 1-2s on first call; the IPC handler returns
  // multiGpuDetected:false until this resolves.
  app.getGPUInfo('complete').then((info: unknown) => {
    const list: string[] = [];
    // Electron's GPUInfo shape uses `gpuDevice` (singular array). Names live
    // in auxAttributes.glRenderer for the active device, but device-level
    // names are not always populated — fall back to a vendor/device-id hint.
    if (info && typeof info === 'object') {
      const gpuDevice = (info as { gpuDevice?: Array<Record<string, unknown>> }).gpuDevice;
      const aux = (info as { auxAttributes?: Record<string, unknown> }).auxAttributes;
      if (Array.isArray(gpuDevice)) {
        for (const d of gpuDevice) {
          const renderer = typeof aux?.glRenderer === 'string' && d.active === true
            ? (aux.glRenderer as string)
            : null;
          const fallback = `GPU vendor=${d.vendorId ?? '?'} device=${d.deviceId ?? '?'}`;
          list.push(renderer ?? fallback);
        }
      }
    }
    setCachedGpu(list);
  }).catch((err: unknown) => {
    log('[performance] getGPUInfo failed:', err);
    setCachedGpu([]);
  });
```

- [ ] **Step 4: Verify the build still typechecks**

```bash
cd desktop && npx tsc --noEmit
```
Expected: no errors.

- [ ] **Step 5: Run all main-process tests to confirm no regression**

```bash
cd desktop && npx vitest run src/main/
```
Expected: all existing tests still pass; new performance-config tests still pass.

- [ ] **Step 6: Commit**

```bash
git add desktop/src/main/main.ts
git commit -m "feat(performance): apply GPU pref Chromium switch at startup"
```

---

### Task 3: Define IPC channels + preload + remote-shim

**Files:**
- Modify: `desktop/src/shared/types.ts` (add channel constants and types)
- Modify: `desktop/src/main/preload.ts` (expose `window.claude.performance` and `window.claude.app.restart`)
- Modify: `desktop/src/renderer/remote-shim.ts` (mirror over WebSocket)

- [ ] **Step 1: Add channel constants and shared types to `shared/types.ts`**

Inside the existing `IPC` constant object, add three new entries (place them in alphabetical order or grouped with related namespaces):

```typescript
  PERFORMANCE_GET_CONFIG: 'performance:get-config',
  PERFORMANCE_SET_CONFIG: 'performance:set-config',
  APP_RESTART: 'app:restart',
```

After the IPC object, add the shared types (near other IPC payload types):

```typescript
export interface PerformanceConfigSnapshot {
  preferPowerSaving: boolean;
  appliedAtLaunch: boolean;
  multiGpuDetected: boolean;
  gpuList: string[];
}
```

- [ ] **Step 2: Add the same channel strings to preload's inline IPC constant**

Edit `desktop/src/main/preload.ts`, find the `const IPC = { ... }` block at the top, and add:

```typescript
  PERFORMANCE_GET_CONFIG: 'performance:get-config',
  PERFORMANCE_SET_CONFIG: 'performance:set-config',
  APP_RESTART: 'app:restart',
```

- [ ] **Step 3: Expose the APIs on `window.claude`**

In `preload.ts`, find where `window.claude` is built up via `contextBridge.exposeInMainWorld`. Add a new `performance` namespace and extend `app`:

```typescript
  performance: {
    get: (): Promise<PerformanceConfigSnapshot> =>
      ipcRenderer.invoke(IPC.PERFORMANCE_GET_CONFIG),
    set: (preferPowerSaving: boolean): Promise<{ ok: true }> =>
      ipcRenderer.invoke(IPC.PERFORMANCE_SET_CONFIG, { preferPowerSaving }),
  },
  app: {
    restart: (): Promise<void> => ipcRenderer.invoke(IPC.APP_RESTART),
  },
```

If a `window.claude.app` namespace already exists, add `restart` to it without duplicating the namespace.

Type this addition by adding to the shared `WindowClaude` interface in `shared/types.ts` (or wherever `window.claude` is typed):

```typescript
performance: {
  get: () => Promise<PerformanceConfigSnapshot>;
  set: (preferPowerSaving: boolean) => Promise<{ ok: true }>;
};
app: {
  restart: () => Promise<void>;
  // ...existing app methods
};
```

- [ ] **Step 4: Mirror the API in remote-shim.ts**

Edit `desktop/src/renderer/remote-shim.ts`. Find the `installRemoteShim()` function where `window.claude` is built. Add a `performance` namespace and `app.restart`. Both go through the WebSocket invoke helper (search for an existing example, e.g. how `dev.logTail` is implemented around line 897):

```typescript
  performance: {
    get: () => invoke<PerformanceConfigSnapshot>('performance:get-config'),
    set: (preferPowerSaving: boolean) =>
      invoke<{ ok: true }>('performance:set-config', { preferPowerSaving }),
  },
  app: {
    restart: () => invoke<void>('app:restart'),
    // ...keep any existing app methods on this namespace
  },
```

Import the type at the top:

```typescript
import type { PerformanceConfigSnapshot } from '../shared/types';
```

- [ ] **Step 5: Typecheck**

```bash
cd desktop && npx tsc --noEmit
```
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add desktop/src/shared/types.ts desktop/src/main/preload.ts desktop/src/renderer/remote-shim.ts
git commit -m "feat(performance): add performance:* and app:restart IPC channels"
```

---

### Task 4: Implement IPC handlers in main process

**Files:**
- Modify: `desktop/src/main/ipc-handlers.ts`

- [ ] **Step 1: Add imports near the top of ipc-handlers.ts**

Confirm Electron's `app` is already imported. If `import { ... } from 'electron'` is present but doesn't include `app`, add it. Then add:

```typescript
import { loadConfigSync, writeConfig, getAppliedAtLaunch, getCachedGpu } from './performance-config';
import type { PerformanceConfigSnapshot } from '../shared/types';
```

- [ ] **Step 2: Register the three handlers**

Inside `registerIpcHandlers()` (the function that wires up `ipcMain.handle` calls), add:

```typescript
  ipcMain.handle(IPC.PERFORMANCE_GET_CONFIG, (): PerformanceConfigSnapshot => {
    const cfg = loadConfigSync();
    const gpu = getCachedGpu();
    return {
      preferPowerSaving: cfg.preferPowerSaving,
      appliedAtLaunch: getAppliedAtLaunch(),
      multiGpuDetected: gpu.multiGpuDetected,
      gpuList: gpu.gpuList,
    };
  });

  ipcMain.handle(IPC.PERFORMANCE_SET_CONFIG, (_event, payload: { preferPowerSaving: boolean }) => {
    // Validate the payload — IPC inputs are untrusted (a remote browser
    // client could send anything). We coerce to a strict boolean.
    const next = payload?.preferPowerSaving === true;
    writeConfig({ preferPowerSaving: next });
    return { ok: true as const };
  });

  ipcMain.handle(IPC.APP_RESTART, () => {
    // Generic restart channel — reused by any future setting that needs a
    // restart to apply. relaunch() schedules the restart for after exit().
    app.relaunch();
    app.exit(0);
  });
```

- [ ] **Step 3: Manual smoke verification**

Build and launch the app to confirm the handlers don't throw on startup wiring. Full functional test happens in Task 7.

```bash
cd desktop && npx tsc --noEmit && npm run build
```
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/main/ipc-handlers.ts
git commit -m "feat(performance): wire ipc handlers for config get/set and app restart"
```

---

### Task 5: Add Android stub handlers in SessionService.kt

**Files:**
- Modify: `app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt`

- [ ] **Step 1: Add the three when-cases inside `handleBridgeMessage`**

Find the `when (msg.type) { ... }` block in `handleBridgeMessage` (starts ~line 663). Add these cases anywhere inside it — alphabetical placement is fine:

```kotlin
            "performance:get-config" -> {
                // Android has no userland GPU choice. Always return defaults so
                // the renderer's Performance section stays hidden (it gates on
                // multiGpuDetected). Keeps IPC parity green without surfacing
                // a setting that has no effect on Android.
                val payload = JSONObject().apply {
                    put("preferPowerSaving", false)
                    put("appliedAtLaunch", false)
                    put("multiGpuDetected", false)
                    put("gpuList", JSONArray())
                }
                msg.id?.let { bridgeServer.respond(ws, msg.type, it, payload) }
            }
            "performance:set-config" -> {
                // No-op write. We accept the payload silently so the renderer
                // doesn't see an error if it ever fires this on Android.
                val payload = JSONObject().apply { put("ok", true) }
                msg.id?.let { bridgeServer.respond(ws, msg.type, it, payload) }
            }
            "app:restart" -> {
                // Android session lifecycle differs — a restart equivalent
                // would be killing and respawning SessionService. Out of scope
                // for the GPU-toggle feature. Acknowledge so the parity test
                // stays green; the Performance section is hidden on Android
                // so this branch is unreachable in normal use anyway.
                msg.id?.let { bridgeServer.respond(ws, msg.type, it, JSONObject.NULL) }
            }
```

If `JSONArray` isn't already imported at the top of the file, add `import org.json.JSONArray`.

- [ ] **Step 2: Add the IPC parity test**

Edit `desktop/tests/ipc-channels.test.ts`. After the existing `analytics:*` describe block, add a new describe:

```typescript
describe('performance:* and app:restart parity', () => {
  const channels = ['performance:get-config', 'performance:set-config', 'app:restart'];

  it('all three types are declared in preload.ts', () => {
    const preload = fs.readFileSync(
      path.join(__dirname, '../src/main/preload.ts'), 'utf8'
    );
    for (const ch of channels) {
      expect(preload, `${ch} missing from preload.ts`).toContain(`'${ch}'`);
    }
  });

  it('all three types are referenced in remote-shim.ts', () => {
    const shim = fs.readFileSync(
      path.join(__dirname, '../src/renderer/remote-shim.ts'), 'utf8'
    );
    for (const ch of channels) {
      expect(shim, `${ch} missing from remote-shim.ts`).toContain(`'${ch}'`);
    }
  });

  it('all three types are handled by SessionService.kt (Android)', () => {
    const kt = fs.readFileSync(
      path.join(__dirname, '../../app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt'),
      'utf8'
    );
    for (const ch of channels) {
      expect(kt, `${ch} missing from SessionService.kt`).toContain(`"${ch}"`);
    }
  });
});
```

- [ ] **Step 3: Run the parity test**

```bash
cd desktop && npx vitest run tests/ipc-channels.test.ts
```
Expected: all three new `it()` assertions pass.

- [ ] **Step 4: Build the Android module to confirm Kotlin compiles**

```bash
cd .. && ./gradlew :app:compileDebugKotlin
```
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: Commit**

```bash
git add app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt desktop/tests/ipc-channels.test.ts
git commit -m "feat(performance): android stub handlers + ipc parity test"
```

---

### Task 6: Renderer hook `usePerformanceConfig`

**Files:**
- Create: `desktop/src/renderer/hooks/usePerformanceConfig.ts`
- Test: `desktop/src/renderer/hooks/usePerformanceConfig.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// desktop/src/renderer/hooks/usePerformanceConfig.test.ts
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { renderHook, act, waitFor } from '@testing-library/react';
import { usePerformanceConfig } from './usePerformanceConfig';

const mockGet = vi.fn();
const mockSet = vi.fn();
const mockRestart = vi.fn();

beforeEach(() => {
  mockGet.mockReset();
  mockSet.mockReset();
  mockRestart.mockReset();
  (globalThis as unknown as { window: { claude: unknown } }).window = {
    claude: {
      performance: { get: mockGet, set: mockSet },
      app: { restart: mockRestart },
    },
  };
});

describe('usePerformanceConfig', () => {
  it('loads config on mount', async () => {
    mockGet.mockResolvedValue({
      preferPowerSaving: false,
      appliedAtLaunch: false,
      multiGpuDetected: true,
      gpuList: ['Intel Iris Xe', 'NVIDIA RTX 4070'],
    });
    const { result } = renderHook(() => usePerformanceConfig());
    await waitFor(() => expect(result.current.loaded).toBe(true));
    expect(result.current.saved).toBe(false);
    expect(result.current.appliedAtLaunch).toBe(false);
    expect(result.current.multiGpuDetected).toBe(true);
    expect(result.current.gpuList).toEqual(['Intel Iris Xe', 'NVIDIA RTX 4070']);
  });

  it('setPreferPowerSaving updates saved optimistically and persists', async () => {
    mockGet.mockResolvedValue({
      preferPowerSaving: false, appliedAtLaunch: false,
      multiGpuDetected: true, gpuList: ['A', 'B'],
    });
    mockSet.mockResolvedValue({ ok: true });
    const { result } = renderHook(() => usePerformanceConfig());
    await waitFor(() => expect(result.current.loaded).toBe(true));

    await act(async () => { await result.current.setPreferPowerSaving(true); });

    expect(result.current.saved).toBe(true);
    expect(mockSet).toHaveBeenCalledWith(true);
  });

  it('setPreferPowerSaving reverts saved on persistence failure', async () => {
    mockGet.mockResolvedValue({
      preferPowerSaving: false, appliedAtLaunch: false,
      multiGpuDetected: true, gpuList: ['A', 'B'],
    });
    mockSet.mockRejectedValue(new Error('disk full'));
    const { result } = renderHook(() => usePerformanceConfig());
    await waitFor(() => expect(result.current.loaded).toBe(true));

    await act(async () => {
      await expect(result.current.setPreferPowerSaving(true)).rejects.toThrow();
    });

    expect(result.current.saved).toBe(false);
  });

  it('needsRestart is true when saved !== appliedAtLaunch', async () => {
    mockGet.mockResolvedValue({
      preferPowerSaving: true, appliedAtLaunch: false,
      multiGpuDetected: true, gpuList: ['A', 'B'],
    });
    const { result } = renderHook(() => usePerformanceConfig());
    await waitFor(() => expect(result.current.loaded).toBe(true));
    expect(result.current.needsRestart).toBe(true);
  });

  it('restart() calls window.claude.app.restart', async () => {
    mockGet.mockResolvedValue({
      preferPowerSaving: false, appliedAtLaunch: false,
      multiGpuDetected: true, gpuList: ['A', 'B'],
    });
    const { result } = renderHook(() => usePerformanceConfig());
    await waitFor(() => expect(result.current.loaded).toBe(true));
    await act(async () => { await result.current.restart(); });
    expect(mockRestart).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd desktop && npx vitest run src/renderer/hooks/usePerformanceConfig.test.ts
```
Expected: FAIL with "Cannot find module './usePerformanceConfig'".

- [ ] **Step 3: Implement the hook**

```typescript
// desktop/src/renderer/hooks/usePerformanceConfig.ts
import { useCallback, useEffect, useState } from 'react';
import type { PerformanceConfigSnapshot } from '../../shared/types';

interface UsePerformanceConfigResult {
  loaded: boolean;
  saved: boolean;            // current persisted value
  appliedAtLaunch: boolean;  // value the running process actually used
  multiGpuDetected: boolean;
  gpuList: string[];
  needsRestart: boolean;     // saved !== appliedAtLaunch
  setPreferPowerSaving: (value: boolean) => Promise<void>;
  restart: () => Promise<void>;
}

const DEFAULT_SNAPSHOT: PerformanceConfigSnapshot = {
  preferPowerSaving: false,
  appliedAtLaunch: false,
  multiGpuDetected: false,
  gpuList: [],
};

export function usePerformanceConfig(): UsePerformanceConfigResult {
  const [loaded, setLoaded] = useState(false);
  const [snapshot, setSnapshot] = useState<PerformanceConfigSnapshot>(DEFAULT_SNAPSHOT);

  useEffect(() => {
    let cancelled = false;
    window.claude.performance.get().then((s) => {
      if (cancelled) return;
      setSnapshot(s);
      setLoaded(true);
    }).catch(() => {
      if (cancelled) return;
      setLoaded(true); // surface defaults — section will hide due to multiGpuDetected:false
    });
    return () => { cancelled = true; };
  }, []);

  const setPreferPowerSaving = useCallback(async (value: boolean) => {
    // Optimistic update: flip saved synchronously so the toggle responds
    // immediately. If the IPC fails, revert.
    setSnapshot((prev) => ({ ...prev, preferPowerSaving: value }));
    try {
      await window.claude.performance.set(value);
    } catch (err) {
      setSnapshot((prev) => ({ ...prev, preferPowerSaving: !value }));
      throw err;
    }
  }, []);

  const restart = useCallback(async () => {
    await window.claude.app.restart();
  }, []);

  return {
    loaded,
    saved: snapshot.preferPowerSaving,
    appliedAtLaunch: snapshot.appliedAtLaunch,
    multiGpuDetected: snapshot.multiGpuDetected,
    gpuList: snapshot.gpuList,
    needsRestart: snapshot.preferPowerSaving !== snapshot.appliedAtLaunch,
    setPreferPowerSaving,
    restart,
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd desktop && npx vitest run src/renderer/hooks/usePerformanceConfig.test.ts
```
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/hooks/usePerformanceConfig.ts desktop/src/renderer/hooks/usePerformanceConfig.test.ts
git commit -m "feat(performance): add usePerformanceConfig renderer hook"
```

---

### Task 7: Performance section UI in SettingsPanel

**Files:**
- Create: `desktop/src/renderer/components/PerformanceSection.tsx`
- Modify: `desktop/src/renderer/components/SettingsPanel.tsx`

- [ ] **Step 1: Create the section component**

```tsx
// desktop/src/renderer/components/PerformanceSection.tsx
import React, { useState } from 'react';
import { usePerformanceConfig } from '../hooks/usePerformanceConfig';
import { InfoIconButton } from './SettingsExplainer';
import PerformancePopup from './PerformancePopup';

// The Performance section in SettingsPanel. Hidden when only one GPU is
// detected (or when GPU enumeration failed) so single-GPU systems don't see
// a non-functional control. The (i) info icon opens an explainer popup that
// frames the GPU-vs-iGPU tradeoff and lists OS-level overrides.
export default function PerformanceSection() {
  const { loaded, saved, multiGpuDetected, gpuList, needsRestart,
          setPreferPowerSaving, restart } = usePerformanceConfig();
  const [showInfo, setShowInfo] = useState(false);
  const [restarting, setRestarting] = useState(false);

  // Hide entirely if config hasn't loaded yet OR only one GPU is present.
  // Single-GPU systems include desktops with iGPU only, Apple Silicon Macs,
  // and Linux systems where Chromium reported one device. Detection failures
  // (rejected promise, empty gpuDevice array) also fall through to hidden.
  if (!loaded || !multiGpuDetected) return null;

  const handleRestart = async () => {
    setRestarting(true);
    try {
      await restart();
    } catch {
      setRestarting(false);
    }
  };

  return (
    <div className="mb-6">
      <div className="flex items-center mb-3 gap-2">
        <h3 className="text-[10px] font-medium text-fg-muted tracking-wider uppercase">
          Performance
        </h3>
        <InfoIconButton onClick={() => setShowInfo(true)} />
      </div>

      <p className="text-xs text-fg-2 mb-3">GPU choice affects performance.</p>

      <button
        type="button"
        onClick={() => setPreferPowerSaving(!saved)}
        className="w-full text-left flex items-start gap-3 p-3 rounded-lg hover:bg-inset transition-colors"
      >
        <span className={`mt-0.5 inline-block w-4 h-4 rounded border ${
          saved ? 'bg-accent border-accent' : 'border-edge'
        }`} />
        <span className="flex-1">
          <span className="block text-sm text-fg">Prefer power saving</span>
          <span className="block text-xs text-fg-muted mt-0.5">
            Use the integrated GPU instead of the discrete one. Saves battery,
            but UI animations may stutter.
          </span>
        </span>
      </button>

      {needsRestart && (
        <div className="mt-2 px-3 py-2 rounded-lg bg-inset flex items-center justify-between gap-3">
          <span className="text-xs text-fg-2">⟳ Restart YouCoded to apply.</span>
          <button
            type="button"
            onClick={handleRestart}
            disabled={restarting}
            className="text-xs px-3 py-1 rounded bg-accent text-on-accent disabled:opacity-60"
          >
            {restarting ? 'Restarting…' : 'Restart now'}
          </button>
        </div>
      )}

      {gpuList.length > 0 && (
        <p className="text-[11px] text-fg-muted mt-3">
          Detected GPUs: {gpuList.join(', ')}
        </p>
      )}

      {showInfo && (
        <PerformancePopup onClose={() => setShowInfo(false)} />
      )}
    </div>
  );
}
```

- [ ] **Step 2: Insert PerformanceSection into both Settings variants**

Edit `desktop/src/renderer/components/SettingsPanel.tsx`. Add the import near the top:

```tsx
import PerformanceSection from './PerformanceSection';
```

Find both `<SyncSection ... />` placements (the AndroidSettings one at ~line 1984 and the DesktopSettings one at ~line 2293). Insert `<PerformanceSection />` immediately *before* each `<SyncSection ... />`. The Performance section is positioned after Appearance (which already lives above Sync) and before Sync.

- [ ] **Step 3: Smoke build**

```bash
cd desktop && npx tsc --noEmit
```
Expected: no errors.

- [ ] **Step 4: Manual UI verification on the dev box**

```bash
cd ~/youcoded-dev && bash scripts/run-dev.sh
```
Expected:
- The dev YouCoded window opens.
- Settings → Performance section visible (this is a multi-GPU laptop).
- "Detected GPUs: ..." shows two devices.
- Toggling "Prefer power saving" shows the inline restart notice.
- Toggling back hides the notice.
- Clicking the (i) icon opens PerformancePopup (created in Task 8 — deferred verification).

If the section doesn't appear: check `~/.claude/youcoded.log` for the `[performance] getGPUInfo` entries. Detection may have failed.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/PerformanceSection.tsx desktop/src/renderer/components/SettingsPanel.tsx
git commit -m "feat(performance): add Performance section to SettingsPanel"
```

---

### Task 8: Performance info popup explainer

**Files:**
- Create: `desktop/src/renderer/components/PerformancePopup.tsx`

- [ ] **Step 1: Create the popup component**

Use the existing `SettingsExplainer` infrastructure used by `REMOTE_ACCESS_EXPLAINER`. Read `RemoteButton`'s use of `SettingsExplainer` for the exact wiring; the shape below mirrors that pattern.

```tsx
// desktop/src/renderer/components/PerformancePopup.tsx
import React from 'react';
import { Scrim, OverlayPanel } from './overlays/Overlay';
import SettingsExplainer, { type ExplainerSection } from './SettingsExplainer';

const PERFORMANCE_EXPLAINER: { intro: string; sections: ExplainerSection[] } = {
  intro:
    "Your laptop has more than one graphics processor (GPU). YouCoded uses " +
    "the more powerful one by default for smoother chat, terminal scrolling, " +
    "and theme effects. If your laptop runs hot or your battery drains " +
    "faster than you'd like, you can switch to power-saving mode here — but " +
    "most performance issues actually trace back to GPU choice, so try this " +
    "before reaching for other settings.",
  sections: [
    {
      heading: 'Why YouCoded uses the discrete GPU',
      paragraphs: [
        "Integrated GPUs share system memory and thermal budget with your CPU. " +
        "When the integrated GPU works hard, your CPU slows down too — they're " +
        "physically the same chip and they share the cooling system. So a slow " +
        "GPU often shows up as both slow rendering AND a slow CPU.",
        "YouCoded also runs more concurrent visual work than most apps: each " +
        "chat session has its own terminal, themes can include animated " +
        "wallpapers and blur effects, and the chat history scrolls smoothly. " +
        "On a laptop with a discrete GPU, that work belongs on the discrete " +
        "card — it has its own memory and cooling and won't compete with " +
        "everything else your computer is doing.",
      ],
    },
    {
      heading: 'Other places to look for power savings',
      bullets: [
        { term: 'Themes', text: "Pick a theme without glassmorphism / blur, or enable Reduced Effects in Appearance — biggest GPU savings after this toggle." },
        { term: 'Close unused sessions', text: 'Each Claude session uses memory and a terminal, even when idle.' },
        { term: 'Windows', text: 'Settings → System → Display → Graphics → add YouCoded.exe → set "High performance" or "Power saving" per app. The OS setting overrides this toggle.' },
        { term: 'macOS', text: 'Apple Silicon switches automatically. On Intel Macs, System Settings → Battery → "Automatic graphics switching" controls this globally.' },
        { term: 'Linux (NVIDIA Optimus)', text: "Use prime-run or set __NV_PRIME_RENDER_OFFLOAD=1 when launching YouCoded. Chromium's switch alone doesn't reach the NVIDIA driver." },
      ],
    },
    {
      heading: 'Why a restart is needed',
      paragraphs: [
        "Graphics binding is set when YouCoded launches. Toggling at runtime " +
        "would require throwing away the current GPU context and reinitializing " +
        "every window, which Electron doesn't support. Restart is the clean path.",
      ],
    },
  ],
};

interface Props { onClose: () => void; }

export default function PerformancePopup({ onClose }: Props) {
  return (
    <>
      <Scrim layer={2} onClick={onClose} />
      <OverlayPanel layer={2} className="fixed left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 w-[480px] max-h-[80vh] overflow-y-auto p-5">
        <div className="flex items-center justify-between mb-3">
          <h2 className="text-sm font-semibold text-fg">Performance</h2>
          <button
            type="button"
            onClick={onClose}
            className="text-fg-muted hover:text-fg text-lg leading-none"
            aria-label="Close"
          >×</button>
        </div>
        <SettingsExplainer
          intro={PERFORMANCE_EXPLAINER.intro}
          sections={PERFORMANCE_EXPLAINER.sections}
        />
      </OverlayPanel>
    </>
  );
}
```

`SettingsExplainer`'s prop signature is `{ intro: string; sections: ExplainerSection[] }` — confirmed by `REMOTE_ACCESS_EXPLAINER` in `SettingsPanel.tsx`. The popup is a thin wrapper; the explainer component does the rendering work.

- [ ] **Step 2: Typecheck**

```bash
cd desktop && npx tsc --noEmit
```
Expected: no errors.

- [ ] **Step 3: Manual UI verification**

With the dev app running (from Task 7), click the `(i)` icon next to the Performance header. Expected: PerformancePopup opens with intro + 3 sections (Why YouCoded uses the discrete GPU / Other places to look for power savings / Why a restart is needed). Click the scrim or the × to close.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/renderer/components/PerformancePopup.tsx
git commit -m "feat(performance): add (i) info popup explainer"
```

---

### Task 9: End-to-end verification

This task is verification-only (no code changes). It exists so the implementer must explicitly confirm the full happy path before declaring the feature done.

- [ ] **Step 1: Verify default behavior on a clean profile**

Delete the persisted config to simulate a fresh user:

```bash
rm -f ~/.claude/youcoded-performance.json
```

Launch the dev app:

```bash
cd ~/youcoded-dev && bash scripts/run-dev.sh
```

Expected:
- Open Task Manager → GPU tab → the YouCoded Dev process is bound to the **discrete GPU** (RTX 4070), not the iGPU.
- Settings → Performance section is visible. "Prefer power saving" is OFF. No restart notice. "Detected GPUs:" lists 2+ devices.

- [ ] **Step 2: Verify the toggle and restart**

Toggle "Prefer power saving" ON. Expected:
- Inline notice appears: "⟳ Restart YouCoded to apply." with "Restart now" button.
- `~/.claude/youcoded-performance.json` now contains `{ "preferPowerSaving": true }`.

Click "Restart now". Expected:
- App relaunches.
- After relaunch, Task Manager → GPU tab → YouCoded Dev is now bound to the **integrated GPU** (Iris Xe).
- The Performance section toggle shows ON, no restart notice (saved === appliedAtLaunch again).

Toggle back OFF, click Restart. Expected: app returns to discrete GPU after relaunch.

- [ ] **Step 3: Verify single-GPU detection hides the section**

If a single-GPU dev box is available, launch the app there and confirm the Performance section is absent from Settings. Otherwise, simulate by adding a temporary `window.claude.performance.get` mock in DevTools or by stubbing `getCachedGpu()` to return `multiGpuDetected: false` — confirm the section disappears.

(Skip this step if no single-GPU box is available; rely on the unit test guarding the `multiGpuDetected` gate.)

- [ ] **Step 4: Run the full test suite**

```bash
cd desktop && npm test
```
Expected: all tests pass.

```bash
cd .. && ./gradlew :app:compileDebugKotlin
```
Expected: BUILD SUCCESSFUL.

- [ ] **Step 5: No commit needed for verification-only**

If any step in this task surfaced a bug, file it as a follow-up task and fix in a new commit before considering the feature complete.

---

## Notes for the implementer

- **Worktree discipline.** All commits in this plan land on `feat/discrete-gpu-toggle` in the worktree. Don't switch branches inside the worktree (`worktree-guard.sh` blocks it). Once the feature is fully verified and merged to `master`, remove the worktree per the workspace's working rules.
- **Annotate non-trivial code with WHY comments.** Destin (the project owner) reads code to understand changes. Inline comments explaining *why* a switch is applied or *why* the section is hidden are required, not optional.
- **Don't add features that weren't asked for.** No "test my GPU" button, no telemetry, no auto-detect-on-battery. The spec's "Non-goals" section is binding.
- **The `appliedAtLaunch` value is set ONCE at startup** by Task 2. The IPC handler (`PERFORMANCE_GET_CONFIG`) reads it via `getAppliedAtLaunch()`. Don't update it after writes — that defeats the "Restart to apply" notice.
