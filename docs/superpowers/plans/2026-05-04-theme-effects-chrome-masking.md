# Theme Effects Chrome Masking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce active-use GPU copy-engine load on themes that combine particles with chrome glassmorphism (e.g. `halftone-dimension` with `panels-blur: 20`) by masking the chrome regions out of the particle canvas, so chrome's `backdrop-filter` becomes a static-input cache hit instead of a per-frame recompute.

**Architecture:** Particle canvas stays full-window (so particle physics is unchanged), but a CSS `clip-path: path(evenodd, ...)` cuts rectangular holes wherever a glassmorphism chrome panel sits (header bar, status bar, input bar). Because nothing paints into the canvas's clipped regions, those regions don't appear in chrome's backdrop, and Chromium's backdrop-filter cache stops invalidating per frame. A small per-particle opacity falloff near each masked edge prevents particles from popping at sharp boundaries.

**Tech Stack:** React 18 hooks + refs, TypeScript, native browser APIs (`ResizeObserver`, `getBoundingClientRect`, CSS `clip-path: path()`), Vitest with jsdom for unit tests.

**Depends on:** PR #91 (`fix/theme-effects-visibility-gate`). Execute after #91 lands on `origin/master` so the visibility-gate logic is in place.

---

## File Structure

| Path | Purpose | Action |
|------|---------|--------|
| `youcoded/desktop/src/renderer/components/theme-effects-mask.ts` | Pure utilities: `buildChromeClipPath`, `chromeEdgeFalloff`, `ChromeRect` type | Create |
| `youcoded/desktop/src/renderer/hooks/useChromeGeometry.ts` | Hook that finds glass-chrome elements and tracks their bounding rects via `ResizeObserver` | Create |
| `youcoded/desktop/src/renderer/components/ThemeEffects.tsx` | Wire the hook + utilities in: apply `clipPath` to canvas, multiply per-particle opacity by chrome-edge falloff | Modify |
| `youcoded/desktop/tests/theme-effects-mask.test.ts` | Unit tests for the pure utilities | Create |
| `youcoded/desktop/tests/use-chrome-geometry.test.ts` | Unit tests for the hook (with mocked `ResizeObserver`) | Create |

The two pure utilities live alongside the only component that uses them; the hook follows the existing convention of one file per hook in `hooks/`. Tests sit next to existing `theme-*.test.ts` files in `desktop/tests/`.

---

## Setup (one-time)

- [ ] **Setup Step 1: Confirm PR #91 is merged**

```bash
cd /c/Users/desti/youcoded-dev/youcoded
git fetch origin
git log --oneline origin/master | head -5
```

Expected: a commit titled `fix(theme-effects): pause particle rAF when window is hidden` appears on `origin/master`.

If not yet merged: stop here. The visibility-gate change touches the same `useEffect` body this plan modifies; landing #91 first avoids a manual conflict.

- [ ] **Setup Step 2: Create the implementation worktree**

```bash
cd /c/Users/desti/youcoded-dev/youcoded
git worktree add ../youcoded.wt/theme-effects-chrome-mask -b fix/theme-effects-chrome-mask origin/master
```

Expected: worktree at `C:\Users\desti\youcoded-dev\youcoded.wt\theme-effects-chrome-mask` on a fresh branch off the latest `origin/master`.

- [ ] **Setup Step 3: Junction `node_modules` from the main checkout**

