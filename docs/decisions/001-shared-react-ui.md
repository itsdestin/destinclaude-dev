# ADR 001: Shared React UI Across Desktop and Android

**Status:** Accepted
**Date:** Pre-2026 (foundational)

## Context

YouCoded targets both desktop (Windows/Mac/Linux via Electron) and Android. The creator is a non-developer; maintaining two UI codebases through conversation with Claude would be prohibitively complex.

## Decision

Use a single React app (`youcoded/desktop/src/renderer/`) as the source of truth for the main UI on both platforms:
- Desktop: Electron hosts the React app natively
- Android: WebView loads the React build from bundled assets (`file:///android_asset/web/`)
- IPC between the UI and native code uses the same JSON protocol on both platforms — only transport differs (Electron IPC vs WebSocket to LocalBridgeServer on `ws://localhost:9901`)

## Alternatives Considered

- **React Native** — would require porting every component, abandoning browser-only deps (backdrop-filter, content-visibility, etc.). Rejected.
- **Separate Compose/XML UI for Android** — would double maintenance burden. Rejected.
- **Capacitor / Tauri** — still requires writing Android-native glue for anything non-trivial. The WebView + WebSocket bridge gave us more control.

## Consequences

**Good:**
- Any React feature works on both platforms automatically
- Only platform-specific code is the IPC bridge + native APIs (camera, file picker, bootstrap)
- Themes, games, marketplace — all work on both with zero platform-specific code

**Bad:**
- `scripts/build-web-ui.sh` must run before every APK build (blank WebView otherwise)
- IPC handler parity must be maintained between preload.ts, ipc-handlers.ts, and SessionService.kt — 92 message types currently
- Some browser APIs behave subtly different in Android WebView vs Electron — need per-platform testing for complex features
