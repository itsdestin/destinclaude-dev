# Marketplace Mobile / Narrow-Viewport Responsive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the marketplace screen usable on phones, narrow remote browsers, and narrow desktop windows by switching to a list-row card variant, compact hero, sheet-based filters, and a touch-appropriate top bar below 640px.

**Architecture:** Pure-CSS responsive treatment where the DOM is identical between modes (top bar, hero); a small `useNarrowViewport` hook drives a `compact` prop where the DOM structure differs (cards, filter bar, grid). No platform branching. Single component tree, breakpoint-driven.

**Tech Stack:** React + TypeScript, Tailwind CSS, Vitest + @testing-library/react. Threshold: `(max-width: 639.98px)` matches Tailwind's `sm:` boundary at 640px.

**Spec:** `docs/superpowers/specs/2026-04-26-marketplace-mobile-responsive-design.md`

**Worktree note:** This is a multi-file renderer change. Per workspace `CLAUDE.md`: create a worktree before starting (`git -C youcoded worktree add ../youcoded-worktrees/marketplace-mobile mp-mobile`), and work in the `youcoded/` repo's worktree throughout. All paths in this plan are relative to that worktree.

---

## File Structure

| Path (relative to `youcoded/desktop/`) | Action | Responsibility |
|---|---|---|
| `src/renderer/hooks/use-narrow-viewport.ts` | Create | matchMedia-based hook, single source of truth for the 640px threshold |
| `tests/use-narrow-viewport.test.ts` | Create | Hook unit test (matchMedia mock + change event) |
| `src/renderer/components/marketplace/MarketplaceCard.tsx` | Modify | Add `compact?: boolean` prop and a list-row layout branch |
| `tests/marketplace-card-compact.test.tsx` | Create | Render-test the compact and wide layouts |
| `src/renderer/components/marketplace/MarketplaceGrid.tsx` | Modify | Switch container layout via `useNarrowViewport`; pass `compact` to children |
| `src/renderer/components/marketplace/MarketplaceHero.tsx` | Modify | Pure-CSS responsive variant (no JS branch) |
| `src/renderer/components/marketplace/MarketplaceScreen.tsx` | Modify | Top bar swap (Esc-hint ↔ back arrow) via responsive Tailwind classes |
| `src/renderer/components/marketplace/MarketplaceFilterBar.tsx` | Modify | Collapse to search + Filters button at narrow; add `FilterSheet` sub-component |

---

## Task 1: `useNarrowViewport` hook

**Files:**
- Create: `youcoded/desktop/src/renderer/hooks/use-narrow-viewport.ts`
- Test: `youcoded/desktop/tests/use-narrow-viewport.test.ts`

- [ ] **Step 1: Write the failing test**

Create `youcoded/desktop/tests/use-narrow-viewport.test.ts`:

```ts
// @vitest-environment jsdom
// Unit test for useNarrowViewport — matchMedia-based hook returning true when
// viewport is below the marketplace mobile breakpoint (640px).

import React from 'react';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, cleanup, act } from '@testing-library/react';
import { useNarrowViewport } from '../src/renderer/hooks/use-narrow-viewport';

// Build a fake MediaQueryList we can mutate to simulate viewport changes.
function installMatchMediaMock(initialMatches: boolean) {
  let matches = initialMatches;
  const listeners = new Set<(e: MediaQueryListEvent) => void>();
  const mql = {
    get matches() { return matches; },
    media: '(max-width: 639.98px)',
    onchange: null,
    addEventListener: (_t: string, cb: any) => { listeners.add(cb); },
    removeEventListener: (_t: string, cb: any) => { listeners.delete(cb); },
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: () => true,
  };
  (window as any).matchMedia = (q: string) => {
    mql.media = q;
    return mql;
  };
  return {
    setMatches(next: boolean) {
      matches = next;
      listeners.forEach((cb) => cb({ matches: next } as MediaQueryListEvent));
    },
  };
}

function HookProbe({ onValue }: { onValue: (v: boolean) => void }) {
  const v = useNarrowViewport();
  onValue(v);
  return null;
}

describe('useNarrowViewport', () => {
  beforeEach(() => {
    (globalThis as any).window = (globalThis as any).window ?? {};
  });
  afterEach(() => {
    cleanup();
    delete (window as any).matchMedia;
  });

  it('returns false initially when viewport is wide', () => {
    installMatchMediaMock(false);
    const observed: boolean[] = [];
    render(<HookProbe onValue={(v) => observed.push(v)} />);
    // Last observed value (post-effect) should be false.
    expect(observed[observed.length - 1]).toBe(false);
  });

  it('returns true initially when viewport is narrow', () => {
    installMatchMediaMock(true);
    const observed: boolean[] = [];
    render(<HookProbe onValue={(v) => observed.push(v)} />);
    expect(observed[observed.length - 1]).toBe(true);
  });

  it('updates when the viewport crosses the breakpoint', () => {
    const ctl = installMatchMediaMock(false);
    const observed: boolean[] = [];
    render(<HookProbe onValue={(v) => observed.push(v)} />);
    expect(observed[observed.length - 1]).toBe(false);

    act(() => { ctl.setMatches(true); });
    expect(observed[observed.length - 1]).toBe(true);

    act(() => { ctl.setMatches(false); });
    expect(observed[observed.length - 1]).toBe(false);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd youcoded/desktop && npx vitest run tests/use-narrow-viewport.test.ts
```

