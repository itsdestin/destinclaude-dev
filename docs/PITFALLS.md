# Pitfalls & Architectural Invariants

Every item here is a lesson learned the hard way or a constraint that's invisible from reading code alone. Violating these silently breaks things.

## Cross-Platform (Desktop + Android)

- **`preload.ts` and `remote-shim.ts` must expose the same SHARED `window.claude` shape.** If one has a shared API the other lacks, React crashes on that platform. Intentional exceptions: `window.claude.window` (Electron-only, for minimize/maximize/close) and `window.claude.android` (Android-only).
- **Desktop handlers return raw values; Android wraps in JSONObject.** The shim must normalize both to a consistent shape before React sees them.
- **Message type strings must be identical across preload.ts, ipc-handlers.ts, and SessionService.kt.** A typo silently fails on one platform.
- **`build-web-ui.sh` MUST run before Android APK builds** or the Android app launches with a blank WebView.

## Chat Reducer

- **`toolCalls` Map is never cleared.** ToolCards need old results for display. Use `activeTurnToolIds` (a Set) for current-turn status checks, not the full Map.
- **Always use `endTurn()` helper when adding turn-ending code paths.** Don't manually clear `isThinking`, `streamingText`, `currentTurnId`, `attentionState`, etc. — `endTurn()` handles all of them consistently. `SESSION_PROCESS_EXITED` is the one handler that spreads `endTurn()` and then overrides `attentionState: 'session-died'`.
- **Dedup is content-based, not flag-based.** There is no `optimistic` flag. Both `USER_PROMPT` and `TRANSCRIPT_USER_MESSAGE` compare content against the last 10 timeline entries. Legitimate rapid-fire identical messages can be suppressed — known limitation.
- **`attentionState` is classifier-driven, not timer-driven.** The 30s `thinkingTimedOut` flag is gone. `useAttentionClassifier` reads the xterm buffer every 1s and dispatches `ATTENTION_STATE_CHANGED`; transcript events + `PERMISSION_REQUEST` reset it to `'ok'`. **Classifier patterns in `attention-classifier.ts` are Claude Code CLI-version sensitive** — regex drift is the most likely source of banner false positives/negatives. Keep the version-anchor comment current and treat it like a dated fixture.

## Android Runtime

- **`LD_LIBRARY_PATH` is mandatory. DO NOT remove.** Termux binaries are relocated from `/data/data/com.termux/files/usr` to `context.filesDir/usr`; `DT_RUNPATH` baked into binaries is stale.
- **All binaries route through `/system/bin/linker64`** for SELinux W^X bypass. Three layers with distinct roles: LD_PRELOAD for C/Rust, claude-wrapper.js for runtime quirks, linker64-env.sh for Go binaries.
- **`TMPDIR` points to `$HOME/.cache/tmpdir`, not `$HOME/tmp`.** The specific path avoids Termux Node.js's compiled-in `/tmp` rewriting double-applying. Don't "fix" it to `$HOME/tmp`.
- **Use the linker variant of `termux-exec`.** Bootstrap copies `libtermux-exec-linker-ld-preload.so` over the primary `.so` after install.
- **Runtime fixes must work in BOTH `PtyBridge` and `DirectShellBridge`.** Both share `Bootstrap.buildRuntimeEnv()` and `Bootstrap.deployBashEnv()` — fix once, applies everywhere.
- **DO NOT poll `isRunning`.** Use the reactive `sessionFinished` `StateFlow` (fed by JNI waitpid thread).
- **`claude-wrapper.js` canonical source is `app/src/main/assets/claude-wrapper.js`.** Edit this file directly. It's deployed to `~/.claude-mobile/` at every launch.

## Toolkit & Hooks

- **Never edit hooks in `settings.json` directly — update `hooks-manifest.json`.** During `/update`, the manifest is merged into settings.json. Direct edits get overwritten.
- **`.sh` files MUST have execute bit set.** On Windows, Git does not set this automatically. Use `git update-index --chmod=+x path/to/file.sh`. Missing execute bit is the #1 cause of "hook does nothing" bugs.
- **`config.json` is portable, `config.local.json` is machine-specific.** config.local.json is rebuilt every session by session-start.sh — don't sync it.
- **Feature work requires `git worktree add`**, not `git checkout -b`, in the main plugin dir. `worktree-guard.sh` blocks branch switches.

## Sync Warnings

