# Remote Access State Sync — Design Spec

**Status:** Draft
**Date:** 2026-04-17
**Scope:** `youcoded/desktop/`

## Problem

Two observable gaps when a device connects to the desktop app via remote access:

1. **Chat history is blank.** The remote browser renders an empty chat timeline until new activity arrives. All prior user messages, assistant text, tool calls, and results are missing until the next turn.
2. **Status indicator lights are wrong.** The `StatusDot` and `AttentionBanner` do not match what the desktop shows. A desktop session stuck on "awaiting input" looks "thinking" on the remote (or vice versa).

## Root causes

### Issue 1 — chat history

`remote-server.ts::replayBuffers()` sends session list, per-session metadata, PTY buffer, and hook events on new-client connect. It does **not** send the transcript history. The server does buffer transcript events via `bufferTranscriptEvent()`, but the replay block for those buffers is missing.

### Issue 2 — status indicators

Two independent causes:

- `attentionState` is classifier-driven on the desktop only. `useAttentionClassifier` reads the xterm buffer every 1s, maps the tail to an `AttentionState`, and dispatches `ATTENTION_STATE_CHANGED` into the local reducer. Remote clients never see this — they have no way to compute or receive it.
- `isThinking` and `activeTurnToolIds` are reconstructible from transcript events, but because Issue 1 drops those on connect, any in-flight state is invisible until the next event.

Fixing Issue 1 substantially resolves the transcript-derived parts of Issue 2 for free. `attentionState` still needs its own channel.

## Design

Two independent mechanisms:

- **(A) Chat hydration** — one-shot on remote connect. Desktop serializes its per-session chat state into a snapshot; server pushes it; remote reducer applies it.
- **(B) Attention broadcast** — live. Attention changes flow from the renderer to the main process, get folded into the existing `status:data` payload, and are pushed both on-change and on the 10s timer.

Intentionally separate: (A) bootstraps, (B) keeps state aligned.

### (A) Chat hydration

#### Serialization

`SessionChatState` holds three `Map`s (`toolCalls`, `toolGroups`, `assistantTurns`) and one `Set` (`activeTurnToolIds`). The top-level `ChatState` is itself `Map<sessionId, SessionChatState>`.

Add two pure helpers to `src/renderer/state/chat-types.ts`:

- `serializeChatState(state: ChatState): SerializedChatState` — converts every Map to `[[key, value], ...]` tuples and every Set to an array. JSON-safe.
- `deserializeChatState(s: SerializedChatState): ChatState` — inverse.

All serialization logic lives in one place alongside the type definitions.

#### Handshake

Source of truth is the renderer's reducer, not the main process. On new-client auth, the server requests a snapshot from the renderer via a new IPC channel:

- Renderer registers `chat:get-hydrate-snapshot` which calls `serializeChatState(currentChatState)` and returns the result.
- `remote-server.ts` invokes it on connect (via `webContents.send` + response channel), then sends `{ type: 'chat:hydrate', payload: <snapshot> }` to the connecting client only — not broadcast.

No server-side cache. Snapshots are rare (one per connect) and cheap to build.

#### Ordering in `replayBuffers()`

```
1. Session list                    (existing)
2. Per-session metadata            (existing)
3. chat:hydrate                    (NEW)
4. After 500ms: PTY + hook buffers (existing)
```

Hydrate before PTY/hooks so the reducer has state to merge into when live/replayed events arrive.

#### Reducer action

```ts
| { type: 'HYDRATE_CHAT_STATE'; sessions: SerializedChatState }
```

Handler replaces the entire `ChatState` Map outright. Remote-only, fires once per connect, so no dedup concern. Later events are idempotent:

- Tool events keyed by `toolUseId` (update-in-place)
- Assistant text keyed by `messageId`
- User messages dedup via content match against last 10 entries (existing behavior)

### (B) Attention broadcast

#### Payload

Extend `buildStatusData()` in `ipc-handlers.ts` with:

```ts
attentionMap: Record<desktopSessionId, AttentionState>
```

`AttentionState` is the existing union: `'ok' | 'awaiting-input' | 'shell-idle' | 'error' | 'stuck' | 'session-died'`.

#### Renderer → main

The renderer's reducer holds `attentionState` per session; the main process does not. Bridge via a push model:

- New `useRemoteAttentionSync` hook in `src/renderer/hooks/` listens for `attentionState` changes per session and fires `window.claude.fire('remote:attention-changed', { sessionId, state })`. Co-located with `useAttentionClassifier`.
- Main process keeps a `lastAttentionBySession: Map<string, AttentionState>` updated by that fire. `buildStatusData()` reads from it.
- Guard the fire with `if (remoteServer.hasClients())` so it's a no-op when no one's connected.

