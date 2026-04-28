---
date: 2026-04-27
status: approved
topic: message-send-queue
---

# Message Send Queue — Design

## Problem

Today, every user message in YouCoded is written to Claude Code's PTY immediately. There is no equivalent of CC's "type-ahead while thinking" workflow that users can see or control. Three concrete problems:

1. **No back-pressure or visibility.** Users can fire several messages while CC is mid-turn with no indication that messages 2/3/4 are stacking up. CC's input bar absorbs them but the trailing `\r` on type-ahead during a turn often gets reclassified as paste content (CC v2.1.119, ~64-byte threshold), leaving messages wedged in the input bar with no auto-submit when the turn ends.
2. **Chat view can drift from transcript order.** The `pending`-flag dedup mechanism preserves order when send order matches transcript order, but Android lacks input serialization on `PtyBridge.writeInput` — concurrent writes can interleave (e.g. msg-1 body + msg-2 body + msg-1 delayed `\r` + msg-2 delayed `\r`), producing real data corruption.
3. **No source-of-truth confirmation surfaced to the user.** Optimistic bubbles look identical to confirmed ones; the user has no signal that a message is in flight vs. acknowledged by CC's transcript.

The goal is a YouCoded-managed queue that gates sends to safe moments, surfaces queue state in chat view, gives the user fine control (edit/reorder/cancel/pause/force), and uses transcript events as the source of truth for "Claude has actually received this" — with chat-view order always matching transcript order.

This work also unifies desktop and Android by porting the desktop `pty-worker.js` echo-driven submit + input serialization to `PtyBridge.kt`.

## Decisions

- **Queue is YouCoded-managed (Approach B from brainstorm).** We own the queue; CC's input bar is only written to when our gate opens (or when force-send bypasses the gate).
- **Force-send is "interrupt then send."** Per-item button on a queued bubble (and a "send now" affordance from InputBar). Force always sends `\x1b` first, waits for CC to return to idle, then writes the message. This sidesteps the paste-classification race entirely because CC is idle by the time we write the body. Force-send bypasses the queue gate and the global pause, but is **disabled while a permission/approval prompt is open** — sending `\x1b` to a permission prompt would deny it, conflating chat send with permission decision.
- **Gray-pending styling on force-sent messages.** Tooltip "Claude has not yet seen this message" persists until transcript confirms.
- **Inline ghost bubbles in the chat timeline.** Queue is rendered as additional bubbles after confirmed/pending messages, in queue order. No separate strip or modal.
- **Operations supported:** edit-in-place, drag-reorder, cancel (X button) for queued items.
- **Esc auto-pauses.** Esc still interrupts the current turn AND sets the queue to paused with reason `'esc-interrupt'`. User must explicitly unpause to resume.
- **Single global pause toggle.** No per-item pause. Force-send still works while paused (force is the override).
- **Terminal-typed messages: out of scope.** Continue current behavior — they appear in chat view as confirmed bubbles when transcript reveals them.
- **Architecture: renderer-side queue (Approach 1 from brainstorm).** Queue lives in `chat-reducer.ts` state per session. Single implementation in shared React renderer covers desktop + Android WebView + remote browser. No new IPC types required.
- **Companion work bundled in:** port echo-driven submit + per-session Mutex serialization from `pty-worker.js` to `PtyBridge.writeInput` so Android force-send is as safe as desktop.
- **Persistence: deferred.** Queue state lives in renderer Redux; lost on full reload. Queued-but-unsent items are recoverable by the user retyping; not destructive in the way losing transcript content would be.

## Architecture

### State (added to `ChatSessionState` in `chat-reducer.ts`)

```ts
interface QueuedMessage {
  id: string;
  text: string;
  attachments?: AttachmentRef[];
  createdAt: number;
  releasing?: boolean;  // transient: set during the dispatch→sendInput microtask, cleared by reducer
}

interface ChatSessionState {
  // ...existing fields
  queue: QueuedMessage[];
  queuePaused: boolean;
  queuePauseReason: 'manual' | 'esc-interrupt' | 'session-died' | null;
}
```

