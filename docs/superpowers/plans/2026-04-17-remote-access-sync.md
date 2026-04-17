# Remote Access State Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remote access clients see the full chat history on connect and have `attentionState` indicators that match the desktop in real time.

**Architecture:** Two independent mechanisms. **(A) Chat hydration:** on new WebSocket auth, the remote server asks the renderer for a serialized snapshot of the full `ChatState` Map and pushes it to the connecting client via a new `chat:hydrate` message. **(B) Attention broadcast:** the renderer fires `remote:attention-changed` on reducer diffs; the main process caches per-session state and folds it into the existing `status:data` payload (`attentionMap`), broadcasting on change instead of only on the 10s timer.

**Tech Stack:** TypeScript, Electron IPC (main ↔ renderer), WebSocket protocol, React + useReducer.

**Working directory for execution:** A fresh git worktree of `youcoded/` (per workspace CLAUDE.md rule). All paths below are relative to `youcoded/desktop/`.

**Spec:** `docs/superpowers/specs/2026-04-17-remote-access-sync-design.md` (in youcoded-dev, parent workspace).

---

## Task 1: Serialization helpers + tests

**Files:**
- Modify: `src/renderer/state/chat-types.ts`
- Create: `src/renderer/state/__tests__/chat-serialization.test.ts`

- [ ] **Step 1: Write failing tests for `serializeChatState` / `deserializeChatState`**

Create `src/renderer/state/__tests__/chat-serialization.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import {
  createSessionChatState,
  serializeChatState,
  deserializeChatState,
} from '../chat-types';
import type { ChatState, ToolCallState } from '../chat-types';

describe('chat state serialization', () => {
  it('round-trips an empty ChatState', () => {
    const state: ChatState = new Map();
    const round = deserializeChatState(serializeChatState(state));
    expect(round).toEqual(state);
  });

  it('round-trips a session with tool calls, turns, and an active turn set', () => {
    const session = createSessionChatState();
    const toolCall: ToolCallState = {
      id: 'tool-1',
      name: 'Bash',
      status: 'success',
      input: { command: 'ls' },
      result: 'file.txt',
    } as any;
    session.toolCalls.set('tool-1', toolCall);
    session.activeTurnToolIds.add('tool-1');
    session.assistantTurns.set('turn-1', { id: 'turn-1', segments: [], timestamp: 123 });
    session.timeline.push({ kind: 'assistant-turn', turnId: 'turn-1' });
    session.isThinking = true;
    session.attentionState = 'awaiting-input';
    session.compactionPending = { startedAt: 456, beforeContextTokens: 1000 };
    const state: ChatState = new Map([['session-a', session]]);

    const serialized = serializeChatState(state);
    // Ensure JSON-safe: can survive a JSON round-trip.
    const viaJson = JSON.parse(JSON.stringify(serialized));
    const round = deserializeChatState(viaJson);

    const restored = round.get('session-a')!;
    expect(restored.toolCalls.get('tool-1')).toEqual(toolCall);
    expect(restored.activeTurnToolIds.has('tool-1')).toBe(true);
    expect(restored.assistantTurns.get('turn-1')?.timestamp).toBe(123);
    expect(restored.timeline).toEqual([{ kind: 'assistant-turn', turnId: 'turn-1' }]);
    expect(restored.isThinking).toBe(true);
    expect(restored.attentionState).toBe('awaiting-input');
    expect(restored.compactionPending).toEqual({ startedAt: 456, beforeContextTokens: 1000 });
  });
});
```

- [ ] **Step 2: Run tests to verify failure**

Run: `cd youcoded/desktop && npm test -- chat-serialization`
Expected: FAIL with "serializeChatState is not exported" or similar.

- [ ] **Step 3: Add serialization types and helpers to `chat-types.ts`**

Append to `src/renderer/state/chat-types.ts` (after the existing `createSessionChatState` function):

