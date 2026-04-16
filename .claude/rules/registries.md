---
paths:
  - "wecoded-themes/**"
  - "wecoded-marketplace/**"
last_verified: 2026-04-11
---

# Registries Rules

You are editing either the theme registry or the skill marketplace. Read `docs/registries.md` for full context.

## Theme Registry (`wecoded-themes`)

- `registry/theme-registry.json` is **auto-generated** on CI merge. Don't hand-edit it.
- Each theme lives under `themes/{slug}/` with a `manifest.json` + assets.
- **15 required CSS tokens**: canvas, panel, inset, well, accent, on-accent, fg, fg-2, fg-dim, fg-muted, fg-faint, edge, edge-dim, scrollbar-thumb, scrollbar-hover
- **CSS safety** (CI enforces): NO `@import`, NO external URLs, NO `expression()`, NO `javascript:` URIs
- `previewTokens` in registry power CSS-based card previews (no image load)
- CI runs Playwright to generate preview PNGs on merge

## Skill Marketplace (`wecoded-marketplace`)

- Registry split into `/skills/` and `/themes/` subdirectories (recent restructure).
- `index.json` holds combined entries; `marketplace.json` holds YouCoded-only entries
- Synced from upstream Anthropic marketplace via `scripts/sync.js` — handles diffing, version tracking, deprecation
- Entries with `sourceMarketplace: "youcoded-core"` are **never overwritten** by upstream sync
- CI: `.github/workflows/validate-plugin-pr.yml` validates community plugin PRs
- App caches the fetched registry for 24 hours at `~/.claude/wecoded-marketplace-cache/`

## Common gotchas

- No CI rebuilds either registry on a schedule. Rebuild happens on merge (themes) or via manual `node scripts/sync.js` (marketplace).
- Submitting a theme without all 15 tokens fails CI.
- Submitting a theme manifest larger than 10MB fails CI.
- Slug uniqueness is validated — a PR with a duplicate slug fails CI.