Expected: FAIL with module-not-found error for `../src/renderer/hooks/use-narrow-viewport`.

- [ ] **Step 3: Implement the hook**

Create `youcoded/desktop/src/renderer/hooks/use-narrow-viewport.ts`:

```ts
// Matches Tailwind's sm: boundary at 640px. Returned boolean is true when the
// viewport is < 640px. Single source of truth for the marketplace mobile
// breakpoint — used wherever the DOM structure (not just classes) needs to
// branch between the wide and narrow layouts.

import { useEffect, useState } from 'react';

const QUERY = '(max-width: 639.98px)';

export function useNarrowViewport(): boolean {
  // false during SSR / before mount; updated synchronously inside the effect
  // so first paint after mount reflects the real viewport.
  const [narrow, setNarrow] = useState(false);
  useEffect(() => {
    const mql = window.matchMedia(QUERY);
    setNarrow(mql.matches);
    const onChange = (e: MediaQueryListEvent) => setNarrow(e.matches);
    mql.addEventListener('change', onChange);
    return () => mql.removeEventListener('change', onChange);
  }, []);
  return narrow;
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd youcoded/desktop && npx vitest run tests/use-narrow-viewport.test.ts
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add desktop/src/renderer/hooks/use-narrow-viewport.ts desktop/tests/use-narrow-viewport.test.ts
git commit -m "feat(marketplace): useNarrowViewport hook for mobile breakpoint detection"
```

---

## Task 2: `MarketplaceCard` compact prop + list-row layout

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/marketplace/MarketplaceCard.tsx`
- Test: `youcoded/desktop/tests/marketplace-card-compact.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `youcoded/desktop/tests/marketplace-card-compact.test.tsx`:

```tsx
// @vitest-environment jsdom
// Render tests for MarketplaceCard's compact list-row variant. Confirms:
// - compact=true switches the outer container to flex-row layout
// - compact=true hides InstallFavoriteCorner (no absolute corner affordance)
// - compact=true renders the right-column status pill via the status badge

import React from 'react';
import { describe, it, expect, afterEach } from 'vitest';
import { render, cleanup } from '@testing-library/react';
import MarketplaceCard from '../src/renderer/components/marketplace/MarketplaceCard';
import { MarketplaceContext } from '../src/renderer/state/marketplace-context';
import { MarketplaceStatsContext } from '../src/renderer/state/marketplace-stats-context';
import type { SkillEntry } from '../src/shared/types';

// Minimal stub providers — MarketplaceCard reads these contexts but the
// compact-layout tests don't need real install/favorite behavior.
const stubMpContext: any = {
  installingIds: new Set<string>(),
  favorites: [] as string[],
  themeFavorites: [] as string[],
  installSkill: () => Promise.resolve(),
  installTheme: () => Promise.resolve(),
  setFavorite: () => Promise.resolve(),
  favoriteTheme: () => Promise.resolve(),
};
const stubStatsContext: any = { plugins: {}, themes: {} };

const sampleSkill: SkillEntry = {
  id: 'sample-skill',
  displayName: 'Sample Skill',
  description: 'A sample',
  tagline: 'Quick description',
  author: 'Tester',
  category: 'productivity',
  prompt: '/sample',
  source: 'marketplace',
  type: 'plugin',
  visibility: 'published',
  components: null,
  lifeArea: [],
  tags: [],
} as any;

function renderWithProviders(ui: React.ReactElement) {
  return render(
    <MarketplaceContext.Provider value={stubMpContext}>
      <MarketplaceStatsContext.Provider value={stubStatsContext}>
        {ui}
      </MarketplaceStatsContext.Provider>
    </MarketplaceContext.Provider>
  );
}

describe('MarketplaceCard compact variant', () => {
  afterEach(cleanup);

  it('renders the wide layout with InstallFavoriteCorner when compact is unset', () => {
    const { container, queryByLabelText } = renderWithProviders(
      <MarketplaceCard
        item={{ kind: 'skill', entry: sampleSkill }}
        onOpen={() => {}}
      />
    );
    // Wide layout uses flex-col internally on the body. The corner Install
    // button has aria-label="Install".
    expect(queryByLabelText('Install')).not.toBeNull();
    // Outer container has neither the compact row classes nor the absolute
    // corner suppressed.
    const outer = container.firstChild as HTMLElement;
    expect(outer.getAttribute('data-marketplace-card')).toBe('sample-skill');
  });

  it('renders the compact list-row layout when compact=true', () => {
    const { container, queryByLabelText } = renderWithProviders(
      <MarketplaceCard
        item={{ kind: 'skill', entry: sampleSkill }}
        onOpen={() => {}}
        compact
      />
    );
    // Compact layout: outer container is a flex-row, no corner Install button.
    const outer = container.firstChild as HTMLElement;
    expect(outer.getAttribute('data-marketplace-card-compact')).toBe('true');
    // The corner affordance is hidden in compact mode — install moves to the
    // right column or detail overlay.
    expect(queryByLabelText('Install')).toBeNull();
  });

  it('shows the title and tagline in compact mode', () => {
    const { getByText } = renderWithProviders(
      <MarketplaceCard
        item={{ kind: 'skill', entry: sampleSkill }}
        onOpen={() => {}}
        compact
      />
    );
    expect(getByText('Sample Skill')).toBeTruthy();
    expect(getByText('Quick description')).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd youcoded/desktop && npx vitest run tests/marketplace-card-compact.test.tsx
```

