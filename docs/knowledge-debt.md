# Knowledge Debt

Running list of documentation/rule drift that's been noticed but not yet fixed. Each entry has concrete fix instructions so they persist across sessions.

**How to use this file:**
- Claude appends entries when it notices drift mid-session (outdated claim, renamed file, etc.)
- `/audit` appends entries for any drift detected but not fixed in-session
- User reviews periodically, applies fixes, removes entries
- Each entry stays until resolved — empty file = no known debt

## Entry format

```markdown
## <Title> (noticed YYYY-MM-DD)
- **Claim**: <what docs/rules say>
- **Actual**: <what code does>
- **Fix**: <concrete steps — file, section, change, verify>
- **Priority**: low / medium / high
```

---

Last audit: 2026-04-11 (Phase 0 baseline — see `docs/AUDIT.md` for full findings).

## Onboarding.tsx screen deferred (noticed 2026-04-12)
- **Claim**: Decomposition v3 §7.12 / §9.10 specify a React Onboarding screen that collects name/comfort/output-style, installs curated packages on first launch, and replaces the conversational setup-wizard as the primary first-run path.
- **Actual**: All backend helpers exist and are bridged to desktop, remote, and Android (skills:install-many, skills:apply-output-style, skills:get-curated-defaults, skills:get-integration-info). The React screen itself has not been built — App.tsx still shows only `FirstRunView` (CLI prereqs) and no toolkit-preferences step. Net effect: after decomposition lands, first-launch users reach an empty app with no curated packages installed and no output style set.
- **Fix**: Build `desktop/src/renderer/components/Onboarding.tsx` — form with name input, comfort radio (beginner/intermediate/power), output-style picker (casual/conversational/academic/professional), and a "install curated defaults" confirm step that calls `window.claude.skills.installMany(curatedIds)` and `window.claude.skills.applyOutputStyle(styleId)`. Gate it in App.tsx after `FirstRunView` completes, keyed on absence of `~/.claude/toolkit-state/config.json` (add a tiny IPC `toolkit:hasConfig` if needed). Must have a skip button so a bug can't brick first launch. Needs live dev-server iteration — don't ship blind.
- **Priority**: high (blocks decomposition merge to master)

## SkillDetail loses star rating + install count after Task 6 (noticed 2026-04-12)
- **Claim**: `SkillDetail.tsx` displays install count and star rating sourced from the marketplace backend.
- **Actual**: Task 6 removed static-stats reads from `skill-provider.ts` (main process). `getSkillDetail()` now returns `installs`, `rating`, and `ratingCount` as `undefined`. `SkillDetail.tsx`'s `<StarRating>` renders `null` when rating is nullish, so the detail panel silently shows no rating or install count. Task 9 only re-wires `SkillCard`, not `SkillDetail`.
- **Why it happened**: Live stats context lives in the renderer (`useMarketplaceStats()`); `skill-provider.ts` runs in Electron main and cannot reach it. `SkillDetail.tsx` was not updated to pull from the renderer-side stats context the way `SkillCard` will be in Task 9.
- **Fix**: In the Task 9 follow-up (or a dedicated follow-up), update `SkillDetail.tsx` to call `useMarketplaceStats()` and merge the live `installs`/`rating`/`ratingCount` numbers from context — same pattern as SkillCard. Until then: detail panel ratings are absent; SkillCard ratings also remain broken until Task 9 ships.
- **Priority**: high (visible regression — users see no rating or install count in the skill detail panel)

## Icon override system is dead code (noticed 2026-04-12)
- **Claim**: `theme.icons` manifest entries (slots: send, new-chat, settings, theme-cycle, close, menu per `destincode/desktop/src/renderer/themes/theme-types.ts:75`) override the app's built-in icons. `theme-builder` SKILL.md documents generating and shipping `icon-<slot>.svg` assets. Exemplar theme `golden-sunbreak/manifest.json` ships a `send` override.
- **Actual**: Manifest loading and asset resolution work end-to-end (`theme-asset-resolver.ts:52-58`), but **zero React components consume `theme.icons[slot]`**. Every UI icon — send button (`InputBar.tsx:493-495`), settings gear + view toggle + gamepad (`HeaderBar.tsx`), new session (`SessionStrip.tsx`) — is hardcoded inline SVG that ignores the override map. `golden-sunbreak`'s `send` override has been dead data since shipped.
- **Fix**: Either (a) wire each icon-rendering component to check `theme.icons[slot]` before falling back to its hardcoded SVG, and expand slots to cover terminal/chat-view/game/session-add, OR (b) remove the `icons` field from `theme-types.ts` + manifest schema + SKILL.md and stop pretending it works. Also update `theme-builder/scripts/mockup-render.js` if (a) — mockup's chrome SVGs are also hardcoded. Tracked in destincode issue.
- **Priority**: medium (affects every theme's claimed override capability; blocks theme-builder icon pack work)
