---
paths:
  - "youcoded/desktop/src/renderer/state/chat-reducer.ts"
  - "youcoded/desktop/src/renderer/state/chat-types.ts"
  - "youcoded/desktop/src/renderer/components/ChatView.tsx"
last_verified: 2026-04-12
---

# Chat Reducer Rules

You are editing chat state or the ChatView component. Read `docs/chat-reducer.md` for full context.

## Hard invariants

1. **`toolCalls` Map is NEVER cleared.** ToolCards need old results for display. Don't "optimize" this away.

2. **Use `activeTurnToolIds` for current-turn status checks** (StatusDot color, ThinkingIndicator, attention classifier). NOT the full toolCalls Map — that would reflect stale state from prior turns.

3. **Always use `endTurn()` helper** when adding turn-ending code paths. It marks orphaned `running`/`awaiting-approval` tools as failed, clears the Set, and resets isThinking/streamingText/currentTurnId + attentionState:'ok' atomically. Don't manually clear these. (SESSION_PROCESS_EXITED spreads endTurn() and then overrides attentionState:'session-died' — the one exception.)

4. **Dedup is content-based, NOT flag-based.** Both USER_PROMPT and TRANSCRIPT_USER_MESSAGE compare message content against the last 10 timeline entries. Don't try to add an `optimistic` flag without a full redesign — content matching is the current working solution, with the known limitation that rapid-fire identical messages can be suppressed.

5. **attentionState is classifier-driven, not timer-driven.** `useAttentionClassifier` ticks the PTY buffer every 1s while `isThinking && !hasRunningTools && !hasAwaitingApproval && visible` and dispatches `ATTENTION_STATE_CHANGED` only when the mapped state differs from the current one. Transcript events (user/assistant/tool/heartbeat) and `PERMISSION_REQUEST` reset it to `'ok'`. Don't add side-channel writes to `attentionState` from timers or polling code — update `classifyBuffer` patterns in `attention-classifier.ts` instead. Those regexes are Claude Code CLI-version sensitive; keep the version-anchor comment current.

## Adding a new turn-ending action

Call `endTurn(session)` inside the handler. It returns the updated toolCalls Map plus reset fields. Do NOT duplicate the clearing logic inline.
