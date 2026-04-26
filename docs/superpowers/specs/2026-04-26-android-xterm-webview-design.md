# Android xterm-in-WebView (Tier 2 / 3 combined)

**Date:** 2026-04-26
**Status:** Approved for planning
**Predecessors:** [2026-04-24-android-terminal-data-parity-design.md](2026-04-24-android-terminal-data-parity-design.md) (Tier 1 — shipped)

## Goal

Replace Android's native Termux `TerminalView` with the existing React `TerminalView` (xterm.js) running inside the WebView. xterm consumes the `pty:raw-bytes` stream that Tier 1 already broadcasts. Result: a single shared terminal renderer across desktop and Android, fixing the pre-existing "WebView blocks touches to native terminal" bug as a side effect.

## Background

Tier 1 added the data-layer plumbing: vendored Termux `terminal-emulator` patched with `RawByteListener`, `pty:raw-bytes` WebSocket broadcast on Android, `terminal:get-screen-text` IPC on both platforms. Tier 1 did **not** touch the renderer — Android still renders the terminal via a native `TerminalView` Compose element behind the WebView. Because the WebView (always full-screen, transparent in terminal mode) sits on top, touches never reach the native terminal.

Tier 2 swaps the rendering surface: xterm becomes the only terminal renderer on Android, fed by `pty:raw-bytes`. Tier 1's previously-named "Tier 2 prototype" and "Tier 3 swap" collapse into a single phase — there is no feature flag and no parallel code path. The decision gate is dogfooding before merge.

## Architecture

**Single rendering surface on both platforms.** The React `TerminalView` (xterm.js with WebGL/Fit/Unicode11 addons) is the only terminal renderer. Desktop continues to consume `pty:output` (string from node-pty); Android consumes `pty:raw-bytes` (base64 → `Uint8Array` → `terminal.write()`). The vendored `terminal-emulator` module stays — `TerminalSession` runs the PTY headlessly and feeds the raw-byte stream via `RawByteListener`. Termux's `terminal-view` Maven dependency is removed.

**Display-only on touch platforms.** xterm renders bytes but does not solicit input on Android or remote-browser sessions. The existing `InputBar` `<textarea>` (`minimal` mode) is the typing surface; `TerminalToolbar` and `TerminalScrollButtons` provide special keys. xterm's hidden textarea is suppressed via `disableStdin: true`, and the `terminal.onData → sendInput` registration is skipped on touch platforms.

**On desktop:** xterm's input handling is unchanged. Hardware keyboard, CJK IME, bracketed paste, etc. continue to work via `terminal.onData → sendInput`.

## Component changes

### React renderer (`youcoded/desktop/src/renderer/`)

