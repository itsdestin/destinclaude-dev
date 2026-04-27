# Local Themes in Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make user-built local themes appear in the Library's existing "Installed themes" section with a "Local" badge + tooltip, drive preview-card generation from the `/theme-builder` skill, and wire CI to honor the locally-generated `preview.png` instead of overwriting it.

**Architecture:** The app's `MarketplaceProvider` currently fetches `themeEntries` from the external GitHub registry only — local user themes (the ones written to `~/.claude/wecoded-themes/<slug>/` by `/theme-builder`) never reach the Library Themes tab. We add a second source: synthesize `ThemeRegistryEntryWithStatus` records from `LoadedTheme`s with `source: 'user'` that have no marketplace entry, tagged with a new `isLocal: true` flag. The cards render in the existing Installed section with a "Local" badge + (i) hover tooltip. `/theme-builder` Phase 2 finalize gets a new step that shells out to `wecoded-themes/scripts/generate-previews.js <slug>` to produce `preview.png`. The publisher's existing `generateThemePreview()` call (in `theme-marketplace-provider.ts:384`) becomes a fallback when the file is missing or stale. CI's `generate-previews.js` is updated to honor a committed `preview.png` so the user-supplied image survives merge.

**Tech Stack:** TypeScript (Electron main + React renderer), Node.js (Playwright preview script), Python (registry builder), GitHub Actions, Vitest.

**Sequencing:** Phase 1 (app fix) lands first — that's the user-visible bug. Phase 2 (preview generation in skill) follows so local cards have images. Phase 3 (publisher optimization) and Phase 4 (CI honoring) are decoupling polish that ensures the locally-generated preview is the canonical one. Each phase ships independently.

**Worktree convention:** Per `youcoded-dev/CLAUDE.md`, all non-trivial work goes in `git worktree add` branches. Each phase below specifies its repo and branch name.

---

## Phase 1 — App: synthesize local theme entries and render them

**Repo:** `youcoded-dev/youcoded`
**Worktree:** `git worktree add youcoded-worktrees/local-themes-library local-themes-library` from `youcoded/`
**Why first:** This is the user-visible bug. After this phase, locally-built themes appear in Library with their existing `wallpaper.<ext>` as a fallback image (no preview.png yet).

### Task 1.1: Extend `ThemeRegistryEntryWithStatus` with `isLocal` flag

**Files:**
- Modify: `desktop/src/shared/theme-marketplace-types.ts:76-79`
- Test: `desktop/tests/theme-marketplace-types.test.ts` (create)

- [ ] **Step 1: Write the failing test**

