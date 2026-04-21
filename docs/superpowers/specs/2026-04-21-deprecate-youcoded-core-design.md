# Deprecate `youcoded-core` — Design

**Date:** 2026-04-21
**Status:** Approved for plan
**Owner:** Destin
**Scope:** The `youcoded-core` repo, the `youcoded` app repo, and the `youcoded-dev` workspace scaffold

## Goal

Remove `youcoded-core` from YouCoded's architecture. User-facing features already live in the app; the WeCoded marketplace covers plugin distribution; `youcoded-core` is down to safety hooks, setup fallbacks, and specs, most of which are dead weight or duplicates. After this work lands, `youcoded-core` is archived on GitHub, no longer cloned by the app, and no longer referenced by any live code path.

The user-visible promise: **YouCoded = the YouCoded app.** No separate toolkit repo, no separate install path, no separate update cycle.

## Why now

`youcoded-core` currently ships:

- 2 skills (`setup-wizard`, `remote-setup`) — both explicitly fallbacks for CLI-only users. The app owns the real onboarding flow end-to-end.
- 3 slash commands (`/update`, `/health`, `/diagnose`) — all concerned with maintaining the toolkit itself.
- 5 hooks (`session-start`, `write-guard`, `worktree-guard`, `tool-router`, `statusline` in Notification slot). Only `write-guard` has general-purpose value; the rest are either self-referential to the toolkit, superseded by the app's own hooks, or dead code paths.
- Bootstrap scripts for CLI-only install, scripts that migrate toolkit versions, templates that only fed the old setup-wizard, specs that describe defunct subsystems.

