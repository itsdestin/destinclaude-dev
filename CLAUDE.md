# CLAUDE.md

## Workspace Setup

**On first session**, run `bash setup.sh` from the project root to clone all repos. On subsequent sessions, run it again to pull the latest from each repo's default branch. Do this before any other work.

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## About This Project

DestinCode is an open-source cross-platform AI assistant app built entirely without coding experience using Claude Code. The creator (Destin) is a non-developer — the entire ecosystem is built and maintained through conversation with Claude.

**What DestinCode is:** A hyper-personalized AI assistant app for students, professionals, and anyone who uses AI regularly. Users sign in with their Claude Pro or Max plan (no API key needed). It runs on Windows, macOS, Linux, Android, and via remote web access.

**Core pillars:**
- **Social AI** — share custom themes and skills with friends/classmates/coworkers, play multiplayer games while waiting for Claude to work
- **Personalization** — the DestinClaude toolkit adds journaling, a personal encyclopedia, task inbox, text messaging, and cross-device sync
- **Accessibility** — designed for non-technical users, not just developers. You can build things within this app using just conversation

**DestinCode is the product. DestinClaude is the toolkit that supplements it.** Documentation and code should always reflect this hierarchy.

## Workspace Layout

This is a multi-repo development workspace. Each directory is its own Git repo.

| Directory | Repo | What it is |
|-----------|------|------------|
| `destincode/` | itsdestin/destincode | **The app** — Desktop (Electron) + Android (Kotlin), skill marketplace, themes, multiplayer games |
| `destinclaude/` | itsdestin/destinclaude | **The toolkit** — Claude Code plugin with skills, hooks, commands for personalization (journaling, encyclopedia, sync) |
| `destinclaude-admin/` | itsdestin/destinclaude-admin | Owner-only release and announcement skills |
| `destinclaude-themes/` | itsdestin/destinclaude-themes | Community theme registry |
| `destincode-marketplace/` | itsdestin/destincode-marketplace | Skill marketplace registry (29 DestinClaude + 122 upstream Anthropic plugins) |

## Cross-Repo Relationships

- **destincode** is the main product. It contains `desktop/` (Electron app) and `app/` (Android app) side by side.
- **destinclaude** is the plugin toolkit installed at `~/.claude/plugins/destinclaude/`. The app discovers its skills via the filesystem.
- **destinclaude-themes** and **destincode-marketplace** registries are fetched at runtime by both apps from raw GitHub URLs.
- **destinclaude-admin** release skill orchestrates coordinated releases across both repos. A single `v*` tag in destincode triggers both Android and Desktop release workflows.

## Shared UI Architecture (Critical)

**Desktop and Android render the same React UI.** This is the most important architectural fact about the project:

