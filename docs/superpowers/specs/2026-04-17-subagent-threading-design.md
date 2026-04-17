# Subagent Transcript Threading — Design Spec

**Date:** 2026-04-17
**Status:** Approved, ready for implementation plan
**Repo scope:** `youcoded/` (desktop + Android)

## Problem

When Claude invokes a subagent via the Task tool (`tool_use` with `name: "Agent"`), the parent's AgentView card in the Chat View stays blank until the subagent completes. Only the final text response is rendered. The subagent's internal work — tool calls, intermediate narration, progress — is invisible during what is often the longest-running portion of a turn.

Subagents can emit dozens of tool calls and run for minutes. A blank spinner for that duration is a poor experience, and when a subagent stalls or goes down a wrong path, the user has no signal.

## Background

Claude Code writes subagent work to its own JSONL files, **not** inline in the parent transcript:

```
~/.claude/projects/<project-slug>/<parent-session-id>/subagents/
  agent-<agentId>.jsonl         # streaming transcript, lines have isSidechain:true
  agent-<agentId>.meta.json     # { "agentType": "Explore", "description": "..." }
```

Verified on disk in project transcripts:

- Subagent JSONL lines carry `isSidechain: true`, a stable `agentId`, and the parent's `sessionId`. Tool calls, tool results, and assistant text all appear as normal `message.content[]` blocks.
- Entries **stream in live** — timestamps show ~250ms–3s gaps between lines, matching real-time work; the file is not batched on completion.
- Subagent file appears on disk ~1s after the parent emits the Agent `tool_use`.
- No subagent has ever spawned a nested subagent in project history — no recursive `subagents/` dirs exist. This design targets exactly one level of nesting.

**Correlation problem:** the parent's Agent `tool_use` block (`id: toolu_…`) does not contain the subagent's `agentId` or filename. `meta.json` carries `description` and `agentType`, which match the parent's `input.description` and `input.subagent_type`. In a sample session with 26 Agent calls, descriptions were all unique; collisions are possible (e.g. `dispatching-parallel-agents` firing two "Review this diff" calls in one turn) but empirically rare.

## Goals

1. Subagent tool calls and narration stream live into the parent's AgentView card.
2. Resuming or re-docking a session rebuilds past subagent timelines from disk.
3. Final reply still renders through the existing `tool_result` path.
4. Desktop + Android parity — the React UI is shared; both platforms' watchers must emit the new event fields.
5. No regressions in existing transcript parsing, reducer invariants, or IPC parity.

## Non-goals

- Nested subagents (subagent spawning its own subagent). Doesn't happen on disk; defer.
- Retroactive correlation via `promptId` when FIFO binding is wrong. Collisions are rare enough that FIFO is sufficient.
- On-demand "expand to fetch" UX. Full replay from disk is simpler and the data is already local.

## Design

### Architecture & data flow

Components introduced and modified:

