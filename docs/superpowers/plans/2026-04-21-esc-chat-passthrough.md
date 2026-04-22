# ESC Key Chat Passthrough Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pressing ESC in the chat pane sends `\x1b` to the PTY to interrupt the underlying Claude session; overlays still close first; transcript interrupt markers end the turn in the reducer.

**Architecture:** Add a centralized `useEscClose(open, onClose)` hook backed by a small provider with an ordered stack; migrate ~13 existing overlay ESC `useEffect`s onto it. Install a window-level ESC listener in App.tsx that forwards `\x1b` to the active session's PTY only when no overlay consumed the event and the chat pane is focused. Detect Claude Code's `[Request interrupted by user]` / `[Request interrupted by user for tool use]` transcript markers in `transcript-watcher.ts` and dispatch a new `TRANSCRIPT_INTERRUPT` action that attaches `stopReason: 'interrupted'` to the in-flight turn and calls `endTurn()`.

**Tech Stack:** TypeScript, React, Vitest, Electron (main + renderer).

**Spec:** `docs/superpowers/specs/2026-04-21-esc-chat-passthrough-design.md`

---

## Preconditions

- [ ] **Verify repo is up-to-date**

Run:
```bash
cd /c/Users/desti/youcoded-dev/youcoded && git fetch origin && git pull origin master
```
Expected: `Already up to date` or clean fast-forward.

---

## Task 0: Create worktree for this work

Per workspace CLAUDE.md: "Any work beyond a handful of lines must be done in a separate git worktree." This feature touches ~20 files.

**Files:**
- New worktree at `/c/Users/desti/youcoded-worktrees/esc-chat-passthrough/`

- [ ] **Step 1: Create worktree**

Run:
```bash
cd /c/Users/desti/youcoded-dev/youcoded && git worktree add -b feat/esc-chat-passthrough /c/Users/desti/youcoded-worktrees/esc-chat-passthrough master
```
Expected: `Preparing worktree (new branch 'feat/esc-chat-passthrough')` and the directory exists.

- [ ] **Step 2: Verify worktree**

Run:
```bash
cd /c/Users/desti/youcoded-worktrees/esc-chat-passthrough && git status && git branch --show-current
```
Expected: clean working tree on branch `feat/esc-chat-passthrough`.

**From this point, all file paths are relative to `/c/Users/desti/youcoded-worktrees/esc-chat-passthrough/`.** The path to `youcoded/desktop/src/...` in later tasks refers to this worktree copy, not the original repo.

---

## Task 1: `useEscClose` hook (TDD)

**Files:**
- Create: `desktop/src/renderer/hooks/use-esc-close.tsx`
- Create: `desktop/src/renderer/hooks/use-esc-close.test.tsx`

### Design

A `EscCloseProvider` holds an ordered array of `{ id, onCloseRef }`. `useEscClose(open, onClose)` pushes when `open` transitions true, pops on transition to false or on unmount. A single window-level capture-phase listener on the provider pops the top entry and calls its ref-held `onClose`, calling `preventDefault()` + `stopPropagation()`. `useEscStackEmpty()` exposes a boolean for downstream consumers.

**Why a ref for `onClose`:** consumers re-render often, so the `onClose` identity changes. A ref lets the provider always invoke the latest closure without pushing/popping the stack on every re-render.

**Why capture phase on the provider:** during the migration, any legacy window-level handler still on another overlay would compete for the same event. Capture runs before bubble, so the provider always wins when the stack is non-empty; when the stack is empty, the provider is a pure no-op and legacy handlers are unaffected.

- [ ] **Step 1: Write the failing tests**

Create `desktop/src/renderer/hooks/use-esc-close.test.tsx`:

```tsx
import React, { useState } from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent, act } from '@testing-library/react';
import { EscCloseProvider, useEscClose, useEscStackEmpty } from './use-esc-close';

function pressEsc() {
  act(() => {
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
  });
}

function Overlay({ onClose }: { onClose: () => void }) {
  useEscClose(true, onClose);
  return <div />;
}

describe('useEscClose', () => {
  it('closes a single open overlay on ESC', () => {
    const onClose = vi.fn();
    render(
      <EscCloseProvider>
        <Overlay onClose={onClose} />
      </EscCloseProvider>,
    );
    pressEsc();
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('does not fire when open is false', () => {
    const onClose = vi.fn();
    function ClosedOverlay() {
      useEscClose(false, onClose);
      return <div />;
    }
    render(
      <EscCloseProvider>
        <ClosedOverlay />
      </EscCloseProvider>,
    );
    pressEsc();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('LIFO: closes the most-recently-opened overlay first', () => {
    const onCloseA = vi.fn();
    const onCloseB = vi.fn();
    render(
      <EscCloseProvider>
        <Overlay onClose={onCloseA} />
        <Overlay onClose={onCloseB} />
      </EscCloseProvider>,
    );
    pressEsc();
    expect(onCloseB).toHaveBeenCalledTimes(1);
    expect(onCloseA).not.toHaveBeenCalled();
  });

  it('removes entry from stack on unmount', () => {
    const onClose = vi.fn();
    function Parent({ show }: { show: boolean }) {
      return (
        <EscCloseProvider>
          {show && <Overlay onClose={onClose} />}
        </EscCloseProvider>
      );
    }
    const { rerender } = render(<Parent show={true} />);
    rerender(<Parent show={false} />);
    pressEsc();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('calls the latest onClose identity after re-render', () => {
    const onCloseA = vi.fn();
    const onCloseB = vi.fn();
    function ChangingOverlay({ cb }: { cb: () => void }) {
      useEscClose(true, cb);
      return <div />;
    }
    const { rerender } = render(
      <EscCloseProvider>
        <ChangingOverlay cb={onCloseA} />
      </EscCloseProvider>,
    );
    rerender(
      <EscCloseProvider>
        <ChangingOverlay cb={onCloseB} />
      </EscCloseProvider>,
    );
    pressEsc();
    expect(onCloseB).toHaveBeenCalledTimes(1);
    expect(onCloseA).not.toHaveBeenCalled();
  });

  it('useEscStackEmpty reflects stack state', () => {
    let captured: boolean[] = [];
    function Probe() {
      captured.push(useEscStackEmpty());
      return null;
    }
    function Harness({ open }: { open: boolean }) {
      return (
        <EscCloseProvider>
          <Probe />
          {open && <Overlay onClose={() => {}} />}
        </EscCloseProvider>
      );
    }
    const { rerender } = render(<Harness open={false} />);
    rerender(<Harness open={true} />);
    rerender(<Harness open={false} />);
    // First render: empty. After open: not empty. After close: empty.
    expect(captured[0]).toBe(true);
    expect(captured[captured.length - 2]).toBe(false);
    expect(captured[captured.length - 1]).toBe(true);
  });

  it('calls preventDefault when it handles ESC', () => {
    const onClose = vi.fn();
    render(
      <EscCloseProvider>
        <Overlay onClose={onClose} />
      </EscCloseProvider>,
    );
    const ev = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true });
    act(() => { window.dispatchEvent(ev); });
    expect(ev.defaultPrevented).toBe(true);
  });

  it('does NOT preventDefault when stack is empty', () => {
    render(<EscCloseProvider><div /></EscCloseProvider>);
    const ev = new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true });
    act(() => { window.dispatchEvent(ev); });
    expect(ev.defaultPrevented).toBe(false);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd desktop && npx vitest run src/renderer/hooks/use-esc-close.test.tsx
```
Expected: FAIL with `Cannot find module './use-esc-close'`.

