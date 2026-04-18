# Chat Reducer Architecture

Chat state lives in `youcoded/desktop/src/renderer/state/chat-reducer.ts` with types in `chat-types.ts`. A few non-obvious invariants govern how tool activity and turns are scoped.

## Tool activity scoping

`toolCalls` is a **session-lifetime Map** — never cleared. ToolCards need old results for display, so entries persist. Individual entries are updated in-place (status flipped to `failed`), but the Map never resets.

To prevent stale `running` / `awaiting-approval` entries from old turns affecting status indicators, `activeTurnToolIds` (a Set) tracks which tools belong to the current turn. All status checks — StatusDot color, ThinkingIndicator visibility, attention classifier — scan this Set only, not the full Map.

## endTurn() helper

`endTurn()` in chat-reducer.ts:52-69 is the shared path for ending a turn. It:

- Iterates `activeTurnToolIds` and marks any `running` or `awaiting-approval` tool as `failed` with error `'Turn ended'`
- Returns a fresh empty `activeTurnToolIds: new Set()`
- Clears `isThinking`, `streamingText`, `currentGroupId`, `currentTurnId`, and resets `attentionState: 'ok'`

**Always use this helper when adding a new turn-ending code path.** Don't manually clear these fields.

`SESSION_PROCESS_EXITED` spreads `endTurn()` and then overrides `attentionState: 'session-died'` — the only case where the post-endTurn attention is not `'ok'`.

## Attention classifier

The old 30-second `thinkingTimedOut` watchdog was replaced by a per-session `attentionState` enum driven by three independent signals:

1. **Process liveness** — main-process `session-exit` forwards `exitCode` via IPC; App.tsx dispatches `SESSION_PROCESS_EXITED`. If a turn was in flight OR the exit was nonzero, the reducer calls `endTurn()` and sets `attentionState: 'session-died'`. Clean exits during idle are no-ops.
2. **PTY buffer classifier** — `useAttentionClassifier` ticks every 1s while `isThinking && !hasRunningTools && !hasAwaitingApproval && visible`. It reads the xterm buffer via `getScreenText`, passes the last 40 lines to the pure `classifyBuffer` function (`src/renderer/state/attention-classifier.ts`), and dispatches `ATTENTION_STATE_CHANGED` only when the mapped state differs from the current one. Reset to `'ok'` on unmount.
3. **Transcript corroboration** — `TRANSCRIPT_USER_MESSAGE`, `TRANSCRIPT_ASSISTANT_TEXT`, `TRANSCRIPT_TOOL_USE`, `TRANSCRIPT_TOOL_RESULT`, `PERMISSION_REQUEST`, and the new `TRANSCRIPT_THINKING_HEARTBEAT` (emitted for `thinking` blocks from extended-thinking models) clear `attentionState` back to `'ok'`.

`ChatView` renders `<ThinkingIndicator />` when `attentionState === 'ok' && isThinking`, and swaps in `<AttentionBanner state={attentionState} />` otherwise. Banner copy is keyed off the state (`awaiting-input`, `shell-idle`, `error`, `stuck`, `session-died`).

The classifier's regex patterns are Claude Code CLI-version sensitive — see the version-anchor comment at the top of `attention-classifier.ts` and review if CLI visuals change.

## Deduplication

Both `USER_PROMPT` (chat-reducer.ts:101-141) and `TRANSCRIPT_USER_MESSAGE` (chat-reducer.ts:209-248) dedup via **content matching** against the last 10 timeline entries. There is **no `optimistic` flag** — dedup compares strings and entry kinds directly.

### Known limitation
Identical messages sent legitimately in quick succession can be suppressed. If this becomes a real problem, the fix requires source tagging (e.g., a flag distinguishing optimistic-from-local vs confirmed-from-transcript entries), not content comparison.

## Per-turn metadata

`AssistantTurn` carries four fields populated from the JSONL transcript:

- `stopReason: string | null` — set only for non-`end_turn` completions (`max_tokens`, `refusal`, `stop_sequence`, `pause_turn`). Rendered inline as a footer under the affected turn; `null` means the turn completed normally. The transcript-watcher filters `tool_use` upstream; `end_turn` reaches the reducer but is filtered at the `AssistantTurnBubble` render gate (it's the normal case — no note needed).
- `model: string | null` — Anthropic model ID (e.g. `claude-opus-4-7`). Captured on the first `TRANSCRIPT_ASSISTANT_TEXT` action (Task 2.4) and reconfirmed on `TRANSCRIPT_TURN_COMPLETE`. Drives (a) the opt-in per-turn metadata strip and (b) a reconciliation `useEffect` in App.tsx that silently updates the session-pill `sessionModels` when the transcript reveals drift (user typed `/model X` in the terminal, rate-limit downshift, session resume).
- `usage: TurnUsage | null` — `{ inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens }` from `message.usage`. Populated on `TRANSCRIPT_TURN_COMPLETE`. Displayed only when the `showTurnMetadata` theme-context preference is on (default off — follows the "default hidden" precedent set by the derived StatusBar widgets).
- `anthropicRequestId: string | null` — `req_…` from the transcript line's outer `requestId` field. Surfaced in `AttentionBanner` when state is `session-died` or `error` so the user can reference it when reporting issues.

**Distinct from the permission-flow `requestId`** on `ToolCallState` (used by `PERMISSION_REQUEST` / `PERMISSION_RESPONSE`). The permission `requestId` is a YouCoded-internal approval-flow ID; `anthropicRequestId` is the Anthropic API request ID. Don't conflate — the distinctive name prevents silent cross-wiring.

All four fields default to `null` on turn creation. The reducer's `TRANSCRIPT_TURN_COMPLETE` handler attaches metadata to the completing turn via a spread-then-override BEFORE calling `endTurn()`, because `endTurn()` doesn't touch `assistantTurns` and the override must survive the endTurn state merge.