The existing `messages` timeline keeps `pending: true` semantics unchanged. Queued items live in `queue`, not `messages`, until released.

Released bubbles use a new `forceSend?: boolean` flag on the message entry — drives gray styling and "Claude has not yet seen this" tooltip until transcript clears `pending`.

A new `failed?: boolean` flag drives the post-60s "Claude may not have received this. [Retry] [Discard]" affordance.

### New reducer actions

| Action | Purpose |
|--------|---------|
| `QUEUE_ENQUEUE` | Append `{ text, attachments }` to `queue`. |
| `QUEUE_RELEASE_HEAD` | Move head item out of `queue`, append to `messages` with `pending: true, forceSend: false`. |
| `QUEUE_FORCE_SEND` | From queue (id) or InputBar (text): append to `messages` with `pending: true, forceSend: true, awaitingInterrupt: true`; remove from queue if applicable. Triggers the interrupt-then-send coordinator. No-op if `permissionPending`. |
| `QUEUE_EDIT` | Update `text` on matching id in `queue`. No-op if not in queue. |
| `QUEUE_REORDER` | Move queued item to new index. No-op on items with `releasing: true`. |
| `QUEUE_REMOVE` | Delete from queue. No-op on missing or releasing items. |
| `QUEUE_PAUSE` / `QUEUE_UNPAUSE` | Flip `queuePaused`; set/clear `queuePauseReason`. |
| `MESSAGE_FAIL_PENDING` | Set `failed: true` on a pending message after the 60s max-age. |

`SESSION_PROCESS_EXITED` is extended to additionally dispatch `QUEUE_PAUSE({ reason: 'session-died' })`.

### Gate logic — `useQueueReleaser(sessionId)` hook

