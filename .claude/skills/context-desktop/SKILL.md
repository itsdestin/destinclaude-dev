---
name: context-desktop
description: Load deep context for desktop app development — Electron main process, React renderer, IPC handlers, hook relay, remote server, multiplayer games, themes. Invoke before making non-trivial changes to youcoded/desktop/ code, especially when working on IPC, state management, or cross-platform features.
---

# Desktop Development Context

You are working on the YouCoded desktop app. Before making changes, orient with these references:

## Read first
- `youcoded/desktop/CLAUDE.md` — component-level docs (SessionManager, TranscriptWatcher, HookRelay)
- `docs/shared-ui-architecture.md` — cross-platform React sharing + IPC pattern
- `docs/chat-reducer.md` — if touching state/chat-reducer.ts or ChatView

## Critical invariants (do not violate)

1. **preload.ts and remote-shim.ts MUST expose the same shared `window.claude` shape.** Intentional exceptions: `window.claude.window` (Electron-only) and `window.claude.android` (Android-only). Any other divergence crashes React on one platform.

2. **Message type strings must be identical** across preload.ts, ipc-handlers.ts, and SessionService.kt. A typo silently breaks one platform.

3. **Node.js vs Browser boundary** in renderer: no `process.env`, no `require()`, no Node builtins. WebView has no Node runtime. Use `window.claude.*` for platform ops.

4. **toolCalls Map is never cleared** in the chat reducer. Use `activeTurnToolIds` for current-turn checks.

5. **Always use `endTurn()` helper** when adding turn-ending code paths.

## Testing

Run `cd youcoded/desktop && npm test` for vitest suite. 16 test files covering transcript-watcher, theme system, remote config, IPC handlers, session management.

## File locations
- React app: `youcoded/desktop/src/renderer/`
- Electron main: `youcoded/desktop/src/main/`
- IPC contract: `ipc-handlers.ts` (main) ↔ `remote-shim.ts` (renderer) ↔ `preload.ts` (bridge)
- Shared types: `youcoded/desktop/src/shared/`
