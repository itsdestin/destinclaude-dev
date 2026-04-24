# Open Tasks StatusBar Chip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a StatusBar chip + popup that shows all Task* tool activity from the current Claude Code session in one place, replacing the scroll-hunt through per-card TaskCreate/TaskUpdate entries in the chat timeline.

**Architecture:** Pure renderer-side feature built from existing chat reducer state. Extends the existing `task-state.ts` derivation with two new response-string parsers and three new `TaskState` fields, wraps them in a `useSessionTasks(sessionId)` hook, surfaces them through a new `OpenTasksChip` in `StatusBar` and an `OpenTasksPopup` mounted at `App` root. No IPC, no main-process, no Kotlin changes — cross-platform parity preserved by design.

**Tech Stack:** React 18, TypeScript, Vitest (test runner), `@testing-library/react` (component tests), Tailwind (styling), shared `Scrim`/`OverlayPanel` primitives (overlays), localStorage (per-device user state).

**Reference:** `docs/superpowers/specs/2026-04-23-open-tasks-statusbar-chip-design.md`

---

## File Structure

**New files** (all under `youcoded/desktop/src/renderer/`):
- `state/task-state.test.ts` — unit tests for parsers and buildTasksById (node env)
- `hooks/useSessionTasks.ts` — session-scoped task derivation + localStorage overlay
- `hooks/useSessionTasks.test.tsx` — hook tests (jsdom env via pragma)
- `components/OpenTasksChip.tsx` — the status bar chip
- `components/OpenTasksChip.test.tsx` — chip tests (jsdom env via pragma)
- `components/OpenTasksPopup.tsx` — the L2 popup
- `components/OpenTasksPopup.test.tsx` — popup tests (jsdom env via pragma)

**Modified files:**
- `youcoded/desktop/src/renderer/state/task-state.ts` — add parsers, extend `TaskState`, extend `buildTasksById`
- `youcoded/desktop/src/renderer/components/StatusBar.tsx` — mount `OpenTasksChip` after permission chip; plumb `sessionId` + `onOpenOpenTasks`
- `youcoded/desktop/src/renderer/App.tsx` — render `OpenTasksPopup` at root; manage open state; pass sessionId to StatusBar

