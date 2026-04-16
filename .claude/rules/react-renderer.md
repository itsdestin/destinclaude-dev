---
paths:
  - "youcoded/desktop/src/renderer/**"
last_verified: 2026-04-11
---

# React Renderer Rules

You are editing the React renderer — code that runs in BOTH the Electron renderer process AND in a bundled Android WebView.

## Node.js vs Browser boundary

Renderer code runs in a sandboxed browser-like environment. **Do not use:**

- `process.env.*` — not available in Android WebView; not reliably available in Electron renderer either
- `require()` — CommonJS is not available in the bundled output
- `fs`, `path`, `os`, or any Node builtin — WebView has no Node runtime
- Direct file system access — must go through IPC (`window.claude.*`)

**Do use:**
- `window.claude.*` APIs from `remote-shim.ts` for all platform operations
- `import` statements (ES modules) for dependencies
- Standard browser APIs (`fetch`, `localStorage`, `document`, etc.)

## Performance patterns

- **Prefer `content-visibility: auto` over virtualization** for long lists. It handles layout offscreen without the complexity of virtual scrolling. Virtualization breaks find-in-page and accessibility.
- **Smart `backdrop-filter`**: apply only when panel is visible. Disable during scroll/transitions to avoid GPU overload on low-end Android devices.
- **Context memoization**: Any value placed in React Context must be memoized (`useMemo`) or it re-renders every consumer on every parent render. Always split contexts when some values change more often than others.

## Reducer refs

During text streaming, the chat reducer preserves `toolCalls` and `toolGroups` Map references when those Maps haven't changed. This lets `React.memo` on ToolBubble/ToolGroup work correctly without requiring reducer changes. Don't clone these Maps when not needed.

## Platform detection

`location.protocol === 'file:'` indicates Android (WebView loading bundled assets). Desktop uses `http:` (dev server) or packaged protocol. Use `remote-shim.ts` helpers rather than checking this directly in components.