Vitest and TypeScript need `node_modules`. Reuse the main checkout's tree to avoid a full `npm ci` in the worktree.

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/theme-effects-chrome-mask/desktop
cmd //c "mklink /J node_modules ..\\..\\..\\youcoded\\desktop\\node_modules"
ls node_modules | head -3
```

Expected: `@adobe`, `@alloc`, `@asamuzakjp` (or whatever first 3 packages exist). Confirms the junction works.

---

## Task 1: Empirical Verification (Pre-Code Sanity Check)

**Why first:** Items 1–6 below are ~80 lines of new code. Before writing them, verify the underlying theory: that hiding the canvas eliminates the GPU copy-engine load on `halftone-dimension`. If GPU still pegs with the canvas hidden, the masking strategy will not help and the plan needs to be revisited.

**Files:** None modified — this is a runtime probe in dev mode.

- [ ] **Step 1: Start dev mode against the worktree**

```bash
cd /c/Users/desti/youcoded-dev
YOUCODED_WT=youcoded.wt/theme-effects-chrome-mask bash scripts/run-dev.sh
```

Expected: a second Electron window labelled "YouCoded Dev" launches.

(If `run-dev.sh` doesn't accept that env var as a worktree pointer, run it from the worktree directly: `cd youcoded.wt/theme-effects-chrome-mask/desktop && npx vite & npx electron .`. Use whichever variant matches `scripts/run-dev.sh` in the current repo state.)

- [ ] **Step 2: Switch the dev instance to `halftone-dimension`**

In the dev window: Settings → Appearance → set theme to **Halftone Dimension**, ensure **Reduced Effects** is OFF.

- [ ] **Step 3: Capture baseline GPU usage**

In Task Manager → Details, locate the YouCoded process tree. Filter to children where command line contains `--type=gpu-process`. Note the GPU column percentage. (Or use the PowerShell snippet from the original investigation: `Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue` and grep for the YouCoded GPU PID's `engtype_copy` engine.)

Expected baseline: copy engine ≈ 100%.

- [ ] **Step 4: Hide the canvas in the running renderer**

In the dev window, open DevTools (`Ctrl+Shift+I`) → Console. Run:

```javascript
document.querySelector('canvas[aria-hidden="true"]').style.display = 'none'
```

Expected: particles disappear from the visible UI immediately.

- [ ] **Step 5: Measure GPU usage with canvas hidden**

Re-check the GPU process's copy engine percentage after ~5 seconds.

- **If copy engine drops to single digits:** theory confirmed. Re-show the canvas (`...style.display = ''`), close dev mode, proceed to Task 2.
- **If copy engine stays high:** the canvas is not the dominant driver of backdrop-filter recompute. Stop. Revisit the plan with the new evidence — likely culprits become CSS animations (`flowing-word-pan`, `breathe`, `challenge-pulse`) or some other dynamic source.

No commit for this task — it's a verification probe.

---

## Task 2: Pure Utilities (TDD)

**Files:**
- Create: `youcoded/desktop/src/renderer/components/theme-effects-mask.ts`
- Test: `youcoded/desktop/tests/theme-effects-mask.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `youcoded/desktop/tests/theme-effects-mask.test.ts`:

```typescript
import { describe, it, expect } from 'vitest';
import {
  buildChromeClipPath,
  chromeEdgeFalloff,
  type ChromeRect,
} from '../src/renderer/components/theme-effects-mask';

describe('buildChromeClipPath', () => {
  const viewport = { width: 1280, height: 720 };

  it('returns "none" when there are no rects (no clip applied)', () => {
    expect(buildChromeClipPath(viewport, [])).toBe('none');
  });

  it('produces an SVG path with the viewport outer rect plus one hole', () => {
    const rects: ChromeRect[] = [{ left: 0, top: 0, width: 1280, height: 40 }];
    const result = buildChromeClipPath(viewport, rects);
    expect(result.startsWith("path(evenodd, '")).toBe(true);
    expect(result).toContain('M 0 0 H 1280 V 720 H 0 Z');
    expect(result).toContain('M 0 0 H 1280 V 40 H 0 Z');
    expect(result.endsWith("')")).toBe(true);
  });

  it('emits a hole subpath for every rect, separated by spaces', () => {
    const rects: ChromeRect[] = [
      { left: 0, top: 0, width: 1280, height: 40 },
      { left: 0, top: 680, width: 1280, height: 40 },
    ];
    const result = buildChromeClipPath(viewport, rects);
    expect(result).toContain('M 0 0 H 1280 V 40 H 0 Z');
    expect(result).toContain('M 0 680 H 1280 V 720 H 0 Z');
  });
});

describe('chromeEdgeFalloff', () => {
  const FADE = 24;
  const rect: ChromeRect = { left: 100, top: 100, width: 200, height: 50 };

  it('returns 1 when there are no rects', () => {
    expect(chromeEdgeFalloff(50, 50, [], FADE)).toBe(1);
  });

  it('returns 1 for a particle far outside every rect', () => {
    expect(chromeEdgeFalloff(50, 50, [rect], FADE)).toBe(1);
  });

  it('returns 0 for a particle strictly inside a rect', () => {
    expect(chromeEdgeFalloff(150, 120, [rect], FADE)).toBe(0);
  });

  it('returns a smooth fraction within the fade band outside the rect', () => {
    // Particle 12px above the rect's top edge (rect top = 100, so y = 88 is 12px above)
    const m = chromeEdgeFalloff(150, 88, [rect], FADE);
    expect(m).toBeGreaterThan(0);
    expect(m).toBeLessThan(1);
    // 12 / 24 = 0.5
    expect(m).toBeCloseTo(0.5, 2);
  });

  it('uses the minimum (closest) rect when several rects are nearby', () => {
    const rectA: ChromeRect = { left: 100, top: 100, width: 100, height: 50 };
    const rectB: ChromeRect = { left: 100, top: 200, width: 100, height: 50 };
    // Particle at (150, 180) — 30px below A (well outside fade), 20px above B (inside fade band)
    const m = chromeEdgeFalloff(150, 180, [rectA, rectB], FADE);
    expect(m).toBeCloseTo(20 / 24, 2);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/theme-effects-chrome-mask/desktop
npx vitest run tests/theme-effects-mask.test.ts 2>&1 | tail -10
```