```ts
// ───────────────────────── Serialization ─────────────────────────
// Maps and Sets are not JSON-safe. These helpers flatten a ChatState
// into tuple arrays for transport over IPC / WebSocket, and restore
// the live structure on the other side. Used by remote-access hydration
// so a newly-connected browser can receive the desktop's full chat state
// in a single message.

export interface SerializedSessionChatState {
  timeline: TimelineEntry[];
  toolCalls: Array<[string, ToolCallState]>;
  toolGroups: Array<[string, ToolGroupState]>;
  assistantTurns: Array<[string, AssistantTurn]>;
  isThinking: boolean;
  streamingText: string;
  currentGroupId: string | null;
  currentTurnId: string | null;
  lastActivityAt: number;
  activeTurnToolIds: string[];
  attentionState: AttentionState;
  lastBufferActivityAt: number;
  compactionPending: { startedAt: number; beforeContextTokens: number | null } | null;
}

export interface SerializedChatState {
  sessions: Array<[string, SerializedSessionChatState]>;
}

export function serializeChatState(state: ChatState): SerializedChatState {
  const sessions: Array<[string, SerializedSessionChatState]> = [];
  for (const [sessionId, s] of state) {
    sessions.push([
      sessionId,
      {
        timeline: s.timeline,
        toolCalls: Array.from(s.toolCalls.entries()),
        toolGroups: Array.from(s.toolGroups.entries()),
        assistantTurns: Array.from(s.assistantTurns.entries()),
        isThinking: s.isThinking,
        streamingText: s.streamingText,
        currentGroupId: s.currentGroupId,
        currentTurnId: s.currentTurnId,
        lastActivityAt: s.lastActivityAt,
        activeTurnToolIds: Array.from(s.activeTurnToolIds),
        attentionState: s.attentionState,
        lastBufferActivityAt: s.lastBufferActivityAt,
        compactionPending: s.compactionPending,
      },
    ]);
  }
  return { sessions };
}

export function deserializeChatState(s: SerializedChatState): ChatState {
  const result: ChatState = new Map();
  for (const [sessionId, ser] of s.sessions) {
    result.set(sessionId, {
      timeline: ser.timeline,
      toolCalls: new Map(ser.toolCalls),
      toolGroups: new Map(ser.toolGroups),
      assistantTurns: new Map(ser.assistantTurns),
      isThinking: ser.isThinking,
      streamingText: ser.streamingText,
      currentGroupId: ser.currentGroupId,
      currentTurnId: ser.currentTurnId,
      lastActivityAt: ser.lastActivityAt,
      activeTurnToolIds: new Set(ser.activeTurnToolIds),
      attentionState: ser.attentionState,
      lastBufferActivityAt: ser.lastBufferActivityAt,
      compactionPending: ser.compactionPending,
    });
  }
  return result;
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd youcoded/desktop && npm test -- chat-serialization`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/renderer/state/chat-types.ts src/renderer/state/__tests__/chat-serialization.test.ts
git commit -m "feat(chat): add ChatState serialization helpers for remote hydration"
```

---

## Task 2: `HYDRATE_CHAT_STATE` reducer action + tests

**Files:**
- Modify: `src/renderer/state/chat-types.ts` (action variant)
- Modify: `src/renderer/state/chat-reducer.ts`
- Create: `src/renderer/state/__tests__/chat-hydration.test.ts`

- [ ] **Step 1: Add the action variant**

In `src/renderer/state/chat-types.ts`, find the `ChatAction` union (around line 151) and add this variant:

```ts
  | { type: 'HYDRATE_CHAT_STATE'; sessions: SerializedChatState }
```

- [ ] **Step 2: Write failing reducer test**

Create `src/renderer/state/__tests__/chat-hydration.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { chatReducer } from '../chat-reducer';
import { createSessionChatState, serializeChatState } from '../chat-types';
import type { ChatState } from '../chat-types';