Expected: FAIL — the compact prop doesn't exist yet, so the second test ("renders the compact list-row layout") fails to find `data-marketplace-card-compact`. (The first test should pass; it asserts existing behavior.)

- [ ] **Step 3: Add the `compact` prop and split the render path**

Edit `youcoded/desktop/src/renderer/components/marketplace/MarketplaceCard.tsx`. Add `compact?: boolean` to the `Props` interface, threaded into the component signature, and add a list-row branch.

Replace the existing `Props` interface to add the new field:

```ts
interface Props {
  item: MarketplaceCardEntry;
  onOpen(): void;
  installed?: boolean;
  updateAvailable?: boolean;
  iconUrl?: string;
  accentColor?: string;
  suppressCorner?: boolean;
  statusBadge?: {
    text: string;
    tone: 'ok' | 'warn' | 'err' | 'neutral' | 'locked';
  };
  pluginBadge?: {
    name: string;
    onClick: () => void;
  };
  /** When true, render as a horizontal list row optimized for narrow viewports.
   *  Used by MarketplaceGrid below 640px. Rails always pass false (omit). */
  compact?: boolean;
}
```

Update the function signature to destructure `compact`:

```ts
export default function MarketplaceCard({
  item, onOpen, installed, updateAvailable, iconUrl, accentColor,
  suppressCorner, statusBadge, pluginBadge, compact,
}: Props) {
```

After the existing data derivations (the block ending with `const showIcon = !!iconUrl && !iconFailed;`) and BEFORE the existing `return (` that renders the wide card, insert:

```tsx
  // Compact list-row layout for narrow viewports. Outer click and keyboard
  // affordance match the wide layout so detail overlays open the same way.
  if (compact) {
    // Resolve a 52x52 thumbnail. Order: explicit iconUrl, then theme preview,
    // then first-letter fallback on accent-tinted background.
    const themeThumb = item.kind === 'theme' ? item.entry.preview : undefined;
    const fallbackLetter = title.slice(0, 1).toUpperCase();

    // Status pill: "Local" for local themes wins over generic Installed/Update,
    // since local themes are always "installed" but the more interesting fact
    // is that they're not in the marketplace.
    const compactStatus: { text: string; tone: 'ok' | 'warn' | 'err' | 'neutral' | 'locked' } | null = statusBadge
      ? statusBadge
      : isLocalTheme
        ? { text: 'Local', tone: 'neutral' }
        : isInstalling
          ? { text: 'Installing…', tone: 'neutral' }
          : updateAvailable
            ? { text: 'Update', tone: 'warn' }
            : isInstalled
              ? { text: 'Installed', tone: 'neutral' }
              : null;

    return (
      <div
        role="button"
        tabIndex={0}
        onClick={onOpen}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            onOpen();
          }
        }}
        className="layer-surface flex flex-row items-center gap-3 p-3 text-left transition-colors hover:bg-inset focus:outline-none focus-visible:ring-2 focus-visible:ring-accent"
        data-marketplace-card={id}
        data-marketplace-card-compact="true"
        style={accentColor ? { borderColor: accentColor } : undefined}
      >
        {/* 52x52 thumbnail. Themes use a tiny preview crop; integrations use
            their iconUrl; otherwise a first-letter chip on accent. */}
        <div
          className="w-[52px] h-[52px] rounded-md shrink-0 overflow-hidden bg-inset flex items-center justify-center text-on-accent text-lg font-semibold"
          style={!showIcon && !themeThumb ? { background: accentColor || 'var(--accent)' } : undefined}
        >
          {showIcon ? (
            <img src={iconUrl!} alt="" className="w-full h-full object-contain" onError={() => setIconFailed(true)} />
          ) : themeThumb ? (
            <img src={themeThumb} alt="" className="w-full h-full object-cover" loading="lazy" />
          ) : (
            <span aria-hidden>{fallbackLetter}</span>
          )}
        </div>

        {/* Center column. min-w-0 is load-bearing — without it the truncate
            below stops working because the flex item can grow past parent. */}
        <div className="flex-1 min-w-0">
          <h3 className="font-medium text-fg truncate">{title}</h3>
          {author && <p className="text-xs text-fg-dim truncate">{author}</p>}
          {blurb && <p className="text-sm text-fg-2 line-clamp-1">{blurb}</p>}
          {(rating != null && ratingCount > 0) || installs > 0 || likes > 0 ? (
            <div className="mt-1 flex items-center gap-3 text-xs text-fg-dim">
              {rating != null && ratingCount > 0 && (
                <StarRating value={rating} count={ratingCount} size="sm" />
              )}
              {installs > 0 && <span>{installs.toLocaleString()} installs</span>}
              {likes > 0 && <span>{likes.toLocaleString()} likes</span>}
            </div>
          ) : null}
        </div>

        {/* Right column. Status pill on top; if the skill is uninstalled and
            the corner isn't suppressed, an inline install button sits below
            so the row keeps its primary tap action (open detail) while
            preserving one-tap install. Themes route install through the
            detail overlay, so no inline install button for them. */}
        <div className="shrink-0 flex flex-col items-end gap-1.5">
          {compactStatus && (
            <span
              className={`text-[10px] uppercase tracking-wide px-2 py-0.5 rounded-full ${STATUS_TONE_CLASS[compactStatus.tone]}`}
            >
              {compactStatus.text}
            </span>
          )}
          {!suppressCorner && kind === 'skill' && !isInstalled && !isInstalling && (
            <button
              type="button"
              onClick={(e) => { e.stopPropagation(); install(); }}
              aria-label="Install"
              title="Install"
              className="p-2 rounded-md text-fg-dim hover:text-fg hover:bg-inset transition-colors"
            >
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
                <polyline points="7 10 12 15 17 10" />
                <line x1="12" y1="15" x2="12" y2="3" />
              </svg>
            </button>
          )}
        </div>
      </div>
    );
  }
```