**New documentation:**
- `youcoded/docs/cc-dependencies.md` — create the file (doesn't exist yet) and add the result-string coupling entry

---

## Task 0: Setup worktree

**Goal:** Isolate this work in a git worktree so concurrent sessions can't overwrite it.

- [ ] **Step 1: Sync both repos to latest master**

```bash
cd /c/Users/desti/youcoded-dev/youcoded && git fetch origin && git pull origin master
cd /c/Users/desti/youcoded-dev && git fetch origin && git pull origin master
```

- [ ] **Step 2: Create the worktree**

Create the worktree on a feature branch alongside the main youcoded checkout.

```bash
cd /c/Users/desti/youcoded-dev/youcoded
git worktree add ../../youcoded-worktrees/open-tasks-chip -b feat/open-tasks-chip
cd /c/Users/desti/youcoded-dev/youcoded-worktrees/open-tasks-chip
```

- [ ] **Step 3: Install dependencies in the worktree's desktop package**

Worktrees share `.git` but NOT `node_modules` — install once.

```bash
cd desktop && npm ci
```

Expected: clean install, no errors.

All subsequent tasks run from `/c/Users/desti/youcoded-dev/youcoded-worktrees/open-tasks-chip` unless noted.

---

## Task 1: `parseTaskCreateResult` parser

**Goal:** Parse Claude Code's `TaskCreate` response string to extract the numeric task ID and subject. This closes the known `task-state.ts` gap where TaskCreate-only tasks were invisible (the ID is only in the response text, not the input).

**Files:**
- Create: `desktop/src/renderer/state/task-state.test.ts`
- Modify: `desktop/src/renderer/state/task-state.ts`

- [ ] **Step 1: Write the failing test**

Create `desktop/src/renderer/state/task-state.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { parseTaskCreateResult } from './task-state';

describe('parseTaskCreateResult', () => {
  it('parses the canonical "Task #N created successfully: <subject>" form', () => {
    const result = parseTaskCreateResult('Task #1 created successfully: Sync youcoded master');
    expect(result).toEqual({ id: '1', subject: 'Sync youcoded master' });
  });

  it('handles multi-digit IDs', () => {
    const result = parseTaskCreateResult('Task #42 created successfully: Do the thing');
    expect(result).toEqual({ id: '42', subject: 'Do the thing' });
  });

  it('preserves colons inside subjects', () => {
    const result = parseTaskCreateResult('Task #3 created successfully: Verified: all tests pass');
    expect(result).toEqual({ id: '3', subject: 'Verified: all tests pass' });
  });

  it('returns null for malformed strings (no "created successfully")', () => {
    expect(parseTaskCreateResult('Task #1 was definitely made: Hello')).toBeNull();
  });

  it('returns null for the empty string', () => {
    expect(parseTaskCreateResult('')).toBeNull();
  });

  it('returns null when the ID is missing', () => {
    expect(parseTaskCreateResult('Task # created successfully: Hello')).toBeNull();
  });

  it('does not throw on non-string-looking input', () => {
    expect(() => parseTaskCreateResult('\n\n\n')).not.toThrow();
    expect(parseTaskCreateResult('\n\n\n')).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd desktop && npx vitest run src/renderer/state/task-state.test.ts
```

Expected: FAIL — `parseTaskCreateResult is not exported from './task-state'` or similar.

- [ ] **Step 3: Implement the parser**

Append to `desktop/src/renderer/state/task-state.ts` (above `buildTasksById`, below the type definitions):

```ts
/**
 * Parse Claude Code's TaskCreate response string to extract task id + subject.
 * Example input: "Task #1 created successfully: Sync youcoded master"
 *
 * The numeric id is NOT in the tool input — only in this response string. If
 * this format ever changes in Claude Code, the Open Tasks chip degrades
 * gracefully: tasks appear only once TaskUpdate/TaskList mention them. See
 * youcoded/docs/cc-dependencies.md for the coupling.
 */
export function parseTaskCreateResult(text: string): { id: string; subject: string } | null {
  if (typeof text !== 'string') return null;
  const match = text.match(/^Task #(\d+) created successfully: (.+)$/);
  if (!match) return null;
  return { id: match[1], subject: match[2] };
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd desktop && npx vitest run src/renderer/state/task-state.test.ts
```

Expected: PASS — all 7 `parseTaskCreateResult` tests pass.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/state/task-state.ts desktop/src/renderer/state/task-state.test.ts
git commit -m "feat(tasks): parse TaskCreate response for task id + subject"
```

---

## Task 2: `parseTaskListResult` parser

**Goal:** Parse the multi-line text block that Claude Code's `TaskList` tool returns into an authoritative per-task snapshot. This is the primary truth source for task state — TaskList reflects the CLI-side source of truth in a single call.

**Files:**
- Modify: `desktop/src/renderer/state/task-state.test.ts`
- Modify: `desktop/src/renderer/state/task-state.ts`

- [ ] **Step 1: Write the failing tests**

Append to `desktop/src/renderer/state/task-state.test.ts`:

```ts
import { parseTaskListResult } from './task-state';

describe('parseTaskListResult', () => {
  it('parses a standard TaskList block with mixed statuses', () => {
    const input = [
      '#1 [completed] Task 1: Create worktree and branch',
      '#2 [in_progress] Task 2: Plugin grouping utility',
      '#3 [pending] Task 3: Wire it into the UI',
    ].join('\n');
    const result = parseTaskListResult(input);
    expect(result).toEqual([
      { id: '1', status: 'completed', subject: 'Create worktree and branch' },
      { id: '2', status: 'in_progress', subject: 'Plugin grouping utility' },
      { id: '3', status: 'pending', subject: 'Wire it into the UI' },
    ]);
  });

  it('tolerates missing "Task N:" prefix (subject only)', () => {
    const input = '#7 [pending] Some subject without the prefix';
    const result = parseTaskListResult(input);
    expect(result).toEqual([
      { id: '7', status: 'pending', subject: 'Some subject without the prefix' },
    ]);
  });

  it('skips blank lines and non-matching lines silently', () => {
    const input = [
      '',
      'Here are the open tasks:',
      '#1 [completed] Task 1: First',
      '',
      'garbage line',
      '#2 [pending] Task 2: Second',
    ].join('\n');
    const result = parseTaskListResult(input);
    expect(result).toEqual([
      { id: '1', status: 'completed', subject: 'First' },
      { id: '2', status: 'pending', subject: 'Second' },
    ]);
  });

  it('returns an empty array for empty input', () => {
    expect(parseTaskListResult('')).toEqual([]);
  });

  it('does not throw on non-string-like garbage', () => {
    expect(() => parseTaskListResult('')).not.toThrow();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd desktop && npx vitest run src/renderer/state/task-state.test.ts
```

Expected: FAIL — `parseTaskListResult is not exported`.

- [ ] **Step 3: Implement the parser**

Append to `desktop/src/renderer/state/task-state.ts` (below `parseTaskCreateResult`):

```ts
/**
 * Parse Claude Code's TaskList response block into a per-task snapshot.
 * Example row: "#1 [completed] Task 1: Create worktree and branch"
 * The "Task N: " prefix is optional.
 *
 * Malformed lines are skipped silently — a format change degrades to "some
 * tasks missing from the snapshot" rather than a render crash.
 */
export function parseTaskListResult(text: string): Array<{ id: string; status: TaskStatus; subject: string }> {
  if (typeof text !== 'string' || text.length === 0) return [];
  const rows: Array<{ id: string; status: TaskStatus; subject: string }> = [];
  const lineRegex = /^#(\d+) \[(pending|in_progress|completed)\] (?:Task \d+: )?(.+)$/;
  for (const line of text.split(/\r?\n/)) {
    const match = line.match(lineRegex);
    if (!match) continue;
    rows.push({ id: match[1], status: match[2] as TaskStatus, subject: match[3] });
  }
  return rows;
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd desktop && npx vitest run src/renderer/state/task-state.test.ts
```

Expected: PASS — all tests (including the `parseTaskCreateResult` block from Task 1) pass.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/state/task-state.ts desktop/src/renderer/state/task-state.test.ts
git commit -m "feat(tasks): parse TaskList response for authoritative snapshots"
```

---

## Task 3: Extend `TaskState` and `buildTasksById`

**Goal:** Wire the parsers into the task derivation. Add `activeForm` and `createdAt` fields. Make TaskCreate-only tasks appear. Make TaskList snapshots overwrite stale status.

**Files:**
- Modify: `desktop/src/renderer/state/task-state.ts`
- Modify: `desktop/src/renderer/state/task-state.test.ts`

- [ ] **Step 1: Write the failing tests**

Append to `desktop/src/renderer/state/task-state.test.ts`:

```ts
import { buildTasksById } from './task-state';
import type { ToolCallState } from '../../shared/types';

function makeCall(overrides: Partial<ToolCallState> & { toolUseId: string; toolName: string }): ToolCallState {
  return {
    status: 'complete',
    input: {},
    ...overrides,
  } as ToolCallState;
}

describe('buildTasksById (extended)', () => {
  it('indexes a TaskCreate-only task via the response string', () => {
    const toolCalls = new Map<string, ToolCallState>();
    toolCalls.set('t1', makeCall({
      toolUseId: 't1',
      toolName: 'TaskCreate',
      input: { subject: 'Do the thing', description: 'Detail', activeForm: 'Doing the thing' },
      response: 'Task #5 created successfully: Do the thing',
    }));

    const tasks = buildTasksById(toolCalls);
    const task = tasks.get('5');
    expect(task).toBeDefined();
    expect(task!.id).toBe('5');
    expect(task!.subject).toBe('Do the thing');
    expect(task!.description).toBe('Detail');
    expect(task!.activeForm).toBe('Doing the thing');
    expect(task!.createdAt).toBe(0);
    expect(task!.status).toBeUndefined();
  });

  it('lets a TaskList snapshot overwrite a stale TaskUpdate status', () => {
    const toolCalls = new Map<string, ToolCallState>();
    toolCalls.set('t1', makeCall({
      toolUseId: 't1',
      toolName: 'TaskCreate',
      input: { subject: 'S', description: 'D' },
      response: 'Task #1 created successfully: S',
    }));
    toolCalls.set('t2', makeCall({
      toolUseId: 't2',
      toolName: 'TaskUpdate',
      input: { taskId: '1', status: 'in_progress' },
    }));
    toolCalls.set('t3', makeCall({
      toolUseId: 't3',
      toolName: 'TaskList',
      input: {},
      response: '#1 [completed] Task 1: S',
    }));

    const task = buildTasksById(toolCalls).get('1');
    expect(task!.status).toBe('completed');
  });

  it('preserves existing TaskUpdate-only indexing (backward compatibility)', () => {
    const toolCalls = new Map<string, ToolCallState>();
    toolCalls.set('t1', makeCall({
      toolUseId: 't1',
      toolName: 'TaskUpdate',
      input: { taskId: '9', status: 'pending' },
    }));
    const task = buildTasksById(toolCalls).get('9');
    expect(task).toBeDefined();
    expect(task!.status).toBe('pending');
  });

  it('sets createdAt from the first toolCalls index the task appears at', () => {
    const toolCalls = new Map<string, ToolCallState>();
    toolCalls.set('a', makeCall({
      toolUseId: 'a', toolName: 'Bash', input: { command: 'ls' },
    }));
    toolCalls.set('b', makeCall({
      toolUseId: 'b', toolName: 'TaskCreate',
      input: { subject: 'X' }, response: 'Task #3 created successfully: X',
    }));
    toolCalls.set('c', makeCall({
      toolUseId: 'c', toolName: 'TaskUpdate',
      input: { taskId: '3', status: 'in_progress' },
    }));

    const task = buildTasksById(toolCalls).get('3');
    expect(task!.createdAt).toBe(1);
  });

  it('tolerates unknown input keys without throwing', () => {
    const toolCalls = new Map<string, ToolCallState>();
    toolCalls.set('t1', makeCall({
      toolUseId: 't1', toolName: 'TaskCreate',
      input: { subject: 'S', owner: 'agent-x', metadata: { foo: 1 } },
      response: 'Task #1 created successfully: S',
    }));
    expect(() => buildTasksById(toolCalls)).not.toThrow();
    expect(buildTasksById(toolCalls).get('1')).toBeDefined();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd desktop && npx vitest run src/renderer/state/task-state.test.ts
```

Expected: FAIL — the `buildTasksById (extended)` block fails because the current implementation doesn't use parsers, doesn't set `activeForm` or `createdAt`, and doesn't handle TaskList snapshots.

- [ ] **Step 3: Extend the `TaskState` interface**

In `desktop/src/renderer/state/task-state.ts`, replace the `TaskState` interface (currently lines 24-32) with:

```ts
export interface TaskState {
  id: string;
  subject?: string;
  description?: string;
  activeForm?: string;           // Present-continuous label shown while in_progress
  priority?: string;
  status?: TaskStatus;
  /** Insertion index in toolCalls where this task first appeared — sort key. */
  createdAt?: number;
  /** Events in chronological order (insertion order of toolCalls Map). */
  events: TaskEvent[];
  /** User-flagged-inactive in the UI. View-model only; not derived from tool calls. */
  markedInactive?: boolean;
}
```

Also update the `TASK_TOOLS` Set to include `'TaskList'`:

```ts
const TASK_TOOLS = new Set(['TaskCreate', 'TaskUpdate', 'TaskGet', 'TaskStop', 'TaskList']);
```

- [ ] **Step 4: Rewrite `buildTasksById`**

Replace the existing `buildTasksById` function body with:

```ts
export function buildTasksById(toolCalls: Map<string, ToolCallState>): Map<string, TaskState> {
  const tasks = new Map<string, TaskState>();

  // Scan in insertion order. `idx` gives us stable createdAt values.
  let idx = 0;
  for (const tool of toolCalls.values()) {
    const i = idx++;
    if (!TASK_TOOLS.has(tool.toolName)) continue;
    const input = tool.input || {};

    // --- TaskList: authoritative snapshot, overwrites current tasks ---
    if (tool.toolName === 'TaskList' && typeof tool.response === 'string') {
      for (const row of parseTaskListResult(tool.response)) {
        const existing = tasks.get(row.id) || { id: row.id, events: [], createdAt: i };
        tasks.set(row.id, {
          ...existing,
          subject: row.subject ?? existing.subject,
          status: row.status,
          events: [...existing.events, {
            toolUseId: tool.toolUseId,
            toolName: tool.toolName,
            status: row.status,
            patch: { taskId: row.id, subject: row.subject, status: row.status },
          }],
        });
      }
      continue;
    }

    // --- TaskCreate: derive id from the response string if the input lacks it ---
    let taskId = input.taskId as string | undefined;
    if (!taskId && tool.toolName === 'TaskCreate' && typeof tool.response === 'string') {
      const parsed = parseTaskCreateResult(tool.response);
      if (parsed) taskId = parsed.id;
    }
    if (!taskId) continue;

    const existing = tasks.get(taskId) || { id: taskId, events: [], createdAt: i };
    const status = input.status as TaskStatus | undefined;

    const event: TaskEvent = {
      toolUseId: tool.toolUseId,
      toolName: tool.toolName,
      ...(status && { status }),
      patch: { ...input },
    };

    tasks.set(taskId, {
      ...existing,
      subject: (input.subject as string | undefined) ?? existing.subject,
      description: (input.description as string | undefined) ?? existing.description,
      activeForm: (input.activeForm as string | undefined) ?? existing.activeForm,
      priority: (input.priority as string | undefined) ?? existing.priority,
      status: status ?? existing.status,
      events: [...existing.events, event],
    });
  }

  return tasks;
}
```

Also remove the comment block at the top of the file about the "KNOWN LIMITATION" (lines 7-12) — that limitation is now fixed. Replace with a one-line comment about the response-string coupling:

```ts
// Derived per-session task state built from Task* tool calls in chat state.
// Scans toolCalls in insertion order. Pure function — memoize on the Map ref
// (preserved across streams per chat-reducer invariants).
//
// TaskCreate returns its numeric id ONLY in the response string (see
// parseTaskCreateResult). TaskList response is the authoritative per-session
// snapshot (see parseTaskListResult). Both are CC-coupled; see
// youcoded/docs/cc-dependencies.md.
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd desktop && npx vitest run src/renderer/state/task-state.test.ts
```

Expected: PASS — all parser + `buildTasksById (extended)` tests pass.

- [ ] **Step 6: Run the full test suite to confirm no regressions**

```bash
cd desktop && npm test -- --run
```

Expected: no existing test fails because of these changes. If `chat-reducer.test.ts` or `chat-serialization.test.ts` had task-related assertions, they should still pass.

- [ ] **Step 7: Commit**

```bash
git add desktop/src/renderer/state/task-state.ts desktop/src/renderer/state/task-state.test.ts
git commit -m "feat(tasks): extend TaskState with activeForm+createdAt; wire parsers into buildTasksById"
```

---

## Task 4: `useSessionTasks` hook with localStorage `markedInactive` overlay

**Goal:** A React hook that reads the current session's `toolCalls`, derives tasks, and overlays the per-session `markedInactive` flags from localStorage. Returns an array of tasks plus counts split by status.

**Files:**
- Create: `desktop/src/renderer/hooks/useSessionTasks.ts`
- Create: `desktop/src/renderer/hooks/useSessionTasks.test.tsx`

- [ ] **Step 1: Write the failing tests**

Create `desktop/src/renderer/hooks/useSessionTasks.test.tsx`:

```tsx
// @vitest-environment jsdom
import React from 'react';
import { describe, it, expect, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { ChatProvider, useChatDispatch } from '../state/chat-context';
import { useSessionTasks, INACTIVE_STORAGE_KEY } from './useSessionTasks';

const SESSION_ID = 'sess-test';

function Providers({ children }: { children: React.ReactNode }) {
  return <ChatProvider>{children}</ChatProvider>;
}

interface SeedCall {
  toolUseId: string;
  toolName: string;
  input: Record<string, unknown>;
  response?: string;
}

/**
 * Injects tool-use + tool-result actions into the chat store for SESSION_ID.
 * Matches the real transcript-watcher flow: TRANSCRIPT_TOOL_USE creates the
 * entry, then TRANSCRIPT_TOOL_RESULT populates `response`.
 */
function useSeedTasks() {
  const dispatch = useChatDispatch();
  return (calls: SeedCall[]) => {
    for (const call of calls) {
      dispatch({
        type: 'TRANSCRIPT_TOOL_USE',
        sessionId: SESSION_ID,
        toolUseId: call.toolUseId,
        toolName: call.toolName,
        toolInput: call.input,
      } as any);
      if (call.response !== undefined) {
        dispatch({
          type: 'TRANSCRIPT_TOOL_RESULT',
          sessionId: SESSION_ID,
          toolUseId: call.toolUseId,
          result: call.response,
          isError: false,
        } as any);
      }
    }
  };
}

describe('useSessionTasks', () => {
  beforeEach(() => {
    localStorage.removeItem(INACTIVE_STORAGE_KEY);
  });

  it('returns empty state for a session with no task tool calls', () => {
    const { result } = renderHook(() => useSessionTasks(SESSION_ID), { wrapper: Providers });
    expect(result.current.tasks).toEqual([]);
    expect(result.current.counts).toEqual({ running: 0, pending: 0, completed: 0, inactive: 0 });
  });

  it('derives tasks live as TaskCreate/TaskUpdate events arrive', () => {
    const { result } = renderHook(() => {
      const seed = useSeedTasks();
      const tasks = useSessionTasks(SESSION_ID);
      return { seed, ...tasks };
    }, { wrapper: Providers });

    act(() => {
      result.current.seed([
        {
          toolUseId: 't1', toolName: 'TaskCreate',
          input: { subject: 'First', description: 'desc' },
          response: 'Task #1 created successfully: First',
        },
        {
          toolUseId: 't2', toolName: 'TaskUpdate',
          input: { taskId: '1', status: 'in_progress' },
        },
      ]);
    });

    expect(result.current.tasks).toHaveLength(1);
    expect(result.current.tasks[0].id).toBe('1');
    expect(result.current.tasks[0].status).toBe('in_progress');
    expect(result.current.counts.running).toBe(1);
  });

  it('marks a task inactive and persists it to localStorage', () => {
    const { result } = renderHook(() => {
      const seed = useSeedTasks();
      return { seed, ...useSessionTasks(SESSION_ID) };
    }, { wrapper: Providers });

    act(() => {
      result.current.seed([{
        toolUseId: 't1', toolName: 'TaskCreate',
        input: { subject: 'X' }, response: 'Task #1 created successfully: X',
      }]);
    });
    act(() => { result.current.markInactive('1'); });

    expect(result.current.tasks[0].markedInactive).toBe(true);
    expect(result.current.counts.inactive).toBe(1);
    const stored = JSON.parse(localStorage.getItem(INACTIVE_STORAGE_KEY)!);
    expect(stored[SESSION_ID]).toContain('1');
  });

  it('unhides a task and updates localStorage', () => {
    localStorage.setItem(INACTIVE_STORAGE_KEY, JSON.stringify({ [SESSION_ID]: ['1'] }));

    const { result } = renderHook(() => {
      const seed = useSeedTasks();
      return { seed, ...useSessionTasks(SESSION_ID) };
    }, { wrapper: Providers });

    act(() => {
      result.current.seed([{
        toolUseId: 't1', toolName: 'TaskCreate',
        input: { subject: 'X' }, response: 'Task #1 created successfully: X',
      }]);
    });
    expect(result.current.tasks[0].markedInactive).toBe(true);

    act(() => { result.current.unhide('1'); });
    expect(result.current.tasks[0].markedInactive).toBeFalsy();
    const stored = JSON.parse(localStorage.getItem(INACTIVE_STORAGE_KEY) ?? '{}');
    expect(stored[SESSION_ID] ?? []).not.toContain('1');
  });

  it('clears markedInactive automatically when the task transitions to completed', () => {
    localStorage.setItem(INACTIVE_STORAGE_KEY, JSON.stringify({ [SESSION_ID]: ['1'] }));

    const { result } = renderHook(() => {
      const seed = useSeedTasks();
      return { seed, ...useSessionTasks(SESSION_ID) };
    }, { wrapper: Providers });

    act(() => {
      result.current.seed([
        {
          toolUseId: 't1', toolName: 'TaskCreate',
          input: { subject: 'X' }, response: 'Task #1 created successfully: X',
        },
        {
          toolUseId: 't2', toolName: 'TaskUpdate',
          input: { taskId: '1', status: 'completed' },
        },
      ]);
    });

    // The auto-clear effect fires inside `act`, so by now the flag is cleared.
    expect(result.current.tasks[0].markedInactive).toBeFalsy();
    const stored = JSON.parse(localStorage.getItem(INACTIVE_STORAGE_KEY) ?? '{}');
    expect(stored[SESSION_ID] ?? []).not.toContain('1');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd desktop && npx vitest run src/renderer/hooks/useSessionTasks.test.tsx
```

Expected: FAIL — `Cannot find module './useSessionTasks'`.

- [ ] **Step 3: Implement the hook**

Create `desktop/src/renderer/hooks/useSessionTasks.ts`:

```ts
import { useCallback, useEffect, useMemo, useState } from 'react';
import { useChatState } from '../state/chat-context';
import { buildTasksById, TaskState, TaskStatus } from '../state/task-state';

export const INACTIVE_STORAGE_KEY = 'youcoded-tasks-inactive-v1';

type InactiveMap = Record<string, string[]>;

interface Counts {
  running: number;
  pending: number;
  completed: number;
  inactive: number;
}

function readInactive(): InactiveMap {
  try {
    const raw = localStorage.getItem(INACTIVE_STORAGE_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

function writeInactive(map: InactiveMap): void {
  try {
    localStorage.setItem(INACTIVE_STORAGE_KEY, JSON.stringify(map));
  } catch {
    // localStorage full / unavailable — silently drop; the flag is a nice-to-have.
  }
}

/**
 * Session-scoped task derivation + local "marked inactive" overlay.
 *
 * Auto-clears the inactive flag when a task transitions to `completed` — the
 * flag is "I'm tired of seeing this stale open task", not "I never want to see
 * this task". Once closed, the concern is resolved.
 */
export function useSessionTasks(sessionId: string) {
  const session = useChatState(sessionId);
  const [inactiveMap, setInactiveMap] = useState<InactiveMap>(() => readInactive());

  const sessionInactive = useMemo(() => new Set(inactiveMap[sessionId] ?? []), [inactiveMap, sessionId]);

  // Derive tasks from the session's toolCalls (memoized on the Map ref).
  const derived = useMemo(() => buildTasksById(session.toolCalls), [session.toolCalls]);

  // Overlay markedInactive and sort by createdAt ascending (undefined sorts last).
  const tasks = useMemo<TaskState[]>(() => {
    const out: TaskState[] = [];
    for (const t of derived.values()) {
      out.push({ ...t, markedInactive: sessionInactive.has(t.id) });
    }
    out.sort((a, b) => (a.createdAt ?? Infinity) - (b.createdAt ?? Infinity));
    return out;
  }, [derived, sessionInactive]);

  // Auto-clear the inactive flag once a task completes. Inactive means "I'm
  // tired of seeing this stale open task" — when Claude closes it naturally,
  // the concern is resolved. Runs as a post-render effect so it doesn't
  // synchronously set state during the memo. The next render sees the updated
  // sessionInactive and the task's markedInactive flips to false.
  useEffect(() => {
    const toClear = tasks
      .filter(t => t.markedInactive && t.status === 'completed')
      .map(t => t.id);
    if (toClear.length === 0) return;
    setInactiveMap(prev => {
      const curr = new Set(prev[sessionId] ?? []);
      let changed = false;
      for (const id of toClear) { if (curr.delete(id)) changed = true; }
      if (!changed) return prev;
      const next = { ...prev };
      if (curr.size === 0) delete next[sessionId];
      else next[sessionId] = [...curr];
      writeInactive(next);
      return next;
    });
  }, [tasks, sessionId]);

  const counts = useMemo<Counts>(() => {
    let running = 0, pending = 0, completed = 0, inactive = 0;
    for (const t of tasks) {
      if (t.markedInactive) { inactive++; continue; }
      if (t.status === 'in_progress') running++;
      else if (t.status === 'completed' || t.status === 'deleted') completed++;
      else pending++; // undefined status counts as pending (just created)
    }
    return { running, pending, completed, inactive };
  }, [tasks]);

  const markInactive = useCallback((taskId: string) => {
    setInactiveMap(prev => {
      const curr = new Set(prev[sessionId] ?? []);
      curr.add(taskId);
      const next = { ...prev, [sessionId]: [...curr] };
      writeInactive(next);
      return next;
    });
  }, [sessionId]);

  const unhide = useCallback((taskId: string) => {
    setInactiveMap(prev => {
      const curr = new Set(prev[sessionId] ?? []);
      curr.delete(taskId);
      const next = { ...prev };
      if (curr.size === 0) delete next[sessionId];
      else next[sessionId] = [...curr];
      writeInactive(next);
      return next;
    });
  }, [sessionId]);

  // Sync localStorage on mount (handles in-session external edits — rare).
  useEffect(() => {
    const onStorage = (e: StorageEvent) => {
      if (e.key === INACTIVE_STORAGE_KEY) setInactiveMap(readInactive());
    };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, []);

  return { tasks, counts, markInactive, unhide };
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd desktop && npx vitest run src/renderer/hooks/useSessionTasks.test.tsx
```

Expected: PASS — all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/hooks/useSessionTasks.ts desktop/src/renderer/hooks/useSessionTasks.test.tsx
git commit -m "feat(tasks): useSessionTasks hook with per-session inactive overlay"
```

---

## Task 5: `OpenTasksChip` component

**Goal:** The status bar chip itself. Renders `TASKS 1◐ 2○` breakdown with per-count coloring. Hidden when 0 open. Fires `onOpen()` on click.

**Files:**
- Create: `desktop/src/renderer/components/OpenTasksChip.tsx`
- Create: `desktop/src/renderer/components/OpenTasksChip.test.tsx`

- [ ] **Step 1: Write the failing tests**

Create `desktop/src/renderer/components/OpenTasksChip.test.tsx`:

```tsx
// @vitest-environment jsdom
import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import OpenTasksChip from './OpenTasksChip';

describe('OpenTasksChip', () => {
  it('renders nothing when running=0 and pending=0', () => {
    const { container } = render(
      <OpenTasksChip running={0} pending={0} onOpen={() => {}} />
    );
    expect(container.firstChild).toBeNull();
  });

  it('renders both counts when both are nonzero', () => {
    render(<OpenTasksChip running={1} pending={2} onOpen={() => {}} />);
    const btn = screen.getByRole('button');
    expect(btn.textContent).toContain('1');
    expect(btn.textContent).toContain('2');
    expect(btn.textContent?.toUpperCase()).toContain('TASKS');
  });

  it('omits zero counts from the label', () => {
    render(<OpenTasksChip running={0} pending={3} onOpen={() => {}} />);
    const btn = screen.getByRole('button');
    expect(btn.textContent).toContain('3');
    expect(btn.textContent).not.toMatch(/\b0\b/);
  });

  it('fires onOpen when clicked', () => {
    const onOpen = vi.fn();
    render(<OpenTasksChip running={1} pending={0} onOpen={onOpen} />);
    fireEvent.click(screen.getByRole('button'));
    expect(onOpen).toHaveBeenCalledTimes(1);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd desktop && npx vitest run src/renderer/components/OpenTasksChip.test.tsx
```

Expected: FAIL — `Cannot find module './OpenTasksChip'`.

- [ ] **Step 3: Implement the component**

Create `desktop/src/renderer/components/OpenTasksChip.tsx`:

```tsx
import React from 'react';

interface Props {
  running: number;   // count of in_progress tasks
  pending: number;   // count of pending tasks
  onOpen: () => void;
}

/**
 * StatusBar chip showing an at-a-glance count of open tasks (running + pending).
 * Hidden entirely when both counts are 0 — matches the announcement-pill pattern.
 * Clicking opens the OpenTasksPopup (parent owns the popup state).
 *
 * Visual: "TASKS 1◐ 2○" — blue running count, amber pending count. Numbers
 * carry the color; the chip surface stays neutral so it doesn't compete with
 * the salmon BYPASS chip next to it.
 */
export default function OpenTasksChip({ running, pending, onOpen }: Props) {
  const total = running + pending;
  if (total === 0) return null;

  const tooltip = `${running} in progress, ${pending} pending — click to view`;

  return (
    <button
      onClick={onOpen}
      className="flex items-center gap-1 px-1.5 py-0.5 rounded-sm border cursor-pointer hover:brightness-125 transition-colors"
      style={{
        backgroundColor: 'var(--inset)',
        color: 'var(--fg-muted)',
        borderColor: 'var(--edge-dim)',
      }}
      title={tooltip}
      aria-label={tooltip}
    >
      <span className="hidden sm:inline">TASKS</span>
      {running > 0 && (
        <span className="inline-flex items-center gap-0.5" style={{ color: '#60a5fa' }}>
          <span>{running}</span>
          <span aria-hidden>◐</span>
        </span>
      )}
      {pending > 0 && (
        <span className="inline-flex items-center gap-0.5" style={{ color: '#fbbf24' }}>
          <span>{pending}</span>
          <span aria-hidden>○</span>
        </span>
      )}
    </button>
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd desktop && npx vitest run src/renderer/components/OpenTasksChip.test.tsx
```

Expected: PASS — all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/OpenTasksChip.tsx desktop/src/renderer/components/OpenTasksChip.test.tsx
git commit -m "feat(tasks): OpenTasksChip component for status bar"
```

---

## Task 6: `OpenTasksPopup` component

**Goal:** The L2 popup opened by the chip. Renders tasks grouped by status (In Progress / Pending / Completed), with a collapsed "Marked Inactive" expander. Mark Inactive / Unhide buttons per row.

**Files:**
- Create: `desktop/src/renderer/components/OpenTasksPopup.tsx`
- Create: `desktop/src/renderer/components/OpenTasksPopup.test.tsx`

- [ ] **Step 1: Write the failing tests**

Create `desktop/src/renderer/components/OpenTasksPopup.test.tsx`:

```tsx
// @vitest-environment jsdom
import React from 'react';
import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import OpenTasksPopup from './OpenTasksPopup';
import type { TaskState } from '../state/task-state';

const noop = () => {};

function task(overrides: Partial<TaskState> & { id: string }): TaskState {
  return { events: [], ...overrides } as TaskState;
}

describe('OpenTasksPopup', () => {
  it('returns null when open=false', () => {
    const { container } = render(
      <OpenTasksPopup
        open={false}
        tasks={[task({ id: '1', subject: 'X', status: 'in_progress' })]}
        onClose={noop}
        onMarkInactive={noop}
        onUnhide={noop}
      />
    );
    expect(container.firstChild).toBeNull();
  });

  it('groups tasks by status with "In Progress", "Pending", "Completed" sections', () => {
    render(
      <OpenTasksPopup
        open={true}
        tasks={[
          task({ id: '1', subject: 'Done thing', status: 'completed', createdAt: 0 }),
          task({ id: '2', subject: 'Running thing', status: 'in_progress', activeForm: 'Running', createdAt: 1 }),
          task({ id: '3', subject: 'Queued thing', status: 'pending', createdAt: 2 }),
        ]}
        onClose={noop}
        onMarkInactive={noop}
        onUnhide={noop}
      />
    );
    const body = screen.getByRole('dialog').textContent!;
    const inProgressIdx = body.toLowerCase().indexOf('in progress');
    const pendingIdx = body.toLowerCase().indexOf('pending');
    const completedIdx = body.toLowerCase().indexOf('completed');
    expect(inProgressIdx).toBeGreaterThanOrEqual(0);
    expect(pendingIdx).toBeGreaterThan(inProgressIdx);
    expect(completedIdx).toBeGreaterThan(pendingIdx);
  });

  it('uses activeForm as the row title when task is in_progress', () => {
    render(
      <OpenTasksPopup
        open={true}
        tasks={[task({ id: '2', subject: 'Default', activeForm: 'Running things…', status: 'in_progress' })]}
        onClose={noop}
        onMarkInactive={noop}
        onUnhide={noop}
      />
    );
    expect(screen.getByText(/Running things…/)).toBeTruthy();
  });

  it('fires onMarkInactive when the Mark Inactive button is clicked', () => {
    const onMarkInactive = vi.fn();
    render(
      <OpenTasksPopup
        open={true}
        tasks={[task({ id: '5', subject: 'Thing', status: 'pending' })]}
        onClose={noop}
        onMarkInactive={onMarkInactive}
        onUnhide={noop}
      />
    );
    const btn = screen.getByRole('button', { name: /mark inactive/i });
    fireEvent.click(btn);
    expect(onMarkInactive).toHaveBeenCalledWith('5');
  });

  it('shows a "Marked Inactive" section at the bottom with an Unhide button per row', () => {
    const onUnhide = vi.fn();
    render(
      <OpenTasksPopup
        open={true}
        tasks={[task({ id: '9', subject: 'Stale', status: 'pending', markedInactive: true })]}
        onClose={noop}
        onMarkInactive={noop}
        onUnhide={onUnhide}
      />
    );
    expect(screen.getByText(/marked inactive/i)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: /unhide/i }));
    expect(onUnhide).toHaveBeenCalledWith('9');
  });

  it('renders "No open tasks" when every task is completed', () => {
    render(
      <OpenTasksPopup
        open={true}
        tasks={[task({ id: '1', subject: 'Done', status: 'completed' })]}
        onClose={noop}
        onMarkInactive={noop}
        onUnhide={noop}
      />
    );
    expect(screen.getByText(/no open tasks/i)).toBeTruthy();
  });

  it('fires onClose when scrim is clicked', () => {
    const onClose = vi.fn();
    render(
      <OpenTasksPopup
        open={true}
        tasks={[task({ id: '1', subject: 'X', status: 'pending' })]}
        onClose={onClose}
        onMarkInactive={noop}
        onUnhide={noop}
      />
    );
    fireEvent.click(screen.getByTestId('open-tasks-scrim'));
    expect(onClose).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd desktop && npx vitest run src/renderer/components/OpenTasksPopup.test.tsx
```

Expected: FAIL — `Cannot find module './OpenTasksPopup'`.

- [ ] **Step 3: Implement the component**

Create `desktop/src/renderer/components/OpenTasksPopup.tsx`:

```tsx
import React, { useState } from 'react';
import { Scrim, OverlayPanel } from './overlays/Overlay';
import type { TaskState } from '../state/task-state';

interface Props {
  open: boolean;
  tasks: TaskState[];                      // pre-sorted by createdAt ascending
  onClose: () => void;
  onMarkInactive: (taskId: string) => void;
  onUnhide: (taskId: string) => void;
}

type Group = 'in_progress' | 'pending' | 'completed' | 'inactive';

function groupOf(t: TaskState): Group {
  if (t.markedInactive) return 'inactive';
  if (t.status === 'in_progress') return 'in_progress';
  if (t.status === 'completed' || t.status === 'deleted') return 'completed';
  return 'pending';
}

function StatusDot({ group }: { group: Group }) {
  if (group === 'in_progress') {
    return <span className="inline-block w-2 h-2 rounded-full" style={{ background: '#60a5fa', boxShadow: '0 0 0 2px rgba(96,165,250,0.25)' }} />;
  }
  if (group === 'completed') {
    return <span className="inline-block w-2 h-2 rounded-full bg-fg-muted" />;
  }
  // pending / inactive
  return <span className="inline-block w-2 h-2 rounded-full border border-fg-muted" />;
}

function Row({ t, group, onMarkInactive, onUnhide }: {
  t: TaskState;
  group: Group;
  onMarkInactive: (id: string) => void;
  onUnhide: (id: string) => void;
}) {
  const title = group === 'in_progress' && t.activeForm ? t.activeForm : (t.subject ?? `#${t.id}`);
  const isDeleted = t.status === 'deleted';
  const showDesc = group !== 'completed' && t.description;

  return (
    <div className={`group flex gap-2 items-start px-2 py-1.5 rounded ${group === 'completed' ? 'opacity-60' : ''}`}>
      <div className="pt-1.5"><StatusDot group={group} /></div>
      <div className="flex-1 min-w-0">
        <div className="flex items-baseline gap-1.5">
          <span className="text-[11px] font-mono text-fg-muted">#{t.id}</span>
          <span className={`text-xs ${group === 'in_progress' ? 'text-blue-400 italic' : 'text-fg'} ${group === 'completed' ? 'line-through' : ''}`}>
            {title}
          </span>
          {isDeleted && <span className="text-[10px] px-1 rounded bg-inset text-fg-muted">deleted</span>}
        </div>
        {showDesc && <div className="text-[11px] text-fg-muted mt-0.5 leading-tight">{t.description}</div>}
      </div>
      {group === 'inactive' ? (
        <button
          className="text-[10px] text-fg-muted hover:text-fg bg-inset hover:bg-well px-2 py-0.5 rounded border border-edge-dim"
          onClick={() => onUnhide(t.id)}
          aria-label={`Unhide task #${t.id}`}
        >
          Unhide
        </button>
      ) : (
        <button
          className="text-[10px] text-fg-muted hover:text-fg bg-inset hover:bg-well px-2 py-0.5 rounded border border-edge-dim opacity-40 group-hover:opacity-100 focus:opacity-100 transition-opacity"
          onClick={() => onMarkInactive(t.id)}
          aria-label={`Mark task #${t.id} inactive`}
        >
          Mark Inactive
        </button>
      )}
    </div>
  );
}

function SectionHeader({ label, count }: { label: string; count: number }) {
  return (
    <div className="text-[10px] uppercase tracking-wider text-fg-muted px-2 pt-2 pb-1 flex justify-between items-baseline">
      <span>{label}</span>
      <span>{count}</span>
    </div>
  );
}

export default function OpenTasksPopup({ open, tasks, onClose, onMarkInactive, onUnhide }: Props) {
  const [completedOpen, setCompletedOpen] = useState(false);
  const [inactiveOpen, setInactiveOpen] = useState(false);

  if (!open) return null;

  const running = tasks.filter(t => groupOf(t) === 'in_progress');
  const pending = tasks.filter(t => groupOf(t) === 'pending');
  const completed = tasks.filter(t => groupOf(t) === 'completed');
  const inactive = tasks.filter(t => groupOf(t) === 'inactive');
  const openCount = running.length + pending.length;

  // Completed section: collapsed by default if >5 entries.
  const completedStartOpen = completed.length > 0 && completed.length <= 5;
  const effectiveCompletedOpen = completedOpen || completedStartOpen;

  return (
    <>
      <Scrim layer={2} onClick={onClose} data-testid="open-tasks-scrim" />
      <OverlayPanel
        layer={2}
        className="fixed right-3 bottom-8 w-[420px] max-w-[calc(100vw-1.5rem)] max-h-[70vh] overflow-auto rounded-md"
        role="dialog"
        aria-label="Open tasks"
      >
        <div className="flex justify-between items-baseline px-3 pt-2 pb-1 border-b border-edge-dim">
          <span className="text-sm font-medium text-fg">Open Tasks</span>
          <span className="text-[10px] uppercase tracking-wider text-fg-muted">{openCount} open</span>
        </div>

        {openCount === 0 && completed.length === 0 && inactive.length === 0 && (
          <div className="px-3 py-4 text-xs text-fg-muted text-center">No open tasks.</div>
        )}

        {openCount === 0 && (completed.length > 0 || inactive.length > 0) && (
          <div className="px-3 py-3 text-xs text-fg-muted italic">No open tasks.</div>
        )}

        {running.length > 0 && (
          <>
            <SectionHeader label="In Progress" count={running.length} />
            {running.map(t => <Row key={t.id} t={t} group="in_progress" onMarkInactive={onMarkInactive} onUnhide={onUnhide} />)}
          </>
        )}

        {pending.length > 0 && (
          <>
            <SectionHeader label="Pending" count={pending.length} />
            {pending.map(t => <Row key={t.id} t={t} group="pending" onMarkInactive={onMarkInactive} onUnhide={onUnhide} />)}
          </>
        )}

        {completed.length > 0 && (
          <>
            <button
              className="w-full text-left text-[10px] uppercase tracking-wider text-fg-muted px-2 pt-2 pb-1 flex justify-between items-baseline hover:text-fg"
              onClick={() => setCompletedOpen(v => !v)}
            >
              <span>Completed</span>
              <span>{completed.length} {effectiveCompletedOpen ? '▾' : '▸'}</span>
            </button>
            {effectiveCompletedOpen && completed.map(t => (
              <Row key={t.id} t={t} group="completed" onMarkInactive={onMarkInactive} onUnhide={onUnhide} />
            ))}
          </>
        )}

        {inactive.length > 0 && (
          <>
            <button
              className="w-full text-left text-[10px] uppercase tracking-wider text-fg-muted px-2 pt-2 pb-1 flex justify-between items-baseline hover:text-fg border-t border-edge-dim mt-1"
              onClick={() => setInactiveOpen(v => !v)}
            >
              <span>Marked Inactive</span>
              <span>{inactive.length} {inactiveOpen ? '▾' : '▸'}</span>
            </button>
            {inactiveOpen && inactive.map(t => (
              <Row key={t.id} t={t} group="inactive" onMarkInactive={onMarkInactive} onUnhide={onUnhide} />
            ))}
          </>
        )}
      </OverlayPanel>
    </>
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd desktop && npx vitest run src/renderer/components/OpenTasksPopup.test.tsx
```

Expected: PASS — all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/OpenTasksPopup.tsx desktop/src/renderer/components/OpenTasksPopup.test.tsx
git commit -m "feat(tasks): OpenTasksPopup with grouped sections + mark-inactive flow"
```

---

## Task 7: Wire chip + popup into `StatusBar` and `App`

**Goal:** Mount `OpenTasksChip` in the StatusBar just after the permission chip; render `OpenTasksPopup` at the App root; thread state and handlers through. No tests — integration verified by the manual smoke test in Task 9.

**Files:**
- Modify: `desktop/src/renderer/components/StatusBar.tsx`
- Modify: `desktop/src/renderer/App.tsx`

- [ ] **Step 1: Extend the StatusBar `Props` interface**

In `desktop/src/renderer/components/StatusBar.tsx`, locate the `Props` interface (starts around line 121). Add three new optional fields:

```ts
  /** Current session id — needed for OpenTasksChip to read the session's task state. */
  sessionId?: string;
  /** Fired when the user clicks the Open Tasks chip. */
  onOpenOpenTasks?: () => void;
```

And in the component signature (around line 590), destructure them:

```ts
export default function StatusBar({
  statusData, onRunSync, onOpenSync, model, onCycleModel,
  permissionMode, onCyclePermission, fast, effort, onOpenModelPicker,
  sessionId, onOpenOpenTasks,
}: Props) {
```

- [ ] **Step 2: Import `OpenTasksChip` and `useSessionTasks`, then mount the chip**

Add imports near the top of `StatusBar.tsx`:

```ts
import OpenTasksChip from './OpenTasksChip';
import { useSessionTasks } from '../hooks/useSessionTasks';
```

Immediately after the permission chip JSX block (currently ends at line 649, just after the closing `</button>`), add:

```tsx
      {/* Open Tasks chip — hidden when 0 open; opens the OpenTasksPopup. */}
      {sessionId && onOpenOpenTasks && <OpenTasksChipMount sessionId={sessionId} onOpen={onOpenOpenTasks} />}
```

Then at the bottom of the file (outside the default export), add a small wrapper that owns the hook call (so the hook only runs when `sessionId` is defined):

```tsx
function OpenTasksChipMount({ sessionId, onOpen }: { sessionId: string; onOpen: () => void }) {
  const { counts } = useSessionTasks(sessionId);
  return <OpenTasksChip running={counts.running} pending={counts.pending} onOpen={onOpen} />;
}
```

- [ ] **Step 3: Wire popup state in `App.tsx`**

In `desktop/src/renderer/App.tsx`, near the existing `const [modelPickerOpen, setModelPickerOpen] = useState(false);` line (around line 150), add:

```ts
  const [openTasksPopupOpen, setOpenTasksPopupOpen] = useState(false);
```

Add an import for the popup near the other component imports (around line 39):

```ts
import OpenTasksPopup from './components/OpenTasksPopup';
import { useSessionTasks } from './hooks/useSessionTasks';
```

- [ ] **Step 4: Pass `sessionId` + `onOpenOpenTasks` to StatusBar**

Locate the existing `<StatusBar ... />` render (around line 1945-1973). After `onOpenModelPicker={() => setModelPickerOpen(true)}` add:

```tsx
                  sessionId={sessionId ?? undefined}
                  onOpenOpenTasks={() => setOpenTasksPopupOpen(true)}
```

(`sessionId` is already in scope at that render site.)

- [ ] **Step 5: Render the popup at the App root**

Near the existing `<ModelPickerPopup open={modelPickerOpen} ... />` render (around line 2130), add the OpenTasksPopup. Because the popup needs the active session's task data + mutation callbacks, mount a small inline wrapper that calls `useSessionTasks(sessionId)` and passes its outputs down:

```tsx
      {sessionId && (
        <OpenTasksPopupMount
          sessionId={sessionId}
          open={openTasksPopupOpen}
          onClose={() => setOpenTasksPopupOpen(false)}
        />
      )}
```

Then near the bottom of `App.tsx` (outside the App component body), add the wrapper:

```tsx
function OpenTasksPopupMount({ sessionId, open, onClose }: { sessionId: string; open: boolean; onClose: () => void }) {
  const { tasks, markInactive, unhide } = useSessionTasks(sessionId);
  return (
    <OpenTasksPopup
      open={open}
      tasks={tasks}
      onClose={onClose}
      onMarkInactive={markInactive}
      onUnhide={unhide}
    />
  );
}
```

- [ ] **Step 6: Wire ESC to close the popup**

The existing `useEscClose` stack handles overlay stacking. Confirm ModelPickerPopup's pattern — if it registers via `useEscClose`, do the same inside `OpenTasksPopup`. If it relies on the App-root ESC bubble handler, no change needed. Search for "useEscClose" in the ModelPickerPopup source and mirror whatever pattern is there:

```bash
grep -n "useEscClose\|Escape" desktop/src/renderer/components/ModelPickerPopup.tsx | head
```

If `useEscClose` is used, add equivalent wiring inside `OpenTasksPopup` (open gate + close callback). If not, skip — the App-level ESC handler + scrim click already cover it.

- [ ] **Step 7: Typecheck and run the full test suite**

```bash
cd desktop && npm run build
```

Expected: build succeeds with no TypeScript errors.

```bash
cd desktop && npm test -- --run
```

Expected: every test passes.

- [ ] **Step 8: Commit**

```bash
git add desktop/src/renderer/components/StatusBar.tsx desktop/src/renderer/App.tsx
git commit -m "feat(tasks): mount OpenTasksChip in StatusBar and popup at App root"
```

---

## Task 8: Create `cc-dependencies.md` and add the Task* coupling entry

**Goal:** Document the Claude Code result-string coupling so the `review-cc-changes` release agent can surface it if CC's wording changes. The file doesn't exist yet — create it with a scaffold and this first entry.

**Files:**
- Create: `youcoded/docs/cc-dependencies.md`

- [ ] **Step 1: Create the file**

Create `youcoded/docs/cc-dependencies.md`:

```markdown
# Claude Code Dependencies

This document catalogs every place YouCoded depends on a specific Claude Code (CC) behavior, file format, text output, or CLI flag. The `review-cc-changes` release agent uses this list to map upstream CC CHANGELOG entries to YouCoded code that could break.

Coupling categories: (a) parsing CC output (transcript JSONL, statusline JSON, tool result strings), (b) consuming a CC file (settings.json, installed_plugins.json), (c) depending on CLI behavior (flags, exit codes, prompt text), or (d) matching a CC text pattern (spinner glyphs, prompt markers).

---

## Task tool result strings

**Files:** `desktop/src/renderer/state/task-state.ts`
**Functions:** `parseTaskCreateResult`, `parseTaskListResult`
**Used by:** `OpenTasksChip` / `OpenTasksPopup` in the status bar

Parses two specific wordings CC emits from its Task* tool family:

- `TaskCreate` response: `Task #<N> created successfully: <subject>` — the numeric id is ONLY in this response, not in the tool input. Without this parse, a freshly created task stays invisible until a subsequent `TaskUpdate` or `TaskList` mentions it.
- `TaskList` response: newline-separated rows matching `^#<N> \[(pending|in_progress|completed)\] (?:Task \d+: )?<subject>$`. This is the authoritative per-session snapshot.

**If CC changes these strings:** tasks still render once `TaskUpdate` activity references them, so the feature degrades gracefully rather than crashing. Update the regexes and bump the `task-state.test.ts` fixtures.

**Verified against:** CC versions that emit these wordings as of 2026-04-24 (checked across 30 transcripts in `~/.claude/projects/`).
```

- [ ] **Step 2: Commit**

```bash
git add docs/cc-dependencies.md
git commit -m "docs(cc-deps): create cc-dependencies.md with Task* result-string entry"
```

---

## Task 9: Manual cross-platform smoke test

**Goal:** Verify the chip + popup work end-to-end on desktop; confirm the Android build picks up the shared React bundle. No code changes here — just verification with recorded observations.

- [ ] **Step 1: Run the desktop dev instance**

From the worktree root (`youcoded-worktrees/open-tasks-chip`):

```bash
bash ../../scripts/run-dev.sh
```

The YouCoded Dev window opens on shifted ports (Vite 5223, remote 9950).

- [ ] **Step 2: In the dev window, drive Claude to exercise the feature**

Start or resume a session and run:

```
/tell Claude to create 3 tasks using TaskCreate, then mark one in_progress, leave one pending, and mark one completed
```

Or more directly, prompt Claude:

```
Please use TaskCreate to add three tasks: "Explore", "Implement", "Verify". Then use TaskUpdate to mark the first in_progress.
```

Verify:
- [ ] The chip appears in the status bar after the first TaskCreate response lands.
- [ ] The chip reads `TASKS 1◐ 2○` (or the appropriate counts).
- [ ] Clicking the chip opens the popup.
- [ ] The popup shows the three tasks grouped into "In Progress" and "Pending" sections.
- [ ] Ask Claude to run `TaskList` — confirm any status drift in the popup gets reconciled from the TaskList snapshot.
- [ ] Hover a row — the "Mark Inactive" button becomes fully visible.
- [ ] Click "Mark Inactive" — the task moves to the "Marked Inactive" expander; the chip count drops.
- [ ] Refresh the window (Ctrl+R) — the inactive state persists (localStorage).
- [ ] Ask Claude to complete the inactive task — it moves to Completed and the inactive flag clears automatically.
- [ ] Click the chip again with 0 open tasks — chip should be hidden entirely.
- [ ] Switch to another session — the chip shows that session's tasks (or is hidden if none).

- [ ] **Step 3: Build the Android web bundle and APK**

```bash
cd /c/Users/desti/youcoded-dev/youcoded-worktrees/open-tasks-chip
bash scripts/build-web-ui.sh
./gradlew assembleDebug
```

Expected: both succeed. The APK now contains the updated React bundle with the Open Tasks feature.

- [ ] **Step 4: Install the APK on the Android device and smoke test**

Install the debug APK and repeat Step 2's checks on Android. The WebView loads the same React bundle, so behavior should be identical. Specifically verify:
- [ ] The chip is visible and tappable in the StatusBar.
- [ ] Tapping opens the popup (touch instead of click).
- [ ] The "Mark Inactive" button is visible at reduced opacity (no hover on touch) and remains tappable.

If Android doesn't reproduce desktop behavior exactly, capture the specific difference and add a follow-up task — don't paper over it.

- [ ] **Step 5: Record the verification in the worktree**

```bash
git commit --allow-empty -m "chore: manual smoke test verified desktop+android open tasks chip"
```

(Empty commit for traceability; documents the verification step on the branch.)

---

## Task 10: Finish the development branch

**Goal:** Hand off to the `finishing-a-development-branch` skill for merge decision. Do NOT merge unilaterally — that skill walks through the options.

- [ ] **Step 1: Confirm all tests pass and the build is clean**

```bash
cd desktop && npm ci && npm test -- --run && npm run build
```

Expected: all green.

- [ ] **Step 2: Push the feature branch**

```bash
git push origin feat/open-tasks-chip
```

- [ ] **Step 3: Invoke the finishing skill**

At this point, invoke `superpowers:finishing-a-development-branch` to decide whether to merge to master, open a PR, or do more work first. That skill owns the merge flow.

---

## Self-review notes (written after drafting)

- **Spec coverage:** every `## Design` subsection from the spec maps to a task (data layer → Tasks 1-3; `useSessionTasks` → Task 4; chip → Task 5; popup → Task 6; wiring → Task 7; cc-dependencies → Task 8). Success criteria 1-7 are directly verified by Task 9's checklist.
- **Placeholder scan:** no TBD / TODO / vague steps. All code shown inline.
- **Type consistency:** `counts` uses `{ running, pending, completed, inactive }` in both `useSessionTasks` and test fixtures. `TaskState.markedInactive` is boolean-optional across all touchpoints. `TaskStatus` pulls from `task-state.ts` consistently.
- **One concern noted:** Task 7 Step 6 has a conditional ("if ModelPickerPopup uses useEscClose, mirror it"). Acceptable because the behavior is "match existing pattern" — a judgment call for the implementer that doesn't change the feature surface.