- The React app in `desktop/src/renderer/` is the **single source of truth** for the main UI on both platforms.
- On desktop: Electron hosts the React app natively.
- On Android: `WebViewHost.kt` loads the React app from bundled assets (`file:///android_asset/web/`). The React build is generated from the desktop source via `scripts/build-web-ui.sh`.
- Both platforms communicate via the **same WebSocket JSON protocol**. On desktop, the Electron main process handles IPC. On Android, `LocalBridgeServer` (ws://localhost:9901) + `SessionService.handleBridgeMessage()` handles it.
- The React shim (`remote-shim.ts`) detects the platform via `location.protocol === 'file:'` (Android) and routes IPC accordingly.

**What this means in practice:** Most features — themes, session management, skill marketplace, model selector, status bar, folder switcher, settings panel, games — are React components that work on both platforms automatically. Only features requiring native Android APIs (camera/QR, file picker, package bootstrap, tier selection) need Kotlin code. When evaluating feature gaps between desktop and Android, check whether the IPC handler exists in `SessionService.kt` — the UI itself is shared.

## Adding Cross-Platform Features (IPC Pattern)

When adding a feature that needs both React UI and platform backend:

1. **React side** (`desktop/src/renderer/remote-shim.ts`): Add method to `window.claude` object using `invoke('type:name', payload)` (request-response) or `fire('type:name', payload)` (fire-and-forget)
2. **Desktop side** (`desktop/src/main/ipc-handlers.ts`): Add `ipcMain.handle(IPC.CHANNEL, handler)` for request-response, or `ipcMain.on()` for fire-and-forget
3. **Android side** (`app/src/main/kotlin/.../runtime/SessionService.kt`): Add a `when` case to `handleBridgeMessage()` matching the same type string. Respond with `bridgeServer.respond(ws, msg.type, msg.id, payload)` if `msg.id` is present

The message type string (e.g., `"skills:install"`) must be identical across all three files. The WebSocket protocol handles transport — React doesn't need to know which platform it's on.

**Critical**: `preload.ts` and `remote-shim.ts` must expose the **same `window.claude` shape**. If one has an API the other lacks, React components will crash on that platform. When adding features, always update both.

**Response formats**: Desktop handlers return raw values (`string[]`), Android wraps in JSONObject (`{paths: [...]}`). The shim should normalize differences so React sees a consistent shape.

**Protocol format:**
- Request: `{ "type": "...", "id": "msg-1", "payload": {...} }`
- Response: `{ "type": "...:response", "id": "msg-1", "payload": {...} }`
- Push event: `{ "type": "...", "payload": {...} }` (no id, broadcast to all clients)

## Build Order Dependencies

- **`scripts/build-web-ui.sh` MUST run before Android APK builds.** It bundles `desktop/dist/renderer/` into `app/src/main/assets/web/`. If skipped, the Android app launches with a blank WebView.
- **Desktop version comes from git tag**, not package.json. CI extracts version from `vX.Y.Z` tag and patches package.json before building.
- **Android version requires manual bump** of both `versionCode` (integer) and `versionName` (string) in `app/build.gradle.kts` before tagging.
- **One tag, all platforms**: A single `vX.Y.Z` tag in destincode triggers both `android-release.yml` and `desktop-release.yml`. Both workflows upload artifacts to the same GitHub Release.

## DestinClaude Toolkit Structure

The toolkit at `destinclaude/` has three plugin layers, each with its own `plugin.json`:

| Layer | Purpose | Key Skills |
|-------|---------|------------|
| **Core** | Foundation — hooks, setup, sync, themes | setup-wizard, sync, theme-builder, remote-setup |
| **Life** | Personal knowledge — journal, encyclopedia | journaling-assistant, encyclopedia-*, fork-file, google-drive |
| **Productivity** | Task processing, skill creation, messaging | claudes-inbox, skill-creator + MCP servers (imessages, gmessages) |

**Skills** are directories with a `SKILL.md` file. The YAML frontmatter `description` field is how Claude discovers when to invoke them. Skills live in `~/.claude/plugins/destinclaude/` and are symlinked during setup.

**Hooks** are declared in `core/hooks/hooks-manifest.json` (desired-state format). Key hooks:
- `session-start.sh` — syncs encyclopedia, checks inbox
- `sync.sh` (PostToolUse) — backs up data after file changes
- `write-guard.sh` (PreToolUse:Write|Edit) — prevents file conflicts between sessions
- `worktree-guard.sh` (PreToolUse:Bash|Agent) — guards worktree safety

**Commands** are `.md` files in `core/commands/` invoked with `/command-name` (e.g., `/update`, `/health`, `/toolkit`).

**Hooks reconciliation**: During `/update`, the toolkit merges hooks-manifest.json into the user's `settings.json`. New hooks are added, timeouts use the max of user vs manifest values. Never edit hooks directly in settings.json — update the manifest.

## Registries (Marketplace & Themes)

Both registries are GitHub repos fetched at runtime via raw.githubusercontent.com:

**Skill Marketplace** (`destincode-marketplace/`):
- `index.json` — 151 entries (29 DestinClaude + 122 upstream Anthropic)
- Synced from upstream via `scripts/sync.js`. DestinClaude entries (`sourceMarketplace: "destinclaude"`) are never overwritten
- Apps cache for 24 hours at `~/.claude/destincode-marketplace-cache/`
- No CI — registry is rebuilt manually with `node scripts/sync.js`

**Theme Registry** (`destinclaude-themes/`):
- `registry/theme-registry.json` — auto-generated from `themes/{slug}/manifest.json` files
- CI validates PRs (required tokens, CSS safety, size <10MB, slug uniqueness)
- CI auto-rebuilds registry + generates preview PNGs on merge to main
- Themes require 15 CSS tokens: canvas, panel, inset, well, accent, on-accent, fg, fg-2, fg-dim, fg-muted, fg-faint, edge, edge-dim, scrollbar-thumb, scrollbar-hover
- CSS is sanitized: no @import, no external URLs, no expression(), no javascript: URIs

## Chat Reducer Architecture

**Tool activity scoping:** `toolCalls` is a session-lifetime Map (never cleared — ToolCards need old results for display). To prevent stale `running`/`awaiting-approval` entries from old turns affecting status indicators, `activeTurnToolIds` tracks which tools belong to the current turn. All status checks (StatusDot color, ThinkingIndicator visibility, thinking timeout) scan only this Set, not the full Map. The shared `endTurn()` helper in `chat-reducer.ts` clears the Set and marks orphaned tools as failed — always use it when adding a new turn-ending code path.

**Thinking timeout:** A 30s watchdog fires only when `isThinking && !hasRunningTools && !hasAwaitingApproval` (true silence). It sets an ephemeral `thinkingTimedOut` flag rather than injecting permanent text — the flag auto-clears on `TRANSCRIPT_TURN_COMPLETE`.

## Known Issues

- **Chat dedup** — Fixed. Both `USER_PROMPT` and `TRANSCRIPT_USER_MESSAGE` handlers now dedup only against `optimistic: true` timeline entries. `USER_PROMPT` marks entries optimistic; `TRANSCRIPT_USER_MESSAGE` claims them by flipping the flag to false. Identical messages sent at different times no longer collide.

## Working Rules

**Always sync before working.** Before making changes, proposing plans, or investigating problems, pull the latest from origin for every repo you'll touch:
```bash
cd <repo> && git fetch origin && git pull origin master
```

**Use worktrees for non-trivial work.** Any work beyond a handful of lines must be done in a separate git worktree (or use the Agent tool with `isolation: "worktree"`). This prevents multiple concurrent Claude sessions from overwriting each other's changes.

**Annotate code edits.** Bug fixes and important cross-cutting tie-ins must include a brief inline comment explaining the purpose or rationale (e.g., `// Fix: prevent stale tool IDs from coloring the status dot` or `// Ties into WebViewHost platform detection`). This is critical for a non-developer maintainer who relies on comments to understand *why* code was changed, not just *what* changed.

## Development Workflow

Destin does not build locally. All builds happen through GitHub Actions CI:

- **App (all platforms):** Push to destincode repo → tag with `vX.Y.Z` → `android-release.yml` + `desktop-release.yml` both trigger, producing signed APK/AAB + Win/Mac/Linux installers
- **Toolkit:** Push to destinclaude repo → bump plugin.json version → `auto-tag.yml` creates tag

For Claude sessions that need to verify code compiles or run tests locally:

```bash
# Desktop
cd destincode/desktop && npm ci && npm test && npm run build

# Android
cd destincode && ./gradlew assembleDebug && ./gradlew test

# Build Android React UI from desktop source
cd destincode && ./scripts/build-web-ui.sh
```

## Release Flows

**Toolkit (destinclaude):** Bump `version` in `plugin.json` on master → `auto-tag.yml` creates `vX.Y.Z` tag

**App (Desktop + Android):** Tag with `vX.Y.Z` in destincode → `android-release.yml` builds signed APK/AAB + `desktop-release.yml` builds Win/Mac/Linux installers → all artifacts uploaded to one GitHub Release

## Android Runtime Rules

**Note:** `destincode/CLAUDE.md` is NOT for developers — it contains instructions for Claude instances running *inside* the DestinCode mobile app. All development docs belong here or in `destincode/desktop/CLAUDE.md`.

### System Fundamentals

- **`LD_LIBRARY_PATH` is mandatory** — The app relocates Termux binaries from `/data/data/com.termux/files/usr` to `context.filesDir/usr`, so `DT_RUNPATH` is stale. `LD_LIBRARY_PATH` overrides it. Do NOT remove.
- **All binaries route through `/system/bin/linker64`** — SELinux W^X bypass (Android 10+). Three layers enforce this: `claude-wrapper.js` (Node.js), `libtermux-exec-ld-preload.so` (C), `linker64-env.sh` (bash).
- **No `/tmp`** — Use `$HOME/tmp` via `TMPDIR` and `CLAUDE_CODE_TMPDIR`.
- **No glibc** — Bionic only. The `native/execve-interceptor.c` is a research artifact, not deployed.
- **`claude-wrapper.js`** canonical source is `app/src/main/assets/claude-wrapper.js`. Deployed at launch by `Bootstrap.deployWrapperJs()`.
- **Use the linker variant of termux-exec** — Copy `libtermux-exec-linker-ld-preload.so` over `libtermux-exec-ld-preload.so` after installing `termux-exec`.
- **Runtime fixes must work in both PtyBridge and DirectShellBridge** — Both share `Bootstrap.buildRuntimeEnv()` and `Bootstrap.deployBashEnv()`.
- **DO NOT poll isRunning** — Use the reactive `sessionFinished` StateFlow (JNI `waitpid()` thread).

### Native Android UI Bridge Pattern (Deferred)

When an IPC handler needs native Android UI (file picker, folder picker, QR scanner):
1. `SessionService` creates a `CompletableDeferred<T>` and stores it (e.g., `pendingFolderPicker`)
2. `SessionService` calls a callback (e.g., `onFolderPickerRequested`) to notify the Activity
3. `MainActivity` shows the native UI (Compose dialog or ActivityResultContract)
4. On result, `MainActivity` calls `deferred.complete(result)`
5. `SessionService` awaits the deferred and sends the response back via WebSocket

Used by: `dialog:open-file`, `dialog:open-folder`, `android:scan-qr`. Follow this pattern for new native UI features.

### Android Key Files

| File | Purpose |
|------|---------|
| **Shared UI (React → Android)** | |
| `app/.../ui/WebViewHost.kt` | Hosts React UI in WebView, loads bundled web assets |
| `app/.../bridge/LocalBridgeServer.kt` | WebSocket server on :9901, bridges React IPC to Kotlin |
| `app/.../bridge/PlatformBridge.kt` | Android-native operations (file picker, clipboard, URLs) |
| `desktop/src/renderer/remote-shim.ts` | React-side platform detection + WebSocket IPC client |
| **Runtime** | |
| `app/.../runtime/Bootstrap.kt` | Package management, environment setup, shell function generation |
| `app/.../runtime/SessionService.kt` | Main IPC dispatcher — handles all ~70 bridge message types |
| `app/.../runtime/PtyBridge.kt` | Claude Code terminal session (PTY + event bridge) |
| `app/.../runtime/DirectShellBridge.kt` | Standalone bash shell session |
| `app/.../runtime/ManagedSession.kt` | Session lifecycle, status, approval flow, prompt detection |
| `app/.../runtime/SessionRegistry.kt` | Multi-session management |
| **Assets** | |
| `app/.../assets/claude-wrapper.js` | Node.js monkey-patch for SELinux bypass (CANONICAL SOURCE) |
| `app/.../assets/hook-relay.js` | Unix socket event relay for structured hook events |
| **Skills** | |
| `app/.../skills/LocalSkillProvider.kt` | Skill marketplace backend (discovery, install, config, sharing) |
| `app/.../skills/PluginInstaller.kt` | Installs Claude Code plugins via git clone/copy |
| **Native-only screens (Compose)** | |
| `app/.../ui/TierPickerScreen.kt` | First-run package tier selection |
| `app/.../ui/SetupScreen.kt` | Bootstrap progress display |
| `app/.../ui/FolderPickerDialog.kt` | Native folder browser for FolderSwitcher |