Carrying this repo forward means maintaining a clone path, a reconciler-driven hook registration pathway, and ~30 `youcoded-core`-aware branches in the app code — all for a surface that no one uses directly. Deprecating it removes a full repo from the release matrix, simplifies prerequisite installation, and eliminates the "which plugin ships this feature" ambiguity (it's now unambiguously the app).

## Non-goals

- Not changing how marketplace plugins (WeCoded) are installed or distributed. The `HookReconciler` mechanism stays — it's still needed for marketplace plugins that ship their own `hooks-manifest.json`.
- Not migrating away from Claude Code's plugin model. The app continues to integrate with Claude Code's plugin registries exactly as today.
- Not touching the app's own hooks (`relay.js`, `relay-blocking.js`, `title-update.sh`, `statusline.sh`, `usage-fetch.js`). Those were always app-owned.
- Not changing user data (`~/.claude/encyclopedia`, `~/.claude/memory`, `~/.claude/youcoded-*.json` config files) beyond the one config rename noted below.

## Current state reference

Pieces of `youcoded-core/` fall into three buckets after decomposition:

1. **Definitely unused / self-referential:** `setup-wizard/`, `remote-setup/`, `commands/` (all three), `worktree-guard.sh`, `session-start.sh`, `bootstrap/`, `scripts/install-app.sh`, `scripts/post-update.sh`, `scripts/pre-push`, `scripts/migrations/`, `templates/` (all), `data/destintip-catalog.json`, most of `specs/`, `docs/`.
2. **Active but duplicate / obsolete:** `statusline.sh` (Notification slot — app has its own statusline at `settings.statusLine.command`), `tool-router.sh` (gmail/calendar routing — google-services plugin owns this now).
3. **Active with general-purpose value:** `write-guard.sh` (cross-session concurrency guard on tracked files), plus 3–5 specs that describe live app behavior (`write-guard-spec.md`, `remote-access-spec.md`, `statusline-spec.md`, possibly `memory-system-spec.md` and `output-styles-spec.md`).

App code currently clones the repo via `desktop/src/main/prerequisite-installer.ts:cloneToolkit()`, then `hook-reconciler.ts` reads `hooks-manifest.json` and merges the required hooks into `~/.claude/settings.json`. Several other files (`plugin-installer.ts`, `skill-scanner.ts`, `marketplace-file-reader.ts`, `skill-provider.ts`, `sync-service.ts`) have `youcoded-core`-aware branches for historical-reason reasons.

## Design

### 1. Deletions inside `youcoded-core` (before archive)

- **Skills:** `skills/setup-wizard/`, `skills/remote-setup/` — the entire `skills/` dir
- **Commands:** `commands/diagnose.md`, `commands/health.md`, `commands/update.md` — the entire `commands/` dir
- **Hooks:** `hooks/worktree-guard.sh`, `hooks/tool-router.sh`, `hooks/session-start.sh`, `hooks/statusline.sh`, `hooks/hooks-manifest.json`. After moving `write-guard.sh` (see §2), the entire `hooks/` dir can go, including `hooks/lib/` if nothing else sources it.
- **Bootstrap:** `bootstrap/install.sh`, `bootstrap/install.ps1`, `bootstrap/prerequisites.md` — the entire `bootstrap/` dir
- **Scripts:** `scripts/install-app.sh`, `scripts/post-update.sh`, `scripts/pre-push`, `scripts/migrations/` (entire dir including 2.2.0.sh, 2.3.0.sh, README.md), `scripts/security-sweep.sh`, `scripts/security-patterns.txt`, `scripts/excluded-files.txt`. All deleted with the repo. If Destin wants the security-sweep utility preserved personally, he can recover it from git history after archive.
- **Templates:** `templates/` entire dir (claude-md-fragments, memory-skeleton, spec-template.md, template-variables.json)
- **Data:** `data/destintip-catalog.json`, then empty `data/` dir
- **Specs being deleted outright:** `specs/destintip-spec.md`, `specs/worktree-guard-spec.md`, `specs/youcoded-core-spec.md`, `specs/specs-system-spec.md`, `specs/system-architecture-spec.md`, `specs/INDEX.md`. Verify `specs/landing-page-spec.md` — if it describes a live project website, move to an appropriate repo; otherwise delete.
- **Docs:** `docs/` entire dir (all self-describing, superseded by the app's own docs)
- **Metadata:** `plugin.json`, `mcp-manifest.json`, `VERSION`, `.private-manifest`. Keep `LICENSE`, `README.md` (rewritten as tombstone), and `CHANGELOG.md` (historical record).

### 2. Moves into the `youcoded` app repo

| From youcoded-core | To (in youcoded repo) | Notes |
|---|---|---|
| `hooks/write-guard.sh` | `desktop/hook-scripts/write-guard.sh` | Mirrors native-bundled pattern of relay/title-update/statusline |
| `hooks/write-guard.sh` | `app/src/main/assets/write-guard.sh` | Android mirror, same content |
| `hooks/lib/hook-preamble.sh` | `desktop/hook-scripts/hook-preamble.sh` + `app/src/main/assets/hook-preamble.sh` | Only if write-guard.sh actually sources it; otherwise drop |
| `specs/write-guard-spec.md` | `youcoded/docs/write-guard-spec.md` | |
| `specs/remote-access-spec.md` | `youcoded/docs/remote-access-spec.md` | |
| `specs/statusline-spec.md` | `youcoded/docs/statusline-spec.md` | |
| `specs/memory-system-spec.md` | `youcoded/docs/memory-system-spec.md` | Only if still describes live behavior; review at move time |
| `specs/output-styles-spec.md` | `youcoded/docs/output-styles-spec.md` | Only if still describes live behavior; review at move time |

### 3. App-side code changes (`youcoded` repo)

#### 3a. Additions

**Bundle write-guard natively.** In `desktop/scripts/install-hooks.js`, add a registration block for write-guard that follows the same pattern as the existing title-update registration:

- Resolve `rawWriteGuardPath = path.resolve(__dirname, '..', 'hook-scripts', 'write-guard.sh')`
- Apply the `app.asar` → `app.asar.unpacked` substitution for packaged builds
- Apply the existing worktree-safety guard (refuse to write paths inside `.worktrees/`)
- Ensure `settings.hooks.PreToolUse` exists
- Find any existing entry whose command includes `write-guard.sh` and overwrite in place; otherwise append
- Use matcher `"Write|Edit"` and timeout 10 (matches the retired manifest spec)
- Emit a log line similar to the existing "Hooks installed for…" message

**Android mirror.** The Android app bundles hooks under `app/src/main/assets/`. Add `write-guard.sh` there and replicate the registration in whichever Kotlin file owns hook-writing (likely `Bootstrap.kt` or `SessionService.kt` — the existing `title-update.sh` / `statusline.sh` registration path is the template).

**Active cleanup routine.** Add a one-shot cleanup that runs at app launch, before `reconcileHooks()`. It deletes `~/.claude/plugins/youcoded-core/` if the directory exists, logs the deletion through the existing app logger, and swallows errors (missing dir, permission issues, etc. — non-fatal). The subsequent `reconcileHooks()` invocation's `pruneDeadPluginHooks()` pass automatically strips the orphaned `settings.json` entries once the directory is gone.

Location: a new small module, e.g., `desktop/src/main/legacy-cleanup.ts`, invoked from the same startup site as `reconcileHooks()`. Android equivalent in `Bootstrap.kt` alongside the existing bootstrap steps.

#### 3b. Removals

Dead-branch removal is staged (see §5 rollout). The full list of touchpoints to clean:

- `desktop/src/main/prerequisite-installer.ts` — delete `cloneToolkit()` (lines ~440–483), delete `detectToolkit()` (lines ~253–269), remove the `'youcoded-core'` entry from the prerequisite list (line ~260). The `VERSION`-file detection of an installed toolkit also goes.
- `desktop/src/main/plugin-installer.ts` — delete the `sourceMarketplace === 'youcoded-core'` branches (lines 53, 60). `'youcoded'` branches stay.
- `desktop/src/main/skill-scanner.ts` — delete the `inferredSource: 'youcoded-core'` type member and associated branches (~lines 31, 83, 89, 140, 155). Skill discovery continues via marketplace-plugin paths only.
- `desktop/src/main/marketplace-file-reader.ts` — remove the comments and depth-4 walk tuning for `core/skills`, `life/skills`, `productivity/skills` layered prefixes. The glob logic can simplify now that only marketplace plugins populate the tree.
- `desktop/src/main/skill-provider.ts` — remove the youcoded-core clone-path precedence. Rename `~/.claude/youcoded-config/youcoded-core-output-styles.json` to `~/.claude/youcoded-config/youcoded-output-styles.json`. Add a one-time migration read: on load, if the new filename doesn't exist but the old one does, read the old file and write the new filename, then delete the old. Keep this migration for 2–3 releases then remove it.
- `desktop/src/main/sync-service.ts` — delete the dedup branches that walk "any youcoded-core-prefixed plugin" (lines ~1962–1985). The dedup logic survives with the prefix check narrowed to just `youcoded/` or wherever marketplace plugins live.
- `desktop/src/main/hook-reconciler.ts` — update the stale docstring references to `youcoded-core` paths (line 57, the comment about `core/hooks/` vs `hooks/` decomposition). The mechanism itself stays.
- `desktop/src/shared/bundled-plugins.ts` and `app/src/main/kotlin/com/youcoded/app/skills/BundledPlugins.kt` — remove `youcoded-core` from `BUNDLED_PLUGIN_IDS` if present (per PITFALLS, these must stay in sync between platforms).
- `app/src/main/kotlin/com/youcoded/app/runtime/Bootstrap.kt` — remove any clone-from-git or copy-from-bundle logic targeting `youcoded-core`.

#### 3c. Test updates

- `desktop/tests/hook-reconciler-prune.test.ts` — any fixture that seeds `~/.claude/plugins/youcoded-core/` needs updating. The prune behavior itself is unchanged, but the test data should model a post-deprecation world.
- `desktop/tests/skill-scanner.test.ts` — remove `inferredSource: 'youcoded-core'` test cases.
- `desktop/tests/symlink-cleanup.test.ts` — verify no dependency on toolkit layout; adjust fixtures if present.
- `desktop/tests/transcript-watcher.test.ts` — scan for any incidental youcoded-core mention.
- Add a test for the new legacy-cleanup routine: given a seeded `~/.claude/plugins/youcoded-core/` directory, the routine deletes it and `reconcileHooks()` produces `{ pruned: N }` where N reflects the prior hook count.

### 4. User migration

**Design:** active cleanup on app launch. No opt-in, no prompt.

**What happens:** The first time a user runs the new app version:

1. `legacyCleanup()` runs in app startup, detects `~/.claude/plugins/youcoded-core/`, deletes it recursively, logs the deletion.
2. `reconcileHooks()` runs as usual; `pruneDeadPluginHooks()` strips the now-orphaned `settings.json` entries for `session-start.sh`, `write-guard.sh` (old path), `worktree-guard.sh`, and anything else pointing into the deleted directory.
3. `installHooks()` registers the new native-bundled `write-guard.sh` on `PreToolUse`. Users keep their concurrency guard continuously — there's no gap.
4. Next session start: settings.json is clean, only native-bundled hooks are registered, no youcoded-core directory on disk.

**Edge cases considered:**

- **User customized a file inside `youcoded-core/`:** it's lost. Acceptable — the repo was never meant to be user-edited, and the customization would have been overwritten on any `/update` anyway.
- **User's `settings.json` has manually-added hooks pointing into `youcoded-core/`:** they get pruned by `pruneDeadPluginHooks()` (already behaves this way today; it only prunes entries whose script *file* is missing, and prefers paths *owned* by a plugin root). If Destin has customized one and it's load-bearing, he'll know and can restore manually from the archived repo.
- **Cleanup fails (perms, mount issues):** non-fatal. Legacy directory sits, hooks keep running their old scripts until manual cleanup. Diagnostic log captures the failure.
- **User was already on a release without the cleanup but without the clone:** the old directory persists from an even earlier version. The cleanup still catches it on first launch of the new version. Same outcome.

### 5. Rollout ordering

To keep the app tolerant of `~/.claude/plugins/youcoded-core/` existing during the transition, ship the change in **two releases**:

**Release N — additive + cleanup:**
- Add native-bundled `write-guard.sh` (desktop + Android)
- Add `legacy-cleanup.ts` and wire into startup
- Remove `cloneToolkit()` and `detectToolkit()` from `prerequisite-installer.ts` — new users won't get the clone
- Leave all other `youcoded-core`-aware branches in place (plugin-installer, skill-scanner, sync-service, marketplace-file-reader). They're no-ops when the directory doesn't exist, so they don't break anything; they just become dead code temporarily.

**Release N+1 — dead-branch cleanup** (after N has been live long enough that Destin has run it on his own machine without issues — typically a week or two):
- Remove all remaining `youcoded-core`-aware branches from plugin-installer, skill-scanner, sync-service, marketplace-file-reader, skill-provider, hook-reconciler docstrings
- Remove `youcoded-core` from `BUNDLED_PLUGIN_IDS` if present
- Keep the config-filename migration in `skill-provider.ts` (2–3 more releases)

**Post-N+1 — repo archive:**
- Delete the files inside `youcoded-core` per §1
- Move specs per §2
- Rewrite `README.md` as a tombstone pointing to the app
- Add `DEPRECATED.md`
- Archive the repo on GitHub

### 6. Workspace scaffold (`youcoded-dev`) cleanup

The workspace repo references `youcoded-core` across many files. Either land these alongside Release N, or as a sibling cleanup PR after N lands — doesn't matter functionally, but stale docs mislead future Claude sessions.

- `setup.sh` — remove `youcoded-core` from the clone list
- `CLAUDE.md` — remove the row from the workspace layout table; update "Cross-Repo Relationships"; drop references in working-rules examples
- `docs/toolkit-structure.md` — delete
- `docs/registries.md` — scan for stale references, prune
- `docs/build-and-release.md` — remove the "Toolkit (youcoded-core)" release flow section
- `docs/PITFALLS.md` — prune `youcoded-core` mentions in the Toolkit & Hooks section, the Plugin Installation section, the Announcements section, and anywhere else it appears
- `.claude/rules/youcoded-toolkit.md` — delete
- `.claude/skills/context-toolkit/SKILL.md` — delete
- `.claude/hooks/context-inject.sh` — scan for toolkit-specific injection, prune

### 7. Verification

Once Release N ships and a real user has upgraded:

- `ls ~/.claude/plugins/` should no longer show `youcoded-core/`
- `cat ~/.claude/settings.json` should show `PreToolUse` hooks pointing at the app's bundled write-guard path, not `~/.claude/plugins/youcoded-core/hooks/write-guard.sh`
- Write-guard behavior must still function — attempt a cross-session write conflict and confirm the block
- The app's diagnostic log should contain one entry documenting the legacy-cleanup execution (or note that nothing needed cleanup, for users who were already on a fresh install)

Once Release N+1 ships, a global grep in the `youcoded` repo for `youcoded-core` should return zero matches outside of (a) historical changelogs, (b) the `cc-dependencies.md` notes if applicable, and (c) variable names that happen to contain the substring (none expected).

## Decisions log

| Question | Decision |
|---|---|
| Support CLI-only install after deprecation? | No. YouCoded = the app. |
| Native bundle the encyclopedia context line? | No — drop it entirely. Skill descriptions already carry the encyclopedia into Claude's awareness. |
| Existing users: cleanup strategy? | Active delete of the legacy directory on app launch. No safety move. |
| `tool-router.sh` fate? | Delete (superseded by google-services plugin's own routing). |
| `write-guard.sh` fate? | Bundle natively in the app on both platforms. Only surviving piece from `youcoded-core`. |
| Hook registration mechanism? | App-owned hooks use `install-hooks.js` (write absolute path to `settings.json`). `HookReconciler` + `hooks-manifest.json` mechanism stays for marketplace plugins. |

## Open items to verify at plan time

- Does `write-guard.sh` actually source `hooks/lib/hook-preamble.sh`? If yes, that file comes along. If no, `hooks/lib/` deletes entirely.
- Is `specs/landing-page-spec.md` about a live website, or defunct? If live, find its right home.
- Is `specs/memory-system-spec.md` still describing current behavior, or is it stale? Same for `specs/output-styles-spec.md`.
- Android's hook-registration mechanism: does `Bootstrap.kt` write to a settings.json equivalent, or does `SessionService.kt` own it? Plan should pin down the exact Kotlin file before editing.
- Does anything in the youcoded-admin repo (the owner-only release skill) reference youcoded-core? If yes, update as part of this work.