Expected: FAIL with module-not-found / cannot-find error referencing `theme-effects-mask`.

- [ ] **Step 3: Implement the utilities**

Create `youcoded/desktop/src/renderer/components/theme-effects-mask.ts`:

```typescript
// Pure helpers used by ThemeEffects to mask the particle canvas around
// glassmorphism chrome panels (header bar, status bar, input bar). Kept
// pure + free of React/DOM imports so the unit tests can run under jsdom
// without any browser stubs.

export interface ChromeRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** Builds a CSS `clip-path: path(evenodd, ...)` value that includes the
 *  whole viewport with rectangular holes punched out for each chrome rect.
 *  Even-odd fill rule means the inner subpaths subtract from the outer. */
export function buildChromeClipPath(
  viewport: { width: number; height: number },
  rects: ChromeRect[],
): string {
  if (rects.length === 0) return 'none';
  const outer = `M 0 0 H ${viewport.width} V ${viewport.height} H 0 Z`;
  const holes = rects
    .map(
      (r) =>
        `M ${r.left} ${r.top} H ${r.left + r.width} V ${r.top + r.height} H ${r.left} Z`,
    )
    .join(' ');
  return `path(evenodd, '${outer} ${holes}')`;
}

/** Returns an opacity multiplier in [0, 1] for a particle at (x, y) based
 *  on its distance to the nearest chrome rect.
 *  - 1.0 when the particle is at least `fadeDistance` pixels away from every rect
 *  - 0.0 when the particle is strictly inside any rect
 *  - linear ramp in the fade band between
 *  Used to soften the edge of the canvas clip so particles don't pop at
 *  the masked-rect boundary. */
export function chromeEdgeFalloff(
  x: number,
  y: number,
  rects: ChromeRect[],
  fadeDistance: number,
): number {
  if (rects.length === 0) return 1;
  let minMultiplier = 1;
  for (const r of rects) {
    const right = r.left + r.width;
    const bottom = r.top + r.height;
    // Component distances from the point to the rect — 0 if the point is
    // inside the corresponding axis range, positive if outside.
    const dx = Math.max(r.left - x, 0, x - right);
    const dy = Math.max(r.top - y, 0, y - bottom);
    const outside = Math.sqrt(dx * dx + dy * dy);
    if (outside === 0) return 0; // inside this rect
    if (outside < fadeDistance) {
      const m = outside / fadeDistance;
      if (m < minMultiplier) minMultiplier = m;
    }
  }
  return minMultiplier;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npx vitest run tests/theme-effects-mask.test.ts 2>&1 | tail -10
```

Expected: PASS — 7 tests passing (3 buildChromeClipPath + 5 chromeEdgeFalloff... wait, recount: the file has 3 + 5 = 8 tests).

If anything fails, fix the implementation to match the test expectations rather than relaxing the test.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/theme-effects-mask.ts desktop/tests/theme-effects-mask.test.ts
git commit -m "feat(theme-effects): add pure helpers for chrome-mask geometry"
```

---

## Task 3: `useChromeGeometry` Hook (TDD)

**Files:**
- Create: `youcoded/desktop/src/renderer/hooks/useChromeGeometry.ts`
- Test: `youcoded/desktop/tests/use-chrome-geometry.test.ts`

The hook needs `ResizeObserver`. jsdom does not ship one — the test mocks it via a global stub.

- [ ] **Step 1: Write the failing test**

Create `youcoded/desktop/tests/use-chrome-geometry.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { renderHook } from '@testing-library/react';
import { useChromeGeometry } from '../src/renderer/hooks/useChromeGeometry';

// Minimal ResizeObserver stub — captures observed elements and exposes a
// `trigger()` so tests can simulate a resize event on demand.
class StubResizeObserver {
  static instances: StubResizeObserver[] = [];
  cb: ResizeObserverCallback;
  observed = new Set<Element>();
  constructor(cb: ResizeObserverCallback) {
    this.cb = cb;
    StubResizeObserver.instances.push(this);
  }
  observe(el: Element) { this.observed.add(el); }
  unobserve(el: Element) { this.observed.delete(el); }
  disconnect() { this.observed.clear(); }
  trigger() { this.cb([], this); }
}

