# ADR 004: Hooks Declared in Manifest, Merged Into Settings.json

**Status:** Accepted
**Date:** Pre-2026

## Context

Claude Code reads hook configuration from `~/.claude/settings.json`. The toolkit ships with hooks users need, but users may also customize their settings.json for other tools or personal preferences. Direct writes to settings.json during toolkit updates would clobber user edits.

## Decision

Declare toolkit hooks in `youcoded-core/core/hooks/hooks-manifest.json` in a **desired-state format**. During `/update`, `phase_settings_migrate()` performs an additive reconciliation into settings.json:

- New hooks from manifest → added to settings.json
- Missing properties (matcher, timeout) → added
- For timeouts, use `MAX(user_value, manifest_value)` (user can extend, not shorten)
- Existing non-toolkit hooks in settings.json → untouched

## Alternatives Considered

- **Direct write to settings.json** — simplest, but destroys user customizations
- **Separate hooks config file** — would require Claude Code to read our config, which it doesn't
- **Hook registration via a CLI command** — adds complexity and another path for state drift

## Consequences

**Good:**
- Users can safely customize settings.json for non-toolkit hooks
- `/update` is idempotent and non-destructive
- Timeout reconciliation respects user intent (they can only increase timeouts, not decrease)
- Single source of truth for toolkit hooks (the manifest)

**Bad:**
- Reconciliation logic lives in `session-start.sh` and `post-update.sh` — complex and somewhat fragile
- Current observed drift: `~/.claude/settings.json` shows YouCoded app hooks (relay.js) rather than toolkit hooks. Reconciliation may need a bug fix or the user may never have run `/update` with the current manifest.
- Users who want to temporarily disable a toolkit hook can't — editing settings.json directly gets overwritten on next `/update`
