# Context StatusBar Popup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the non-interactive Context % pill in the StatusBar into a clickable chip that opens a popup with (a) a plain-language explainer of what context is, (b) a split-button primary action that runs `/compact` or `/compact <instructions>`, and (c) a secondary `/clear` action.

**Architecture:** One new renderer-only component (`ContextPopup.tsx`) rendered via React portal at overlay layer L2. Reuses existing `<Scrim>` / `<OverlayPanel>` primitives for theming, `SettingsExplainer` + `InfoIconButton` for the `(i)` view, and `useEscClose` for ESC routing. The StatusBar chip becomes a button that toggles the popup; the popup's actions call an `onDispatch` wrapper threaded in from `App.tsx` that invokes the existing `dispatchSlashCommand` — no dispatcher changes needed.

**Tech Stack:** React 18, TypeScript, Tailwind CSS with theme tokens (`bg-panel`, `text-fg`, etc.), Vitest + @testing-library/react (jsdom) for tests.

**Spec:** `docs/superpowers/specs/2026-04-24-context-statusbar-popup-design.md`

---

## Pre-flight: environment

The React UI lives in `youcoded/desktop/`. Work should happen in a dedicated git worktree off `youcoded/` master (per workspace convention — see `CLAUDE.md` in `youcoded-dev`). If one wasn't already created, run:

```bash
cd youcoded && git fetch origin && git pull origin master
git worktree add ../../youcoded-worktrees/context-popup -b feat/context-popup
cd ../../youcoded-worktrees/context-popup/desktop && npm ci
```

All paths below are relative to `youcoded/` (the sub-repo), not the workspace root.

---

## Task 1: Scaffold `ContextPopup` with main view (percent, tokens, hint)

**Files:**
- Create: `desktop/src/renderer/components/ContextPopup.tsx`
- Create: `desktop/tests/context-popup.test.tsx`

The first iteration renders the outer popup shell — portal, scrim, panel, header with title + close X, and the "current state" block (percent, tokens, hint). No info view, no actions yet.

- [ ] **Step 1: Write the failing test for the main view**

Create `desktop/tests/context-popup.test.tsx` with initial content:

```tsx
// @vitest-environment jsdom
// context-popup.test.tsx — tests for the StatusBar context chip popup.

import React from 'react';
import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import ContextPopup from '../src/renderer/components/ContextPopup';

afterEach(cleanup);

function renderPopup(overrides: Partial<React.ComponentProps<typeof ContextPopup>> = {}) {
  const onClose = vi.fn();
  const onDispatch = vi.fn();
  const defaults: React.ComponentProps<typeof ContextPopup> = {
    open: true,
    onClose,
    sessionId: 'sess-1',
    contextPercent: 72,
    contextTokens: 143_200,
    onDispatch,
  };
  const props = { ...defaults, ...overrides };
  return { ...render(<ContextPopup {...props} />), onClose, onDispatch };
}

describe('ContextPopup — main view', () => {
  it('renders title, percent, tokens, and the high-band hint', () => {
    renderPopup({ contextPercent: 72, contextTokens: 143_200 });
    expect(screen.getByText('Context')).toBeInTheDocument();
    expect(screen.getByText('72%')).toBeInTheDocument();
    expect(screen.getByText(/143,200 tokens remaining/)).toBeInTheDocument();
    expect(screen.getByText(/Plenty of room/i)).toBeInTheDocument();
  });

  it('shows the mid-band hint between 20% and 60%', () => {
    renderPopup({ contextPercent: 35 });
    expect(screen.getByText(/Getting tight/i)).toBeInTheDocument();
  });

  it('shows the low-band hint under 20%', () => {
    renderPopup({ contextPercent: 8 });
    expect(screen.getByText(/Very low/i)).toBeInTheDocument();
  });

  it('omits the tokens line when contextTokens is null', () => {
    renderPopup({ contextTokens: null });
    expect(screen.queryByText(/tokens remaining/)).toBeNull();
  });

  it('returns null when open is false', () => {
    const { container } = renderPopup({ open: false });
    expect(container.querySelector('[role="dialog"]')).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: FAIL — module not found (`ContextPopup` doesn't exist yet).

- [ ] **Step 3: Create `ContextPopup.tsx` with the minimal main view**

Create `desktop/src/renderer/components/ContextPopup.tsx`:

```tsx
import React from 'react';
import { createPortal } from 'react-dom';
import { Scrim, OverlayPanel } from './overlays/Overlay';

// Hint text keyed to the same color bands the chip uses (contextColor in StatusBar.tsx).
// > 60% green, 20–60% amber, < 20% red. Non-dev copy — reviewed with spec.
function hintFor(pct: number): string {
  if (pct > 60) return 'Plenty of room — no action needed.';
  if (pct >= 20) return 'Getting tight — consider compacting soon.';
  return 'Very low — compact now or Claude may start forgetting earlier context.';
}

// Match the color function in StatusBar.tsx exactly so the popup number tracks the chip.
function contextColor(pct: number): string {
  if (pct < 20) return 'text-[#DD4444]';
  if (pct < 50) return 'text-[#FF9800]';
  return 'text-[#4CAF50]';
}