describe('HYDRATE_CHAT_STATE', () => {
  it('replaces the entire ChatState map', () => {
    const existing: ChatState = new Map([['old-session', createSessionChatState()]]);

    const incoming = createSessionChatState();
    incoming.isThinking = true;
    incoming.attentionState = 'awaiting-input';
    const snapshot = serializeChatState(new Map([['new-session', incoming]]));

    const next = chatReducer(existing, { type: 'HYDRATE_CHAT_STATE', sessions: snapshot });

    expect(next.has('old-session')).toBe(false);
    expect(next.has('new-session')).toBe(true);
    expect(next.get('new-session')!.attentionState).toBe('awaiting-input');
  });

  it('leaves state untouched if deserialization throws', () => {
    const existing: ChatState = new Map([['s1', createSessionChatState()]]);
    // Malformed snapshot (sessions is not an array of tuples)
    const bad = { sessions: 'oops' } as any;
    const next = chatReducer(existing, { type: 'HYDRATE_CHAT_STATE', sessions: bad });
    expect(next).toBe(existing);
  });
});
```

- [ ] **Step 3: Run test to verify failure**

Run: `cd youcoded/desktop && npm test -- chat-hydration`
Expected: FAIL — reducer doesn't handle the action.

- [ ] **Step 4: Add reducer handler**

In `src/renderer/state/chat-reducer.ts`, add the following at the top of the `switch (action.type)` block inside `chatReducer` (find the main switch — the first case is usually `'RESET'`):

```ts
    case 'HYDRATE_CHAT_STATE': {
      try {
        // Replace the entire ChatState with a deserialized snapshot from the
        // desktop renderer. Fired once per remote-access connect so browser
        // clients see the full chat history immediately instead of rebuilding
        // it from replayed transcript events.
        return deserializeChatState(action.sessions);
      } catch (err) {
        console.error('[chat-reducer] HYDRATE_CHAT_STATE deserialize failed:', err);
        return state;
      }
    }
```

Also add `deserializeChatState` to the import from `./chat-types` at the top of the file.

- [ ] **Step 5: Run test to verify pass**

Run: `cd youcoded/desktop && npm test -- chat-hydration`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add src/renderer/state/chat-types.ts src/renderer/state/chat-reducer.ts src/renderer/state/__tests__/chat-hydration.test.ts
git commit -m "feat(chat): HYDRATE_CHAT_STATE reducer action for remote snapshot"
```

---

## Task 3: IPC channel constants + preload surface

**Files:**
- Modify: `src/main/preload.ts`

Add three new IPC channels. `chat:export-snapshot` is a main→renderer push (renderer listens); `chat:snapshot-response` is the renderer's reply; `remote:attention-changed` is renderer→main fire.

- [ ] **Step 1: Add channel constants**

In `src/main/preload.ts`, add these entries to the `IPC` object (location near the other string constants, ~line 70):

```ts
  CHAT_EXPORT_SNAPSHOT: 'chat:export-snapshot',
  CHAT_SNAPSHOT_RESPONSE: 'chat:snapshot-response',
  REMOTE_ATTENTION_CHANGED: 'remote:attention-changed',
```

- [ ] **Step 2: Expose renderer-side bindings on `window.claude`**

Find the `contextBridge.exposeInMainWorld('claude', ...)` block in preload.ts. Add these methods alongside the existing ones (group them near other `chat:` or `remote:` entries for consistency):

```ts
    onChatExportSnapshot: (cb: (requestId: string) => void) => {
      const handler = (_e: IpcRendererEvent, requestId: string) => cb(requestId);
      ipcRenderer.on(IPC.CHAT_EXPORT_SNAPSHOT, handler);
      return () => ipcRenderer.off(IPC.CHAT_EXPORT_SNAPSHOT, handler);
    },
    sendChatSnapshotResponse: (payload: { requestId: string; snapshot: unknown }) =>
      ipcRenderer.send(IPC.CHAT_SNAPSHOT_RESPONSE, payload),
    fireRemoteAttentionChanged: (payload: { sessionId: string; state: string }) =>
      ipcRenderer.send(IPC.REMOTE_ATTENTION_CHANGED, payload),
```

Note: these are Electron-only surfaces (the main process is where remote clients live). The remote-shim parity requirement does not apply — remote browsers serve `chat:hydrate` via WebSocket directly and do not need these IPC shims.

- [ ] **Step 3: Commit**

```bash
git add src/main/preload.ts
git commit -m "feat(ipc): preload channels for chat snapshot + attention sync"
```

---

## Task 4: Renderer-side snapshot exporter

**Files:**
- Create: `src/renderer/components/RemoteSnapshotExporter.tsx`
- Modify: `src/renderer/App.tsx` (mount the exporter)