- **`SubagentIndex`** (new, `desktop/src/main/subagent-index.ts`) — per-parent-session in-memory correlation map. Tracks `agentId → parentAgentToolUseId` bindings. Maintains a queue of unmatched parent Agent `tool_use`s (by emit order) and a lookup for unmatched subagent bindings. Pure logic, unit-testable.
- **`SubagentWatcher`** (new, `desktop/src/main/subagent-watcher.ts`) — one instance per parent session. Watches `<parent>/subagents/` directory with `fs.watch` and a 1s poll safety net. On new `agent-*.jsonl`, reads the sibling `.meta.json`, calls `SubagentIndex.bindSubagent`, then runs a byte-offset reader on the subagent file. Emitted events carry `parentAgentToolUseId` and `agentId`.
- **`TranscriptWatcher`** (modified) — instantiates one `SubagentIndex` + `SubagentWatcher` per session on `startWatching`. When its parser yields a `tool-use` with `toolName === 'Agent'`, calls `index.recordParentAgentToolUse` before emitting. Extends `getHistory` to replay subagents after the parent JSONL.
- **`ByteOffsetJsonlReader`** (new, `desktop/src/main/byte-offset-jsonl-reader.ts`) — extraction of the existing `readNewLines` logic (partial-line buffering, sliding `seenUuids` window, Windows fs.watch + poll safety net, truncation detection). Used by both `TranscriptWatcher` (parent JSONL) and `SubagentWatcher` (per-subagent-file).
- **TranscriptEvent** (modified) — `data` gains two optional fields: `parentAgentToolUseId?: string`, `agentId?: string`. No new event types; no new IPC channels.
- **Reducer** (modified) — the existing `TRANSCRIPT_TOOL_USE`, `TRANSCRIPT_TOOL_RESULT`, `TRANSCRIPT_ASSISTANT_TEXT` handlers branch to `applySubagentEvent` when `parentAgentToolUseId` is present.
- **`ToolCallState`** (modified) — gains `subagentSegments?: SubagentSegment[]`, `agentType?: string`, `agentId?: string` for Agent tools.
- **`SubagentTimeline`** (new, `desktop/src/renderer/components/tool-views/SubagentTimeline.tsx`) — renders a subagent's segments inside AgentView.
- **`AgentView`** (modified, `tool-views/ToolBody.tsx:647`) — adds a collapsible "Show agent activity" section between the briefing and the reply.

#### Live data flow

```
Parent JSONL line: tool_use {name:"Agent", id:toolu_X, input:{description, subagent_type}}
  → TranscriptWatcher.parseTranscriptLine → tool-use event (unchanged)
  → TranscriptWatcher.recordAgentToolUse() → SubagentIndex queues unmatched parent
  → emit → renderer → TRANSCRIPT_TOOL_USE → toolCalls.set(toolu_X, {toolName:"Agent", …})

~1s later — fs.watch fires on <parent>/subagents/:
  → SubagentWatcher sees agent-abc.jsonl appear
  → reads agent-abc.meta.json → {agentType, description}
  → SubagentIndex.bindSubagent(meta) → returns toolu_X
  → SubagentWatcher opens a ByteOffsetJsonlReader on agent-abc.jsonl

For each line in agent-abc.jsonl:
  → parseTranscriptLine (same parser as parent)
  → stamp parentAgentToolUseId=toolu_X, agentId="abc" on event
  → emit → renderer → TRANSCRIPT_TOOL_USE (nested branch)
  → applySubagentEvent: toolCalls.get(toolu_X).subagentSegments.push(...)
```

#### Resume / re-dock data flow

On `startWatching`, before attaching live watchers:

1. Parent JSONL replayed from offset 0 — parent Agent `tool_use` events populate `SubagentIndex.unmatchedParents` first.
2. Enumerate `<parent>/subagents/*.meta.json`, bind each subagent to its parent via the index, replay each subagent JSONL fully.
3. Then attach live `fs.watch` for both parent JSONL and the subagents directory.

Disk-is-source-of-truth semantics, same as the parent transcript today. Remote-server replay (the desktop main process ships `getHistory` results to connected browser tabs) gets nested state rebuilt for free.

### Event shape

`TranscriptEvent.data` (in `desktop/src/shared/types.ts`) adds:

```ts
data: {
  // …existing fields (text, toolUseId, toolName, toolInput, toolResult, isError, stopReason, structuredPatch)
  /** Present only on events emitted from a subagent JSONL. */
  parentAgentToolUseId?: string;
  agentId?: string;
}
```

No new `TranscriptEventType`. Legacy consumers that don't know about subagents keep working — reducer handlers branch on presence of the new fields.

### State shape

`ToolCallState` (in `desktop/src/shared/types.ts`) adds:

