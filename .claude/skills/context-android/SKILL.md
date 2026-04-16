---
name: context-android
description: Load deep context for Android app development — Kotlin SessionService, Bootstrap runtime, WebViewHost, LocalBridgeServer, Termux environment, SELinux bypass. Invoke before making non-trivial changes to youcoded/app/ code, especially runtime, IPC, or native UI features.
---

# Android Development Context

You are working on the YouCoded Android app. Before making changes, orient with these references:

## Read first
- `docs/android-runtime.md` — full runtime architecture, key files table, SELinux bypass details
- `docs/shared-ui-architecture.md` — React UI is SHARED with desktop; Android only contributes native APIs
- `arch_shared_ui_why.md` memory — why UI is shared, not native

## Hard constraints (DO NOT violate)

1. **`LD_LIBRARY_PATH` is mandatory** in `Bootstrap.buildRuntimeEnv()`. Termux binaries relocated, DT_RUNPATH stale. Removing it breaks all binaries.

2. **All exec routes through `/system/bin/linker64`** for SELinux W^X. Three distinct layers:
   - LD_PRELOAD (termux-exec linker variant) for C/Rust
   - `claude-wrapper.js` for /tmp rewriting, fs patches, BASH_ENV injection (NOT exec routing)
   - `linker64-env.sh` for Go binaries (gh, fzf, micro)

3. **`TMPDIR` = `$HOME/.cache/tmpdir`** (not `$HOME/tmp` — avoids Node.js compiled-in rewriting double-applying)

4. **Runtime fixes must apply to BOTH `PtyBridge` and `DirectShellBridge`**. Both share `Bootstrap.buildRuntimeEnv()` and `Bootstrap.deployBashEnv()`.

5. **Do NOT poll `isRunning`.** Use the reactive `sessionFinished: StateFlow<Boolean>`.

6. **`claude-wrapper.js` canonical source is `app/src/main/assets/claude-wrapper.js`.** Edit this file directly.

## Native UI Bridge Pattern (Deferred)

For IPC handlers that need native Android UI (file picker, folder picker, QR scan):
1. SessionService creates `CompletableDeferred<T>`
2. Calls Activity callback (e.g., `onFolderPickerRequested`)
3. MainActivity shows Compose dialog or ActivityResultContract
4. Result calls `deferred.complete(value)`
5. SessionService awaits, responds via WebSocket

## Testing

`cd youcoded && ./gradlew test` for unit tests. `./gradlew assembleDebug` for APK. Remember to run `./scripts/build-web-ui.sh` first or the APK launches with a blank WebView.

## Key files
See `docs/android-runtime.md` table for full reference. Most critical: `Bootstrap.kt`, `SessionService.kt`, `PtyBridge.kt`, `LocalBridgeServer.kt`, `assets/claude-wrapper.js`.