describe('useChromeGeometry', () => {
  let originalRO: typeof ResizeObserver;

  beforeEach(() => {
    originalRO = (globalThis as any).ResizeObserver;
    (globalThis as any).ResizeObserver = StubResizeObserver;
    StubResizeObserver.instances = [];
    document.body.innerHTML = '';
  });

  afterEach(() => {
    (globalThis as any).ResizeObserver = originalRO;
  });

  function makeChrome(className: string, rect: { left: number; top: number; width: number; height: number }) {
    const el = document.createElement('div');
    el.className = className;
    el.getBoundingClientRect = () =>
      ({
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
        right: rect.left + rect.width,
        bottom: rect.top + rect.height,
        x: rect.left,
        y: rect.top,
        toJSON: () => ({}),
      }) as DOMRect;
    document.body.appendChild(el);
    return el;
  }

  it('returns [] when no chrome elements exist', () => {
    const { result } = renderHook(() => useChromeGeometry());
    expect(result.current).toEqual([]);
  });

  it('returns rects for matched chrome elements on first render', () => {
    makeChrome('header-bar', { left: 0, top: 0, width: 1280, height: 40 });
    makeChrome('status-bar', { left: 0, top: 680, width: 1280, height: 40 });
    const { result } = renderHook(() => useChromeGeometry());
    expect(result.current).toEqual([
      { left: 0, top: 0, width: 1280, height: 40 },
      { left: 0, top: 680, width: 1280, height: 40 },
    ]);
  });

  it('updates rects when ResizeObserver fires', () => {
    const header = makeChrome('header-bar', { left: 0, top: 0, width: 1280, height: 40 });
    const { result } = renderHook(() => useChromeGeometry());
    expect(result.current[0].height).toBe(40);

    // Simulate the input bar growing — change the rect, then trigger the observer.
    header.getBoundingClientRect = () =>
      ({
        left: 0, top: 0, width: 1280, height: 60,
        right: 1280, bottom: 60, x: 0, y: 0, toJSON: () => ({}),
      }) as DOMRect;
    StubResizeObserver.instances[0].trigger();

    expect(result.current[0].height).toBe(60);
  });

  it('disconnects the observer on unmount', () => {
    makeChrome('header-bar', { left: 0, top: 0, width: 1280, height: 40 });
    const { unmount } = renderHook(() => useChromeGeometry());
    const obs = StubResizeObserver.instances[0];
    expect(obs.observed.size).toBe(1);
    unmount();
    expect(obs.observed.size).toBe(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
npx vitest run tests/use-chrome-geometry.test.ts 2>&1 | tail -10
```

Expected: FAIL with module-not-found referencing `useChromeGeometry`.

- [ ] **Step 3: Implement the hook**

Create `youcoded/desktop/src/renderer/hooks/useChromeGeometry.ts`:

```typescript
import { useEffect, useState } from 'react';
import type { ChromeRect } from '../components/theme-effects-mask';

// CSS classes of the always-on glassmorphism chrome panels. These are the
// elements whose backdrop-filter cost we want to make static. Dynamic
// overlays (.settings-drawer, .layer-surface popups) are intentionally
// excluded — masking them would require tracking show/hide/animate state
// and is not worth the complexity. Cost while a popup is open is a
// known, accepted trade-off documented in the plan.
const CHROME_SELECTORS = ['.header-bar', '.status-bar', '.input-bar-container'];

export function useChromeGeometry(): ChromeRect[] {
  const [rects, setRects] = useState<ChromeRect[]>([]);

  useEffect(() => {
    const elements = CHROME_SELECTORS
      .map((sel) => document.querySelector(sel))
      .filter((el): el is Element => el !== null);

    if (elements.length === 0) {
      setRects([]);
      return;
    }

    const measure = () => {
      const next = elements.map((el) => {
        const r = el.getBoundingClientRect();
        return { left: r.left, top: r.top, width: r.width, height: r.height };
      });
      setRects(next);
    };

    // Synchronous initial measurement avoids a frame where the canvas is
    // unmasked while React is still scheduling the first observer callback.
    measure();

    const observer = new ResizeObserver(measure);
    elements.forEach((el) => observer.observe(el));
    window.addEventListener('resize', measure);

    return () => {
      observer.disconnect();
      window.removeEventListener('resize', measure);
    };
  }, []);

  return rects;
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npx vitest run tests/use-chrome-geometry.test.ts 2>&1 | tail -10
```

Expected: PASS — 4 tests passing.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/hooks/useChromeGeometry.ts desktop/tests/use-chrome-geometry.test.ts
git commit -m "feat(theme-effects): add useChromeGeometry hook"
```

---

## Task 4: Wire `ThemeEffects` to Mask the Canvas

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/ThemeEffects.tsx`

There is no straightforward unit test for canvas drawing under jsdom (no real canvas backend). Verification for this task is the typecheck + the manual smoke test in Task 5.

- [ ] **Step 1: Add imports and the chrome-rects ref**

At the top of `ThemeEffects.tsx`, add the new imports next to the existing React import:

```typescript
import React, { useEffect, useRef, useState } from 'react';
import { useTheme } from '../state/theme-context';
import { useChromeGeometry } from '../hooks/useChromeGeometry';
import {
  buildChromeClipPath,
  chromeEdgeFalloff,
  type ChromeRect,
} from './theme-effects-mask';
```

(`useState` may already be imported; if so, leave it.)

Inside the `ThemeEffects` component body, after the existing `imgRef` declaration, add:

```typescript
  const chromeRects = useChromeGeometry();
  // Mirror the latest rects into a ref so the rAF closure (which is set
  // up once per [preset, ...] change) can read fresh values without
  // re-creating the animation loop on every chrome resize.
  const chromeRectsRef = useRef<ChromeRect[]>([]);
  useEffect(() => {
    chromeRectsRef.current = chromeRects;
  }, [chromeRects]);

  const [viewport, setViewport] = useState(() => ({
    width: typeof window !== 'undefined' ? window.innerWidth : 1280,
    height: typeof window !== 'undefined' ? window.innerHeight : 720,
  }));
  useEffect(() => {
    const onResize = () => setViewport({ width: window.innerWidth, height: window.innerHeight });
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);
```

- [ ] **Step 2: Extend the draw functions to multiply opacity by a per-particle factor**

Each top-level `drawX` function currently writes `ctx.globalAlpha = p.opacity`. Add a `getMul: (p: Particle) => number` parameter, and use it. Replace the existing draw functions (top of `ThemeEffects.tsx`) with these versions:

```typescript
function drawRain(
  ctx: CanvasRenderingContext2D,
  particles: Particle[],
  w: number, h: number,
  rainColor: string,
  getMul: (p: Particle) => number,
) {
  ctx.clearRect(0, 0, w, h);
  ctx.strokeStyle = rainColor;
  ctx.lineWidth = 1;
  for (const p of particles) {
    ctx.globalAlpha = p.opacity * getMul(p);
    ctx.beginPath();
    ctx.moveTo(p.x, p.y);
    ctx.lineTo(p.x - 1, p.y + p.length);
    ctx.stroke();
    p.y += p.speed;
    if (p.y > h) { p.y = -p.length; p.x = Math.random() * w; }
  }
  ctx.globalAlpha = 1;
}

function drawDust(
  ctx: CanvasRenderingContext2D,
  particles: Particle[],
  w: number, h: number,
  accent: string,
  getMul: (p: Particle) => number,
) {
  ctx.clearRect(0, 0, w, h);
  for (const p of particles) {
    ctx.globalAlpha = p.opacity * getMul(p);
    ctx.fillStyle = accent;
    ctx.beginPath();
    ctx.arc(p.x, p.y, 1, 0, Math.PI * 2);
    ctx.fill();
    p.y -= p.speed * 0.3;
    p.x += Math.sin(p.y * 0.02) * 0.5;
    if (p.y < 0) { p.y = h; p.x = Math.random() * w; }
  }
  ctx.globalAlpha = 1;
}

function drawEmber(
  ctx: CanvasRenderingContext2D,
  particles: Particle[],
  w: number, h: number,
  accent: string,
  getMul: (p: Particle) => number,
) {
  ctx.clearRect(0, 0, w, h);
  const t = Date.now() * 0.001;
  for (const p of particles) {
    ctx.globalAlpha = p.opacity * 0.8 * getMul(p);
    ctx.fillStyle = accent;
    ctx.beginPath();
    ctx.arc(p.x, p.y, 1.5, 0, Math.PI * 2);
    ctx.fill();
    p.y -= p.speed;
    p.x += Math.sin(t + p.length) * 0.8;
    p.opacity -= 0.002;
    if (p.y < 0 || p.opacity <= 0) {
      p.y = h + 10; p.x = Math.random() * w;
      p.opacity = Math.random() * 0.5 + 0.2;
    }
  }
  ctx.globalAlpha = 1;
}

function drawSnow(
  ctx: CanvasRenderingContext2D,
  particles: Particle[],
  w: number, h: number,
  accent: string,
  getMul: (p: Particle) => number,
) {
  ctx.clearRect(0, 0, w, h);
  const t = Date.now() * 0.0005;
  for (const p of particles) {
    ctx.globalAlpha = p.opacity * getMul(p);
    ctx.fillStyle = accent;
    ctx.beginPath();
    ctx.arc(p.x, p.y, p.length * 0.15 + 1, 0, Math.PI * 2);
    ctx.fill();
    p.y += p.speed * 0.4;
    p.x += Math.sin(t + p.length) * 0.6;
    if (p.y > h) { p.y = -5; p.x = Math.random() * w; }
  }
  ctx.globalAlpha = 1;
}

function drawCustom(
  ctx: CanvasRenderingContext2D,
  particles: Particle[],
  w: number, h: number,
  img: HTMLImageElement,
  drift: number,
  getMul: (p: Particle) => number,
) {
  ctx.clearRect(0, 0, w, h);
  const t = Date.now() * 0.001;
  for (const p of particles) {
    ctx.globalAlpha = p.opacity * getMul(p);
    ctx.drawImage(img, p.x - p.size / 2, p.y - p.size / 2, p.size, p.size);
    p.y -= p.speed * 0.5;
    p.x += Math.sin(t + p.length) * drift;
    if (p.y < -p.size) {
      p.y = h + p.size;
      p.x = Math.random() * w;
    }
  }
  ctx.globalAlpha = 1;
}
```

- [ ] **Step 3: Pass the falloff function into each draw call**

Inside the rAF `useEffect`, replace the `draw` function body with the version that constructs `getMul` once per frame and passes it through:

```typescript
    const FADE_DISTANCE = 24; // px — soft falloff band around every chrome rect

    const draw = (now: number) => {
      animRef.current = requestAnimationFrame(draw);
      // Cap at ~30fps — ambient particles don't need 60fps
      if (now - lastFrame < 33) return;
      lastFrame = now;
      const w = canvas.width;
      const h = canvas.height;
      const rects = chromeRectsRef.current;
      const getMul = (p: Particle) => chromeEdgeFalloff(p.x, p.y, rects, FADE_DISTANCE);
      if (preset === 'rain') drawRain(ctx, particlesRef.current, w, h, rainColor, getMul);
      else if (preset === 'dust') drawDust(ctx, particlesRef.current, w, h, accent, getMul);
      else if (preset === 'ember') drawEmber(ctx, particlesRef.current, w, h, accent, getMul);
      else if (preset === 'snow') drawSnow(ctx, particlesRef.current, w, h, accent, getMul);
      else if (preset === 'custom' && imgRef.current) {
        drawCustom(ctx, particlesRef.current, w, h, imgRef.current, particleDrift, getMul);
      }
    };
```

- [ ] **Step 4: Apply the clip-path to the canvas style**

At the bottom of the component, the canvas JSX currently has a `style={{ ... }}` with `position: 'fixed'`, etc. Add a `clipPath` entry computed from `chromeRects` + `viewport`:

```tsx
  return (
    <canvas
      ref={canvasRef}
      style={{
        position: 'fixed',
        top: 0, left: 0, right: 0, bottom: 0,
        // Behind chat bubbles / chrome, above #theme-bg / #theme-pattern via
        // DOM order. At z-index: 0 particles render IN FRONT of bubble text.
        zIndex: -1,
        pointerEvents: 'none',
        opacity: 0.6,
        // Mask out glassmorphism chrome regions so their backdrop-filter
        // sees a static gradient (cached blur) instead of a per-frame
        // canvas update (forced re-blur). See theme-effects-mask.ts.
        clipPath: buildChromeClipPath(viewport, chromeRects),
        WebkitClipPath: buildChromeClipPath(viewport, chromeRects),
      }}
      aria-hidden="true"
    />
  );
```

- [ ] **Step 5: Typecheck the full desktop project**

```bash
npx tsc --noEmit -p tsconfig.json 2>&1 | head -10
```

Expected: only the pre-existing `node-machine-id` error from master. No new errors referencing ThemeEffects, useChromeGeometry, or theme-effects-mask.

If the typecheck reports new errors, fix them before committing — typically they'll be a missing `Particle` import in the new draw signatures or a missing dependency in a `useEffect` array.

- [ ] **Step 6: Run the existing test suite to confirm no regression**

```bash
npx vitest run 2>&1 | tail -20
```

Expected: all tests pass, including the two new test files from Tasks 2 and 3.

- [ ] **Step 7: Build the renderer bundle**

```bash
npx vite build --logLevel=warn 2>&1 | tail -10
```

Expected: build succeeds. Warnings about chunk size are pre-existing and acceptable.

- [ ] **Step 8: Commit**

```bash
git add desktop/src/renderer/components/ThemeEffects.tsx
git commit -m "fix(theme-effects): mask chrome regions out of particle canvas"
```

---

## Task 5: Manual Smoke Test (Cross-Theme)

**Files:** None modified — runtime verification.

The five themes that ship particles (per `wecoded-themes/themes/*/manifest.json`): `strawberry-kitty` (dust, image bg, panels-blur 4), `kuromi-dreamer`, `halftone-dimension` (custom, gradient bg, panels-blur 20), `golden-sunbreak`, `devils-garden`. Each verifies a different combination of `chrome-style`, `panels-blur`, and particle preset.

- [ ] **Step 1: Start dev mode against the worktree**

```bash
cd /c/Users/desti/youcoded-dev
YOUCODED_WT=youcoded.wt/theme-effects-chrome-mask bash scripts/run-dev.sh
```

(Or whatever invocation `run-dev.sh` accepts — the worktree is a normal desktop checkout, so `cd` into it and run `npx vite & npx electron .` as a fallback.)

- [ ] **Step 2: Verify halftone-dimension (the original repro case)**

In the dev window: Settings → Appearance → **Halftone Dimension**. Reduced Effects OFF.

Check Task Manager → YouCoded GPU process → copy engine percentage.

- **Pass:** copy engine ≪ 100%, ideally single digits or low double digits.
- **Fail:** still pegged. Drop to DevTools → Console → run `document.querySelector('canvas[aria-hidden="true"]').getBoundingClientRect()` and `getComputedStyle(...).clipPath` to confirm clip-path is applied. Common causes: wrong selector for chrome elements, CSS `clip-path: path()` syntax error, viewport state stale.

- [ ] **Step 3: Verify particles still appear in the chat area**

Look at the chat area on halftone-dimension. Particles (the SVG halftone shapes) should drift visibly there, fading near the header / input bar / status bar rather than popping in/out at sharp lines.

- [ ] **Step 4: Verify particles do NOT appear in chrome regions**

Stare at the header bar and the status bar for 10+ seconds. The faint blurred-particle halos that used to pass through the glass should be gone. The chrome should look like a clean gradient blur.

- [ ] **Step 5: Verify other particle themes**

Cycle through each particle theme and confirm the GPU number drops on every one with `panels-blur >= 8`. Visually confirm the particle chat-area effect still looks right.

```
Strawberry Kitty   — dust,   image,    panels-blur 4   → small GPU change expected (low blur)
Kuromi Dreamer     — varies                            → check
Halftone Dimension — custom, gradient, panels-blur 20  → already verified in step 2
Golden Sunbreak    — varies                            → check
Devils Garden      — varies                            → check
```

For any theme that visually regresses (sharp particle pops, missing particles in unexpected places), capture the theme name and chrome-style/panels-blur values in the PR description and decide whether to ship anyway or refine.

- [ ] **Step 6: Verify non-particle themes are unaffected**

Switch to Light, Dark, Midnight, Crème. Confirm:
- No visual change vs. before this PR
- GPU stays at idle baseline
- No console errors mentioning ThemeEffects, useChromeGeometry, or clip-path

- [ ] **Step 7: Verify Reduced Effects still works**

On Halftone Dimension, toggle Reduced Effects ON. Particles should disappear entirely (existing behavior — `ThemeEffects` returns null). Toggle OFF — particles return, masked correctly.

- [ ] **Step 8: Verify dynamic chrome resize**

On Halftone Dimension with Reduced Effects OFF, type a long multi-line message in the input bar (Shift+Enter several times) so the input bar grows. Particles near the input bar should fade as the bar grows; the masked region should track the new bar height. No flicker.

- [ ] **Step 9: Verify visibility-gate from PR #91 still works**

Minimize the YouCoded Dev window. After ~5 seconds, GPU usage should drop to near-zero. Restore — particles resume from where they were.

If everything passes, proceed to Task 6.

If anything fails, gather the symptom (GPU still pinned, visual artifact, console error) and stop to investigate before opening the PR.

No commit for this task — verification only.

---

## Task 6: Open the PR

- [ ] **Step 1: Push the branch**

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/theme-effects-chrome-mask
git push -u origin fix/theme-effects-chrome-mask
```

Expected: branch pushed, GitHub returns the PR-creation URL.

- [ ] **Step 2: Open the PR**

```bash
gh pr create --repo itsdestin/youcoded \
  --title "fix(theme-effects): mask chrome regions out of particle canvas" \
  --body "$(cat <<'EOF'
## Summary

- Particle canvas now mounts a CSS \`clip-path: path(evenodd, ...)\` that punches holes wherever a glassmorphism chrome panel sits (header bar, status bar, input bar). Chrome's \`backdrop-filter\` no longer sees per-frame canvas updates, so Chromium can cache the blur output and stop recomputing it 30 times per second.
- Per-particle opacity falloff (24px fade band around each chrome rect) keeps particles from popping at the masked edges.
- Particle simulation is unchanged — same count, same physics, same presets.

## Why

Themes that combine particles with heavy chrome blur (e.g. \`halftone-dimension\` with \`panels-blur: 20px\`) pegged the GPU copy engine at ~100% even while the user was actively using the app. Diagnosed in the same investigation that produced #91 (visibility-gate); that PR fixes the idle case but the active-use cost remained intrinsic to the per-frame backdrop-filter recompute.

The empirical baseline on the original repro: copy engine at ~100% on halftone-dimension. After this PR + #91: copy engine in single digits, no visible change in the chat area.

## Trade-offs

- **Particles no longer appear inside chrome panels.** They previously showed as faint blurred halos through the glass (~5% effective opacity after a 20px blur on a 6–14px particle). The diff is small but not zero. The edge fade keeps the boundary smooth.
- **Open popups / drawers** (SettingsPanel, PreferencesPopup, ResumeBrowser, etc.) still trigger their own backdrop-filter cost while open — they are not in the static-chrome selector list. Acceptable: the cost is bought when the user actively interacts.
- **Chat bubbles with \`bubble-blur > 0\`** (e.g. strawberry-kitty's 13px) also still re-blur as canvas changes underneath them. Smaller surface area, smaller cost. Out of scope for this PR.

## Files

- \`desktop/src/renderer/components/theme-effects-mask.ts\` (new) — pure helpers
- \`desktop/src/renderer/hooks/useChromeGeometry.ts\` (new) — chrome-rect tracking hook
- \`desktop/src/renderer/components/ThemeEffects.tsx\` — wire it all in
- \`desktop/tests/theme-effects-mask.test.ts\` (new) — 8 unit tests
- \`desktop/tests/use-chrome-geometry.test.ts\` (new) — 4 unit tests with mocked ResizeObserver

## Test plan

- [ ] \`npx vitest run\` — full suite green including new tests
- [ ] \`npx tsc --noEmit -p desktop/tsconfig.json\` — no new errors
- [ ] \`npx vite build\` — clean build
- [ ] Halftone Dimension: GPU copy engine drops from ~100% to single digits while window is active and visible
- [ ] Particles still drift visibly in the chat area; no sharp pops at chrome edges
- [ ] Particles do not appear inside header / status bar / input bar
- [ ] Other particle themes (Strawberry Kitty, Kuromi Dreamer, Golden Sunbreak, Devils Garden) — no visual regression
- [ ] Light / Dark / Midnight / Crème — no change
- [ ] Reduced Effects toggle ON → particles disappear; OFF → particles return masked
- [ ] Multi-line input grows input bar → mask tracks the new height with no flicker
- [ ] Window minimize → GPU drops (visibility-gate from #91 still works)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR URL printed.

- [ ] **Step 3: Record the PR URL in the plan**

Reply to the user with the PR URL so they can review.

---

## Self-Review Checklist (run before handing off)

- [ ] Every task that touches code includes the actual code in a code block.
- [ ] Every test step states the expected pass/fail outcome.
- [ ] No "TBD", "implement later", "handle edge cases", or "similar to Task N" placeholders.
- [ ] Function names / type names / file paths are consistent between tasks (`buildChromeClipPath`, `chromeEdgeFalloff`, `ChromeRect`, `useChromeGeometry`, `theme-effects-mask.ts`, `useChromeGeometry.ts`, `ThemeEffects.tsx`).
- [ ] The plan covers the spec: clip-path mask + edge fade + chrome-rect hook + dynamic resize tracking + smoke tests for parity across themes + Reduced Effects compatibility.
- [ ] PR #91 dependency is called out explicitly in the setup section.
- [ ] Task 1 (verification) is gated — if it fails, the rest of the plan stops.

---

## Cleanup After Merge

```bash
cd /c/Users/desti/youcoded-dev/youcoded
git fetch origin
git worktree remove ../youcoded.wt/theme-effects-chrome-mask
git branch -D fix/theme-effects-chrome-mask
```

Verify the commit landed on master before deleting the branch:

```bash
git branch --contains <merge-sha>   # should list 'master'
```