New shared React hook (mirrors `useAttentionClassifier`'s pattern). Runs in renderer; works on desktop, Android WebView, and remote browser identically.

Gate condition (re-evaluated whenever any input changes):

```
canRelease = !queuePaused
          && !isThinking
          && attentionState === 'ok'
          && !permissionPending
          && queue.length > 0
          && !queue[0].releasing
```

When `canRelease`:
1. Dispatch `QUEUE_RELEASE_HEAD` (which sets `releasing: true` then synchronously moves the item).
2. Call `window.claude.session.sendInput(sessionId, text + '\r')`.

The release moves the bubble from queued styling (dotted border, queue badge, controls) to standard `pending: true` styling. From there the existing transcript-confirm flow takes over: pty-worker echo-driven submit fires, CC processes, `TRANSCRIPT_USER_MESSAGE` arrives, reducer matches oldest pending entry by content, clears `pending` flag.

### Force-send — interrupt-then-send

`QUEUE_FORCE_SEND` is a no-op when `permissionPending` (the force button is disabled in that state, but the reducer also gates as a safety net).

Otherwise:
1. Append message to `messages` with `pending: true, forceSend: true, awaitingInterrupt: true`. Remove from queue if id was provided.
2. Immediately send `\x1b` byte via `sendInput(sessionId, '\x1b')`.
3. A new `useForceSendCoordinator(sessionId)` hook watches messages with `awaitingInterrupt: true`. When `attentionState` flips to `'ok'` AND `isThinking` is false (CC has finished interrupting), it dispatches `FORCE_SEND_DELIVER({ id })` which clears `awaitingInterrupt` and calls `sendInput(sessionId, text + '\r')`.
4. Fallback: if `awaitingInterrupt` stays true for 3 seconds (interrupt didn't land), the coordinator sends the message anyway. The 60s `MESSAGE_FAIL_PENDING` and the existing `useSubmitConfirmation` retry catch the residual case.

The `\x1b` byte sent to an idle CC is benign — no turn to interrupt. The "always interrupt" policy is intentional: it keeps the force-send code path uniform regardless of CC state, and avoids the edge case where mid-typing-in-xterm + force-send misclassifies CC as idle.

Gray styling persists across all three states (`awaitingInterrupt`, then `pending` post-deliver, until transcript clears `pending`).

### Esc handling

The existing chat-passthrough Esc handler in `App.tsx` is extended to additionally dispatch `QUEUE_PAUSE({ reason: 'esc-interrupt' })`. The `\x1b` byte still goes to the PTY as today.

### UI

- **Chat timeline** renders `[...messages, ...queue]`. Queued bubbles have dotted border, "queued" badge, and controls (edit pencil, drag handle, cancel X, force-send button). Pending bubbles with `forceSend: true` are visually grayed and show the "Claude has not yet seen this message" tooltip on hover.
- **InputBar** gains a small pause/play toggle next to send. Active pause shows a tooltip with `queuePauseReason` ("Paused after Esc" / "Paused" / "Session ended").
- **Failed bubbles** render with a warning chevron and inline `[Retry] [Discard]` buttons. Retry re-enqueues at head (respecting current pause). Discard removes the bubble from `messages`.

### Companion work — Android parity

Independent but bundled in the same release because they unify the platform architecture:

1. **Port echo-driven submit to `PtyBridge.writeInput`.** Use the existing `RawByteListener` tap (already broadcast as `pty:raw-bytes`) to watch for body echo. Mirror the three-path protocol from `pty-worker.js`: passthrough, atomic submit (≤56 bytes), echo-driven (>56 bytes with 12s fallback to bare `\r`).
2. **Wrap `PtyBridge.writeInput` in a coroutine `Mutex`** per session so concurrent writes serialize. This eliminates the existing race where two concurrent force-sends interleave their body + delayed `\r` writes.
3. **Verify `useSubmitConfirmation` works identically on Android.** It already lives in shared React; confirm `attentionState` arrives at the Android renderer through the WebSocket on the same cadence as desktop.

## Data Flow

### Happy path: queued → released → confirmed

1. User types "hello", hits Enter while CC is mid-turn.
2. InputBar dispatches `QUEUE_ENQUEUE({ text: 'hello' })`. Bubble appears at bottom with queued styling.
3. CC's turn ends → `attentionState` returns to `'ok'`, `isThinking` flips to `false`.
4. `useQueueReleaser` evaluates gate: open. Dispatches `QUEUE_RELEASE_HEAD`, calls `sendInput(sessionId, 'hello\r')`.
5. Reducer moves item out of queue into `messages` with `pending: true, forceSend: false`. Bubble re-renders with normal pending styling.
6. PTY worker echo-driven submit fires; CC processes; transcript watcher emits `TRANSCRIPT_USER_MESSAGE`.
7. Existing `TRANSCRIPT_USER_MESSAGE` handler matches oldest pending entry by content → clears `pending`. Bubble becomes confirmed.

### Force-send (interrupt then send)

1. User clicks force button on a queued bubble (or types and clicks "send now"). Button is disabled if `permissionPending`.
2. `QUEUE_FORCE_SEND({ id })` or `QUEUE_FORCE_SEND({ text })` fires.
3. Reducer appends to `messages` with `pending: true, forceSend: true, awaitingInterrupt: true`. Removes from queue if id was provided.
4. `sendInput(sessionId, '\x1b')` fires immediately.
5. CC interrupts current turn. Transcript emits `[Request interrupted by user]` → existing reducer handler ends turn → `attentionState: 'ok'`, `isThinking: false`.
6. `useForceSendCoordinator` sees the awaiting-interrupt message and now-idle state. Dispatches `FORCE_SEND_DELIVER({ id })` and calls `sendInput(sessionId, text + '\r')`.
7. Reducer clears `awaitingInterrupt` (gray styling stays via `forceSend` until transcript confirms).
8. PTY worker echo-driven submit fires (CC is idle so paste-classification race is essentially gone). Transcript event arrives → matches by content → clears `pending` and `forceSend`. Bubble becomes confirmed.

If CC is already idle when force-send fires, the `\x1b` is benign and the coordinator delivers on the same tick.

### Pause / unpause

- `QUEUE_PAUSE` flips `queuePaused: true`. Releaser's gate fails; nothing releases. New `QUEUE_ENQUEUE` calls still append (queue grows, doesn't drain).
- `QUEUE_UNPAUSE` flips `queuePaused: false`. Next state tick drains head if other gate conditions are met.
- Force-send always bypasses both gate and pause.

### Esc with queue

1. User hits Esc.
2. App.tsx Esc handler: dispatches `QUEUE_PAUSE({ reason: 'esc-interrupt' })` AND sends `\x1b` to PTY.
3. CC interrupts the current turn. Transcript emits `[Request interrupted by user]` → existing reducer handler ends turn cleanly.
4. Queue stays paused with intact items. UI shows "Paused after Esc" hint. User must explicitly unpause to resume.

### Permission prompt mid-queue

1. CC asks for tool approval → existing hook event sets `permissionPending: true`.
2. If queue release was about to fire, gate now fails; release defers.
3. User answers permission via existing approval UI → `permissionPending: false`.
4. Releaser resumes on next state tick after CC's turn fully ends and `attentionState` returns to `'ok'`.

### Multiple rapid enqueues

Three `QUEUE_ENQUEUE` actions fire synchronously through the reducer. Queue becomes `[m1, m2, m3]`. Releaser drains one at a time, each waiting for the gate to re-arm after the prior release-confirm cycle.

### Ordering invariant — by construction

Queue release fires only when `attentionState === 'ok'` (CC idle). If "A" was released and is in flight, CC is mid-turn; gate is closed; "B" cannot release until "A" finishes. So queue release is ordering-safe by construction.

The remaining ordering concern is force-sends interleaving with queued items: a force-send always goes through the same `pending` flag mechanism, so transcript-arrival order resolves matching as today (oldest pending with matching content). Send-order = transcript-order = chat-view-order.

## Error Handling

### Release reaches PTY but transcript never arrives

Three layers of defense, mostly reusing existing infrastructure:

1. **`pty-worker.js` echo-driven submit** (desktop today; ported to Android in this work). Holds `\r` until CC drains stdin. On 12s timeout, fires bare `\r` anyway.
2. **`useSubmitConfirmation`** (shared React, already exists). 8s after a `pending: true` bubble appears, if `attentionState === 'ok'`, fires bare `\r` retry. Already wired into chat-input today; will fire identically for queue-released and force-sent messages.
3. **NEW: 60s max-age timeout per pending bubble.** If a bubble stays `pending: true` for 60 seconds AND `useSubmitConfirmation` already fired its retry AND no transcript event has arrived, dispatch `MESSAGE_FAIL_PENDING({ id })` → bubble transitions to `failed` state with `[Retry] [Discard]` affordance.

### Edit / cancel / reorder while releasing

`QUEUE_RELEASE_HEAD` sets `releasing: true` synchronously before the sendInput call. UI hides edit/cancel/reorder/force buttons for items with `releasing: true`. Reducer handlers for `QUEUE_EDIT`, `QUEUE_REORDER`, `QUEUE_REMOVE` are no-ops on releasing items. The flag clears the moment the item moves out of the queue (next reducer pass).

### Pause toggled mid-release

Once `sendInput` has been called, bytes are en route. `QUEUE_PAUSE` after that has no effect on the in-flight item — it only stops future releases. This is correct: pause is "release no more"; abort-what's-en-route is what Esc does.

### Session dies during release

`SESSION_PROCESS_EXITED` handler runs `endTurn()` (existing) and additionally dispatches `QUEUE_PAUSE({ reason: 'session-died' })`. Queued items survive; user can resume the session and unpause when ready.

### Renderer reload / browser refresh

Queue state lost on reload. Transcript replay rebuilds confirmed messages; pending bubbles that hadn't yet confirmed simply don't reappear (consistent with current chat-input behavior). User retypes anything queued at the time of reload.

### WebSocket disconnect on Android / remote browser mid-release

If `sendInput` fails because the WebSocket dropped, the message stays in `messages` as `pending: true` (already moved out of queue). On reconnect + `chat:hydrate`, the snapshot includes pending bubbles. `useSubmitConfirmation` retries once `attentionState` is observable again; if that fails too, falls into the 60s `failed` state.

### Concurrent renderer instances (dev + built app, two browsers)

Each renderer manages its own queue. If two renderers race a release for the same message id, whichever wins; the other's `QUEUE_RELEASE_HEAD` is a no-op for that id (already in `messages`). **Cross-renderer queue sync is explicitly out of scope.** If it becomes a real problem, future work can push queue state through `status:data` similarly to `attentionMap`.

## Testing

### Reducer unit tests — `chat-reducer-queue.test.ts`

- Each new action: state transitions, no-op cases, ordering preservation across multiple enqueues + releases.
- `MESSAGE_FAIL_PENDING` only fires after 60s with no transcript and after `useSubmitConfirmation` retry.
- Ordering invariant: 5 enqueues + 5 sequential releases + 5 transcript events → chat view order = transcript order, byte-for-byte.

### `useQueueReleaser` hook tests

- Each gate condition individually toggled → release fires only when all open.
- Releases sequentially: after release N, no release of N+1 until gate re-arms.
- Force-send while gate closed → triggers interrupt-then-send (sendInput `\x1b` first, then deliver via coordinator). Does NOT trigger queue release.
- Force-send while `permissionPending` → no-op. Reducer rejects the action.
- Pause toggled mid-release → in-flight call still fires; subsequent items wait.

### `useForceSendCoordinator` hook tests (new)

- Force-send dispatched → `\x1b` sent immediately, message marked `awaitingInterrupt: true`.
- After CC interrupts and `attentionState === 'ok'` → coordinator calls `sendInput(text + '\r')`, clears `awaitingInterrupt`.
- 3s fallback: coordinator fires sendInput even if interrupt confirmation didn't land.
- CC already idle when force-send fires → coordinator delivers on the same tick (no observable delay).
- Force-send while `permissionPending` → reducer rejects, coordinator never sees the message.

### `useSubmitConfirmation` interaction

Add cases to existing test file:
- Released-from-queue bubble → 8s retry fires identically to chat-input bubble.
- Force-sent bubble → same retry path.
- 60s elapsed + retry already fired + no transcript → bubble enters `failed` state.

### Android parity tests (new)

- **Echo-driven submit on Android.** Kotlin instrumentation test exercising `PtyBridge.writeInput` against a stub PTY that simulates Ink echo behavior. Asserts chunked body + echo-wait + delayed `\r` ordering matching `test-conpty/test-worker-submit.mjs`.
- **Mutex serialization on Android.** Coroutine test fires 3 concurrent `writeInput` calls, asserts sequential byte ordering at the stub PTY (no interleaving).

### IPC parity check

Confirm by absence: the design adds zero new IPC types (queue is renderer-local; `sendInput` already exists). `desktop/tests/ipc-channels.test.ts` should require no additions.

### End-to-end integration — `desktop/tests/queue-integration.test.ts`

- Enqueue 3, simulate turn end → all 3 release in order with attention re-arming between.
- Force-send while 2 are queued and CC is mid-turn → `\x1b` fires, force-sent message becomes `awaitingInterrupt: true`, then delivers when interrupt lands. Queued items wait for normal turn AFTER the force-sent message resolves.
- Force-send while `permissionPending` → reducer rejects, force button is disabled, queue continues to wait for the permission to resolve.
- Pause + enqueue 2 + simulate turn end → nothing releases. Unpause → both release.
- Esc auto-pause: dispatch `\x1b` + auto-pause → queue intact, paused, `queuePauseReason === 'esc-interrupt'`.
- Permission prompt mid-queue: enqueue 2, simulate permission event, simulate turn end + permission still pending → no release. Resolve permission → next release fires.

### Manual UX checklist

- Queued bubble visually distinct from pending (dotted vs solid).
- Force-pending bubble shows "Claude has not yet seen this message" tooltip on hover.
- Drag-reorder produces visible insertion line; releasing item can't be dragged.
- Edit-in-place autofocuses, saves on Enter, cancels on Esc.
- Pause indicator next to InputBar reflects state and reason.
- Failed-bubble retry/discard buttons appear after 60s.

## Out of Scope

- Terminal-typed messages getting an optimistic gray bubble before transcript arrives.
- Per-item pause (only global pause).
- Cross-renderer queue sync.
- Queue state persistence across renderer reloads.
- Buffering xterm keystrokes to decode Ink input-bar state.