| File | Change |
|------|--------|
| `components/TerminalView.tsx` | Conditional input source: `usePtyOutput` on desktop, new `usePtyRawBytes` on touch platforms. `disableStdin: true` on touch platforms. Skip `terminal.onData(...)` registration on touch platforms. Font size constant: 12px on touch platforms, 15px on desktop. |
| `hooks/useIpc.ts` (or new `hooks/usePtyRawBytes.ts`) | New hook `usePtyRawBytes(sessionId, callback)` that subscribes to `pty:raw-bytes:${sessionId}` events, base64-decodes the payload, and invokes the callback with `Uint8Array`. Malformed base64 is silently ignored (don't crash the renderer). |
| `components/InputBar.tsx` | No change. The `minimal` mode submit path (`val + '\r'` via `sendInput`) continues to drive the PTY. |
| `components/TerminalToolbar.tsx` | No change. Existing Esc/Tab/Ctrl/←/→ buttons continue to call `sendInput`. |
| `platform.ts` | No change. `isTouchDevice()` already returns true for Android and remote browser. |

### Android Compose / Gradle

| File | Change |
|------|--------|
| `app/src/main/kotlin/com/youcoded/app/ui/ChatScreen.kt` | Delete the entire `if (currentSession != null && screenMode == ScreenMode.Terminal)` Compose render block (the native `TerminalView` host). Delete the private `applyTerminalColors(session)` helper. The `screenMode` enum and `viewModeRequest` collector stay if they have other consumers; if not (verified during implementation), drop them. |
| `app/src/main/kotlin/com/youcoded/app/runtime/BaseTerminalViewClient.kt` | Delete (only consumer was the deleted Compose block). |
| `app/build.gradle.kts` | Remove `com.github.termux.termux-app:terminal-view:v0.118.1` dependency. Keep `terminal-emulator-vendored` (still produces the raw-byte stream). |
| `app/src/main/kotlin/com/youcoded/app/ui/WebViewHost.kt` | No change. Background stays transparent so theme tokens / wallpapers show through consistently in chat and terminal modes. |
| `app/src/main/kotlin/com/youcoded/app/runtime/PtyBridge.kt` | No change. Continues to host `TerminalSession`, register the `RawByteListener`, and emit `rawByteFlow`. |
| `app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` | No change. Continues to broadcast `pty:raw-bytes` and respond to `terminal:get-screen-text`. |

### Vendored module (`youcoded/terminal-emulator-vendored/`)

No change. The patched `RawByteListener` is still load-bearing: it is the source of the `pty:raw-bytes` stream that xterm now consumes.

## Touch / IME / UX

- **Soft keyboard:** never summons from tapping the terminal pane. xterm's hidden textarea is disabled via `disableStdin: true` on touch platforms.
- **Typed input:** flows through `InputBar` (`minimal` mode `<textarea>`) → `sendInput(text + '\r')` → PTY. Native Android IME (GBoard, Samsung keyboard, etc.) interacts with the textarea, never with xterm. The historical xterm.js mobile IME risk (issue #2403) does not apply to our use case.
- **Special keys:** `TerminalToolbar` (Esc/Tab/Ctrl/←/→) and `TerminalScrollButtons` (↑/↓) continue to dispatch escape sequences via `sendInput`.
- **Auto-scroll on output:** xterm's default `scrollOnUserInput: true` handles it.
- **Font size:** 12px constant on Android (touch platforms), 14px on desktop (current value, unchanged). One-line tweak if dogfooding shows the 12px touch value is wrong.
- **WebGL renderer:** kept on Android. The existing `WebglAddon` `onContextLoss` recovery falls back to xterm's canvas renderer if WebGL fails to attach. If even canvas is sluggish during dogfood, that triggers a revert.

### Explicitly NOT in scope

- Pinch-zoom (xterm.js has no native support)
- Long-press text selection tuning for mobile gestures
- Wiring `TerminalToolbar`'s sticky `Ctrl` toggle to compose with the next character (pre-existing limitation, separate work)
- Migrating desktop to consume `pty:raw-bytes` (desktop's `pty:output` string path works fine; YAGNI)
- Removing `screenMode` / `viewModeRequest` plumbing — drop only if verified to have no other consumers

## Decision gate

**One pass, no flag.** Implementation merges to a feature branch and is dogfooded before merging to master.

**Merge to master requires explicit user (Destin) sign-off after dogfooding.** Not automatic.

**Revert path:** if any criterion below fires, `git revert` the merge commit. Native `TerminalView`, `BaseTerminalViewClient`, and the `terminal-view` Gradle dep all come back from history. Tier 1 raw-byte infrastructure stays regardless — it's still useful for the screen-text classifier even if xterm doesn't ship.

**Revert criteria (any one triggers revert):**
- Visible frame drops during Claude's normal TUI render (banner + spinner + tool output)
- Auto-scroll-to-bottom doesn't fire when new output arrives
- Noticeable latency between PTY output emission and bytes appearing on screen
- Existing `InputBar` / `TerminalToolbar` / `TerminalScrollButtons` behavior regresses

**Ship-and-file-issue (annoying but not blocking):**
- Cosmetic xterm rendering glitches that don't lose data
- Missing pinch-zoom or long-press selection
- Sticky `Ctrl` toggle still purely visual (pre-existing)

## Tests & verification

### Automated tests that must keep passing (no changes expected)

- `desktop/tests/attention-classifier-parity.test.ts` (classifier path unchanged)
- `desktop/tests/raw-byte-listener-contract.test.ts` (xterm becomes a new consumer of the contract)
- `desktop/tests/ipc-channels.test.ts` (no new IPC types)
- Existing desktop `TerminalView` smoke tests (desktop path unchanged)

### New automated tests

- `usePtyRawBytes` unit test: feed a base64 string, assert callback receives the decoded `Uint8Array`. Feed a malformed base64 string, assert no throw and callback not called.
- `TerminalView` mount logic test (touch path): mock `isTouchDevice()` → true. Mock `Terminal` constructor. Assert it is constructed with `disableStdin: true`. Assert `terminal.onData` is never called.
- `TerminalView` mount logic test (desktop path): mock `isTouchDevice()` → false. Assert `disableStdin` is `false` (or omitted). Assert `terminal.onData` is registered.

### Manual verification (Destin runs, Claude guides via Chrome DevTools)

1. Build + install debug APK
2. Open a session, switch to terminal view
3. Confirm Claude's TUI renders in xterm (banner, prompt, spinner all visible)
4. Type in `InputBar`, hit Enter — message reaches Claude
5. Tap Esc / Tab / arrows / scroll buttons — sequences fire correctly
6. Wait for Claude output — auto-scroll-to-bottom works
7. Tap on the xterm pane itself — soft keyboard does NOT appear
8. Chrome DevTools: confirm `pty:raw-bytes` WebSocket frames are arriving and `terminalRef.current.write()` is being called
9. Watch for visible frame drops during heavy output (Ink redraws + tool spinners)

### Cleanup verification

- Native `TerminalView` block removed from `ChatScreen.kt` (grep for `com.termux.view.TerminalView` import — should be gone)
- `terminal-view:v0.118.1` removed from `app/build.gradle.kts`
- `BaseTerminalViewClient.kt` deleted, no remaining references in the codebase
- `applyTerminalColors()` deleted from `ChatScreen.kt`, no remaining references
- App still builds (`./gradlew assembleDebug`)
- App still runs the existing test suite (`./gradlew test`)

## Open questions / known limitations

- **`screenMode` enum and `viewModeRequest` collector** in `ChatScreen.kt`: may have other consumers (auto-switch on shell sessions, etc.). Implementation step verifies and either prunes or leaves intact — does not block merge.
- **`useSubmitConfirmation`** (the renderer-side submit retry from PITFALLS) applies to chat-view submits, not terminal-view minimal-mode submits. Out of scope; existing behavior unchanged.
- **Selection / copy on xterm in WebView**: not enabled in v1 (mobile gesture tuning is fiddly). Will be a follow-up if dogfood reveals strong demand.
- **`pty:output` on Android**: not broadcast today, not added by this work. The classifier uses `terminal:get-screen-text` (Kotlin path reading the headless emulator), unchanged.