#### Live broadcast on change

After updating `lastAttentionBySession`, main calls `remoteServer.broadcastStatusData(buildStatusData())` immediately instead of waiting for the 10s timer. Payload is cheap.

#### Remote side

The existing `status:data` handler in `remote-shim.ts` gains a diff step: if `payload.attentionMap` contains per-session values differing from the last received payload, dispatch `ATTENTION_STATE_CHANGED` for each changed session into the chat reducer. Diff-before-dispatch prevents thrashing on every 10s tick.

#### Initial state on connect

The first `status:data` after connect carries the full current `attentionMap` (populated from the push-model cache). Combined with `chat:hydrate` already carrying each session's `attentionState` field, the remote starts correct and stays aligned on changes. No gap window.

#### Why reuse `status:data` instead of a dedicated event

`status:data` already aggregates live state bound for the status bar. One fewer message type to define, test, and keep parity across `preload.ts` / `remote-shim.ts`. The payload grows by one field.

## Error handling

- **Serialization:** pure and synchronous. No IO, no failure modes short of OOM. No try/catch.
- **Renderer not ready on connect:** IPC invoke for `chat:get-hydrate-snapshot` times out after 2s. Server falls back to `chat:hydrate` with empty `sessions: []`. Remote starts empty and repopulates from live events — equivalent to today's behavior. Log at warn level.
- **Malformed snapshot at remote:** if `deserializeChatState` throws, catch in the reducer handler and log; leave existing state untouched.

## Testing

### Unit tests

- `serializeChatState` / `deserializeChatState` round-trip for a session containing tool calls, tool groups, assistant turns, active turn tool IDs, compaction-pending state.
- Reducer: `HYDRATE_CHAT_STATE` replaces state; a subsequent `TRANSCRIPT_TOOL_USE` with a hydrated `toolUseId` updates in place without duplicating.
- Reducer/shim: a `status:data` arrival with `attentionMap` dispatches `ATTENTION_STATE_CHANGED` only for sessions whose state differs from the prior payload.

### Integration

- Remote client connects mid-session; rendered timeline matches desktop at that moment.
- Remote client connects while desktop is in `'awaiting-input'`; `AttentionBanner` renders immediately, not on next transcript event.

## Edge cases

- **Session switch on remote:** hydration covers all sessions. No re-hydrate needed.
- **Session created after connect:** existing `session:created` event + live transcript events populate it. No special case.
- **Session removed:** existing `SESSION_REMOVE` flow handles both sides.
- **Multiple remote clients:** snapshot is per-connect (unicast). `status:data` stays broadcast.
- **Attention state for sessions no one is viewing:** classifier only ticks for the visible session. `attentionMap` may omit inactive sessions; remote treats missing entries as `'ok'` (matches `endTurn()` reset).
- **Snapshot size:** typical 500-entry session with tool calls serializes to ~100–500 KB JSON. Acceptable for a one-shot push. Lazy per-session hydration on switch is the future mitigation if this becomes a problem.

## Non-goals

- **Persistence across desktop restarts.** After a restart, in-memory `ChatState` is lost and rebuilt by `TranscriptWatcher` from on-disk JSONL files. Remote hydration inherits that behavior — it is not a durable transcript store.
- **Remote-side attention classifier.** Desktop is the single source of truth. Running the classifier independently on remote would duplicate CLI-version-sensitive logic and risk drift.
- **Other out-of-sync renderer state** (theme, layout, font). Not observed as a reported issue; out of scope.

## Files touched

| File | Change |
|---|---|
| `src/renderer/state/chat-types.ts` | Add `SerializedChatState`, `serializeChatState`, `deserializeChatState`; add `HYDRATE_CHAT_STATE` action variant |
| `src/renderer/state/chat-reducer.ts` | Handle `HYDRATE_CHAT_STATE` |
| `src/renderer/hooks/useRemoteAttentionSync.ts` | NEW — fires `remote:attention-changed` on reducer state diffs |
| `src/renderer/remote-shim.ts` | Handle `chat:hydrate` push; diff `attentionMap` in `status:data` handler |
| `src/main/preload.ts` | Register `chat:get-hydrate-snapshot` channel + `remote:attention-changed` channel |
| `src/main/ipc-handlers.ts` | Track `lastAttentionBySession`; extend `buildStatusData()` with `attentionMap`; broadcast on attention change |
| `src/main/remote-server.ts` | Send `chat:hydrate` in `replayBuffers()`. Remove the dead `transcriptBuffers` buffering path — hydration supersedes it, and leaving unused buffering code around invites confusion. |
| `src/renderer/state/__tests__/chat-reducer.test.ts` | Add hydration + serialization tests |

## Open questions

None at design time.