```ts
interface ToolCallState {
  // …existing fields
  /** Populated for tools where toolName === 'Agent'. */
  subagentSegments?: SubagentSegment[];
  /** Copied from meta.json once the subagent is bound. */
  agentType?: string;
  /** Stable subagent ID — matches filename agent-<agentId>.jsonl. */
  agentId?: string;
}

type SubagentSegment =
  | { type: 'text'; id: string; content: string }
  | { type: 'tool'; id: string; toolUseId: string; toolName: string;
      input: Record<string, unknown>; status: 'running' | 'complete' | 'failed';
      response?: string; error?: string; structuredPatch?: StructuredPatchHunk[] };
```

`SubagentSegment` is deliberately narrower than `ToolCallState`:

- No `awaiting-approval` / `requestId` / `permissionSuggestions` — subagents don't hit the hook-relay permission flow.
- No tool groups — flat list inside the subagent.
- No turn tracking — subagent completion is signaled by the parent Agent tool's `tool_result`, not by a nested turn-complete event.

The parent AgentView's `subagentStatus` is derived, not stored: `tool.response ? 'complete' : 'running'`.

### Reducer changes

Each of `TRANSCRIPT_TOOL_USE`, `TRANSCRIPT_TOOL_RESULT`, `TRANSCRIPT_ASSISTANT_TEXT` starts with:

```ts
if (action.parentAgentToolUseId) {
  return applySubagentEvent(state, action);
}
```

`applySubagentEvent` is the single new function for all nested mutation:

1. Looks up `toolCalls.get(parentAgentToolUseId)`. If missing, returns state unchanged.
2. Appends or updates the matching `SubagentSegment` by `toolUseId` (tools) or segment `id` (text).
3. Returns new state with the updated tool entry.

`TRANSCRIPT_TURN_COMPLETE` events that carry `parentAgentToolUseId` are ignored — subagent completion is signaled by the parent's `tool_result`.

#### Invariants preserved

- `toolCalls` Map is still never cleared. Subagent tools live inside `subagentSegments`, not in the top-level Map.
- `activeTurnToolIds` does **not** include subagent-internal tools. `endTurn()` unchanged.
- Subagent events do **not** reset `attentionState` to `'ok'`. Only the parent's activity resets attention — subagent writes could race with genuine main-session idle.
- Content-based dedup on user messages is unchanged — subagents don't emit user messages from the chat user's perspective.

### UI

`SubagentTimeline` renders segments inside AgentView:

```tsx
<div className="subagent-timeline border-l border-edge-dim pl-3 ml-1 space-y-1.5">
  {segments.map(seg =>
    seg.type === 'text'
      ? <SubagentText key={seg.id} content={seg.content} />
      : <SubagentToolRow key={seg.id} tool={seg} />
  )}
</div>
```

- Single vertical left border framed with `border-edge-dim` signals "nested work."
- Text size `text-xs`, tighter row spacing than top-level tools — keeps 20+ rows scannable.
- `SubagentToolRow` dispatches through the existing `ToolBody` component for the specific tool name. Tool views read only from `tool.input / .response / .status / .error / .structuredPatch`, so they work unchanged wrapped in a denser row.
- `SubagentText` is `MarkdownContent` at `text-xs` for short "I'll start by reading…" narration.

AgentView adds a collapsible section between briefing and reply:

```tsx
{tool.subagentSegments && tool.subagentSegments.length > 0 && (
  <div>
    <button onClick={() => setShowTimeline(s => !s)}>
      {showTimeline ? 'Hide agent activity' : `Show agent activity (${segCount})`}
    </button>
    {showTimeline && <SubagentTimeline segments={tool.subagentSegments} />}
  </div>
)}
```

**Expand-default logic:**

- While `tool.status === 'running'` or `!tool.response`: `showTimeline` defaults to `true`.
- When `tool.response` transitions undefined → defined, auto-collapses once.
- User manual toggle sets a `userToggled` flag — auto-collapse respects it.

Per `.claude/rules/react-renderer.md`, rows apply `content-visibility: auto` to avoid laying out offscreen content on large subagents.

### Android parity