```ts
// desktop/tests/theme-marketplace-types.test.ts
import { describe, it, expect } from 'vitest';
import type { ThemeRegistryEntryWithStatus } from '../src/shared/theme-marketplace-types';

describe('ThemeRegistryEntryWithStatus', () => {
  it('accepts isLocal as an optional boolean', () => {
    const entry: ThemeRegistryEntryWithStatus = {
      slug: 'foo', name: 'Foo', author: 'destin', dark: true,
      source: 'community', features: [], manifestUrl: 'https://example/manifest.json',
      installed: true, isLocal: true,
    };
    expect(entry.isLocal).toBe(true);
  });

  it('isLocal is optional — omitting it is valid', () => {
    const entry: ThemeRegistryEntryWithStatus = {
      slug: 'foo', name: 'Foo', author: 'destin', dark: true,
      source: 'community', features: [], manifestUrl: 'https://example/manifest.json',
      installed: true,
    };
    expect(entry.isLocal).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails (compile error on `isLocal`)**

Run: `cd youcoded/desktop && npx vitest run tests/theme-marketplace-types.test.ts`
Expected: FAIL — TypeScript error "Object literal may only specify known properties, and 'isLocal' does not exist in type 'ThemeRegistryEntryWithStatus'"

- [ ] **Step 3: Add the field to the type**

Edit `desktop/src/shared/theme-marketplace-types.ts:76-79`. Replace:

```ts
export type ThemeRegistryEntryWithStatus = ThemeRegistryEntry & {
  installed: boolean;
};
```

with:

```ts
export type ThemeRegistryEntryWithStatus = ThemeRegistryEntry & {
  installed: boolean;
  /** True for entries synthesized from a locally-built user theme that has no
   * marketplace registry entry. Drives the "Local" badge + tooltip in
   * MarketplaceCard, and the permanent-deletion confirmation copy. Distinct
   * from `installed: true` which means "manifest.json exists on disk" — a
   * marketplace theme can be installed but not local. */
  isLocal?: boolean;
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd youcoded/desktop && npx vitest run tests/theme-marketplace-types.test.ts`
Expected: PASS (both cases).

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add desktop/src/shared/theme-marketplace-types.ts desktop/tests/theme-marketplace-types.test.ts
git commit -m "feat(themes): add isLocal flag to ThemeRegistryEntryWithStatus"
```

### Task 1.2: Synthesize local theme entries in main-process provider

**Files:**
- Create: `desktop/src/main/local-theme-synthesizer.ts`
- Modify: `desktop/src/main/theme-marketplace-provider.ts` (around line 121, the `listThemes()` method)
- Test: `desktop/tests/local-theme-synthesizer.test.ts` (create)

The helper takes (a) the marketplace-fetched registry list and (b) the on-disk user theme manifests, and returns a merged list where local-only manifests appear as synthesized entries.

- [ ] **Step 1: Write the failing test**

```ts
// desktop/tests/local-theme-synthesizer.test.ts
import { describe, it, expect } from 'vitest';
import { synthesizeLocalThemeEntries } from '../src/main/local-theme-synthesizer';
import type { ThemeRegistryEntryWithStatus } from '../src/shared/theme-marketplace-types';

const marketplaceEntry: ThemeRegistryEntryWithStatus = {
  slug: 'golden-sunbreak', name: 'Golden Sunbreak', author: 'itsdestin', dark: true,
  source: 'youcoded-core', features: ['wallpaper'],
  manifestUrl: 'https://raw.githubusercontent.com/itsdestin/wecoded-themes/main/themes/golden-sunbreak/manifest.json',
  installed: true,
};

const localManifest = {
  slug: 'after-the-show', name: 'After the Show', author: 'destin', dark: true,
  description: 'Cozy mint glow under fairy lights',
  tokens: { canvas: '#231731', panel: '#2d1f3f', accent: '#6ad1b9', 'on-accent': '#000', fg: '#faedd5', 'fg-muted': '#a08fb0', edge: '#3a2a4f' },
  background: { type: 'image', value: 'assets/wallpaper.jpg', 'panels-blur': 12 },
};

describe('synthesizeLocalThemeEntries', () => {
  it('adds an isLocal entry for a manifest that has no marketplace match', () => {
    const result = synthesizeLocalThemeEntries(
      [marketplaceEntry],
      [{ slug: 'after-the-show', manifest: localManifest, hasPreview: true }],
    );
    expect(result).toHaveLength(2);
    const local = result.find(e => e.slug === 'after-the-show');
    expect(local).toBeDefined();
    expect(local!.isLocal).toBe(true);
    expect(local!.installed).toBe(true);
    expect(local!.name).toBe('After the Show');
    expect(local!.description).toBe('Cozy mint glow under fairy lights');
    expect(local!.preview).toBe('theme-asset://after-the-show/preview.png');
    expect(local!.previewTokens).toEqual({
      canvas: '#231731', panel: '#2d1f3f', accent: '#6ad1b9',
      'on-accent': '#000', fg: '#faedd5', 'fg-muted': '#a08fb0', edge: '#3a2a4f',
    });
    expect(local!.features).toContain('wallpaper');
    expect(local!.features).toContain('glassmorphism');
  });

  it('does not duplicate when a local manifest matches a marketplace slug', () => {
    const result = synthesizeLocalThemeEntries(
      [marketplaceEntry],
      [{ slug: 'golden-sunbreak', manifest: { slug: 'golden-sunbreak', name: 'X', author: 'Y', dark: true, tokens: {} }, hasPreview: false }],
    );
    expect(result).toHaveLength(1);
    expect(result[0].isLocal).toBeUndefined();
  });

  it('falls back to wallpaper path when preview.png is missing', () => {
    const result = synthesizeLocalThemeEntries([], [{
      slug: 'after-the-show', manifest: localManifest, hasPreview: false,
    }]);
    expect(result[0].preview).toBe('theme-asset://after-the-show/assets/wallpaper.jpg');
  });

  it('omits preview when there is no preview.png and no wallpaper', () => {
    const result = synthesizeLocalThemeEntries([], [{
      slug: 'plain', manifest: { slug: 'plain', name: 'Plain', author: 'd', dark: false, tokens: {} },
      hasPreview: false,
    }]);
    expect(result[0].preview).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd youcoded/desktop && npx vitest run tests/local-theme-synthesizer.test.ts`
Expected: FAIL with "Cannot find module './local-theme-synthesizer'"

- [ ] **Step 3: Implement the synthesizer**

Create `desktop/src/main/local-theme-synthesizer.ts`:

```ts
import type { ThemeRegistryEntryWithStatus } from '../shared/theme-marketplace-types';

/** What we read for each local user theme on disk. The caller (provider)
 * supplies these — this module is pure so it stays unit-testable. */
export interface LocalThemeRecord {
  slug: string;
  manifest: Record<string, any>;
  /** True if `<themeDir>/preview.png` exists on disk. */
  hasPreview: boolean;
}

const PREVIEW_TOKEN_KEYS = [
  'canvas', 'panel', 'accent', 'on-accent', 'fg', 'fg-muted', 'edge',
] as const;

function detectFeatures(manifest: Record<string, any>): string[] {
  const features: string[] = [];
  const bg = manifest.background ?? {};
  if (bg.type === 'image') features.push('wallpaper');
  if ((bg['panels-blur'] ?? 0) > 0) features.push('glassmorphism');
  const effects = manifest.effects ?? {};
  if (effects.particles && effects.particles !== 'none') features.push('particles');
  if (manifest.font) features.push('custom-font');
  if (manifest.icons) features.push('custom-icons');
  if (manifest.mascot) features.push('mascot');
  if (manifest.custom_css) features.push('custom-css');
  return features;
}

function pickPreviewTokens(manifest: Record<string, any>): Record<string, string> | undefined {
  const tokens = manifest.tokens ?? {};
  const picked: Record<string, string> = {};
  for (const key of PREVIEW_TOKEN_KEYS) {
    if (typeof tokens[key] === 'string') picked[key] = tokens[key];
  }
  return Object.keys(picked).length === PREVIEW_TOKEN_KEYS.length
    ? (picked as any)
    : undefined;
}

function pickPreviewUrl(rec: LocalThemeRecord): string | undefined {
  if (rec.hasPreview) return `theme-asset://${rec.slug}/preview.png`;
  const wallpaperPath = rec.manifest?.background?.value;
  if (typeof wallpaperPath === 'string' && wallpaperPath.startsWith('assets/')) {
    return `theme-asset://${rec.slug}/${wallpaperPath}`;
  }
  return undefined;
}

