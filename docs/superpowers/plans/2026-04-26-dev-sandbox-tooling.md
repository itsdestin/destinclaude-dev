# Dev Sandbox & Testing Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a unified developer workbench (`?mode=workbench`) with three browser tabs (Tool cards / Conversations / Theme cycle), a pure-node snapshot script for Claude-driven regression checks, a JSONL transcript redactor + curated real-anonymized bundle, and a CC-coupling probe library catalog.

**Architecture:** Two surfaces. Browser side = a Vite/Electron React app at `?mode=workbench` housing three tabs that share a `ScenarioProvider`; status bar rides atop conversations. Node side = standalone scripts (`snapshot.js`, `redact-transcript.js`) plus `test-conpty/` probes catalogued via `INDEX.md`. Production code is touched only via a one-line re-export shim for the transcript parser.

**Tech Stack:** React 19, TypeScript, Vite, Electron, Vitest, node-pty (probes only). All logic in TypeScript except probes (`.mjs`) and dev-tools scripts (`.js` for direct node invocation).

**Spec:** `docs/superpowers/specs/2026-04-26-dev-sandbox-tooling-design.md`. Read it first.

**Note on adjustment during implementation:** Some downstream phases (especially #6–#7) make assumptions about scenario content and probe specifics that will be sharper once #1–#4 are in motion. If a downstream task's premise turns out wrong (e.g., a sidecar field needs renaming because of how ScenarioProvider actually consumes it), update later tasks inline rather than fighting the plan.

---

## Phase 1 — Workbench shell

Pure restructure. The end state is `?mode=workbench` rendering a left-nav-only shell with one working tab (Tools, which is today's `ToolSandbox` unchanged). `?mode=tool-sandbox` continues to work as a deep-link to that tab.

### Task 1.1: Workspace-root launcher script

**Files:**
- Create: `scripts/run-workbench.sh`

- [ ] **Step 1: Create the launcher**

Mirrors `scripts/run-sandbox.sh`. Same port-offset isolation and dev profile, but loads `?mode=workbench`.

```bash
#!/bin/bash
# Launch a dev instance of YouCoded that boots straight into the unified
# developer workbench (?mode=workbench). See
# docs/superpowers/specs/2026-04-26-dev-sandbox-tooling-design.md.
set -euo pipefail

cd "$(dirname "$0")/.."

export YOUCODED_PORT_OFFSET="${YOUCODED_PORT_OFFSET:-50}"
export YOUCODED_PROFILE=dev
export YOUCODED_DEV_URL="http://localhost:$((5173 + YOUCODED_PORT_OFFSET))/?mode=workbench"

echo "Starting YouCoded dev in workbench mode (port offset: $YOUCODED_PORT_OFFSET)..."
echo "  Vite:  http://localhost:$((5173 + YOUCODED_PORT_OFFSET))"
echo "  Loads: $YOUCODED_DEV_URL"
echo ""
cd youcoded/desktop
npm run dev
```

- [ ] **Step 2: Make it executable (Windows-friendly)**

```bash
chmod +x scripts/run-workbench.sh
git update-index --chmod=+x scripts/run-workbench.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/run-workbench.sh
git commit -m "feat(workbench): add run-workbench.sh launcher"
```

### Task 1.2: WorkbenchShell scaffold + route gate

**Files:**
- Create: `youcoded/desktop/src/renderer/dev/workbench/WorkbenchShell.tsx`
- Modify: `youcoded/desktop/src/renderer/App.tsx` (around line 2340–2350)

- [ ] **Step 1: Create the shell component**

Minimal scaffold with no tabs yet — just a left-nav stub and a placeholder content area. Tabs come in Task 1.3.

```tsx
// youcoded/desktop/src/renderer/dev/workbench/WorkbenchShell.tsx
//
// Dev-only unified workbench. Hosts three tabs:
//   - Tools          (the existing ToolCard fixture grid)
//   - Conversations  (full chat scenarios; status bar rides along)
//   - Theme cycle    (synthetic transcript across every theme)
//
// Gated behind ?mode=workbench in App.tsx, dev-only via import.meta.env.DEV.

import React, { useState } from 'react';

type TabId = 'tools' | 'conversations' | 'themes';

const TABS: { id: TabId; label: string }[] = [
  { id: 'tools', label: 'Tool cards' },
  { id: 'conversations', label: 'Conversations' },
  { id: 'themes', label: 'Theme cycle' },
];

export function WorkbenchShell() {
  // ?mode=tool-sandbox is the legacy deep-link to the Tools tab.
  const initialTab: TabId =
    new URLSearchParams(location.search).get('mode') === 'tool-sandbox'
      ? 'tools'
      : 'tools';
  const [activeTab, setActiveTab] = useState<TabId>(initialTab);

  return (
    <div style={{ height: '100vh', display: 'flex', overflow: 'hidden' }}>
      <nav
        style={{
          width: 200,
          flexShrink: 0,
          borderRight: '1px solid var(--edge-dim, #333)',
          padding: '16px 0',
          overflowY: 'auto',
        }}
      >
        <div
          style={{
            fontSize: 11,
            opacity: 0.5,
            textTransform: 'uppercase',
            padding: '0 16px 8px',
            letterSpacing: 0.5,
          }}
        >
          Workbench
        </div>
        {TABS.map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            style={{
              display: 'block',
              width: '100%',
              textAlign: 'left',
              padding: '8px 16px',
              background: activeTab === tab.id ? 'var(--bg-inset, #222)' : 'transparent',
              border: 'none',
              color: 'inherit',
              cursor: 'pointer',
              fontSize: 14,
            }}
          >
            {tab.label}
          </button>
        ))}
      </nav>
      <main style={{ flex: 1, overflow: 'auto' }}>
        <div style={{ padding: 24 }}>
          <p style={{ opacity: 0.6 }}>Tab: {activeTab}</p>
          <p style={{ opacity: 0.4, fontSize: 13 }}>
            Tabs are scaffolded in subsequent tasks.
          </p>
        </div>
      </main>
    </div>
  );
}
```

- [ ] **Step 2: Add the `workbench` route gate to App.tsx**

Locate the existing `?mode=tool-sandbox` block (around line 2343) and add a sibling `?mode=workbench` block above it. Both are dev-only.

```tsx
// In App.tsx around line 2343, BEFORE the existing tool-sandbox gate:

// @ts-ignore TS1343 — import.meta is intercepted by Vite at build time
if (import.meta.env.DEV && buddyMode === 'workbench') {
  return <WorkbenchShellRoute />;
}

// (The existing tool-sandbox gate stays — Tools tab will absorb it in Task 1.4)
```

Add the `WorkbenchShellRoute` lazy import near the other dev-only imports at top of App.tsx (search for `ToolSandboxRoute` to find the pattern):

```tsx
const WorkbenchShellRoute = React.lazy(() =>
  import('./dev/workbench/WorkbenchShell').then((m) => ({ default: m.WorkbenchShell }))
);
```

- [ ] **Step 3: Smoke-test the route locally**

```bash
bash scripts/run-workbench.sh
```

Expected: dev window opens, left-nav shows three tabs, content area shows "Tab: tools". Clicking each tab updates the label.

- [ ] **Step 4: Commit**

```bash
git add youcoded/desktop/src/renderer/dev/workbench/WorkbenchShell.tsx \
        youcoded/desktop/src/renderer/App.tsx
git commit -m "feat(workbench): scaffold WorkbenchShell + ?mode=workbench gate"
```

### Task 1.3: Move ToolSandbox under workbench as Tools tab

**Files:**
- Create: `youcoded/desktop/src/renderer/dev/workbench/tabs/ToolCardsTab.tsx`
- Modify: `youcoded/desktop/src/renderer/dev/workbench/WorkbenchShell.tsx`

- [ ] **Step 1: Create thin re-exporting tab component**

```tsx
// youcoded/desktop/src/renderer/dev/workbench/tabs/ToolCardsTab.tsx
//
// Wraps the existing ToolSandbox so the Tools tab inside the workbench
// shows the same per-tool fixture grid. The original ToolSandbox stays at
// dev/ToolSandbox.tsx and is also reachable via ?mode=tool-sandbox for
// back-compat.

import React from 'react';
import { ToolSandbox } from '../../ToolSandbox';

export function ToolCardsTab() {
  return <ToolSandbox />;
}
```

- [ ] **Step 2: Wire the tab into WorkbenchShell**

Replace the placeholder `<main>` content in WorkbenchShell.tsx with a switch on `activeTab`:

```tsx
// In WorkbenchShell.tsx, replace the existing <main> body:

import { ToolCardsTab } from './tabs/ToolCardsTab';

// ... inside WorkbenchShell:
<main style={{ flex: 1, overflow: 'auto' }}>
  {activeTab === 'tools' && <ToolCardsTab />}
  {activeTab === 'conversations' && (
    <div style={{ padding: 24, opacity: 0.5 }}>Coming in Phase 3.</div>
  )}
  {activeTab === 'themes' && (
    <div style={{ padding: 24, opacity: 0.5 }}>Coming in Phase 5.</div>
  )}
</main>
```

- [ ] **Step 3: Verify both routes work**

```bash
bash scripts/run-workbench.sh
```

- Visit `http://localhost:5223/?mode=workbench` → Tools tab shows the fixture grid.
- Visit `http://localhost:5223/?mode=tool-sandbox` → still shows the standalone fixture grid (legacy route preserved).

- [ ] **Step 4: Commit**

```bash
git add youcoded/desktop/src/renderer/dev/workbench/tabs/ToolCardsTab.tsx \
        youcoded/desktop/src/renderer/dev/workbench/WorkbenchShell.tsx
git commit -m "feat(workbench): wire Tools tab to existing ToolSandbox"
```

---

## Phase 2 — Parser re-export shim

Trivial; just gives the snapshot script a stable address to import the parser from. Production code paths are untouched — existing parity tests keep passing because they import from the original location.

### Task 2.1: Add the shim file

**Files:**
- Create: `youcoded/desktop/src/shared/transcript-parser.ts`

- [ ] **Step 1: Write the shim**

```ts
// youcoded/desktop/src/shared/transcript-parser.ts
//
// Stable re-export address for the transcript parser. The implementation
// lives in src/main/transcript-watcher.ts; this shim lets dev-tools scripts
// (snapshot.js, smoke tests) import without reaching into src/main/.
//
// If the parser is ever moved out of transcript-watcher.ts, update only
// this file — every dev-tools consumer keeps working.

export { parseTranscriptLine, cwdToProjectSlug } from '../main/transcript-watcher';
```

- [ ] **Step 2: Verify parity tests still pass**

```bash
cd youcoded/desktop && npm test -- transcript-parity
```

Expected: PASS. The parity tests import from `src/main/transcript-watcher.ts` directly, so the shim is additive and shouldn't change anything.

- [ ] **Step 3: Verify the shim itself imports correctly**

```bash
cd youcoded/desktop && npx tsc --noEmit
```

Expected: no TypeScript errors.

- [ ] **Step 4: Commit**

```bash
git add youcoded/desktop/src/shared/transcript-parser.ts
git commit -m "feat(workbench): add shared transcript-parser re-export shim"
```

---

## Phase 3 — Conversations tab (synthetic only)

This phase delivers: synthetic JSONL + sidecar, `ScenarioProvider`, scenario picker, drag-drop, full chat frame rendering. By the end, you can pick a scenario in the workbench and see the chat render with status bar, attention banner, and any permission/error states baked into the synthetic.

### Task 3.1: Default scenario state constant + types

**Files:**
- Create: `youcoded/desktop/src/renderer/dev/workbench/scenario-types.ts`

- [ ] **Step 1: Define types and defaults**

```ts
// youcoded/desktop/src/renderer/dev/workbench/scenario-types.ts
//
// Shape of a scenario sidecar JSON file. All fields optional — missing
// fields use DEFAULT_SCENARIO_STATE.

export interface ScenarioState {
  model: string;
  cwd: string;
  gitBranch: string;
  contextUsedPct: number;
  todos: ScenarioTodo[];
  subagents: ScenarioSubagent[];
  announcement: string | null;
  syncWarnings: ScenarioSyncWarning[];
  attentionState: 'ok' | 'stuck' | 'session-died';
  permissionMode: 'normal' | 'auto-accept' | 'plan' | 'bypass';
}

export interface ScenarioTodo {
  id: string;
  text: string;
  status: 'pending' | 'in_progress' | 'completed';
}

export interface ScenarioSubagent {
  id: string;
  name: string;
  status: 'running' | 'completed' | 'failed';
}

export interface ScenarioSyncWarning {
  code: string;
  message: string;
  backendId?: string;
  dismissible: boolean;
}

export const DEFAULT_SCENARIO_STATE: ScenarioState = {
  model: 'claude-opus-4-7',
  cwd: '/redacted/scenario',
  gitBranch: 'master',
  contextUsedPct: 0,
  todos: [],
  subagents: [],
  announcement: null,
  syncWarnings: [],
  attentionState: 'ok',
  permissionMode: 'normal',
};

export function mergeScenarioState(partial: Partial<ScenarioState> | null | undefined): ScenarioState {
  return { ...DEFAULT_SCENARIO_STATE, ...(partial ?? {}) };
}
```

- [ ] **Step 2: Commit**

```bash
git add youcoded/desktop/src/renderer/dev/workbench/scenario-types.ts
git commit -m "feat(workbench): define ScenarioState types + defaults"
```

### Task 3.2: Test the JSONL→reducer-actions replay

**Files:**
- Create: `youcoded/desktop/src/renderer/dev/workbench/scenario-replay.ts`
- Create: `youcoded/desktop/tests/scenario-replay.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// youcoded/desktop/tests/scenario-replay.test.ts
import { describe, it, expect } from 'vitest';
import { replayScenarioJsonl } from '../src/renderer/dev/workbench/scenario-replay';

describe('replayScenarioJsonl', () => {
  it('produces a chat state with one user + one assistant turn from a minimal session', () => {
    // Two-line JSONL: a user message, then an assistant text response.
    const jsonl = [
      JSON.stringify({
        type: 'user',
        uuid: 'u1',
        sessionId: 's1',
        timestamp: '2026-04-26T00:00:00Z',
        message: { role: 'user', content: 'hi' },
      }),
      JSON.stringify({
        type: 'assistant',
        uuid: 'a1',
        sessionId: 's1',
        timestamp: '2026-04-26T00:00:01Z',
        message: {
          role: 'assistant',
          model: 'claude-opus-4-7',
          content: [{ type: 'text', text: 'hello' }],
        },
      }),
    ].join('\n');

    const state = replayScenarioJsonl(jsonl, 'scenario-test');

    // Session was initialized.
    expect(state.has('scenario-test')).toBe(true);
    const session = state.get('scenario-test')!;

    // Timeline contains one user entry.
    const userEntries = session.userTimeline.filter((e) => e.text === 'hi');
    expect(userEntries.length).toBe(1);

    // Assistant text was captured.
    expect(session.assistantTurns.length).toBeGreaterThan(0);
  });

  it('returns an empty session for empty input', () => {
    const state = replayScenarioJsonl('', 'empty');
    expect(state.has('empty')).toBe(true);
    expect(state.get('empty')!.userTimeline.length).toBe(0);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd youcoded/desktop && npm test -- scenario-replay
```

Expected: FAIL — module not found.

- [ ] **Step 3: Write the replay function**

```ts
// youcoded/desktop/src/renderer/dev/workbench/scenario-replay.ts
//
// Pure function: take a JSONL transcript string and produce the final
// ChatState by dispatching parsed events through the chat reducer.
// No DOM, no async, no IPC — same logic that runs in src/main/transcript-watcher
// for live sessions, but driven by a static input.

import { parseTranscriptLine } from '../../../shared/transcript-parser';
import { chatReducer } from '../../state/chat-reducer';
import type { ChatState, ChatAction } from '../../state/chat-types';
import type { TranscriptEvent } from '../../../shared/types';

export function replayScenarioJsonl(jsonl: string, sessionId: string): ChatState {
  let state: ChatState = new Map();

  // Initialize the session so TRANSCRIPT_* actions have a target.
  state = chatReducer(state, { type: 'SESSION_INIT', sessionId });

  const lines = jsonl.split('\n').map((l) => l.trim()).filter(Boolean);
  for (const line of lines) {
    let events: TranscriptEvent[];
    try {
      events = parseTranscriptLine(line, sessionId);
    } catch {
      // Skip malformed lines — same behavior as the live watcher (it logs
      // and continues). The smoke test catches systemic breakage.
      continue;
    }
    for (const event of events) {
      const action = transcriptEventToAction(event, sessionId);
      if (action) state = chatReducer(state, action);
    }
  }

  return state;
}

// Maps a TranscriptEvent to its corresponding ChatAction. This mirrors the
// dispatch logic in App.tsx's transcript:event IPC handler. Keep in sync if
// new TranscriptEvent kinds are added.
function transcriptEventToAction(event: TranscriptEvent, sessionId: string): ChatAction | null {
  switch (event.kind) {
    case 'user-message':
      return {
        type: 'TRANSCRIPT_USER_MESSAGE',
        sessionId,
        uuid: event.uuid,
        text: event.text,
      };
    case 'assistant-text':
      return {
        type: 'TRANSCRIPT_ASSISTANT_TEXT',
        sessionId,
        uuid: event.uuid,
        text: event.text,
        model: event.model ?? null,
      };
    case 'tool-use':
      return {
        type: 'TRANSCRIPT_TOOL_USE',
        sessionId,
        uuid: event.uuid,
        toolUseId: event.toolUseId,
        toolName: event.toolName,
        toolInput: event.toolInput,
      };
    case 'tool-result':
      return {
        type: 'TRANSCRIPT_TOOL_RESULT',
        sessionId,
        uuid: event.uuid,
        toolUseId: event.toolUseId,
        result: event.result,
        isError: event.isError ?? false,
      };
    case 'turn-complete':
      return {
        type: 'TRANSCRIPT_TURN_COMPLETE',
        sessionId,
        uuid: event.uuid,
        stopReason: event.stopReason ?? null,
        model: event.model ?? null,
        usage: event.usage ?? null,
        anthropicRequestId: event.anthropicRequestId ?? null,
      };
    case 'user-interrupt':
      return {
        type: 'TRANSCRIPT_INTERRUPT',
        sessionId,
        uuid: event.uuid,
      };
    case 'assistant-thinking':
      return {
        type: 'TRANSCRIPT_THINKING_HEARTBEAT',
        sessionId,
        uuid: event.uuid,
      };
    default:
      return null;
  }
}
```

> **Adjustment note:** The `TranscriptEvent` discriminator field is `event.kind` in this plan; if the actual type uses `event.type`, swap accordingly. Likewise for the `ChatAction` shape — open `chat-types.ts` and `shared/types.ts` to confirm exact field names before writing this file.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd youcoded/desktop && npm test -- scenario-replay
```

Expected: PASS, both cases.

- [ ] **Step 5: Commit**

```bash
git add youcoded/desktop/src/renderer/dev/workbench/scenario-replay.ts \
        youcoded/desktop/tests/scenario-replay.test.ts
git commit -m "feat(workbench): JSONL→ChatState replay function"
```

### Task 3.3: ScenarioProvider — context override scaffold

**Files:**
- Create: `youcoded/desktop/src/renderer/dev/workbench/ScenarioProvider.tsx`

- [ ] **Step 1: Survey context dependencies first**

Before writing `ScenarioProvider`, list the contexts that the chat frame's components consume — this drives which providers `ScenarioProvider` must wrap and override. Spend 5 minutes reading:

- `src/renderer/state/chat-context.ts` — chat state/dispatch.
- `src/renderer/state/theme-context.tsx` — theme.
- Any sync-warnings / announcement / attention contexts that the status-bar widgets read from.

> **Adjustment note:** This survey may discover that some status-bar widgets read directly from `window.claude.*` (IPC) rather than React context. For those, `ScenarioProvider` will need to mock `window.claude` for the workbench session OR move the widget to take its data from a context. Pick the lower-risk option per widget — mocking `window.claude` for a single read is fine; refactoring an existing widget to take a context prop should only be done if the widget already has many props and the context is a natural fit.

- [ ] **Step 2: Implement the provider**

```tsx
// youcoded/desktop/src/renderer/dev/workbench/ScenarioProvider.tsx
//
// Wraps a chat frame in a synthesized session state. Replays a JSONL
// transcript through the chat reducer, then provides every context the
// chat frame reads from with scenario-driven values (instead of IPC-driven).

import React, { useMemo } from 'react';
import { ChatProvider, useChatDispatch } from '../../state/chat-context';
import { replayScenarioJsonl } from './scenario-replay';
import { mergeScenarioState, type ScenarioState } from './scenario-types';

const SCENARIO_SESSION_ID = 'workbench-scenario';

interface Props {
  jsonl: string;
  scenarioState?: Partial<ScenarioState> | null;
  children: React.ReactNode;
}

// Inner component — must run inside ChatProvider so it has access to dispatch.
function ScenarioStateBridge({ jsonl, children }: { jsonl: string; children: React.ReactNode }) {
  const dispatch = useChatDispatch();

  // Replay the JSONL on mount and on jsonl change. We compute the final state
  // via the pure function and dispatch a single SESSION_HYDRATE-equivalent.
  // Since ChatProvider's reducer is private, we instead dispatch each replayed
  // action sequentially. Use a flag to avoid double-dispatch under StrictMode.
  React.useEffect(() => {
    // Replay through a local copy of the reducer to compute the final state...
    // ...then dispatch a single REPLACE_SESSION action.
    //
    // (If REPLACE_SESSION doesn't exist as an action, add it in chat-reducer.ts
    // gated behind a `__test_only` flag, or sequence-dispatch the events
    // directly — see the Adjustment note below.)
  }, [jsonl, dispatch]);

  return <>{children}</>;
}

export function ScenarioProvider({ jsonl, scenarioState, children }: Props) {
  const merged = useMemo(() => mergeScenarioState(scenarioState), [scenarioState]);

  // TODO in implementation: wrap with the actual contexts the chat frame reads
  // from (theme, sync warnings, announcement, attention, etc.) and override
  // their values with `merged`. Each override is one extra <Provider> wrapper.

  return (
    <ChatProvider>
      <ScenarioStateBridge jsonl={jsonl}>
        {/* Other context overrides nest here, innermost first. */}
        {children}
      </ScenarioStateBridge>
    </ChatProvider>
  );
}
```

> **Adjustment note (important):** The `ChatProvider` exported from `chat-context.ts` is currently fed by `transcript:event` IPC. The cleanest way to seed it from a static JSONL is to add a `REPLACE_SESSION` action in `chat-reducer.ts` that wholesale-replaces a session's state from a precomputed value. Alternative: dispatch each `TRANSCRIPT_*` action in sequence in the bridge `useEffect` — slower but no reducer changes. **Pick whichever is less invasive after reading the reducer.** The plan's later snapshot script (Task 4.1) does NOT depend on this choice — it operates on the pure `replayScenarioJsonl` function directly, no React.

- [ ] **Step 3: Smoke test**

Run the workbench. The Conversations tab will still show "Coming in Phase 3" — `ScenarioProvider` is wired up in Task 3.5. For now, just verify nothing in App.tsx broke.

```bash
cd youcoded/desktop && npx tsc --noEmit
```

Expected: no TypeScript errors.

- [ ] **Step 4: Commit**

```bash
git add youcoded/desktop/src/renderer/dev/workbench/ScenarioProvider.tsx
git commit -m "feat(workbench): ScenarioProvider scaffold"
```

### Task 3.4: Hand-write the synthetic transcript fixture

**Files:**
- Create: `youcoded/desktop/src/renderer/dev/fixtures/conversations/synthetic.jsonl`
- Create: `youcoded/desktop/src/renderer/dev/fixtures/conversations/synthetic.scenario.json`

This is the longest task in the plan — hand-build a JSONL covering the v1 checklist from the spec. Budget: 60–90 minutes.

- [ ] **Step 1: Open a real CC session as a reference**

The format CC writes is the contract. Open `~/.claude/projects/<some-recent-slug>/<session>.jsonl` and use it as the structural reference for line shapes. Don't copy content — copy structure (key names, nesting, `type` field discriminators).

- [ ] **Step 2: Build the synthetic JSONL**

The transcript should cover, in one continuous session:
- User message variants: short, multi-line with code block, with markdown link.
- Assistant text: short, multi-paragraph, with code block, with table, with bullet list.
- `tool_use` + `tool_result` for: Bash, Edit, Read, Write, Glob, Grep, TodoWrite, Agent, WebFetch, WebSearch, Skill.
- At least one MCP tool example (e.g., `mcp__windows-control__Screenshot`).
- One failed tool result with `is_error: true`.
- One grouped multi-tool turn (one assistant turn emits two `tool_use` blocks before any text).
- An interrupt marker (`[Request interrupted by user]` user-message body).
- A compaction marker (find an example in a real session — typical format involves a `[Conversation compacted]` system-style message).
- An extended-thinking heartbeat (`thinking` content block format).
- A non-`end_turn` stop reason — e.g., `max_tokens` — on at least one turn.
- A long markdown block (>1000 chars in one assistant text).

Use a fixed `sessionId` of `synthetic-session` and deterministic `uuid` values like `u1`, `a1`, `t1`. Use a deterministic `timestamp` sequence starting at `2026-04-26T00:00:00Z`, incrementing by 1 second per line.

> **Adjustment note:** It's easier to validate as you go than to write everything and debug later. After every ~5–10 lines, save the file and run the scenario through `replayScenarioJsonl` in a quick Node REPL or vitest spike to confirm the parser doesn't choke. If `parseTranscriptLine` rejects a line shape, fix that line before continuing.

- [ ] **Step 3: Build the sidecar**

```json
{
  "model": "claude-opus-4-7",
  "cwd": "/redacted/synthetic",
  "gitBranch": "master",
  "contextUsedPct": 0.42,
  "todos": [
    { "id": "1", "text": "Implement workbench shell", "status": "completed" },
    { "id": "2", "text": "Build synthetic transcript", "status": "in_progress" },
    { "id": "3", "text": "Wire snapshot script", "status": "pending" }
  ],
  "subagents": [],
  "announcement": null,
  "syncWarnings": [],
  "attentionState": "ok",
  "permissionMode": "normal"
}
```

- [ ] **Step 4: Validate replay end-to-end**

Add a one-off vitest spike (delete after this task — its purpose is just to confirm the synthetic loads cleanly):

```ts
// Temporary spike, delete after this task. File: youcoded/desktop/tests/synthetic-spike.test.ts
import { describe, it, expect } from 'vitest';
import * as fs from 'fs';
import * as path from 'path';
import { replayScenarioJsonl } from '../src/renderer/dev/workbench/scenario-replay';

describe('synthetic transcript', () => {
  it('replays without throwing and produces a session with timeline entries', () => {
    const jsonl = fs.readFileSync(
      path.join(__dirname, '../src/renderer/dev/fixtures/conversations/synthetic.jsonl'),
      'utf8'
    );
    const state = replayScenarioJsonl(jsonl, 'synthetic-test');
    const session = state.get('synthetic-test')!;
    expect(session.userTimeline.length).toBeGreaterThanOrEqual(3);
    expect(session.toolCalls.size).toBeGreaterThanOrEqual(8);
  });
});
```

```bash
cd youcoded/desktop && npm test -- synthetic-spike
```

Expected: PASS. If it fails, fix the JSONL.

- [ ] **Step 5: Delete the spike test**

```bash
rm youcoded/desktop/tests/synthetic-spike.test.ts
```

The smoke test in Phase 4 covers the same ground systematically.

- [ ] **Step 6: Commit**

```bash
git add youcoded/desktop/src/renderer/dev/fixtures/conversations/synthetic.jsonl \
        youcoded/desktop/src/renderer/dev/fixtures/conversations/synthetic.scenario.json
git commit -m "feat(workbench): hand-built synthetic transcript + sidecar"
```

### Task 3.5: ConversationsTab — picker, drag-drop, render frame

**Files:**
- Create: `youcoded/desktop/src/renderer/dev/workbench/tabs/ConversationsTab.tsx`
- Create: `youcoded/desktop/src/renderer/dev/workbench/scenario-loader.ts`
- Modify: `youcoded/desktop/src/renderer/dev/workbench/WorkbenchShell.tsx`

- [ ] **Step 1: Build the scenario loader**

This module is the single place that knows how to enumerate bundled scenarios and how to read a sidecar.

```ts
// youcoded/desktop/src/renderer/dev/workbench/scenario-loader.ts
//
// Vite-bundled scenario discovery. Uses import.meta.glob to eagerly load
// every JSONL + sidecar pair under fixtures/conversations/ at build time.

import type { ScenarioState } from './scenario-types';

export interface BundledScenario {
  name: string;
  jsonl: string;
  scenarioState: Partial<ScenarioState> | null;
}

// @ts-ignore TS1343 — import.meta intercepted by Vite
const jsonls = import.meta.glob('../../fixtures/conversations/**/*.jsonl', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

// @ts-ignore TS1343
const sidecars = import.meta.glob('../../fixtures/conversations/**/*.scenario.json', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

export function listBundledScenarios(): BundledScenario[] {
  const out: BundledScenario[] = [];
  for (const [path, raw] of Object.entries(jsonls)) {
    const name = path.split('/').pop()!.replace(/\.jsonl$/, '');
    const sidecarPath = path.replace(/\.jsonl$/, '.scenario.json');
    const sidecarRaw = sidecars[sidecarPath];
    let scenarioState: Partial<ScenarioState> | null = null;
    if (sidecarRaw) {
      try {
        scenarioState = JSON.parse(sidecarRaw);
      } catch {
        scenarioState = null;
      }
    }
    out.push({ name, jsonl: raw, scenarioState });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}
```

- [ ] **Step 2: Build the tab component**

```tsx
// youcoded/desktop/src/renderer/dev/workbench/tabs/ConversationsTab.tsx
import React, { useState } from 'react';
import { ScenarioProvider } from '../ScenarioProvider';
import { listBundledScenarios, type BundledScenario } from '../scenario-loader';

interface AdHocScenario {
  name: string;
  jsonl: string;
  scenarioState: null;
}

export function ConversationsTab() {
  const bundled = React.useMemo(() => listBundledScenarios(), []);
  const [activeScenario, setActiveScenario] = useState<BundledScenario | AdHocScenario | null>(
    bundled[0] ?? null
  );
  const [dragOver, setDragOver] = useState(false);

  const handleDrop = async (e: React.DragEvent) => {
    e.preventDefault();
    setDragOver(false);
    const file = e.dataTransfer.files[0];
    if (!file || !file.name.endsWith('.jsonl')) return;
    const text = await file.text();
    setActiveScenario({ name: file.name, jsonl: text, scenarioState: null });
  };

  return (
    <div style={{ display: 'flex', height: '100%' }}>
      <aside
        style={{
          width: 240,
          flexShrink: 0,
          borderRight: '1px solid var(--edge-dim, #333)',
          overflowY: 'auto',
          padding: 12,
        }}
      >
        <div
          style={{
            fontSize: 11,
            opacity: 0.5,
            textTransform: 'uppercase',
            margin: '0 0 8px',
            letterSpacing: 0.5,
          }}
        >
          Bundled scenarios
        </div>
        {bundled.map((s) => (
          <button
            key={s.name}
            onClick={() => setActiveScenario(s)}
            style={{
              display: 'block',
              width: '100%',
              textAlign: 'left',
              padding: '6px 8px',
              background:
                activeScenario?.name === s.name ? 'var(--bg-inset, #222)' : 'transparent',
              border: 'none',
              color: 'inherit',
              cursor: 'pointer',
              fontSize: 13,
              borderRadius: 4,
            }}
          >
            {s.name}
          </button>
        ))}

        <div
          onDragOver={(e) => {
            e.preventDefault();
            setDragOver(true);
          }}
          onDragLeave={() => setDragOver(false)}
          onDrop={handleDrop}
          style={{
            marginTop: 16,
            padding: 16,
            border: `1px dashed ${dragOver ? 'var(--accent, #4af)' : 'var(--edge-dim, #333)'}`,
            borderRadius: 6,
            textAlign: 'center',
            fontSize: 12,
            opacity: 0.7,
          }}
        >
          {dragOver ? 'Release to load' : 'Drop a .jsonl here'}
        </div>
      </aside>

      <div style={{ flex: 1, overflow: 'auto' }}>
        {activeScenario ? (
          <ScenarioProvider
            key={activeScenario.name}
            jsonl={activeScenario.jsonl}
            scenarioState={activeScenario.scenarioState}
          >
            {/*
              In the actual implementation, this is replaced with the real
              chat frame layout — the same components App.tsx mounts when a
              session is active. For the initial cut, render a minimal
              placeholder that proves the provider mounts and chat state is
              populated, and add the real layout in a follow-up step.
            */}
            <ChatFrame />
          </ScenarioProvider>
        ) : (
          <div style={{ padding: 24, opacity: 0.5 }}>
            No scenario loaded. Pick one or drop a .jsonl on the left.
          </div>
        )}
      </div>
    </div>
  );
}

// Imported here for clarity; actual component lives in chat-related files.
// Replace with the real chat layout component in step 3 below.
function ChatFrame() {
  return (
    <div style={{ padding: 24 }}>
      <p style={{ opacity: 0.6 }}>Chat frame goes here.</p>
    </div>
  );
}
```

- [ ] **Step 3: Replace `<ChatFrame />` with the real chat layout**

Identify the component(s) that App.tsx renders when a session is active — the chain typically is `<HeaderBar /> <ChatView /> <StatusBar />` plus overlays. Mount the same composition inside `<ScenarioProvider>`. The exact import paths depend on the renderer's component layout — find them via:

```bash
grep -rn "ChatView\|HeaderBar\|StatusBar" youcoded/desktop/src/renderer/components/ | head
```

> **Adjustment note:** App.tsx wraps the chat with several context providers (theme, sync, announcement, etc.) that the workbench needs to substitute. Either make `<ScenarioProvider>` wrap them all (preferred) or render the chat layout's underlying components directly (without their App-level context expectations) and override every context the workbench cares about. The right balance is determined by reading App.tsx around line 2360+ to see which providers wrap the chat and which feed it.

- [ ] **Step 4: Wire ConversationsTab into WorkbenchShell**

In `WorkbenchShell.tsx`, replace the placeholder for `'conversations'`:

```tsx
import { ConversationsTab } from './tabs/ConversationsTab';
// ...
{activeTab === 'conversations' && <ConversationsTab />}
```

- [ ] **Step 5: Smoke test**

```bash
bash scripts/run-workbench.sh
```

- Click "Conversations" in left-nav. Expected: list of bundled scenarios on the left, chat content on the right.
- Click "synthetic". Expected: chat renders with all the message types.
- Drag-drop a real prod JSONL file from `~/.claude/projects/`. Expected: it renders with default scenario state.

- [ ] **Step 6: Commit**

```bash
git add youcoded/desktop/src/renderer/dev/workbench/tabs/ConversationsTab.tsx \
        youcoded/desktop/src/renderer/dev/workbench/scenario-loader.ts \
        youcoded/desktop/src/renderer/dev/workbench/WorkbenchShell.tsx
git commit -m "feat(workbench): Conversations tab with picker, drag-drop, ScenarioProvider"
```

---

## Phase 4 — Snapshot script + baselines

### Task 4.1: Snapshot serializer (pure function)

**Files:**
- Create: `youcoded/desktop/src/renderer/dev/workbench/snapshot-serializer.ts`
- Create: `youcoded/desktop/tests/snapshot-serializer.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// youcoded/desktop/tests/snapshot-serializer.test.ts
import { describe, it, expect } from 'vitest';
import { serializeScenarioSnapshot } from '../src/renderer/dev/workbench/snapshot-serializer';
import { replayScenarioJsonl } from '../src/renderer/dev/workbench/scenario-replay';
import { mergeScenarioState } from '../src/renderer/dev/workbench/scenario-types';

describe('serializeScenarioSnapshot', () => {
  it('produces a deterministic snapshot for a minimal session', () => {
    const jsonl = [
      JSON.stringify({
        type: 'user',
        uuid: 'u1',
        sessionId: 's',
        timestamp: '2026-04-26T00:00:00Z',
        message: { role: 'user', content: 'hi' },
      }),
      JSON.stringify({
        type: 'assistant',
        uuid: 'a1',
        sessionId: 's',
        timestamp: '2026-04-26T00:00:01Z',
        message: { role: 'assistant', model: 'claude-opus-4-7', content: [{ type: 'text', text: 'hello' }] },
      }),
    ].join('\n');

    const state = replayScenarioJsonl(jsonl, 's');
    const snap = serializeScenarioSnapshot('mini', state.get('s')!, mergeScenarioState(null));

    expect(snap.scenario).toBe('mini');
    expect(snap.schemaVersion).toBe(1);
    expect(snap.timeline.length).toBeGreaterThanOrEqual(2);
    expect(snap.timeline[0].kind).toBe('user');
    expect(snap.attentionState).toBe('ok');
    expect(snap.statusbar.model).toBe('claude-opus-4-7');
  });
});
```

- [ ] **Step 2: Run to verify failure**

```bash
cd youcoded/desktop && npm test -- snapshot-serializer
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement the serializer**

```ts
// youcoded/desktop/src/renderer/dev/workbench/snapshot-serializer.ts
//
// Pure: SessionChatState + ScenarioState → deterministic JSON snapshot.
// No DOM, no React, no IPC. Used by snapshot.js (CLI) and the smoke test.

import type { SessionChatState } from '../../state/chat-types';
import type { ScenarioState } from './scenario-types';

export interface ScenarioSnapshot {
  scenario: string;
  schemaVersion: 1;
  timeline: TimelineEntry[];
  toolCallsCount: number;
  orphanToolCalls: string[];
  attentionState: ScenarioState['attentionState'];
  stopReason: string | null;
  statusbar: {
    model: string;
    gitBranch: string;
    contextUsedPct: number;
    todosActive: number;
    subagentsActive: number;
    announcement: string | null;
    syncWarningCount: number;
  };
}

export type TimelineEntry =
  | { kind: 'user'; text: string; pending: boolean }
  | { kind: 'assistant-text'; text: string }
  | { kind: 'tool'; name: string; status: string; inputSummary: string; resultSummary: string };

export function serializeScenarioSnapshot(
  name: string,
  session: SessionChatState,
  scenarioState: ScenarioState
): ScenarioSnapshot {
  const timeline: TimelineEntry[] = [];

  // Walk userTimeline entries in their stored order. Interleave assistant
  // text and tool entries by their action order — for v1 we approximate by
  // using the timestamp/insertion order each session structure preserves.
  for (const entry of session.userTimeline) {
    timeline.push({ kind: 'user', text: entry.text ?? '', pending: !!entry.pending });
  }
  for (const turn of session.assistantTurns) {
    if (turn.text) timeline.push({ kind: 'assistant-text', text: turn.text });
  }
  for (const tool of session.toolCalls.values()) {
    timeline.push({
      kind: 'tool',
      name: tool.toolName,
      status: tool.status,
      inputSummary: summarize(tool.input),
      resultSummary: summarize(tool.result),
    });
  }

  // Orphan = tool that's still 'running' or 'awaiting-approval' at session end.
  const orphans: string[] = [];
  for (const [id, tool] of session.toolCalls) {
    if (tool.status === 'running' || tool.status === 'awaiting-approval') orphans.push(id);
  }

  // Last completed turn's stop reason; null if none.
  const lastTurn = session.assistantTurns[session.assistantTurns.length - 1];
  const stopReason = lastTurn?.stopReason ?? null;

  return {
    scenario: name,
    schemaVersion: 1,
    timeline,
    toolCallsCount: session.toolCalls.size,
    orphanToolCalls: orphans,
    attentionState: scenarioState.attentionState,
    stopReason,
    statusbar: {
      model: scenarioState.model,
      gitBranch: scenarioState.gitBranch,
      contextUsedPct: scenarioState.contextUsedPct,
      todosActive: scenarioState.todos.filter((t) => t.status === 'in_progress').length,
      subagentsActive: scenarioState.subagents.filter((s) => s.status === 'running').length,
      announcement: scenarioState.announcement,
      syncWarningCount: scenarioState.syncWarnings.length,
    },
  };
}

function summarize(value: unknown): string {
  if (value == null) return '';
  if (typeof value === 'string') {
    return value.length > 80 ? `${value.slice(0, 77)}...` : value;
  }
  try {
    const json = JSON.stringify(value);
    return json.length > 80 ? `${json.slice(0, 77)}...` : json;
  } catch {
    return String(value);
  }
}
```

> **Adjustment note:** The exact field names on `SessionChatState` (`userTimeline`, `assistantTurns`, `toolCalls`) come from `chat-types.ts` — confirm before wiring. Also confirm `ToolCallState` uses `toolName`, `status`, `input`, `result`. Adjust if names differ.

- [ ] **Step 4: Run test to verify pass**

```bash
cd youcoded/desktop && npm test -- snapshot-serializer
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add youcoded/desktop/src/renderer/dev/workbench/snapshot-serializer.ts \
        youcoded/desktop/tests/snapshot-serializer.test.ts
git commit -m "feat(workbench): scenario snapshot serializer"
```

### Task 4.2: snapshot.js CLI

**Files:**
- Create: `youcoded/desktop/scripts/dev-tools/snapshot.js`

- [ ] **Step 1: Implement the CLI**

```js
#!/usr/bin/env node
// youcoded/desktop/scripts/dev-tools/snapshot.js
//
// Usage:
//   node scripts/dev-tools/snapshot.js <scenario>             # print JSON to stdout
//   node scripts/dev-tools/snapshot.js <scenario> --diff      # diff against baseline
//   node scripts/dev-tools/snapshot.js <scenario> --update    # write baseline
//   node scripts/dev-tools/snapshot.js --all --diff           # diff every bundled scenario
//
// Pure node — no Electron, no DOM. Imports the renderer's pure modules
// (scenario-replay + snapshot-serializer) directly. tsc is required so the
// TS sources are resolvable; this script imports their built JS via require
// from dist/, OR via tsx/ts-node at runtime (decide in Step 2).

const fs = require('fs');
const path = require('path');

const FIXTURES_DIR = path.join(
  __dirname, '..', '..',
  'src/renderer/dev/fixtures/conversations'
);
const BASELINES_DIR = path.join(
  __dirname, '..', '..',
  'src/renderer/dev/baselines/conversations'
);

// Use tsx so TS sources resolve at runtime without a separate build step.
require('tsx/cjs');
const { replayScenarioJsonl } = require(
  '../../src/renderer/dev/workbench/scenario-replay'
);
const { serializeScenarioSnapshot } = require(
  '../../src/renderer/dev/workbench/snapshot-serializer'
);
const { mergeScenarioState } = require(
  '../../src/renderer/dev/workbench/scenario-types'
);

const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith('--')));
const positional = args.filter((a) => !a.startsWith('--'));

const all = flags.has('--all');
const doDiff = flags.has('--diff');
const doUpdate = flags.has('--update');

function findScenarios(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...findScenarios(full));
    } else if (entry.name.endsWith('.jsonl')) {
      const name = path.relative(FIXTURES_DIR, full).replace(/\.jsonl$/, '').replace(/\\/g, '/');
      out.push({ name, path: full });
    }
  }
  return out;
}

function buildSnapshot(name, jsonlPath) {
  const jsonl = fs.readFileSync(jsonlPath, 'utf8');
  const sidecarPath = jsonlPath.replace(/\.jsonl$/, '.scenario.json');
  const sidecar = fs.existsSync(sidecarPath)
    ? JSON.parse(fs.readFileSync(sidecarPath, 'utf8'))
    : null;
  const state = replayScenarioJsonl(jsonl, name);
  const session = state.get(name);
  if (!session) throw new Error(`Replay produced no session for ${name}`);
  return serializeScenarioSnapshot(name, session, mergeScenarioState(sidecar));
}

function baselinePath(name) {
  return path.join(BASELINES_DIR, `${name}.snapshot.json`);
}

function exitFail(msg) {
  console.error(msg);
  process.exit(1);
}

function processOne(name, jsonlPath) {
  const snap = buildSnapshot(name, jsonlPath);
  const json = JSON.stringify(snap, null, 2);
  const blPath = baselinePath(name);

  if (doUpdate) {
    fs.mkdirSync(path.dirname(blPath), { recursive: true });
    fs.writeFileSync(blPath, json + '\n');
    console.log(`Updated baseline: ${blPath}`);
    return true;
  }

  if (doDiff) {
    if (!fs.existsSync(blPath)) {
      console.log(`[${name}] NO BASELINE — run with --update to create`);
      return false;
    }
    const baseline = fs.readFileSync(blPath, 'utf8').trimEnd();
    if (baseline === json) {
      console.log(`[${name}] OK`);
      return true;
    }
    console.log(`[${name}] DIFF`);
    // Plain unified-style line diff for readability.
    const a = baseline.split('\n');
    const b = json.split('\n');
    const max = Math.max(a.length, b.length);
    for (let i = 0; i < max; i++) {
      if (a[i] !== b[i]) {
        if (a[i] !== undefined) console.log(`  - ${a[i]}`);
        if (b[i] !== undefined) console.log(`  + ${b[i]}`);
      }
    }
    return false;
  }

  // Default: print snapshot to stdout.
  console.log(json);
  return true;
}

function main() {
  const targets = all
    ? findScenarios(FIXTURES_DIR)
    : positional.length === 1
    ? [{ name: positional[0], path: path.join(FIXTURES_DIR, `${positional[0]}.jsonl`) }]
    : null;

  if (!targets) {
    exitFail('Usage: snapshot.js <scenario>|--all [--diff|--update]');
  }

  let allOk = true;
  for (const t of targets) {
    if (!fs.existsSync(t.path)) {
      console.error(`Scenario JSONL not found: ${t.path}`);
      allOk = false;
      continue;
    }
    const ok = processOne(t.name, t.path);
    if (!ok) allOk = false;
  }

  process.exit(allOk ? 0 : 1);
}

main();
```

- [ ] **Step 2: Add tsx as a devDependency**

```bash
cd youcoded/desktop && npm install --save-dev tsx
```

- [ ] **Step 3: Smoke test — print mode**

```bash
cd youcoded/desktop && node scripts/dev-tools/snapshot.js synthetic
```

Expected: deterministic JSON to stdout describing the synthetic scenario.

- [ ] **Step 4: Establish the synthetic baseline**

```bash
cd youcoded/desktop && node scripts/dev-tools/snapshot.js synthetic --update
```

Expected: writes `src/renderer/dev/baselines/conversations/synthetic.snapshot.json`.

- [ ] **Step 5: Smoke test — diff mode**

```bash
cd youcoded/desktop && node scripts/dev-tools/snapshot.js synthetic --diff
```

Expected: prints `[synthetic] OK`.

- [ ] **Step 6: Smoke test — --all**

```bash
cd youcoded/desktop && node scripts/dev-tools/snapshot.js --all --diff
```

Expected: `[synthetic] OK`. (Other scenarios come in Phase 6.)

- [ ] **Step 7: Commit**

```bash
git add youcoded/desktop/scripts/dev-tools/snapshot.js \
        youcoded/desktop/package.json \
        youcoded/desktop/package-lock.json \
        youcoded/desktop/src/renderer/dev/baselines/conversations/synthetic.snapshot.json
git commit -m "feat(workbench): snapshot CLI + synthetic baseline"
```

### Task 4.3: Smoke test for fixtures

**Files:**
- Create: `youcoded/desktop/tests/conversations-fixtures-smoke.test.ts`

- [ ] **Step 1: Write the smoke test**

```ts
// youcoded/desktop/tests/conversations-fixtures-smoke.test.ts
//
// Loads every bundled scenario JSONL + sidecar and asserts the snapshot
// pipeline (replay + serialize) produces JSON without throwing. Catches
// "I edited a fixture into an unparseable state" within npm test.

import { describe, it, expect } from 'vitest';
import * as fs from 'fs';
import * as path from 'path';
import { replayScenarioJsonl } from '../src/renderer/dev/workbench/scenario-replay';
import { serializeScenarioSnapshot } from '../src/renderer/dev/workbench/snapshot-serializer';
import { mergeScenarioState } from '../src/renderer/dev/workbench/scenario-types';

const FIXTURES_DIR = path.join(__dirname, '../src/renderer/dev/fixtures/conversations');

function listJsonls(dir: string): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...listJsonls(full));
    else if (entry.name.endsWith('.jsonl')) out.push(full);
  }
  return out;
}

describe('conversations fixtures smoke', () => {
  const fixtures = listJsonls(FIXTURES_DIR);

  it('finds at least the synthetic fixture', () => {
    expect(fixtures.some((f) => f.endsWith('synthetic.jsonl'))).toBe(true);
  });

  for (const fixturePath of fixtures) {
    const name = path.relative(FIXTURES_DIR, fixturePath).replace(/\.jsonl$/, '').replace(/\\/g, '/');
    it(`builds a snapshot for ${name} without throwing`, () => {
      const jsonl = fs.readFileSync(fixturePath, 'utf8');
      const sidecarPath = fixturePath.replace(/\.jsonl$/, '.scenario.json');
      const sidecar = fs.existsSync(sidecarPath)
        ? JSON.parse(fs.readFileSync(sidecarPath, 'utf8'))
        : null;

      const state = replayScenarioJsonl(jsonl, name);
      const session = state.get(name)!;
      expect(session).toBeDefined();

      const snap = serializeScenarioSnapshot(name, session, mergeScenarioState(sidecar));
      expect(snap.scenario).toBe(name);
      expect(snap.schemaVersion).toBe(1);
    });
  }
});
```

- [ ] **Step 2: Run the smoke test**

```bash
cd youcoded/desktop && npm test -- conversations-fixtures-smoke
```

Expected: PASS for synthetic.

- [ ] **Step 3: Commit**

```bash
git add youcoded/desktop/tests/conversations-fixtures-smoke.test.ts
git commit -m "test(workbench): smoke test for bundled scenario fixtures"
```

---

## Phase 5 — Theme cycle tab

### Task 5.1: ThemeCycleTab

**Files:**
- Create: `youcoded/desktop/src/renderer/dev/workbench/tabs/ThemeCycleTab.tsx`
- Modify: `youcoded/desktop/src/renderer/dev/workbench/WorkbenchShell.tsx`

- [ ] **Step 1: Find the theme list**

Identify how themes are enumerated. Per `desktop/CLAUDE.md`: themes are listed in a `THEMES` array in `theme-context.tsx`. Use that as the source of truth.

```bash
grep -n "THEMES\|export.*theme" youcoded/desktop/src/renderer/state/theme-context.tsx | head
```

- [ ] **Step 2: Implement the tab**

```tsx
// youcoded/desktop/src/renderer/dev/workbench/tabs/ThemeCycleTab.tsx
//
// Renders the synthetic transcript in every available theme on one page.
// Lets you eyeball any token regressions across themes in seconds.

import React from 'react';
import { ScenarioProvider } from '../ScenarioProvider';
import { listBundledScenarios } from '../scenario-loader';
import { THEMES } from '../../../state/theme-context';

// Reuse the same ChatFrame composition as ConversationsTab. Extract that
// component into a shared module first if the duplication is non-trivial.
import { ChatFrame } from './ConversationsTab';

export function ThemeCycleTab() {
  const synthetic = listBundledScenarios().find((s) => s.name === 'synthetic');
  if (!synthetic) {
    return <div style={{ padding: 24, opacity: 0.5 }}>synthetic scenario not found</div>;
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column' }}>
      {THEMES.map((theme) => (
        <section
          key={theme}
          data-theme={theme}
          style={{ borderBottom: '1px solid var(--edge-dim, #333)' }}
        >
          <header
            style={{
              padding: '12px 24px',
              fontSize: 13,
              opacity: 0.7,
              background: 'var(--bg-inset, #222)',
            }}
          >
            Theme: {theme}
          </header>
          <div style={{ padding: 16 }}>
            <ScenarioProvider
              jsonl={synthetic.jsonl}
              scenarioState={synthetic.scenarioState}
            >
              <ChatFrame />
            </ScenarioProvider>
          </div>
        </section>
      ))}
    </div>
  );
}
```

> **Adjustment note:** Two real things to handle — (1) `data-theme` attribute is set on `<html>` globally in production; for the cycle tab to render multiple themes simultaneously, each section's `data-theme` needs a CSS scope rule in `globals.css` (e.g., `[data-theme] [data-theme-scope] { ... }`) OR the renderer must accept an `initialTheme` prop on `ThemeProvider` that scopes the variables to a `<div>` instead of `<html>`. Pick the lighter path. (2) `ChatFrame` needs to be exported from `ConversationsTab.tsx` (it currently isn't); export it or move to a shared module.

- [ ] **Step 3: Wire into WorkbenchShell**

```tsx
// In WorkbenchShell.tsx:
import { ThemeCycleTab } from './tabs/ThemeCycleTab';
// ...
{activeTab === 'themes' && <ThemeCycleTab />}
```

- [ ] **Step 4: Smoke test**

```bash
bash scripts/run-workbench.sh
```

Click "Theme cycle" → see the synthetic scenario rendered in each theme, vertically stacked.

- [ ] **Step 5: Commit**

```bash
git add youcoded/desktop/src/renderer/dev/workbench/tabs/ThemeCycleTab.tsx \
        youcoded/desktop/src/renderer/dev/workbench/WorkbenchShell.tsx \
        youcoded/desktop/src/renderer/dev/workbench/tabs/ConversationsTab.tsx
git commit -m "feat(workbench): Theme cycle tab"
```

---

## Phase 6 — Redactor + real-anonymized bundle

### Task 6.1: Test redactor's pure transformations

**Files:**
- Create: `youcoded/desktop/scripts/dev-tools/redact-transcript.js`
- Create: `youcoded/desktop/tests/redact-transcript.test.ts`

- [ ] **Step 1: Write failing tests for each redaction pass**

```ts
// youcoded/desktop/tests/redact-transcript.test.ts
import { describe, it, expect } from 'vitest';
import {
  scrubPaths,
  scrubIdentities,
  scrubSecrets,
  rewriteCwd,
  stableTimestamp,
} from '../scripts/dev-tools/redact-transcript';

describe('redact-transcript pure transformations', () => {
  it('scrubPaths replaces home and absolute paths with placeholders', () => {
    const before = 'Open C:/Users/alice/projects/foo.txt or /home/alice/secret.md';
    const after = scrubPaths(before, 'C:/Users/alice', '/home/alice');
    expect(after).not.toContain('alice');
    expect(after).toContain('<HOME>');
  });

  it('scrubIdentities replaces names per identity map', () => {
    const map = { alice: '<USER>', acme: '<ORG>' };
    const after = scrubIdentities('hello alice from acme', map);
    expect(after).toBe('hello <USER> from <ORG>');
  });

  it('scrubSecrets removes common secret patterns', () => {
    const inputs = [
      'token=ghp_abcdefghijklmnopqrstuvwxyz1234567890',
      'key sk-ant-api03-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
      'github_pat_11ABCDEF12345_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
    ];
    for (const i of inputs) {
      expect(scrubSecrets(i)).not.toMatch(/ghp_|sk-ant|github_pat/);
    }
  });

  it('rewriteCwd replaces the cwd field on a JSONL line', () => {
    const line = JSON.stringify({ type: 'user', cwd: 'C:/Users/alice/proj' });
    const out = JSON.parse(rewriteCwd(line));
    expect(out.cwd).toBe('/redacted/scenario');
  });

  it('stableTimestamp replaces timestamp with a deterministic sequence', () => {
    const line1 = JSON.stringify({ timestamp: '2026-01-01T00:00:00Z' });
    const line2 = JSON.stringify({ timestamp: '2026-04-26T15:30:00Z' });
    const t1 = JSON.parse(stableTimestamp(line1, 0)).timestamp;
    const t2 = JSON.parse(stableTimestamp(line2, 1)).timestamp;
    expect(t1).toBe('2026-04-26T00:00:00.000Z');
    expect(t2).toBe('2026-04-26T00:00:01.000Z');
  });
});
```

- [ ] **Step 2: Run to verify failure**

```bash
cd youcoded/desktop && npm test -- redact-transcript
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement the redactor**

```js
#!/usr/bin/env node
// youcoded/desktop/scripts/dev-tools/redact-transcript.js
//
// Usage:
//   node scripts/dev-tools/redact-transcript.js <input.jsonl> <output.jsonl> \
//     [--identities <file.json>] [--stable-timestamps]
//
// Operations in order: paths, identities, secrets, cwd, timestamps.
// Also writes <output>.scenario.json with sensible defaults.

const fs = require('fs');
const os = require('os');
const path = require('path');

// Common secret regexes — extend as new patterns bite.
const SECRET_PATTERNS = [
  /ghp_[A-Za-z0-9]{20,}/g,
  /github_pat_[A-Za-z0-9_]{20,}/g,
  /gho_[A-Za-z0-9]{20,}/g,
  /ghu_[A-Za-z0-9]{20,}/g,
  /ghs_[A-Za-z0-9]{20,}/g,
  /sk-ant-(?:api03-)?[A-Za-z0-9_-]{20,}/g,
  /xoxb-[A-Za-z0-9-]{20,}/g,
  /AKIA[A-Z0-9]{16}/g,                       // AWS access keys
  /AIza[A-Za-z0-9_-]{20,}/g,                 // Google API keys
];

function scrubPaths(text, homeWin, homeUnix) {
  let out = text;
  if (homeWin) {
    const escWin = homeWin.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\\/g, '[\\\\/]');
    out = out.replace(new RegExp(escWin, 'gi'), '<HOME>');
  }
  if (homeUnix) {
    const escUnix = homeUnix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    out = out.replace(new RegExp(escUnix, 'g'), '<HOME>');
  }
  return out;
}

function scrubIdentities(text, map) {
  let out = text;
  for (const [name, replacement] of Object.entries(map)) {
    const esc = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    out = out.replace(new RegExp(esc, 'gi'), replacement);
  }
  return out;
}

function scrubSecrets(text) {
  let out = text;
  for (const pattern of SECRET_PATTERNS) out = out.replace(pattern, '<REDACTED-SECRET>');
  return out;
}

function rewriteCwd(line) {
  let parsed;
  try { parsed = JSON.parse(line); } catch { return line; }
  if (parsed && typeof parsed === 'object' && 'cwd' in parsed) {
    parsed.cwd = '/redacted/scenario';
  }
  return JSON.stringify(parsed);
}

function stableTimestamp(line, sequenceIndex) {
  let parsed;
  try { parsed = JSON.parse(line); } catch { return line; }
  if (parsed && 'timestamp' in parsed) {
    const t = new Date('2026-04-26T00:00:00Z');
    t.setUTCSeconds(t.getUTCSeconds() + sequenceIndex);
    parsed.timestamp = t.toISOString();
  }
  return JSON.stringify(parsed);
}

function detectModelFromJsonl(jsonl) {
  const lines = jsonl.split('\n');
  // Walk in reverse — last assistant turn's model wins.
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const obj = JSON.parse(lines[i]);
      if (obj?.message?.role === 'assistant' && obj?.message?.model) return obj.message.model;
    } catch { /* skip */ }
  }
  return 'claude-opus-4-7';
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.length < 2) {
    console.error('Usage: redact-transcript.js <input.jsonl> <output.jsonl> [--identities <file>] [--stable-timestamps]');
    process.exit(1);
  }
  const [inputPath, outputPath] = argv;
  const identitiesIdx = argv.indexOf('--identities');
  const identities = identitiesIdx >= 0 && argv[identitiesIdx + 1]
    ? JSON.parse(fs.readFileSync(argv[identitiesIdx + 1], 'utf8'))
    : {};
  const stable = argv.includes('--stable-timestamps');

  const input = fs.readFileSync(inputPath, 'utf8');
  const homeWin = os.homedir().replace(/\\/g, '/');
  const homeUnix = process.platform !== 'win32' ? os.homedir() : '';

  const lines = input.split('\n');
  const out = [];
  let seq = 0;
  for (const raw of lines) {
    if (!raw.trim()) { out.push(raw); continue; }
    let line = raw;
    line = scrubPaths(line, homeWin, homeUnix);
    line = scrubIdentities(line, identities);
    line = scrubSecrets(line);
    line = rewriteCwd(line);
    if (stable) { line = stableTimestamp(line, seq); seq++; }
    out.push(line);
  }
  fs.writeFileSync(outputPath, out.join('\n'));

  // Generate sidecar
  const sidecar = {
    model: detectModelFromJsonl(input),
    cwd: '/redacted/scenario',
    gitBranch: 'master',
  };
  fs.writeFileSync(outputPath.replace(/\.jsonl$/, '.scenario.json'), JSON.stringify(sidecar, null, 2) + '\n');

  console.log(`Wrote ${outputPath}`);
  console.log(`Wrote ${outputPath.replace(/\.jsonl$/, '.scenario.json')}`);
}