A mount-only component that holds a ref to the latest `ChatState`, listens for `chat:export-snapshot` requests, and fires the serialized snapshot back. Separated into its own component so the App.tsx diff is minimal and the exporter's lifecycle is explicit.

- [ ] **Step 1: Create the component**

Create `src/renderer/components/RemoteSnapshotExporter.tsx`:

```tsx
import { useEffect, useRef } from 'react';
import { useChatStateMap } from '../state/chat-context';
import { serializeChatState } from '../state/chat-types';

/**
 * Mount-only component. Holds a ref to the latest ChatState, listens for
 * `chat:export-snapshot` from the main process, and sends the serialized
 * snapshot back. Used by the remote-access server to hand a freshly-connected
 * browser client the full chat history in a single message.
 *
 * Only active in Electron (window.claude.onChatExportSnapshot is undefined
 * in the WebSocket remote shim).
 */
export function RemoteSnapshotExporter() {
  const chatState = useChatStateMap();
  const chatStateRef = useRef(chatState);

  useEffect(() => {
    chatStateRef.current = chatState;
  }, [chatState]);

  useEffect(() => {
    const api = (window as any).claude;
    if (typeof api?.onChatExportSnapshot !== 'function') return;

    const unsubscribe = api.onChatExportSnapshot((requestId: string) => {
      try {
        const snapshot = serializeChatState(chatStateRef.current);
        api.sendChatSnapshotResponse({ requestId, snapshot });
      } catch (err) {
        console.error('[RemoteSnapshotExporter] serialize failed:', err);
        api.sendChatSnapshotResponse({ requestId, snapshot: { sessions: [] } });
      }
    });

    return unsubscribe;
  }, []);

  return null;
}
```

- [ ] **Step 2: Mount it in App.tsx**

In `src/renderer/App.tsx`, add the import near the top:

```tsx
import { RemoteSnapshotExporter } from './components/RemoteSnapshotExporter';
```

Then mount the component once inside the root JSX tree, anywhere under the `ChatProvider`. A good place is next to other mount-only utility components (search App.tsx for similar sentinels such as `<UsageMeter>` or similar invisible components). If no clear home exists, add it at the top of the main return:

```tsx
<>
  <RemoteSnapshotExporter />
  {/* ...existing tree... */}
</>
```

- [ ] **Step 3: Verify build**

Run: `cd youcoded/desktop && npm run build`
Expected: Build succeeds, no TS errors.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/components/RemoteSnapshotExporter.tsx src/renderer/App.tsx
git commit -m "feat(remote): renderer-side chat snapshot exporter"
```

---

## Task 5: Main-process `requestChatSnapshot` helper

**Files:**
- Modify: `src/main/ipc-handlers.ts`
- Modify: `src/main/remote-server.ts` (inject the helper on construction)

The remote server needs a way to ask the renderer for the current snapshot. This helper encapsulates the round-trip: send export request with a unique id, wait (with timeout) for the matching response, resolve.

- [ ] **Step 1: Add the helper near the top of ipc-handlers.ts or in a new file**

Decide based on ipc-handlers.ts length. If it's already large, create a new file `src/main/chat-snapshot.ts`:

```ts
import { ipcMain, WebContents } from 'electron';
import type { SerializedChatState } from '../renderer/state/chat-types';

const EXPORT_CHANNEL = 'chat:export-snapshot';
const RESPONSE_CHANNEL = 'chat:snapshot-response';
const TIMEOUT_MS = 2000;

/**
 * Request a serialized ChatState snapshot from a renderer webContents.
 * Resolves with { sessions: [] } if the renderer doesn't respond within
 * 2s (e.g. still booting). Used by the remote-access server to hand new
 * browser clients the full chat history on connect.
 */
