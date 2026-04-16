---
name: context-toolkit
description: Load deep context for YouCoded toolkit development — plugin structure, hooks, skills, sync system, encyclopedia, specs. Invoke before making non-trivial changes to youcoded-core/ code, especially hooks, skills, or sync/config logic.
---

# Toolkit Development Context

You are working on the YouCoded toolkit. Before making changes, orient with these references:

## Read first
- `docs/toolkit-structure.md` — three-layer plugin architecture
- `youcoded-core/docs/system-architecture.md` — comprehensive architecture reference
- `arch_three_layer_toolkit.md` memory — why the layer split exists
- `arch_hook_enforcement.md` memory — why hooks-manifest.json is the source of truth
- `arch_sync_design.md` memory — config.json vs config.local.json, sync backends

## Hard rules

1. **Never edit `~/.claude/settings.json` hooks directly.** Update `core/hooks/hooks-manifest.json`. `/update` merges via additive reconciliation with `MAX(user, manifest)` timeouts.

2. **`.sh` files MUST have execute bit set.** On Windows Git: `git update-index --chmod=+x path/to/file.sh`. The #1 cause of "hook does nothing."

3. **`config.json` is portable, `config.local.json` is machine-specific.** Never commit or sync config.local.json. session-start.sh rebuilds it every session.

4. **Feature work uses `git worktree add`** in the main plugin dir. `worktree-guard.sh` blocks branch switches there.

5. **Bump the ROOT `plugin.json` version** to trigger a toolkit release. `auto-tag.yml` detects changes and creates `vX.Y.Z` tag. Layer plugin.json files are currently independent and don't drive releases.

## Skill conventions

- Directories with `SKILL.md` + YAML frontmatter (`name`, `description`)
- Description is how Claude discovers the skill — always in context. Be specific.
- Never cross-layer dependencies (core never depends on life/productivity).

## Hook lifecycle

11 hooks declared across 6 types. Important guards:
- `write-guard.sh` (PreToolUse:Write|Edit) — same-machine concurrency, blocks writes when another session modified the file
- `worktree-guard.sh` (PreToolUse:Bash|Agent) — enforces master-only in main plugin dir
- `session-start.sh` — 44KB, handles config rebuild, sync, encyclopedia cache, inbox check

## Known state

`~/.claude/settings.json` currently runs YouCoded app hooks (relay.js), not toolkit hooks directly. The manifest reconciliation may need `/update` to activate. See `arch_hook_enforcement.md` for details.
