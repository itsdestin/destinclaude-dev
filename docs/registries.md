# Registries (Marketplace & Themes)

Both registries are GitHub repos fetched at runtime by apps via `raw.githubusercontent.com`. No CI rebuild on either — registries are rebuilt manually or on merge.

## Skill Marketplace (`wecoded-marketplace/`)

Recent restructure (unified-marketplace merge) split the registry into `/skills/` and `/themes/` subdirectories. The `sync.js` rewrite added diffing, version tracking, and deprecation logic.

- `index.json` — entries from both sources
- `marketplace.json` — YouCoded-only entries
- Synced from upstream via `scripts/sync.js`. Entries with `sourceMarketplace: "youcoded-core"` are never overwritten by upstream sync
- Apps cache for 24 hours at `~/.claude/wecoded-marketplace-cache/`
- CI: `.github/workflows/validate-plugin-pr.yml` validates community plugin PRs

## Theme Registry (`wecoded-themes/`)

- `registry/theme-registry.json` — auto-generated from `themes/{slug}/manifest.json` files
- Each theme directory under `/themes/` holds its manifest and assets
- CI validates PRs (required tokens, CSS safety, size <10MB, slug uniqueness)
- CI auto-rebuilds registry + generates preview PNGs (Playwright) on merge to main
- `previewTokens` in registry power CSS-based card previews in the app (no image load needed)

### Required CSS tokens (15)

`canvas`, `panel`, `inset`, `well`, `accent`, `on-accent`, `fg`, `fg-2`, `fg-dim`, `fg-muted`, `fg-faint`, `edge`, `edge-dim`, `scrollbar-thumb`, `scrollbar-hover`

### CSS safety rules (CI enforced)

- No `@import`
- No external URLs
- No `expression()`
- No `javascript:` URIs

Violations fail CI. Community theme PRs are auto-rejected.