The existing wide-layout `return (` block stays unchanged below this `if (compact)` branch.

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd youcoded/desktop && npx vitest run tests/marketplace-card-compact.test.tsx
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Run the full test suite to confirm nothing else broke**

```bash
cd youcoded/desktop && npm test
```

Expected: PASS — all existing marketplace tests still pass because the new `compact` prop defaults to `false` and the existing render path is unchanged.

- [ ] **Step 6: Commit**

```bash
cd youcoded
git add desktop/src/renderer/components/marketplace/MarketplaceCard.tsx desktop/tests/marketplace-card-compact.test.tsx
git commit -m "feat(marketplace): MarketplaceCard compact list-row variant"
```

---

## Task 3: `MarketplaceGrid` responsive switch

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/marketplace/MarketplaceGrid.tsx`

- [ ] **Step 1: Replace the grid implementation**

Replace the entire contents of `youcoded/desktop/src/renderer/components/marketplace/MarketplaceGrid.tsx` with:

```tsx
// Dense, responsive grid for search-mode + bottom catalog.
//
// At ≥ 640px: 2-/3-/4-column grid of vertical MarketplaceCard tiles.
// At < 640px: stacked flex-col list of MarketplaceCard rows in compact mode.
//
// Switching between the two modes structurally (rather than via pure CSS) lets
// the card itself swap layouts cleanly — pure CSS would require rendering both
// trees and hiding one. See docs/superpowers/specs/2026-04-26-marketplace-mobile-responsive-design.md.

import React, { isValidElement, cloneElement, Children } from "react";
import { useNarrowViewport } from "../../hooks/use-narrow-viewport";

interface Props {
  children: React.ReactNode;
  dense?: boolean;
}

export default function MarketplaceGrid({ children, dense }: Props) {
  const compact = useNarrowViewport();

  // Inject compact={true} into each MarketplaceCard child when compact is on.
  // Done here (rather than at the call site) so MarketplaceScreen doesn't need
  // to know about the breakpoint — its bottom-catalog and search-grid render
  // paths stay unchanged.
  const childrenWithCompact = compact
    ? Children.map(children, (child) => {
        if (!isValidElement(child)) return child;
        // Only the MarketplaceCard children opt into compact. If a different
        // component happens to be passed in, it just won't get the prop.
        return cloneElement(child as React.ReactElement<{ compact?: boolean }>, { compact: true });
      })
    : children;

  if (compact) {
    return (
      <div className={`flex flex-col gap-2 ${dense ? "panel-glass p-3 rounded-lg" : ""}`}>
        {childrenWithCompact}
      </div>
    );
  }

  return (
    <div className={`grid grid-cols-2 md:grid-cols-3 xl:grid-cols-4 gap-3 ${dense ? "panel-glass p-3 rounded-lg" : ""}`}>
      {childrenWithCompact}
    </div>
  );
}
```

- [ ] **Step 2: Run the full test suite**

```bash
cd youcoded/desktop && npm test
```

Expected: PASS — no test changes needed; the grid's contract didn't change for callers, and `useNarrowViewport` returns false in the JSDOM test environment by default.

- [ ] **Step 3: Run the type check**

```bash
cd youcoded/desktop && npm run build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
cd youcoded
git add desktop/src/renderer/components/marketplace/MarketplaceGrid.tsx
git commit -m "feat(marketplace): MarketplaceGrid switches to compact rows below 640px"
```

---

## Task 4: Compact `MarketplaceHero` (CSS-only)

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/marketplace/MarketplaceHero.tsx`