- [ ] **Step 3: Implement the hook + provider**

Create `desktop/src/renderer/hooks/use-esc-close.tsx`:

```tsx
import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';

// Centralized ESC-key dismissal stack. Overlays call useEscClose(open, onClose);
// a single window-level capture-phase listener pops the top of the stack on ESC
// and invokes its onClose. When the stack is empty the listener is a no-op, so
// ESC can fall through to the chat-passthrough handler in App.tsx (which then
// forwards \x1b to the PTY to interrupt the active Claude session).
//
// This replaces ~13 ad-hoc `useEffect(() => { ... if (e.key === 'Escape') onClose(); ... })`
// copies across overlay components. Reasons for the indirection:
//   1. LIFO semantics — if two overlays are open, only the top one closes per ESC press.
//   2. preventDefault'd events signal to the chat-passthrough listener that an
//      overlay consumed the keypress, so we don't both close an overlay AND
//      interrupt Claude on a single ESC.
//   3. Single source of truth for "is any overlay open right now".

type Closer = { id: number; ref: React.MutableRefObject<() => void> };

type StoreListener = () => void;

class EscStore {
  private stack: Closer[] = [];
  private listeners = new Set<StoreListener>();

  push(closer: Closer) {
    this.stack.push(closer);
    this.emit();
  }

  remove(id: number) {
    const before = this.stack.length;
    this.stack = this.stack.filter((c) => c.id !== id);
    if (this.stack.length !== before) this.emit();
  }

  popTop(): Closer | undefined {
    const top = this.stack.pop();
    if (top) this.emit();
    return top;
  }

  get isEmpty(): boolean {
    return this.stack.length === 0;
  }

  subscribe(l: StoreListener): () => void {
    this.listeners.add(l);
    return () => this.listeners.delete(l);
  }

  private emit() {
    for (const l of this.listeners) l();
  }
}

const EscStoreContext = createContext<EscStore | null>(null);

let nextId = 1;

export function EscCloseProvider({ children }: { children: React.ReactNode }): JSX.Element {
  // One store per provider instance. In practice we mount exactly one at App root.
  const storeRef = useRef<EscStore | null>(null);
  if (storeRef.current === null) storeRef.current = new EscStore();
  const store = storeRef.current;

  useEffect(() => {
    // Capture phase so we run before any legacy bubble-phase listener still
    // present during the migration, and before the App-level chat passthrough.
    const handler = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      if (store.isEmpty) return;
      const top = store.popTop();
      if (!top) return;
      // stopPropagation prevents any other window listeners from double-firing;
      // preventDefault is the signal the App-level passthrough listener reads
      // to know an overlay consumed this event.
      e.preventDefault();
      e.stopPropagation();
      try {
        top.ref.current();
      } catch (err) {
        // An overlay's onClose threw. Log and carry on so the stack doesn't
        // get stuck with a zombie top.
        // eslint-disable-next-line no-console
        console.error('[useEscClose] onClose threw:', err);
      }
    };
    window.addEventListener('keydown', handler, true);
    return () => window.removeEventListener('keydown', handler, true);
  }, [store]);

  return <EscStoreContext.Provider value={store}>{children}</EscStoreContext.Provider>;
}

export function useEscClose(open: boolean, onClose: () => void): void {
  const store = useContext(EscStoreContext);
  if (!store) {
    throw new Error('useEscClose must be used inside <EscCloseProvider>');
  }
  const ref = useRef(onClose);
  // Keep the ref pointing at the latest onClose so consumers can re-render
  // without us churning the stack.
  useEffect(() => { ref.current = onClose; }, [onClose]);

  useEffect(() => {
    if (!open) return;
    const id = nextId++;
    store.push({ id, ref });
    return () => store.remove(id);
  }, [open, store]);
}

export function useEscStackEmpty(): boolean {
  const store = useContext(EscStoreContext);
  if (!store) {
    throw new Error('useEscStackEmpty must be used inside <EscCloseProvider>');
  }
  return useSyncExternalStore(
    useCallback((l) => store.subscribe(l), [store]),
    useCallback(() => store.isEmpty, [store]),
    useCallback(() => true, []),
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd desktop && npx vitest run src/renderer/hooks/use-esc-close.test.tsx
```
Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /c/Users/desti/youcoded-worktrees/esc-chat-passthrough
git add youcoded/desktop/src/renderer/hooks/use-esc-close.tsx youcoded/desktop/src/renderer/hooks/use-esc-close.test.tsx
git commit -m "feat(esc): add useEscClose stack hook for centralized overlay dismissal"
```

---

## Task 2: `shouldForwardEscToPty` pure function (TDD)

**Files:**
- Create: `desktop/src/renderer/state/should-forward-esc-to-pty.ts`
- Create: `desktop/src/renderer/state/should-forward-esc-to-pty.test.ts`

### Design

Decision function for the App-level passthrough listener. Four boolean inputs; `true` means "send `\x1b` to the PTY." Extracted as a pure function for unit-testing without mounting App.

- [ ] **Step 1: Write the failing tests**

Create `desktop/src/renderer/state/should-forward-esc-to-pty.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { shouldForwardEscToPty } from './should-forward-esc-to-pty';