/** Return the merged list of marketplace entries plus synthesized entries
 * for local themes that don't appear in the marketplace list. Local entries
 * are tagged `isLocal: true` and `installed: true`. */
export function synthesizeLocalThemeEntries(
  marketplaceEntries: ThemeRegistryEntryWithStatus[],
  localRecords: LocalThemeRecord[],
): ThemeRegistryEntryWithStatus[] {
  const marketplaceSlugs = new Set(marketplaceEntries.map(e => e.slug));
  const synthesized: ThemeRegistryEntryWithStatus[] = [];

  for (const rec of localRecords) {
    if (marketplaceSlugs.has(rec.slug)) continue;  // marketplace wins; entry already represents this theme
    const m = rec.manifest;
    synthesized.push({
      slug: rec.slug,
      name: m.name ?? rec.slug,
      author: m.author ?? 'unknown',
      dark: !!m.dark,
      description: typeof m.description === 'string' ? m.description : undefined,
      preview: pickPreviewUrl(rec),
      previewTokens: pickPreviewTokens(m),
      version: typeof m.version === 'string' ? m.version : '1.0.0',
      created: typeof m.created === 'string' ? m.created : undefined,
      source: 'community',  // synthesized entries fill the discriminator with the closest match — `isLocal` is the real differentiator
      features: detectFeatures(m),
      manifestUrl: '',  // empty — local themes have no upstream URL
      installed: true,
      isLocal: true,
    });
  }

  return [...marketplaceEntries, ...synthesized];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd youcoded/desktop && npx vitest run tests/local-theme-synthesizer.test.ts`
Expected: all four test cases PASS.

- [ ] **Step 5: Wire it into `theme-marketplace-provider.ts`**

Open `desktop/src/main/theme-marketplace-provider.ts`. Find the `listThemes()` method around line 121. Currently:

```ts
async listThemes(): Promise<ThemeRegistryEntryWithStatus[]> {
  // ... existing fetch from registry ...
  return themes.map(t => ({
    ...t,
    installed: this.isInstalled(t.slug),
  }));
}
```

Replace the `return` with a merge-with-local pass. Add at the top of the file (with other imports):

```ts
import { synthesizeLocalThemeEntries, type LocalThemeRecord } from './local-theme-synthesizer';
import { listUserThemes } from './theme-watcher';
```

(`listUserThemes` already exists in `theme-watcher.ts` — it returns the on-disk manifests. Confirm by reading it; if it returns a different shape, the adapter below normalizes.)

Replace the `return` block in `listThemes()` with:

```ts
  const marketplaceEntries = themes.map(t => ({
    ...t,
    installed: this.isInstalled(t.slug),
  }));

  // Merge in local user themes (built via /theme-builder, never published).
  // We treat any on-disk theme not in the marketplace list as local-only.
  const localRecords: LocalThemeRecord[] = [];
  try {
    const userThemes = listUserThemes();  // returns parsed manifests for ~/.claude/wecoded-themes/<slug>/
    for (const ut of userThemes) {
      const previewPath = path.join(THEMES_DIR, ut.slug, 'preview.png');
      localRecords.push({
        slug: ut.slug,
        manifest: ut.manifest ?? ut,  // listUserThemes shape varies — adapter
        hasPreview: fs.existsSync(previewPath),
      });
    }
  } catch (err) {
    console.warn('[ThemeMarketplace] Failed to enumerate local themes:', err);
  }

  return synthesizeLocalThemeEntries(marketplaceEntries, localRecords);
```

(`THEMES_DIR` is already imported from `./theme-watcher` per line 12; `fs` and `path` are already imported.)

- [ ] **Step 6: Verify `listUserThemes()` shape**

Read `desktop/src/main/theme-watcher.ts` and confirm what `listUserThemes()` returns. If it returns `{ slug, ... fields ...}` directly (manifest spread at top level), pass `ut` as the manifest. If it returns `{ slug, manifest }`, pass `ut.manifest`. The line `manifest: ut.manifest ?? ut` handles both.

- [ ] **Step 7: Commit**

```bash
git add desktop/src/main/local-theme-synthesizer.ts desktop/src/main/theme-marketplace-provider.ts desktop/tests/local-theme-synthesizer.test.ts
git commit -m "feat(themes): synthesize local user themes into marketplace listings

Local themes built via /theme-builder live at ~/.claude/wecoded-themes/<slug>/
but the Library Themes tab only ever showed entries from the external GitHub
registry. Synthesize ThemeRegistryEntryWithStatus records for any on-disk theme
without a marketplace match and tag them isLocal so cards can render a Local
badge."
```

### Task 1.3: Refresh `themeEntries` when local themes change on disk

**Files:**
- Modify: `desktop/src/renderer/state/marketplace-context.tsx` (around the existing `themeFavoritesChanged` peer-window listener, lines 377+)

The marketplace context already listens for cross-window theme-favorite events. We add a second trigger: when the theme-watcher fires `theme:reload` (chokidar detected a change in `~/.claude/wecoded-themes/`), refetch.

- [ ] **Step 1: Find the existing reload-trigger listener**

In `marketplace-context.tsx`, locate the effect that listens for `themeFavoritesChanged` events (around line 377-396 per the existing comments). Note the pattern.

- [ ] **Step 2: Add a parallel listener for theme reloads**

Open the renderer-side IPC binding at `desktop/src/main/preload.ts`. Confirm there's an `onThemeReload(callback)` API exposed under `window.claude.theme` (it already exists — used by `theme-context.tsx`). If it's not directly callable from `marketplace-context.tsx`, expose a thin wrapper that just bumps a generation counter.

In `marketplace-context.tsx`, add inside `MarketplaceProvider`:

```tsx
useEffect(() => {
  // Local user themes are surfaced in themeEntries via synthesis on the main
  // side. When the theme-watcher reports a change (theme:reload), the merged
  // list may have changed — refetch so the Library reflects new/deleted/edited
  // user themes immediately rather than at next mount.
  const off = window.claude.theme.onThemeReload?.(() => {
    fetchAll();
  });
  return () => { try { off?.(); } catch {} };
}, [fetchAll]);
```

- [ ] **Step 3: Test manually**

Build: `cd youcoded/desktop && npm run build`
Run dev: from workspace root, `bash scripts/run-dev.sh`
- Open Library → Themes tab. Note any themes shown.
- In a terminal: `mkdir -p ~/.claude/wecoded-themes/test-local-theme && cp ~/.claude/wecoded-themes/after-the-show/manifest.json ~/.claude/wecoded-themes/test-local-theme/`
- Edit the copied manifest's `slug` field to `"test-local-theme"`.
- Library should auto-update within ~1s, showing "test-local-theme" in Installed themes.
- Cleanup: `rm -rf ~/.claude/wecoded-themes/test-local-theme`. Library updates again.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/renderer/state/marketplace-context.tsx
git commit -m "feat(themes): refetch marketplace entries on theme-watcher reload"
```

### Task 1.4: Render the "Local" badge + (i) hover tooltip on theme cards

**Files:**
- Modify: `desktop/src/renderer/components/marketplace/MarketplaceCard.tsx` (the theme-card render path, around line 178-195 where the title block lives)

- [ ] **Step 1: Locate the title block and badge logic**

In `MarketplaceCard.tsx`, find the section starting at line 164 (`<div className="flex items-start justify-between gap-2">`) and the existing status badge block (lines 189-204). The "Local" badge will render alongside title row, separate from the install-status badge.

- [ ] **Step 2: Add an `isLocalTheme` derived value and the badge JSX**

After line 84 (`const isInstalled = !!installed;`), add:

```ts
const isLocalTheme = item.kind === 'theme' && !!item.entry.isLocal;
```

Inside the title block (`<div className="min-w-0">` at line 178), after the `{author && ...}` line, add:

```tsx
{isLocalTheme && (
  <div className="mt-1 inline-flex items-center gap-1 group relative">
    <span className="text-[10px] uppercase tracking-wide px-2 py-0.5 rounded-full bg-accent/15 text-accent border border-accent/30">
      Local
    </span>
    <button
      type="button"
      onClick={(e) => e.stopPropagation()}
      onKeyDown={(e) => e.stopPropagation()}
      className="text-fg-muted hover:text-fg-2 leading-none focus:outline-none focus-visible:ring-1 focus-visible:ring-accent rounded-full"
      aria-label="What does Local mean?"
    >
      <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true">
        <circle cx="8" cy="8" r="7" fill="none" stroke="currentColor" strokeWidth="1.5" />
        <text x="8" y="11" textAnchor="middle" fontSize="9" fontWeight="600" fill="currentColor">i</text>
      </svg>
    </button>
    {/* Tooltip — only shown on hover/focus of the (i). The group-hover on the
         parent inline-flex handles both badge hover and the icon button. */}
    <div
      role="tooltip"
      className="pointer-events-none absolute top-full left-0 mt-1 w-64 z-20 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity layer-surface p-3 text-xs text-fg-2 leading-relaxed"
    >
      Local only. Built by you with Claude — not in the marketplace, so it can't be shared or re-downloaded. Deleting it removes the files permanently. You can publish it later from the theme detail view.
    </div>
  </div>
)}
```

- [ ] **Step 3: Manual verification**

Rebuild and re-run dev. Open Library → Themes tab. Local themes should show:
- "Local" pill in accent color under the author line
- (i) icon next to the pill
- Hovering the row reveals the tooltip
- Clicking the (i) does NOT open the card detail (stopPropagation)

- [ ] **Step 4: Commit**

```bash
git add desktop/src/renderer/components/marketplace/MarketplaceCard.tsx
git commit -m "feat(themes): render Local badge + tooltip on locally-built theme cards"
```

### Task 1.5: Sanity-check the LibraryScreen filters work unchanged

**Files:** None modified — verification only.

- [ ] **Step 1: Read `LibraryScreen.tsx:205-218`**

The current Themes tab filters are `mp.themeEntries.filter(t => t.installed && ...)`. Synthesized local entries have `installed: true` so they pass the filter automatically. No change needed.

- [ ] **Step 2: Verify by inspection**

Open Library → Themes. Confirm:
- "Favorite themes" section shows local themes whose slug is in `themeFavorites`
- "Installed themes" section shows local themes NOT in `themeFavorites`
- The "After the Show" theme should appear in Favorites since it was already starred in `youcoded-skills.json`

If both pass, Phase 1 visible behavior is complete.

### Task 1.6: Permanent-deletion confirmation copy for local themes

**Files:**
- Modify: wherever theme uninstall/delete is initiated. Per the earlier grep, there's no `deleteTheme`/`removeUserTheme` handler in the renderer — uninstall flows through `mp.uninstallTheme(slug)` which calls the IPC `theme:uninstall` and ultimately removes the directory. Locate the call site of `uninstallTheme` in the renderer.

- [ ] **Step 1: Locate the uninstall confirmation UI**

Run from workspace root: search the renderer for `uninstallTheme(`:

```bash
cd youcoded/desktop && grep -rn "uninstallTheme(" src/renderer/
```

Expected: a handful of matches, likely in a theme-detail overlay or settings panel. Open the file with the user-facing confirmation.

- [ ] **Step 2: Update the confirmation copy conditionally**

When the call site already has access to the `ThemeRegistryEntryWithStatus` (it should — that's what cards open), branch the confirm() string on `entry.isLocal`:

```tsx
const confirmCopy = entry.isLocal
  ? `Permanently delete "${entry.name}"? This theme was built locally — there's no marketplace copy, so the files will be removed forever and can't be recovered.`
  : `Uninstall "${entry.name}"? You can reinstall it later from the marketplace.`;

if (!window.confirm(confirmCopy)) return;
await mp.uninstallTheme(entry.slug);
```

(If the existing UI uses a custom modal rather than `window.confirm`, branch the modal's copy field instead — same shape.)

- [ ] **Step 3: Manual verification**

Try to delete a local theme — confirm dialog says "Permanently delete..." Cancel it. Try to delete a marketplace-installed theme — confirm dialog says "Uninstall..."

- [ ] **Step 4: Commit and merge Phase 1**

```bash
git add -p  # stage just the deletion-copy change
git commit -m "feat(themes): emphasize permanence when deleting a local theme"
```

Then merge the worktree branch back per `youcoded-dev/CLAUDE.md` rules:

```bash
cd youcoded
git checkout master
git pull origin master
git merge --no-ff local-themes-library
git push origin master
git worktree remove ../youcoded-worktrees/local-themes-library
git branch -D local-themes-library
```

**Phase 1 ships independently.** After this lands, "After the Show" and any other local theme appear in Library → Themes → Installed (or Favorites if starred), with a Local badge + tooltip and permanent-deletion confirm. Preview images use the wallpaper as a fallback because there's no `preview.png` yet — Phase 2 fills that in.

---

## Phase 2 — Theme-builder: generate `preview.png` at finalize

**Repo:** `youcoded-dev/wecoded-marketplace` (the `wecoded-themes-plugin` source lives here at `wecoded-marketplace/wecoded-themes-plugin/`)
**Worktree:** `git worktree add wecoded-marketplace-worktrees/preview-on-finalize preview-on-finalize` from `wecoded-marketplace/`

### Task 2.1: Add a finalize step that runs the canonical preview script

**Files:**
- Modify: `wecoded-marketplace/wecoded-themes-plugin/skills/theme-builder/reference/phase2-finalize.md` (around line 95-101, between "validate contrast" and "confirm to user")

- [ ] **Step 1: Insert a new step in the finalize doc**

Open `phase2-finalize.md`. Currently the flow ends with Step 7 (validate contrast) → Step 8 (confirm + delete `_preview`). Insert a new Step 7.5 between them:

```markdown
## Step 7.5: Generate preview card image

Run the canonical preview generator from the workspace's wecoded-themes clone — this produces the `preview.png` that the app's Library uses for the local theme card AND that the publisher uploads to the marketplace PR (replacing the publisher's BrowserWindow-based fallback).

```bash
cd ~/youcoded-dev/wecoded-themes
[ -d node_modules ] || npm ci
[ -d node_modules/playwright ] && npx playwright install chromium --with-deps 2>&1 | tail -5 || true
node scripts/generate-previews.js <slug>
```

Output: `~/.claude/wecoded-themes/<slug>/preview.png` (~150-300 KB at 800×500). The script prints `done: <slug> -> preview.png (<size> KB)` on success.

If the script fails (Playwright dependency error, etc.), don't block finalization — the publisher's fallback `theme-preview-generator.ts` will produce one at publish time, and the app's Library card will fall back to the wallpaper image. Tell the user the failure was non-fatal.
```

- [ ] **Step 2: Update the SKILL.md "before finalizing" checklist**

Open `wecoded-marketplace/wecoded-themes-plugin/skills/theme-builder/SKILL.md`. Find the "Before finalizing theme pack (Phase 2)" checklist near the bottom. Add a line:

```markdown
- [ ] `preview.png` generated via `wecoded-themes/scripts/generate-previews.js <slug>` (Step 7.5) — fallback OK if Playwright unavailable
```

- [ ] **Step 3: Smoke-test the script invocation**

```bash
cd ~/youcoded-dev/wecoded-themes
node scripts/generate-previews.js after-the-show
ls -la ~/.claude/wecoded-themes/after-the-show/preview.png
```

Expected: PNG file exists, size 150–500 KB. Open it in an image viewer — should show a mocked YouCoded UI in the After the Show theme.

- [ ] **Step 4: Commit**

```bash
cd wecoded-marketplace
git add wecoded-themes-plugin/skills/theme-builder/reference/phase2-finalize.md wecoded-themes-plugin/skills/theme-builder/SKILL.md
git commit -m "feat(theme-builder): generate preview.png at finalize via canonical script"
```

### Task 2.2: Verify the live skill picks up the new step

**Files:** None — runtime verification only.

- [ ] **Step 1: Reinstall the bundled plugin**

The `wecoded-themes-plugin` is bundled and auto-installed by the app on launch. After committing to `master` of `wecoded-marketplace`, the next app launch refreshes the install. Force a refresh:

```bash
cp wecoded-marketplace/wecoded-themes-plugin/skills/theme-builder/reference/phase2-finalize.md \
   ~/.claude/plugins/marketplaces/youcoded/plugins/wecoded-themes-plugin/skills/theme-builder/reference/phase2-finalize.md
```

(In a fresh user environment, the auto-update on launch handles this.)

- [ ] **Step 2: Run /theme-builder end-to-end on a throwaway theme**

In Claude Code, invoke `/wecoded-themes-plugin:theme-builder` and walk through a quick concept → Phase 2 build for a "test-preview-gen" theme. Confirm the model executes the new Step 7.5 and writes `preview.png`. Verify the file exists.

- [ ] **Step 3: Verify Library shows the preview**

Open the YouCoded Library → Themes tab. The newly-built test theme should appear in Installed themes with `preview.png` rendered as the card image (not the wallpaper fallback).

- [ ] **Step 4: Cleanup test theme + merge Phase 2**

```bash
rm -rf ~/.claude/wecoded-themes/test-preview-gen
cd wecoded-marketplace
git checkout master && git pull origin master
git merge --no-ff preview-on-finalize
git push origin master
git worktree remove ../wecoded-marketplace-worktrees/preview-on-finalize
git branch -D preview-on-finalize
```

---

## Phase 3 — Publisher: skip regeneration when local preview is fresh

**Repo:** `youcoded-dev/youcoded`
**Worktree:** `git worktree add youcoded-worktrees/publisher-skip-fresh-preview publisher-skip-fresh-preview` from `youcoded/`
**Why:** The publisher currently always regenerates `preview.png` at publish time (line 384 of `theme-marketplace-provider.ts`), overwriting the canonical one theme-builder produced. Skip the regeneration when the local preview is newer than `manifest.json` — the user-supplied one wins.

### Task 3.1: Skip publisher's `generateThemePreview` when local file is fresh

**Files:**
- Modify: `desktop/src/main/theme-marketplace-provider.ts:382-387` (the `// 4. Generate preview image` block)
- Test: `desktop/tests/publisher-preview-freshness.test.ts` (create)

- [ ] **Step 1: Write the failing test**

```ts
// desktop/tests/publisher-preview-freshness.test.ts
import { describe, it, expect } from 'vitest';
import { isPreviewFresh } from '../src/main/theme-marketplace-provider';
import fs from 'fs';
import os from 'os';
import path from 'path';

describe('isPreviewFresh', () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'preview-fresh-'));
  const manifestPath = path.join(tmp, 'manifest.json');
  const previewPath = path.join(tmp, 'preview.png');

  it('returns false when preview.png does not exist', () => {
    fs.writeFileSync(manifestPath, '{}');
    expect(isPreviewFresh(tmp)).toBe(false);
  });

  it('returns true when preview.png mtime is newer than manifest.json', () => {
    fs.writeFileSync(manifestPath, '{}');
    // ensure manifest is older
    const past = new Date(Date.now() - 60_000);
    fs.utimesSync(manifestPath, past, past);
    fs.writeFileSync(previewPath, 'png');
    expect(isPreviewFresh(tmp)).toBe(true);
  });

  it('returns false when preview.png mtime is older than manifest.json', () => {
    fs.writeFileSync(previewPath, 'png');
    const past = new Date(Date.now() - 60_000);
    fs.utimesSync(previewPath, past, past);
    fs.writeFileSync(manifestPath, '{}');
    expect(isPreviewFresh(tmp)).toBe(false);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd youcoded/desktop && npx vitest run tests/publisher-preview-freshness.test.ts`
Expected: FAIL — `isPreviewFresh` not exported.

- [ ] **Step 3: Add the helper and use it in publishTheme**

Open `desktop/src/main/theme-marketplace-provider.ts`. Near the top of the file (after imports, before the class), add:

```ts
export function isPreviewFresh(themeDir: string): boolean {
  const previewPath = path.join(themeDir, 'preview.png');
  const manifestPath = path.join(themeDir, 'manifest.json');
  try {
    if (!fs.existsSync(previewPath) || !fs.existsSync(manifestPath)) return false;
    return fs.statSync(previewPath).mtimeMs > fs.statSync(manifestPath).mtimeMs;
  } catch {
    return false;
  }
}
```

Then update the `// 4. Generate preview image` block (lines 382-387). Replace:

```ts
    // 4. Generate preview image
    try {
      await generateThemePreview(themeDir, manifest);
    } catch (err: any) {
      console.warn('[ThemeMarketplace] Preview generation failed (continuing without):', err.message);
    }
```

with:

```ts
    // 4. Use the local preview.png if it's fresher than manifest.json (theme-builder
    //    already generated it via wecoded-themes/scripts/generate-previews.js at finalize).
    //    Only fall back to BrowserWindow rendering when the local file is missing/stale.
    if (!isPreviewFresh(themeDir)) {
      try {
        await generateThemePreview(themeDir, manifest);
      } catch (err: any) {
        console.warn('[ThemeMarketplace] Preview generation failed (continuing without):', err.message);
      }
    } else {
      console.log('[ThemeMarketplace] Using existing fresh preview.png from theme-builder');
    }
```

- [ ] **Step 4: Run tests**

Run: `cd youcoded/desktop && npx vitest run tests/publisher-preview-freshness.test.ts`
Expected: all three cases PASS.

- [ ] **Step 5: Commit and merge Phase 3**

```bash
git add desktop/src/main/theme-marketplace-provider.ts desktop/tests/publisher-preview-freshness.test.ts
git commit -m "feat(themes): publisher honors theme-builder's fresh preview.png

Skip regeneration when preview.png mtime > manifest.json mtime — the theme-
builder generated it via the canonical wecoded-themes Playwright script and
overwriting it with the publisher's BrowserWindow capture would diverge from
what CI eventually produces."
cd youcoded
git checkout master && git pull origin master
git merge --no-ff publisher-skip-fresh-preview
git push origin master
git worktree remove ../youcoded-worktrees/publisher-skip-fresh-preview
git branch -D publisher-skip-fresh-preview
```

---

## Phase 4 — CI: honor a committed `preview.png`

**Repo:** `youcoded-dev/wecoded-themes`
**Worktree:** `git worktree add wecoded-themes-worktrees/ci-honor-existing-preview ci-honor-existing-preview` from `wecoded-themes/`
**Why:** `scripts/generate-previews.js` regenerates every theme's preview on merge to main. When the publisher PR ships a `preview.png` already, CI overwrites it. Skip regeneration when the file is committed in the PR so the user-supplied preview stays canonical.

### Task 4.1: Skip-when-exists in `generate-previews.js`

**Files:**
- Modify: `wecoded-themes/scripts/generate-previews.js` (the `generatePreview()` function around lines 365-391)

- [ ] **Step 1: Add a skip path early in `generatePreview`**

Open `wecoded-themes/scripts/generate-previews.js`. Find `generatePreview(browser, slug)` at line 365. Currently:

```js
async function generatePreview(browser, slug) {
  const themeDir = path.join(THEMES_DIR, slug);
  const manifestPath = path.join(themeDir, 'manifest.json');

  if (!fs.existsSync(manifestPath)) {
    console.log(`  skip: ${slug} (no manifest.json)`);
    return false;
  }

  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf-8'));
  const html = buildPreviewHTML(manifest, themeDir);
  const outputPath = path.join(themeDir, 'preview.png');
  // ... screenshot logic ...
}
```

Replace the lines after the `manifest = JSON.parse(...)` line and before `const html = buildPreviewHTML(...)` with:

```js
  const outputPath = path.join(themeDir, 'preview.png');

  // Honor a preview.png committed by the publisher PR — theme-builder generated
  // it via this same script at finalize, so regenerating here would just churn
  // the file and risk drift if someone changes the script between local and CI.
  // Skip when preview.png exists AND is newer than manifest.json.
  const force = process.env.FORCE_REGENERATE_PREVIEWS === '1';
  if (!force && fs.existsSync(outputPath)) {
    const previewMtime = fs.statSync(outputPath).mtimeMs;
    const manifestMtime = fs.statSync(manifestPath).mtimeMs;
    if (previewMtime >= manifestMtime) {
      const size = fs.statSync(outputPath).size;
      console.log(`  skip: ${slug} -> preview.png exists (${(size / 1024).toFixed(1)} KB, fresh)`);
      return false;
    }
  }

  const html = buildPreviewHTML(manifest, themeDir);
```

(The original `const outputPath = ...` line at line 376 is now moved up to before the skip check; remove the duplicate that was there.)

- [ ] **Step 2: Run the generator and confirm skip**

```bash
cd wecoded-themes
node scripts/generate-previews.js golden-sunbreak
```

Expected output: `  skip: golden-sunbreak -> preview.png exists (NNN.N KB, fresh)`

Then force-regenerate to confirm the escape hatch:

```bash
FORCE_REGENERATE_PREVIEWS=1 node scripts/generate-previews.js golden-sunbreak
```

Expected: `  done: golden-sunbreak -> preview.png (NNN.N KB)`

- [ ] **Step 3: Update the CI workflow to document the env var**

Open `wecoded-themes/.github/workflows/update-registry.yml`. Find the step that runs `node scripts/generate-previews.js`. Add a comment line above it:

```yaml
      # Skip themes whose preview.png was committed by the publisher PR (the
      # publisher generated it via the same script at finalize). Set
      # FORCE_REGENERATE_PREVIEWS=1 in workflow_dispatch input if you ever need
      # to regenerate everything (e.g. mockup-template change).
```

If the workflow has a `workflow_dispatch` block with inputs, add an optional input:

```yaml
on:
  push:
    branches: [main]
    paths: ['themes/**']
  workflow_dispatch:
    inputs:
      force_regenerate:
        description: 'Force-regenerate all theme previews (overrides skip-when-exists)'
        required: false
        default: 'false'
```

And in the script step, set the env conditionally:

```yaml
      - name: Generate preview PNGs
        env:
          FORCE_REGENERATE_PREVIEWS: ${{ github.event.inputs.force_regenerate == 'true' && '1' || '0' }}
        run: node scripts/generate-previews.js
```

- [ ] **Step 4: Commit and merge Phase 4**

```bash
cd wecoded-themes
git add scripts/generate-previews.js .github/workflows/update-registry.yml
git commit -m "ci(themes): skip preview regeneration when preview.png is committed

The publisher PR ships preview.png generated by theme-builder at finalize
using this same script. Regenerating in CI would overwrite the canonical
local-generated file. Skip when preview.png exists and is newer than
manifest.json. FORCE_REGENERATE_PREVIEWS=1 (or workflow_dispatch input) is
the escape hatch when the mockup template changes and we need a sweep."
git checkout main && git pull origin main
git merge --no-ff ci-honor-existing-preview
git push origin main
git worktree remove ../wecoded-themes-worktrees/ci-honor-existing-preview
git branch -D ci-honor-existing-preview
```

---

## Verification

After all four phases ship to master:

- [ ] **App-side end-to-end:**
  1. Build a fresh theme via `/wecoded-themes-plugin:theme-builder` (concept → kit → finalize).
  2. Confirm `preview.png` is written to `~/.claude/wecoded-themes/<slug>/`.
  3. Open Library → Themes. The new theme appears in Installed with the generated preview image and a "Local" badge with a (i) tooltip.
  4. Hover the (i) — tooltip says "Local only. Built by you with Claude — not in the marketplace, so it can't be shared or re-downloaded. Deleting it removes the files permanently."
  5. Try to delete it — confirm dialog says "Permanently delete..."

- [ ] **Publisher end-to-end:**
  1. From Library, open the new theme's detail and click Publish.
  2. Confirm the resulting PR contains `preview.png` matching the local file (byte-identical or close).
  3. After the PR merges, CI should log `skip: <slug> -> preview.png exists (...fresh)` rather than regenerating.

- [ ] **Regression check:**
  1. Existing marketplace themes (e.g. `golden-sunbreak`) still appear in Library with their registry-supplied preview.
  2. Their cards do NOT show the "Local" badge.
  3. Their delete confirms still say "Uninstall...", not "Permanently delete..."

---

## Self-Review Notes

- **Type consistency:** `ThemeRegistryEntryWithStatus.isLocal` is the only new field; it's added in Task 1.1 and consumed in Tasks 1.4, 1.6 only. `synthesizeLocalThemeEntries` and `LocalThemeRecord` are introduced together in Task 1.2 and consumed in Task 1.2 only. `isPreviewFresh` introduced in Task 3.1, consumed in Task 3.1 only.
- **Spec coverage:** All four user requirements covered:
  1. Local themes in Library Installed section → Task 1.2 + 1.5.
  2. Distinct from marketplace-installed → `isLocal` flag + Task 1.4 badge + Task 1.6 deletion copy.
  3. Theme-builder generates the card → Task 2.1.
  4. Publisher consumes the card → Task 3.1 + Task 4.1.
- **No placeholders:** every step has executable commands or full code blocks.
