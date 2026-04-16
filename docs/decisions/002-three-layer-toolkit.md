# ADR 002: Three-Layer Toolkit Structure

**Status:** Accepted
**Date:** Pre-2026 (foundational)

## Context

YouCoded ships a large surface area of features: hooks, setup, sync, themes, journaling, encyclopedia, task inbox, skill creation, messaging. Putting all of these in a single flat plugin would make updates, debugging, and user comprehension difficult.

## Decision

Split the toolkit into three functional layers, each with its own `plugin.json`:

- `core/` — foundation (hooks, setup, sync, themes). Required for everything else.
- `life/` — personal knowledge (journal, encyclopedia). Depends on core.
- `productivity/` — task processing, skill creation, messaging. Depends on core.

A root `plugin.json` aggregates all three and drives releases via `auto-tag.yml`.

## Alternatives Considered

- **Monolithic plugin** — harder to reason about, single failure mode for every feature
- **One plugin per skill** — too granular, users would install 20+ things
- **Two layers (core + everything else)** — the life/productivity distinction is meaningful enough to preserve

## Consequences

**Good:**
- Clear dependency direction (core never imports from life/productivity)
- Layer-level comprehension — users understand "what does life do?" vs reading 20 skills
- Future flexibility — could publish layers independently when useful
- Each layer has its own SKILL.md collection, easy to navigate

**Bad:**
- Currently only the root `plugin.json` drives releases (layer versions are v0.1.0 placeholders) — the multi-version complexity isn't yet realized as a benefit
- Users don't actually pick-and-choose layers — the plugin installs everything
- Some skills could reasonably fit in multiple layers (e.g., skill-creator is in productivity, but could be core)