describe('shouldForwardEscToPty', () => {
  const base = {
    defaultPrevented: false,
    viewMode: 'chat' as const,
    hasActiveSession: true,
  };

  it('forwards when all conditions are met', () => {
    expect(shouldForwardEscToPty(base)).toBe(true);
  });

  it('does NOT forward when the event was defaultPrevented by an overlay', () => {
    expect(shouldForwardEscToPty({ ...base, defaultPrevented: true })).toBe(false);
  });

  it('does NOT forward when view mode is terminal', () => {
    expect(shouldForwardEscToPty({ ...base, viewMode: 'terminal' })).toBe(false);
  });

  it('does NOT forward when there is no active session', () => {
    expect(shouldForwardEscToPty({ ...base, hasActiveSession: false })).toBe(false);
  });

  it('returns false when multiple guards fail', () => {
    expect(shouldForwardEscToPty({
      defaultPrevented: true,
      viewMode: 'terminal',
      hasActiveSession: false,
    })).toBe(false);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd desktop && npx vitest run src/renderer/state/should-forward-esc-to-pty.test.ts
```
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

Create `desktop/src/renderer/state/should-forward-esc-to-pty.ts`:

```ts
// Decision function for the App-level ESC-to-PTY passthrough.
// Extracted as a pure function so it's unit-testable without mounting App.
//
// Three guards, all must pass:
//   1. defaultPrevented: the provider sets this when an overlay consumed ESC,
//      so we don't both close the overlay AND interrupt Claude.
//   2. viewMode === 'chat': in terminal view, xterm already forwards ESC
//      natively to node-pty. Running our handler too would double-send.
//   3. hasActiveSession: nothing to send to otherwise.
//
// Note: BuddyChat is not a concern here. It renders in a separate window
// (buddyMode === 'buddy-chat' in App.tsx) with its own React root and its
// own `window` object, so its ESC handler cannot collide with the main
// window's listener.
export function shouldForwardEscToPty(params: {
  defaultPrevented: boolean;
  viewMode: 'chat' | 'terminal';
  hasActiveSession: boolean;
}): boolean {
  return !params.defaultPrevented
    && params.viewMode === 'chat'
    && params.hasActiveSession;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd desktop && npx vitest run src/renderer/state/should-forward-esc-to-pty.test.ts
```
Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add youcoded/desktop/src/renderer/state/should-forward-esc-to-pty.ts youcoded/desktop/src/renderer/state/should-forward-esc-to-pty.test.ts
git commit -m "feat(esc): pure guard fn for chat ESC -> PTY passthrough"
```

---

## Task 3: Add `TRANSCRIPT_INTERRUPT` event + action types

**Files:**
- Modify: `desktop/src/main/transcript-watcher.ts` (add event type in `TranscriptEvent` union)
- Modify: `desktop/src/renderer/state/chat-types.ts` (add action type in `ChatAction` union)

### Design

Two type additions only, no logic. Keeps type-graph clean before the implementing tasks depend on them.

- [ ] **Step 1: Add event type in transcript-watcher.ts**

Find the `TranscriptEvent` union type at the top of `desktop/src/main/transcript-watcher.ts`. It is a discriminated union by `type: 'user-message' | 'assistant-text' | ...`. Add a new variant:

```ts
| {
    type: 'user-interrupt';
    sessionId: string;
    uuid: string;
    timestamp: number;
    data: { kind: 'plain' | 'tool-use' };
  }
```

If the file uses an inline union, insert alongside the existing `'user-message'` variant. If it imports event shapes from a types module, add it there instead — search for the existing `'user-message'` event to find the location.

- [ ] **Step 2: Add action type in chat-types.ts**

Find the `ChatAction` union in `desktop/src/renderer/state/chat-types.ts`. Add:

```ts
| {
    type: 'TRANSCRIPT_INTERRUPT';
    sessionId: string;
    uuid: string;
    timestamp: number;
    kind: 'plain' | 'tool-use';
  }
```

Insert near `TRANSCRIPT_TURN_COMPLETE` so related actions stay grouped.

- [ ] **Step 3: Typecheck**

Run:
```bash
cd desktop && npx tsc --noEmit
```
Expected: no new errors. (Existing errors, if any, are unrelated.)

- [ ] **Step 4: Commit**

```bash
git add youcoded/desktop/src/main/transcript-watcher.ts youcoded/desktop/src/renderer/state/chat-types.ts
git commit -m "feat(esc): add TRANSCRIPT_INTERRUPT event + action types"
```

---

## Task 4: Detect interrupt markers in `transcript-watcher.ts` (TDD)

**Files:**
- Modify: `desktop/src/main/transcript-watcher.ts` (interrupt detection in the user-message branch)
- Create or extend: `desktop/src/main/transcript-watcher.test.ts`

### Design

When Claude Code interrupts, it writes a `type: "user"` message whose text content is **exactly** one of:

- `[Request interrupted by user]`
- `[Request interrupted by user for tool use]`

These arrive with a `promptId`, so they enter the same branch that emits `'user-message'` today. We intercept and emit `'user-interrupt'` instead, with `kind: 'plain' | 'tool-use'` derived from the suffix. The interrupt marker is **not** also emitted as a user message — we suppress the user bubble.

**Exact-match only:** If the user legitimately types the literal string themselves (e.g., in a code block), it still triggers the interrupt branch. Documented acceptable edge. Substring match would produce false positives for the literal string embedded in user text, which is strictly worse.

- [ ] **Step 1: Locate the test file**

Run:
```bash
ls desktop/src/main/transcript-watcher.test.ts 2>/dev/null || echo "MISSING"
```

If MISSING, create an empty scaffold first:
```ts
// desktop/src/main/transcript-watcher.test.ts
import { describe, it, expect } from 'vitest';
// Tests added in step 2.
describe('transcript-watcher', () => {
  it.todo('added in step 2');
});
```

Otherwise open the existing file — you'll append tests to it.

- [ ] **Step 2: Write the failing tests**

The exact symbol to test depends on the watcher's exports. Read `transcript-watcher.ts` and find the pure parser — typically a function like `parseTranscriptLine(line: string, sessionId: string): TranscriptEvent[]` or a method on the watcher class. If only the class is exported, the parser logic may be inline inside a method. In that case, first extract a pure helper `parseUserMessageContent(...): TranscriptEvent[]` that both the class and the tests can call. Update the line numbers noted in the spec if the file layout has drifted.

Add these tests to `desktop/src/main/transcript-watcher.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { parseTranscriptLine } from './transcript-watcher'; // adjust import to whatever exists

function makeUserLine(text: string, promptId = 'pid-1', uuid = 'u-1', timestamp = '2026-04-21T00:00:00Z') {
  return JSON.stringify({
    type: 'user',
    promptId,
    uuid,
    timestamp,
    message: { role: 'user', content: [{ type: 'text', text }] },
  });
}

describe('transcript-watcher interrupt detection', () => {
  it('emits user-interrupt (kind=plain) for "[Request interrupted by user]"', () => {
    const events = parseTranscriptLine(makeUserLine('[Request interrupted by user]'), 'sess-1');
    expect(events).toEqual([
      expect.objectContaining({ type: 'user-interrupt', sessionId: 'sess-1', data: { kind: 'plain' } }),
    ]);
  });

  it('emits user-interrupt (kind=tool-use) for "[Request interrupted by user for tool use]"', () => {
    const events = parseTranscriptLine(makeUserLine('[Request interrupted by user for tool use]'), 'sess-1');
    expect(events).toEqual([
      expect.objectContaining({ type: 'user-interrupt', sessionId: 'sess-1', data: { kind: 'tool-use' } }),
    ]);
  });

  it('does NOT emit a user-message when emitting user-interrupt', () => {
    const events = parseTranscriptLine(makeUserLine('[Request interrupted by user]'), 'sess-1');
    expect(events.some((e) => e.type === 'user-message')).toBe(false);
  });

  it('emits user-message for a normal user prompt', () => {
    const events = parseTranscriptLine(makeUserLine('hello claude'), 'sess-1');
    expect(events).toEqual([
      expect.objectContaining({ type: 'user-message', data: expect.objectContaining({ text: 'hello claude' }) }),
    ]);
  });

  it('treats interrupt text embedded in longer content as a normal user-message', () => {
    const events = parseTranscriptLine(makeUserLine('hey, [Request interrupted by user] btw'), 'sess-1');
    expect(events).toEqual([
      expect.objectContaining({ type: 'user-message' }),
    ]);
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run:
```bash
cd desktop && npx vitest run src/main/transcript-watcher.test.ts
```
Expected: the 3 interrupt tests FAIL (no detection logic yet). The normal-user-message test might already pass if the parser exists.

- [ ] **Step 4: Implement interrupt detection**

In `desktop/src/main/transcript-watcher.ts`, locate the branch that handles user messages with a `promptId` (currently around line 112-128). That block extracts `text` from the content and then emits a `'user-message'` event. Modify it:

```ts
// User-typed prompt: has a promptId and text content (not tool results)
if (parsed.promptId) {
  const raw = typeof content === 'string'
    ? content
    : extractTextFromBlocks(content);
  const text = stripSystemTags(raw);
  // Skip empty messages (e.g. interrupted tool use placeholders)
  if (!text) return [];

  // Intercept Claude Code's user-interrupt markers. They arrive as a user
  // message with text content matching exactly one of the two strings below.
  // We emit a dedicated user-interrupt event (consumed by the reducer to end
  // the in-flight turn) instead of the normal user-message, so the marker
  // does not render as a user bubble.
  if (text === '[Request interrupted by user]') {
    events.push({
      type: 'user-interrupt',
      sessionId,
      uuid,
      timestamp,
      data: { kind: 'plain' },
    });
    return events;
  }
  if (text === '[Request interrupted by user for tool use]') {
    events.push({
      type: 'user-interrupt',
      sessionId,
      uuid,
      timestamp,
      data: { kind: 'tool-use' },
    });
    return events;
  }

  events.push({
    type: 'user-message',
    sessionId,
    uuid,
    timestamp,
    data: { text },
  });
  return events;
}
```

If a pure helper had to be extracted in Step 2 to make this testable, keep the extraction and call it from the class method.

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
cd desktop && npx vitest run src/main/transcript-watcher.test.ts
```
Expected: all interrupt tests + the baseline user-message test PASS.

- [ ] **Step 6: Typecheck**

Run:
```bash
cd desktop && npx tsc --noEmit
```
Expected: no new errors.

- [ ] **Step 7: Commit**

```bash
git add youcoded/desktop/src/main/transcript-watcher.ts youcoded/desktop/src/main/transcript-watcher.test.ts
git commit -m "feat(esc): detect user-interrupt markers in transcript watcher"
```

---

## Task 5: Reducer handler for `TRANSCRIPT_INTERRUPT` (TDD)

**Files:**
- Modify: `desktop/src/renderer/state/chat-reducer.ts` (extend `endTurn` signature; add `TRANSCRIPT_INTERRUPT` case)
- Create or extend: `desktop/src/renderer/state/__tests__/chat-reducer.test.ts`

### Design

Mirror `TRANSCRIPT_TURN_COMPLETE` at line 650: find the in-flight turn, attach `stopReason: 'interrupted'` via spread-then-override on `assistantTurns`, then spread `endTurn(session)` onto the session. If no in-flight turn exists, skip metadata attachment but still call `endTurn` — it's idempotent.

Extend `endTurn(session, errorMessage = 'Turn ended')` so the interrupt case can pass `'Turn interrupted'` for user-facing tool failure copy. All existing callers (the current default) are unaffected.

- [ ] **Step 1: Locate or create the reducer test file**

Run:
```bash
ls desktop/src/renderer/state/__tests__/chat-reducer.test.ts 2>/dev/null || echo "MISSING"
```

If MISSING, create scaffold:
```ts
// desktop/src/renderer/state/__tests__/chat-reducer.test.ts
import { describe, it, expect } from 'vitest';
import { chatReducer } from '../chat-reducer';
import { createSessionChatState } from '../chat-types';
import type { ChatState, ToolCallState } from '../chat-types';
describe('chatReducer TRANSCRIPT_INTERRUPT', () => {
  it.todo('added below');
});
```

Adjust the `chatReducer` import name to whatever the file actually exports (search `chat-reducer.ts` for `export function` or `export const`).

- [ ] **Step 2: Write the failing tests**

Append to the test file:

```ts
function stateWithInFlightTurn(sessionId = 'sess-1', turnId = 'turn-1'): ChatState {
  const session = createSessionChatState();
  session.currentTurnId = turnId;
  session.isThinking = true;
  const runningTool: ToolCallState = {
    id: 'tool-1',
    toolName: 'Bash',
    status: 'running',
    input: { command: 'sleep 1000' },
  } as any;
  const awaitingTool: ToolCallState = {
    id: 'tool-2',
    toolName: 'Edit',
    status: 'awaiting-approval',
    input: {},
  } as any;
  session.toolCalls.set('tool-1', runningTool);
  session.toolCalls.set('tool-2', awaitingTool);
  session.activeTurnToolIds.add('tool-1');
  session.activeTurnToolIds.add('tool-2');
  session.assistantTurns.set(turnId, {
    id: turnId,
    segments: [],
    timestamp: 1000,
    stopReason: null,
    model: null,
    usage: null,
    anthropicRequestId: null,
  });
  return new Map([[sessionId, session]]);
}

describe('chatReducer TRANSCRIPT_INTERRUPT', () => {
  it('attaches stopReason=interrupted to the in-flight turn', () => {
    const state = stateWithInFlightTurn();
    const next = chatReducer(state, {
      type: 'TRANSCRIPT_INTERRUPT',
      sessionId: 'sess-1',
      uuid: 'u-1',
      timestamp: 2000,
      kind: 'plain',
    });
    const session = next.get('sess-1')!;
    expect(session.assistantTurns.get('turn-1')?.stopReason).toBe('interrupted');
  });

  it('flips running/awaiting-approval tools to failed with error "Turn interrupted"', () => {
    const state = stateWithInFlightTurn();
    const next = chatReducer(state, {
      type: 'TRANSCRIPT_INTERRUPT',
      sessionId: 'sess-1',
      uuid: 'u-1',
      timestamp: 2000,
      kind: 'tool-use',
    });
    const session = next.get('sess-1')!;
    expect(session.toolCalls.get('tool-1')?.status).toBe('failed');
    expect((session.toolCalls.get('tool-1') as any).error).toBe('Turn interrupted');
    expect(session.toolCalls.get('tool-2')?.status).toBe('failed');
    expect((session.toolCalls.get('tool-2') as any).error).toBe('Turn interrupted');
  });

  it('clears turn-scoped state via endTurn()', () => {
    const state = stateWithInFlightTurn();
    const next = chatReducer(state, {
      type: 'TRANSCRIPT_INTERRUPT',
      sessionId: 'sess-1',
      uuid: 'u-1',
      timestamp: 2000,
      kind: 'plain',
    });
    const session = next.get('sess-1')!;
    expect(session.isThinking).toBe(false);
    expect(session.currentTurnId).toBeNull();
    expect(session.activeTurnToolIds.size).toBe(0);
    expect(session.attentionState).toBe('ok');
  });

  it('is a no-op-safe call when there is no in-flight turn', () => {
    const session = createSessionChatState();
    session.isThinking = false;
    session.currentTurnId = null;
    const state: ChatState = new Map([['sess-1', session]]);
    const next = chatReducer(state, {
      type: 'TRANSCRIPT_INTERRUPT',
      sessionId: 'sess-1',
      uuid: 'u-1',
      timestamp: 2000,
      kind: 'plain',
    });
    const nextSession = next.get('sess-1')!;
    expect(nextSession.isThinking).toBe(false);
    expect(nextSession.currentTurnId).toBeNull();
  });

  it('returns original state if sessionId is unknown', () => {
    const state = stateWithInFlightTurn();
    const next = chatReducer(state, {
      type: 'TRANSCRIPT_INTERRUPT',
      sessionId: 'no-such-session',
      uuid: 'u-1',
      timestamp: 2000,
      kind: 'plain',
    });
    expect(next).toBe(state);
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run:
```bash
cd desktop && npx vitest run src/renderer/state/__tests__/chat-reducer.test.ts
```
Expected: FAIL — no handler for `TRANSCRIPT_INTERRUPT`; reducer returns state unchanged, so most assertions fail.

- [ ] **Step 4: Extend `endTurn` to accept an optional error message**

In `desktop/src/renderer/state/chat-reducer.ts` at line 139:

```ts
function endTurn(
  session: SessionChatState,
  errorMessage: string = 'Turn ended',
): Partial<SessionChatState> {
  const toolCalls = new Map(session.toolCalls);
  for (const id of session.activeTurnToolIds) {
    const tool = toolCalls.get(id);
    if (tool && (tool.status === 'running' || tool.status === 'awaiting-approval')) {
      toolCalls.set(id, { ...tool, status: 'failed', error: errorMessage });
    }
  }
  return {
    toolCalls,
    isThinking: false,
    streamingText: '',
    currentGroupId: null,
    currentTurnId: null,
    activeTurnToolIds: new Set(),
    attentionState: 'ok' as const,
  };
}
```

All existing callsites continue to work because `errorMessage` defaults to `'Turn ended'`.

- [ ] **Step 5: Add the `TRANSCRIPT_INTERRUPT` case**

Add immediately after `TRANSCRIPT_TURN_COMPLETE` (near line 678). Pattern mirrors TURN_COMPLETE: attach `stopReason` to the in-flight turn (if any), then spread `endTurn(session, 'Turn interrupted')`:

```ts
case 'TRANSCRIPT_INTERRUPT': {
  const session = next.get(action.sessionId);
  if (!session) return state;

  // Attach stopReason='interrupted' to the in-flight turn so the
  // AssistantTurnBubble footer shows "Interrupted" under the affected turn.
  // Then endTurn() clears turn-scoped state and flips any running /
  // awaiting-approval tools in this turn to failed with error 'Turn interrupted'.
  const interruptingTurnId = session.currentTurnId;
  const assistantTurns = new Map(session.assistantTurns);
  if (interruptingTurnId) {
    const turn = assistantTurns.get(interruptingTurnId);
    if (turn) {
      assistantTurns.set(interruptingTurnId, {
        ...turn,
        stopReason: 'interrupted',
      });
    }
  }

  next.set(action.sessionId, { ...session, assistantTurns, ...endTurn(session, 'Turn interrupted') });
  return next;
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run:
```bash
cd desktop && npx vitest run src/renderer/state/__tests__/chat-reducer.test.ts
```
Expected: all 5 new tests PASS.

- [ ] **Step 7: Run the full reducer test suite**

Run:
```bash
cd desktop && npx vitest run src/renderer/state/__tests__/
```
Expected: all tests PASS (no regression in `chat-serialization.test.ts` or `chat-hydration.test.ts`).

- [ ] **Step 8: Commit**

```bash
git add youcoded/desktop/src/renderer/state/chat-reducer.ts youcoded/desktop/src/renderer/state/__tests__/chat-reducer.test.ts
git commit -m "feat(esc): reducer handler for TRANSCRIPT_INTERRUPT + endTurn error msg param"
```

---

## Task 6: Wire the event→action translation in App.tsx

**Files:**
- Modify: `desktop/src/renderer/App.tsx` (~line 611 — the transcript event switch)

- [ ] **Step 1: Add the case**

In `desktop/src/renderer/App.tsx`, find the `transcriptHandler` switch around line 611. Immediately after `case 'user-message':` add:

```tsx
case 'user-interrupt':
  batchTranscriptDispatch({
    type: 'TRANSCRIPT_INTERRUPT',
    sessionId: event.sessionId,
    uuid: event.uuid,
    timestamp: event.timestamp,
    kind: event.data.kind,
  });
  break;
```

- [ ] **Step 2: Typecheck**

Run:
```bash
cd desktop && npx tsc --noEmit
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add youcoded/desktop/src/renderer/App.tsx
git commit -m "feat(esc): dispatch TRANSCRIPT_INTERRUPT from user-interrupt transcript events"
```

---

## Task 7: Mount `EscCloseProvider` at App root

**Files:**
- Modify: `desktop/src/renderer/App.tsx`

- [ ] **Step 1: Import the provider**

Add near the existing hook/state imports in App.tsx:

```tsx
import { EscCloseProvider } from './hooks/use-esc-close';
```

- [ ] **Step 2: Wrap the app tree**

Find the top-level return of `App` (or whatever provider scope wraps `ChatProvider`, `ThemeProvider`, etc.). Wrap that tree:

```tsx
return (
  <EscCloseProvider>
    {/* existing providers/content */}
  </EscCloseProvider>
);
```

It must be high enough in the tree that every overlay component is a descendant.

- [ ] **Step 3: Verify the app still boots**

Run:
```bash
cd desktop && npm run build
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add youcoded/desktop/src/renderer/App.tsx
git commit -m "feat(esc): mount EscCloseProvider at app root"
```

---

## Task 8: Install chat-passthrough ESC listener in App.tsx

**Files:**
- Modify: `desktop/src/renderer/App.tsx`

### Design

One window-level keydown listener in a top-level `useEffect`. It reads the current view mode, active session id, and BuddyChat-open state from existing App state. On ESC with guard=true, it calls `window.claude.session.sendInput(sessionId, '\x1b')`. A ref pattern keeps the reactive values fresh without re-registering the listener on every state change.

**Why a ref instead of the useEffect dep array:** listing the values in deps would tear down and re-register the listener on every change — noisy but correct. The ref pattern keeps exactly one installation while still reading the latest values at event time.

**BuddyChat open state source:** find whatever App-level state already tracks BuddyChat visibility (search App.tsx for `buddy` / `BuddyChat`). If no single boolean exists yet but two or more props drive visibility, expose a derived boolean in scope for the listener. Don't introduce a new state field.

- [ ] **Step 1: Add the imports**

```tsx
import { shouldForwardEscToPty } from './state/should-forward-esc-to-pty';
import { useRef } from 'react'; // already imported — verify
```

- [ ] **Step 2: Add the listener**

In the App component body, after the view-mode and active-session state are declared, add:

```tsx
// Forward ESC to the active session's PTY when chat is focused and no
// overlay consumed the event. See docs/superpowers/specs/2026-04-21-esc-chat-passthrough-design.md
// and docs/PITFALLS.md → "Keyboard Routing".
const escPassthroughStateRef = useRef({
  activeSessionId: '',
  viewMode: 'chat' as 'chat' | 'terminal',
});
escPassthroughStateRef.current = {
  activeSessionId: activeSessionId ?? '',
  viewMode: currentViewMode,
};

useEffect(() => {
  const handler = (e: KeyboardEvent) => {
    if (e.key !== 'Escape') return;
    const s = escPassthroughStateRef.current;
    const forward = shouldForwardEscToPty({
      defaultPrevented: e.defaultPrevented,
      viewMode: s.viewMode,
      hasActiveSession: !!s.activeSessionId,
    });
    if (!forward) return;
    // One byte to the PTY — Claude Code treats it as an interrupt.
    // Single-byte writes do NOT trigger Ink's 500ms paste-mode coalescing,
    // so no chunking or pacing is needed. See docs/PITFALLS.md → "PTY Writes".
    window.claude.session.sendInput(s.activeSessionId, '\x1b');
  };
  // Bubble phase on purpose — capture phase is the EscCloseProvider's slot.
  // Bubble fires after capture, so by the time this listener runs the
  // provider has already popped + preventDefault'd when appropriate.
  window.addEventListener('keydown', handler);
  return () => window.removeEventListener('keydown', handler);
}, []);
```

Make sure the variable names on the right (`activeSessionId`, `currentViewMode`) match what App.tsx actually declares in scope — search for `currentViewMode` (already exists per spec research).

- [ ] **Step 3: Typecheck and build**

Run:
```bash
cd desktop && npx tsc --noEmit && npm run build
```
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add youcoded/desktop/src/renderer/App.tsx
git commit -m "feat(esc): install chat ESC -> PTY passthrough listener in App"
```

---

## Task 9: Add 'interrupted' stop-reason copy

**Files:**
- Modify: `desktop/src/renderer/components/AssistantTurnBubble.tsx` (line 25-30)

- [ ] **Step 1: Update the copy map**

Change:

```tsx
const STOP_REASON_COPY: Record<string, string> = {
  max_tokens: 'Response truncated — Claude hit the output token limit.',
  stop_sequence: 'Response stopped at a configured stop sequence.',
  refusal: 'Claude declined to respond.',
  pause_turn: 'Extended thinking paused mid-turn.',
};
```

to:

```tsx
const STOP_REASON_COPY: Record<string, string> = {
  max_tokens: 'Response truncated — Claude hit the output token limit.',
  stop_sequence: 'Response stopped at a configured stop sequence.',
  refusal: 'Claude declined to respond.',
  pause_turn: 'Extended thinking paused mid-turn.',
  interrupted: 'Interrupted.',
};
```

The short copy matches the tone of the existing entries; the footer already renders with `italic` + a left border, so the single word is enough.

- [ ] **Step 2: Commit**

```bash
git add youcoded/desktop/src/renderer/components/AssistantTurnBubble.tsx
git commit -m "feat(esc): render 'Interrupted' footer for interrupted-stopReason turns"
```

---

## Task 10: Migrate overlays to `useEscClose` — batch 1 (simple overlays)

**Files:**
- Modify: `desktop/src/renderer/components/CommandDrawer.tsx`
- Modify: `desktop/src/renderer/components/ShareSheet.tsx`
- Modify: `desktop/src/renderer/components/ThemeShareSheet.tsx`
- Modify: `desktop/src/renderer/components/SkillEditor.tsx`
- Modify: `desktop/src/renderer/components/ResumeBrowser.tsx`
- Modify: `desktop/src/renderer/components/AboutPopup.tsx`
- Modify: `desktop/src/renderer/components/CloseSessionPrompt.tsx`
- Modify: `desktop/src/renderer/components/FolderSwitcher.tsx`
- Modify: `desktop/src/renderer/components/marketplace/MarketplaceScreen.tsx`

All nine have the identical pattern; the replacement is mechanical.

- [ ] **Step 1: For each file, replace the ESC `useEffect` with `useEscClose`**

Find this block (exact shape varies by variable name — typically `open`/`onClose`, but some may use `isOpen` or `editorOpen`):

```tsx
// Close on Escape
useEffect(() => {
  if (!open) return;
  const handler = (e: KeyboardEvent) => {
    if (e.key === 'Escape') onClose();
  };
  window.addEventListener('keydown', handler);
  return () => window.removeEventListener('keydown', handler);
}, [open, onClose]);
```

Replace with:

```tsx
useEscClose(open, onClose);
```

Add the import at the top of the file:

```tsx
import { useEscClose } from '../hooks/use-esc-close';
```

(For files under `components/marketplace/`, the import path is `'../../hooks/use-esc-close'`.)

Remove the now-unused `useEffect` import if no other `useEffect` remains in the file — `tsc` and the React linter will flag unused imports.

- [ ] **Step 2: Build**

Run:
```bash
cd desktop && npx tsc --noEmit && npm run build
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add youcoded/desktop/src/renderer/components/CommandDrawer.tsx \
        youcoded/desktop/src/renderer/components/ShareSheet.tsx \
        youcoded/desktop/src/renderer/components/ThemeShareSheet.tsx \
        youcoded/desktop/src/renderer/components/SkillEditor.tsx \
        youcoded/desktop/src/renderer/components/ResumeBrowser.tsx \
        youcoded/desktop/src/renderer/components/AboutPopup.tsx \
        youcoded/desktop/src/renderer/components/CloseSessionPrompt.tsx \
        youcoded/desktop/src/renderer/components/FolderSwitcher.tsx \
        youcoded/desktop/src/renderer/components/marketplace/MarketplaceScreen.tsx
git commit -m "refactor(esc): migrate 9 simple overlays to useEscClose"
```

---

## Task 11: Migrate overlays — batch 2 (guarded + capture-phase cases)

**Files:**
- Modify: `desktop/src/renderer/components/marketplace/RatingSubmitModal.tsx` (inFlight guard)
- Modify: `desktop/src/renderer/components/marketplace/ReportReviewButton.tsx` (inFlight guard)
- Modify: `desktop/src/renderer/components/QuickChips.tsx` (had capture-phase + stopPropagation)

### Design

- For `RatingSubmitModal` and `ReportReviewButton`, the existing handler wraps `onClose` with an `inFlight` guard. Replicate that by passing a guarded close to `useEscClose`.
- For `QuickChips`, its existing handler used capture phase + `stopPropagation` to beat other overlays — that workaround is obsolete once every overlay is on the stack (LIFO ordering gives it first dibs when it's top). Simple migration.

- [ ] **Step 1: Migrate `RatingSubmitModal.tsx`**

Replace the existing ESC `useEffect` with:

```tsx
const handleEscapeClose = useCallback(() => {
  if (!inFlight) onClose();
}, [inFlight, onClose]);
useEscClose(open, handleEscapeClose);
```

Add imports:
```tsx
import { useCallback } from 'react'; // if not already imported
import { useEscClose } from '../../hooks/use-esc-close';
```

- [ ] **Step 2: Migrate `ReportReviewButton.tsx`** — same pattern, adjust to whatever the file calls its `inFlight` equivalent.

- [ ] **Step 3: Migrate `QuickChips.tsx`**

Current block:

```tsx
useEffect(() => {
  if (!editorOpen) return;
  const handler = (e: KeyboardEvent) => {
    if (e.key === 'Escape') { setEditorOpen(false); e.stopPropagation(); }
  };
  window.addEventListener('keydown', handler, true);
  return () => window.removeEventListener('keydown', handler, true);
}, [editorOpen]);
```

Replace with:

```tsx
const handleEditorClose = useCallback(() => setEditorOpen(false), [setEditorOpen]);
useEscClose(editorOpen, handleEditorClose);
```

Add imports (same as above; import path is `'../hooks/use-esc-close'` from `components/`).

- [ ] **Step 4: Build**

Run:
```bash
cd desktop && npx tsc --noEmit && npm run build
```

- [ ] **Step 5: Commit**

```bash
git add youcoded/desktop/src/renderer/components/marketplace/RatingSubmitModal.tsx \
        youcoded/desktop/src/renderer/components/marketplace/ReportReviewButton.tsx \
        youcoded/desktop/src/renderer/components/QuickChips.tsx
git commit -m "refactor(esc): migrate guarded + capture-phase overlays to useEscClose"
```

---

## Task 12: Update docs (PITFALLS + keyboard shortcuts)

**Files:**
- Modify: `docs/PITFALLS.md` (workspace scaffold root)
- Modify: `youcoded/desktop/CLAUDE.md` (the keyboard shortcuts table in "Keyboard Shortcuts")

### PITFALLS entry

Add a new section between "Overlays" and existing later sections (preserve alphabetical-ish section ordering if the file uses it; otherwise append):

```markdown
## Keyboard Routing

- **ESC handling flows through `useEscClose` stack → chat-passthrough guard.** The stack's capture-phase listener pops the top overlay and calls `preventDefault()`; the App-level bubble-phase listener reads `defaultPrevented` to decide whether to forward `\x1b` to the active session's PTY. Do not add parallel window-level ESC listeners — they break the stack's LIFO ordering and can race the chat-passthrough. Exception: **xterm's terminal view** still forwards ESC natively via node-pty when the terminal pane is focused; the chat-passthrough listener explicitly returns when `viewMode === 'terminal'` to avoid a double-send. The buddy window has its own React root and its own `window`, so its ESC handler does not compete with the main window's.
- **Chat-to-PTY interrupt is single-byte, so no chunking applies.** `window.claude.session.sendInput(sessionId, '\x1b')` sends 1 byte. Ink's 500ms PASTE_TIMEOUT applies only to writes ≥2 chars — see "PTY Writes" above for why multi-byte writes ending in `\r` require pacing. Don't mistakenly wrap the single ESC in the paste-splitter workaround.
- **Interrupt markers in the transcript end the turn in the reducer.** `transcript-watcher.ts` detects `[Request interrupted by user]` and `[Request interrupted by user for tool use]` in user messages and emits `user-interrupt` events instead of `user-message`. The reducer's `TRANSCRIPT_INTERRUPT` handler attaches `stopReason: 'interrupted'` to the in-flight turn and calls `endTurn(session, 'Turn interrupted')`. Don't "simplify" either by removing the interception — the marker would then render as a user bubble and in-flight tools would stay `running` forever.
```

### Keyboard shortcuts update

In `youcoded/desktop/CLAUDE.md` under "Keyboard Shortcuts", change this row:

```markdown
| **Escape** | Drawer/modal open | Close drawer or modal |
```

to two rows:

```markdown
| **Escape** | Drawer/modal open | Close the topmost drawer/modal |
| **Escape** | Chat view focused, no overlay open | Interrupt the active Claude session (sends `\x1b` to the PTY) |
```

- [ ] **Step 1: Apply both doc edits** (as shown above).

- [ ] **Step 2: Commit**

```bash
git add docs/PITFALLS.md youcoded/desktop/CLAUDE.md
git commit -m "docs(esc): record keyboard routing invariants in PITFALLS and shortcuts"
```

---

## Task 13: Full test sweep

- [ ] **Step 1: Run all desktop tests**

Run:
```bash
cd /c/Users/desti/youcoded-worktrees/esc-chat-passthrough/youcoded/desktop && npm test
```
Expected: all green. If anything fails, triage — do not push through.

- [ ] **Step 2: Typecheck the whole desktop tree**

Run:
```bash
cd /c/Users/desti/youcoded-worktrees/esc-chat-passthrough/youcoded/desktop && npx tsc --noEmit
```
Expected: no errors.

- [ ] **Step 3: Production build**

Run:
```bash
cd /c/Users/desti/youcoded-worktrees/esc-chat-passthrough/youcoded/desktop && npm run build
```
Expected: clean build.

---

## Task 14: Manual verification

The feature is user-facing and protocol-spanning. Type-check + tests don't prove the UI works. Run these by hand **before** merging.

**Setup:**

```bash
cd /c/Users/desti/youcoded-worktrees/esc-chat-passthrough
bash scripts/run-dev.sh
```

This launches the "YouCoded Dev" window on a shifted port so it coexists with the installed app.

### Desktop scenarios

- [ ] **Scenario 1 — basic interrupt.** In the dev window, open a chat session, send a prompt that takes a while (e.g. "count slowly to 50"). While Claude is thinking, press ESC. Expected: thinking indicator clears immediately, the in-progress turn gets a small "Interrupted." footer, and the next prompt works normally.

- [ ] **Scenario 2 — overlay precedence.** Open the Settings drawer (or any popup/drawer). While it's open and Claude is NOT thinking, press ESC. Expected: drawer closes; no interrupt sent. Then while Claude IS thinking and the drawer is open, press ESC. Expected: drawer closes, Claude continues thinking (no double-fire).

- [ ] **Scenario 3 — terminal view.** Switch to terminal view with `Ctrl+\`` (Ctrl-backtick). Press ESC. Expected: xterm's native path forwards ESC and Claude interrupts — same as always. Add a temporary `console.log('chat-passthrough fired')` inside the App.tsx listener before verification and confirm it does NOT log for this scenario. Remove the log before commit.

- [ ] **Scenario 4 — interrupt during tool approval.** Send a prompt that runs a tool requiring approval (e.g. something that triggers the permission dialog — a write). When the "Yes / No / Always allow" prompt appears, press ESC. Expected: the awaiting-approval tool flips to failed with "Turn interrupted" as the error; thinking indicator clears; next prompt works.

### Remote browser

- [ ] **Scenario 5 — remote browser passthrough.** Connect to the dev instance over the remote access URL in a browser. Repeat scenarios 1 and 2. Expected: same behavior — ESC in the browser forwards through WebSocket → `session:input` → PTY; overlays close first.

### Android (if APK available)

- [ ] **Scenario 6 — Android parity.** If time permits, build `./scripts/build-web-ui.sh && ./gradlew assembleDebug` and install on-device. Repeat scenarios 1 and 2. Expected: same behavior — Android routes through the same `session:input` bridge message to `PtyBridge.writeInput`.

---

## Task 15: Merge + cleanup

- [ ] **Step 1: Merge the feature branch**

Per workspace CLAUDE.md, "merge" means merge AND push. Create a PR if Destin's workflow wants review, else merge locally:

Local merge path:
```bash
cd /c/Users/desti/youcoded-dev/youcoded
git fetch origin
git checkout master
git pull origin master
git merge --no-ff feat/esc-chat-passthrough -m "feat: ESC in chat view interrupts Claude session"
git push origin master
```

Or, if Destin prefers PRs:
```bash
cd /c/Users/desti/youcoded-worktrees/esc-chat-passthrough
git push -u origin feat/esc-chat-passthrough
gh pr create --title "ESC in chat view interrupts Claude session" \
  --body "$(cat <<'EOF'
## Summary
- Adds centralized \`useEscClose\` stack; migrates ~12 overlay components to it.
- ESC in chat view forwards \`\\x1b\` to the active session PTY, with LIFO overlay precedence.
- Detects Claude Code interrupt markers in the transcript and ends the turn in the reducer.

## Test plan
- [ ] \`npm test\` green
- [ ] \`tsc --noEmit\` clean
- [ ] Manual: desktop scenarios 1-5 in the plan
- [ ] Manual: remote browser (scenario 6)
- [ ] Manual: Android APK parity (scenario 7, optional)

Spec: docs/superpowers/specs/2026-04-21-esc-chat-passthrough-design.md
Plan: docs/superpowers/plans/2026-04-21-esc-chat-passthrough.md
EOF
)"
```

Ask Destin which path to take if unclear.

- [ ] **Step 2: Verify the commit landed on master**

After merge:
```bash
cd /c/Users/desti/youcoded-dev/youcoded
git branch --contains $(git rev-parse feat/esc-chat-passthrough) | grep master
```
Expected: `master` listed.

- [ ] **Step 3: Remove the worktree and branch**

```bash
cd /c/Users/desti/youcoded-dev/youcoded
git worktree remove /c/Users/desti/youcoded-worktrees/esc-chat-passthrough
git branch -D feat/esc-chat-passthrough
```

(`-D` not `-d` because `--no-ff` merges leave the tip non-ancestral per workspace CLAUDE.md.)

- [ ] **Step 4: Also commit docs in `youcoded-dev`**

The PITFALLS.md edit is in the workspace scaffold (`youcoded-dev` repo), not `youcoded`. If Task 12 edited the workspace copy, commit that repo separately:

```bash
cd /c/Users/desti/youcoded-dev
git status        # should show docs/PITFALLS.md modified
git add docs/PITFALLS.md
git commit -m "docs(pitfalls): keyboard routing invariants for ESC passthrough"
git push origin master
```

Skip this step if PITFALLS.md was edited only inside the `youcoded` repo (the workspace scaffold has its own copy at the root — CLAUDE.md cross-references it).
