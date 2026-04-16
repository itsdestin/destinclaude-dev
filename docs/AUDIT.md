# Codebase Audit — 2026-04-11

Verified every claim in workspace CLAUDE.md against actual source code. This document is the authoritative source for all documentation written in Phases 1-4 of the development system improvement plan.

## Audit 0A: Cross-Platform IPC

| Claim | Status | Actual |
|-------|--------|--------|
| Platform detection via `location.protocol === 'file:'` | CONFIRMED | remote-shim.ts:49-51 |
| Android WebSocket on ws://localhost:9901 | CONFIRMED | LocalBridgeServer.kt:22 (`port = 9901`) |
| ~70 bridge message types in handleBridgeMessage() | **CORRECTED** | Actually **92 message types** (SessionService.kt:524+) |
| preload.ts and remote-shim.ts expose same window.claude shape | **NUANCED** | Mostly identical. preload.ts has `window.claude.window` (minimize/maximize/close) which remote-shim lacks — intentional, Electron-specific. remote-shim has `window.claude.android` which preload lacks — also intentional. All shared functionality matches. |
| Protocol: type+id+payload request, type:response+id+payload response | CONFIRMED | remote-shim.ts:63-128, LocalBridgeServer.kt:149-168 |

### Shared window.claude namespaces (both files)
session, on, off, removeAllListeners, skills, marketplace, dialog, shell, remote, model, appearance, defaults, folders, sync, theme, firstRun, zoom, getGitHubAuth, getHomePath, getFavorites, setFavorites, getIncognito, setIncognito

### Platform-exclusive namespaces
- **Electron only** (preload.ts): `window.claude.window` (minimize/maximize/close/onFullscreenChanged)
- **Android only** (remote-shim.ts): `window.claude.android`

---

## Audit 0B: Chat Reducer Architecture

| Claim | Status | Evidence |
|-------|--------|---------|
| toolCalls is a session-lifetime Map, never cleared | CONFIRMED | chat-types.ts:31, reducer clones but never clears |
| activeTurnToolIds tracks current-turn tools as a Set | CONFIRMED | chat-types.ts:43, used at lines 307-309, 351-352, 472-473 |
| endTurn() clears Set and marks orphaned tools as failed | CONFIRMED | chat-reducer.ts:52-69, marks running/awaiting-approval as failed with 'Turn ended' |
| 30s thinking timeout fires only when isThinking && !hasRunningTools && !hasAwaitingApproval | CONFIRMED | ChatView.tsx useEffect, condition logic matches (clause order differs but logic identical) |
| thinkingTimedOut is ephemeral, auto-clears on TRANSCRIPT_TURN_COMPLETE | CONFIRMED | Set true in THINKING_TIMEOUT (line 200), cleared via endTurn() on TRANSCRIPT_TURN_COMPLETE (lines 386-391) |
| Dedup uses optimistic flag — USER_PROMPT marks optimistic, TRANSCRIPT_USER_MESSAGE claims | **OUTDATED** | No `optimistic` flag exists. Both handlers dedup via content matching against last 10 timeline entries. |

### Dedup actual implementation
- USER_PROMPT (lines 101-141): Linear search through last 10 entries comparing `action.content`
- TRANSCRIPT_USER_MESSAGE (lines 209-248): Same approach comparing `action.text`
- No flag-based claiming mechanism — purely content-based dedup

---

## Audit 0C: Android Runtime Constraints

| Claim | Status | Evidence |
|-------|--------|---------|
| LD_LIBRARY_PATH mandatory (Termux binaries relocated, DT_RUNPATH stale) | CONFIRMED | Bootstrap.kt:1538 sets it, lines 1563-1567 explain why |
| All binaries through linker64, three layers: claude-wrapper.js, termux-exec, linker64-env.sh | CONFIRMED | But roles differ from implication — see below |
| No /tmp, use $HOME/tmp via TMPDIR | **CORRECTED** | TMPDIR actually points to `$HOME/.cache/tmpdir` (Bootstrap.kt:1603-1607), not `$HOME/tmp`. Intentional: avoids Node.js compiled-in /tmp rewriting double-applying. |
| claude-wrapper.js canonical at app/src/main/assets/ | CONFIRMED | File exists, line 1-3 states "CANONICAL SOURCE" |
| Use linker variant of termux-exec | CONFIRMED | Bootstrap.kt:407, lines 579-591 copy linker variant over primary |
| Both PtyBridge and DirectShellBridge share buildRuntimeEnv()/deployBashEnv() | CONFIRMED | PtyBridge.kt:106,131 and DirectShellBridge.kt:43,49 |
| Use sessionFinished StateFlow, don't poll isRunning | CONFIRMED | PtyBridge.kt:46-47, no polling patterns found |

