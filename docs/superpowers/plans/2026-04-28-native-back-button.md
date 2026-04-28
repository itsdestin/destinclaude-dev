# Native Android Back Button — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Android's hardware back button to dismiss overlays and full-screen destinations LIFO via the existing React `useEscClose` stack, with no Claude-interrupt overload at chat root.

**Architecture:** Reuse the existing `EscStore` LIFO stack. Add an imperative entry point `useDismissTop()` so the Android-back bridge can pop the top without synthesizing a keyboard event. `MainActivity.OnBackPressedCallback.isEnabled` mirrors `useEscStackEmpty()` via two new IPC types (`system:notify-stack-state` React→host, `system:back` host→React). Marketplace and Library full-screen views opt into the existing `useEscClose` so both desktop ESC and Android back can dismiss them.

**Tech Stack:** React 18 (renderer), Electron 30 (desktop main), Kotlin (Android `MainActivity` + `SessionService` + `LocalBridgeServer`), vitest + jsdom (renderer tests).

**Spec:** `docs/superpowers/specs/2026-04-28-native-back-button-design.md`

---

## File Structure

### New files
- None. Every change is to existing files.

### Modified files (ordered by dependency)

| File | Responsibility | Tasks |
|---|---|---|
| `youcoded/desktop/src/renderer/hooks/use-esc-close.tsx` | Add `useDismissTop` imperative entry point | 1 |
| `youcoded/desktop/src/renderer/hooks/use-esc-close.test.tsx` | Cover new hook | 1 |
| `youcoded/desktop/src/shared/types.ts` | IPC channel constants — single source of truth | 2 |
| `youcoded/desktop/src/main/preload.ts` | Desktop `window.claude.system` no-op stub + IPC constants | 3 |
| `youcoded/desktop/src/main/ipc-handlers.ts` | Desktop no-op handler (parity) | 4 |
| `youcoded/desktop/src/renderer/remote-shim.ts` | Android/remote `window.claude.system` real impl + `system:back` subscribe | 5 |
| `youcoded/desktop/src/renderer/components/marketplace/MarketplaceScreen.tsx` | Register with dismiss stack | 6 |
| `youcoded/desktop/src/renderer/components/library/LibraryScreen.tsx` | Register with dismiss stack | 7 |
| `youcoded/desktop/src/renderer/App.tsx` | Wire stack-state push + `system:back` listener | 8 |
| `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` | Handle `system:notify-stack-state`; expose callback to Activity; cache last value | 9 |
| `youcoded/app/src/main/kotlin/com/youcoded/app/MainActivity.kt` | Register `OnBackPressedCallback`; broadcast `system:back` | 10 |
| `youcoded/desktop/tests/ipc-channels.test.ts` | Assert new types present in all four files | 11 |

### Test/verification flow
- Tasks 1–8: each ends in `npm test` for desktop renderer/main.
- Task 9–10: each ends in `./gradlew assembleDebug` (Android compiles).
- Task 11: parity test runs as part of `npm test`.
- Task 12: manual Android smoke test on a device or emulator.

---

## Task 1: Add `useDismissTop` hook (TDD)

**Files:**
- Modify: `youcoded/desktop/src/renderer/hooks/use-esc-close.tsx`
- Modify: `youcoded/desktop/src/renderer/hooks/use-esc-close.test.tsx`

The existing `EscStore` (defined in `use-esc-close.tsx:28-61`) has a `popTop()` method that's only called from inside the keydown listener (`use-esc-close.tsx:75-76`). We're adding a public hook that returns a stable function exposing the same behavior.

- [ ] **Step 1.1: Write failing tests**

Add three new tests to the bottom of `youcoded/desktop/src/renderer/hooks/use-esc-close.test.tsx`, inside the existing `describe('useEscClose', () => { ... })` block:

```tsx
  it('useDismissTop pops the top of the stack and invokes its onClose', () => {
    const onClose = vi.fn();
    let dismiss: () => void = () => {};
    function Capturer() {
      dismiss = useDismissTop();
      return null;
    }
    render(
      <EscCloseProvider>
        <Capturer />
        <Overlay onClose={onClose} />
      </EscCloseProvider>,
    );
    act(() => { dismiss(); });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('useDismissTop is LIFO: closes the most-recently-opened overlay first', () => {
    const onCloseA = vi.fn();
    const onCloseB = vi.fn();
    let dismiss: () => void = () => {};
    function Capturer() {
      dismiss = useDismissTop();
      return null;
    }
    render(
      <EscCloseProvider>
        <Capturer />
        <Overlay onClose={onCloseA} />
        <Overlay onClose={onCloseB} />
      </EscCloseProvider>,
    );
    act(() => { dismiss(); });
    expect(onCloseB).toHaveBeenCalledTimes(1);
    expect(onCloseA).not.toHaveBeenCalled();
  });

  it('useDismissTop is a no-op when the stack is empty', () => {
    let dismiss: () => void = () => {};
    function Capturer() {
      dismiss = useDismissTop();
      return null;
    }
    render(
      <EscCloseProvider>
        <Capturer />
      </EscCloseProvider>,
    );
    expect(() => act(() => { dismiss(); })).not.toThrow();
  });
```