- [ ] **Step 1: Update the hero JSX with responsive Tailwind classes**

Edit `youcoded/desktop/src/renderer/components/marketplace/MarketplaceHero.tsx`. Find the `<section>` element and its inner content, and replace them with:

```tsx
    <section
      role="region"
      aria-label="Featured"
      className="layer-surface relative overflow-hidden min-h-[110px] sm:min-h-[180px] p-4 sm:p-6 flex flex-col justify-end gap-2"
      style={slot.accentColor ? { borderColor: slot.accentColor } : undefined}
    >
      <div className="relative z-10">
        <p className="text-xs uppercase tracking-wide text-fg-dim">Featured</p>
        <h2 className="text-base sm:text-2xl font-semibold text-fg">
          {entry?.displayName || slot.id}
        </h2>
        <p className="text-sm text-fg-2 max-w-xl mt-1 line-clamp-1 sm:line-clamp-none">{slot.blurb}</p>
        <button
          type="button"
          onClick={() => onOpen(slot.id)}
          className="mt-3 self-start px-3 py-1.5 rounded-md bg-accent text-on-accent text-sm font-medium hover:opacity-90 transition-opacity"
        >
          View details
        </button>
      </div>
      {slots.length > 1 && (
        <div className="absolute bottom-3 right-4 flex gap-1.5 z-10">
          {slots.map((_, i) => (
            <button
              key={i}
              type="button"
              aria-label={`Go to slot ${i + 1}`}
              onClick={() => setIndex(i)}
              className={`w-2 h-2 rounded-full transition-opacity ${i === index ? "bg-fg opacity-90" : "bg-fg-dim opacity-40 hover:opacity-70"}`}
            />
          ))}
        </div>
      )}
    </section>
```

The only changes from the original are: `min-h-[110px] sm:min-h-[180px]`, `p-4 sm:p-6`, `text-base sm:text-2xl`, and `line-clamp-1 sm:line-clamp-none` on the blurb.

- [ ] **Step 2: Run the build**

```bash
cd youcoded/desktop && npm run build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
cd youcoded
git add desktop/src/renderer/components/marketplace/MarketplaceHero.tsx
git commit -m "feat(marketplace): compact hero variant below 640px"
```

---

## Task 5: Top bar mobile treatment (CSS-only)

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/marketplace/MarketplaceScreen.tsx`

- [ ] **Step 1: Update the top bar JSX**

Edit `youcoded/desktop/src/renderer/components/marketplace/MarketplaceScreen.tsx`. Find the top-bar block (around line 259, the `<div className="flex items-center justify-between p-3">` and its children), and replace the entire top-bar `<div>` with:

```tsx
      {/* Top bar — stays visible on scroll; holds Auth, title, library, exit. */}
      <div className="flex items-center justify-between gap-2 p-3">
        <div className="flex items-center gap-2 pl-2 min-w-0">
          <MarketplaceAuthChip />
          <h1 className="text-xl font-semibold text-fg truncate">Marketplace</h1>
        </div>
        <div className="flex items-center gap-2 shrink-0">
          {onOpenLibrary && (
            <button
              type="button"
              onClick={onOpenLibrary}
              className="text-fg-2 hover:text-fg text-sm px-3 py-1 rounded-md border border-edge-dim hover:border-edge"
              aria-label="Open Your Library"
            >
              {/* Full label at sm+, abbreviated below — keeps the row to one line on a 360-wide phone. */}
              <span className="hidden sm:inline">Your Library</span>
              <span className="sm:hidden">Lib</span>
            </button>
          )}
          <button
            type="button"
            onClick={onExit}
            className="text-fg-dim hover:text-fg text-sm px-2 py-1"
            aria-label="Exit marketplace"
          >
            {/* Esc hint on desktop where there's an Esc key; back arrow on touch. */}
            <span className="hidden sm:inline">Esc · Back to chat</span>
            <span className="sm:hidden" aria-hidden>←</span>
          </button>
        </div>
      </div>