### Three-layer architecture (clarified roles)
1. **LD_PRELOAD (termux-exec)**: Intercepts libc execve() in C/Rust programs, routes through linker64
2. **claude-wrapper.js**: NOT exec routing — handles /tmp rewriting, fs.accessSync bypass, shell path fixing, BASH_ENV injection
3. **linker64-env.sh**: Bash function wrappers for Go binaries (gh, fzf, micro) that bypass LD_PRELOAD via raw syscalls + /tmp rewriting helpers

---

## Audit 0D: Toolkit Structure and Hooks

| Claim | Status | Evidence |
|-------|--------|---------|
| Three plugin layers, each with plugin.json | **CORRECTED** | 4 plugin.json files: root (v2.3.2) + core (v0.1.0) + life (v0.1.0) + productivity (v0.1.0). Root is aggregate package. |
| Skills are dirs with SKILL.md, YAML frontmatter description for discovery | CONFIRMED | Verified across setup-wizard, sync, encyclopedia-compile |
| Hooks in core/hooks/hooks-manifest.json | CONFIRMED | 11 hooks across 6 types (SessionStart:2, PreToolUse:3, PostToolUse:2, UserPromptSubmit:1, Stop:2, SessionEnd:1) |
| hooks-manifest.json is desired-state, merged during /update | **CONFIRMED WITH DRIFT** | Manifest declares desired state (comment at line 1-2). But current ~/.claude/settings.json shows only generic relay.js hooks — no merged manifest hooks. Migration may not have run. |
| session-start.sh syncs encyclopedia, checks inbox | CONFIRMED | 44KB script handles config rebuild, sync, encyclopedia, inbox |
| write-guard.sh prevents file conflicts between sessions | CONFIRMED | Same-machine concurrency guard using .write-registry.json |
| worktree-guard.sh guards worktree safety | CONFIRMED | Blocks git checkout/switch in plugin dir, enforces master-only policy |

---

## Audit 0E: Recent Undocumented Changes

### Features added AFTER last CLAUDE.md update (2026-04-07) — NOT documented anywhere:

**youcoded:**
- Unified marketplace integration (merged branch)
- Guided sync setup wizard for non-technical users
- Glass sliders + per-theme CSS overrides system
- Zoom UI (Ctrl+/-, pinch-to-zoom, overlay)
- Android remote settings consolidation (tile/popup)
- Status bar derived metrics (cache hit rate, active ratio, output speed)
- Non-Claude session support (Gemini CLI)

**youcoded-core:**
- Output styles system (conversational, academic, professional)
- Theme builder overhaul (bubble-blur/opacity fields)
- Landing page marketplace showcase

**youcoded-admin:**
- PartyKit deploy verification in release flow
- Plugin.json discovery system

**wecoded-themes:**
- Theme registry with previewTokens (CSS-based card previews)
- Playwright-based preview PNG generator
- /themes/ subdirectory structure with manifest-based asset inclusion

**wecoded-marketplace:**
- Registry restructure: /skills/ and /themes/ directories
- sync.js rewrite with diffing, version tracking, deprecation
- CI validation workflow for community plugin PRs

### Deleted features:
- `rebuild-stats` workflow removed from wecoded-marketplace

### Repos with NO CLAUDE.md:
- youcoded-core/ (toolkit itself)
- youcoded-admin/
- wecoded-themes/
- wecoded-marketplace/

---

## Audit 0F: Build and Release Flow

| Claim | Status | Evidence |
|-------|--------|---------|
| build-web-ui.sh bundles desktop/dist/renderer/ into app/src/main/assets/web/ | CONFIRMED | Script at youcoded/scripts/build-web-ui.sh:14-27, called at android-release.yml:35 |
| Desktop version from git tag, CI patches package.json | CONFIRMED | desktop-release.yml:40-46, strips v prefix and patches |
| Android needs manual versionCode + versionName bump in build.gradle.kts | CONFIRMED | app/build.gradle.kts:23-24, currently versionCode=7, versionName="2.3.2" |
| One vX.Y.Z tag triggers both workflows | CONFIRMED | Both trigger on `v*` pattern, both upload to same release |
| Toolkit: plugin.json version bump on master triggers auto-tag.yml | CONFIRMED | auto-tag.yml compares HEAD vs HEAD~1 version, creates tag |

---

## Summary: What Must Be Corrected in New Docs

1. **Bridge message count**: ~70 -> 92
2. **Dedup mechanism**: Remove optimistic flag claim; document content-matching approach
3. **TMPDIR path**: $HOME/tmp -> $HOME/.cache/tmpdir (intentional)
4. **Plugin layer count**: "three layers" -> "root manifest + three layers (core/life/productivity)"
5. **Three-layer linker64**: Clarify functional roles (LD_PRELOAD for C/Rust, wrapper for runtime quirks, linker64-env.sh for Go)
6. **IPC shape parity**: Document intentional platform-exclusive namespaces (window.* for Electron, android.* for Android)
7. **Hooks drift**: Note that manifest hooks may not be active in settings.json
8. **Many recent features undocumented**: See 0E list above
