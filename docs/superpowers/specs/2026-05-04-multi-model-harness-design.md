# Multi-Model Harness — Design

**Date:** 2026-05-04
**Status:** Design — pending implementation plan

## Problem

YouCoded today is structurally a Claude Code wrapper. The chat reducer, transcript watcher, hook system, skill router, MCP integration, attention classifier, and permission flow are all coupled to Claude Code's specific CLI surface and JSONL transcript format. A `SessionProvider` seam exists at session-spawn (`'claude' | 'gemini'`), but it only goes one level deep — non-Claude sessions are second-class today (terminal-only, no chat view, no skills, no hooks).

We want users to be able to choose a local model (Qwen 3 via Ollama) as a first-class session type alongside Claude — same chat UI, same conversation experience — without weakening Claude's place as the headline runtime. We also want the architecture for adding more providers later (LM Studio, OpenRouter, others) to be additive rather than a rewrite each time.

This spec covers the **MVP**: chat-only Local sessions backed by Ollama on desktop. It also sketches the staged roadmap (Stages B → D) so the harness contract is shaped to support tools, skills/MCP, and full parity without restructuring later.

## Goals

- Add a third provider, `'local'`, that runs against any OpenAI-compatible HTTP endpoint
- First-run UX that auto-installs Ollama and pulls Qwen 3 8B for non-technical users
- LM Studio supported for users who already have it (no auto-install for it)
- Local sessions render in the existing chat view — same bubbles, same streaming, same markdown
- Conversation persistence + resume
- Architecture explicitly designed so Stages B (tools), C (skills + MCP), and D (hooks, memory, Android, multimodal, remote endpoints) are additive, not rewrites

## Non-goals (MVP)