```

Changes from the original: added `gap-2` to the outer flex (prevents children touching); added `min-w-0` to the left cluster so the `truncate` on the title actually clips on tiny widths; added `shrink-0` to the right cluster so it doesn't lose room to the title; added the `<span>` swap pairs inside the two right-side buttons.

- [ ] **Step 2: Run the build**

```bash
cd youcoded/desktop && npm run build
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
cd youcoded
git add desktop/src/renderer/components/marketplace/MarketplaceScreen.tsx
git commit -m "feat(marketplace): mobile top-bar variant below 640px"
```

---

## Task 6: Filter bar collapse + `FilterSheet`

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/marketplace/MarketplaceFilterBar.tsx`

- [ ] **Step 1: Replace the filter-bar implementation**

Replace the entire contents of `youcoded/desktop/src/renderer/components/marketplace/MarketplaceFilterBar.tsx` with:

```tsx
// Sticky chip bar — type, vibe, meta, search.
//
// At ≥ 640px: chips render inline (current behavior).
// At < 640px: only the search input + a "Filters" button render in the sticky
//   bar; tapping the button opens a bottom-anchored FilterSheet that hosts the
//   same chip groups stacked vertically. State shape and toggle logic are
//   unchanged — the sheet is just a different layout container.
//
// Active count for the Filters button: (type ? 1 : 0) + vibes.size + meta.size.
// The query is excluded since it's already visible in the search input.

import React, { useState } from "react";
import { Scrim, OverlayPanel } from "../overlays/Overlay";
import { useEscClose } from "../../hooks/use-esc-close";
import { useNarrowViewport } from "../../hooks/use-narrow-viewport";

export type TypeChip = "skill" | "theme";
export type MetaChip = "new" | "popular" | "picks";

const VIBES = ["school", "work", "creative", "health", "personal", "finance", "home"] as const;
export type VibeChip = typeof VIBES[number];

export interface FilterState {
  type: TypeChip | null;
  vibes: Set<VibeChip>;
  meta: Set<MetaChip>;
  query: string;
}

export function emptyFilter(): FilterState {
  return { type: null, vibes: new Set(), meta: new Set(), query: "" };
}

export function isActive(f: FilterState): boolean {
  return f.type !== null || f.vibes.size > 0 || f.meta.size > 0 || f.query.trim().length > 0;
}

function activeFilterCount(f: FilterState): number {
  return (f.type !== null ? 1 : 0) + f.vibes.size + f.meta.size;
}

interface Props {
  value: FilterState;
  onChange(next: FilterState): void;
}

export default function MarketplaceFilterBar({ value, onChange }: Props) {
  const compact = useNarrowViewport();
  const [sheetOpen, setSheetOpen] = useState(false);

  const toggleMulti = (key: "vibes" | "meta", v: any) => {
    const next = { ...value, vibes: new Set(value.vibes), meta: new Set(value.meta) };
    const set = next[key] as Set<any>;
    if (set.has(v)) set.delete(v); else set.add(v);
    onChange(next);
  };
  const setType = (t: TypeChip) => {
    onChange({ ...value, type: value.type === t ? null : t });
  };

  if (compact) {
    const count = activeFilterCount(value);
    return (
      <>
        <div className="layer-surface sticky top-0 z-20 flex items-center gap-2 p-2">
          <input
            type="search"
            placeholder="Search…"
            value={value.query}
            onChange={(e) => onChange({ ...value, query: e.target.value })}
            className="flex-1 min-w-0 bg-inset border border-edge rounded-md px-3 py-1.5 text-sm text-fg placeholder:text-fg-muted focus:outline-none focus:ring-2 focus:ring-accent"
          />
          <button
            type="button"
            onClick={() => setSheetOpen(true)}
            className="shrink-0 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm border border-edge-dim hover:border-edge text-fg-2 hover:text-fg"
            aria-label={count > 0 ? `Filters (${count} active)` : 'Filters'}
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
              <line x1="4" y1="6" x2="20" y2="6" />
              <line x1="6" y1="12" x2="18" y2="12" />
              <line x1="9" y1="18" x2="15" y2="18" />
            </svg>
            <span>Filters</span>
            {count > 0 && (
              <span className="text-[10px] px-1.5 py-0.5 rounded-full bg-accent text-on-accent leading-none">{count}</span>
            )}
          </button>
        </div>
        {sheetOpen && (
          <FilterSheet
            value={value}
            onChange={onChange}
            onClose={() => setSheetOpen(false)}
            toggleMulti={toggleMulti}
            setType={setType}
          />
        )}
      </>
    );
  }

  // Wide layout — unchanged from before the mobile redesign.
  return (
    <div className="layer-surface sticky top-0 z-20 flex flex-wrap items-center gap-2 p-3">
      <ChipGroup label="Type">
        <Chip active={value.type === "skill"} onClick={() => setType("skill")}>Plugins</Chip>
        <Chip active={value.type === "theme"} onClick={() => setType("theme")}>Themes</Chip>
      </ChipGroup>
      <Divider />
      <ChipGroup label="Vibe">
        {VIBES.map((v) => (
          <Chip key={v} active={value.vibes.has(v)} onClick={() => toggleMulti("vibes", v)}>
            {v[0].toUpperCase() + v.slice(1)}
          </Chip>
        ))}
      </ChipGroup>
      <Divider />
      <ChipGroup label="Meta">
        <Chip active={value.meta.has("new")} onClick={() => toggleMulti("meta", "new")}>New</Chip>
        <Chip active={value.meta.has("popular")} onClick={() => toggleMulti("meta", "popular")}>Popular</Chip>
        <Chip active={value.meta.has("picks")} onClick={() => toggleMulti("meta", "picks")}>Destin's picks</Chip>
      </ChipGroup>
      <div className="w-full sm:w-auto sm:ml-auto">
        <input
          type="search"
          placeholder="Search…"
          value={value.query}
          onChange={(e) => onChange({ ...value, query: e.target.value })}
          className="bg-inset border border-edge rounded-md px-3 py-1.5 text-sm text-fg placeholder:text-fg-muted focus:outline-none focus:ring-2 focus:ring-accent w-full sm:w-48"
        />
      </div>
    </div>
  );
}

// Bottom-anchored sheet hosting the same chip groups stacked vertically. Built
// on the existing Scrim + OverlayPanel primitives so theme tokens (scrim color,
// blur, shadow, z-index) drive the look. Chip toggles update FilterState live —
// "Apply" is just a close affordance.
function FilterSheet({
  value, onChange, onClose, toggleMulti, setType,
}: {
  value: FilterState;
  onChange(next: FilterState): void;
  onClose(): void;
  toggleMulti(key: 'vibes' | 'meta', v: any): void;
  setType(t: TypeChip): void;
}) {
  useEscClose(true, onClose);

  const clearAll = () => {
    // Preserve the search query (it's still visible in the sticky bar) but
    // reset all chip selections.
    onChange({ ...emptyFilter(), query: value.query });
  };

  return (
    <>
      <Scrim layer={2} onClick={onClose} />
      <OverlayPanel
        layer={2}
        className="fixed inset-x-2 bottom-2 max-h-[80vh] overflow-y-auto rounded-2xl flex flex-col"
      >
        <header className="sticky top-0 z-10 flex items-center justify-between px-4 py-3 border-b border-edge-dim bg-panel">
          <h2 className="text-base font-semibold text-fg">Filters</h2>
          <button
            type="button"
            onClick={clearAll}
            className="text-sm text-fg-2 hover:text-fg"
          >
            Clear all
          </button>
        </header>
        <div className="flex-1 flex flex-col gap-4 p-4">
          <SheetGroup label="Type">
            <Chip active={value.type === "skill"} onClick={() => setType("skill")}>Plugins</Chip>
            <Chip active={value.type === "theme"} onClick={() => setType("theme")}>Themes</Chip>
          </SheetGroup>
          <SheetGroup label="Vibe">
            {VIBES.map((v) => (
              <Chip key={v} active={value.vibes.has(v)} onClick={() => toggleMulti("vibes", v)}>
                {v[0].toUpperCase() + v.slice(1)}
              </Chip>
            ))}
          </SheetGroup>
          <SheetGroup label="Meta">
            <Chip active={value.meta.has("new")} onClick={() => toggleMulti("meta", "new")}>New</Chip>
            <Chip active={value.meta.has("popular")} onClick={() => toggleMulti("meta", "popular")}>Popular</Chip>
            <Chip active={value.meta.has("picks")} onClick={() => toggleMulti("meta", "picks")}>Destin's picks</Chip>
          </SheetGroup>
        </div>
        <footer className="sticky bottom-0 z-10 px-4 py-3 border-t border-edge-dim bg-panel">
          <button
            type="button"
            onClick={onClose}
            className="w-full px-4 py-2 rounded-md bg-accent text-on-accent font-medium hover:opacity-90"
          >
            Apply
          </button>
        </footer>
      </OverlayPanel>
    </>
  );
}

function SheetGroup({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-2">
      <h3 className="text-xs uppercase tracking-wide text-fg-dim">{label}</h3>
      <div className="flex flex-wrap gap-2">{children}</div>
    </div>
  );
}

function Chip({ active, onClick, children }: { active: boolean; onClick(): void; children: React.ReactNode }) {
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={active}
      onClick={onClick}
      className={`px-3 py-1 rounded-full text-sm transition-colors ${
        active
          ? "bg-accent text-on-accent"
          : "bg-inset text-fg-2 hover:text-fg border border-edge hover:border-edge-dim"
      }`}
    >
      {children}
    </button>
  );
}

function ChipGroup({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center gap-1.5" aria-label={label}>
      {children}
    </div>
  );
}

function Divider() {
  return <span className="w-px h-5 bg-edge-dim mx-1" aria-hidden />;
}
```

