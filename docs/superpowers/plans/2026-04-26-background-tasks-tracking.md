# Background Tasks Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track Claude Code background tasks (backgrounded `Bash` + `Monitor`) across turn boundaries — surface a per-active-session StatusBar chip + popup, auto-complete the originating tool card at launch, and add a `'background-active'` AttentionState that keeps the session dot green and the in-chat indicator alive while tasks are still running.

**Architecture:** Three new transcript event types (`background-task-started`, `background-task-completed`, `background-task-event`) feed a session-lifetime `backgroundTasks: Map<taskId, BackgroundTask>` on chat state. `endTurn()` writes `'background-active'` to `attentionState` when the Map is non-empty; the classifier skips ticks under that state; ChatView's ThinkingIndicator widens its render gate; the StatusBar chip reads the active session's Map via the existing `attentionMap`-style IPC plumbing. Android parity mirrors the new event types in Kotlin.

**Tech Stack:** TypeScript, React 18, Vitest, Electron 33+, Kotlin (Android parity).

**Spec:** `docs/superpowers/specs/2026-04-26-background-tasks-tracking-design.md`
**Investigation:** `docs/superpowers/investigations/2026-04-26-background-task-tracking.md`

**Worktree:** Create one before starting:

```bash
cd ~/youcoded-dev/youcoded
git worktree add ../youcoded-worktrees/background-tasks -b feat/background-tasks
cd ../youcoded-worktrees/background-tasks
npm --prefix desktop ci
```

All paths in tasks below are relative to the worktree root (`youcoded/`).

---

## File structure