- **`~/.claude/.sync-warnings.json` is the authoritative sync warning file.** It holds a typed `SyncWarning[]` array consumed by SyncPanel, StatusBar chips, and the gear-icon red dot. The legacy string-code `~/.claude/.sync-warnings` is still written by bash `statusline.sh` for the terminal statusline — the desktop app no longer writes or reads that file.
- **Two writers, non-overlapping codes.** `runHealthCheck()` owns `OFFLINE`, `PERSONAL_NOT_CONFIGURED`, `PERSONAL_STALE`, `SKILLS_UNROUTED`, `PROJECTS_UNSYNCED`. Push methods (`pushDrive`/`pushGithub`/`pushiCloud`) own per-backend codes (`CONFIG_MISSING`, `AUTH_EXPIRED`, `QUOTA_EXCEEDED`, `NETWORK`, `RCLONE_MISSING`, `UNKNOWN`). Every push-path warning has a `backendId`; health-check ones don't. If you add a new code, pick an owner — the health-check merge replaces only its own codes on every run, so a push-path-owned code must never appear in `runHealthCheck`.
- **`.sync-error-<backendId>` is retired.** The old per-backend error file format is deleted on startup by `SyncService.cleanupStaleBackendErrorFiles()`. Do not reintroduce that file. All per-backend error state now lives in `.sync-warnings.json` entries keyed by `backendId`.
- **Push-failure warnings are non-dismissible.** `dismissWarning()` enforces `dismissible: false` server-side — the UI's dismiss button is hidden for those, but even if it weren't, the server rejects the call. That's deliberate: silencing "Google Drive isn't connected" risks data loss. Don't add a force-dismiss path.
- **Remove a backend → clear its warnings.** `removeBackend()` calls `clearWarningsByBackend(id)` after removing the backend from config. Skipping this leaves a phantom warning with no way to dismiss (the backend it pointed to is gone).
- **Classifier stderr patterns are version-sensitive.** `sync-error-classifier.ts` uses rclone-version-sensitive substring matches. When rclone changes its error messages (major version bumps), patterns can silently drop to `UNKNOWN`. The test file is the source of truth for what stderr each code matches — keep it alongside any pattern change.

## PTY Writes (Desktop + Android)

Pasting multi-paragraph text into Claude Code from YouCoded exposes two stacked PTY bugs. Both were debugged end-to-end in a session where a 2584-char paste was losing paragraphs silently; fixes live in `desktop/src/main/pty-worker.js` (case `'input'`) and `app/.../runtime/PtyBridge.kt` (`writeInput`).

- **Atomic write-then-Enter is broken.** Claude Code's Ink framework has a 500ms `PASTE_TIMEOUT`. Any write ≥2 chars is treated as a paste event; if that write ends in `\r`, Enter gets absorbed into the paste and the message never submits. **Fix: split `content + trailing \r` into two writes with a 600ms gap.** The 600ms must exceed 500ms so Enter arrives as a distinct keystroke after paste mode closes.
- **Windows ConPTY drops bytes on large single writes.** Its input buffer silently drops data when a write exceeds capacity (symptom: paste >~600 chars → only the tail reaches Claude, head-truncated). Single-write workarounds like bracketed paste (`\x1b[200~...\x1b[201~`) do NOT solve this — the wrapper bytes count toward the same buffer. **Fix: chunk writes >64 bytes into 64-byte pieces with 50ms gaps.** The gap must stay < Ink's 500ms PASTE_TIMEOUT so the chunks are treated as one paste. Larger chunks (128/30ms, 256/10ms) drop middle sections intermittently — 64/50ms was the smallest/slowest config that reliably delivered 2500+ chars in manual testing. Expect ~2s of latency for a 3000-char paste; that is the cost of reliable delivery on ConPTY.
- **Diagnosing at the boundaries: renderer → main → worker → node-pty → ConPTY → Claude.** Bytes survive cleanly through the JS layers (Electron IPC has no practical size limit). Truncation always happens in the last hop. If you need to confirm where a specific loss occurs, instrument `session-manager.sendInput()` and the worker's `case 'input'` with length + head/tail logs — Ink's UI redraws hide side-channel banners emitted via `process.send({type:'data'})`, so route length diagnostics through `console.log` on the main side instead. Ask Claude to list distinct markers (`A-START`, `B-START`, …) in the last user message to confirm end-to-end delivery.
- **Android is not affected by (B).** Termux's Linux PTY does not have a ring-buffer limit. `PtyBridge.writeInput` only implements the 600ms split for (A); it does not chunk.
- **Bracketed paste was tried and failed historically** (commit `e54faa3`) because Windows ConPTY interferes with escape sequences. Do not reintroduce it as a "clean" alternative to chunking — the escapes arrive but the byte loss still happens inside ConPTY.

