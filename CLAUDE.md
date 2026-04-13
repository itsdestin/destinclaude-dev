# CLAUDE.md

Workspace guidance for Claude Code. Subsystem details live in `docs/` and `.claude/rules/` — loaded only when relevant.

## Workspace Setup

**On first session**, run `bash setup.sh` from the project root to clone all repos. On subsequent sessions, run it again to pull the latest from each repo's default branch. Do this before any other work.

**All pushes and PRs go to the relevant sub-repo** (e.g., `destincode/`, `destinclaude/`), never to the `destinclaude-dev` repo itself. This repo is only the workspace scaffold.

## About This Project

DestinCode is an open-source cross-platform AI assistant app built entirely without coding experience using Claude Code. The creator (Destin) is a non-developer — the entire ecosystem is built and maintained through conversation with Claude.

**What DestinCode is:** A hyper-personalized AI assistant app for students, professionals, and anyone who uses AI regularly. Users sign in with their Claude Pro or Max plan (no API key needed). It runs on Windows, macOS, Linux, Android, and via remote web access.

**Core pillars:**
- **Social AI** — share custom themes and skills with friends/classmates/coworkers, play multiplayer games while waiting for Claude to work
- **Personalization** — the DestinClaude toolkit adds journaling, a personal encyclopedia, task inbox, text messaging, and cross-device sync
- **Accessibility** — designed for non-technical users, not just developers. You can build things within this app using just conversation

**DestinCode is the product. DestinClaude is the toolkit that supplements it.** Documentation and code should always reflect this hierarchy.

## Workspace Layout

| Directory | Repo | What it is |
|-----------|------|------------|
| `destincode/` | itsdestin/destincode | **The app** — Desktop (Electron) + Android (Kotlin), skill marketplace, themes, multiplayer games |
| `destinclaude/` | itsdestin/destinclaude | **The toolkit** — Claude Code plugin with skills, hooks, commands for personalization |
| `destinclaude-admin/` | itsdestin/destinclaude-admin | Owner-only release and announcement skills |
| `destinclaude-themes/` | itsdestin/destinclaude-themes | Community theme registry |
| `destincode-marketplace/` | itsdestin/destincode-marketplace | Skill marketplace registry |

## Cross-Repo Relationships

- **destincode** is the main product. It contains `desktop/` (Electron app) and `app/` (Android app) side by side.
- **destinclaude** is the plugin toolkit installed at `~/.claude/plugins/destinclaude/`. The app discovers its skills via the filesystem.
- **destinclaude-themes** and **destincode-marketplace** registries are fetched at runtime by both apps from raw GitHub URLs.
- **destinclaude-admin** release skill orchestrates coordinated releases across both repos.

## Working Rules

**Always sync before working.** Before changes, plans, or investigations, pull the latest:
```bash
cd <repo> && git fetch origin && git pull origin master
```

**Use worktrees for non-trivial work.** Any work beyond a handful of lines must be done in a separate git worktree (or use the Agent tool with `isolation: "worktree"`). This prevents multiple concurrent Claude sessions from overwriting each other's changes.

**Annotate non-trivial code edits with a WHY comment.** Destin is a non-developer and relies on comments to understand what code does and why it was changed. Example: `// Fix: prevent stale tool IDs from coloring the status dot`. This is critical for long-term maintainability.

**"Merge" means merge AND push.** Don't stop at a local merge.

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

This shifts every port destincode uses (Vite 5173 → 5223, remote server 9900 → 9950) and splits Electron `userData` into a separate dir so the dev instance coexists with a running built app. See `docs/local-dev.md` for what's isolated, what's shared (`~/.claude/`), and the caveats.

For Claude sessions that need to verify code compiles or run tests locally:

```bash
# Desktop
cd destincode/desktop && npm ci && npm test && npm run build

# Android (requires Desktop React UI built first)
cd destincode && ./scripts/build-web-ui.sh && ./gradlew assembleDebug && ./gradlew test
```

See `docs/build-and-release.md` for full build order, release flows, and version bumping rules.

## Known Pitfalls

All architectural invariants, cross-cutting gotchas, and lessons learned live in `docs/PITFALLS.md`. **Read it before making non-trivial changes** — it covers IPC parity, chat reducer invariants, Android runtime constraints, toolkit/hooks rules, release gotchas, and working conventions.

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