- [ ] **Step 2: Run the full test suite**

```bash
cd youcoded/desktop && npm test
```

Expected: PASS — no marketplace tests reference the chip bar's internal layout, and the wide layout's DOM is unchanged.

- [ ] **Step 3: Run the build**

```bash
cd youcoded/desktop && npm run build
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
cd youcoded
git add desktop/src/renderer/components/marketplace/MarketplaceFilterBar.tsx
git commit -m "feat(marketplace): mobile filter bar collapses to search + sheet below 640px"
```

---

## Task 7: Visual verification

This task has no code edits — it's the dev-server + Android verification pass. Per the workspace `CLAUDE.md`: "For UI or frontend changes, start the dev server and use the feature in a browser before reporting the task as complete."

- [ ] **Step 1: Start the dev server and verify desktop responsive behavior**

```bash
cd /c/Users/desti/youcoded-dev
bash scripts/run-dev.sh
```

In the YouCoded Dev window:
1. Open the marketplace.
2. Resize the window to ≥ 640px. Verify: hero is tall and bold, filter bar shows all chip groups, bottom catalog is a 2/3/4-column grid with vertical cards, top-bar shows "Your Library" + "Esc · Back to chat".
3. Resize to < 640px. Verify: hero is short with smaller font and a 1-line blurb, filter bar shows search + Filters button, bottom catalog is a stacked list of compact rows, top-bar shows "Lib" + "←".
4. Tap "Filters" — sheet slides up from the bottom with Type / Vibe / Meta groups stacked. Toggle a chip; the count badge on the Filters button updates after dismiss.
5. Tap "Clear all" inside the sheet — chip selections clear, search input keeps its value.
6. Press Esc — sheet dismisses (only at ≥ 640px there's a real Esc key; on touch you'll use the scrim or Apply).
7. Verify rails (e.g., "Connect your stuff", "Destin's picks") at narrow still render full vertical cards at `~85vw` — they shouldn't switch to compact rows.

