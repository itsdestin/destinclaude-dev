# ToolCard Dev Sandbox — Design

**Date:** 2026-04-23
**Status:** Approved — ready for implementation plan
**Repo:** `youcoded/`

## Problem

Iterating on `ToolCard` / `ToolBody` renders today requires triggering real Claude Code sessions that invoke the right tool in the right state. That loop is slow, non-deterministic, and blocks us from cheaply testing ideas like rendering `Skill` invocations as compact inline pills or building compact MCP views (Todoist, Google Services, Windows-Control).

A dev-only sandbox that renders real `<ToolCard>` components against fixture data would turn a multi-minute feedback loop into a Vite HMR edit cycle and unlock fast experimentation.

## Scope

**In scope:**
- A dev-only React route in the desktop renderer that renders `<ToolCard>` + `<ToolBody>` against fixture tool calls.
- Fixture corpus seeded from real JSONL transcripts, organized for easy extension.
- Per-card status toggle (running / completed / failed) for exercising view states without needing a fixture per branch.
- Error-tolerant fixture parsing so a bad file doesn't crash the page.

**Out of scope:**
- Any user-visible UI changes (no new compact views in this pass — the sandbox is the enabling infrastructure).
- Unit tests for `ToolCard` / `ToolBody`. Fixtures become the corpus for a future `ToolCard.test.tsx`, but adding that is a separate task.
- Android parity. Sandbox is Electron-dev-only.
- Persistence, theme switching, or any polish that doesn't serve the iteration loop.

## Architecture

### Route

- Lazy-loaded React route at `#/tool-sandbox`.
- Gated on `import.meta.env.DEV`. In production builds the module is tree-shaken and the path is not registered.
- Entry: type `#/tool-sandbox` in the URL bar of the dev Electron window. No settings toggle, no menu entry — keeps the feature invisible to anyone not reading the code.

### File layout

```
youcoded/desktop/src/renderer/dev/
  ToolSandbox.tsx           # Page component
  fixtures/
    skill.jsonl             # One fixture per tool type
    agent.jsonl
    bash.jsonl
    read.jsonl
    mcp-todoist.jsonl       # Hand-crafted for MCP tools
    ...
```

The `dev/` dir makes the "don't ship this" contract visible. Files inside are still part of the renderer bundle during dev; the `import.meta.env.DEV` gate prevents registration in prod.

### Fixture format

Each fixture is one `.jsonl` file containing **two lines** from a real transcript:
1. The `assistant` message carrying the `tool_use` content block.
2. The `user` message carrying the matching `tool_result` content block.

Fixtures are pulled directly from `~/.claude/projects/<slug>/*.jsonl`. When sensitive content is involved, we sanitize the payload inline — no automated scrubbing.

### Data flow

1. Sandbox imports all fixtures at build time via `import.meta.glob('./fixtures/*.jsonl', { as: 'raw', eager: true })`. No runtime fetch.
2. Each fixture is parsed line-by-line into the same action shapes the transcript watcher emits (`TRANSCRIPT_TOOL_USE`, `TRANSCRIPT_TOOL_RESULT`).
3. Actions are applied to a throwaway initial `ChatState` via the real `chatReducer`. This yields real `ToolCallState` objects, not hand-rolled mocks — so any future reducer drift surfaces in the sandbox too.
4. Sandbox renders a vertical stack of `<ToolCard>` components, grouped by tool name with section headers.

### Rendering

- Each card renders with `expanded: true` forced, so both header and body are visible simultaneously.
- A small control strip per card lets us toggle the tool's `status` between `running`, `completed`, and `failed` without editing the fixture.
- No theme switcher — inherits the dev app's current theme. Themed rendering validation happens in the full app.

## Error handling

- Fixture parse failures render an inline red error card showing the filename and the parse error. The rest of the page keeps working.
- Missing `toolUseResult.success` defaults to `completed` status (matches reducer behavior).
- Unknown tool names fall through to `RawFallbackView` as they do in the real app — that's the expected behavior and what we want to see in the sandbox.

## Testing

No new unit tests for the sandbox itself — it is dev infrastructure, not shipped code.

Verification is visual and HMR-driven:
1. Start the dev app via `bash scripts/run-dev.sh`.
2. Navigate to `#/tool-sandbox`.
3. Edit a view function in `ToolBody.tsx`.
4. Confirm the fixture card updates instantly without a full reload.

## Non-goals clarifications

- **No production exposure path.** No feature flag, no settings toggle. If a non-dev user navigates to the URL, they should get the app's normal not-found behavior.
- **No fixture runtime updates.** Fixtures are committed files. If we want to replay a live transcript, that's a separate feature.
- **No parity with the real chat layout.** Cards render on a simple vertical page. Spacing, grouping, and animation are not part of this work.

## Open questions

None blocking. Items to track separately once the sandbox exists:
- Should cards also render the surrounding assistant text bubble for context? (Probably yes for some tools, no for others — decide per-experiment.)
- Do we want a fixture-generator CLI that extracts tool pairs from a live transcript file? (Low priority — manual copy-paste is fine for a handful of fixtures.)

## Next

Hand off to `writing-plans` for the implementation plan.
