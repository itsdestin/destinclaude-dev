# Android xterm-in-WebView Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Android's native Termux `TerminalView` with the existing React `TerminalView` (xterm.js) running inside the WebView, consuming the `pty:raw-bytes` stream that Tier 1 already broadcasts.

**Architecture:** xterm.js becomes the only terminal renderer on both platforms. On touch platforms (Android + remote browser) xterm renders display-only — `disableStdin: true`, no `terminal.onData` registration. Existing `InputBar` minimal-mode `<textarea>` and `TerminalToolbar` continue to drive PTY input via `sendInput`. Native Termux `TerminalView` and `terminal-view` Maven dep are removed; vendored `terminal-emulator` module stays (still produces the raw-byte stream).

**Tech Stack:** React + xterm.js (WebGL/Fit/Unicode11 addons), Electron preload, WebSocket bridge, Android Compose, Termux `TerminalSession`/`TerminalEmulator` (vendored).

**Spec:** [`docs/superpowers/specs/2026-04-26-android-xterm-webview-design.md`](../specs/2026-04-26-android-xterm-webview-design.md)

**Predecessors:**
- Tier 1 spec: `docs/superpowers/specs/2026-04-24-android-terminal-data-parity-design.md` (shipped)
- Tier 1 plan: `docs/superpowers/plans/2026-04-24-android-terminal-data-parity.md` (shipped)

**Branch & worktree:** All implementation work happens in a worktree of `youcoded/` (NOT `youcoded-dev/`). Suggested name `android-xterm-webview`. The plan itself lives in the workspace repo on `master`. Per `youcoded-dev/CLAUDE.md`: do not merge to `youcoded`'s `master` without explicit user (Destin) approval after dogfooding.

---

## File Structure

### Create
| File | Responsibility |
|------|----------------|
| `youcoded/desktop/src/renderer/hooks/usePtyRawBytes.ts` | React hook: subscribes to `pty:raw-bytes:${sessionId}` push events, base64-decodes payload to `Uint8Array`, invokes callback. Malformed base64 ignored silently. |
| `youcoded/desktop/tests/use-pty-raw-bytes.test.tsx` | Unit tests for `usePtyRawBytes`: happy-path decode, malformed-base64 ignore, sessionId filtering. |
| `youcoded/desktop/tests/terminal-view-touch-mode.test.tsx` | Unit tests for `TerminalView` mount logic: `disableStdin: true` and no `terminal.onData` call on touch platforms; opposite on desktop. |

