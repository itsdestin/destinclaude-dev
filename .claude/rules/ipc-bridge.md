---
paths:
  - "youcoded/desktop/src/main/preload.ts"
  - "youcoded/desktop/src/main/ipc-handlers.ts"
  - "youcoded/desktop/src/renderer/remote-shim.ts"
  - "youcoded/app/**/SessionService.kt"
  - "youcoded/app/**/LocalBridgeServer.kt"
  - "youcoded/app/**/PlatformBridge.kt"
last_verified: 2026-04-11
---

# IPC Bridge Rules

You are editing the cross-platform IPC bridge. Before making changes, read `docs/shared-ui-architecture.md` for full context.

## Critical invariants

1. **Parity requirement**: `preload.ts` and `remote-shim.ts` MUST expose the same shared `window.claude` shape. If you add an API to one, add it to the other (or explicitly document it as platform-exclusive — only `window.claude.window` for Electron and `window.claude.android` for Android are allowed exceptions).

2. **Message type strings must be identical** across preload.ts, ipc-handlers.ts, and SessionService.kt. A typo silently breaks that feature on one platform.

3. **Response shape normalization**: Desktop returns raw values, Android wraps in JSONObject. The shim normalizes both. When adding a handler, test on BOTH platforms.

## Protocol format

- Request: `{ "type": "...", "id": "msg-1", "payload": {...} }`
- Response: `{ "type": "...:response", "id": "msg-1", "payload": {...} }`
- Push event: `{ "type": "...", "payload": {...} }` (no id)

## Adding a new IPC method

1. Add to `remote-shim.ts` using `invoke('type:name', payload)` or `fire('type:name', payload)`
2. Add to `ipc-handlers.ts` using `ipcMain.handle(IPC.CHANNEL, handler)` or `ipcMain.on()`
3. Add a `when` case to `SessionService.handleBridgeMessage()` (currently has 92 types)

Use `bridgeServer.respond(ws, msg.type, msg.id, payload)` in SessionService when `msg.id` is present.