Android already has its own `TranscriptWatcher.kt`, `TranscriptEvent.kt`, and `TranscriptSerializer.kt`. The React renderer is shared, so reducer + UI changes apply unchanged.

Kotlin additions mirror the TypeScript additions:

- `TranscriptEvent.kt` — two optional fields: `parentAgentToolUseId: String?`, `agentId: String?`.
- `TranscriptSerializer.kt` — serializes both optional keys when present, omits when absent.
- New `SubagentIndex` Kotlin class — same FIFO correlation logic.
- New `SubagentWatcher` Kotlin class — uses `FileObserver` (already imported by the existing watcher) with a coroutine-based poll fallback.
- Extract `ByteOffsetJsonlReader` helper in Kotlin (same responsibility as the TypeScript helper).
- Existing `TranscriptWatcher.kt` calls `index.recordParentAgentToolUse(...)` when it parses an Agent `tool_use`.

No new IPC message types. The WebSocket still carries `transcript-event` frames; only the payload grows two optional fields. `preload.ts` / `remote-shim.ts` / `SessionService.kt` parity stays exact — this is the main reason Approach 1 was chosen over dedicated `subagent-*` event types.

**Open verification:** Claude Code on Android must be confirmed to write `<parent-session-id>/subagents/` the same way it does on desktop. The implementation plan schedules this as the first Android-side task so a gap is caught early. If Android doesn't write subagent files, Android parity falls back to today's behavior (blank card until complete). In that case, `docs/PITFALLS.md` gains an entry under the Cross-Platform section documenting the limitation, and a knowledge-debt entry tracks the follow-up.

### Error handling & edge cases