## Releases

- **Bump `versionCode` AND `versionName` in `app/build.gradle.kts` BEFORE tagging.** Play Store requires `versionCode` to be monotonically increasing; CI cannot derive it from the tag.
- **Desktop version is from the git tag**, not `package.json`. CI patches `package.json` during build.
- **Auto-tag for toolkit triggers on `plugin.json` version changes** on master. Bump the root `plugin.json` (not layer plugin.json files) — the root version drives releases.
- **Release skill (`youcoded-admin`) only handles toolkit releases currently.** youcoded multi-repo coordination needs rework — see memory entry `project_release_rework`.
- **v2.3.0 lessons**: auto-tag was fragile, hooks were untested, spec gaps existed, protocol parity blind spots broke cross-platform features. See memory `project_release_lessons_2_3_0`.

## Plugin Installation & Claude Code Registries

- **Claude Code v2.1+ does NOT filesystem-scan `~/.claude/plugins/`.** Its plugin loader (`GD_` in the binary) iterates `enabledPlugins` from `settings.json` only. Dropping files into `~/.claude/plugins/<id>/` without writing the four registries leaves the plugin invisible to the CLI — `/reload-plugins` will report "0 new plugins."
- **Four registries must be written for a plugin to load.** `ClaudeCodeRegistry` (`src/main/claude-code-registry.ts`) handles all four atomically: (1) `~/.claude/settings.json` → `enabledPlugins["id@youcoded"]: true`, (2) `~/.claude/plugins/installed_plugins.json` → v2 entry with absolute `installPath`, (3) `~/.claude/plugins/known_marketplaces.json` → marketplace source config, (4) `~/.claude/plugins/marketplaces/youcoded/.claude-plugin/marketplace.json` → plugin manifest list. Always call `registerPluginInstall()` / `unregisterPluginInstall()` — don't write these files by hand.
- **Plugin install location is `~/.claude/plugins/marketplaces/youcoded/plugins/<id>/`.** The marketplace subtree lives under the plugin cache dir (`~/.claude/plugins/`), NOT directly under `~/.claude/`. The non-cache loader (`t71`) computes the path as `<marketplaceInstallLocation>/<source>` and errors if that directory doesn't exist. Two exceptions sit OUTSIDE the marketplace subtree: (a) the core toolkit at `~/.claude/plugins/youcoded-core/` (cloned by `youcoded-core/bootstrap/install.sh`, not via the plugin installer), and (b) legacy top-level installs for other Claude-Code-installed plugins.
- **Reconcilers must scan both roots.** `listInstalledPluginDirs()` in `claude-code-registry.ts` enumerates top-level children of `~/.claude/plugins/` (for the core toolkit clone) AND direct children of `YOUCODED_PLUGINS_DIR` (for marketplace-installed packages). Scanning only one misses half the installed plugins — this was the decomposition-v3 reconciler bug.
- **`installed_plugins.json` lives at `~/.claude/plugins/installed_plugins.json`** (inside the plugin cache dir). Historical commentary said `~/.claude/installed_plugins.json`; that was the pre-v2.1 location and is wrong for current Claude Code.

## Header Bar

- **Do not add `min-w-0` to the left cluster in `HeaderBar.tsx`.** It makes the column collapse below the settings gear's `shrink-0` width, which lets SessionStrip paint over the gear. The left and right `flex-1` columns must stay symmetric — both omit `min-w-0`. If you need to truncate something inside, put `min-w-0` on the individual child, not the flex parent.
- **Header layout is space-aware, not viewport-aware.** The session strip uses `packSessions()` + ResizeObserver; the chat/terminal toggle labels follow a measured 560 px threshold on the header's own `clientWidth`. Do not reintroduce `@media`, `hidden sm:`, or `window.innerWidth` checks in header children — they lie when the app window is narrow but the viewport is wide, which is the default state on desktop.
- **Chat/terminal toggle placement is platform-conditional.** On macOS the toggle is in the right cluster; on Windows/Linux it's in the left cluster. Balances the opposite-side OS window controls (traffic lights on Mac, caption buttons on Win/Linux). Do not hardcode to one side. The gamepad pill and caption buttons stay in the right cluster on all platforms — only the chat/terminal toggle moves.
- **Announcement lives in StatusBar.** A `announcement` widget in the "Updates" category. Do not re-thread announcement into HeaderBar — the status bar has room and user-toggleable widgets; the header does not.

