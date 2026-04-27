# CLAUDE.md

Workspace guidance for Claude Code. Subsystem details live in `docs/` and `.claude/rules/` — loaded only when relevant.

## Workspace Setup

**On first session**, run `bash setup.sh` from the project root to clone all repos. On subsequent sessions, run it again to pull the latest from each repo's default branch. Do this before any other work.

**Sub-repo code changes go to the relevant sub-repo** (e.g., `youcoded/`, `youcoded-core/`, `wecoded-themes/`, `wecoded-marketplace/`) — open PRs there, push there. Do NOT mix sub-repo code into the workspace repo (`youcoded-dev`).

**Workspace-level artifacts DO get committed + pushed to `youcoded-dev`.** That includes:
- Cross-cutting docs that span multiple sub-repos: `docs/PITFALLS.md`, `docs/android-runtime.md`, `docs/chat-reducer.md`, `docs/shared-ui-architecture.md`, `docs/registries.md`, `docs/build-and-release.md`, `docs/knowledge-debt.md`, etc.
- This `CLAUDE.md` and any rule files under `.claude/rules/`.
- Specs / plans / investigations under `docs/superpowers/` (the artifacts produced by brainstorming, writing-plans, and similar skills before any sub-repo code changes).
- Dev tooling under `scripts/` — `run-dev.sh`, `run-sandbox.sh`, `cdp-eval.mjs`, etc.
- The workspace's own `.gitignore`, `setup.sh`, and skill marketplace pointers under `.claude/`.

## About This Project

YouCoded is an open-source cross-platform AI assistant app built entirely without coding experience using Claude Code. The creator (Destin) is a non-developer — the entire ecosystem is built and maintained through conversation with Claude.

**What YouCoded is:** A hyper-personalized AI assistant app for students, professionals, and anyone who uses AI regularly. Users sign in with their Claude Pro or Max plan (no API key needed). It runs on Windows, macOS, Linux, Android, and via remote web access.

**Core pillars:**
- **Social AI** — share custom themes and skills with friends/classmates/coworkers, play multiplayer games while waiting for Claude to work
- **Personalization** — community plugins (journaling, personal encyclopedia, task inbox, text messaging) install from the WeCoded marketplace; cross-device sync is built into the app
- **Accessibility** — designed for non-technical users, not just developers. You can build things within this app using just conversation

**The app is the product.** Everything else — themes, skill marketplace, bundled plugins — supports the app. Documentation and code should reflect that hierarchy.

## Workspace Layout

| Directory | Repo | What it is |
|-----------|------|------------|
| `youcoded/` | itsdestin/youcoded | **The app** — Desktop (Electron) + Android (Kotlin), skill marketplace UI, themes, multiplayer games |
| `wecoded-marketplace/` | itsdestin/wecoded-marketplace | Skill marketplace registry + Cloudflare Worker backend |
| `wecoded-themes/` | itsdestin/wecoded-themes | Community theme registry |
| `youcoded-core/` | itsdestin/youcoded-core | A bundled Claude Code plugin (being deprecated — see `docs/superpowers/plans/2026-04-21-deprecate-youcoded-core.md`) |
| `youcoded-admin/` | itsdestin/youcoded-admin | Owner-only release and announcement skills |

## Cross-Repo Relationships

- **youcoded** is the main product. It contains `desktop/` (Electron app) and `app/` (Android app) side by side.
- **wecoded-marketplace** and **wecoded-themes** are the registries the app fetches at runtime from raw GitHub URLs. Community plugins live here.
- **Bundled plugins** — `youcoded-core`, `wecoded-themes-plugin`, and `wecoded-marketplace-publisher` ship with the app and are auto-installed on launch (see `youcoded/desktop/src/shared/bundled-plugins.ts` + `BundledPlugins.kt`).
- **youcoded-core** is the oldest bundled plugin, installed at `~/.claude/plugins/youcoded-core/`. It contributes hooks (write-guard, session-start) and two setup skills. Being deprecated — `write-guard` is moving into the app natively, and the repo will eventually be archived.
- **youcoded-admin** release skill orchestrates coordinated releases across repos.

## Working Rules

**Always sync before working.** Before changes, plans, or investigations, pull the latest:
```bash
cd <repo> && git fetch origin && git pull origin master
```

**Use worktrees for non-trivial work.** Any work beyond a handful of lines must be done in a separate git worktree (or use the Agent tool with `isolation: "worktree"`). This prevents multiple concurrent Claude sessions from overwriting each other's changes.

**Annotate non-trivial code edits with a WHY comment.** Destin is a non-developer and relies on comments to understand what code does and why it was changed. Example: `// Fix: prevent stale tool IDs from coloring the status dot`. This is critical for long-term maintainability.

**"Merge" means merge AND push.** Don't stop at a local merge.