| File | Action | Responsibility |
|------|--------|----------------|
| `desktop/src/shared/types.ts` | Modify | Add three transcript event type strings; extend `AttentionState` union with `'background-active'`; extend `TranscriptEvent.data` with optional fields used by the new shapes (`taskId`, `kind`, `description`, `command`, `timeoutMs`, `persistent`, `exitCode`, `status`, `summary`) |
| `desktop/src/renderer/state/chat-types.ts` | Modify | Add `BackgroundTask` interface; add `backgroundTasks: Map<string, BackgroundTask>` to `SessionChatState`; initialize in `createSessionChatState()`; add three new `ChatAction` types |
| `desktop/src/renderer/state/chat-reducer.ts` | Modify | Three new handlers; modify `endTurn()` to set `'background-active'` when Map non-empty; modify `SESSION_PROCESS_EXITED` to clear Map; modify `TRANSCRIPT_TOOL_USE` (or add a chained step) so backgrounded tools auto-complete on the matching `tool-result` |
| `desktop/tests/chat-reducer.test.ts` | Modify | Add reducer tests for the three new actions and the modified flows |
| `desktop/src/main/transcript-watcher.ts` | Modify | Detect `toolUseResult.backgroundTaskId`/`taskId` to emit `background-task-started`; relax non-message-line filter for `queue-operation` (with `<task-notification>`) and `attachment` (with `queued_command` + `<event>`) shapes |
| `desktop/src/main/transcript-watcher.test.ts` | Modify | Add unit tests for the three new emit paths |
| `desktop/src/renderer/state/hook-dispatcher.ts` OR `desktop/src/renderer/App.tsx` | Modify | Wire the three new transcript event types into `TRANSCRIPT_BACKGROUND_TASK_*` action dispatch (location is wherever the existing `transcript:event` listener turns events into actions) |
| `desktop/src/renderer/hooks/useAttentionClassifier.ts` | Modify | AND `attentionState !== 'background-active'` into the `active` gate (line ~74) |
| `desktop/src/renderer/components/ThinkingIndicator.tsx` | Modify | Accept optional `variant?: 'thinking' \| 'background'` prop with copy `'Background tasks running'` for the new variant |
| `desktop/src/renderer/components/ChatView.tsx` | Modify | Widen render gate so `ThinkingIndicator` also renders when `attentionState === 'background-active'`; pass `variant="background"` in that case |
| `desktop/src/renderer/components/ToolCard.tsx` | Modify | Update `friendlyToolDisplay` for backgrounded `Bash` and `Monitor` to return label "Launched a background task" + description as detail |
| `desktop/src/renderer/components/StatusBar.tsx` | Modify | Add `'background-tasks'` to `WidgetId`, add `WidgetDef` in Tasks category, add `backgroundTasksMap` field to `StatusData`, render the chip |
| `desktop/src/renderer/components/BackgroundTasksChip.tsx` | Create | The chip + popup component (renders the active session's tasks using `<OverlayPanel layer={2}>`) |
| `desktop/src/renderer/hooks/useRemoteBackgroundTasksSync.ts` | Create | Mirror of `useRemoteAttentionSync.ts` — diffs the active session's Map and fires `remote:background-tasks-changed` IPC on change |
| `desktop/src/main/preload.ts` | Modify | Expose `window.claude.fireRemoteBackgroundTasksChanged` mirroring `fireRemoteAttentionChanged` |
| `desktop/src/renderer/remote-shim.ts` | Modify | Mirror the same surface for remote browser clients |
| `desktop/src/main/ipc-handlers.ts` | Modify | Declare `lastBackgroundTasksBySession`, register `remote:background-tasks-changed` listener, fold `backgroundTasksMap` into `buildStatusData()` |
| `desktop/src/renderer/App.tsx` | Modify | Mount `useRemoteBackgroundTasksSync()` alongside the existing `useRemoteAttentionSync()` |
| `app/src/main/kotlin/com/youcoded/app/parser/TranscriptEvent.kt` | Modify | Add `BackgroundTaskStarted`, `BackgroundTaskCompleted`, `BackgroundTaskEvent` data classes |
| `app/src/main/kotlin/com/youcoded/app/parser/TranscriptWatcher.kt` | Modify | Mirror the new emit paths from desktop |
| `app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` | Modify | Include backgroundTasks in `status:data` payload (parallel to `attentionMap`) |

---

## Type definitions reused across tasks

The `BackgroundTask` shape used in chat state and in the StatusBar feed:

```typescript
export interface BackgroundTask {
  taskId: string;          // e.g. "b6lazmyhu"
  toolUseId: string;       // e.g. "toolu_01..."
  kind: 'bash' | 'monitor';
  description: string;     // human-readable label
  command: string;         // raw bash command or monitor pipeline
  startedAt: number;       // ms epoch
  timeoutMs?: number;      // monitor-only
  persistent?: boolean;    // monitor-only
  monitorEventCount?: number; // incremented by TRANSCRIPT_BACKGROUND_TASK_EVENT
}
```

The summary shape sent over IPC to remote clients (subset — drops `command` to keep the payload lean):

```typescript
export interface BackgroundTaskSummary {
  taskId: string;
  kind: 'bash' | 'monitor';
  description: string;
  startedAt: number;
  timeoutMs?: number;
  monitorEventCount?: number;
}
```

The three new ChatAction types:

```typescript
| {
    type: 'TRANSCRIPT_BACKGROUND_TASK_STARTED';
    sessionId: string;
    uuid: string;
    timestamp: number;
    taskId: string;
    toolUseId: string;
    kind: 'bash' | 'monitor';
    description: string;
    command: string;
    timeoutMs?: number;
    persistent?: boolean;
  }
| {
    type: 'TRANSCRIPT_BACKGROUND_TASK_COMPLETED';
    sessionId: string;
    taskId: string;
  }
| {
    type: 'TRANSCRIPT_BACKGROUND_TASK_EVENT';
    sessionId: string;
    taskId: string;
  }
```

---

### Task 1: Type foundation — shared/types.ts

**Files:**
- Modify: `desktop/src/shared/types.ts:53-72` (TranscriptEventType union)
- Modify: `desktop/src/shared/types.ts:74-119` (TranscriptEvent.data shape)
- Modify: `desktop/src/shared/types.ts:451-454` (AttentionState union)

- [ ] **Step 1: Extend `TranscriptEventType` union**

In `desktop/src/shared/types.ts`, replace lines 53-72 with:

```typescript
export type TranscriptEventType =
  | 'user-message'
  | 'assistant-text'
  | 'tool-use'
  | 'tool-result'
  | 'thinking'
  | 'assistant-thinking'
  | 'turn-complete'
  | 'compact-summary'
  | 'user-interrupt'
  | 'background-task-started'
  | 'background-task-completed'
  | 'background-task-event';
```

- [ ] **Step 2: Extend `TranscriptEvent.data` with the new optional fields**

Locate the `TranscriptEvent` interface (lines 74-119). Add the following optional fields to the `data: { ... }` block (preserve all existing fields):

```typescript
    // Background task fields (one or more present depending on event type):
    taskId?: string;             // started + completed + event
    kind?: 'bash' | 'monitor' | 'plain' | 'tool-use';  // started — extends existing 'kind' union; no name collision
    description?: string;        // started
    command?: string;            // started
    timeoutMs?: number;          // started (monitor only)
    persistent?: boolean;        // started (monitor only)
    exitCode?: number;           // completed (when present in <summary>)
    status?: string;             // completed (raw <status> XML element value)
    summary?: string;            // completed (raw <summary> XML element value)
```

Note: the existing `kind?: 'plain' | 'tool-use'` field used by `user-interrupt` events stays — we extend its union to include `'bash' | 'monitor'`. Same field name, broader union; no collision.

- [ ] **Step 3: Extend `AttentionState` union**

Replace lines 451-454 with:

```typescript
export type AttentionState =
  | 'ok'                  // Default — indicator renders if isThinking
  | 'stuck'               // Spinner glyph stale ≥ 30s OR no spinner ≥ 20s while thinking
  | 'session-died'        // Process exited mid-turn
  | 'background-active';  // Turn ended but ≥1 background task still running for this session
```

- [ ] **Step 4: Verify it type-checks**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS (no new errors). Existing files use `AttentionState` as a discriminated union; adding a member is non-breaking until exhaustive `switch` statements are widened in later tasks.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/shared/types.ts
git commit -m "feat(background-tasks): add transcript event types and AttentionState value"
```

---

### Task 2: chat-types.ts — BackgroundTask interface, state field, action types

**Files:**
- Modify: `desktop/src/renderer/state/chat-types.ts:105-142` (SessionChatState)
- Modify: `desktop/src/renderer/state/chat-types.ts:144-160` (createSessionChatState)
- Modify: `desktop/src/renderer/state/chat-types.ts:162-355` (ChatAction union)

- [ ] **Step 1: Add `BackgroundTask` and `BackgroundTaskSummary` interfaces**

Above the `SessionChatState` interface (around line 100), add:

```typescript
export interface BackgroundTask {
  taskId: string;
  toolUseId: string;
  kind: 'bash' | 'monitor';
  description: string;
  command: string;
  startedAt: number;
  timeoutMs?: number;
  persistent?: boolean;
  monitorEventCount?: number;
}

/** Smaller projection of BackgroundTask used in the StatusBar IPC feed.
 *  Drops `command` (potentially long; the chip popup doesn't display it). */
export interface BackgroundTaskSummary {
  taskId: string;
  kind: 'bash' | 'monitor';
  description: string;
  startedAt: number;
  timeoutMs?: number;
  monitorEventCount?: number;
}
```

- [ ] **Step 2: Add `backgroundTasks` field to `SessionChatState`**

Inside the `SessionChatState` interface, add (anywhere — convention: after `activeTurnToolIds`, before `attentionState`):

```typescript
  /**
   * Background tasks (backgrounded Bash, Monitor) that have started but not
   * yet completed. Session-lifetime — NOT cleared by endTurn(). Cleared only
   * by SESSION_PROCESS_EXITED. Drives the StatusBar background-tasks chip and
   * the 'background-active' AttentionState that keeps the session dot green
   * past turn-complete.
   */
  backgroundTasks: Map<string, BackgroundTask>;
```

- [ ] **Step 3: Initialize the field in `createSessionChatState`**

Inside the returned object, add `backgroundTasks: new Map(),` (anywhere; convention: alongside the other Maps).

- [ ] **Step 4: Add three new ChatAction members**

Inside the `ChatAction` union (lines 162-355), append the three new variants from the "Type definitions reused across tasks" section above (TRANSCRIPT_BACKGROUND_TASK_STARTED / _COMPLETED / _EVENT). Place them near the other `TRANSCRIPT_*` actions for grouping.

- [ ] **Step 5: Verify type-checking**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS. The reducer's `switch` statement is non-exhaustive (it has a `default`), so the new actions don't cause unhandled-case errors yet.

- [ ] **Step 6: Commit**

```bash
git add desktop/src/renderer/state/chat-types.ts
git commit -m "feat(background-tasks): add chat-state types, action types, Map field"
```

---

### Task 3: Reducer — `TRANSCRIPT_BACKGROUND_TASK_STARTED` handler (TDD)

**Files:**
- Test: `desktop/tests/chat-reducer.test.ts`
- Modify: `desktop/src/renderer/state/chat-reducer.ts`

- [ ] **Step 1: Write the failing test**

Append to `desktop/tests/chat-reducer.test.ts`:

```typescript
describe('TRANSCRIPT_BACKGROUND_TASK_STARTED', () => {
  let state: ChatState;

  beforeEach(() => {
    state = initState();
  });

  it('adds an entry to backgroundTasks Map', () => {
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_STARTED',
      sessionId: SESSION,
      uuid: 'u-1',
      timestamp: 1000,
      taskId: 'b6lazmyhu',
      toolUseId: 'toolu_001',
      kind: 'bash',
      description: 'Start dev server',
      command: 'npm run dev 2>&1 &',
    });

    const session = state.get(SESSION)!;
    expect(session.backgroundTasks.size).toBe(1);
    const task = session.backgroundTasks.get('b6lazmyhu');
    expect(task).toMatchObject({
      taskId: 'b6lazmyhu',
      toolUseId: 'toolu_001',
      kind: 'bash',
      description: 'Start dev server',
      command: 'npm run dev 2>&1 &',
      startedAt: 1000,
    });
  });

  it('preserves monitor-specific fields when kind is monitor', () => {
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_STARTED',
      sessionId: SESSION,
      uuid: 'u-2',
      timestamp: 2000,
      taskId: 'b8hrhggum',
      toolUseId: 'toolu_002',
      kind: 'monitor',
      description: 'dev server errors',
      command: 'tail -F log',
      timeoutMs: 120000,
      persistent: false,
    });

    const task = state.get(SESSION)!.backgroundTasks.get('b8hrhggum')!;
    expect(task.kind).toBe('monitor');
    expect(task.timeoutMs).toBe(120000);
    expect(task.persistent).toBe(false);
    expect(task.monitorEventCount).toBeUndefined();
  });

  it('flips the originating tool card status to completed', () => {
    // Set up a running tool first
    state = dispatch(state, {
      type: 'TRANSCRIPT_TOOL_USE',
      sessionId: SESSION,
      uuid: 'u-tool',
      toolUseId: 'toolu_001',
      toolName: 'Bash',
      toolInput: { command: 'npm run dev 2>&1 &', run_in_background: true },
    });
    expect(state.get(SESSION)!.toolCalls.get('toolu_001')!.status).toBe('running');

    // Background task starts
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_STARTED',
      sessionId: SESSION,
      uuid: 'u-1',
      timestamp: 1000,
      taskId: 'b6lazmyhu',
      toolUseId: 'toolu_001',
      kind: 'bash',
      description: 'Start dev server',
      command: 'npm run dev 2>&1 &',
    });

    // Originating tool card is now completed (the launch IS the completion).
    expect(state.get(SESSION)!.toolCalls.get('toolu_001')!.status).toBe('completed');
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'TRANSCRIPT_BACKGROUND_TASK_STARTED'`
Expected: FAIL — handler not implemented; `backgroundTasks.size` is 0 (or the field is undefined).

- [ ] **Step 3: Implement the handler**

In `desktop/src/renderer/state/chat-reducer.ts`, inside the main `switch (action.type)` block, add a new case:

```typescript
case 'TRANSCRIPT_BACKGROUND_TASK_STARTED': {
  const session = next.get(action.sessionId);
  if (!session) return state;

  // Clone the Map so React refs change.
  const backgroundTasks = new Map(session.backgroundTasks);
  backgroundTasks.set(action.taskId, {
    taskId: action.taskId,
    toolUseId: action.toolUseId,
    kind: action.kind,
    description: action.description,
    command: action.command,
    startedAt: action.timestamp,
    ...(action.timeoutMs !== undefined ? { timeoutMs: action.timeoutMs } : {}),
    ...(action.persistent !== undefined ? { persistent: action.persistent } : {}),
  });

  // Auto-complete the originating tool card. The launch IS the completion
  // for chat purposes — the chip is the source of truth for ongoing state.
  let toolCalls = session.toolCalls;
  const originating = toolCalls.get(action.toolUseId);
  if (originating && originating.status !== 'completed') {
    toolCalls = new Map(toolCalls);
    toolCalls.set(action.toolUseId, { ...originating, status: 'completed' });
  }

  next.set(action.sessionId, { ...session, backgroundTasks, toolCalls });
  return next;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'TRANSCRIPT_BACKGROUND_TASK_STARTED'`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/state/chat-reducer.ts desktop/tests/chat-reducer.test.ts
git commit -m "feat(background-tasks): reducer handler for STARTED + auto-complete tool card"
```

---

### Task 4: Reducer — `TRANSCRIPT_BACKGROUND_TASK_COMPLETED` handler (TDD)

**Files:**
- Test: `desktop/tests/chat-reducer.test.ts`
- Modify: `desktop/src/renderer/state/chat-reducer.ts`

- [ ] **Step 1: Write the failing test**

Append to `desktop/tests/chat-reducer.test.ts`:

```typescript
describe('TRANSCRIPT_BACKGROUND_TASK_COMPLETED', () => {
  let state: ChatState;

  function startTask(s: ChatState, taskId: string, toolUseId: string): ChatState {
    return dispatch(s, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_STARTED',
      sessionId: SESSION,
      uuid: 'u-' + taskId,
      timestamp: 1000,
      taskId,
      toolUseId,
      kind: 'bash',
      description: 'desc',
      command: 'cmd',
    });
  }

  beforeEach(() => {
    state = initState();
  });

  it('removes the entry from backgroundTasks Map', () => {
    state = startTask(state, 'b1', 'toolu_001');
    expect(state.get(SESSION)!.backgroundTasks.size).toBe(1);

    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_COMPLETED',
      sessionId: SESSION,
      taskId: 'b1',
    });

    expect(state.get(SESSION)!.backgroundTasks.size).toBe(0);
  });

  it('is a no-op if the taskId is unknown (race against transcript replay)', () => {
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_COMPLETED',
      sessionId: SESSION,
      taskId: 'never-started',
    });
    expect(state.get(SESSION)!.backgroundTasks.size).toBe(0);
  });

  it('transitions attentionState back to ok when count hits zero', () => {
    // Start two tasks, end the turn → attentionState becomes 'background-active'.
    state = startTask(state, 'b1', 'toolu_001');
    state = startTask(state, 'b2', 'toolu_002');
    state = dispatch(state, {
      type: 'TRANSCRIPT_TURN_COMPLETE',
      sessionId: SESSION,
      uuid: 'u-tc',
      timestamp: 2000,
      stopReason: 'end_turn',
      model: 'claude-opus-4-7',
      anthropicRequestId: null,
      usage: null,
    });
    expect(state.get(SESSION)!.attentionState).toBe('background-active');

    // First completion — still one task left, state stays.
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_COMPLETED',
      sessionId: SESSION,
      taskId: 'b1',
    });
    expect(state.get(SESSION)!.attentionState).toBe('background-active');

    // Second completion — Map empty → state recovers to 'ok'.
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_COMPLETED',
      sessionId: SESSION,
      taskId: 'b2',
    });
    expect(state.get(SESSION)!.attentionState).toBe('ok');
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'TRANSCRIPT_BACKGROUND_TASK_COMPLETED'`
Expected: FAIL on first two tests (Map.size still 1 / undefined). Third test will fail later in the chain when endTurn() doesn't yet emit `'background-active'` — fine for now, it'll pass after Task 6.

- [ ] **Step 3: Implement the handler**

In `chat-reducer.ts`, add the case:

```typescript
case 'TRANSCRIPT_BACKGROUND_TASK_COMPLETED': {
  const session = next.get(action.sessionId);
  if (!session) return state;
  if (!session.backgroundTasks.has(action.taskId)) return state;

  const backgroundTasks = new Map(session.backgroundTasks);
  backgroundTasks.delete(action.taskId);

  // Recovery: if we were in 'background-active' and the Map is now empty,
  // transition back to 'ok'. Anything else (stuck, session-died) takes
  // precedence and stays.
  const nextAttention =
    backgroundTasks.size === 0 && session.attentionState === 'background-active'
      ? 'ok'
      : session.attentionState;

  next.set(action.sessionId, {
    ...session,
    backgroundTasks,
    attentionState: nextAttention,
  });
  return next;
}
```

- [ ] **Step 4: Run the first two tests to verify they pass**

Run: `cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'TRANSCRIPT_BACKGROUND_TASK_COMPLETED' -t 'removes' -t 'no-op'`
Expected: PASS for "removes the entry" and "is a no-op". The "transitions attentionState" test will pass after Task 6.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/state/chat-reducer.ts desktop/tests/chat-reducer.test.ts
git commit -m "feat(background-tasks): reducer handler for COMPLETED with attention recovery"
```

---

### Task 5: Reducer — `TRANSCRIPT_BACKGROUND_TASK_EVENT` handler (TDD)

**Files:**
- Test: `desktop/tests/chat-reducer.test.ts`
- Modify: `desktop/src/renderer/state/chat-reducer.ts`

- [ ] **Step 1: Write the failing test**

Append to `desktop/tests/chat-reducer.test.ts`:

```typescript
describe('TRANSCRIPT_BACKGROUND_TASK_EVENT', () => {
  let state: ChatState;

  beforeEach(() => {
    state = initState();
    // Start a Monitor task.
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_STARTED',
      sessionId: SESSION,
      uuid: 'u-mon',
      timestamp: 1000,
      taskId: 'mon-1',
      toolUseId: 'toolu_mon',
      kind: 'monitor',
      description: 'tail server log',
      command: 'tail -F /tmp/log',
      timeoutMs: 60000,
      persistent: false,
    });
  });

  it('increments monitorEventCount for matching task', () => {
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_EVENT',
      sessionId: SESSION,
      taskId: 'mon-1',
    });
    expect(state.get(SESSION)!.backgroundTasks.get('mon-1')!.monitorEventCount).toBe(1);

    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_EVENT',
      sessionId: SESSION,
      taskId: 'mon-1',
    });
    expect(state.get(SESSION)!.backgroundTasks.get('mon-1')!.monitorEventCount).toBe(2);
  });

  it('is a no-op for unknown taskId (event arrived after completion)', () => {
    const before = state.get(SESSION)!.backgroundTasks;
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_EVENT',
      sessionId: SESSION,
      taskId: 'unknown',
    });
    expect(state.get(SESSION)!.backgroundTasks).toBe(before);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'TRANSCRIPT_BACKGROUND_TASK_EVENT'`
Expected: FAIL — handler not implemented; `monitorEventCount` is undefined.

- [ ] **Step 3: Implement the handler**

In `chat-reducer.ts`, add the case:

```typescript
case 'TRANSCRIPT_BACKGROUND_TASK_EVENT': {
  const session = next.get(action.sessionId);
  if (!session) return state;
  const task = session.backgroundTasks.get(action.taskId);
  if (!task) return state;

  const backgroundTasks = new Map(session.backgroundTasks);
  backgroundTasks.set(action.taskId, {
    ...task,
    monitorEventCount: (task.monitorEventCount ?? 0) + 1,
  });

  next.set(action.sessionId, { ...session, backgroundTasks });
  return next;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'TRANSCRIPT_BACKGROUND_TASK_EVENT'`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/state/chat-reducer.ts desktop/tests/chat-reducer.test.ts
git commit -m "feat(background-tasks): reducer handler for EVENT (Monitor counter)"
```

---

### Task 6: `endTurn()` — set `'background-active'` when Map non-empty (TDD)

**Files:**
- Test: `desktop/tests/chat-reducer.test.ts`
- Modify: `desktop/src/renderer/state/chat-reducer.ts:145-167`

- [ ] **Step 1: Write the failing test**

Append to `desktop/tests/chat-reducer.test.ts`:

```typescript
describe('endTurn() with active background tasks', () => {
  let state: ChatState;

  beforeEach(() => {
    state = initState();
    // Start a background task.
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_STARTED',
      sessionId: SESSION,
      uuid: 'u-bg',
      timestamp: 1000,
      taskId: 'bg-1',
      toolUseId: 'toolu_bg',
      kind: 'bash',
      description: 'desc',
      command: 'cmd',
    });
  });

  it('sets attentionState to background-active on TRANSCRIPT_TURN_COMPLETE when Map non-empty', () => {
    state = dispatch(state, {
      type: 'TRANSCRIPT_TURN_COMPLETE',
      sessionId: SESSION,
      uuid: 'u-tc',
      timestamp: 2000,
      stopReason: 'end_turn',
      model: 'claude-opus-4-7',
      anthropicRequestId: null,
      usage: null,
    });
    expect(state.get(SESSION)!.attentionState).toBe('background-active');
    // Other endTurn() effects still apply:
    expect(state.get(SESSION)!.isThinking).toBe(false);
    expect(state.get(SESSION)!.currentTurnId).toBeNull();
  });

  it('still sets ok when Map is empty', () => {
    // Drain the task first.
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_COMPLETED',
      sessionId: SESSION,
      taskId: 'bg-1',
    });
    state = dispatch(state, {
      type: 'TRANSCRIPT_TURN_COMPLETE',
      sessionId: SESSION,
      uuid: 'u-tc',
      timestamp: 2000,
      stopReason: 'end_turn',
      model: 'claude-opus-4-7',
      anthropicRequestId: null,
      usage: null,
    });
    expect(state.get(SESSION)!.attentionState).toBe('ok');
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'endTurn() with active background tasks'`
Expected: FAIL on first test — `attentionState` is `'ok'` because the current `endTurn()` always resets to `'ok'`.

- [ ] **Step 3: Modify `endTurn()`**

In `chat-reducer.ts`, replace the `endTurn` function (lines 145-167) with:

```typescript
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
  // If background tasks outlive this turn, the session is still "active" in the
  // sense that more output may arrive — keep the dot green and the in-chat
  // indicator visible. SESSION_PROCESS_EXITED still overrides this to
  // 'session-died' AFTER spreading endTurn() (see that handler).
  const nextAttention: AttentionState =
    session.backgroundTasks.size > 0 ? 'background-active' : 'ok';
  return {
    toolCalls,
    isThinking: false,
    streamingText: '',
    currentGroupId: null,
    currentTurnId: null,
    activeTurnToolIds: new Set(),
    attentionState: nextAttention,
  };
}
```

(Add an import of `AttentionState` from `./chat-types` at the top of the file if it isn't already imported.)

- [ ] **Step 4: Run the new test plus the previously-pending one from Task 4**

Run:
```bash
cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'endTurn'
cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'transitions attentionState'
```
Expected: PASS for both blocks (Task 4's third test now passes too).

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/state/chat-reducer.ts desktop/tests/chat-reducer.test.ts
git commit -m "feat(background-tasks): endTurn() emits background-active when tasks outstanding"
```

---

### Task 7: `SESSION_PROCESS_EXITED` — clear backgroundTasks (TDD)

**Files:**
- Test: `desktop/tests/chat-reducer.test.ts`
- Modify: `desktop/src/renderer/state/chat-reducer.ts:356-368`

- [ ] **Step 1: Write the failing test**

Append:

```typescript
describe('SESSION_PROCESS_EXITED with background tasks', () => {
  it('clears the backgroundTasks Map and forces session-died', () => {
    let state = initState();
    state = dispatch(state, {
      type: 'TRANSCRIPT_BACKGROUND_TASK_STARTED',
      sessionId: SESSION,
      uuid: 'u-1',
      timestamp: 1000,
      taskId: 'b1',
      toolUseId: 'toolu_001',
      kind: 'bash',
      description: 'desc',
      command: 'cmd',
    });
    expect(state.get(SESSION)!.backgroundTasks.size).toBe(1);

    state = dispatch(state, {
      type: 'SESSION_PROCESS_EXITED',
      sessionId: SESSION,
      exitCode: 1,
    });

    const session = state.get(SESSION)!;
    expect(session.backgroundTasks.size).toBe(0);
    expect(session.attentionState).toBe('session-died');
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'SESSION_PROCESS_EXITED with background tasks'`
Expected: FAIL — the existing handler doesn't touch `backgroundTasks`.

- [ ] **Step 3: Modify `SESSION_PROCESS_EXITED`**

Replace the handler at lines 356-368 with:

```typescript
case 'SESSION_PROCESS_EXITED': {
  const session = next.get(action.sessionId);
  if (!session) return state;
  const hadInFlight =
    session.isThinking ||
    session.activeTurnToolIds.size > 0 ||
    session.backgroundTasks.size > 0;
  if (action.exitCode === 0 && !hadInFlight) return state;
  next.set(action.sessionId, {
    ...session,
    ...endTurn(session),
    // CC died — its background processes died with it. Clear the Map so the
    // chip doesn't show ghost entries forever (no completion event will ever
    // arrive for them).
    backgroundTasks: new Map(),
    // Override endTurn's nextAttention with 'session-died'. The empty Map
    // means endTurn would have written 'ok' anyway, so this is just being
    // explicit about the priority.
    attentionState: 'session-died',
  });
  return next;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd desktop && npx vitest run tests/chat-reducer.test.ts -t 'SESSION_PROCESS_EXITED'`
Expected: PASS for the new test plus any pre-existing tests in the same describe block.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/state/chat-reducer.ts desktop/tests/chat-reducer.test.ts
git commit -m "feat(background-tasks): clear Map on SESSION_PROCESS_EXITED"
```

---

### Task 8: Transcript watcher — emit `background-task-started` (TDD)

**Files:**
- Test: `desktop/src/main/transcript-watcher.test.ts`
- Modify: `desktop/src/main/transcript-watcher.ts`

The detection happens on the `tool_result` line (the synchronous response that carries `backgroundTaskId`/`taskId` on `toolUseResult`). We pair it with the originating `tool_use` from a per-session in-memory Map keyed by `tool_use_id`.

- [ ] **Step 1: Write the failing tests**

Append to `desktop/src/main/transcript-watcher.test.ts`:

```typescript
describe('transcript-watcher background-task-started', () => {
  it('emits background-task-started when tool_result has backgroundTaskId (Bash)', () => {
    // First the tool_use to establish what tool the ID belongs to.
    const useLine = JSON.stringify({
      type: 'assistant',
      uuid: 'u-tu',
      timestamp: '2026-04-26T00:00:00Z',
      message: {
        role: 'assistant',
        content: [{
          type: 'tool_use',
          id: 'toolu_001',
          name: 'Bash',
          input: {
            command: 'npm run dev 2>&1 &',
            description: 'Start dev server',
            run_in_background: true,
          },
        }],
        stop_reason: 'tool_use',
      },
    });
    parseTranscriptLine(useLine, 'sess-1');

    const resultLine = JSON.stringify({
      type: 'user',
      uuid: 'u-tr',
      timestamp: '2026-04-26T00:00:01Z',
      message: {
        role: 'user',
        content: [{
          type: 'tool_result',
          tool_use_id: 'toolu_001',
          content: 'Command running in background with ID: b6lazmyhu',
          is_error: false,
        }],
      },
      toolUseResult: {
        stdout: '',
        stderr: '',
        interrupted: false,
        backgroundTaskId: 'b6lazmyhu',
      },
    });

    const events = parseTranscriptLine(resultLine, 'sess-1');

    // Existing tool-result event still emits.
    expect(events).toContainEqual(
      expect.objectContaining({ type: 'tool-result' }),
    );

    // PLUS the new background-task-started event.
    expect(events).toContainEqual(
      expect.objectContaining({
        type: 'background-task-started',
        sessionId: 'sess-1',
        data: expect.objectContaining({
          taskId: 'b6lazmyhu',
          toolUseId: 'toolu_001',
          kind: 'bash',
          description: 'Start dev server',
          command: 'npm run dev 2>&1 &',
        }),
      }),
    );
  });

  it('emits background-task-started for Monitor with timeoutMs/persistent', () => {
    parseTranscriptLine(
      JSON.stringify({
        type: 'assistant',
        uuid: 'u-mu',
        timestamp: '2026-04-26T00:00:00Z',
        message: {
          role: 'assistant',
          content: [{
            type: 'tool_use',
            id: 'toolu_002',
            name: 'Monitor',
            input: {
              description: 'dev server errors',
              command: 'tail -F /tmp/log',
              timeout_ms: 120000,
              persistent: false,
            },
          }],
          stop_reason: 'tool_use',
        },
      }),
      'sess-1',
    );

    const events = parseTranscriptLine(
      JSON.stringify({
        type: 'user',
        uuid: 'u-mr',
        timestamp: '2026-04-26T00:00:01Z',
        message: {
          role: 'user',
          content: [{
            type: 'tool_result',
            tool_use_id: 'toolu_002',
            content: 'Monitor started',
          }],
        },
        toolUseResult: {
          taskId: 'b8hrhggum',
          timeoutMs: 120000,
          persistent: false,
        },
      }),
      'sess-1',
    );

    expect(events).toContainEqual(
      expect.objectContaining({
        type: 'background-task-started',
        data: expect.objectContaining({
          taskId: 'b8hrhggum',
          toolUseId: 'toolu_002',
          kind: 'monitor',
          description: 'dev server errors',
          command: 'tail -F /tmp/log',
          timeoutMs: 120000,
          persistent: false,
        }),
      }),
    );
  });

  it('does NOT emit background-task-started for ordinary (non-background) Bash', () => {
    parseTranscriptLine(
      JSON.stringify({
        type: 'assistant',
        uuid: 'u-tu2',
        message: {
          role: 'assistant',
          content: [{
            type: 'tool_use',
            id: 'toolu_003',
            name: 'Bash',
            input: { command: 'ls' },
          }],
          stop_reason: 'tool_use',
        },
      }),
      'sess-2',
    );

    const events = parseTranscriptLine(
      JSON.stringify({
        type: 'user',
        uuid: 'u-tr2',
        message: {
          role: 'user',
          content: [{
            type: 'tool_result',
            tool_use_id: 'toolu_003',
            content: 'file1.txt\nfile2.txt',
          }],
        },
        toolUseResult: {
          stdout: 'file1.txt\nfile2.txt',
          stderr: '',
        },
      }),
      'sess-2',
    );

    expect(events.find(e => e.type === 'background-task-started')).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd desktop && npx vitest run src/main/transcript-watcher.test.ts -t 'background-task-started'`
Expected: FAIL — `background-task-started` events are not emitted.

- [ ] **Step 3: Add a per-parser in-memory toolUse cache, then implement emission**

At the top of `transcript-watcher.ts` (module scope, near the imports), add:

```typescript
// In-memory map of tool_use_id → { toolName, input } so that when the
// matching tool_result line is parsed (which may arrive in a separate call),
// we can check whether it corresponds to a backgrounded Bash or a Monitor
// and emit a background-task-started event with the originating fields.
//
// Keyed globally (not per-session) — toolu_* IDs are issued by Anthropic and
// are unique across all sessions. Cache stays bounded in practice because
// each ID is consumed at most once (delete after pairing).
const pendingToolUses = new Map<string, { toolName: string; input: Record<string, unknown> }>();
```

In the `tool_use` block (around line 173), record the tool use immediately after pushing the event:

```typescript
case 'tool_use':
  events.push({
    type: 'tool-use',
    sessionId,
    uuid,
    timestamp,
    data: {
      toolUseId: block.id,
      toolName: block.name,
      toolInput: block.input,
    },
  });
  // Record for background-task pairing (Task 8).
  pendingToolUses.set(block.id, { toolName: block.name, input: block.input ?? {} });
  break;
```

In the `tool_result` block (around line 99), after pushing the existing tool-result event, check for backgroundTaskId/taskId on `toolUseResult`:

```typescript
for (const block of content) {
  if (block.type === 'tool_result') {
    events.push({
      type: 'tool-result',
      sessionId,
      uuid,
      timestamp,
      data: {
        toolUseId: block.tool_use_id,
        toolResult: extractToolResultContent(block.content),
        isError: block.is_error ?? false,
        ...(structuredPatch ? { structuredPatch } : {}),
      },
    });

    // NEW: detect background tasks. CC sets `backgroundTaskId` on `toolUseResult`
    // for backgrounded Bash, and `taskId` for Monitor. Pair with the cached
    // tool_use by tool_use_id.
    const tur = parsed.toolUseResult ?? {};
    const bgId: string | undefined = tur.backgroundTaskId || tur.taskId;
    if (bgId && block.tool_use_id) {
      const originating = pendingToolUses.get(block.tool_use_id);
      if (originating) {
        const isMonitor = originating.toolName === 'Monitor';
        const input = originating.input;
        events.push({
          type: 'background-task-started',
          sessionId,
          uuid,
          timestamp,
          data: {
            taskId: bgId,
            toolUseId: block.tool_use_id,
            kind: isMonitor ? 'monitor' : 'bash',
            description: typeof input.description === 'string' ? input.description : '',
            command: typeof input.command === 'string' ? input.command : '',
            ...(typeof input.timeout_ms === 'number' ? { timeoutMs: input.timeout_ms } : {}),
            ...(typeof input.persistent === 'boolean' ? { persistent: input.persistent } : {}),
          },
        });
        pendingToolUses.delete(block.tool_use_id);
      }
    }
  }
}
```

(Place the `import` of any types you reference. The `parsed.toolUseResult` access mirrors the existing `parsed.toolUseResult?.structuredPatch` access a few lines up — same source.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd desktop && npx vitest run src/main/transcript-watcher.test.ts -t 'background-task-started'`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/transcript-watcher.ts desktop/src/main/transcript-watcher.test.ts
git commit -m "feat(background-tasks): emit background-task-started from tool_result"
```

---

### Task 9: Transcript watcher — emit `background-task-completed` from queue-operation (TDD)

The queue-operation lines today are filtered out by the "only user/assistant lines" gate (transcript-watcher.ts:48-54). We need to relax it for the `<task-notification>` subset that carries `<status>completed</status>` (or any future terminal status).

**Files:**
- Test: `desktop/src/main/transcript-watcher.test.ts`
- Modify: `desktop/src/main/transcript-watcher.ts`

- [ ] **Step 1: Write the failing test**

Append:

```typescript
describe('transcript-watcher background-task-completed', () => {
  it('emits background-task-completed from queue-operation with task-notification', () => {
    const line = JSON.stringify({
      type: 'queue-operation',
      operation: 'enqueue',
      timestamp: '2026-04-26T00:00:10Z',
      content:
        '<task-notification>\n' +
        '<task-id>b6lazmyhu</task-id>\n' +
        '<tool-use-id>toolu_001</tool-use-id>\n' +
        '<output-file>/tmp/b6lazmyhu.output</output-file>\n' +
        '<status>completed</status>\n' +
        '<summary>Background command "Start dev server" completed (exit code 0)</summary>\n' +
        '</task-notification>',
    });

    const events = parseTranscriptLine(line, 'sess-1');

    expect(events).toContainEqual(
      expect.objectContaining({
        type: 'background-task-completed',
        sessionId: 'sess-1',
        data: expect.objectContaining({
          taskId: 'b6lazmyhu',
          status: 'completed',
          exitCode: 0,
          summary: expect.stringContaining('Start dev server'),
        }),
      }),
    );
  });

  it('parses non-zero exit code from summary', () => {
    const line = JSON.stringify({
      type: 'queue-operation',
      operation: 'enqueue',
      content:
        '<task-notification>\n' +
        '<task-id>x9</task-id>\n' +
        '<status>completed</status>\n' +
        '<summary>Background command "build" completed (exit code 2)</summary>\n' +
        '</task-notification>',
    });

    const events = parseTranscriptLine(line, 'sess-1');
    const completed = events.find(e => e.type === 'background-task-completed');
    expect(completed?.data.exitCode).toBe(2);
  });

  it('emits nothing for queue-operation lines without task-notification', () => {
    const line = JSON.stringify({
      type: 'queue-operation',
      operation: 'enqueue',
      content: 'some other queue payload',
    });
    expect(parseTranscriptLine(line, 'sess-1')).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd desktop && npx vitest run src/main/transcript-watcher.test.ts -t 'background-task-completed'`
Expected: FAIL — events are empty.

- [ ] **Step 3: Modify the parser**

Locate the gate at `transcript-watcher.ts:48-54`:

```typescript
// Only process user / assistant message lines
if (parsed.type !== 'user' && parsed.type !== 'assistant') {
  return [];
}
if (!parsed.message) {
  return [];
}
```

Replace with:

```typescript
// Background task completion arrives as a queue-operation line with a
// <task-notification> XML payload. Handle that BEFORE the user/assistant
// gate so we don't lose it. Other queue-operation shapes are still skipped.
if (parsed.type === 'queue-operation' && typeof parsed.content === 'string') {
  return parseTaskNotification(parsed, sessionId);
}

// Only process user / assistant message lines
if (parsed.type !== 'user' && parsed.type !== 'assistant') {
  return [];
}
if (!parsed.message) {
  return [];
}
```

Then add the helper at the bottom of the file (or with the other helpers):

```typescript
/**
 * Parses a queue-operation line carrying a CC <task-notification> XML payload.
 * Today CC emits these on background-task completion (and Monitor events —
 * those are handled in parseAttachment, since they arrive as type=attachment).
 */
function parseTaskNotification(parsed: any, sessionId: string): TranscriptEvent[] {
  const content: string = parsed.content;
  if (!content.includes('<task-notification>')) return [];

  const taskIdMatch = content.match(/<task-id>([^<]+)<\/task-id>/);
  const statusMatch = content.match(/<status>([^<]+)<\/status>/);
  const summaryMatch = content.match(/<summary>([^<]+)<\/summary>/);

  if (!taskIdMatch || !statusMatch) return [];

  const taskId = taskIdMatch[1].trim();
  const status = statusMatch[1].trim();
  const summary = summaryMatch ? summaryMatch[1].trim() : '';

  // Parse trailing "(exit code N)" from the summary if present.
  const exitMatch = summary.match(/\(exit code (-?\d+)\)/);
  const exitCode = exitMatch ? parseInt(exitMatch[1], 10) : undefined;

  return [{
    type: 'background-task-completed',
    sessionId,
    uuid: parsed.uuid ?? '',
    timestamp: Date.now(),
    data: {
      taskId,
      status,
      summary,
      ...(exitCode !== undefined ? { exitCode } : {}),
    },
  }];
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd desktop && npx vitest run src/main/transcript-watcher.test.ts -t 'background-task-completed'`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/transcript-watcher.ts desktop/src/main/transcript-watcher.test.ts
git commit -m "feat(background-tasks): parse queue-operation completion notifications"
```

---

### Task 10: Transcript watcher — emit `background-task-event` from attachment (TDD)

Monitor stdout events arrive as `type: "attachment"` with `attachment.type: "queued_command"` and a `<task-notification>` containing `<event>...</event>` (NOT `<status>`).

**Files:**
- Test: `desktop/src/main/transcript-watcher.test.ts`
- Modify: `desktop/src/main/transcript-watcher.ts`

- [ ] **Step 1: Write the failing test**

Append:

```typescript
describe('transcript-watcher background-task-event', () => {
  it('emits background-task-event from attachment with queued_command + <event>', () => {
    const line = JSON.stringify({
      type: 'attachment',
      attachment: {
        type: 'queued_command',
        prompt:
          '<task-notification>\n' +
          '<task-id>b8hrhggum</task-id>\n' +
          '<summary>Monitor event: "dev server errors"</summary>\n' +
          '<event>VITE v8.0.1 ready in 1273 ms</event>\n' +
          '</task-notification>',
        commandMode: 'task-notification',
      },
      timestamp: '2026-04-26T00:00:10Z',
    });

    const events = parseTranscriptLine(line, 'sess-1');
    expect(events).toContainEqual(
      expect.objectContaining({
        type: 'background-task-event',
        sessionId: 'sess-1',
        data: expect.objectContaining({ taskId: 'b8hrhggum' }),
      }),
    );
  });

  it('emits nothing for attachment shapes without queued_command + <event>', () => {
    expect(parseTranscriptLine(
      JSON.stringify({ type: 'attachment', attachment: { type: 'something-else' } }),
      'sess-1',
    )).toEqual([]);
  });
});
```

- [ ] **Step 2: Run to verify failure**

Run: `cd desktop && npx vitest run src/main/transcript-watcher.test.ts -t 'background-task-event'`
Expected: FAIL.

- [ ] **Step 3: Add the attachment branch to the parser**

In `transcript-watcher.ts`, ABOVE the `queue-operation` branch added in Task 9, add:

```typescript
// Background task events (Monitor stdout lines) arrive as attachment lines.
if (parsed.type === 'attachment' && parsed.attachment?.type === 'queued_command') {
  return parseAttachmentTaskNotification(parsed, sessionId);
}
```

Add the helper:

```typescript
function parseAttachmentTaskNotification(parsed: any, sessionId: string): TranscriptEvent[] {
  const prompt: string = parsed.attachment?.prompt ?? '';
  if (!prompt.includes('<task-notification>') || !prompt.includes('<event>')) return [];

  const taskIdMatch = prompt.match(/<task-id>([^<]+)<\/task-id>/);
  if (!taskIdMatch) return [];

  return [{
    type: 'background-task-event',
    sessionId,
    uuid: parsed.uuid ?? '',
    timestamp: Date.now(),
    data: { taskId: taskIdMatch[1].trim() },
  }];
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd desktop && npx vitest run src/main/transcript-watcher.test.ts -t 'background-task-event'`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/transcript-watcher.ts desktop/src/main/transcript-watcher.test.ts
git commit -m "feat(background-tasks): parse attachment Monitor event notifications"
```

---

### Task 11: Wire transcript events into reducer dispatch

The renderer has an existing dispatcher that turns `transcript:event` IPC payloads into `TRANSCRIPT_*` actions. Find it and add the three new mappings.

**Files:**
- Modify: wherever `transcript:event` is consumed in the renderer (likely `src/renderer/App.tsx` or `src/renderer/state/hook-dispatcher.ts`)

- [ ] **Step 1: Locate the existing dispatcher**

Run:
```bash
cd desktop && grep -rn "TRANSCRIPT_TURN_COMPLETE" src/renderer/ | grep -v "\.test\." | head -5
```

Open the file that constructs the action with `type: 'TRANSCRIPT_TURN_COMPLETE'`. There will be a switch on `event.type` that maps each transcript event type to its action.

- [ ] **Step 2: Add the three new cases**

Inside that switch, add:

```typescript
case 'background-task-started':
  dispatch({
    type: 'TRANSCRIPT_BACKGROUND_TASK_STARTED',
    sessionId: event.sessionId,
    uuid: event.uuid,
    timestamp: event.timestamp,
    taskId: event.data.taskId!,
    toolUseId: event.data.toolUseId!,
    kind: event.data.kind as 'bash' | 'monitor',
    description: event.data.description ?? '',
    command: event.data.command ?? '',
    ...(event.data.timeoutMs !== undefined ? { timeoutMs: event.data.timeoutMs } : {}),
    ...(event.data.persistent !== undefined ? { persistent: event.data.persistent } : {}),
  });
  break;

case 'background-task-completed':
  dispatch({
    type: 'TRANSCRIPT_BACKGROUND_TASK_COMPLETED',
    sessionId: event.sessionId,
    taskId: event.data.taskId!,
  });
  break;

case 'background-task-event':
  dispatch({
    type: 'TRANSCRIPT_BACKGROUND_TASK_EVENT',
    sessionId: event.sessionId,
    taskId: event.data.taskId!,
  });
  break;
```

- [ ] **Step 3: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/renderer/  # commit just the dispatcher file you changed
git commit -m "feat(background-tasks): dispatch new transcript events to reducer"
```

---

### Task 12: Classifier gate — skip ticks during background-active

**Files:**
- Modify: `desktop/src/renderer/hooks/useAttentionClassifier.ts:74`

- [ ] **Step 1: Read the file to find the `active` gate**

Open `desktop/src/renderer/hooks/useAttentionClassifier.ts`. Locate (around line 74):

```typescript
const active = isThinking && !hasRunningTools && !hasAwaitingApproval && visible;
```

- [ ] **Step 2: Pull `attentionState` from the session and AND it into the gate**

The hook already has access to session state via `useChatState(sessionId)` (or similar — check the existing imports). If `attentionState` is not already in scope, destructure it from the session.

Replace the line with:

```typescript
const active =
  isThinking &&
  !hasRunningTools &&
  !hasAwaitingApproval &&
  visible &&
  attentionState !== 'background-active';
```

If `attentionState` isn't already destructured, add it to the destructuring statement that pulls fields from the session state (search the file for `isThinking,` and add it next to that field).

- [ ] **Step 3: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/renderer/hooks/useAttentionClassifier.ts
git commit -m "feat(background-tasks): classifier skips ticks during background-active"
```

---

### Task 12b: Session status dot — keep green for background-active

The session-dot color is computed in `App.tsx:428-475` (`sessionStatuses` memo). Today, the rule `chatState.attentionState !== 'ok'` flips the dot to **amber** ("needs attention"). We want `'background-active'` to stay **green** (healthy, just has background work running).

**Files:**
- Modify: `desktop/src/renderer/App.tsx:453`

- [ ] **Step 1: Update the `needsAttention` predicate**

Locate (around line 453):

```typescript
const needsAttention = chatState.attentionState !== 'ok';
```

Replace with:

```typescript
// 'background-active' isn't a problem — turn ended cleanly, just has work
// outliving it. Treat it as healthy (will fall through to the green branch
// because the next-line check folds it into the "active" group).
const needsAttention =
  chatState.attentionState !== 'ok' &&
  chatState.attentionState !== 'background-active';
```

- [ ] **Step 2: Update the green-branch predicate to include background-active**

Right below, the green branch reads:

```typescript
: (chatState.isThinking || hasRunning)
  ? 'green'
```

Replace with:

```typescript
: (chatState.isThinking || hasRunning || chatState.attentionState === 'background-active')
  ? 'green'
```

This keeps the dot green while background tasks are running even when `isThinking` is false (the normal post-endTurn state).

- [ ] **Step 3: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/renderer/App.tsx
git commit -m "feat(background-tasks): session dot stays green during background-active"
```

---

### Task 13: ThinkingIndicator — accept `variant` prop

**Files:**
- Modify: `desktop/src/renderer/components/ThinkingIndicator.tsx`

- [ ] **Step 1: Replace the component to accept the variant prop**

Replace the file contents with:

```typescript
import React, { useState, useEffect } from 'react';
import BrailleSpinner from './BrailleSpinner';

const THINKING_LINES = [
  'Thinking',
  'Cogitating',
  'Pondering',
  // ... (preserve the existing 20+ lines — keep the array exactly as it was)
];

export type IndicatorVariant = 'thinking' | 'background';

export default function ThinkingIndicator({ variant = 'thinking' }: { variant?: IndicatorVariant }) {
  // For 'thinking' we rotate through THINKING_LINES every 2.5s. For 'background'
  // the copy is fixed — Claude isn't producing anything; it's just that a
  // background process is still alive. Static copy avoids implying ongoing work.
  const [lineIndex, setLineIndex] = useState(() =>
    Math.floor(Math.random() * THINKING_LINES.length),
  );

  useEffect(() => {
    if (variant !== 'thinking') return;
    const id = setInterval(() => {
      setLineIndex(Math.floor(Math.random() * THINKING_LINES.length));
    }, 2500);
    return () => clearInterval(id);
  }, [variant]);

  const copy = variant === 'background'
    ? 'Background tasks running'
    : THINKING_LINES[lineIndex];

  return (
    <div className="flex items-center gap-2 px-4 py-1.5 in-view">
      <div className="flex items-center gap-2 bg-inset rounded-2xl rounded-bl-sm px-4 py-2.5">
        <BrailleSpinner size="base" />
        <span className="text-sm text-fg-dim">{copy}</span>
      </div>
    </div>
  );
}
```

(Preserve the actual `THINKING_LINES` array contents from the existing file — only the surrounding code structure changes.)

- [ ] **Step 2: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add desktop/src/renderer/components/ThinkingIndicator.tsx
git commit -m "feat(background-tasks): ThinkingIndicator accepts variant prop"
```

---

### Task 14: ChatView — widen indicator render gate

**Files:**
- Modify: `desktop/src/renderer/components/ChatView.tsx`

- [ ] **Step 1: Find the existing render gate**

Open `desktop/src/renderer/components/ChatView.tsx`. Find where `<ThinkingIndicator />` is rendered (search for `ThinkingIndicator`). It will be in a conditional like:

```typescript
{attentionState === 'ok' && isThinking && <ThinkingIndicator />}
{attentionState !== 'ok' && <AttentionBanner state={attentionState} ... />}
```

- [ ] **Step 2: Update the condition**

Replace with:

```typescript
{(attentionState === 'ok' && isThinking) && (
  <ThinkingIndicator variant="thinking" />
)}
{attentionState === 'background-active' && (
  <ThinkingIndicator variant="background" />
)}
{(attentionState === 'stuck' || attentionState === 'session-died') && (
  <AttentionBanner state={attentionState} anthropicRequestId={...} />
)}
```

(Preserve the `anthropicRequestId` prop from the existing AttentionBanner call.)

- [ ] **Step 3: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS — `AttentionBanner` already excludes `'ok'` from its prop type. Excluding `'background-active'` too needs a tweak to its `Props['state']` type.

- [ ] **Step 4: Tighten AttentionBanner's prop type**

In `desktop/src/renderer/components/AttentionBanner.tsx`, change:

```typescript
state: Exclude<AttentionState, 'ok'>;
```

to:

```typescript
state: Exclude<AttentionState, 'ok' | 'background-active'>;
```

This makes the AttentionBanner only accept `'stuck'` or `'session-died'`, matching what ChatView now passes. The COPY map already covers exactly those keys.

- [ ] **Step 5: Type-check + commit**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

```bash
git add desktop/src/renderer/components/ChatView.tsx desktop/src/renderer/components/AttentionBanner.tsx
git commit -m "feat(background-tasks): ChatView renders background-variant indicator"
```

---

### Task 15: Tool card label — auto-completing copy for backgrounded tools

**Files:**
- Modify: `desktop/src/renderer/components/ToolCard.tsx:30-48`

- [ ] **Step 1: Update `friendlyToolDisplay` for `Bash` with `run_in_background`**

In `ToolCard.tsx`, locate the `case 'Bash':` block in `friendlyToolDisplay` (lines 34-48). Replace it with:

```typescript
case 'Bash': {
  const cmd = (input.command as string) || '';
  const desc = input.description as string | undefined;
  const bg = input.run_in_background === true;

  // Backgrounded Bash auto-completes at launch — the chip in the StatusBar
  // is the source of truth for ongoing state. Show a fixed "launched" label.
  if (bg) {
    return {
      label: 'Launched a background task',
      detail: desc ? `↳ ${desc}` : (cmd ? `↳ ${truncate(cmd, 80)}` : ''),
    };
  }

  let label: string;
  if (desc) {
    label = desc;
  } else if (cmd) {
    const firstBin = cmd.trimStart().split(/\s+/)[0] || 'command';
    label = `Running ${basename(firstBin)}`;
  } else {
    label = 'Run Command';
  }
  return { label, detail: cmd ? `↳ ${truncate(cmd, 80)}` : '' };
}
```

- [ ] **Step 2: Add a `case 'Monitor':` block**

Just before the `default:` of the switch in `friendlyToolDisplay`, add:

```typescript
case 'Monitor': {
  const desc = (input.description as string | undefined) ?? '';
  const cmd = (input.command as string | undefined) ?? '';
  return {
    label: 'Launched a background task',
    detail: desc ? `↳ ${desc}` : (cmd ? `↳ ${truncate(cmd, 80)}` : ''),
  };
}
```

- [ ] **Step 3: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/renderer/components/ToolCard.tsx
git commit -m "feat(background-tasks): ToolCard label for backgrounded Bash + Monitor"
```

---

### Task 16: StatusData + WidgetId + WidgetDef

**Files:**
- Modify: `desktop/src/renderer/components/StatusBar.tsx:30-47` (StatusData)
- Modify: `desktop/src/renderer/components/StatusBar.tsx:154-159` (WidgetId)
- Modify: `desktop/src/renderer/components/StatusBar.tsx:289-298` (Tasks category)

- [ ] **Step 1: Add field to `StatusData`**

In the `StatusData` interface, add (anywhere — convention: near `sessionStatsMap`):

```typescript
  /** Per-active-session list of running background tasks. Empty/missing -> chip hidden. */
  backgroundTasksMap: Record<string, BackgroundTaskSummary[]> | null;
```

Import the type at the top:

```typescript
import type { BackgroundTaskSummary } from '../state/chat-types';
```

- [ ] **Step 2: Extend `WidgetId`**

Replace the WidgetId union to add `'background-tasks'`:

```typescript
type WidgetId =
  | 'usage-5h' | 'usage-7d' | 'context' | 'git-branch' | 'sync-warnings' | 'theme' | 'version'
  | 'session-cost' | 'tokens-in' | 'tokens-out' | 'cache-stats' | 'code-changes' | 'session-time'
  | 'cache-hit-rate' | 'active-ratio' | 'output-speed'
  | 'announcement'
  | 'open-tasks'
  | 'background-tasks';
```

- [ ] **Step 3: Add `WidgetDef` to the Tasks category**

Find the Tasks category block (search for `category: 'Tasks'` or similar). Add a new entry:

```typescript
{
  id: 'background-tasks',
  label: 'Background Tasks',
  defaultVisible: true,
  description:
    'Live count of backgrounded Bash processes and Monitor watchers in the active session. Hidden when nothing is running.',
  bestFor:
    'Knowing when a dev server, build, or log tail is still running after the chat turn ended.',
}
```

- [ ] **Step 4: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/StatusBar.tsx
git commit -m "feat(background-tasks): WidgetId + WidgetDef + StatusData field"
```

---

### Task 17: BackgroundTasksChip component (chip + popup)

**Files:**
- Create: `desktop/src/renderer/components/BackgroundTasksChip.tsx`

- [ ] **Step 1: Create the file with the full component**

```typescript
import React, { useEffect, useState, useRef, useCallback } from 'react';
import type { BackgroundTaskSummary } from '../state/chat-types';
import { OverlayPanel } from './overlays/Overlay';

function formatElapsed(ms: number): string {
  const s = Math.floor(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  if (m < 60) return rem === 0 ? `${m}m` : `${m}m ${rem}s`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m`;
}

function formatRemaining(startedAt: number, timeoutMs: number, nowMs: number): string {
  const remaining = Math.max(0, timeoutMs - (nowMs - startedAt));
  const s = Math.floor(remaining / 1000);
  if (s < 60) return `${s}s left`;
  const m = Math.floor(s / 60);
  return `${m}m ${s % 60}s left`;
}

export function BackgroundTasksChip({ tasks }: { tasks: BackgroundTaskSummary[] }) {
  // Tick once per second so elapsed times update live without prop changes.
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  const [open, setOpen] = useState(false);
  const anchorRef = useRef<HTMLButtonElement>(null);

  const close = useCallback(() => setOpen(false), []);

  // Hide the chip entirely if no tasks. Returning null also avoids any flicker
  // between the open popup and the chip disappearing.
  if (tasks.length === 0) {
    if (open) setOpen(false);
    return null;
  }

  const bashCount = tasks.filter(t => t.kind === 'bash').length;
  const monitorCount = tasks.filter(t => t.kind === 'monitor').length;

  const chipParts: string[] = [];
  if (bashCount > 0) chipParts.push(`⚙ ${bashCount}`);
  if (monitorCount > 0) chipParts.push(`👁 ${monitorCount}`);

  return (
    <>
      <button
        ref={anchorRef}
        type="button"
        onClick={() => setOpen(o => !o)}
        className="px-2 py-0.5 text-xs rounded-sm bg-inset text-fg-2 hover:text-fg border border-edge"
        title="Background tasks"
      >
        {chipParts.join(' · ')}
      </button>
      {open && (
        <OverlayPanel layer={2} className="absolute mt-1 right-0 min-w-[260px] max-w-[400px] rounded-md p-2">
          <ul className="flex flex-col gap-1">
            {tasks.map(task => (
              <li
                key={task.taskId}
                className="flex items-center justify-between gap-3 text-xs px-2 py-1 rounded-sm"
              >
                <span className="flex items-center gap-2 min-w-0">
                  <span className="text-fg-muted shrink-0">
                    {task.kind === 'monitor' ? '👁' : '⚙'}
                  </span>
                  <span className="truncate text-fg-2">
                    {task.description || (task.kind === 'monitor' ? 'Monitor' : 'Background command')}
                  </span>
                </span>
                <span className="text-fg-muted shrink-0">
                  {formatElapsed(now - task.startedAt)}
                  {task.kind === 'monitor' && task.monitorEventCount !== undefined && (
                    <> · {task.monitorEventCount} events</>
                  )}
                  {task.kind === 'monitor' && task.timeoutMs !== undefined && (
                    <> · {formatRemaining(task.startedAt, task.timeoutMs, now)}</>
                  )}
                </span>
              </li>
            ))}
          </ul>
        </OverlayPanel>
      )}
      {open && (
        // Click-outside catcher. Lower z than OverlayPanel (layer 2 = z 60+).
        <div className="fixed inset-0 z-[59]" onClick={close} />
      )}
    </>
  );
}
```

If `OverlayPanel` lives at a different path, run `cd desktop && grep -rn "export function OverlayPanel\|export.*OverlayPanel" src/renderer/` to locate it and adjust the import.

- [ ] **Step 2: Wire the chip into StatusBar render**

In `desktop/src/renderer/components/StatusBar.tsx`, find the Tasks-category render block (where `open-tasks` widget is rendered). Add a sibling render for the new widget:

```typescript
{show('background-tasks') && statusData.backgroundTasksMap && activeSessionId && (
  <BackgroundTasksChip tasks={statusData.backgroundTasksMap[activeSessionId] ?? []} />
)}
```

Add the import at the top:

```typescript
import { BackgroundTasksChip } from './BackgroundTasksChip';
```

(`activeSessionId` should already be in scope wherever per-session widgets render. If not, look at how `open-tasks` accesses the active session and follow that pattern.)

- [ ] **Step 3: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/renderer/components/BackgroundTasksChip.tsx desktop/src/renderer/components/StatusBar.tsx
git commit -m "feat(background-tasks): StatusBar chip + popup"
```

---

### Task 18: useRemoteBackgroundTasksSync hook

**Files:**
- Create: `desktop/src/renderer/hooks/useRemoteBackgroundTasksSync.ts`

- [ ] **Step 1: Create the file**

Mirror `useRemoteAttentionSync.ts`:

```typescript
import { useEffect, useRef } from 'react';
import { useChatStateMap } from '../state/chat-context';
import type { BackgroundTaskSummary } from '../state/chat-types';

/**
 * Mirror of useRemoteAttentionSync, but for backgroundTasks.
 *
 * Fires `remote:background-tasks-changed` over IPC when any session's
 * backgroundTasks Map changes (size or contents). Lets the main process
 * maintain a per-session cache so remote browsers and the StatusBar widget
 * see consistent counts via the existing `status:data` broadcast.
 *
 * The diff key is taskIds + monitorEventCount (so Monitor event ticks
 * propagate live) joined as a single comparable string.
 */
function summarize(tasks: Map<string, { taskId: string; kind: 'bash' | 'monitor'; description: string; startedAt: number; timeoutMs?: number; monitorEventCount?: number }>): BackgroundTaskSummary[] {
  return Array.from(tasks.values()).map(t => ({
    taskId: t.taskId,
    kind: t.kind,
    description: t.description,
    startedAt: t.startedAt,
    ...(t.timeoutMs !== undefined ? { timeoutMs: t.timeoutMs } : {}),
    ...(t.monitorEventCount !== undefined ? { monitorEventCount: t.monitorEventCount } : {}),
  }));
}

function diffKey(summary: BackgroundTaskSummary[]): string {
  return summary
    .map(s => `${s.taskId}:${s.monitorEventCount ?? 0}`)
    .sort()
    .join('|');
}

export function useRemoteBackgroundTasksSync() {
  const chatState = useChatStateMap();
  const lastByIdRef = useRef<Map<string, string>>(new Map());

  useEffect(() => {
    const api = (window as any).claude;
    if (typeof api?.fireRemoteBackgroundTasksChanged !== 'function') return;

    const last = lastByIdRef.current;
    for (const [sessionId, session] of chatState) {
      const summary = summarize(session.backgroundTasks);
      const key = diffKey(summary);
      const prev = last.get(sessionId);
      if (prev !== key) {
        last.set(sessionId, key);
        api.fireRemoteBackgroundTasksChanged({ sessionId, tasks: summary });
      }
    }
    for (const sessionId of Array.from(last.keys())) {
      if (!chatState.has(sessionId)) last.delete(sessionId);
    }
  }, [chatState]);
}
```

- [ ] **Step 2: Mount the hook in App.tsx**

Open `desktop/src/renderer/App.tsx`. Find where `useRemoteAttentionSync()` is called. Add right after it:

```typescript
useRemoteBackgroundTasksSync();
```

And import:

```typescript
import { useRemoteBackgroundTasksSync } from './hooks/useRemoteBackgroundTasksSync';
```

- [ ] **Step 3: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/renderer/hooks/useRemoteBackgroundTasksSync.ts desktop/src/renderer/App.tsx
git commit -m "feat(background-tasks): renderer-side IPC sync hook"
```

---

### Task 19: preload.ts + remote-shim.ts — `fireRemoteBackgroundTasksChanged`

**Files:**
- Modify: `desktop/src/main/preload.ts`
- Modify: `desktop/src/renderer/remote-shim.ts`

- [ ] **Step 1: Find the existing `fireRemoteAttentionChanged` exposure in preload.ts**

Run:
```bash
cd desktop && grep -n "fireRemoteAttentionChanged" src/main/preload.ts
```

You'll find a block roughly like:

```typescript
fireRemoteAttentionChanged: (payload) => ipcRenderer.send('remote:attention-changed', payload),
```

- [ ] **Step 2: Add the parallel for background tasks**

Right next to `fireRemoteAttentionChanged`, add:

```typescript
fireRemoteBackgroundTasksChanged: (payload) =>
  ipcRenderer.send('remote:background-tasks-changed', payload),
```

- [ ] **Step 3: Mirror in remote-shim.ts**

Run:
```bash
cd desktop && grep -n "fireRemoteAttentionChanged" src/renderer/remote-shim.ts
```

Find the parallel exposure for the WebSocket-backed remote case. Add the matching `fireRemoteBackgroundTasksChanged` that sends the same payload over WebSocket (follow the exact pattern used by `fireRemoteAttentionChanged`).

- [ ] **Step 4: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/preload.ts desktop/src/renderer/remote-shim.ts
git commit -m "feat(background-tasks): preload + remote-shim IPC surface"
```

---

### Task 20: Main process — cache + listener + buildStatusData

**Files:**
- Modify: `desktop/src/main/ipc-handlers.ts`

- [ ] **Step 1: Declare the cache**

Find the line declaring `lastAttentionBySession` (around line 1491-1497 per the agent's findings). Right after it, add:

```typescript
// Per-session background-tasks summaries, updated by the renderer via
// `remote:background-tasks-changed` and read by buildStatusData() so the
// StatusBar chip and remote browsers see consistent counts.
const lastBackgroundTasksBySession = new Map<string, any[]>();
```

- [ ] **Step 2: Fold the field into `buildStatusData()`**

Find the `attentionMap` construction inside `buildStatusData()` (around line 1554). Right after it, add:

```typescript
const backgroundTasksMap: Record<string, any[]> = {};
for (const [desktopId] of sessionIdMap) {
  const tasks = lastBackgroundTasksBySession.get(desktopId);
  if (tasks && tasks.length > 0) backgroundTasksMap[desktopId] = tasks;
}
```

In the return statement, add `backgroundTasksMap`:

```typescript
return {
  usage, announcement, updateStatus, syncStatus, syncWarnings, lastSyncEpoch,
  syncInProgress, backupMeta, contextMap, gitBranchMap, sessionStatsMap,
  attentionMap, backgroundTasksMap,
};
```

- [ ] **Step 3: Register the listener**

Find the existing `ipcMain.on('remote:attention-changed', ...)` registration (around line 1616-1625). Right after that block, add:

```typescript
ipcMain.on('remote:background-tasks-changed', (_e, payload: { sessionId: string; tasks: any[] }) => {
  if (!payload?.sessionId || !Array.isArray(payload.tasks)) return;
  if (payload.tasks.length === 0) {
    lastBackgroundTasksBySession.delete(payload.sessionId);
  } else {
    lastBackgroundTasksBySession.set(payload.sessionId, payload.tasks);
  }
  if (remoteServer) {
    const data = buildStatusData();
    remoteServer.broadcastStatusData(data);
  }
});
```

- [ ] **Step 4: Type-check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/ipc-handlers.ts
git commit -m "feat(background-tasks): main-process cache + listener + status:data feed"
```

---

### Task 21: Android — TranscriptEvent additions

**Files:**
- Modify: `app/src/main/kotlin/com/youcoded/app/parser/TranscriptEvent.kt`

- [ ] **Step 1: Add the three sealed-class members**

Inside the `sealed class TranscriptEvent`, add:

```kotlin
/** Backgrounded Bash or Monitor started — synchronous tool_result returned a backgroundTaskId. */
data class BackgroundTaskStarted(
    override val sessionId: String,
    override val uuid: String,
    override val timestamp: Long,
    val taskId: String,
    val toolUseId: String,
    val kind: String, // "bash" | "monitor"
    val description: String,
    val command: String,
    val timeoutMs: Long? = null,
    val persistent: Boolean? = null,
) : TranscriptEvent()

/** Backgrounded task ended — queue-operation enqueue with <task-notification><status>. */
data class BackgroundTaskCompleted(
    override val sessionId: String,
    override val uuid: String,
    override val timestamp: Long,
    val taskId: String,
    val status: String,
    val summary: String,
    val exitCode: Int? = null,
) : TranscriptEvent()

/** Monitor stdout event — attachment with queued_command + <event>. */
data class BackgroundTaskEvent(
    override val sessionId: String,
    override val uuid: String,
    override val timestamp: Long,
    val taskId: String,
) : TranscriptEvent()
```

- [ ] **Step 2: Build to verify**

Run from worktree root: `./gradlew assembleDebug`
Expected: SUCCESS — compiles cleanly. (No emit sites yet; just the data classes added.)

- [ ] **Step 3: Commit**

```bash
git add app/src/main/kotlin/com/youcoded/app/parser/TranscriptEvent.kt
git commit -m "feat(background-tasks): Kotlin TranscriptEvent additions"
```

---

### Task 22: Android — TranscriptWatcher emit paths

**Files:**
- Modify: `app/src/main/kotlin/com/youcoded/app/parser/TranscriptWatcher.kt`

The Kotlin parser is the fallback when the Node CLI is not in use. Mirror the desktop's three emit paths.

- [ ] **Step 1: Add a per-watcher `pendingToolUses` map**

Inside the `WatcherState` class (around line 76), add:

```kotlin
val pendingToolUses: MutableMap<String, Pair<String, JSONObject>> = mutableMapOf()
```

(Pair = toolName + input.)

- [ ] **Step 2: In the assistant tool_use parsing, record into the cache**

Find where `TranscriptEvent.ToolUse` is constructed (search for `ToolUse(`). Right after it's emitted, add:

```kotlin
state.pendingToolUses[block.getString("id")] = Pair(
    block.getString("name"),
    block.optJSONObject("input") ?: JSONObject(),
)
```

(Use the actual local variable names for `block`/`state` from that scope.)

- [ ] **Step 3: In the user tool_result parsing, detect background tasks**

Find where `TranscriptEvent.ToolResult` is constructed. Right after the result is emitted, before the close of that block, add:

```kotlin
val tur = parsed.optJSONObject("toolUseResult")
if (tur != null) {
    val bgId = tur.optString("backgroundTaskId").ifEmpty { tur.optString("taskId") }
    val toolUseId = block.optString("tool_use_id")
    if (bgId.isNotEmpty() && toolUseId.isNotEmpty()) {
        val originating = state.pendingToolUses[toolUseId]
        if (originating != null) {
            val (toolName, input) = originating
            val isMonitor = toolName == "Monitor"
            _events.tryEmit(TranscriptEvent.BackgroundTaskStarted(
                sessionId = state.mobileSessionId,
                uuid = parsed.optString("uuid"),
                timestamp = System.currentTimeMillis(),
                taskId = bgId,
                toolUseId = toolUseId,
                kind = if (isMonitor) "monitor" else "bash",
                description = input.optString("description"),
                command = input.optString("command"),
                timeoutMs = if (input.has("timeout_ms")) input.getLong("timeout_ms") else null,
                persistent = if (input.has("persistent")) input.getBoolean("persistent") else null,
            ))
            state.pendingToolUses.remove(toolUseId)
        }
    }
}
```

- [ ] **Step 4: Add a top-level branch for queue-operation lines**

Find the gate that filters non-`user`/`assistant` lines. Before that gate (early in the parse function), add:

```kotlin
val type = parsed.optString("type")
if (type == "queue-operation") {
    parseTaskNotification(parsed, state)
    return
}
if (type == "attachment" && parsed.optJSONObject("attachment")?.optString("type") == "queued_command") {
    parseAttachmentTaskNotification(parsed, state)
    return
}
```

Add the helpers below in the class (or as top-level private functions):

```kotlin
private fun parseTaskNotification(parsed: JSONObject, state: WatcherState) {
    val content = parsed.optString("content")
    if (!content.contains("<task-notification>")) return

    val taskIdRegex = Regex("""<task-id>([^<]+)</task-id>""")
    val statusRegex = Regex("""<status>([^<]+)</status>""")
    val summaryRegex = Regex("""<summary>([^<]+)</summary>""")
    val exitRegex = Regex("""\(exit code (-?\d+)\)""")

    val taskId = taskIdRegex.find(content)?.groupValues?.get(1)?.trim() ?: return
    val status = statusRegex.find(content)?.groupValues?.get(1)?.trim() ?: return
    val summary = summaryRegex.find(content)?.groupValues?.get(1)?.trim() ?: ""
    val exitCode = exitRegex.find(summary)?.groupValues?.get(1)?.toIntOrNull()

    _events.tryEmit(TranscriptEvent.BackgroundTaskCompleted(
        sessionId = state.mobileSessionId,
        uuid = parsed.optString("uuid"),
        timestamp = System.currentTimeMillis(),
        taskId = taskId,
        status = status,
        summary = summary,
        exitCode = exitCode,
    ))
}

private fun parseAttachmentTaskNotification(parsed: JSONObject, state: WatcherState) {
    val prompt = parsed.optJSONObject("attachment")?.optString("prompt") ?: ""
    if (!prompt.contains("<task-notification>") || !prompt.contains("<event>")) return
    val taskIdRegex = Regex("""<task-id>([^<]+)</task-id>""")
    val taskId = taskIdRegex.find(prompt)?.groupValues?.get(1)?.trim() ?: return

    _events.tryEmit(TranscriptEvent.BackgroundTaskEvent(
        sessionId = state.mobileSessionId,
        uuid = parsed.optString("uuid"),
        timestamp = System.currentTimeMillis(),
        taskId = taskId,
    ))
}
```

- [ ] **Step 5: Build to verify**

Run from worktree root: `./gradlew assembleDebug`
Expected: SUCCESS.

- [ ] **Step 6: Commit**

```bash
git add app/src/main/kotlin/com/youcoded/app/parser/TranscriptWatcher.kt
git commit -m "feat(background-tasks): Kotlin parser emits new event types"
```

---

### Task 23: Android — SessionService.kt status:data inclusion

**Files:**
- Modify: `app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt`

Mirror the desktop's `lastBackgroundTasksBySession` cache and fold into the WebSocket status broadcast.

- [ ] **Step 1: Add per-session cache + collector**

Locate `startStatusBroadcast` (around line 345-421). At the SessionService class scope (or wherever per-session state is kept), add:

```kotlin
private val backgroundTasksBySession = ConcurrentHashMap<String, List<JSONObject>>()
```

In the place where the SessionService observes the React renderer's events (the same plumbing that handles `remote:attention-changed` payloads), add a handler for `remote:background-tasks-changed`. The exact location depends on how Android receives renderer-originated WebSocket messages — search for `remote:attention-changed` in `SessionService.kt` and follow the pattern. The handler body:

```kotlin
"remote:background-tasks-changed" -> {
    val sessionId = msg.optString("sessionId").ifEmpty { return@let }
    val tasksArray = msg.optJSONArray("tasks") ?: JSONArray()
    val list = (0 until tasksArray.length()).map { tasksArray.getJSONObject(it) }
    if (list.isEmpty()) backgroundTasksBySession.remove(sessionId)
    else backgroundTasksBySession[sessionId] = list
    // Trigger an immediate status broadcast so subscribers see the change.
    broadcastStatusDataNow()
}
```

(Adjust to whatever the existing message-routing pattern in SessionService.kt looks like.)

- [ ] **Step 2: Include in `status:data` payload**

Find where the status:data JSON is assembled. Add a `backgroundTasksMap` field:

```kotlin
val backgroundTasksMap = JSONObject()
backgroundTasksBySession.forEach { (id, tasks) ->
    backgroundTasksMap.put(id, JSONArray(tasks))
}
statusData.put("backgroundTasksMap", backgroundTasksMap)
```

- [ ] **Step 3: Build to verify**

Run: `./gradlew assembleDebug`
Expected: SUCCESS.

- [ ] **Step 4: Commit**

```bash
git add app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt
git commit -m "feat(background-tasks): Android SessionService status broadcast"
```

---

### Task 24: Final verification

- [ ] **Step 1: Full TypeScript check**

Run: `cd desktop && npx tsc --noEmit`
Expected: PASS, no errors.

- [ ] **Step 2: Full test suite**

Run: `cd desktop && npm test`
Expected: PASS — all existing tests still green, new reducer + parser tests included.

- [ ] **Step 3: Build distributable**

Run: `cd desktop && npm run build`
Expected: SUCCESS.

- [ ] **Step 4: Build Android APK**

Run from worktree root: `bash scripts/build-web-ui.sh && ./gradlew assembleDebug`
Expected: SUCCESS.

- [ ] **Step 5: Manual smoke test**

Launch dev (`bash scripts/run-dev.sh` from workspace root).

Verify:
1. Run `npm run dev` (or similar long-running) via Bash with `run_in_background: true`. The originating tool card shows "Launched a background task" with the description as detail. The card has a checkmark, not a spinner.
2. After the assistant turn ends, the chat shows `Background tasks running` with the spinner instead of disappearing into idle. The session status dot stays green.
3. The StatusBar shows a `⚙ 1` chip. Clicking it opens a popup with the task description and elapsed time updating live.
4. When the bash exits (or you `KillShell` from another session), the chip disappears and the chat indicator goes idle within 1 second.
5. Repeat with a `Monitor` task: chip shows `👁 1`, popup shows event count and timeout countdown updating live.
6. Open the same session in a remote browser — the StatusBar chip mirrors the desktop count.

If any of these fail, check `cd desktop && npm test -- --reporter=verbose` for failing assertions, and consult the spec at `docs/superpowers/specs/2026-04-26-background-tasks-tracking-design.md` for intended behavior.

- [ ] **Step 6: Push the branch and open the PR (sub-repo, NOT youcoded-dev)**

```bash
git push -u origin feat/background-tasks
gh pr create --repo itsdestin/youcoded --title "feat: track background tasks (Bash/Monitor)" \
  --body "Implements background task tracking per spec docs/superpowers/specs/2026-04-26-background-tasks-tracking-design.md."
```

---

## Worktree cleanup (after merge)

```bash
cd ~/youcoded-dev/youcoded
git worktree remove ../youcoded-worktrees/background-tasks
git branch -D feat/background-tasks
```