### Modify
| File | Change |
|------|--------|
| `youcoded/desktop/src/renderer/remote-shim.ts` | Add `case 'pty:raw-bytes'` to `handleMessage` (per-session dispatch). Add `ptyRawBytesForSession` to `on:` block. |
| `youcoded/desktop/src/main/preload.ts` | Add `PTY_RAW_BYTES` channel constant + no-op stub `ptyRawBytesForSession` for shape parity (desktop never broadcasts this). |
| `youcoded/desktop/src/renderer/hooks/useIpc.ts` | Add `ptyRawBytesForSession` to the `on:` block of the `Window.claude` type declaration. |
| `youcoded/desktop/src/renderer/components/TerminalView.tsx` | Conditional input source via `isTouchDevice()` from `../platform`: call `usePtyRawBytes` on touch platforms (writes `Uint8Array`), `usePtyOutput` on desktop (writes string). On touch platforms also pass `disableStdin: true` to `Terminal` constructor and skip `terminal.onData(...)` registration. Font size: 12px on touch, 14px on desktop. |
| `youcoded/desktop/tests/ipc-channels.test.ts` | Convert the `pty:raw-bytes` tombstone block to full parity: assert presence in `preload.ts`, `remote-shim.ts`, `SessionService.kt` (3 assertions, no `ipc-handlers.ts` because there's no sender on desktop). |
| `youcoded/app/src/main/kotlin/com/youcoded/app/ui/ChatScreen.kt` | Delete `applyTerminalColors`, the entire `if (currentSession != null && screenMode == ScreenMode.Terminal)` Compose render block, and the now-unused `com.termux.view.TerminalView` + `BaseTerminalViewClient` imports. Verify whether `screenMode` enum and related state still have other consumers; if not, remove. |
| `youcoded/app/build.gradle.kts` | Remove `implementation("com.github.termux.termux-app:terminal-view:v0.118.1")` block. |

### Delete
| File | Reason |
|------|--------|
| `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/TerminalViewClient.kt` | Defines `BaseTerminalViewClient`; only consumer is the deleted Compose block. The base class `com.termux.view.TerminalViewClient` it implements goes away when the Maven dep is removed. |

---

## Task 1: Wire `pty:raw-bytes` push event through preload + remote-shim, with parity test

Tier 1 added the broadcast on Android (`SessionService.kt`) but no desktop-side surfaces consume it. This task adds the consumer surfaces with a no-op stub on Electron (parity), real dispatch on remote-shim, and converts the existing test tombstone to enforce parity.

**Files:**
- Modify: `youcoded/desktop/src/main/preload.ts:25` (add channel constant) and `:281-286` (add `ptyRawBytesForSession` stub)
- Modify: `youcoded/desktop/src/renderer/remote-shim.ts` (add case in `handleMessage` and entry in `on:` block)
- Modify: `youcoded/desktop/src/renderer/hooks/useIpc.ts:46-59` (add `ptyRawBytesForSession` to `on` interface)
- Modify: `youcoded/desktop/tests/ipc-channels.test.ts:163-184` (replace tombstone with three real assertions)

- [ ] **Step 1: Update the existing parity test to expect full coverage (will fail)**

Open `youcoded/desktop/tests/ipc-channels.test.ts` and replace the existing tombstone block (currently the single-assertion describe at lines ~163-184) with:

```ts
// Regression net for pty:raw-bytes. Tier 1 introduced the Android broadcaster;
// Tier 2 (xterm-in-WebView) added the desktop-side consumer surfaces. Three
// surfaces must carry identical type strings — drift would silently break the
// xterm-on-Android renderer. ipc-handlers.ts is intentionally NOT in this list:
// pty:raw-bytes is a push event from Android via WebSocket, not a request-
// response handler, and there is no desktop sender (Electron PTY emits
// pty:output strings instead).
describe('pty:raw-bytes channel parity', () => {
  const CHANNEL = 'pty:raw-bytes';

  it('pty:raw-bytes is declared in preload.ts', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'src', 'main', 'preload.ts'), 'utf8');
    expect(src).toContain(`'${CHANNEL}'`);
  });

  it('pty:raw-bytes is referenced in remote-shim.ts', () => {
    const src = fs.readFileSync(path.join(__dirname, '..', 'src', 'renderer', 'remote-shim.ts'), 'utf8');
    expect(src).toContain(`'${CHANNEL}'`);
  });

  it('pty:raw-bytes is broadcast by SessionService.kt (Android)', () => {
    const ktPath = path.join(
      __dirname, '..', '..', 'app', 'src', 'main', 'kotlin',
      'com', 'youcoded', 'app', 'runtime', 'SessionService.kt',
    );
    const src = fs.readFileSync(ktPath, 'utf8');
    expect(src).toContain(`"${CHANNEL}"`);
  });
});
```

- [ ] **Step 2: Run the parity test to confirm two assertions fail**

```bash
cd youcoded/desktop && npx vitest run tests/ipc-channels.test.ts -t "pty:raw-bytes channel parity"
```

Expected: 3 tests, 2 fail (preload.ts + remote-shim.ts assertions), 1 passes (SessionService.kt).

- [ ] **Step 3: Add `PTY_RAW_BYTES` constant and stub to preload.ts**

In `youcoded/desktop/src/main/preload.ts`, add to the `IPC` constants block (alongside `PTY_OUTPUT: 'pty:output'` at line 25):

```ts
PTY_RAW_BYTES: 'pty:raw-bytes',
```

Then add a no-op stub in the `on:` block (immediately after the `ptyOutputForSession` definition around line 286):

```ts
// Shape parity with remote-shim — desktop never fires this push event
// (Electron PTY emits pty:output strings instead). The stub keeps the
// window.claude.on shape symmetric so React components don't need to
// platform-branch on the API's existence.
ptyRawBytesForSession: (_sessionId: string, _cb: (data: string) => void) => {
  return () => {};
},
```

- [ ] **Step 4: Add `case 'pty:raw-bytes'` to remote-shim's `handleMessage`**

In `youcoded/desktop/src/renderer/remote-shim.ts`, locate the `handleMessage` switch (starts around line 148 with `case 'pty:output'`). Add a new case immediately after `pty:output`:

```ts
case 'pty:raw-bytes':
  // Per-session dispatch only — no global consumer (xterm is per-session).
  // Payload data is base64-encoded raw PTY bytes from Android's
  // RawByteListener (Tier 1). usePtyRawBytes decodes to Uint8Array.
  dispatchEvent(`pty:raw-bytes:${payload.sessionId}`, payload.data);
  break;
```

- [ ] **Step 5: Add `ptyRawBytesForSession` to remote-shim's `on:` block**

In the same file, locate the `on:` block (starts around line 599). Add immediately after `ptyOutputForSession`:

```ts
ptyRawBytesForSession: (sessionId: string, cb: (data: string) => void) => {
  const channel = `pty:raw-bytes:${sessionId}`;
  const handler = addListener(channel, cb);
  return () => removeListener(channel, handler);
},
```

- [ ] **Step 6: Add the type to the Window interface in useIpc.ts**

In `youcoded/desktop/src/renderer/hooks/useIpc.ts`, locate the `on:` block in the Window claude type declaration (around line 46-59). Add this line after the existing `chatHydrate?` entry:

```ts
ptyRawBytesForSession?: (sessionId: string, cb: (data: string) => void) => () => void;
```

The `?` is intentional — desktop's preload exposes a stub but TypeScript should treat any consumer's existence-check as well-formed.

- [ ] **Step 7: Re-run the parity test, verify all three pass**

```bash
cd youcoded/desktop && npx vitest run tests/ipc-channels.test.ts -t "pty:raw-bytes channel parity"
```

Expected: 3 tests, all pass.

- [ ] **Step 8: Run the full test suite to confirm no regressions**

```bash
cd youcoded/desktop && npm test
```

Expected: all tests pass (modulo any pre-existing failures unrelated to this change).

- [ ] **Step 9: Commit**

```bash
git add youcoded/desktop/src/main/preload.ts \
        youcoded/desktop/src/renderer/remote-shim.ts \
        youcoded/desktop/src/renderer/hooks/useIpc.ts \
        youcoded/desktop/tests/ipc-channels.test.ts
git commit -m "feat(ipc): wire pty:raw-bytes push event through desktop surfaces"
```

---

## Task 2: Create `usePtyRawBytes` hook (TDD)

A React hook that subscribes to the new `pty:raw-bytes:${sessionId}` channel exposed in Task 1. Decodes base64 to `Uint8Array`. Mirrors the structure of the existing `usePtyOutput` (`youcoded/desktop/src/renderer/hooks/useIpc.ts:183`).

**Files:**
- Create: `youcoded/desktop/src/renderer/hooks/usePtyRawBytes.ts`
- Create: `youcoded/desktop/tests/use-pty-raw-bytes.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `youcoded/desktop/tests/use-pty-raw-bytes.test.tsx`:

```tsx
// @vitest-environment jsdom
import React from 'react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, cleanup, act } from '@testing-library/react';

import { usePtyRawBytes } from '../src/renderer/hooks/usePtyRawBytes';

// Helper: install a fake window.claude that captures the registered handler so
// tests can manually fire incoming messages.
function installClaudeMock(): { fire: (sessionId: string, base64: string) => void } {
  const handlers = new Map<string, (data: string) => void>();
  (globalThis as any).window.claude = {
    on: {
      ptyRawBytesForSession: (sessionId: string, cb: (data: string) => void) => {
        const ch = `pty:raw-bytes:${sessionId}`;
        handlers.set(ch, cb);
        return () => handlers.delete(ch);
      },
    },
  };
  return {
    fire: (sessionId, base64) => {
      const cb = handlers.get(`pty:raw-bytes:${sessionId}`);
      if (cb) cb(base64);
    },
  };
}

function HookProbe({ sessionId, onData }: { sessionId: string | null; onData: (b: Uint8Array) => void }) {
  usePtyRawBytes(sessionId, onData);
  return null;
}

describe('usePtyRawBytes', () => {
  beforeEach(() => {
    (globalThis as any).window = (globalThis as any).window ?? {};
  });
  afterEach(() => {
    cleanup();
    delete (globalThis as any).window.claude;
  });

  it('decodes base64 payload to Uint8Array and invokes callback', () => {
    const { fire } = installClaudeMock();
    const onData = vi.fn();
    render(<HookProbe sessionId="sess-1" onData={onData} />);

    // "Hello" in base64
    act(() => {
      fire('sess-1', 'SGVsbG8=');
    });

    expect(onData).toHaveBeenCalledTimes(1);
    const bytes = onData.mock.calls[0][0] as Uint8Array;
    expect(Array.from(bytes)).toEqual([0x48, 0x65, 0x6c, 0x6c, 0x6f]);
  });

  it('round-trips high-bit ANSI bytes (e.g. ESC sequences)', () => {
    const { fire } = installClaudeMock();
    const onData = vi.fn();
    render(<HookProbe sessionId="sess-1" onData={onData} />);

    // ESC [ 3 1 m  +  UTF-8 box-drawing  +  edge bytes (0x00, 0xff, 0x7f, 0x80)
    const original = new Uint8Array([
      0x1b, 0x5b, 0x33, 0x31, 0x6d,
      0xe2, 0x94, 0x80,
      0x00, 0xff, 0x7f, 0x80,
    ]);
    const base64 = btoa(String.fromCharCode(...original));

    act(() => {
      fire('sess-1', base64);
    });

    expect(onData).toHaveBeenCalledTimes(1);
    expect(Array.from(onData.mock.calls[0][0] as Uint8Array)).toEqual(Array.from(original));
  });

  it('silently ignores malformed base64 (does not throw, does not invoke callback)', () => {
    const { fire } = installClaudeMock();
    const onData = vi.fn();
    render(<HookProbe sessionId="sess-1" onData={onData} />);

    // '!!!' is not valid base64
    act(() => {
      fire('sess-1', '!!!');
    });

    expect(onData).not.toHaveBeenCalled();
  });

  it('does nothing when sessionId is null', () => {
    installClaudeMock();
    const onData = vi.fn();
    // Should not throw on mount
    render(<HookProbe sessionId={null} onData={onData} />);
    expect(onData).not.toHaveBeenCalled();
  });

  it('uses the latest callback after re-render (via cbRef pattern)', () => {
    const { fire } = installClaudeMock();
    const first = vi.fn();
    const second = vi.fn();

    const { rerender } = render(<HookProbe sessionId="sess-1" onData={first} />);

    rerender(<HookProbe sessionId="sess-1" onData={second} />);

    act(() => {
      fire('sess-1', 'SGk='); // "Hi"
    });

    expect(first).not.toHaveBeenCalled();
    expect(second).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run the test to confirm it fails (file doesn't exist)**

```bash
cd youcoded/desktop && npx vitest run tests/use-pty-raw-bytes.test.tsx
```

Expected: FAIL with "Failed to load url ../src/renderer/hooks/usePtyRawBytes" (or similar import error).

- [ ] **Step 3: Create the hook**

Create `youcoded/desktop/src/renderer/hooks/usePtyRawBytes.ts`:

```ts
import { useEffect, useRef } from 'react';

/**
 * Subscribe to the per-session pty:raw-bytes push event (Tier 2 of
 * android-terminal-data-parity). Payload is base64-encoded raw PTY bytes
 * emitted by Android's RawByteListener; this hook decodes to Uint8Array.
 *
 * On desktop (Electron preload), the underlying ptyRawBytesForSession is a
 * no-op stub — the hook still mounts safely but its callback will never fire
 * because Electron PTY emits pty:output strings instead.
 *
 * Malformed base64 is silently ignored to avoid crashing the renderer if
 * the bridge ever emits a corrupt frame; the byte stream resumes on the
 * next valid frame.
 */
export function usePtyRawBytes(
  sessionId: string | null,
  onData: (data: Uint8Array) => void,
): void {
  // cbRef pattern matches usePtyOutput — keeps the effect from re-running
  // every render just because the consumer's callback closure changed.
  const cbRef = useRef(onData);
  cbRef.current = onData;

  useEffect(() => {
    if (!sessionId) return;

    const claude = (window as any).claude;
    if (!claude?.on?.ptyRawBytesForSession) return;

    return claude.on.ptyRawBytesForSession(sessionId, (base64: string) => {
      try {
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
          bytes[i] = binary.charCodeAt(i);
        }
        cbRef.current(bytes);
      } catch {
        // Malformed base64 — drop this frame; PTY recovers on next valid frame.
      }
    });
  }, [sessionId]);
}
```

- [ ] **Step 4: Run the test to confirm all five cases pass**

```bash
cd youcoded/desktop && npx vitest run tests/use-pty-raw-bytes.test.tsx
```

Expected: 5 passing tests.

- [ ] **Step 5: Run the full test suite to confirm no regressions**

```bash
cd youcoded/desktop && npm test
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add youcoded/desktop/src/renderer/hooks/usePtyRawBytes.ts \
        youcoded/desktop/tests/use-pty-raw-bytes.test.tsx
git commit -m "feat(renderer): add usePtyRawBytes hook for Android xterm consumer"
```

---

## Task 3: TerminalView — touch-platform handling (TDD)

`TerminalView.tsx` becomes the only renderer for both platforms. On touch platforms (Android, remote browser): `disableStdin: true`, no `terminal.onData` call, font size 12, and consume `pty:raw-bytes` instead of `pty:output`. On desktop: existing behavior unchanged.

The mount logic is currently a single ~280-line `useEffect`. We do NOT refactor it — we add three small conditional branches gated on `isTouchDevice()` from `youcoded/desktop/src/renderer/platform.ts`, and swap the data-source hook call. Kept inline; no new helper.

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/TerminalView.tsx:80-100` (Terminal constructor — add `disableStdin`), `:247-250` (onData registration — wrap in `!isTouch`), `:298-300` (data-source hook call — branch on touch)
- Create: `youcoded/desktop/tests/terminal-view-touch-mode.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `youcoded/desktop/tests/terminal-view-touch-mode.test.tsx`:

```tsx
// @vitest-environment jsdom
import React from 'react';
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, cleanup } from '@testing-library/react';

// Capture Terminal constructor args + method calls. Mocked before TerminalView import.
const terminalCtorArgs: any[] = [];
const onDataSpy = vi.fn();

vi.mock('@xterm/xterm', () => {
  return {
    Terminal: vi.fn().mockImplementation((opts: any) => {
      terminalCtorArgs.push(opts);
      return {
        loadAddon: vi.fn(),
        open: vi.fn(),
        unicode: { activeVersion: '11' },
        attachCustomKeyEventHandler: vi.fn(),
        onData: onDataSpy,
        write: vi.fn(),
        refresh: vi.fn(),
        focus: vi.fn(),
        blur: vi.fn(),
        dispose: vi.fn(),
        hasSelection: vi.fn().mockReturnValue(false),
        getSelection: vi.fn().mockReturnValue(''),
        paste: vi.fn(),
        options: {},
        rows: 24,
      };
    }),
  };
});

vi.mock('@xterm/addon-fit', () => ({
  FitAddon: vi.fn().mockImplementation(() => ({
    fit: vi.fn(),
    proposeDimensions: vi.fn().mockReturnValue({ cols: 80, rows: 24 }),
  })),
}));

vi.mock('@xterm/addon-unicode11', () => ({
  Unicode11Addon: vi.fn().mockImplementation(() => ({})),
}));

vi.mock('@xterm/addon-webgl', () => ({
  WebglAddon: vi.fn().mockImplementation(() => ({
    onContextLoss: vi.fn(),
    dispose: vi.fn(),
  })),
}));

vi.mock('@xterm/xterm/css/xterm.css', () => ({}));

// Mock the platform helper. Each test sets the return value before render.
vi.mock('../src/renderer/platform', () => ({
  isAndroid: vi.fn().mockReturnValue(false),
  isTouchDevice: vi.fn().mockReturnValue(false),
  getPlatform: vi.fn().mockReturnValue('electron'),
}));

// Avoid pulling theme context — the component reads CSS vars from
// document.documentElement; jsdom returns empty strings, the component falls
// back to its defaults.
vi.mock('../src/renderer/state/theme-context', () => ({
  useTheme: () => ({ activeTheme: null, reducedEffects: false }),
}));

// Stub the IPC + registry surfaces TerminalView calls.
vi.mock('../src/renderer/hooks/terminal-registry', () => ({
  registerTerminal: vi.fn(),
  unregisterTerminal: vi.fn(),
  notifyBufferReady: vi.fn(),
}));

vi.mock('../src/renderer/hooks/useIpc', () => ({
  usePtyOutput: vi.fn(),
}));

vi.mock('../src/renderer/hooks/usePtyRawBytes', () => ({
  usePtyRawBytes: vi.fn(),
}));

// Now safe to import — all dependencies are mocked.
import TerminalView from '../src/renderer/components/TerminalView';
import { Terminal } from '@xterm/xterm';
import * as platform from '../src/renderer/platform';
import { usePtyOutput } from '../src/renderer/hooks/useIpc';
import { usePtyRawBytes } from '../src/renderer/hooks/usePtyRawBytes';

beforeEach(() => {
  terminalCtorArgs.length = 0;
  onDataSpy.mockReset();
  vi.mocked(usePtyOutput).mockReset();
  vi.mocked(usePtyRawBytes).mockReset();
  // Stub session.signalReady to no-op (it's called on mount).
  (globalThis as any).window.claude = {
    session: {
      signalReady: vi.fn(),
      sendInput: vi.fn(),
      resize: vi.fn(),
    },
  };
});

afterEach(() => {
  cleanup();
  delete (globalThis as any).window.claude;
});

describe('TerminalView mount logic — touch platform', () => {
  beforeEach(() => {
    vi.mocked(platform.isTouchDevice).mockReturnValue(true);
  });

  it('passes disableStdin: true to the Terminal constructor', () => {
    render(<TerminalView sessionId="s1" visible={true} />);
    expect(terminalCtorArgs[0]).toMatchObject({ disableStdin: true });
  });

  it('does not register a terminal.onData listener', () => {
    render(<TerminalView sessionId="s1" visible={true} />);
    expect(onDataSpy).not.toHaveBeenCalled();
  });

  it('uses 12px font size', () => {
    render(<TerminalView sessionId="s1" visible={true} />);
    expect(terminalCtorArgs[0]).toMatchObject({ fontSize: 12 });
  });

  // Implementation calls BOTH hooks every render (rules-of-hooks: stable hook
  // order). On touch, the raw-bytes hook gets the real sessionId and the
  // string hook gets null (early-returns inside the hook). Asserting which
  // hook got the real sessionId is the meaningful check, not which got called.
  it('passes sessionId to usePtyRawBytes and null to usePtyOutput', () => {
    render(<TerminalView sessionId="s1" visible={true} />);
    expect(usePtyRawBytes).toHaveBeenCalledWith('s1', expect.any(Function));
    expect(usePtyOutput).toHaveBeenCalledWith(null, expect.any(Function));
  });
});

describe('TerminalView mount logic — desktop', () => {
  beforeEach(() => {
    vi.mocked(platform.isTouchDevice).mockReturnValue(false);
  });

  it('does not pass disableStdin (or passes false)', () => {
    render(<TerminalView sessionId="s1" visible={true} />);
    const opts = terminalCtorArgs[0];
    expect(opts.disableStdin === undefined || opts.disableStdin === false).toBe(true);
  });

  it('registers a terminal.onData listener', () => {
    render(<TerminalView sessionId="s1" visible={true} />);
    expect(onDataSpy).toHaveBeenCalled();
  });

  it('uses 14px font size', () => {
    render(<TerminalView sessionId="s1" visible={true} />);
    expect(terminalCtorArgs[0]).toMatchObject({ fontSize: 14 });
  });

  it('passes sessionId to usePtyOutput and null to usePtyRawBytes', () => {
    render(<TerminalView sessionId="s1" visible={true} />);
    expect(usePtyOutput).toHaveBeenCalledWith('s1', expect.any(Function));
    expect(usePtyRawBytes).toHaveBeenCalledWith(null, expect.any(Function));
  });
});
```

- [ ] **Step 2: Run the test to confirm all eight cases fail**

```bash
cd youcoded/desktop && npx vitest run tests/terminal-view-touch-mode.test.tsx
```

Expected: FAIL — touch tests fail because TerminalView currently always passes `fontSize: 14`, never sets `disableStdin`, always calls `onData`, always uses `usePtyOutput`. Desktop tests may incidentally pass (they assert current behavior).

- [ ] **Step 3: Add the platform import to TerminalView**

In `youcoded/desktop/src/renderer/components/TerminalView.tsx`, near the top with the other imports (after the `useTheme` import on line 9), add:

```ts
import { isTouchDevice } from '../platform';
import { usePtyRawBytes } from '../hooks/usePtyRawBytes';
```

- [ ] **Step 4: Branch the Terminal constructor opts on `isTouchDevice()`**

Locate the Terminal construction (currently around line 83-93):

```ts
const terminal = new Terminal({
  allowProposedApi: true,
  cursorBlink: true,
  cursorInactiveStyle: 'none',
  fontSize: 14,
  fontFamily: TERMINAL_FONT,
  theme: getXtermTheme(false),
});
```

Replace with:

```ts
// Touch platforms (Android, remote browser) render xterm display-only:
// typing flows through the InputBar minimal-mode <textarea> instead of
// xterm's hidden textarea (which would summon the soft keyboard and
// expose the historical xterm.js mobile IME issues). disableStdin
// suppresses xterm's input handling entirely.
const touch = isTouchDevice();
const terminal = new Terminal({
  allowProposedApi: true,
  cursorBlink: true,
  cursorInactiveStyle: 'none',
  fontSize: touch ? 12 : 14,
  fontFamily: TERMINAL_FONT,
  theme: getXtermTheme(false),
  disableStdin: touch,
});
```

- [ ] **Step 5: Skip the `terminal.onData` registration on touch platforms**

Locate the `terminal.onData(...)` block (currently around lines 241-250):

```ts
// Send user keyboard input to PTY — only when terminal is the active view.
// xterm.js registers a paste listener on its container element that fires
// even when the terminal is hidden/collapsed. Without this gate, pasting
// into the chat InputBar can also trigger xterm's bracketed paste handler,
// sending the raw multi-line text (wrapped in ESC[200~/ESC[201~) to the
// PTY alongside the chat InputBar's sanitized single-line send.
terminal.onData((data) => {
  if (!visibleRef.current) return;
  window.claude.session.sendInput(sessionId, data);
});
```

Wrap in a `!touch` check:

```ts
// Send user keyboard input to PTY — only when terminal is the active view.
// xterm.js registers a paste listener on its container element that fires
// even when the terminal is hidden/collapsed. Without this gate, pasting
// into the chat InputBar can also trigger xterm's bracketed paste handler,
// sending the raw multi-line text (wrapped in ESC[200~/ESC[201~) to the
// PTY alongside the chat InputBar's sanitized single-line send.
//
// Skipped on touch platforms — disableStdin already silences xterm's
// keyboard input, but the paste listener is registered separately, so we
// also skip onData wiring to make sure no path can deliver text from
// xterm's hidden textarea to the PTY (the InputBar minimal-mode textarea
// is the canonical input on touch).
if (!touch) {
  terminal.onData((data) => {
    if (!visibleRef.current) return;
    window.claude.session.sendInput(sessionId, data);
  });
}
```

- [ ] **Step 6: Branch the data-source hook call on `isTouchDevice()`**

Locate the existing data-source call (around line 297-300):

```ts
// Write PTY output to terminal; notify registry when buffer is updated
usePtyOutput(sessionId, (data) => {
  terminalRef.current?.write(data, () => notifyBufferReady(sessionId));
});
```

Replace with conditional dual-call. React's rules-of-hooks require stable hook order on every render, but `isTouchDevice()` returns the same value across the lifetime of the renderer process — so the conditional is safe. We use a stable boolean in a let-binding so the rules-of-hooks linter doesn't complain about the call site.

```ts
// Write PTY output to terminal; notify registry when buffer is updated.
// Touch platforms (Android, remote browser) consume pty:raw-bytes (Uint8Array)
// from the WebSocket bridge — Tier 2 of android-terminal-data-parity. Desktop
// continues to consume pty:output (string) from node-pty's UTF-8-decoded stream.
// isTouchDevice() is a stable platform constant, so calling different hooks
// based on it does not violate React's rules-of-hooks (the hook order is
// stable for the lifetime of the renderer).
const useRawBytes = isTouchDevice();
usePtyOutput(useRawBytes ? null : sessionId, (data) => {
  terminalRef.current?.write(data, () => notifyBufferReady(sessionId));
});
usePtyRawBytes(useRawBytes ? sessionId : null, (data) => {
  terminalRef.current?.write(data, () => notifyBufferReady(sessionId));
});
```

(Note: passing `null` as `sessionId` is the documented "subscribe to nothing" path — both hooks early-return on null. This keeps the hook order constant on every render across both platforms while only one hook actually subscribes.)

- [ ] **Step 7: Run the touch-mode test to verify all eight cases pass**

```bash
cd youcoded/desktop && npx vitest run tests/terminal-view-touch-mode.test.tsx
```

Expected: 8 passing tests.

- [ ] **Step 8: Run the full test suite to confirm no regressions**

```bash
cd youcoded/desktop && npm test
```

Expected: all tests pass.

- [ ] **Step 9: Run the desktop build to confirm no TypeScript errors**

```bash
cd youcoded/desktop && npm run build
```

Expected: build succeeds.

- [ ] **Step 10: Commit**

```bash
git add youcoded/desktop/src/renderer/components/TerminalView.tsx \
        youcoded/desktop/tests/terminal-view-touch-mode.test.tsx
git commit -m "feat(terminal): xterm display-only on touch, consume pty:raw-bytes"
```

---

## Task 4: Build Web UI bundle and rebuild Android APK with the new renderer

After Task 3, the React side is ready but the Android APK still ships the old bundle. We need to build the web UI bundle and the APK so the next dogfood install includes the changes. (We do NOT delete the native TerminalView yet — that's Task 5. This intermediate APK has BOTH renderers active so we can verify the React-side xterm now receives `pty:raw-bytes` on Android.)

**Files:** none changed — this task only runs build commands.

- [ ] **Step 1: Build the web UI bundle**

```bash
cd youcoded && bash scripts/build-web-ui.sh
```

Expected: succeeds, copies `desktop/dist/renderer/` into `app/src/main/assets/web/`.

- [ ] **Step 2: Build the debug APK**

```bash
cd youcoded && ./gradlew assembleDebug
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Smoke-check via ADB (intermediate state — both renderers active)**

```bash
cd youcoded && adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Then on the device: open a session, switch to terminal view. The native terminal renders behind the WebView as before; xterm in the WebView should now ALSO render (likely opaque background hiding the native one underneath). Confirm by attaching Chrome DevTools (`chrome://inspect`) to the WebView and running:

```js
window.__terminalRegistry?.list?.() ?? Object.keys(window.__terminalRegistry ?? {})
```

The xterm Terminal instance for the active session should be present and the buffer should contain content (Chrome DevTools → Elements → find the `.xterm-screen` and verify rendered cells).

This smoke is informational — pass/fail is not a blocker. The point is to confirm `pty:raw-bytes` is reaching xterm before we delete the native fallback in Task 5.

- [ ] **Step 4: No commit (build artifacts only)**

Build outputs are gitignored. Skip to Task 5.

---

## Task 5: Delete native TerminalView from Android (Compose + Gradle)

Remove the native `TerminalView` Compose render block, the `applyTerminalColors` helper, the `BaseTerminalViewClient` file, and the `terminal-view:v0.118.1` Maven dependency. After this task, xterm is the sole terminal renderer on Android.

**Files:**
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/ui/ChatScreen.kt:1-138` (delete imports + helper + Compose block; verify whether `screenMode` enum still has consumers)
- Delete: `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/TerminalViewClient.kt`
- Modify: `youcoded/app/build.gradle.kts:116-121` (remove the `terminal-view` block)

- [ ] **Step 1: Delete the native TerminalView Compose block + helper from ChatScreen.kt**

In `youcoded/app/src/main/kotlin/com/youcoded/app/ui/ChatScreen.kt`:

(a) Remove these imports (lines 12 and 14):

```kotlin
import com.youcoded.app.runtime.BaseTerminalViewClient
import com.termux.view.TerminalView
```

(b) Delete the `applyTerminalColors` helper (lines 16-22).

(c) Inside the `Box(...)` body, delete the entire `if (currentSession != null && screenMode == ScreenMode.Terminal) { ... }` block (currently lines 73-129 inclusive — the `// Layer 1 (behind): Native terminal` comment and everything down to and including the closing `} // key(currentSessionId)` and the closing brace of the `if`).

The `Box` body should reduce to just the layout-comment and the `WebViewHost` call:

```kotlin
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF111111))
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        // xterm in the WebView is now the sole terminal renderer (Tier 2 of
        // android-terminal-data-parity). The native Termux TerminalView that
        // used to live here has been removed; xterm consumes pty:raw-bytes.
        // Security: pass bridge auth token so WebView can authenticate with LocalBridgeServer
        WebViewHost(
            modifier = Modifier.fillMaxSize(),
            bridgeAuthToken = service.bridgeServer.authToken
        )
    }
```

(d) Verify whether `screenMode`, `ScreenMode`, `viewModeRequest` collector, `headerHeightPx`/`bottomBarHeightPx`, and the `service.layoutInsets` collector still have other consumers. Search:

```bash
cd youcoded && grep -rn "screenMode\|ScreenMode\|viewModeRequest\|layoutInsets" app/src/main/kotlin/
```

For each match: if its only consumer was the deleted Compose block, also remove the related state/collector from `ChatScreen.kt`. If it's still referenced elsewhere (e.g. `service.viewModeRequest` is also used to keep React in sync), leave it intact. **Document each decision in a comment in the commit message.**

- [ ] **Step 2: Delete TerminalViewClient.kt**

```bash
rm youcoded/app/src/main/kotlin/com/youcoded/app/runtime/TerminalViewClient.kt
```

Verify no remaining references:

```bash
cd youcoded && grep -rn "BaseTerminalViewClient\|TerminalViewClient" app/src/
```

Expected: no matches. (`TerminalViewClient` from Termux's library is also gone after Task 5 step 3.)

- [ ] **Step 3: Remove `terminal-view` Maven dep from build.gradle.kts**

In `youcoded/app/build.gradle.kts`, locate the dependency block around lines 116-121:

```kotlin
    // terminal-view stays on Maven — we don't patch the View layer.
    // Exclude terminal-emulator from its transitive deps so Gradle uses
    // our vendored version exclusively.
    implementation("com.github.termux.termux-app:terminal-view:v0.118.1") {
        exclude(group = "com.github.termux.termux-app", module = "terminal-emulator")
    }
```

Delete this entire block (the comment and the implementation call).

Also update the comment block immediately above it (lines 106-114) to reflect that we no longer use Termux's view layer at all. Replace lines 106-114 with:

```kotlin
    // Termux terminal emulator (vendored) — runs the PTY session and emits
    // raw bytes via the patched RawByteListener. Tier 2 (xterm-in-WebView)
    // moved rendering to xterm.js in the React WebView; the native Termux
    // terminal-view library is no longer referenced. Vendored module stays
    // because it owns the PTY fork + JNI waitpid loop + RawByteListener.
    //
    // LICENSE NOTE: terminal-emulator-vendored is GPLv3 (Termux's original
    // license is preserved in the vendor drop). Linking it into the Android
    // APK is why the Android application is distributed under GPLv3 (see
    // app/LICENSE). The desktop Electron app has no such dependency and
    // remains MIT-licensed.
    implementation(project(":terminal-emulator-vendored"))
```

- [ ] **Step 4: Build the debug APK to confirm the deletions compile**

```bash
cd youcoded && ./gradlew assembleDebug
```

Expected: BUILD SUCCESSFUL. If a Kotlin compile error mentions `BaseTerminalViewClient`, `TerminalView`, `TerminalViewClient`, or `applyTerminalColors`, return to step 1 and find the missed reference.

- [ ] **Step 5: Run Android unit tests**

```bash
cd youcoded && ./gradlew test
```

Expected: BUILD SUCCESSFUL with all tests passing.

- [ ] **Step 6: Build the web UI bundle (in case anything in renderer changed since Task 4)**

```bash
cd youcoded && bash scripts/build-web-ui.sh
```

Expected: succeeds.

- [ ] **Step 7: Reinstall the APK and smoke-check (xterm is now the only renderer)**

```bash
cd youcoded && adb install -r app/build/outputs/apk/debug/app-debug.apk
```

On the device, open a session and switch to terminal view. xterm should be the only thing rendering — confirm by:
1. Tapping on the terminal: soft keyboard does NOT appear (xterm `disableStdin: true` plus no native TerminalView to receive touches)
2. Typing in the InputBar `<textarea>` and hitting Enter: text reaches Claude
3. Tapping `Esc` / `Tab` / `←` / `→` / `↑` / `↓` toolbar buttons: all work
4. Output from Claude appears in xterm with correct ANSI colors and box-drawing characters
5. Auto-scroll-to-bottom fires when new output arrives

If any of (1)-(5) fail, do NOT commit — return to the relevant earlier task.

- [ ] **Step 8: Commit**

```bash
git add youcoded/app/src/main/kotlin/com/youcoded/app/ui/ChatScreen.kt \
        youcoded/app/build.gradle.kts
git rm youcoded/app/src/main/kotlin/com/youcoded/app/runtime/TerminalViewClient.kt
git commit -m "feat(android): remove native TerminalView, xterm is sole renderer

xterm in the React WebView consumes pty:raw-bytes (Tier 1) directly,
making the native Termux TerminalView (and the WebView-overlays-it
touch bug) obsolete. Removes:
- ChatScreen.kt: native TerminalView Compose block + applyTerminalColors
- TerminalViewClient.kt: BaseTerminalViewClient (only consumer was the
  deleted Compose block)
- app/build.gradle.kts: com.github.termux.termux-app:terminal-view dep
  (vendored terminal-emulator stays — still produces raw bytes)
"
```

---

## Task 6: Dogfood verification & PITFALLS update

Manual dogfood pass against the revert criteria from the spec, then update the workspace docs to reflect the new architecture.

**Files:**
- Modify: `youcoded-dev/docs/PITFALLS.md` (replace the "Vendored Termux terminal-emulator" section opening so it reflects xterm consumes the stream instead of the native TerminalView)
- Modify: `youcoded-dev/docs/android-runtime.md` (Key Files table — remove deleted entries, add xterm note)
- Modify: `youcoded/docs/cc-dependencies.md` (no new CC coupling, but document that the renderer is now shared across both platforms — relevant for the review-cc-changes agent)

- [ ] **Step 1: Dogfood pass against the revert criteria**

Run a normal Claude session for at least one significant turn (a multi-step task that involves spinner, tool use, and substantial output). Watch for:

| Criterion | Pass | Fail | Notes |
|-----------|------|------|-------|
| No visible frame drops during Ink redraws | | | |
| Auto-scroll-to-bottom fires on new output | | | |
| No noticeable PTY-emit → on-screen latency | | | |
| InputBar typing + Enter still reaches Claude | | | |
| TerminalToolbar Esc/Tab/Ctrl/←/→ all work | | | |
| TerminalScrollButtons ↑/↓ scroll xterm | | | |
| Chat/terminal toggle still switches view | | | |

If ANY criterion fails: do NOT proceed. Stop and discuss with the user (Destin) — likely path is `git revert` of the Task 5 commit (xterm intermediate state from Task 4 stays).

If all pass: proceed.

- [ ] **Step 2: Update PITFALLS.md "Vendored Termux terminal-emulator" section**

In `youcoded-dev/docs/PITFALLS.md`, locate the section starting `## Vendored Termux terminal-emulator`. Update the opening paragraph to:

```markdown
## Vendored Termux terminal-emulator

- **`terminal-emulator-vendored/` is pinned to Termux v0.118.1 with a single documented patch** (a `RawByteListener` hook on `TerminalEmulator.append()`). `VENDORED.md` in that directory is the source of truth. Never edit files in this module outside the documented patch — if a new concern needs more, revisit the decision to vendor.
- **The vendored emulator is now headless** as of Tier 2 (xterm-in-WebView). The native Termux `TerminalView` UI layer was removed from `ChatScreen.kt` along with the `terminal-view` Maven dep. `TerminalSession` still owns the PTY fork + JNI waitpid loop + `TerminalEmulator.append()`, and `RawByteListener` is the single tap point that feeds bytes to React xterm via `pty:raw-bytes`. Don't reintroduce a native render path — the vendored module exists solely to produce the byte stream now.
```

(Keep all the other bullets in the section as-is.)

- [ ] **Step 3: Update android-runtime.md Key Files table**

In `youcoded-dev/docs/android-runtime.md`, locate the `## Key Files` table at the bottom. Remove these rows (they referenced the deleted code path indirectly — xterm is now the canonical renderer and lives in React, not Kotlin). Update the `WebViewHost.kt` row description if it mentions the native overlay.

Specifically: in the row `| `app/.../ui/WebViewHost.kt` | Hosts React UI in WebView, loads bundled web assets |`, no change needed — the description is still accurate.

If `BaseTerminalViewClient.kt` or `TerminalViewClient.kt` are referenced anywhere in the doc body (not just the table), remove those mentions.

Add a paragraph immediately above the `## Key Files` heading:

```markdown
## Terminal rendering (Tier 2)

As of Tier 2 of the android-terminal-data-parity arc, terminal rendering on
Android happens in xterm.js inside the WebView, not in a native Termux
`TerminalView`. The vendored `terminal-emulator` module is now headless: it
runs the PTY and feeds raw bytes via `RawByteListener` to React's `TerminalView`
component (`youcoded/desktop/src/renderer/components/TerminalView.tsx`), which
consumes `pty:raw-bytes` push events through `usePtyRawBytes`. xterm is set
to `disableStdin: true` on touch platforms — typing flows through the
`InputBar` minimal-mode `<textarea>` instead.
```

- [ ] **Step 4: Update cc-dependencies.md (informational note)**

In `youcoded/docs/cc-dependencies.md`, find the existing "Android attention classifier" entry from Tier 1 and update its parenthetical to reflect that the buffer source is now xterm in the WebView, not the native Termux emulator. Specifically, the screen-text reader on Android still reads via `PtyBridge.readScreenText()` (headless emulator), but xterm renders the same content for users.

If there's already a clear sentence in that entry describing what reads what, make sure it stays accurate. If unsure, leave the entry alone — don't rewrite for the sake of rewriting.

- [ ] **Step 5: Run the audit to catch any other doc drift**

```bash
cd youcoded-dev && bash -c '/audit android'
```

Note: this command is run via Claude Code's slash-command interpreter. If running outside Claude Code, skip this step — the user will run `/audit` separately.

- [ ] **Step 6: Commit doc updates**

```bash
cd youcoded-dev && git add docs/PITFALLS.md docs/android-runtime.md
git commit -m "docs: xterm is sole Android terminal renderer (Tier 2)"
```

```bash
cd youcoded && git add docs/cc-dependencies.md
git commit -m "docs(cc-deps): note xterm consumes raw bytes on Android (Tier 2)"
```

(Two repos, two commits — `youcoded-dev` for workspace-level docs, `youcoded` for the in-repo CC dependency map.)

---

## Final review (before merge to master)

After Task 6 dogfood passes, surface back to the user (Destin) for explicit merge approval. Per the spec: **"Merge to master requires explicit user (Destin) sign-off after dogfooding. Not automatic."**

Suggested handoff message for the controller:

> Tier 2 implementation complete on branch `android-xterm-webview`. All automated tests pass; dogfood pass against the revert criteria succeeded. Ready to merge to `master` on your approval. Revert path is `git revert <merge-commit-sha>` if anything regresses post-merge.