Then update the import on line 8 to include `useDismissTop`:

```tsx
import { EscCloseProvider, useEscClose, useEscStackEmpty, useDismissTop } from './use-esc-close';
```

- [ ] **Step 1.2: Run tests — verify they fail**

Run: `cd youcoded/desktop && npx vitest run src/renderer/hooks/use-esc-close.test.tsx`
Expected: FAIL with `useDismissTop is not exported from './use-esc-close'`.

- [ ] **Step 1.3: Implement `useDismissTop`**

In `youcoded/desktop/src/renderer/hooks/use-esc-close.tsx`, update the header comment block (lines 1-22) to document the second trigger source. Replace it with:

```tsx
import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useSyncExternalStore,
} from 'react';

// Centralized dismissal stack. Overlays call useEscClose(open, onClose); a
// LIFO stack tracks them. The stack is triggered from two sources:
//   1. ESC keydown on the window (desktop primary input). The capture-phase
//      listener pops the top of the stack and invokes its onClose.
//   2. useDismissTop() — imperative entry point used by the Android
//      hardware-back bridge in App.tsx. Same popTop() body as the keydown
//      listener; back press is NOT synthesized as a keyboard event.
//
// When the stack is empty, ESC falls through to the chat-passthrough handler
// in App.tsx (which forwards \x1b to the PTY to interrupt Claude). On Android
// the hardware-back callback is disabled when the stack is empty (Android
// default — back backgrounds the app), so the chat-passthrough is never
// reached from a back press.
//
// Reasons for the indirection:
//   1. LIFO semantics — if two overlays are open, only the top one closes per ESC press.
//   2. preventDefault'd events signal to the chat-passthrough listener that an
//      overlay consumed the keypress, so we don't both close an overlay AND
//      interrupt Claude on a single ESC.
//   3. Single source of truth for "is any overlay open right now".
```

Then, at the end of the file (after `useEscStackEmpty`, line 122), add the new hook:

```tsx
// Imperative dismissal trigger — pops the top of the stack and invokes its
// onClose. Used by the Android hardware-back bridge so back press doesn't
// synthesize a keyboard event. ESC keydown listener and this hook share
// the same popTop() body; behavior is identical regardless of trigger source.
//
// The returned function is stable across renders (keyed only on the store
// identity, which never changes within a provider). Callers can safely
// cache it in a ref or pass it as a dependency without retriggering effects.
export function useDismissTop(): () => void {
  const store = useContext(EscStoreContext);
  return useCallback(() => {
    if (!store) return;
    const top = store.popTop();
    if (!top) return;
    try {
      top.ref.current();
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error('[useDismissTop] onClose threw:', err);
    }
  }, [store]);
}
```

- [ ] **Step 1.4: Run tests — verify they pass**

Run: `cd youcoded/desktop && npx vitest run src/renderer/hooks/use-esc-close.test.tsx`
Expected: PASS — all 11 tests green (8 original + 3 new).

- [ ] **Step 1.5: Commit**