**Pushing to master green-lights closing the dev server.** If you started `bash scripts/run-dev.sh` to verify a change, shut it down (plus any helper Electron processes) once the commit lands on `origin/master`. Don't leave it running unless the user explicitly asks — orphaned Vite servers hold port 5223 and trip up the next session's dev launch.

**Clean up worktrees after merging to master.** Once a feature branch is merged and pushed, remove its worktree and delete the branch:
```bash
git worktree remove <path>
git branch -D <branch>   # -D (not -d) because --no-ff merges leave the tip non-ancestral
```
Verify the commit landed on master first: `git branch --contains <sha>` should list `master`. Leaving stale worktrees around accumulates cruft and confuses future sessions about what's in-flight.

**Verify fix consequences before shipping.** Batch fixes — especially network/permission changes — can silently break cross-cutting features. Check both platforms (desktop + Android) after any IPC change.

## Development Workflow

Release builds happen through GitHub Actions CI in the relevant sub-repo. For iterating on desktop changes locally alongside Destin's installed/built app:

```bash
bash scripts/run-dev.sh
```

This shifts every port youcoded uses (Vite 5173 → 5223, remote server 9900 → 9950) and splits Electron `userData` into a separate dir so the dev instance coexists with a running built app. See `docs/local-dev.md` for what's isolated, what's shared (`~/.claude/`), and the caveats.

### ToolCard sandbox

When iterating on `ToolCard` / `ToolBody` view designs in the renderer, skip the live-session loop by running `bash scripts/run-sandbox.sh`. It launches the same dev instance as `run-dev.sh` but boots the Electron window directly into `?mode=tool-sandbox`, where every `.jsonl` fixture in `youcoded/desktop/src/renderer/dev/fixtures/` renders as a real `<ToolCard>`. Edit `ToolBody.tsx` view functions and Vite HMR updates the page within ~1 second. Only touches the renderer; no PTY or transcript side effects.

### CDP eval (live renderer inspection)

`scripts/cdp-eval.mjs` is a one-shot Chrome DevTools Protocol eval helper. Use it to inspect or poke a live React renderer — most often the Android WebView while a debug APK is running on a device. Header comment in the script has the full adb-forward + page-discovery recipe; the short form:

```bash
adb shell ps -A | grep com.youcoded            # find the dev or release PID
adb forward tcp:9222 localabstract:webview_devtools_remote_<PID>
curl -s http://localhost:9222/json             # copy webSocketDebuggerUrl
node scripts/cdp-eval.mjs '<wsUrl>' "(() => ({ url: location.href, vm: document.documentElement.dataset.viewMode }))()"
```

Used during the Tier 2 android-xterm-webview dogfood pass to read xterm scrollback live, trace the byte stream into `terminal.write`, and pinpoint the visible black gap above the InputBar without rebuilding.

For Claude sessions that need to verify code compiles or run tests locally:

```bash
# Desktop
cd youcoded/desktop && npm ci && npm test && npm run build

# Android (requires Desktop React UI built first)
cd youcoded && ./scripts/build-web-ui.sh && ./gradlew assembleDebug && ./gradlew test
```

See `docs/build-and-release.md` for full build order, release flows, and version bumping rules.

## Known Pitfalls

All architectural invariants, cross-cutting gotchas, and lessons learned live in `docs/PITFALLS.md`. **Read it before making non-trivial changes** — it covers IPC parity, chat reducer invariants, Android runtime constraints, bundled-plugin/hooks rules, release gotchas, and working conventions.

## Keeping Documentation Accurate

This workspace's documentation is self-verifying. Run `/audit` to detect drift between docs and current code — produces a report with concrete fix instructions for each drift item. Scope it (`/audit ipc`, `/audit chat`, etc.) for a specific subsystem or run bare for a full sweep.

- Run before any release (prevents shipping with stale docs)
- Run after major refactors touching IPC, reducer, or runtime
- Unresolved findings persist in `docs/knowledge-debt.md`
- Session-start hook surfaces a reminder if `docs/AUDIT.md` is >60 days old or if `knowledge-debt.md` has open entries

If you notice Claude acting on outdated information, or you mention a file/function Claude doesn't recognize, that's the signal to run `/audit`.

## Compaction Guidance

When compacting context (/compact), always preserve:
- The current task objective and success criteria
- Architectural invariants or pitfalls discovered during this session
- File paths of files currently being modified
- Uncommitted work state (what has been changed but not committed)
- Cross-repo dependency context (if working across multiple repos)

Do NOT preserve: full file contents already read, intermediate debugging output, or resolved sub-tasks.

## Subsystem References

Deep context for specific subsystems is loaded automatically via `.claude/rules/` when you touch relevant files. For direct reference:

@docs/shared-ui-architecture.md
@docs/chat-reducer.md
@docs/android-runtime.md
@docs/toolkit-structure.md
@docs/registries.md
@docs/build-and-release.md
@docs/PITFALLS.md