export function requestChatSnapshot(webContents: WebContents): Promise<SerializedChatState> {
  const requestId = `snap-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  return new Promise((resolve) => {
    let settled = false;
    const onResponse = (_e: Electron.IpcMainEvent, payload: { requestId: string; snapshot: SerializedChatState }) => {
      if (settled || payload.requestId !== requestId) return;
      settled = true;
      ipcMain.off(RESPONSE_CHANNEL, onResponse);
      clearTimeout(timer);
      resolve(payload.snapshot);
    };
    ipcMain.on(RESPONSE_CHANNEL, onResponse);
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      ipcMain.off(RESPONSE_CHANNEL, onResponse);
      console.warn('[chat-snapshot] export timed out, returning empty snapshot');
      resolve({ sessions: [] });
    }, TIMEOUT_MS);
    try {
      webContents.send(EXPORT_CHANNEL, requestId);
    } catch (err) {
      console.error('[chat-snapshot] send failed:', err);
      if (!settled) {
        settled = true;
        ipcMain.off(RESPONSE_CHANNEL, onResponse);
        clearTimeout(timer);
        resolve({ sessions: [] });
      }
    }
  });
}
```

- [ ] **Step 2: Wire it into the RemoteServer constructor**

In `src/main/remote-server.ts`, find the constructor / setup code for the `RemoteServer` class and add a property:

```ts
  private requestSnapshot: () => Promise<SerializedChatState>;
```

Accept it as a constructor arg (or setter), so the server does not have a direct dependency on a specific `webContents`:

```ts
  constructor(/* existing args... */, opts: { requestSnapshot: () => Promise<SerializedChatState> }) {
    // existing init
    this.requestSnapshot = opts.requestSnapshot;
  }
```

Import `SerializedChatState` at top of file:

```ts
import type { SerializedChatState } from '../renderer/state/chat-types';
```

- [ ] **Step 3: Construct the server with the snapshot provider**

Find the `RemoteServer` instantiation site in `ipc-handlers.ts` (or wherever it's currently created). The call must pass a closure that uses the main window's webContents:

```ts
import { requestChatSnapshot } from './chat-snapshot';
// ... at RemoteServer instantiation:
remoteServer = new RemoteServer(/* existing args */, {
  requestSnapshot: () => requestChatSnapshot(mainWindow.webContents),
});
```

If `mainWindow` is not in scope at the instantiation site, pass it through from whatever created both (usually `main.ts` or `index.ts`).

- [ ] **Step 4: Verify build**

Run: `cd youcoded/desktop && npm run build`
Expected: Build passes.

- [ ] **Step 5: Commit**

```bash
git add src/main/chat-snapshot.ts src/main/remote-server.ts src/main/ipc-handlers.ts
git commit -m "feat(remote): main-process helper to fetch chat snapshot from renderer"
```

---

## Task 6: Send `chat:hydrate` in `replayBuffers()`

**Files:**
- Modify: `src/main/remote-server.ts`

Insert the snapshot fetch + send between session metadata and the 500ms-delayed PTY/hook replay.

- [ ] **Step 1: Patch `replayBuffers()`**

In `src/main/remote-server.ts`, find `replayBuffers(ws: WebSocket)` (around line 449). Convert it to async (it currently uses `setTimeout`, which is fine to keep) and insert the hydrate step after the metadata section (after the `for (const [desktopId, name] of this.lastTopics)` loop) and before `setTimeout(() => { ... }, 500)`:

```ts
  private async replayBuffers(ws: WebSocket): Promise<void> {
    // ... existing session list + metadata code stays unchanged ...

    // NEW: request a snapshot of the desktop's chat reducer state and push it
    // to the connecting client so they see the full chat history immediately.
    // Must happen before PTY/hook replay so the reducer has state to merge
    // subsequent transcript events into.
    try {
      const snapshot = await this.requestSnapshot();
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'chat:hydrate', payload: snapshot }));
      }
    } catch (err) {
      console.error('[remote-server] chat:hydrate failed:', err);
    }

    // existing setTimeout with PTY + hook replay stays unchanged
    setTimeout(() => { /* ... */ }, 500);
  }
```

Ensure the call site that invokes `replayBuffers()` handles the Promise (add a `.catch` logging path if it was previously sync-called; search the file for `replayBuffers(` to find all call sites).

- [ ] **Step 2: Verify build**

Run: `cd youcoded/desktop && npm run build`
Expected: Build passes.

- [ ] **Step 3: Commit**

```bash
git add src/main/remote-server.ts
git commit -m "feat(remote): push chat:hydrate snapshot to new WebSocket clients"
```

---

## Task 7: Remote shim — handle `chat:hydrate` push

**Files:**
- Modify: `src/renderer/remote-shim.ts`

- [ ] **Step 1: Add a dispatch case**

In `src/renderer/remote-shim.ts`, find the WebSocket message handler `switch (msg.type)` (around line 151). Add a case for `chat:hydrate`:

```ts
    case 'chat:hydrate':
      dispatchEvent('chat:hydrate', payload);
      break;
```

- [ ] **Step 2: Expose the listener on `window.claude`**

In the same file, find the section where listeners are wired onto `window.claude` (around line 552). Add:

```ts
      chatHydrate: (cb: Callback) => addListener('chat:hydrate', cb),
```

- [ ] **Step 3: Wire the listener into App.tsx so it dispatches to the reducer**

In `src/renderer/App.tsx`, find where other `window.claude.on*` listeners are registered (search for `statusData` or `transcriptEvent` registration). Add:

```tsx
useEffect(() => {
  if (typeof window.claude.chatHydrate !== 'function') return;
  const unsub = window.claude.chatHydrate((payload: any) => {
    chatDispatch({ type: 'HYDRATE_CHAT_STATE', sessions: payload });
  });
  return unsub;
}, [chatDispatch]);
```

Use whichever identifier the file already uses for the chat dispatch (e.g., `chatDispatch`, `dispatch`).

- [ ] **Step 4: Verify build + existing tests**

Run: `cd youcoded/desktop && npm run build && npm test`
Expected: Build + all tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/remote-shim.ts src/renderer/App.tsx
git commit -m "feat(remote): apply chat:hydrate snapshot on remote clients"
```

---

## Task 8: `useRemoteAttentionSync` hook

**Files:**
- Create: `src/renderer/hooks/useRemoteAttentionSync.ts`
- Modify: `src/renderer/App.tsx` (or `ChatView.tsx` — wherever `useAttentionClassifier` is called)

- [ ] **Step 1: Create the hook**

Create `src/renderer/hooks/useRemoteAttentionSync.ts`:

```ts
import { useEffect, useRef } from 'react';
import { useChatStateMap } from '../state/chat-context';
import type { AttentionState } from '../state/chat-types';

/**
 * Fires `remote:attention-changed` over IPC when any session's attentionState
 * diffs from the previous tick. Lets the main process maintain a per-session
 * cache for the remote-access status:data broadcast, so browser clients see
 * StatusDot colors that match the desktop in near-real-time (rather than
 * running their own PTY classifier and risking drift).
 */
export function useRemoteAttentionSync() {
  const chatState = useChatStateMap();
  const lastByIdRef = useRef<Map<string, AttentionState>>(new Map());

  useEffect(() => {
    const api = (window as any).claude;
    if (typeof api?.fireRemoteAttentionChanged !== 'function') return;

    const last = lastByIdRef.current;
    for (const [sessionId, session] of chatState) {
      const prev = last.get(sessionId);
      if (prev !== session.attentionState) {
        last.set(sessionId, session.attentionState);
        api.fireRemoteAttentionChanged({ sessionId, state: session.attentionState });
      }
    }
    // Clean up removed sessions so we don't keep stale entries in the ref.
    for (const sessionId of Array.from(last.keys())) {
      if (!chatState.has(sessionId)) last.delete(sessionId);
    }
  }, [chatState]);
}
```

- [ ] **Step 2: Call the hook once from App.tsx**

In `src/renderer/App.tsx`, add the import:

```tsx
import { useRemoteAttentionSync } from './hooks/useRemoteAttentionSync';
```

And call it inside the main `App` component (near other top-level hooks):

```tsx
useRemoteAttentionSync();
```

- [ ] **Step 3: Verify build**

Run: `cd youcoded/desktop && npm run build`
Expected: Passes.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/hooks/useRemoteAttentionSync.ts src/renderer/App.tsx
git commit -m "feat(remote): sync attentionState changes from renderer to main"
```

---

## Task 9: Main-process attention cache + `attentionMap` in `status:data`

**Files:**
- Modify: `src/main/ipc-handlers.ts`

- [ ] **Step 1: Add the cache and IPC listener**

In `src/main/ipc-handlers.ts`, near the top of the main `registerIpcHandlers` function (or wherever other module-level maps live), add:

```ts
  // Per-session attention state, updated by the renderer via
  // `remote:attention-changed` and read by buildStatusData() so remote
  // browsers see matching StatusDot colors.
  const lastAttentionBySession = new Map<string, string>();

  ipcMain.on('remote:attention-changed', (_e, payload: { sessionId: string; state: string }) => {
    if (!payload?.sessionId) return;
    lastAttentionBySession.set(payload.sessionId, payload.state);
    // Broadcast immediately so remote clients see the change without waiting
    // for the 10s status:data timer. Payload rebuild is cheap (~ms).
    if (remoteServer && remoteServer.hasClients?.()) {
      const data = buildStatusData();
      remoteServer.broadcastStatusData(data);
    }
  });
```

Note: `remoteServer.hasClients?.()` — if that method doesn't exist yet, skip the guard (just always call `broadcastStatusData`). It's cheap.

- [ ] **Step 2: Include `attentionMap` in `buildStatusData()` return**

Find `buildStatusData()` (around line 1203). Extend the returned object:

```ts
    const attentionMap: Record<string, string> = {};
    for (const [desktopId] of sessionIdMap) {
      const state = lastAttentionBySession.get(desktopId);
      if (state) attentionMap[desktopId] = state;
    }

    return {
      usage, announcement, updateStatus, syncStatus, syncWarnings, lastSyncEpoch,
      syncInProgress, backupMeta, contextMap, gitBranchMap, sessionStatsMap,
      attentionMap,  // NEW
    };
```

- [ ] **Step 3: Clear cache on session exit**

Find the session-destroyed handler (likely in remote-server or session-manager) and clean up:

```ts
lastAttentionBySession.delete(sessionId);
```

If the cleanup site is not in ipc-handlers.ts (where the cache lives), export a small `clearAttention(sessionId)` helper from ipc-handlers.ts or move the map into a small shared module. Either approach is fine; prefer the smallest diff.

- [ ] **Step 4: Verify build**

Run: `cd youcoded/desktop && npm run build`
Expected: Passes.

- [ ] **Step 5: Commit**

```bash
git add src/main/ipc-handlers.ts
git commit -m "feat(remote): cache attentionState + include in status:data broadcast"
```

---

## Task 10: Remote shim — diff `attentionMap` and dispatch

**Files:**
- Modify: `src/renderer/remote-shim.ts`
- Modify: `src/renderer/App.tsx` (or whichever file already handles `status:data`)

- [ ] **Step 1: Track last-seen attentionMap per remote client**

The shim already re-broadcasts `status:data` to listeners. The diff step lives wherever the subscriber applies it to state. Find the existing `statusData` listener registration in `App.tsx` (search for `statusData`).

Modify the handler to diff `attentionMap` against a ref and dispatch per-session `ATTENTION_STATE_CHANGED` for any changed session:

```tsx
const prevAttentionRef = useRef<Record<string, string>>({});

useEffect(() => {
  const unsub = window.claude.onStatusData?.((data: any) => {
    // ... existing logic that updates statusData state ...

    const incoming = (data?.attentionMap ?? {}) as Record<string, string>;
    const prev = prevAttentionRef.current;
    for (const [sessionId, state] of Object.entries(incoming)) {
      if (prev[sessionId] !== state) {
        chatDispatch({
          type: 'ATTENTION_STATE_CHANGED',
          sessionId,
          state: state as any,
        });
      }
    }
    prevAttentionRef.current = incoming;
  });
  return unsub;
}, [chatDispatch]);
```

Use the exact listener name the existing code uses for status:data — `onStatusData` above is illustrative. Read the surrounding file first and match style.

Note: on the Electron desktop, `ATTENTION_STATE_CHANGED` is dispatched locally by `useAttentionClassifier` reading the xterm buffer. This diff step is a no-op on desktop because the attentionMap coming through IPC matches what's already in the reducer. On remote browsers the classifier hook does not run (no live xterm access to the desktop PTY), so this is the only path that sets attentionState. Correctness: the diff prevents redundant reducer dispatches.

- [ ] **Step 2: Verify build + tests**

Run: `cd youcoded/desktop && npm run build && npm test`
Expected: Passes.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/App.tsx
git commit -m "feat(remote): dispatch ATTENTION_STATE_CHANGED from status:data payload"
```

---

## Task 11: Cleanup — remove dead transcript-buffer path

**Files:**
- Modify: `src/main/remote-server.ts`
- Modify: `src/main/ipc-handlers.ts`

Now that `chat:hydrate` carries the full reducer state, the parallel `transcriptBuffers` + replay in `replayBuffers()` is redundant. Remove it to avoid confusion.

- [ ] **Step 1: Remove the buffer + replay**

In `src/main/remote-server.ts`:
- Delete the `private transcriptBuffers = new Map<string, any[]>();` field declaration.
- Delete `this.transcriptBuffers.clear()` (around line 181).
- Delete `this.transcriptBuffers.delete(sessionId)` in `onSessionExit` (around line 270).
- Delete the whole `bufferTranscriptEvent(event)` method (lines 277-285).
- Delete the transcript replay block inside `setTimeout` of `replayBuffers` (lines 487-492).

In `src/main/ipc-handlers.ts`:
- Delete the `remoteServer.bufferTranscriptEvent(event);` line (around line 1313). Keep `remoteServer.broadcast({ type: 'transcript:event', ... })` — live events still stream.

- [ ] **Step 2: Verify build + tests**

Run: `cd youcoded/desktop && npm run build && npm test`
Expected: Passes.

- [ ] **Step 3: Commit**

```bash
git add src/main/remote-server.ts src/main/ipc-handlers.ts
git commit -m "refactor(remote): drop dead transcript-buffer replay (superseded by chat:hydrate)"
```

---

## Task 12: Manual integration test

Automated E2E of the remote-access flow isn't set up in this repo, so the final verification is manual. Confirm both issues are fixed end-to-end.

- [ ] **Step 1: Start desktop in dev mode**

```bash
cd youcoded-dev
bash scripts/run-dev.sh
```

- [ ] **Step 2: Create activity in the dev desktop window**

- Open a session.
- Send a user message.
- Wait for Claude to run at least one tool call.
- Wait for completion so the chat has real timeline entries.

- [ ] **Step 3: Connect a remote browser**

- In the dev window's Settings → Remote Access, note the port (e.g. 9950).
- Open `http://localhost:9950` in a fresh browser window.
- Authenticate.

- [ ] **Step 4: Verify chat history appears immediately**

Expected: within ~1s of auth, the remote browser's chat view shows the same user messages, assistant text, tool cards, and tool results as the desktop. No reload needed. No gaps.

- [ ] **Step 5: Verify attention state matches**

- In the desktop, send a prompt that puts Claude in an awaiting-input state (e.g., ask it to ask you a question).
- Watch the StatusDot / AttentionBanner on both desktop and remote.

Expected: both show the same state within ~1s. The amber banner appears on remote when it appears on desktop.

- [ ] **Step 6: Verify with multiple sessions**

- Open a second session on the desktop.
- Switch between sessions on the remote.

Expected: each session on the remote shows the correct chat history and attention state.

- [ ] **Step 7: Verify dead-state cleanup**

- Kill the Claude process for a session (from the desktop UI).
- Check the remote's StatusDot within a few seconds.

Expected: the 'session-died' banner appears on remote to match desktop.

- [ ] **Step 8: Close the dev window**

---

## Post-implementation checklist

- [ ] All unit tests pass (`npm test` in `youcoded/desktop`).
- [ ] Build succeeds (`npm run build`).
- [ ] Manual integration test in Task 12 passes.
- [ ] No leftover `transcriptBuffers` references (grep for it — expect zero hits in `src/`).
- [ ] `docs/PITFALLS.md` updated with any new invariants if a future reader might trip on them (e.g., "Remote clients get chat state via `chat:hydrate` on connect — don't add parallel replay paths").
