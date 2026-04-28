---
date: 2026-04-28
status: approved
topic: native-back-button
---

# Native Android Back Button — Design

## Problem

Android's hardware back button currently has no in-app handler. Pressing it from any state in YouCoded — settings panel open, marketplace browsing, command drawer expanded, mid-conversation — backgrounds the entire app instead of unwinding the visible stack of overlays and full-screen destinations. Users have to reach for on-screen close buttons (or accept losing the current screen) when the platform-native gesture would be back.

The desktop app already has a robust dismissal stack — `useEscClose` (`youcoded/desktop/src/renderer/hooks/use-esc-close.tsx`) — that 20+ overlays participate in via a single LIFO `EscStore`. ESC at chat root falls through to a chat-passthrough handler that forwards `\x1b` to the PTY (interrupt Claude). Android has none of this; `MainActivity` registers no `OnBackPressedCallback`.

The goal is to wire Android's hardware back into the existing dismissal stack so back unwinds overlays and full-screen destinations LIFO, with no behavioral change on desktop and no overloading of back into "interrupt Claude" semantics.

iOS is out of scope — there is no iOS app planned. Remote browser users are out of scope — browsers handle their own back via URL history.

## Decisions

- **Reuse the existing ESC stack.** No parallel "system back" stack, no new closer registration per overlay. Hardware back invokes the same `popTop()` the ESC keydown listener does, via a new imperative entry point. Approach (i) from brainstorm.
- **Marketplace and Library register `useEscClose` on all platforms.** Today they only have on-screen close buttons; this puts them in the dismissal stack so both desktop ESC and Android back can dismiss them. Minor desktop-side behavior change: pressing ESC from inside Marketplace/Library now exits to chat (it didn't before).
- **No keyboard event synthesis.** Android does NOT dispatch a synthetic `keydown('Escape')` event. The new `useDismissTop()` hook returns an imperative function the bridge listener calls directly. Cleaner semantics and avoids any chance of the chat-passthrough handler firing on a synthetic event.
- **Back at chat root backgrounds the app — does NOT interrupt Claude.** Hardware back has a strong "navigate up" mental model on Android that's worth preserving; overloading it with "stop the work" risks users aborting Claude when they meant to navigate. The interrupt affordance already exists in-app (toolbar ESC button, slash commands).
- **`OnBackPressedCallback.isEnabled` mirrors React stack non-emptiness.** When the React stack is empty, the callback is disabled and Android default takes over (background). When non-empty, the callback handles back and forwards to React. Avoids any need for the chat-passthrough handler to distinguish "real" vs. "synthetic" trigger sources.
- **Terminal ↔ chat view-mode toggle is out of scope.** They're peer toggles, not parent/child. Back doesn't unwind between them.
- **No "back again to exit" toast.** When the stack is empty, a single back press backgrounds the app. Standard Android behavior; users will discover the gesture works as expected.

## Architecture

### React side: imperative entry point on the existing store

`youcoded/desktop/src/renderer/hooks/use-esc-close.tsx` gains one new export:

```ts
// Returns a stable function that pops the top of the dismissal stack and
// invokes its onClose. Used by the Android hardware-back bridge to dismiss
// the topmost overlay/full-screen view without synthesizing a keyboard
// event. ESC keydown listener and this hook share the same popTop() body —
// keeping behavior identical regardless of trigger source.
export function useDismissTop(): () => void;
```

The implementation calls the same `store.popTop()` and runs the closer's `ref.current()` that the existing `EscCloseProvider` keydown handler uses. No new state, no parallel stack, no changes to existing `useEscClose` registrations.

Header comment on `use-esc-close.tsx` is updated to note the stack is now triggered by both ESC (desktop) and `system:back` (Android), even though the file name remains `use-esc-close.tsx`. A rename is deferred — every existing import site would need a sweep, and the comment is sufficient documentation.

### React side: stack-state push to Android

App.tsx mounts a new effect that subscribes to `useEscStackEmpty()` (already exported from `use-esc-close.tsx`) and pushes `system:notify-stack-state` to the bridge whenever the value flips:

```ts
const stackEmpty = useEscStackEmpty();
useEffect(() => {
  window.claude.system?.notifyStackState?.(stackEmpty);
}, [stackEmpty]);
```

On desktop this is a no-op stub (preload's `system.notifyStackState` does nothing). On Android the remote-shim sends a WebSocket message that SessionService routes to MainActivity.

### React side: `system:back` event listener

`useDismissTop` is a hook and can only be called inside a React component, but the WebSocket listener in `remote-shim.ts` lives outside React. Bridge: `App.tsx` calls `useDismissTop()` once at mount, stores the returned function in a `useRef`, and exposes it to the bridge via `window.__youcodedDismissTop = ref.current` (same pattern App.tsx already uses for cross-effect refs in attention sync). `remote-shim.ts` registers a `'system:back'` event handler on the WebSocket that reads `window.__youcodedDismissTop?.()`. On desktop the global is set but the WebSocket listener is never registered — desktop has no `system:back` source. On Android-only, the global is also harmless on remote browsers because remote browsers connect to `RemoteServer`, not the LocalBridgeServer that emits `system:back` (which is Android-WebView-local).

### Android side: `OnBackPressedCallback`

`MainActivity.onCreate` registers an `OnBackPressedCallback` with `onBackPressedDispatcher`:

```kotlin
private val backCallback = object : OnBackPressedCallback(false) {
  override fun handleOnBackPressed() {
    // bridgeServer.broadcastEvent / sendToAll — whichever method the
    // LocalBridgeServer exposes for unsolicited push events. Same path
    // pty:raw-bytes already uses to push events to the connected WebView.
    boundService?.bridgeServer?.broadcastEvent("system:back", JSONObject())
  }
}
```

Default `isEnabled = false` — Android's default behavior (background) applies until React signals the stack is non-empty.

`SessionService.handleBridgeMessage` adds a `when` case for `system:notify-stack-state`. Payload is `{ empty: Boolean }`. Service forwards to MainActivity via a callback (matching the existing `onFilePickerRequested` / `onFolderPickerRequested` pattern in `MainActivity.kt:189-215`):

```kotlin
svc.onStackStateChanged = { empty ->
  runOnUiThread { backCallback.isEnabled = !empty }
}
```

### Data flow

```
User opens Settings panel
  → SettingsPanel mounts, calls useEscClose(true, onClose)
  → store.push() → store emits → useEscStackEmpty() returns false
  → App.tsx effect fires → window.claude.system.notifyStackState(false)
  → remote-shim sends WebSocket "system:notify-stack-state" {empty: false}
  → SessionService forwards to MainActivity → backCallback.isEnabled = true

User presses hardware back
  → Android dispatches to backCallback (now enabled)
  → MainActivity broadcasts "system:back" via bridgeServer
  → remote-shim receives, invokes dismissTop()
  → store.popTop() → SettingsPanel's onClose runs
  → store empty → useEscStackEmpty() returns true → push true to Android
  → backCallback.isEnabled = false

User presses hardware back again
  → backCallback disabled → Android default → app backgrounds
```

### IPC parity (the four-file rule)

Per `docs/PITFALLS.md → Cross-Platform`, message type strings must be identical across `preload.ts`, `ipc-handlers.ts`, `remote-shim.ts`, and `SessionService.kt`. Two new message types:

| Type | Direction | preload.ts | remote-shim.ts | ipc-handlers.ts | SessionService.kt |
|---|---|---|---|---|---|
| `system:notify-stack-state` | React → host | No-op stub for shape parity | Real WS send | No-op handler (Electron doesn't need it) | Forwards to MainActivity callback |
| `system:back` | host → React | N/A (Electron has no system back) | Listens for WS event, calls `dismissTop()` | N/A | Broadcast from MainActivity via `bridgeServer.broadcast` |

`window.claude.system` is a new namespace exposed in both preload.ts and remote-shim.ts. Currently has only `notifyStackState(empty: boolean)`; reserved for future system-level platform integrations.

### Marketplace/Library registration

Two one-line additions:

- `MarketplaceScreen.tsx`: `useEscClose(true, onExit);` near the top of the component.
- `LibraryScreen.tsx`: `useEscClose(true, onExit);` same.

Both already accept `onExit` props. No prop changes; no parent changes in App.tsx.

## Edge cases

- **Soft keyboard up:** Android dismisses the IME on the first back press before invoking app callbacks. Our callback only sees back presses after the keyboard is already gone. No code needed.
- **Welcome screen / no overlays:** Stack empty → callback disabled → back backgrounds the app. Correct.
- **Marketplace + DetailOverlay open:** Stack is `[Marketplace, DetailOverlay]`. Back closes DetailOverlay first, next back closes Marketplace, next back backgrounds. Already LIFO-correct via existing stack mechanics.
- **Terminal view mode:** Out of scope per Decisions. Terminal ↔ chat toggle stays peer-to-peer; back at chat root in terminal view backgrounds the app same as in chat view.
- **Initial-state race at app start:** Until React mounts and the App.tsx effect first fires, `backCallback.isEnabled = false` (Android default). Any back press during that ~50ms window backgrounds the app — same as today, no regression. Once React signals, callback becomes accurate.
- **Service rebind / Activity recreation:** When MainActivity recreates (configuration change, low memory), it re-registers the callback with `isEnabled = false`. SessionService re-issues the latest known stack state via `onStackStateChanged` after the bind callback wires up (analogous to existing `LaunchedEffect(svc) { ... }` block at `MainActivity.kt:189-215`). Implementation: SessionService caches the most recent `empty` value and replays it when `onStackStateChanged` is assigned.
- **Concurrent stack mutations during back press:** The React `popTop()` is synchronous and runs before the next event loop tick, so a back press → pop → React signals empty happens without intermediate states leaking to Android. If the user presses back twice in rapid succession before the empty signal reaches Android, the second press still routes through the callback (enabled) — but `dismissTop()` on an empty stack is a no-op, so worst case is a wasted IPC round trip. Not a correctness issue.
- **Remote browser users on Android phones:** Out of scope. Their browser's back button traverses URL history; we don't intercept it via popstate.
- **Buddy window:** Buddy renders in its own React root with its own `EscCloseProvider`. Buddy is desktop-only, so the Android back bridge never reaches it.

## Testing

### Unit tests

- New test in `youcoded/desktop/src/renderer/hooks/use-esc-close.test.tsx`:
  - `useDismissTop()` pops the top closer and invokes it.
  - Multiple registered closers — `dismissTop` runs only the most recent.
  - `dismissTop()` on an empty stack is a no-op (does not throw).

### IPC parity test

Extend `youcoded/desktop/tests/ipc-channels.test.ts` to assert both `system:back` and `system:notify-stack-state` strings exist in `preload.ts`, `remote-shim.ts`, and `SessionService.kt`. Per existing convention, push events (`system:back`) only need to appear where they're emitted/listened (no `ipc-handlers.ts` entry required, matching how `pty:raw-bytes` is handled).

### Android instrumented / manual smoke

Manual smoke covering:

1. **Single overlay:** Open Settings → press back → Settings closes, app stays open.
2. **Nested:** Open Marketplace → tap a skill (DetailOverlay opens) → press back → DetailOverlay closes, Marketplace still visible. Press back again → Marketplace closes, chat visible.
3. **Empty stack:** From chat with no overlays, press back → app backgrounds.
4. **During Claude turn:** Send a prompt, while Claude is thinking and no overlay is open, press back → app backgrounds. Claude is NOT interrupted.
5. **Soft keyboard:** Focus InputBar (keyboard up), no overlay, press back → keyboard dismisses, app stays. Press back again → app backgrounds.
6. **Activity recreation:** Open Settings, rotate device, press back → Settings closes (state replay worked).

Instrumented test for #6 specifically (recreation) is highest-value to automate; the others are quick manual checks.

## Files touched

**Modified:**

- `youcoded/desktop/src/renderer/hooks/use-esc-close.tsx` — add `useDismissTop` export, update header comment to document both trigger sources.
- `youcoded/desktop/src/renderer/App.tsx` — wire stack-state push effect; wire `system:back` listener that calls `dismissTop()`.
- `youcoded/desktop/src/renderer/components/marketplace/MarketplaceScreen.tsx` — add `useEscClose(true, onExit)`.
- `youcoded/desktop/src/renderer/components/library/LibraryScreen.tsx` — add `useEscClose(true, onExit)`.
- `youcoded/desktop/src/main/preload.ts` — expose `window.claude.system.notifyStackState` (no-op stub); add `SYSTEM_NOTIFY_STACK_STATE` to inline `IPC` constants.
- `youcoded/desktop/src/renderer/remote-shim.ts` — real implementation of `system.notifyStackState` (WebSocket send); registers `system:back` event handler.
- `youcoded/desktop/src/main/ipc-handlers.ts` — no-op handler for `system:notify-stack-state` (parity).
- `youcoded/app/src/main/kotlin/com/youcoded/app/MainActivity.kt` — register `OnBackPressedCallback`; add `onStackStateChanged` callback hookup analogous to existing `onFilePickerRequested` etc.
- `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` — handle `system:notify-stack-state` in `handleBridgeMessage`; cache last value for activity-recreation replay; expose `bridgeServer.broadcast("system:back", ...)` path used by MainActivity.

**New tests:**

- New cases in `youcoded/desktop/src/renderer/hooks/use-esc-close.test.tsx`.
- New parity assertions in `youcoded/desktop/tests/ipc-channels.test.ts`.

## Out of scope (explicit non-goals)

- iOS app — no plans; not in workspace.
- Remote browser back — browsers manage their own back via URL history.
- Terminal ↔ chat view-mode toggle as a back-traversable layer.
- "Back again to exit" toast at chat root.
- Forwarding back to the PTY as `\x1b` (Claude interrupt) at chat root.
- Renaming `use-esc-close.tsx` to a more accurate name like `dismissible-stack.tsx` — deferred, header-comment update is sufficient until/unless behavior diverges between ESC and back per-overlay.