// Export pure functions for tests; only run main() when invoked directly.
module.exports = { scrubPaths, scrubIdentities, scrubSecrets, rewriteCwd, stableTimestamp };
if (require.main === module) main();
```

- [ ] **Step 4: Run tests to verify pass**

```bash
cd youcoded/desktop && npm test -- redact-transcript
```

Expected: PASS, all five cases.

- [ ] **Step 5: Commit**

```bash
git add youcoded/desktop/scripts/dev-tools/redact-transcript.js \
        youcoded/desktop/tests/redact-transcript.test.ts
git commit -m "feat(workbench): redact-transcript CLI + tests"
```

### Task 6.2: Curate the real-anonymized bundle

This is a hands-on curation task — Destin (or whoever has access to the local `~/.claude/projects/`) picks 3–5 sessions that illustrate diverse real-world shapes.

**Files (per scenario):**
- Create: `youcoded/desktop/src/renderer/dev/fixtures/conversations/real-bundle/<name>.jsonl`
- Create: `youcoded/desktop/src/renderer/dev/fixtures/conversations/real-bundle/<name>.scenario.json`

- [ ] **Step 1: Pick 3 sessions to redact**

Suggested diversity (the spec listed 3–5; pick 3 to start, add more later if a regression motivates it):
- One that triggered compaction.
- One with a mid-tool interrupt.
- One with an MCP tool spike.

```bash
ls ~/.claude/projects/
# Identify candidate session IDs from recent activity. For a quick view:
ls -lt ~/.claude/projects/*/*.jsonl | head -20
```

- [ ] **Step 2: Build the identity map**

Create `youcoded/desktop/scripts/dev-tools/.identities.local.json` (gitignored — strictly local):

```json
{
  "Destin": "<USER>",
  "destinj101@gmail.com": "<USER-EMAIL>",
  "itsdestin": "<USER-HANDLE>",
  "youcoded": "<PROJECT>"
}
```

Add to `.gitignore` if not already covered:

```bash
echo "youcoded/desktop/scripts/dev-tools/.identities.local.json" >> .gitignore
```

- [ ] **Step 3: Run the redactor on each picked session**

For each picked session, e.g.:

```bash
cd youcoded/desktop && node scripts/dev-tools/redact-transcript.js \
  ~/.claude/projects/<slug>/<session>.jsonl \
  src/renderer/dev/fixtures/conversations/real-bundle/long-compaction.jsonl \
  --identities scripts/dev-tools/.identities.local.json \
  --stable-timestamps
```

Repeat for the other two scenarios (e.g. `interrupted-mid-tool`, `mcp-spike`).

- [ ] **Step 4: Manually review each redacted file**

Open each file in an editor. Search for:
- Email addresses (`@`)
- Quoted strings that look like names or hostnames
- Anything that looks like a token (`Bearer`, `=`, long base64-ish strings)
- Identifiable repo/file references

Adjust the identities map and re-run if anything slipped through.

- [ ] **Step 5: Hand-edit each `.scenario.json`**

Add scenario-specific overrides that make the scenario more representative — for instance, the "long-compaction" scenario might set `contextUsedPct: 0.95` to show what the status bar looks like near full context.

- [ ] **Step 6: Generate baselines**

```bash
cd youcoded/desktop && node scripts/dev-tools/snapshot.js --all --update
```

- [ ] **Step 7: Add the README**

Create `youcoded/desktop/src/renderer/dev/fixtures/conversations/real-bundle/README.md`:

```markdown
# Real-anonymized scenario bundle

Each entry illustrates a real-world shape that the synthetic transcript can't fake authentically. All entries are run through `scripts/dev-tools/redact-transcript.js` with stable timestamps so snapshots stay deterministic.

| Scenario | Illustrates |
|----------|-------------|
| `long-compaction` | A session that hit `/compact` mid-stream — exercises compaction marker rendering and the post-compaction context-percent reset. |
| `interrupted-mid-tool` | User pressed ESC during a Bash run; the in-flight tool gets `Turn ended` failed status and the next user message starts a fresh turn. |
| `mcp-spike` | Multiple consecutive MCP tool calls (e.g. `mcp__windows-control__*`) — exercises tool grouping for non-built-in tools. |

Adding a new scenario:
1. Pick a session from `~/.claude/projects/`.
2. Run `redact-transcript.js` with `--identities scripts/dev-tools/.identities.local.json --stable-timestamps`.
3. Manually review for missed PII/secrets.
4. Hand-edit the sidecar to dial in any scenario-specific overrides.
5. Run `node scripts/dev-tools/snapshot.js <name> --update` to lock the baseline.
6. Add a row to this README.
```

- [ ] **Step 8: Verify smoke test passes for all bundled scenarios**

```bash
cd youcoded/desktop && npm test -- conversations-fixtures-smoke
```

Expected: PASS for synthetic + each real-bundle entry.

- [ ] **Step 9: Commit**

```bash
git add youcoded/desktop/src/renderer/dev/fixtures/conversations/real-bundle/ \
        youcoded/desktop/src/renderer/dev/baselines/conversations/ \
        .gitignore
git commit -m "feat(workbench): real-anonymized scenario bundle (3 scenarios)"
```

---

## Phase 7 — CC-coupling probe library

### Task 7.1: test-conpty/INDEX.md catalog

**Files:**
- Create: `youcoded/desktop/test-conpty/INDEX.md`

- [ ] **Step 1: Write the catalog**

```markdown
# test-conpty Probe Index

Every probe in this directory pins a specific Claude Code ↔ YouCoded coupling. This index maps probe → coupling → break symptom → run command, so you can answer "what does this probe protect us from, and how do I run it?" in one place.

For methodology and the irreducible probe template, see `README.md`.

## Catalog

| Probe | Pins coupling | cc-dependencies row | Break symptom | Has baseline? | Run |
|-------|---------------|---------------------|---------------|---------------|-----|
| `cc-snapshot.mjs` | Paste classification threshold + input-bar echo behavior + version baseline | "PTY input-bar echo" | Long sends silently fail to submit; or echo timing changes break the worker's echo-driven path | Yes (`snapshots/cc-<version>.json`) | `node test-conpty/cc-snapshot.mjs` |
| `test-multiline-submit.mjs` | All three submit paths (atomic, atomic-then-CR, split-then-CR) against real CC | "PTY paste classification" | Submits leave body in input bar with literal `\n` | No | `node test-conpty/test-multiline-submit.mjs` |
| `test-worker-submit.mjs` | The forked `pty-worker.js` correctly routes input through to CC for all three submit paths | "PTY input-bar echo" | Worker introduces a regression that bypasses the echo-driven path or chunks wrong | No | `node test-conpty/test-worker-submit.mjs` |
| `test-attention-states.mjs` | Attention classifier inputs (xterm buffer text → BufferClass) | "PTY spinner regex" | False positives/negatives in the AttentionBanner | Fixtures (`shared-fixtures/attention-classifier/`) | `node test-conpty/test-attention-states.mjs` |
| `test-spinner-fullcapture.mjs` | Spinner glyph + gerund + ellipsis matches CC's actual TUI output | "PTY spinner regex" | Spinner regex fails to match a real CC frame, breaking attention classifier | No | `node test-conpty/test-spinner-fullcapture.mjs` |
| `test-attention-false-match.mjs` | Spinner regex anchored at line start — no false matches against assistant text or echoed user input | "PTY spinner regex" | Classifier matches non-spinner content and flags every turn as stalled | No | `node test-conpty/test-attention-false-match.mjs` |
| `test-transcript-emit.mjs` | Parser parity fixtures match what real CC actually emits to JSONL | "Transcript JSONL format" (add row to cc-dependencies) | Hand-crafted parity fixtures drift from CC's real output; parser tests pass but live sessions break | No | `node test-conpty/test-transcript-emit.mjs` |
| `test-hook-relay-roundtrip.mjs` | Hook relay round-trip: PreToolUse hook fires from CC, payload reaches YouCoded's HookRelay with the expected shape | "PreToolUse hook payload" (add row to cc-dependencies) | Hooks run in CC but YouCoded sees nothing, or sees a malformed payload | No | `node test-conpty/test-hook-relay-roundtrip.mjs` |

## When to run

- **Release time** — per the existing release skill's pre-release verification.
- **CC version bumps** — `cc-snapshot.mjs` first; if it diffs against the prior snapshot, run the rest.
- **When changing a probe-relevant area** — e.g. modifying `pty-worker.js` triggers `test-worker-submit.mjs`.

Probes are not run in CI — token cost and CC startup variance don't fit a per-PR check. They're deliberate, on-demand, and Claude can run them.

## Adding a new probe

1. Read `README.md` for the helpers and pitfalls (workspace-trust prompt, slug calculation, ANSI stripping, etc.).
2. Add the probe `.mjs` file in this directory following the `bootClaude()` skeleton.
3. Add a row to this catalog with the coupling it pins, the expected break symptom, and the run command.
4. Add a corresponding row to `youcoded/docs/cc-dependencies.md` so the `review-cc-changes` release agent learns about the coupling.
```

- [ ] **Step 2: Commit**

```bash
git add youcoded/desktop/test-conpty/INDEX.md
git commit -m "docs(test-conpty): add probe catalog INDEX.md"
```

### Task 7.2: test-transcript-emit.mjs probe

**Files:**
- Create: `youcoded/desktop/test-conpty/test-transcript-emit.mjs`

- [ ] **Step 1: Write the probe**

Use `README.md`'s `bootClaude()` skeleton. The probe's logic:
1. Pre-trust a fresh temp cwd.
2. Spawn CC, wait for ready.
3. Send a message that requests a few specific tool calls (e.g., "Run `pwd`, then read `package.json`").
4. Wait until the spinner fires (proves submit), then keep observing for ~30 s to let CC complete.
5. Read back the JSONL from `~/.claude/projects/<slug>/<session>.jsonl`.
6. For each line, run `parseTranscriptLine` and assert the resulting events have expected `kind` values.
7. Print PASS/FAIL with a summary.

```js
// youcoded/desktop/test-conpty/test-transcript-emit.mjs
//
// Pins parser parity to real CC: feeds a controlled prompt, observes the
// JSONL CC actually writes, and asserts every line parses cleanly.

import pty from 'node-pty';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Lazy-import the parser via tsx — same pattern as snapshot.js.
const { register } = await import('tsx/esm/api');
register();
const { parseTranscriptLine, cwdToProjectSlug } = await import(
  path.join(__dirname, '..', 'src', 'shared', 'transcript-parser.ts')
);

// ─── Helpers (copied from cc-snapshot.mjs / README pattern) ─────────────────

function resolveClaudeCommand() {
  const exts = process.platform === 'win32'
    ? (process.env.PATHEXT || '.COM;.EXE;.BAT;.CMD').toLowerCase().split(';')
    : [''];
  const dirs = (process.env.PATH || '').split(path.delimiter);
  for (const dir of dirs) {
    for (const ext of exts) {
      const full = path.join(dir, 'claude' + ext);
      if (fs.existsSync(full)) return full;
    }
  }
  throw new Error('claude not found on PATH');
}

function pretrustCwd(cwd) {
  const cfgPath = path.join(os.homedir(), '.claude.json');
  if (!fs.existsSync(cfgPath)) return;
  const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  cfg.projects = cfg.projects || {};
  const fwd = cwd.replace(/\\/g, '/');
  cfg.projects[fwd] = { ...(cfg.projects[fwd] || {}), hasTrustDialogAccepted: true };
  fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
}

function stripAnsi(s) {
  return String(s)
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '')
    .replace(/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/g, '')
    .replace(/\x1b./g, '');
}

async function bootClaude(cwd) {
  pretrustCwd(cwd);
  const child = pty.spawn(resolveClaudeCommand(), [], {
    name: 'xterm-256color', cols: 120, rows: 30, cwd, env: process.env,
  });
  let buffer = '';
  child.onData((d) => { buffer += stripAnsi(typeof d === 'string' ? d : String(d)); if (buffer.length > 100000) buffer = buffer.slice(-100000); });
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    if (/Welcome|Tips|Recent\s*activity/i.test(buffer)) {
      await new Promise((r) => setTimeout(r, 3500));
      return { child, getBuffer: () => buffer };
    }
    await new Promise((r) => setTimeout(r, 150));
  }
  child.kill();
  throw new Error('CC never reached ready state');
}

// ─── Probe logic ────────────────────────────────────────────────────────────

const TEMP_DIR = path.join(os.tmpdir(), `transcript-emit-${Date.now()}-${Math.random().toString(36).slice(2)}`);
fs.mkdirSync(TEMP_DIR, { recursive: true });
fs.writeFileSync(path.join(TEMP_DIR, 'package.json'), '{"name":"probe","version":"0.0.0"}\n');

const { child, getBuffer } = await bootClaude(TEMP_DIR);

// Send a controlled prompt
const prompt = 'Run `pwd` and then read package.json. Brief output.\r';
child.write(prompt);

// Wait for the spinner — proves submit happened
const submitDeadline = Date.now() + 20000;
while (Date.now() < submitDeadline) {
  if (/[A-Za-z]+ing…/.test(getBuffer())) break;
  await new Promise((r) => setTimeout(r, 200));
}

// Let the turn finish (assistant streams, tools run, JSONL writes)
await new Promise((r) => setTimeout(r, 30000));

// Find the JSONL
const slug = cwdToProjectSlug(TEMP_DIR);
const projectDir = path.join(os.homedir(), '.claude', 'projects', slug);
let sessionJsonl = null;
if (fs.existsSync(projectDir)) {
  const files = fs.readdirSync(projectDir).filter((f) => f.endsWith('.jsonl'));
  if (files.length > 0) sessionJsonl = path.join(projectDir, files[files.length - 1]);
}

child.kill();

if (!sessionJsonl) {
  console.error('FAIL: no JSONL emitted');
  process.exit(1);
}

const jsonl = fs.readFileSync(sessionJsonl, 'utf8');
const lines = jsonl.split('\n').filter(Boolean);

let parsedLines = 0;
let userMsgs = 0, assistantTexts = 0, toolUses = 0, toolResults = 0;
const errors = [];

for (const line of lines) {
  try {
    const events = parseTranscriptLine(line, 'probe-session');
    parsedLines++;
    for (const ev of events) {
      if (ev.kind === 'user-message') userMsgs++;
      else if (ev.kind === 'assistant-text') assistantTexts++;
      else if (ev.kind === 'tool-use') toolUses++;
      else if (ev.kind === 'tool-result') toolResults++;
    }
  } catch (e) {
    errors.push({ line: line.slice(0, 80), error: String(e) });
  }
}

console.log(`Parsed ${parsedLines}/${lines.length} lines.`);
console.log(`  user-message: ${userMsgs}`);
console.log(`  assistant-text: ${assistantTexts}`);
console.log(`  tool-use: ${toolUses}`);
console.log(`  tool-result: ${toolResults}`);

if (errors.length > 0) {
  console.error(`FAIL: ${errors.length} parse errors`);
  for (const e of errors.slice(0, 3)) console.error('  ', e);
  process.exit(1);
}
if (userMsgs < 1 || assistantTexts < 1 || toolUses < 1) {
  console.error('FAIL: expected at least one of each event kind');
  process.exit(1);
}
console.log('PASS');
process.exit(0);
```

- [ ] **Step 2: Run the probe locally to verify it works**

```bash
cd youcoded/desktop && node test-conpty/test-transcript-emit.mjs
```

Expected: prints PASS in ~60s. May fail on first run if CC startup is slow — re-run.

- [ ] **Step 3: Commit**

```bash
git add youcoded/desktop/test-conpty/test-transcript-emit.mjs
git commit -m "feat(test-conpty): probe pinning parser parity to real CC output"
```

### Task 7.3: test-hook-relay-roundtrip.mjs probe

**Files:**
- Create: `youcoded/desktop/test-conpty/test-hook-relay-roundtrip.mjs`

- [ ] **Step 1: Plan the probe shape**

The trickiest probe in the plan because it needs both a CC subprocess AND a fake hook-relay listener (named pipe / Unix socket on the YouCoded side). Strategy:

1. Save the user's current `~/.claude/settings.json` to a temp backup.
2. Write a settings.json that registers a PreToolUse hook pointing at a relay script that writes the payload to a known file.
3. Spawn CC, drive a tool call.
4. Wait for the relay file to appear; read its contents.
5. Assert payload shape (must contain `tool_name`, `tool_input`, `session_id` per `youcoded-core/hooks/` convention).
6. Restore the original settings.json.

> **Adjustment note:** The exact payload shape and named-pipe protocol are documented in `youcoded-core/hooks/relay.js` and `desktop/src/main/hook-relay.ts`. Read both before writing the probe — the contract may have specific keys (`event_type`, `cwd`, etc.) that this probe should assert on. If the hook-relay protocol is materially different from "write payload to a file" (e.g. uses a Windows named pipe or Unix socket the probe must connect to), the probe needs to bind that endpoint itself before spawning CC. Adjust the implementation to match the actual protocol — the goal is an end-to-end assertion that real CC, with a real settings.json hook, delivers a real payload to a YouCoded-style consumer.

- [ ] **Step 2: Implement**

```js
// youcoded/desktop/test-conpty/test-hook-relay-roundtrip.mjs
//
// Pins the PreToolUse hook → relay payload contract end-to-end.
// Saves and restores the user's real settings.json so this probe is
// safe to run on the same machine that has live YouCoded sessions
// (just don't run while one is mid-turn).

import pty from 'node-pty';
import fs from 'fs';
import os from 'os';
import path from 'path';

// Helpers (resolveClaudeCommand, pretrustCwd, stripAnsi, bootClaude) —
// copy from test-transcript-emit.mjs above. Omitted here to keep the plan
// readable; in the actual file, paste them in.

const SETTINGS_PATH = path.join(os.homedir(), '.claude', 'settings.json');
const BACKUP_PATH = SETTINGS_PATH + '.probe-backup';
const PAYLOAD_FILE = path.join(os.tmpdir(), `hook-payload-${Date.now()}.json`);

// 1. Backup
let originalSettings = null;
if (fs.existsSync(SETTINGS_PATH)) {
  originalSettings = fs.readFileSync(SETTINGS_PATH, 'utf8');
  fs.writeFileSync(BACKUP_PATH, originalSettings);
}

// 2. Write a hook script that captures the payload
const HOOK_SCRIPT = path.join(os.tmpdir(), `hook-capture-${Date.now()}.${process.platform === 'win32' ? 'bat' : 'sh'}`);
if (process.platform === 'win32') {
  // Read stdin → file
  fs.writeFileSync(HOOK_SCRIPT, `@echo off\r\nmore > "${PAYLOAD_FILE}"\r\n`);
} else {
  fs.writeFileSync(HOOK_SCRIPT, `#!/bin/sh\ncat > "${PAYLOAD_FILE}"\n`);
  fs.chmodSync(HOOK_SCRIPT, 0o755);
}

// 3. Write probe settings
const probeSettings = {
  ...(originalSettings ? JSON.parse(originalSettings) : {}),
  hooks: {
    PreToolUse: [
      { matcher: '*', hooks: [{ type: 'command', command: HOOK_SCRIPT }] },
    ],
  },
};
fs.writeFileSync(SETTINGS_PATH, JSON.stringify(probeSettings, null, 2));

// 4. Run CC, drive a tool call, wait for payload file to appear
let exitCode = 1;
try {
  const TEMP_DIR = path.join(os.tmpdir(), `hook-probe-${Date.now()}`);
  fs.mkdirSync(TEMP_DIR, { recursive: true });
  // ... bootClaude(TEMP_DIR), send "Run `echo hi`\r", wait for spinner ...
  // ... wait up to 60s for fs.existsSync(PAYLOAD_FILE) ...
  // ... read PAYLOAD_FILE, assert keys: tool_name, tool_input, session_id ...

  // (Implementation continues — see Adjustment note above for the exact
  // payload contract once you've read hook-relay.ts and relay.js.)

  exitCode = 0;
  console.log('PASS');
} catch (e) {
  console.error('FAIL', e);
} finally {
  // 5. Restore
  if (originalSettings != null) {
    fs.writeFileSync(SETTINGS_PATH, originalSettings);
    fs.unlinkSync(BACKUP_PATH);
  } else {
    fs.unlinkSync(SETTINGS_PATH);
  }
  try { fs.unlinkSync(HOOK_SCRIPT); } catch {}
  try { fs.unlinkSync(PAYLOAD_FILE); } catch {}
}
process.exit(exitCode);
```

> **Adjustment note (large):** The bracketed sections above are deliberately incomplete — the probe needs hands-on iteration against the actual hook-relay.ts protocol to pin payload-shape assertions concretely. Treat the file above as the safety scaffold (settings backup/restore, hook command write, cleanup) and fill in the boot/drive/assert middle once you've read the existing relay code and confirmed how YouCoded's hook consumer formats the payload it expects.

- [ ] **Step 3: Run the probe locally**

```bash
cd youcoded/desktop && node test-conpty/test-hook-relay-roundtrip.mjs
```

Expected: PASS. **If it fails the first time, do not commit a broken probe.** Iterate against the real protocol until it passes deterministically. If the probe turns out to be infeasible without bigger refactors (e.g., needing CC to write to a real Unix socket the probe binds), document it in INDEX.md as a deferred probe and ship the rest of Phase 7 without it.

- [ ] **Step 4: Commit (only after green)**

```bash
git add youcoded/desktop/test-conpty/test-hook-relay-roundtrip.mjs
git commit -m "feat(test-conpty): probe pinning PreToolUse hook → relay payload contract"
```

### Task 7.4: Update cc-dependencies.md

**Files:**
- Modify: `youcoded/docs/cc-dependencies.md`

- [ ] **Step 1: Add rows for the two new probes**

Open `youcoded/docs/cc-dependencies.md` and add (or update if rows exist):

- A row for "Transcript JSONL format" pointing at `test-transcript-emit.mjs` as the verification probe.
- A row for "PreToolUse hook payload" pointing at `test-hook-relay-roundtrip.mjs` (or marking it deferred if Task 7.3 deferred).

Match the existing table column shape in that file — don't restructure.

- [ ] **Step 2: Commit**

```bash
git add youcoded/docs/cc-dependencies.md
git commit -m "docs(cc-deps): rows for transcript-emit + hook-relay probes"
```

---

## Self-review — completed inline

The plan covers all spec requirements:

- ✅ Workbench shell (`?mode=workbench`, left-nav, three tabs) → Phase 1
- ✅ Re-export shim → Phase 2
- ✅ Conversations tab + ScenarioProvider → Phase 3
- ✅ Synthetic transcript covering full v1 checklist → Task 3.4
- ✅ Snapshot script (`--diff`/`--update`/`--all`) → Phase 4
- ✅ Smoke test for fixtures → Task 4.3
- ✅ Theme cycle tab → Phase 5
- ✅ Redactor + real-anonymized bundle → Phase 6
- ✅ Probe library catalog + 2 new probes → Phase 7
- ✅ Updated `cc-dependencies.md` → Task 7.4

Out-of-scope items from the spec (no screenshots, no Playwright, no CI for probes, no overlays tab, no Android workbench, no live recording) are simply absent — none of the tasks touch them.

The "adjustment notes" embedded throughout flag the four spots where the plan makes assumptions that must be verified against current code before writing (chat-types field names, ScenarioProvider context override mechanism, theme-data scoping, hook-relay payload shape). These are deliberate handoff points to the engineer, not placeholders.