export interface ContextPopupProps {
  open: boolean;
  onClose: () => void;
  sessionId: string | null;
  contextPercent: number | null;
  contextTokens: number | null;
  /** Dispatches a slash command through App.tsx's wrapper around dispatchSlashCommand. */
  onDispatch: (input: string) => void;
}

export default function ContextPopup({
  open,
  onClose,
  sessionId,
  contextPercent,
  contextTokens,
  onDispatch,
}: ContextPopupProps) {
  if (!open) return null;

  const pct = contextPercent ?? 0;

  return createPortal(
    <>
      <Scrim layer={2} onClick={onClose} />
      <OverlayPanel
        layer={2}
        role="dialog"
        aria-modal={true}
        className="fixed left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 w-[320px]"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 border-b border-edge">
          <h3 className="text-sm font-semibold text-fg">Context</h3>
          <button
            onClick={onClose}
            aria-label="Close"
            className="text-fg-muted hover:text-fg leading-none w-6 h-6 flex items-center justify-center rounded-sm hover:bg-inset"
          >
            ✕
          </button>
        </div>

        {/* Current state */}
        <div className="px-4 py-4 space-y-3">
          <div className="text-center">
            <div className={`text-3xl font-bold ${contextColor(pct)}`}>
              {contextPercent != null ? `${contextPercent}%` : '--'}
            </div>
            {contextTokens != null && (
              <div className="text-xs text-fg-muted mt-1">
                {contextTokens.toLocaleString()} tokens remaining
              </div>
            )}
            {contextPercent != null && (
              <p className="text-xs text-fg-2 mt-2">{hintFor(contextPercent)}</p>
            )}
          </div>
        </div>
      </OverlayPanel>
    </>,
    document.body,
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: PASS — all 5 tests in the "main view" describe block green.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/ContextPopup.tsx desktop/tests/context-popup.test.tsx
git commit -m "feat(context-popup): scaffold main view with percent + hint"
```

---

## Task 2: Wire Escape, scrim click, and X button close paths

**Files:**
- Modify: `desktop/src/renderer/components/ContextPopup.tsx`
- Modify: `desktop/tests/context-popup.test.tsx`

Test that all three close paths call `onClose`. Escape goes through `useEscClose` (the centralized stack) — soft-fails when no `EscCloseProvider` is mounted, which is what the test environment will see.

- [ ] **Step 1: Write the failing tests for close behaviors**

Append to `desktop/tests/context-popup.test.tsx` (inside the existing `describe('ContextPopup — main view', ...)` block, after the last test). Note: `useEscClose` soft-fails without a provider, so directly firing an Escape keydown won't close the popup in the unit test. Test `useEscClose` wiring indirectly by asserting the hook is called (via a render smoke check) and the close-button / scrim paths directly.

Add these tests:

```tsx
  it('calls onClose when the X button is clicked', () => {
    const { onClose } = renderPopup();
    fireEvent.click(screen.getByLabelText('Close'));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('calls onClose when the scrim is clicked', () => {
    const { onClose } = renderPopup();
    // Scrim is the backdrop rendered alongside the dialog. Find by its layer-scrim class.
    const scrim = document.querySelector('.layer-scrim');
    expect(scrim).not.toBeNull();
    fireEvent.click(scrim!);
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('does not bubble clicks from inside the panel to the scrim', () => {
    const { onClose } = renderPopup();
    fireEvent.click(screen.getByRole('dialog'));
    expect(onClose).not.toHaveBeenCalled();
  });
```

- [ ] **Step 2: Run tests to verify they pass (scrim + X already work) or fail**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: The X-button and stopPropagation tests PASS (already wired in Task 1). The scrim click test likely PASSES too because `Scrim` primitive already uses `onClick={onClose}` pattern. If any of them FAIL, adjust the selector in the test (e.g., `[aria-label="Close"]` vs `getByLabelText`).

- [ ] **Step 3: Add ESC wiring to the component**

Modify `desktop/src/renderer/components/ContextPopup.tsx`. Import `useEscClose` and call it at the top of the component:

```tsx
import { useEscClose } from '../hooks/use-esc-close';
```

Inside the component body, before the `if (!open) return null;` guard, add:

```tsx
useEscClose(open, onClose);
```

The hook must be called unconditionally (rules of hooks). It no-ops when `open` is false or no `EscCloseProvider` is mounted.

- [ ] **Step 4: Run tests to verify they still pass**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: PASS — no test regressions. ESC behavior is covered by the production `EscCloseProvider`; unit tests just verify the hook doesn't crash without one (soft-fail contract).

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/ContextPopup.tsx desktop/tests/context-popup.test.tsx
git commit -m "feat(context-popup): wire ESC, scrim, and X close paths"
```

---

## Task 3: Add the `(i)` info view via `SettingsExplainer`

**Files:**
- Modify: `desktop/src/renderer/components/ContextPopup.tsx`
- Modify: `desktop/tests/context-popup.test.tsx`

Add the `showInfo` boolean state and flip between main view and `<SettingsExplainer>`. Reuse the exported `InfoIconButton` from `SettingsExplainer.tsx`.

- [ ] **Step 1: Write the failing tests for the info view**

Append a new describe block at the bottom of `desktop/tests/context-popup.test.tsx`:

```tsx
describe('ContextPopup — info view', () => {
  it('shows the (i) button in the header of the main view', () => {
    renderPopup();
    expect(screen.getByLabelText('What is this?')).toBeInTheDocument();
  });

  it('swaps to the explainer when (i) is clicked', () => {
    renderPopup();
    fireEvent.click(screen.getByLabelText('What is this?'));
    expect(screen.getByText('About Context')).toBeInTheDocument();
    // Main-view hint should no longer be visible
    expect(screen.queryByText(/Plenty of room/i)).toBeNull();
  });

  it('returns to the main view when Back is clicked', () => {
    renderPopup();
    fireEvent.click(screen.getByLabelText('What is this?'));
    fireEvent.click(screen.getByLabelText('Back to settings'));
    expect(screen.getByText(/Plenty of room/i)).toBeInTheDocument();
    expect(screen.queryByText('About Context')).toBeNull();
  });

  it('closes the whole popup when the explainer Close is clicked', () => {
    const { onClose } = renderPopup();
    fireEvent.click(screen.getByLabelText('What is this?'));
    // Explainer renders its own Close button with aria-label="Close"
    const closes = screen.getAllByLabelText('Close');
    // There may be two — one from explainer, one from the main view header
    // (but main view should be hidden). Pick any — the explainer's.
    fireEvent.click(closes[0]);
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: FAIL — `(i)` button is not rendered and explainer is not wired.

- [ ] **Step 3: Add the info view to `ContextPopup.tsx`**

Modify `desktop/src/renderer/components/ContextPopup.tsx`. Add imports:

```tsx
import { useState } from 'react';
import SettingsExplainer, { InfoIconButton, type ExplainerSection } from './SettingsExplainer';
```

(Update the existing `import React from 'react';` to include `useState`, or add the separate import.)

Above the component, define the explainer content:

```tsx
const INFO_SECTIONS: ExplainerSection[] = [
  {
    heading: 'Why it matters',
    paragraphs: [
      "The higher it is, the more Claude remembers — every file you opened, every decision you made together, the full thread of what you're building. When it gets low, Claude may forget files you discussed earlier, lose track of decisions, or repeat questions it already asked. Running out mid-task usually means worse answers and extra back-and-forth.",
    ],
  },
  {
    heading: 'What fills it up',
    bullets: [
      { term: 'Your messages and Claude’s replies', text: 'Every turn of the conversation stays in memory.' },
      { term: 'Tool output', text: "When Claude reads files, runs commands, or lists directories, the results go into context too. This is usually the biggest contributor." },
      { term: 'Attached files and images', text: 'Anything you drag into the input bar.' },
      { term: 'Loaded skills', text: 'Installed skills contribute their instructions to every turn.' },
    ],
    paragraphs: ['Long sessions with lots of file reads fill it up fastest.'],
  },
  {
    heading: 'What to do when it gets low',
    bullets: [
      { term: 'Compact', text: 'Claude summarizes the conversation so far and keeps going in the same session. The thread stays alive. Use optional instructions to tell Claude what to prioritize keeping (e.g. code decisions vs. debugging output).' },
      { term: 'Clear', text: "Wipes the conversation and starts fresh in the same session. No summary is kept. Good when you're switching to an unrelated task." },
      { term: 'New session', text: 'Opens a separate conversation from scratch and leaves this one intact. Good when you want to preserve this conversation’s state while working on something else. Use the + button in the session strip at the top of the window.' },
    ],
  },
];

const INFO_INTRO =
  "Context is Claude’s short-term memory for this conversation. The percentage shows how much room Claude has left before it starts forgetting the earliest messages.";
```

Inside the component, add `showInfo` state and split the render into two branches. Replace the entire return statement with:

```tsx
  const [showInfo, setShowInfo] = useState(false);

  if (!open) return null;

  const pct = contextPercent ?? 0;

  return createPortal(
    <>
      <Scrim layer={2} onClick={onClose} />
      <OverlayPanel
        layer={2}
        role="dialog"
        aria-modal={true}
        className="fixed left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 w-[320px]"
        onClick={(e) => e.stopPropagation()}
      >
        {showInfo ? (
          <SettingsExplainer
            title="Context"
            intro={INFO_INTRO}
            sections={INFO_SECTIONS}
            onBack={() => setShowInfo(false)}
            onClose={onClose}
          />
        ) : (
          <>
            {/* Header */}
            <div className="flex items-center justify-between px-4 py-3 border-b border-edge">
              <h3 className="text-sm font-semibold text-fg">Context</h3>
              <div className="flex items-center gap-1">
                <InfoIconButton onClick={() => setShowInfo(true)} />
                <button
                  onClick={onClose}
                  aria-label="Close"
                  className="text-fg-muted hover:text-fg leading-none w-6 h-6 flex items-center justify-center rounded-sm hover:bg-inset"
                >
                  ✕
                </button>
              </div>
            </div>

            {/* Current state */}
            <div className="px-4 py-4 space-y-3">
              <div className="text-center">
                <div className={`text-3xl font-bold ${contextColor(pct)}`}>
                  {contextPercent != null ? `${contextPercent}%` : '--'}
                </div>
                {contextTokens != null && (
                  <div className="text-xs text-fg-muted mt-1">
                    {contextTokens.toLocaleString()} tokens remaining
                  </div>
                )}
                {contextPercent != null && (
                  <p className="text-xs text-fg-2 mt-2">{hintFor(contextPercent)}</p>
                )}
              </div>
            </div>
          </>
        )}
      </OverlayPanel>
    </>,
    document.body,
  );
```

Note: `ExplainerSection` is already exported from `SettingsExplainer.tsx` (line 23 of that file). If not, add `export` to its declaration.

- [ ] **Step 2a: Verify `ExplainerSection` is exported**

Run: `cd desktop && grep -n "export.*ExplainerSection" src/renderer/components/SettingsExplainer.tsx`
Expected: a match showing `export interface ExplainerSection`. If missing, add `export` before the interface declaration.

- [ ] **Step 3: Run tests to verify they pass**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: PASS — all main-view + info-view tests green.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/renderer/components/ContextPopup.tsx desktop/tests/context-popup.test.tsx
git commit -m "feat(context-popup): add (i) explainer via SettingsExplainer"
```

---

## Task 4: Add the "Clear and start over" secondary action

**Files:**
- Modify: `desktop/src/renderer/components/ContextPopup.tsx`
- Modify: `desktop/tests/context-popup.test.tsx`

- [ ] **Step 1: Write the failing tests for Clear**

Append a new describe block to `desktop/tests/context-popup.test.tsx`:

```tsx
describe('ContextPopup — actions', () => {
  it('renders the "Clear and start over" button with explanatory note', () => {
    renderPopup();
    expect(screen.getByRole('button', { name: /Clear and start over/i })).toBeInTheDocument();
    expect(screen.getByText(/Erases the visible timeline/i)).toBeInTheDocument();
  });

  it('dispatches /clear and closes the popup when Clear is clicked', () => {
    const { onDispatch, onClose } = renderPopup();
    fireEvent.click(screen.getByRole('button', { name: /Clear and start over/i }));
    expect(onDispatch).toHaveBeenCalledWith('/clear');
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('disables Clear when sessionId is null', () => {
    renderPopup({ sessionId: null });
    const btn = screen.getByRole('button', { name: /Clear and start over/i });
    expect(btn).toBeDisabled();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: FAIL — Clear button not rendered.

- [ ] **Step 3: Add the Clear button to the main view**

In `desktop/src/renderer/components/ContextPopup.tsx`, inside the main-view branch, add a new block after the "Current state" block (still inside the same `<>...</>` fragment, i.e., after the closing `</div>` of the current-state container):

```tsx
            {/* Actions — primary compact lands in Task 5; Clear is the secondary. */}
            <div className="px-4 pb-4 pt-2 space-y-3 border-t border-edge">
              <div>
                <button
                  onClick={() => {
                    onDispatch('/clear');
                    onClose();
                  }}
                  disabled={!sessionId}
                  className="w-full py-2 px-3 text-sm rounded-sm border border-edge bg-panel text-fg-2 hover:bg-inset transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  Clear and start over
                </button>
                <p className="text-[11px] text-fg-muted mt-1 leading-snug">
                  Erases the visible timeline and resets Claude&rsquo;s memory for this session. No summary is kept.
                </p>
              </div>
            </div>
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: PASS — Clear action tests green.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/ContextPopup.tsx desktop/tests/context-popup.test.tsx
git commit -m "feat(context-popup): add Clear and start over action"
```

---

## Task 5: Add the primary Compact split-button (main click only)

**Files:**
- Modify: `desktop/src/renderer/components/ContextPopup.tsx`
- Modify: `desktop/tests/context-popup.test.tsx`

Renders the split-button visual (main button + chevron), but the chevron is a stub that only sets state — the inline editor arrives in Task 6. The main-button click dispatches plain `/compact`.

- [ ] **Step 1: Write the failing tests for the Compact main click**

Append to the `describe('ContextPopup — actions', ...)` block in `desktop/tests/context-popup.test.tsx`:

```tsx
  it('renders the Compact split-button', () => {
    renderPopup();
    expect(screen.getByRole('button', { name: /^Compact conversation$/i })).toBeInTheDocument();
    expect(screen.getByLabelText(/Customize compact instructions/i)).toBeInTheDocument();
  });

  it('dispatches /compact and closes when the main Compact button is clicked', () => {
    const { onDispatch, onClose } = renderPopup();
    fireEvent.click(screen.getByRole('button', { name: /^Compact conversation$/i }));
    expect(onDispatch).toHaveBeenCalledWith('/compact');
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('disables both Compact controls when sessionId is null', () => {
    renderPopup({ sessionId: null });
    expect(screen.getByRole('button', { name: /^Compact conversation$/i })).toBeDisabled();
    expect(screen.getByLabelText(/Customize compact instructions/i)).toBeDisabled();
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: FAIL — Compact button not rendered.

- [ ] **Step 3: Add local state for the editor (not used yet) and the split-button**

In `desktop/src/renderer/components/ContextPopup.tsx`, add local state near `showInfo`:

```tsx
  const [showInfo, setShowInfo] = useState(false);
  const [customizing, setCustomizing] = useState(false);
  const [instructions, setInstructions] = useState('');
```

Inside the main-view actions block (Task 4 added `<div className="px-4 pb-4 pt-2 space-y-3 border-t border-edge">`), insert the Compact split-button **before** the Clear block, so the layout is: Compact primary → Clear secondary:

```tsx
              {/* Split-button: main = /compact, chevron = open inline editor (Task 6). */}
              <div>
                <div className="flex w-full rounded-sm overflow-hidden border border-accent">
                  <button
                    onClick={() => {
                      onDispatch('/compact');
                      onClose();
                    }}
                    disabled={!sessionId}
                    className="flex-1 py-2 px-3 text-sm font-medium bg-accent text-on-accent hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
                  >
                    Compact conversation
                  </button>
                  <button
                    onClick={() => setCustomizing(true)}
                    disabled={!sessionId}
                    aria-label="Customize compact instructions"
                    className="px-2 bg-accent text-on-accent border-l border-on-accent/30 hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center"
                  >
                    {/* Chevron down */}
                    <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2} aria-hidden>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M6 9l6 6 6-6" />
                    </svg>
                  </button>
                </div>
              </div>
```

(The `customizing` / `instructions` state is placed but not consumed yet — that's Task 6. Keeping the state here prevents churn in the next task.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: PASS — all existing tests plus the three new ones green.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/ContextPopup.tsx desktop/tests/context-popup.test.tsx
git commit -m "feat(context-popup): add Compact split-button main click"
```

---

## Task 6: Wire the chevron → inline editor → focused-compact dispatch

**Files:**
- Modify: `desktop/src/renderer/components/ContextPopup.tsx`
- Modify: `desktop/tests/context-popup.test.tsx`

When `customizing` is true, the actions block is replaced with an inline editor: textarea, "Compact with instructions" submit, "Back" return. Submit dispatches `/compact <trimmed text>`. Empty text disables submit.

- [ ] **Step 1: Write the failing tests for the inline editor**

Append to `describe('ContextPopup — actions', ...)`:

```tsx
  it('opens the inline editor when the chevron is clicked', () => {
    renderPopup();
    fireEvent.click(screen.getByLabelText(/Customize compact instructions/i));
    expect(screen.getByPlaceholderText(/keep code decisions/i)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /Compact with instructions/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /^Back$/i })).toBeInTheDocument();
    // The default compact button should no longer be visible in editor mode
    expect(screen.queryByRole('button', { name: /^Compact conversation$/i })).toBeNull();
  });

  it('returns to the default actions view when Back is clicked in editor mode', () => {
    renderPopup();
    fireEvent.click(screen.getByLabelText(/Customize compact instructions/i));
    fireEvent.click(screen.getByRole('button', { name: /^Back$/i }));
    expect(screen.getByRole('button', { name: /^Compact conversation$/i })).toBeInTheDocument();
    expect(screen.queryByPlaceholderText(/keep code decisions/i)).toBeNull();
  });

  it('disables submit while the textarea is empty or whitespace-only', () => {
    renderPopup();
    fireEvent.click(screen.getByLabelText(/Customize compact instructions/i));
    const submit = screen.getByRole('button', { name: /Compact with instructions/i });
    expect(submit).toBeDisabled();
    const textarea = screen.getByPlaceholderText(/keep code decisions/i);
    fireEvent.change(textarea, { target: { value: '   ' } });
    expect(submit).toBeDisabled();
    fireEvent.change(textarea, { target: { value: 'keep code' } });
    expect(submit).toBeEnabled();
  });

  it('dispatches /compact <trimmed instructions> and closes on submit', () => {
    const { onDispatch, onClose } = renderPopup();
    fireEvent.click(screen.getByLabelText(/Customize compact instructions/i));
    const textarea = screen.getByPlaceholderText(/keep code decisions/i);
    fireEvent.change(textarea, { target: { value: '   keep architecture decisions  ' } });
    fireEvent.click(screen.getByRole('button', { name: /Compact with instructions/i }));
    expect(onDispatch).toHaveBeenCalledWith('/compact keep architecture decisions');
    expect(onClose).toHaveBeenCalledTimes(1);
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: FAIL — inline editor is not rendered yet.

- [ ] **Step 3: Render the editor branch in the actions block**

In `desktop/src/renderer/components/ContextPopup.tsx`, replace the entire actions-block `<div className="px-4 pb-4 pt-2 space-y-3 border-t border-edge">...</div>` with a branched version:

```tsx
            {/* Actions: default view shows split Compact + Clear; customizing shows the editor. */}
            <div className="px-4 pb-4 pt-2 space-y-3 border-t border-edge">
              {customizing ? (
                <div className="space-y-2">
                  <label className="block text-xs font-medium text-fg-muted tracking-wider uppercase">
                    Keep these priorities (optional)
                  </label>
                  <textarea
                    value={instructions}
                    onChange={(e) => setInstructions(e.target.value)}
                    placeholder="e.g. keep code decisions and architecture; drop debugging output"
                    rows={3}
                    className="w-full px-2 py-1.5 text-xs bg-inset border border-edge rounded-sm text-fg focus:outline-none focus:ring-1 focus:ring-accent resize-none"
                  />
                  <div className="flex gap-2">
                    <button
                      onClick={() => {
                        setCustomizing(false);
                        setInstructions('');
                      }}
                      className="flex-1 py-2 px-3 text-sm rounded-sm border border-edge bg-panel text-fg-2 hover:bg-inset transition-colors"
                    >
                      Back
                    </button>
                    <button
                      onClick={() => {
                        const trimmed = instructions.trim();
                        if (!trimmed || !sessionId) return;
                        onDispatch(`/compact ${trimmed}`);
                        onClose();
                      }}
                      disabled={!sessionId || instructions.trim().length === 0}
                      className="flex-1 py-2 px-3 text-sm font-medium rounded-sm bg-accent text-on-accent hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                      Compact with instructions
                    </button>
                  </div>
                </div>
              ) : (
                <>
                  {/* Split-button: main = /compact, chevron = open inline editor. */}
                  <div>
                    <div className="flex w-full rounded-sm overflow-hidden border border-accent">
                      <button
                        onClick={() => {
                          onDispatch('/compact');
                          onClose();
                        }}
                        disabled={!sessionId}
                        className="flex-1 py-2 px-3 text-sm font-medium bg-accent text-on-accent hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
                      >
                        Compact conversation
                      </button>
                      <button
                        onClick={() => setCustomizing(true)}
                        disabled={!sessionId}
                        aria-label="Customize compact instructions"
                        className="px-2 bg-accent text-on-accent border-l border-on-accent/30 hover:opacity-90 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed flex items-center justify-center"
                      >
                        <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2} aria-hidden>
                          <path strokeLinecap="round" strokeLinejoin="round" d="M6 9l6 6 6-6" />
                        </svg>
                      </button>
                    </div>
                  </div>

                  {/* Clear secondary action. */}
                  <div>
                    <button
                      onClick={() => {
                        onDispatch('/clear');
                        onClose();
                      }}
                      disabled={!sessionId}
                      className="w-full py-2 px-3 text-sm rounded-sm border border-edge bg-panel text-fg-2 hover:bg-inset transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                    >
                      Clear and start over
                    </button>
                    <p className="text-[11px] text-fg-muted mt-1 leading-snug">
                      Erases the visible timeline and resets Claude&rsquo;s memory for this session. No summary is kept.
                    </p>
                  </div>
                </>
              )}
            </div>
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd desktop && npx vitest run tests/context-popup.test.tsx`
Expected: PASS — all action tests including editor tests green.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/ContextPopup.tsx desktop/tests/context-popup.test.tsx
git commit -m "feat(context-popup): wire chevron to focused-compact editor"
```

---

## Task 7: Convert the StatusBar context chip into a button and render the popup

**Files:**
- Modify: `desktop/src/renderer/components/StatusBar.tsx`

Add two new optional props to `StatusBar.Props`: `onDispatch?: (input: string) => void` and `sessionId?: string | null`. Convert the `<span>` wrapper at the current context chip into a `<button>`, maintain local `contextPopupOpen` state, and render `<ContextPopup>` from the same file.

No unit test added here — the popup's own tests cover render + interaction; StatusBar has no existing component-level test to extend. Manual verification is covered in Task 9.

- [ ] **Step 1: Add the new prop names to the Props interface**

In `desktop/src/renderer/components/StatusBar.tsx`, extend the `Props` interface (currently at line 121):

```tsx
interface Props {
  statusData: StatusData;
  onRunSync?: () => void;
  onOpenSync?: () => void;
  model?: ModelAlias;
  onCycleModel?: () => void;
  permissionMode?: PermissionMode;
  onCyclePermission?: () => void;
  fast?: boolean;
  effort?: string;
  onOpenModelPicker?: () => void;
  // Context popup: session and a dispatcher wrapper threaded from App.tsx.
  sessionId?: string | null;
  onDispatch?: (input: string) => void;
}
```

- [ ] **Step 2: Update the function signature and destructure the props**

Update the default export signature (currently at line 590):

```tsx
export default function StatusBar({
  statusData,
  onRunSync,
  onOpenSync,
  model,
  onCycleModel,
  permissionMode,
  onCyclePermission,
  fast,
  effort,
  onOpenModelPicker,
  sessionId,
  onDispatch,
}: Props) {
```

- [ ] **Step 3: Add popup-open state and import the popup**

At the top of the file, import `ContextPopup`:

```tsx
import ContextPopup from './ContextPopup';
```

Inside the component, alongside the other `useState` calls (lines 594-596), add:

```tsx
const [contextPopupOpen, setContextPopupOpen] = useState(false);
```

Also read `contextTokens` out of `sessionStats`. The existing destructure already captures `sessionStats`; access `sessionStats?.contextTokens` directly where needed (or add a shorthand). Use `sessionStats?.contextTokens ?? null` when passing into the popup.

- [ ] **Step 4: Convert the context chip span to a button**

In `desktop/src/renderer/components/StatusBar.tsx`, replace the block at lines 679-688:

Before:
```tsx
      {/* Context remaining */}
      {show('context') && contextPercent != null && (
        <span className="flex items-center gap-1 px-1.5 py-0.5 rounded-sm bg-panel border border-edge-dim">
          <span>Context:</span>
          <span className={contextColor(contextPercent)}>
            {contextPercent}%
          </span>
          <span>Remaining</span>
        </span>
      )}
```

After:
```tsx
      {/* Context remaining — clickable opens ContextPopup (compact/clear actions + explainer). */}
      {show('context') && contextPercent != null && (
        <button
          onClick={() => setContextPopupOpen(true)}
          aria-haspopup="dialog"
          aria-expanded={contextPopupOpen}
          aria-label={`Context: ${contextPercent}% remaining. Click to manage context.`}
          className="flex items-center gap-1 px-1.5 py-0.5 rounded-sm bg-panel border border-edge-dim hover:border-edge hover:bg-inset transition-colors"
        >
          <span>Context:</span>
          <span className={contextColor(contextPercent)}>{contextPercent}%</span>
          <span>Remaining</span>
        </button>
      )}
```

- [ ] **Step 5: Render the popup at the end of the StatusBar JSX**

In the same file, at the end of the main `return (...)` JSX — just before the final closing `</div>` of the status bar container (around the existing `UpdatePanel` render site — grep for `<UpdatePanel` to find it) — add the popup render. The popup uses `createPortal` internally so position in the tree doesn't matter visually:

```tsx
      {/* Context popup — portal-rendered; position in tree is cosmetic. */}
      <ContextPopup
        open={contextPopupOpen}
        onClose={() => setContextPopupOpen(false)}
        sessionId={sessionId ?? null}
        contextPercent={contextPercent}
        contextTokens={sessionStats?.contextTokens ?? null}
        onDispatch={onDispatch ?? (() => {})}
      />
```

The fallback `() => {}` for `onDispatch` is defensive — if App.tsx doesn't wire it, the buttons become no-ops instead of crashing. App.tsx will wire it in Task 8 so this fallback is never hit in production.

- [ ] **Step 6: Run the full test suite to confirm no regressions**

Run: `cd desktop && npx vitest run`
Expected: PASS — all tests green, no new failures.

- [ ] **Step 7: Commit**

```bash
git add desktop/src/renderer/components/StatusBar.tsx
git commit -m "feat(context-popup): convert context chip to button that opens popup"
```

---

## Task 8: Thread `onDispatch` and `sessionId` from `App.tsx` into `StatusBar`

**Files:**
- Modify: `desktop/src/renderer/App.tsx`

Create a small wrapper at the StatusBar render site that invokes `dispatchSlashCommand` with the existing callbacks (same shape other call sites in App.tsx already use — see lines 1379 and 1430), then pass that wrapper + the active `sessionId` as new StatusBar props.

- [ ] **Step 1: Find the existing dispatcher call site for reference**

Run: `grep -n "dispatchSlashCommand" desktop/src/renderer/App.tsx | head -5`

Expected output lists two call sites (around lines 1379 and 1430). Open the nearest one to understand which fields App.tsx already binds (timeline, callbacks, etc.). The wrapper we construct must match that shape.

- [ ] **Step 2: Add the StatusBar props**

In `desktop/src/renderer/App.tsx`, locate the `<StatusBar ... />` render (around line 1946). Add two new props before the closing `/>`:

```tsx
                  sessionId={sessionId}
                  onDispatch={(input: string) => {
                    if (!sessionId) return;
                    const timeline = chatStateMapRef.current.get(sessionId)?.timeline ?? [];
                    const result = dispatchSlashCommand({
                      raw: input,
                      sessionId,
                      view: currentViewMode,
                      files: [],
                      dispatch,
                      timeline,
                      callbacks: {
                        onResumeCommand: () => setResumeRequested(true),
                        getUsageSnapshot,
                        onOpenPreferences: () => setPreferencesOpen(true),
                        onToast: (msg: string) => {
                          setToast(msg);
                          setTimeout(() => setToast(null), 3000);
                        },
                        getSessionState: (sid: string) => chatStateMapRef.current.get(sid),
                        onOpenModelPicker: () => setModelPickerOpen(true),
                      },
                    });
                    // Mirror the InputBar path: if handled with alsoSendToPty, forward to the session.
                    if (result.handled && result.alsoSendToPty) {
                      window.claude.session.sendInput(sessionId, result.alsoSendToPty);
                    }
                  }}
```

- [ ] **Step 3: Cross-check the wrapper against existing call sites**

Open `desktop/src/renderer/components/InputBar.tsx` near line 225 and confirm the `DispatcherInput` shape passed there matches what the wrapper above constructs. Every field in `callbacks` should be either present or reasonably optional (the interface marks them all optional). If InputBar binds fields we didn't (e.g., a `rewritten` branch for non-handled input), those are not needed here because the StatusBar popup only triggers known slash commands (`/compact`, `/clear`) — both handled-with-alsoSendToPty paths.

- [ ] **Step 4: Run type-check and tests**

Run: `cd desktop && npm test`
Expected: PASS. If TypeScript complains about a missing callback field, add it to the wrapper using the closest analogue in App.tsx's existing dispatcher calls.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/App.tsx
git commit -m "feat(context-popup): wire onDispatch wrapper into StatusBar"
```

---

## Task 9: Manual verification (desktop + Android)

No automated test covers the end-to-end flow; the component tests + type checks established parity. Verify by launching the dev app and the Android WebView build.

**Files:** none modified.

- [ ] **Step 1: Build and launch the dev app**

From the workspace root:
```bash
bash scripts/run-dev.sh
```

Wait for the YouCoded Dev window to appear.

- [ ] **Step 2: Verify the desktop flow**

In the dev window:
1. Start (or resume) any session so a Context chip appears in the status bar.
2. Click the chip — popup opens anchored centered (current implementation; anchored-to-chip refinement deferred per spec).
3. Click **(i)** — explainer shows three sections (Why it matters / What fills it up / What to do). Click **Back** — returns to main view.
4. Click the **chevron** on Compact — editor appears. Type `keep code decisions`. Click **Compact with instructions** — popup closes; a "Compacting…" card appears in chat (from the existing `COMPACTION_PENDING` reducer action); Claude Code starts summarizing.
5. Reopen the popup, click the main **Compact conversation** button — same flow but with no instructions.
6. Reopen, click **Clear and start over** — timeline clears immediately; PTY receives `/clear`.
7. Reopen, press **Esc** — popup closes without interrupting any in-flight work.

If all seven pass, desktop is verified.

- [ ] **Step 3: Verify the Android shared React UI still builds**

From `youcoded/`:
```bash
./scripts/build-web-ui.sh
```

Expected: exits 0, copies `desktop/dist/renderer/` to `app/src/main/assets/web/`. This confirms the popup compiles into the shared bundle. A full APK build is optional — the React code is identical across platforms by construction (see `docs/shared-ui-architecture.md`). If a build-time TypeScript error appears, fix it in the renderer source (NOT in the compiled `app/.../web/` output).

- [ ] **Step 4: Shut down the dev server**

Per the workspace convention in `CLAUDE.md`: "Pushing to master green-lights closing the dev server." Since this task isn't merging to master yet, keep the dev server alive if continuing immediately to execution/review. Otherwise close it (Ctrl+C in the `run-dev.sh` terminal, plus any helper Electron processes).

- [ ] **Step 5: Final commit (verification note — optional)**

No code changes. If you want to mark verification in the history:
```bash
git commit --allow-empty -m "chore(context-popup): manual verification pass (desktop + Android build)"
```

Skip this step if you prefer to leave the branch at the last real commit.

---

## Task 10: Open the pull request

**Files:** none modified.

- [ ] **Step 1: Push the branch and open a PR**

From the worktree:
```bash
git push -u origin feat/context-popup
gh pr create --title "feat(context-popup): clickable Context chip with /compact and /clear" --body "$(cat <<'EOF'
## Summary
- Context % pill in the StatusBar is now a clickable chip
- Click opens a popup with a plain-language explainer (via the existing `SettingsExplainer` pattern), a split-button primary that runs `/compact` with optional focusing instructions, and a secondary `/clear` action
- Renderer-only; works on desktop Electron and Android WebView unchanged

## Test plan
- [ ] `cd desktop && npm test` — all tests green including new `tests/context-popup.test.tsx`
- [ ] `cd desktop && npm run build` — clean build
- [ ] Manual: desktop dev app — click chip → Compact, Compact-with-instructions, Clear, (i) explainer, Esc
- [ ] Manual: `bash scripts/build-web-ui.sh` — shared React bundle builds for Android

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review Notes (plan vs. spec)

Checked against `docs/superpowers/specs/2026-04-24-context-statusbar-popup-design.md`:

- **Anchor & trigger** (spec §Trigger & anchoring): chip→button conversion + popup render are in Task 7. Popup uses portal + `<Scrim layer={2}>` + `<OverlayPanel layer={2}>` (Task 1) and calls `useEscClose` (Task 2). The spec calls for anchor-above-chip positioning; the plan uses the simpler centered position from `ModelPickerPopup` for the first pass and notes it explicitly in Task 9 as a deferred refinement — acceptable because the spec's acceptance is about behavior (opens / closes / dispatches), not pixel position. A follow-up task for anchored positioning can ship separately if needed.
- **Main view** (spec §Popup layout — main view): state block in Task 1, (i) in Task 3, Clear in Task 4, Compact split-button in Task 5, focused-compact editor in Task 6. All four hint bands + the sessionId-disabled guard are tested.
- **Info (i) view** (spec §Popup layout — info (i) view): Task 3 reuses `SettingsExplainer` + `InfoIconButton`. Content matches the spec verbatim.
- **Command wiring** (spec §Command wiring): No dispatcher changes. Task 8 threads an `onDispatch` wrapper through App.tsx; Tasks 5/6 dispatch `/compact`, `/compact <instructions>`, and `/clear`.
- **State & props** (spec §State & props): `showInfo` / `customizing` / `instructions` local state (Tasks 3, 5, 6). Props match the spec's list.
- **Files touched** (spec §Files touched): one new file (`ContextPopup.tsx`), one modified (`StatusBar.tsx`), one added prop threading (`App.tsx`). The spec's "Files touched" section didn't enumerate App.tsx explicitly but the prop threading is implied by the `onDispatch` design decision later in the spec — no drift.
- **Accessibility** (spec §Accessibility): `role="dialog"`, `aria-modal`, `aria-label` on chip, `aria-haspopup`. Focus-trap not explicitly implemented (React/SettingsExplainer don't include one and no other L2 popup in the codebase does either) — matches codebase convention.
- **Success criteria** (spec §Success criteria): all seven items covered by Task 9's manual verification steps 2a–2g.

No gaps found. No placeholders. Types consistent across tasks (`ContextPopupProps` exported from Task 1 and used only inside the file; `sessionId` / `onDispatch` names consistent between StatusBar and App.tsx wiring).