- No tools (Read / Write / Edit / Bash / Glob) — Stage B
- No skills support, hooks, MCP, statusline, attention classifier — Stage C/D
- No permission flow (none needed without tools)
- No terminal pane on local sessions (chat-only — view-mode toggle hidden when `provider === 'local'`)
- No Android (Stage D — Ollama doesn't target Android cleanly)
- No remote endpoints (OpenRouter, Together, Groq) — same wire protocol, but defers settings UX for keys
- No multimodal / image input
- No Qwen "thinking mode" toggle (defaults to whatever the model does)
- **No mid-session provider switching, ever.** Switching from Claude to Local mid-conversation would require killing the CC process, format-converting message history, and restarting in a new runtime. Bad UX, bad reliability, dubious value. Spelled out as a permanent non-goal.

## Approach

**Approach 1 of three considered: in-process harness in main, using Vercel AI SDK.** A new `LocalSessionHarness` class in `src/main/` next to `SessionManager` owns local sessions. It uses the [Vercel AI SDK](https://sdk.vercel.ai) to talk to Ollama/LM Studio over HTTP, maintains the conversation in memory, persists to a JSON file, and emits the same `transcript:event` IPC messages the renderer already consumes for Claude sessions.

Alternatives rejected:
- **Subprocess harness mirroring `pty-worker.js`** — solves a problem we don't have (the harness isn't loading native modules), adds memory + spawn cost per session.
- **Embed an existing OSS agent (Cline / Aider) as the runtime** — trades CC coupling for OSS-agent coupling, inherits their UX/prompts/update cadence. Defeats the goal of being model-agnostic.

The recommended approach maximises OSS leverage where leverage actually matters (Vercel AI SDK doing the protocol/streaming/loop work), keeps YouCoded as the agent owner so we don't inherit anyone else's UX, and matches the existing main-process patterns.

## Architecture

### Provider type extension

```ts
// src/shared/types.ts
export type SessionProvider = 'claude' | 'gemini' | 'local';

export interface SessionInfo {
  // ... existing fields
  provider: SessionProvider;
  model?: string;             // for 'local', this is the Ollama model name (e.g. 'qwen3:8b')
  endpoint?: string;          // for 'local', the OpenAI-compat URL (defaults to http://localhost:11434/v1)
}
```

### SessionManager delegation

`SessionManager.createSession()` branches on `provider`:

- `'claude'` / `'gemini'` → existing PTY worker path, unchanged
- `'local'` → delegates to `LocalSessionHarness.startSession(...)` instead of spawning a child process

```ts
// src/main/session-manager.ts (sketch)
createSession(opts: CreateSessionOpts): SessionInfo {
  if (opts.provider === 'local') {
    return this.localHarness.startSession(opts); // returns SessionInfo, emits same events as PTY path
  }
  // ...existing PTY path unchanged
}
```

### LocalSessionHarness

New file `src/main/local-session-harness.ts`:

```ts
class LocalSessionHarness {
  startSession(opts: CreateSessionOpts): SessionInfo
  send(sessionId: string, userText: string): Promise<void>
  cancel(sessionId: string): Promise<void>            // mid-stream interrupt via AbortController
  destroySession(sessionId: string): boolean
  resumeSession(sessionId: string): Promise<SessionInfo>  // load from disk
}
```

Internally per session:
1. Maintains an in-memory `messages: ChatMessage[]` array
2. On `send()`:
   - Emit `transcript:event { type: 'user-message', text }` → reducer dispatches `TRANSCRIPT_USER_MESSAGE`
   - Append user message to `messages`
   - Call Vercel AI SDK `streamText({ model: ollama(modelName, { baseURL: endpoint }), messages, abortSignal })`
   - For each text chunk: emit `transcript:event { type: 'assistant-text', text }` → reducer dispatches `TRANSCRIPT_ASSISTANT_TEXT`
   - On stream complete: emit `transcript:event { type: 'turn-complete', metadata }` → reducer dispatches `TRANSCRIPT_TURN_COMPLETE`
   - Persist updated `messages` to disk (see Persistence section)
3. On `cancel()`: trigger the `AbortController`; SDK stops streaming; emit a synthetic `turn-complete` with `stopReason: 'interrupted'`

### Why this works without touching the chat reducer

The harness emits the exact `transcript:event` shape that `TranscriptWatcher` already emits for Claude sessions. The chat reducer (`chat-reducer.ts`) doesn't know — and doesn't need to know — that the events came from a different source. This means we get for free:

- Streaming text rendering
- Pending-flag dedup of optimistic + transcript-confirmed user messages
- Markdown / code-block / highlight.js rendering
- Turn metadata strip (model name, token usage if the SDK exposes it)
- Auto-titling from first message
- Status-pill display
- Stop button wiring (already dispatches an interrupt action — we just need it routed to `LocalSessionHarness.cancel()` for local sessions instead of `\x1b` to PTY)

### Stage B prep baked in

The same `streamText` call accepts a `tools` parameter and a `stopWhen: stepCountIs(N)` option that runs the multi-step agent loop automatically. Stage B becomes "define tool schemas + executors and pass them in," not "rewrite the loop." See Roadmap.

## UI integration

### Provider chosen at session creation

The runtime picker lives in the existing new-session form (the "+" expansion in `SessionStrip.tsx`). The current `isGemini: boolean` toggle generalizes into a small **Runtime** segmented control at the top of the form:

```
Runtime:  [● Claude]  [○ Local]  [○ Gemini]
Folder:   [folder picker]
Model:    [list updates based on runtime]
Skip Permissions: [toggle, grayed out for non-Claude]
[Create]
```

Selecting **Local** swaps the Model dropdown to the user's installed Ollama models (queried live via the `/api/tags` HTTP endpoint or equivalent), defaulting to whatever was used last. If no models are installed, the form shows "Install Qwen 3 8B →" inline, kicking off the first-run flow.

Gemini stays gated by the existing `sessionDefaults.geminiEnabled` setting. Local is ungated since it's the new headline feature.

### Mid-session model picker — within-runtime swaps only

The existing `ModelPickerPopup.tsx` continues to handle mid-session model changes, but its list is now scoped to the current session's runtime:

- Claude session → Claude variants (current behavior, unchanged)
- Local session → installed Ollama models (e.g. Qwen 8B ↔ Qwen 32B). Safe because we're loading a different model into the same Ollama runtime — message history carries over, no process restart.
- Gemini session → unchanged (no model variants exposed today)

Stretch: locking the model at creation time is acceptable for MVP if mid-session swap proves complicated. The mid-session swap on local sessions is a small win, not a load-bearing requirement.

### First-run for local mode

Extends the existing `prerequisite-installer.ts` pattern:

1. Detect Ollama. If missing, prompt: *"Local mode needs Ollama (~300 MB). Install now? [Install] [Skip]"*
2. After install, detect installed models. If none, prompt: *"Download Qwen 3 8B (~5 GB)? [Download] [Choose different model] [Skip]"*
3. Progress shown in the existing `SetupScreen` UI.

LM Studio is detected (via its default port `1234`) and offered as an alternative endpoint in settings, but never auto-installed.

### Per-session UI differences for `provider === 'local'`

- View-mode toggle (chat ↔ terminal) hidden in HeaderBar — local sessions are chat-only
- Permission-mode badge hidden — no permissions concept
- Status pill shows the Ollama model name (`qwen3:8b`)
- Stop button visible mid-stream
- Attention banner inert (no PTY classifier) — `attentionState` stays `'ok'`

### Settings panel additions

New "Local Models" section in the existing settings panel:

- Endpoint URL (defaults to `http://localhost:11434/v1`)
- Default model (dropdown of installed Ollama models)
- System prompt override (textarea, defaults to a minimal "You are a helpful assistant. The user is using YouCoded, a desktop coding-assistant app.")
- "Manage Ollama models →" button (deep links to `ollama list` workflow or opens a small management UI — exact form deferred to implementation)

## Persistence

Local conversations stored at `~/.claude/youcoded-local/sessions/<session-id>.json`:

```json
{
  "id": "uuid",
  "provider": "local",
  "model": "qwen3:8b",
  "endpoint": "http://localhost:11434/v1",
  "systemPrompt": "You are a helpful assistant...",
  "createdAt": 1714857600000,
  "updatedAt": 1714857890000,
  "title": "Auto-named from first message",
  "messages": [
    { "role": "user", "content": "...", "timestamp": 1714857600000 },
    { "role": "assistant", "content": "...", "timestamp": 1714857615000 }
  ]
}
```

**Why a separate path** (not CC's `~/.claude/projects/<slug>/<id>.jsonl`):

- Different shape (full message array per file vs append-only JSONL with tool/turn nesting)
- Avoids accidentally pretending a local session is a CC session anywhere in existing watcher/resume code
- Keeps the resume browser able to query both stores independently

**Resume browser** — existing `ResumeBrowser` UI lists CC sessions today; gains a "Local" tab (or filter chip) that queries `~/.claude/youcoded-local/sessions/`. Clicking a local session restores message history into the harness and re-mounts in chat view.

**Auto-titling** — first user message → first ~5 words → session title. Same UX as CC's auto-naming.

**Atomic writes** — write to `<id>.json.tmp` then rename, to avoid corrupting on crash mid-write.

## Roadmap to parity (Stages B → D)

Each stage is a separate spec/plan; this section sketches them so the MVP harness contract is shaped to support them.

| Stage | Adds | Approx. effort | Key OSS leverage |
|---|---|---|---|
| **B** | Tools (Read, Write, Edit, Bash, Glob), permission flow (reusing the existing `PERMISSION_REQUEST` reducer action shape so existing approval UI just works), tool result rendering via existing ToolCard | ~3–4 weeks | Vercel AI SDK `streamText({ tools, stopWhen: stepCountIs(N) })` runs the agent loop; tool definitions are pure functions |
| **C** | Skill router (embedding-based match against installed skills), MCP client | ~3–4 weeks | `@modelcontextprotocol/sdk` (official Anthropic), Ollama embedding models (`nomic-embed-text`) |
| **D** | Hook lifecycle parity, memory (long-term context), Android runtime, multimodal, remote endpoints (OpenRouter etc.) with secure key storage | Ongoing | Varies — Android is the hard one (likely needs `llama.cpp` Termux build or a "remote-Ollama-on-PC" pattern) |

The MVP harness contract — `startSession() → { send, cancel, destroy } + emit transcript:event` — is shaped so:

- **Stage B** adds `tools` to the `streamText` call and emits `TRANSCRIPT_TOOL_USE` / `TRANSCRIPT_TOOL_RESULT` events. No reducer changes. Permission gates emit `PERMISSION_REQUEST` events the existing approval UI already consumes.
- **Stage C** inserts a skill-matching pre-pass before the model call (embed the user message, find top-k skill descriptions, inject matched skill bodies into the system prompt) and adds an MCP-tool-discovery step at session start. No reducer changes.
- **Stage D** adds new providers as `LocalSessionHarness` peers (or subclasses) without restructuring SessionManager. Android needs its own runtime story but the harness contract carries over.

## Risks and open questions

- **Ollama install on Windows requires admin rights** in some configurations. The auto-install flow needs to detect this and either elevate (with consent) or fall back to a guided manual install. To be confirmed in implementation.
- **Vercel AI SDK Ollama provider** (`ollama-ai-provider` package by community, or the SDK's built-in OpenAI provider pointed at Ollama's `/v1` endpoint) — we'll use whichever is more stable at implementation time. Both are viable and the choice is a one-line swap.
- **Mid-session model swap within local** (Qwen 8B → Qwen 32B) is plausibly safe but needs verification that Ollama doesn't drop conversation context when the model changes. If it does, the swap requires the harness to re-send the full message history with the new model — slight cost but trivial. Defer to implementation.
- **System prompt for chat-only Qwen** — minimal default is fine, but we should sanity-check that a totally bare prompt doesn't cause Qwen to hallucinate tools or pretend to be Claude. Test during implementation; the prompt is configurable in settings as an escape hatch.
- **Token usage / context-window display** — Vercel AI SDK exposes per-turn token counts. Reuse the existing turn-metadata UI (which already displays this for Claude sessions when enabled).
- **Persistence file growth** — long conversations grow the JSON file unboundedly. Acceptable for MVP. Stage D could add summarization/truncation.
- **Concurrent session handling** — multiple local sessions sharing one Ollama backend will queue at Ollama's level (it serializes inference). UX-wise, the second session will just appear "still thinking" longer. Acceptable; document.
- **Stop-mid-stream cleanup** — if the user cancels mid-stream, the partial assistant text is already in the chat view. We should persist the partial reply with a `stopReason: 'interrupted'` flag so resume doesn't re-show it as an in-flight turn. Implementation detail.

## References

- [Vercel AI SDK docs](https://sdk.vercel.ai/docs) — provider abstraction, streaming, tool calling, multi-step agent loops
- [Ollama API reference](https://github.com/ollama/ollama/blob/main/docs/api.md) — model management, OpenAI-compat endpoint
- [Model Context Protocol](https://modelcontextprotocol.io/) — for Stage C
- Existing YouCoded patterns:
  - `src/main/session-manager.ts` — provider seam
  - `src/main/transcript-watcher.ts` — `transcript:event` shape
  - `src/renderer/state/chat-reducer.ts` — `TRANSCRIPT_*` actions
  - `src/renderer/components/SessionStrip.tsx` — new-session form (where the runtime picker lives)
  - `src/main/prerequisite-installer.ts` — install pattern Ollama setup follows
- Reference OSS implementations to study (not embed): [Cline](https://github.com/cline/cline), [Aider](https://github.com/Aider-AI/aider), [Continue](https://github.com/continuedev/continue)