- **Unbound subagent events** (parent Agent `tool_use` parsed but `TRANSCRIPT_TOOL_USE` hasn't dispatched yet): `applySubagentEvent` bails silently when the parent tool is missing from `toolCalls`. On resume this is impossible (parent replays first). Live-streaming could drop at most one or two subagent events before the parent tool_use catches up — acceptable.
- **Orphaned subagent files** (parent Agent call aborted mid-turn; subagent file already exists): binding still happens; events thread into the failed tool. Visually: timeline shows real work up to abort, then stops.
- **Missing or malformed `meta.json`**: watcher logs and skips. Parent card stays as today.
- **Subagent completes with no parent binding**: watcher buffers events in a per-session pending-bindings map, keyed by `agentId`. Each unbound entry carries a wall-clock timestamp of the first buffered event; entries are dropped 30s after that timestamp. If a matching parent Agent `tool_use` arrives within the window, bind retroactively and flush buffered events in order. Bounds memory on pathological cases.
- **Dedup:** each subagent file has its own byte-offset tracker and sliding `seenUuids` window (via `ByteOffsetJsonlReader`). On restart, replay from offset 0 doesn't double-emit.
- **`CLEAR_TIMELINE`:** drops parent tool's visible timeline but keeps `toolCalls` (existing invariant). `subagentSegments` ride along; invisible because the tool is off-timeline.
- **Crash mid-subagent:** `SubagentIndex` is in-memory only, rebuilt deterministically on every `startWatching` via parent-then-subagents replay.
- **Windows fs.watch flakiness:** inherited from existing TranscriptWatcher — fs.watch + 1s poll safety net on the directory, 2s poll-alongside-watch on each active subagent file.
- **Large subagents** (100+ tool events): `SubagentTimeline` rows use `content-visibility: auto`. No virtualization (breaks find-in-page per renderer rules).

### Testing

New test files in `youcoded/desktop/tests/`:

**`subagent-index.test.ts`** — pure unit tests:
- Single parent + single subagent: binds correctly
- Parent Agent tool_use before subagent: subagent binds to queued parent
- Subagent before parent tool_use: subagent buffers, binds on parent arrival
- Two parallel parents with identical `description` + `subagent_type`: FIFO-by-ctime pairing
- Unknown `subagent_type`: events drop after 30s age-out
- `unbind()` cleans up on subagent completion

**`subagent-watcher.test.ts`** — integration against a temp dir, mirroring `transcript-watcher.test.ts`:
- Directory doesn't exist at start, picks up subagent when parent first writes
- New `.jsonl` + `.meta.json`: events emit with correct stamps
- Incremental writes: byte offset advances
- Dedup: re-read from offset 0 emits no duplicates
- Historical replay: parent events first, subagents after binding
- Subagent file deleted: watcher cleans up without crash

**`transcript-watcher.test.ts` additions** — verify Agent `tool_use` still emits unchanged and calls `index.recordParentAgentToolUse` with correct args.

**`transcript-reducer.test.ts` additions:**
- `TRANSCRIPT_TOOL_USE` with `parentAgentToolUseId` → `subagentSegments` appends; `toolGroups` and `activeTurnToolIds` unchanged
- `TRANSCRIPT_TOOL_RESULT` with `parentAgentToolUseId` → segment flips to complete with response
- `TRANSCRIPT_ASSISTANT_TEXT` with `parentAgentToolUseId` → text segment appended
- `TRANSCRIPT_TURN_COMPLETE` from subagent → reducer ignores; `endTurn()` not called
- Subagent event for unknown parent → no state change, no throw
- `CLEAR_TIMELINE` → `toolCalls` entries with `subagentSegments` survive

**`subagent-view.test.tsx`:**
- Renders nothing when `subagentSegments` is empty or undefined
- Auto-expanded while tool is `running`
- Auto-collapses when `response` transitions undefined → defined
- Respects user-toggled state after auto-collapse

**Android Kotlin tests:**
- `SubagentIndexTest.kt` — mirrors TypeScript unit tests
- `SubagentWatcherTest.kt` — mirrors TypeScript integration tests
- `TranscriptSerializerTest.kt` — gains a case for the two new optional fields round-tripping

**Manual verification checklist** (in the implementation plan):
- Kick off a Plan-agent subagent in the dev build, confirm timeline streams live
- Kick off parallel Explore + Plan (`dispatching-parallel-agents` skill), confirm both thread independently
- Resume a session with completed subagents, confirm historical timelines render
- Repeat all three on an Android build

## Alternatives considered

**Approach 2 — dedicated subagent event types + separate thread map:** Cleaner conceptual separation, but doubles the IPC event surface. Every new channel would need `preload.ts` + `remote-shim.ts` + `SessionService.kt` parity work. Rejected: the separation doesn't buy enough to justify the drift risk.

**Approach 3 — treat each subagent as a nested sub-session:** Subagent gets a full mini `SessionChatState` inside the parent tool; reducer recurses. Most abstract, but entangles state shape, memoization, and the `toolCalls` Map invariants. Rejected: over-engineered for "one level deep, no recursion."

**Retroactive correlation via `promptId`:** Parent's `tool_result` for Agent carries the same `promptId` as the subagent's first user line. Would fix FIFO mis-pairings on parallel identical descriptions. Rejected: collisions haven't occurred in 26 historical Agent calls; the added reducer complexity doesn't match the risk profile.

## Risks

- **Android file-path assumption.** We assume Claude Code on Android writes `<parent>/subagents/` at the same relative path. If it doesn't, Android parity degrades to today's behavior. Verified early in the plan.
- **Parser reuse.** Reusing `parseTranscriptLine` assumes subagent lines are structurally identical to parent lines. Verified against real disk samples, but a future Claude Code CLI version could diverge. The version-anchor comment at the top of `attention-classifier.ts` is the existing precedent for handling CLI-version sensitivity; apply the same pattern here.
- **FIFO collision mis-pairing.** On parallel identical descriptions, wrong subagent can thread to wrong card. User still sees live streaming — just potentially crossed between two identical cards. Acceptable and rare.
- **Memory growth on aborted sessions.** Unmatched-parent queue and pending-bindings buffer both age out on `stopWatching` / 30s. No unbounded growth.