- [ ] **Step 2: Verify Android**

```bash
cd /c/Users/desti/youcoded-dev/youcoded
./scripts/build-web-ui.sh
./gradlew assembleDebug
./gradlew installDebug
```

On the device:
1. Open the YouCoded app, navigate to the marketplace.
2. Verify all checks from Step 1 (#3 onward) — the device viewport is naturally < 640px.
3. Verify the FilterSheet's bottom-anchored panel doesn't overlap the bottom system bar awkwardly. (`inset-x-2 bottom-2` should give it 8px clearance from each edge.)
4. Tap a list-row card — detail overlay opens with the same content as desktop.

- [ ] **Step 3: Verify remote browser at narrow viewport**

With the desktop dev server still running, visit the remote URL (typically `http://localhost:9950` for dev — see `scripts/run-dev.sh` output for the actual port). Open browser DevTools, switch to device emulation at 360×640, navigate to the marketplace. Re-run the checks from Step 1 (#3 onward).

- [ ] **Step 4: Push the worktree branch and shut down the dev server**

```bash
cd /c/Users/desti/youcoded-dev/youcoded-worktrees/marketplace-mobile  # or whatever path
git push -u origin mp-mobile
```

Per workspace `CLAUDE.md`: "Pushing to master green-lights closing the dev server." Once the work merges to master, kill the `run-dev.sh` process group and any orphaned Electron processes.

- [ ] **Step 5: Open a PR in the youcoded repo**

The PR description should reference the spec at `docs/superpowers/specs/2026-04-26-marketplace-mobile-responsive-design.md` and call out the breakpoint (640px) so reviewers know what to test.

---

## Self-Review Notes

**Spec coverage:**
- Top bar (spec §1) → Task 5 ✓
- Hero (spec §2) → Task 4 ✓
- Filter bar + sheet (spec §3) → Task 6 ✓
- Card list-row (spec §4) → Task 2 ✓
- Grid behavior (spec §5) → Task 3 ✓
- `useNarrowViewport` (spec §6) → Task 1 ✓
- Edge cases (spec §7) — Local theme badge, integration rail cards, theme-without-preview, sheet-during-resize — all handled inside Tasks 2 and 6 ✓
- Verification (spec §8) → Task 7 ✓

**Risk notes for the executor:**
- The `cloneElement` injection in Task 3 assumes children are `MarketplaceCard` elements. If a future caller passes a fragment or wrapper component, the `compact` prop won't reach the card. This is acceptable — current call sites in `MarketplaceScreen.tsx` pass cards directly.
- The wide-mode tests in `marketplace-card-compact.test.tsx` Step 1 assume `InstallFavoriteCorner` renders an `aria-label="Install"` button when the skill is uninstalled. Cross-reference `InstallFavoriteCorner.tsx` to confirm before claiming the test failed/passed for the wrong reason.
- The `useNarrowViewport` hook's initial `false` value means SSR or first paint shows the wide layout briefly before the effect resolves on mount. In this Electron + Android WebView app there's no SSR and the effect runs immediately — first paint flicker is not expected, but if you see one, the fix is to read `window.matchMedia` synchronously inside `useState`'s initializer.
