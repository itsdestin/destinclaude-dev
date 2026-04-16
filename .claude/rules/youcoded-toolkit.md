---
paths:
  - "youcoded-core/**"
last_verified: 2026-04-11
---

# YouCoded Toolkit Rules

You are editing the YouCoded toolkit. Read `docs/toolkit-structure.md` for full context.

## Structure

Root manifest plus 3 layers, each with its own `plugin.json`:
- `plugin.json` (root, v2.3.2) — aggregate package users install
- `core/plugin.json` (v0.1.0) — hooks, setup, sync, themes
- `life/plugin.json` (v0.1.0) — journal, encyclopedia
- `productivity/plugin.json` (v0.1.0) — tasks, skills, messaging

## Hard rules

- **Never edit hooks in `~/.claude/settings.json` directly.** Update `core/hooks/hooks-manifest.json` — `/update` merges it into settings.json. Direct edits get overwritten.
- **`.sh` files MUST have execute bit set.** Git on Windows doesn't set this automatically. After creating or renaming a script: `git update-index --chmod=+x path/to/file.sh`. Missing execute bit is the #1 cause of "hook does nothing" bugs.
- **`config.json` is portable; `config.local.json` is machine-specific.** config.local.json is rebuilt every session by `session-start.sh` — don't commit or sync it.
- **Feature work uses `git worktree add`**, not branch creation in the main plugin dir. `worktree-guard.sh` blocks branch switches here.

## Skills

Directories with `SKILL.md` files. YAML frontmatter `description` is how Claude discovers when to invoke them. Be specific and concrete in descriptions — they're always in context.

- Core skills: `core/skills/` (setup-wizard, sync, theme-builder, remote-setup)
- Life skills: `life/skills/` (journaling-assistant, encyclopedia-*, fork-file, google-drive)
- Productivity skills: `productivity/skills/` (claudes-inbox, skill-creator)

## Hooks

Declared in `core/hooks/hooks-manifest.json`. Guards to know about:
- `write-guard.sh` — PreToolUse, blocks writes when another session recently modified the file
- `worktree-guard.sh` — PreToolUse for Bash, blocks branch switches in main plugin dir
- `session-start.sh` — runs at session start, syncs config/encyclopedia/inbox (44KB)

## Version bumping

Bump the ROOT `plugin.json` version to trigger a toolkit release. `auto-tag.yml` detects the change and creates a `vX.Y.Z` tag automatically. Layer `plugin.json` files are independent and don't drive releases.