```bash
cd youcoded
git add desktop/src/renderer/hooks/use-esc-close.tsx desktop/src/renderer/hooks/use-esc-close.test.tsx
git commit -m "$(cat <<'EOF'
feat(dismiss-stack): add useDismissTop imperative entry point

Used by the Android hardware-back bridge to pop the dismissal stack
without synthesizing a keyboard event. Shares the same popTop() body
as the existing ESC keydown listener.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add IPC channel constants

**Files:**
- Modify: `youcoded/desktop/src/shared/types.ts`

`shared/types.ts` is the single source of truth for IPC channel names; `preload.ts` duplicates these as inline literals (Electron sandbox can't import). The parity test in `youcoded/desktop/tests/ipc-channels.test.ts` enforces both sides agree.

- [ ] **Step 2.1: Locate the IPC constant block**

Run: `cd youcoded/desktop && grep -n "^export const IPC" src/shared/types.ts`
Expected: A line like `export const IPC = {`. Note the line number.

- [ ] **Step 2.2: Add the two new channels**

In `youcoded/desktop/src/shared/types.ts`, inside the `export const IPC = {` object, add these two entries near other `system:`-style channels (or at the end, just before the closing `}`). Use the same format as existing entries (uppercase key, kebab-case-with-colons string value):

```ts
  SYSTEM_NOTIFY_STACK_STATE: 'system:notify-stack-state',
  SYSTEM_BACK: 'system:back',
```

- [ ] **Step 2.3: Run tests**

Run: `cd youcoded/desktop && npx vitest run`
Expected: PASS — no failures from this change alone (parity test will fail in later tasks until preload.ts has matching constants; until then it's informational warnings, not hard failures, per the existing test logic at lines 50-77).

- [ ] **Step 2.4: Commit**

```bash
cd youcoded
git add desktop/src/shared/types.ts
git commit -m "$(cat <<'EOF'
feat(ipc): add system:notify-stack-state and system:back channels

For Android hardware back wiring. React signals stack non-emptiness
to host; host (Android) emits system:back when the user presses the
hardware back button.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `window.claude.system` to preload.ts (desktop no-op stub)

**Files:**
- Modify: `youcoded/desktop/src/main/preload.ts`

Desktop has no hardware-back source, so `notifyStackState` is a no-op stub. We expose it anyway because `remote-shim.ts` and `preload.ts` MUST share the same `window.claude` shape (PITFALLS.md → Cross-Platform parity invariant).

- [ ] **Step 3.1: Add IPC constants to the inline `IPC` object in preload.ts**

In `youcoded/desktop/src/main/preload.ts`, inside the `const IPC = {` block (starts at line 17), add:

```ts
  SYSTEM_NOTIFY_STACK_STATE: 'system:notify-stack-state',
  SYSTEM_BACK: 'system:back',
```

The strings must match `shared/types.ts` exactly.

- [ ] **Step 3.2: Locate the `contextBridge.exposeInMainWorld('claude', ...)` block**

Run: `cd youcoded/desktop && grep -n "contextBridge.exposeInMainWorld" src/main/preload.ts`
Expected: One line with the exposeInMainWorld call. Read ~30 lines from there to find the end of the exposed object.

- [ ] **Step 3.3: Add the `system` namespace inside the exposed object**

Add a `system` property to the exposed `window.claude` object (alongside other top-level namespaces like `dialog`, `dev`, `android`):

```ts
    // System namespace — platform integrations like hardware back button.
    // Desktop no-op stub: `notifyStackState` is only meaningful on Android,
    // where MainActivity uses it to enable/disable OnBackPressedCallback.
    // Exposed here for shape parity with remote-shim.ts (PITFALLS.md →
    // Cross-Platform parity invariant).
    system: {
      notifyStackState: (_empty: boolean) => {
        // No-op on desktop. Electron has no hardware back button.
      },
      onBack: (_cb: () => void) => {
        // No-op on desktop. Returns an empty unsubscribe function so
        // callers can call it unconditionally without platform branching.
        return () => {};
      },
    },
```

- [ ] **Step 3.4: Build to confirm TypeScript compiles**

Run: `cd youcoded/desktop && npx tsc -p tsconfig.json --noEmit`
Expected: No errors related to preload.ts.

- [ ] **Step 3.5: Commit**

```bash
cd youcoded
git add desktop/src/main/preload.ts
git commit -m "$(cat <<'EOF'
feat(preload): expose window.claude.system no-op stub

Desktop has no hardware back button. Stub is required for shape parity
with remote-shim.ts so Android-targeting components don't crash on
desktop when window.claude.system.notifyStackState() is called.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add no-op `system:notify-stack-state` handler to ipc-handlers.ts

**Files:**
- Modify: `youcoded/desktop/src/main/ipc-handlers.ts`

The Electron main process never receives this from React on desktop (since preload.ts's `notifyStackState` is a no-op and never calls `ipcRenderer.send`). But the IPC parity test asserts the channel string appears in `ipc-handlers.ts`, so we register a no-op handler.

- [ ] **Step 4.1: Locate a `ipcMain.on` example for fire-and-forget messages**

Run: `cd youcoded/desktop && grep -n "ipcMain.on(" src/main/ipc-handlers.ts | head -5`
Expected: Several entries showing the pattern.

- [ ] **Step 4.2: Add the no-op handler**

Find a logical place near other `system:` or platform-related handlers (or at the end of the registration block, before the closing of the function that wires handlers). Add:

```ts
  // No-op: Electron has no hardware back button. Registered for shape
  // parity with SessionService.kt's handleBridgeMessage() so the IPC
  // channel string exists in the desktop layer too.
  ipcMain.on(IPC.SYSTEM_NOTIFY_STACK_STATE, () => {
    // intentionally empty
  });
```

The `IPC` import should already exist at the top of the file. If it doesn't include `SYSTEM_NOTIFY_STACK_STATE`, no extra import is needed since `IPC` is the whole namespace.

- [ ] **Step 4.3: TypeScript compile check**

Run: `cd youcoded/desktop && npx tsc -p tsconfig.json --noEmit`
Expected: No errors.

- [ ] **Step 4.4: Commit**

```bash
cd youcoded
git add desktop/src/main/ipc-handlers.ts
git commit -m "$(cat <<'EOF'
feat(ipc-handlers): no-op system:notify-stack-state handler

Parity placeholder so the channel string appears in ipc-handlers.ts.
Desktop preload.ts notifyStackState is itself a no-op, so this handler
is unreachable in practice, but the IPC parity test asserts the string
appears here.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `window.claude.system` to remote-shim.ts (real impl)

**Files:**
- Modify: `youcoded/desktop/src/renderer/remote-shim.ts`

`remote-shim.ts` is the Android WebView and remote-browser implementation of `window.claude`. This is where the real wiring lives.

- [ ] **Step 5.1: Locate the `addListener` / `fire` / `invoke` helpers**

Run: `cd youcoded/desktop && grep -n "^const\|^function\|addListener\b\|^  fire" src/renderer/remote-shim.ts | head -30`
Expected: A `fire(type, payload)` helper for fire-and-forget WS sends, an `addListener(type, cb)` / `removeListener(type, cb)` for subscribing to push events. (The existing `dev.onInstallProgress` at lines 932-939 is the canonical template for a push-event subscription.)

- [ ] **Step 5.2: Locate the `dev:` namespace in the exposed object**

Run: `cd youcoded/desktop && grep -n "    dev: {" src/renderer/remote-shim.ts`
Expected: Around line 923. We'll add the `system` namespace nearby.

- [ ] **Step 5.3: Add the `system` namespace**

In `youcoded/desktop/src/renderer/remote-shim.ts`, near the `dev:` namespace (line ~923), add:

```ts
    // System namespace — hardware back button bridge for Android.
    // notifyStackState: React tells Android whether the dismissal stack is
    //   non-empty. Android sets OnBackPressedCallback.isEnabled accordingly.
    // onBack: subscribe to "user pressed hardware back" push events from
    //   Android. Returns an unsubscribe function (same pattern as dev.onInstallProgress).
    system: {
      notifyStackState: (empty: boolean) => {
        fire('system:notify-stack-state', { empty });
      },
      onBack: (cb: () => void) => {
        const handler: Callback = () => cb();
        addListener('system:back', handler);
        return () => removeListener('system:back', handler);
      },
    },
```

If `fire` is not the exact helper name in this file, use the actual fire-and-forget helper. Hints to verify:
- Search for `function fire` or `const fire =` in remote-shim.ts.
- If only `invoke` exists, `notifyStackState` can call `invoke('system:notify-stack-state', { empty })` and ignore the returned promise — there's no response-side handler and the parity test only checks string presence.

- [ ] **Step 5.4: Run tests**

Run: `cd youcoded/desktop && npx vitest run`
Expected: PASS. (Specifically the parity test in `tests/ipc-channels.test.ts` should not regress.)

- [ ] **Step 5.5: Commit**

```bash
cd youcoded
git add desktop/src/renderer/remote-shim.ts
git commit -m "$(cat <<'EOF'
feat(remote-shim): add window.claude.system for hardware back bridge

system.notifyStackState forwards stack-empty signal to Android.
system.onBack subscribes to system:back push events from Android.
Same shape as preload.ts's no-op stub (parity invariant).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Register MarketplaceScreen with the dismiss stack

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/marketplace/MarketplaceScreen.tsx`

Marketplace is a full-screen destination triggered from `App.tsx` via `activeView === 'marketplace'`. Today it has only an on-screen close button. After this change, ESC (desktop) and hardware back (Android) both invoke `onExit`.

Note: MarketplaceDetailOverlay (a child of MarketplaceScreen) already calls `useEscClose` — when both are open, the LIFO stack closes Detail first, then Marketplace.

- [ ] **Step 6.1: Locate the component definition and the `onExit` prop**

Run: `cd youcoded/desktop && grep -n "function MarketplaceScreen\|onExit" src/renderer/components/marketplace/MarketplaceScreen.tsx | head -10`
Expected: Component declaration and the prop type referencing `onExit: () => void`.

- [ ] **Step 6.2: Add the `useEscClose` import**

If `useEscClose` is not already imported in `MarketplaceScreen.tsx`, add the import near the top:

```tsx
import { useEscClose } from '../../hooks/use-esc-close';
```

(Adjust the relative path if MarketplaceScreen lives at a different depth — `../../hooks/use-esc-close` is correct for `components/marketplace/MarketplaceScreen.tsx`.)

- [ ] **Step 6.3: Register with the stack**

Inside the `MarketplaceScreen` component body, near the top (after any early returns and before any conditional rendering logic), add:

```tsx
  // Register with the dismissal stack. ESC on desktop and hardware back on
  // Android both call onExit — same path the on-screen close button uses.
  // LIFO with MarketplaceDetailOverlay: when an overlay is open over the
  // grid, its useEscClose entry sits above this one and gets dismissed first.
  useEscClose(true, onExit);
```

`true` is correct as the `open` argument because the component only mounts when `activeView === 'marketplace'` — the lifecycle of "is the screen open" is the lifecycle of the component itself.

- [ ] **Step 6.4: Manual desktop verification**

Run: `cd youcoded-dev && bash scripts/run-dev.sh`
Steps:
  1. Open the app's marketplace view (Library tab → Marketplace, or whatever the entry point is).
  2. Press ESC.
  3. Expected: returns to chat. (Same as clicking the close button.)
  4. Inside Marketplace, click a skill to open the DetailOverlay. Press ESC. Expected: DetailOverlay closes, Marketplace still visible. Press ESC again. Expected: Marketplace closes.

Shut down the dev server with Ctrl+C when done.

- [ ] **Step 6.5: Commit**

```bash
cd youcoded
git add desktop/src/renderer/components/marketplace/MarketplaceScreen.tsx
git commit -m "$(cat <<'EOF'
feat(marketplace): register MarketplaceScreen with dismiss stack

ESC on desktop and hardware back on Android (once wired) now exit
Marketplace via onExit. LIFO with MarketplaceDetailOverlay so a nested
detail closes first, then the grid.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Register LibraryScreen with the dismiss stack

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/library/LibraryScreen.tsx`

Same pattern as Task 6 for Library.

- [ ] **Step 7.1: Locate the component**

Run: `cd youcoded/desktop && grep -n "function LibraryScreen\|onExit" src/renderer/components/library/LibraryScreen.tsx | head -10`
Expected: Component declaration and `onExit: () => void` prop.

- [ ] **Step 7.2: Add the `useEscClose` import**

If not present in LibraryScreen.tsx, add:

```tsx
import { useEscClose } from '../../hooks/use-esc-close';
```

- [ ] **Step 7.3: Register with the stack**

Inside `LibraryScreen`, near the top of the component body:

```tsx
  // Register with the dismissal stack — ESC (desktop) and hardware back
  // (Android) both call onExit. See MarketplaceScreen.tsx for rationale.
  useEscClose(true, onExit);
```

- [ ] **Step 7.4: Manual desktop verification**

Same dev-server flow as Task 6.4, exercising the Library full-screen view this time.

- [ ] **Step 7.5: Commit**

```bash
cd youcoded
git add desktop/src/renderer/components/library/LibraryScreen.tsx
git commit -m "$(cat <<'EOF'
feat(library): register LibraryScreen with dismiss stack

ESC on desktop and hardware back on Android (once wired) now exit
Library via onExit. Mirrors MarketplaceScreen behavior.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Wire stack-state push and `system:back` listener in App.tsx

**Files:**
- Modify: `youcoded/desktop/src/renderer/App.tsx`

Two effects:
1. Subscribe to `useEscStackEmpty()` and call `window.claude.system.notifyStackState(empty)` whenever it flips. On desktop this is a no-op stub; on Android the WebSocket message reaches MainActivity.
2. Subscribe to `window.claude.system.onBack(handler)` where handler calls `dismissTop()`. The hook must be called inside a component, then captured in a ref so the subscriber outside React's render cycle can read the latest value.

- [ ] **Step 8.1: Identify the App component and the `EscCloseProvider` mount**

Run: `cd youcoded/desktop && grep -n "EscCloseProvider\|function AppInner\|export default function App" src/renderer/App.tsx | head -10`
Expected: One line where `EscCloseProvider` wraps part of the tree, and the inner App component declaration. The hooks must run inside the `EscCloseProvider`.

- [ ] **Step 8.2: Add imports**

At the top of `App.tsx`, ensure these imports include the new hook:

```tsx
import { useEscStackEmpty, useDismissTop } from './hooks/use-esc-close';
```

(Existing import for `useEscStackEmpty` may already be present — extend it.)

- [ ] **Step 8.3: Wire the stack-state push effect**

Inside the inner App component (the one that's a descendant of `EscCloseProvider` — usually `AppInner` or similar), add the effect alongside other top-level effects:

```tsx
  // Push stack-state changes to the host. On Android, MainActivity uses this
  // to flip OnBackPressedCallback.isEnabled. On desktop the call is a no-op
  // (preload.ts's window.claude.system.notifyStackState is a stub).
  const escStackEmpty = useEscStackEmpty();
  useEffect(() => {
    window.claude.system?.notifyStackState?.(escStackEmpty);
  }, [escStackEmpty]);
```

The `?.` chains guard against older `window.claude` shapes during a hot-reload window where preload may have been the previous version.

- [ ] **Step 8.4: Wire the `system:back` listener**

Add a second effect in the same component:

```tsx
  // Hardware back button (Android) → dismiss top of stack. dismissTop is a
  // hook so we capture it in a ref the WS listener (which lives outside
  // React's render cycle) can read.
  const dismissTop = useDismissTop();
  const dismissTopRef = useRef(dismissTop);
  useEffect(() => { dismissTopRef.current = dismissTop; }, [dismissTop]);

  useEffect(() => {
    const handler = () => dismissTopRef.current();
    const unsubscribe = window.claude.system?.onBack?.(handler);
    return unsubscribe;
  }, []);
```

Make sure `useRef` is imported from 'react' at the top of the file (it almost certainly already is — verify).

- [ ] **Step 8.5: Run desktop tests**

Run: `cd youcoded/desktop && npx vitest run`
Expected: PASS. The new effects are no-ops on desktop (preload stubs); existing tests stay green.

- [ ] **Step 8.6: Manual desktop smoke**

Run: `cd youcoded-dev && bash scripts/run-dev.sh`
Steps:
  1. Open the app.
  2. Open Settings panel. Press ESC. Expected: Settings closes (existing behavior, regression check).
  3. Open Marketplace, click into a skill detail, press ESC twice. Expected: Detail closes, then Marketplace closes (Task 6 + this task working together).
  4. Open browser DevTools console. Run: `window.claude.system.notifyStackState(false)`. Expected: no errors, no visible effect on desktop.

Shut down dev server with Ctrl+C.

- [ ] **Step 8.7: Commit**

```bash
cd youcoded
git add desktop/src/renderer/App.tsx
git commit -m "$(cat <<'EOF'
feat(app): wire stack-state push and system:back listener

App.tsx now mirrors useEscStackEmpty to host via window.claude.system
.notifyStackState and subscribes to system:back events to call
useDismissTop. On desktop both paths are no-ops; on Android they bridge
to MainActivity's OnBackPressedCallback.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: SessionService — handle `system:notify-stack-state`, expose callback

**Files:**
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt`

SessionService receives the WS message and routes it to a callback that MainActivity binds. We also cache the most recent value so MainActivity can replay it on Activity recreation (rotation, low memory).

- [ ] **Step 9.1: Locate the callback declarations near the top of SessionService**

Run: `cd youcoded/app && grep -n "var on[A-Z].*Requested" src/main/kotlin/com/youcoded/app/runtime/SessionService.kt | head -10`
Expected: Several `var onFooRequested: (...) -> Unit` declarations near the top of the class (e.g., `onFilePickerRequested`, `onFolderPickerRequested`, `onQrScanRequested`). Note the line numbers; we'll add ours alongside.

- [ ] **Step 9.2: Add the callback and cache field**

Near the existing callback declarations, add:

```kotlin
    /**
     * MainActivity binds this to flip OnBackPressedCallback.isEnabled.
     * `empty = true` means the React dismissal stack is empty (so hardware
     * back should fall through to Android default — background the app).
     * `empty = false` means at least one overlay/full-screen view is open
     * and back should be intercepted to call dismissTop().
     */
    var onStackStateChanged: ((empty: Boolean) -> Unit)? = null
        set(value) {
            field = value
            // Replay the last known state when MainActivity rebinds (e.g.
            // after rotation). Without this, the callback would default to
            // disabled until the user opens/closes another overlay.
            value?.invoke(lastStackEmpty)
        }

    /** Cached most-recent stack-empty value. Defaults to true (Android default
     *  behavior — back backgrounds the app — until React first signals). */
    private var lastStackEmpty: Boolean = true
```

- [ ] **Step 9.3: Locate `handleBridgeMessage` and find a similar fire-and-forget case**

Run: `cd youcoded/app && grep -n "fun handleBridgeMessage\|\"dialog:open-folder\" ->" src/main/kotlin/com/youcoded/app/runtime/SessionService.kt | head -5`
Expected: Function declaration plus an existing `when` case. The function uses a single `when (msg.type) { ... }` block.

- [ ] **Step 9.4: Add the `when` case**

Inside `handleBridgeMessage`'s `when (msg.type) { ... }` block, add (anywhere, but near other `system:` or platform handlers if any exist; otherwise near the end before the `else` branch):

```kotlin
            "system:notify-stack-state" -> {
                // React signals dismissal-stack non-emptiness. Cache and
                // forward to MainActivity to flip OnBackPressedCallback.
                // Fire-and-forget — no msg.id, no response.
                val payload = msg.payload as? JSONObject
                val empty = payload?.optBoolean("empty", true) ?: true
                lastStackEmpty = empty
                onStackStateChanged?.invoke(empty)
            }
```

(`msg.type` is the message type string; `msg.payload` is the JSONObject body; `msg.id` would be present for request-response but is null for fire-and-forget pushes. Match the existing patterns in this file — e.g., `dialog:open-folder` is request-response and uses `msg.id?.let { ... }`; this one is fire-and-forget so we don't.)

- [ ] **Step 9.5: Compile check**

Run: `cd youcoded && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 9.6: Commit**

```bash
cd youcoded
git add app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt
git commit -m "$(cat <<'EOF'
feat(android): handle system:notify-stack-state in SessionService

Adds onStackStateChanged callback bound by MainActivity, plus a
lastStackEmpty cache that's replayed on rebind so OnBackPressedCallback
state survives Activity recreation (rotation / low-memory restart).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: MainActivity — register OnBackPressedCallback, broadcast `system:back`

**Files:**
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/MainActivity.kt`

The Activity owns the `OnBackPressedCallback`. Its `isEnabled` mirrors the React stack state via `SessionService.onStackStateChanged`. When the callback fires, MainActivity broadcasts `system:back` over the LocalBridgeServer.

- [ ] **Step 10.1: Add the import**

At the top of `MainActivity.kt`, add (alphabetically among other `androidx.activity.*` imports):

```kotlin
import androidx.activity.OnBackPressedCallback
```

(It's likely not already imported — verify.) Also confirm `org.json.JSONObject` is importable; the existing file uses JSONObject indirectly via deep-link handling and the bridge server.

- [ ] **Step 10.2: Declare the callback as a class member**

In the `MainActivity` class, near the other field declarations (e.g., `private var boundService: ...` at MainActivity.kt:75), add:

```kotlin
    /**
     * Hardware back button → broadcast system:back to React, which calls
     * useDismissTop() to pop the topmost overlay/full-screen view.
     *
     * `isEnabled` is driven by SessionService.onStackStateChanged below:
     * when the React stack is empty, isEnabled = false and Android default
     * (background the app) takes over. When non-empty, this callback fires.
     *
     * Defaults to false so that during the brief moment between Activity
     * creation and React mounting, hardware back behaves as Android default
     * (no regression vs. pre-feature behavior).
     */
    private val backCallback = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() {
            val svc = boundService ?: return
            val msg = org.json.JSONObject().apply {
                put("type", "system:back")
                put("payload", org.json.JSONObject())
            }
            svc.bridgeServer.broadcast(msg)
        }
    }
```

- [ ] **Step 10.3: Register the callback in `onCreate`**

In `MainActivity.onCreate`, after `super.onCreate(savedInstanceState)` (line 84) and before `enableEdgeToEdge()` (line 89), add:

```kotlin
        // Wire the hardware back button. The callback is disabled by default;
        // SessionService.onStackStateChanged below (set in the LaunchedEffect
        // that fires when the service binds) flips isEnabled based on
        // whether the React dismissal stack is non-empty.
        onBackPressedDispatcher.addCallback(this, backCallback)
```

- [ ] **Step 10.4: Bind `onStackStateChanged` to SessionService when the service connects**

Find the existing `LaunchedEffect(svc)` block in MainActivity.onCreate (approximately MainActivity.kt:189-215). Inside it, alongside `svc.onFilePickerRequested = ...`, `svc.onFolderPickerRequested = ...`, etc., add:

```kotlin
                                        svc.onStackStateChanged = { empty ->
                                            // Must run on the main thread —
                                            // OnBackPressedCallback is UI-thread
                                            // bound. SessionService dispatches
                                            // bridge messages from the WS thread.
                                            runOnUiThread {
                                                backCallback.isEnabled = !empty
                                            }
                                        }
```

(Indentation should match the surrounding callback assignments — this is inside a Compose `LaunchedEffect { ... }` lambda. Match the existing style exactly.)

- [ ] **Step 10.5: Compile + smoke build**

Run: `cd youcoded && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL. The APK should install on a connected device or emulator without crashing.

- [ ] **Step 10.6: Commit**

```bash
cd youcoded
git add app/src/main/kotlin/com/youcoded/app/MainActivity.kt
git commit -m "$(cat <<'EOF'
feat(android): register OnBackPressedCallback for hardware back

Hardware back broadcasts system:back over LocalBridgeServer, which
React's remote-shim subscribes to and routes to useDismissTop().
Callback.isEnabled mirrors SessionService.onStackStateChanged so back
falls through to Android default (background) when no overlay is open.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Extend IPC parity test for new types

**Files:**
- Modify: `youcoded/desktop/tests/ipc-channels.test.ts`

The existing test (lines 1-80+ visible) compares `preload.ts` channel strings to `shared/types.ts`. We add a focused assertion that both new channel strings appear in all four files: `preload.ts`, `shared/types.ts`, `remote-shim.ts`, and `SessionService.kt`.

- [ ] **Step 11.1: Read the existing parity test**

Run: `cd youcoded/desktop && cat tests/ipc-channels.test.ts | tail -40`
Expected: View the end of the file to identify the right place for a new `describe` or `test` block.

- [ ] **Step 11.2: Add a new test case**

At the end of the file (before the final `});` of the outer describe block), add:

```ts
  test('system:back and system:notify-stack-state appear in all four IPC sites', () => {
    const sites = {
      'preload.ts': fs.readFileSync(path.join(__dirname, '../src/main/preload.ts'), 'utf8'),
      'types.ts': fs.readFileSync(path.join(__dirname, '../src/shared/types.ts'), 'utf8'),
      'remote-shim.ts': fs.readFileSync(path.join(__dirname, '../src/renderer/remote-shim.ts'), 'utf8'),
      'SessionService.kt': fs.readFileSync(
        path.join(__dirname, '../../app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt'),
        'utf8',
      ),
    };

    const required = ['system:notify-stack-state', 'system:back'];

    for (const [siteName, source] of Object.entries(sites)) {
      for (const channel of required) {
        // SessionService.kt uses the channel string only for incoming messages
        // (system:notify-stack-state) and outgoing broadcasts (system:back).
        // Both must appear literally somewhere in the file.
        expect(source, `expected ${channel} to appear in ${siteName}`).toContain(channel);
      }
    }
  });
```

- [ ] **Step 11.3: Run the test**

Run: `cd youcoded/desktop && npx vitest run tests/ipc-channels.test.ts`
Expected: PASS.

- [ ] **Step 11.4: Commit**

```bash
cd youcoded
git add desktop/tests/ipc-channels.test.ts
git commit -m "$(cat <<'EOF'
test(ipc): assert system:back and system:notify-stack-state parity

Asserts both channel strings appear literally in preload.ts, types.ts,
remote-shim.ts, and SessionService.kt — catches the typo-on-one-platform
class of bugs called out in PITFALLS.md → Cross-Platform.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Manual Android smoke test

**Files:**
- None (manual verification).

This is the final acceptance gate. Run on a physical Android device (preferred) or emulator with the just-built debug APK. Six scenarios from the spec.

- [ ] **Step 12.1: Build and install the debug APK**

Run: `cd youcoded && ./gradlew installDebug`
Expected: APK installs on the connected device.

- [ ] **Step 12.2: Scenario 1 — single overlay**

  1. Launch YouCoded.
  2. Open Settings panel (gear icon).
  3. Press hardware back button.
  4. Expected: Settings panel closes; chat view visible; app stays open.

- [ ] **Step 12.3: Scenario 2 — nested overlay over full-screen view**

  1. Open Marketplace (full-screen view).
  2. Tap any skill card to open MarketplaceDetailOverlay.
  3. Press hardware back.
  4. Expected: Detail overlay closes; Marketplace grid still visible.
  5. Press hardware back again.
  6. Expected: Marketplace closes; chat view visible.
  7. Press hardware back again.
  8. Expected: app backgrounds (returns to Android home / app switcher).

- [ ] **Step 12.4: Scenario 3 — empty stack at chat root**

  1. From the chat view with no overlays open, press hardware back.
  2. Expected: app backgrounds. No interruption to any in-flight Claude turn (verify by checking that Claude was thinking before/after if a turn was active).

- [ ] **Step 12.5: Scenario 4 — back during a Claude turn**

  1. Send a prompt that takes ≥10 seconds to complete (e.g., "Write a haiku, then explain it in 200 words").
  2. While Claude is thinking and no overlay is open, press hardware back.
  3. Expected: app backgrounds. Re-foreground the app (recents → tap YouCoded). Claude should still be processing or have finished — back press did NOT interrupt.

- [ ] **Step 12.6: Scenario 5 — soft keyboard up**

  1. Tap the InputBar to bring up the soft keyboard.
  2. With no overlay open, press hardware back.
  3. Expected: keyboard dismisses; app stays foregrounded.
  4. Press hardware back again.
  5. Expected: app backgrounds.

- [ ] **Step 12.7: Scenario 6 — Activity recreation**

  1. Open Settings panel.
  2. Rotate the device (or use developer-options → "Don't keep activities" toggled on, then return from background).
  3. Press hardware back.
  4. Expected: Settings panel closes (the cached `lastStackEmpty` was replayed when the new MainActivity rebound `onStackStateChanged`).

- [ ] **Step 12.8: If all six pass, mark feature complete**

No commit — this is verification only.

If any scenario fails, do NOT mark the feature complete. File a bug describing which scenario failed and what was observed; revisit the relevant Task implementation.

---

## Self-Review Checklist (run before handing off)

**Spec coverage**
- ✅ Decision: "Reuse the existing ESC stack" → Task 1 adds `useDismissTop`; Tasks 6-8 wire the rest.
- ✅ Decision: "Marketplace and Library register `useEscClose`" → Tasks 6, 7.
- ✅ Decision: "No keyboard event synthesis" → Task 10 broadcasts `system:back` directly; React calls `dismissTop()` (not a synthesized keydown).
- ✅ Decision: "Back at chat root backgrounds, no Claude interrupt" → Task 10's `OnBackPressedCallback(false)` default + Task 9's `lastStackEmpty = true` default handle this; the chat-passthrough handler is never reached because the callback is disabled.
- ✅ Decision: "isEnabled mirrors stack non-emptiness" → Tasks 8 (push) + 9 (cache) + 10 (mirror).
- ✅ Decision: "Terminal ↔ chat toggle out of scope" → no task touches view-mode toggle.
- ✅ Architecture: `useDismissTop()` exported from `use-esc-close.tsx` → Task 1.
- ✅ Architecture: Stack-state push effect in App.tsx → Task 8.
- ✅ Architecture: `system:back` listener in App.tsx via ref-bridge → Task 8.
- ✅ Architecture: `OnBackPressedCallback` registration → Task 10.
- ✅ Architecture: IPC parity (4-file rule) → Tasks 2, 3, 4, 5, 9, 10 + parity test 11.
- ✅ Edge case: soft keyboard → Task 12.6 (no code, system handles).
- ✅ Edge case: welcome screen → Task 9's `lastStackEmpty = true` default + Task 10's `false` initial isEnabled.
- ✅ Edge case: nested overlay over full-screen view → Task 12.3 (LIFO is automatic via stack mechanics).
- ✅ Edge case: initial-state race → Tasks 9 (default true) and 10 (default false enabled).
- ✅ Edge case: Activity recreation → Task 9's `onStackStateChanged` setter replays `lastStackEmpty`; Task 12.7 verifies.
- ✅ Edge case: concurrent stack mutations during back press → Task 1's `popTop()` is synchronous; Task 12 doesn't have a specific scenario but the hook test covers the no-op-on-empty case.
- ✅ Edge case: remote browser users → out of scope per spec; no task addresses (correct).
- ✅ Edge case: buddy window → out of scope per spec; no task addresses (correct, buddy is desktop-only).
- ✅ Testing: unit tests in Task 1; parity test in Task 11; manual smoke in Task 12.

**Placeholder scan:** All steps have concrete code, exact file paths, exact commands. No "TBD," "implement later," "similar to," or hand-wavy validation directives.

**Type/method consistency:** `useDismissTop()` is the same name in Task 1 (definition), Task 8 (consumption), and the spec. `onStackStateChanged` is consistent across Tasks 9 (declaration) and 10 (binding). `backCallback` is local to Task 10 only. `lastStackEmpty` is the same name in Task 9 declaration + Task 9 setter usage.

---

## Execution Notes

- All work happens on `master` in the `youcoded-dev` workspace by default. If this work needs isolation from concurrent edits, the implementer should `git worktree add` per CLAUDE.md guidance before starting.
- After Task 12 passes, push the branch and (if working in a worktree) clean up per `youcoded-dev/CLAUDE.md` → "Clean up worktrees after merging to master."
- No `app/build.gradle.kts` version bump is needed unless this ships with a release. The plan does not change `versionCode` / `versionName`.
- If the `bridgeServer.broadcast(JSONObject)` API name has changed since this plan was written, Task 10 Step 10.2's broadcast call may need a small adjustment — verify against `youcoded/app/src/main/kotlin/com/youcoded/app/bridge/LocalBridgeServer.kt:181` (current API at time of writing).