## Overlays (Popups, Modals, Drawers)

- **Use `<Scrim>` and `<OverlayPanel>` from `components/overlays/Overlay.tsx`** — don't hardcode `bg-black/40`, `bg-canvas/60`, `backdrop-blur-sm`, `shadow-xl`, `rounded-xl`, or arbitrary z-indexes. The primitives pull scrim color, blur, surface background, shadow, and z-index from theme tokens automatically. Anchored popovers (dropdowns, context menus) that don't need a scrim can use `.layer-surface` class directly.
- **Pick a layer, not a z-index.** L1 = drawers (z 40/50), L2 = popups (z 60/61), L3 = destructive (z 70/71), L4 = system (z 100). See `docs/shared-ui-architecture.md` "Overlay Layer System".
- **SessionStrip dropdown at `z-[9000]` is load-bearing.** `.header-bar`'s `backdrop-filter` creates a stacking context that traps lower values. Don't "fix" it.
- **Glassmorphism is automatic and var-driven.** `.layer-surface` reads `--panels-blur` / `--panels-opacity` directly (always set by theme-engine, defaults `0px` / `1`). No `[data-panels-blur]` attribute gate exists — blur and opacity are independent knobs. Reduced-effects forces `--panels-blur: 0` but preserves the user's opacity intent. No per-component handling required.

## Cloudflare Workers (Marketplace Backend)

Gotchas discovered shipping `wecoded-marketplace/worker/` — the Cloudflare Worker backing marketplace install counts and ratings.

- **Never put a key in both `[vars]` and `wrangler secret put` with the same name.** On every `wrangler deploy`, the var from wrangler.toml wins and silently clobbers the secret. Symptom: OAuth breaks in prod because `GH_CLIENT_ID` ends up as the literal placeholder string from wrangler.toml instead of the real secret. **Fix:** leave the key entirely out of wrangler.toml — define it ONLY as a secret. The missing-var pattern is load-bearing; don't "helpfully" add a placeholder.
- **In CI, `wrangler deploy` must run BEFORE `wrangler secret put`.** Deploy reconciles the Worker's bindings to wrangler.toml, removing stale vars left by earlier deploys. If a stale var with the same name exists when you try `secret put`, Cloudflare errors with "Binding name already in use" (code 10053). The safe order is: `migrations apply --remote` → `deploy` → `secret put`. Don't swap deploy to last.
- **`[env.test]` wrangler section is required to run tests against miniflare with `@cloudflare/vitest-pool-workers` 0.5.x.** It can't resolve wrapped bindings like `[ai]`; the test env must omit AI entirely. Consequence: any code path that depends on `env.AI` must fail open or be test-covered another way. The `test/setup.ts` trick of mutating `env` does NOT propagate to `c.env` inside the running worker — set test vars via `[env.test.vars]` in wrangler.toml instead.
- **Rate limits via the Cache API are per-colo, not global.** `checkRateLimit()` uses `caches.open("rl")` which is edge-local. For casual abuse prevention this is fine; for true global throttling you'd need a Durable Object or D1-backed counter.

## Documentation Drift

- **These pitfalls/invariants age with the code.** Code changes but docs don't always follow. Run `/audit` periodically (or before releases) to verify every claim against current source. The audit produces concrete fix instructions for each drift it finds.
- **Add entries to `docs/knowledge-debt.md`** when you notice drift mid-session but can't fix it immediately. The session-start hook surfaces a reminder when entries exist.
- **Update `last_verified` frontmatter** on rules and docs after confirming they still match code. Stale-detection uses this date.

## Working With Destin

- **"Merge" means merge AND push to origin.** Don't stop at a local merge.
- **Always sync before working.** `git fetch origin && git pull origin master` in every repo you'll touch. Prevents working against stale state.
- **Annotate non-trivial code edits with a WHY comment.** Destin is a non-developer and relies on comments to understand what code does and why it was changed. Example: `// Fix: prevent stale tool IDs from coloring the status dot`.
- **Verify fix consequences before shipping.** Batch fixes — especially network/permission changes — can silently break cross-cutting features. Check both platforms.
