---
title: Dev sandbox & testing tooling
date: 2026-04-26
status: design
---

# Dev sandbox & testing tooling

## Why

Two existing patterns have proven their worth and want to be generalized:

- **The ToolCard sandbox** (`youcoded/desktop/src/renderer/dev/`) — a `?mode=tool-sandbox` route that renders every per-tool fixture through the real `<ToolCard>` component with Vite HMR. Iterating on tool-card visuals without spinning up a real session.
- **`test-conpty/`** — node harnesses that drive real `claude` via `node-pty` to pin specific Claude Code↔YouCoded couplings (paste threshold, echo behavior, attention classifier, spinner regex). Documented methodology in `test-conpty/README.md`.

Both are valuable but narrow. Five recurring scenarios still hurt:

1. *I shipped a chat-render change and didn't notice X type of message broke.*
2. *I'm iterating on a bubble or status-bar style and have to manually reproduce conversations to see how it looks.*
3. *A real user transcript broke and I want to load it locally and watch the UI/state evolve.*
4. *I want to know if a CC version bump broke any of YouCoded's coupling points without spinning up the full app.*
5. *Claude can't easily verify visual or end-to-end behavior on its own — it has to ask Destin to look.*

This design generalizes the existing patterns into a coherent set of dev sandboxes plus the snapshot-and-diff infrastructure Claude needs to verify behavior on its own.

## Shape

**Four tools. One spec. Two surfaces. Sequential ship.**

The four tools share fixture infrastructure but split cleanly across two surfaces:

| Tool | Surface | What it is |
|------|---------|------------|
| 1. Visual gallery (Tool cards / Conversations / Theme cycle) | Browser (Vite/Electron) | Iterate on visual structure across the full message-type matrix |
| 2. Pre-binned scenarios (synthetic + real-anonymized bundle) | Fixtures | Stable, curated test inputs — feed both the gallery AND the snapshot script |
| 3. Snapshot script + baselines | Node | Pure-node reducer-state snapshot for Claude-driven regression checks |
| 4. CC-coupling probe library | Node (real CC) | Curated catalog of `test-conpty/` probes pinning specific CC↔YouCoded couplings |

## Architecture

### Browser surface — the workbench

A unified workbench at `?mode=workbench`, launched via `bash scripts/run-workbench.sh` (modeled on existing `scripts/run-sandbox.sh` — same port-offset isolation, same `YOUCODED_PROFILE=dev` profile split). Left-nav switcher with three tabs:

1. **Tool cards** — today's `ToolSandbox.tsx` moved under the workbench shell unchanged. Same fixture-loader, same per-tool grid, same HMR.
2. **Conversations** — scenario bundles + drag-drop, render full chat frame including status bar.
3. **Theme cycle** — synthetic transcript rendered through every theme on one page.

Renderer code lives under `youcoded/desktop/src/renderer/dev/workbench/`:
- `WorkbenchShell.tsx` — left-nav, route switching, snapshot-mode query handling.
- `tabs/ToolCardsTab.tsx` — re-exports today's `ToolSandbox`.
- `tabs/ConversationsTab.tsx` — scenario picker + scenario provider + chat frame.
- `tabs/ThemeCycleTab.tsx` — multi-theme render of synthetic.
- `ScenarioProvider.tsx` — wraps the chat layout with scenario-injected state.

`App.tsx` already gates `?mode=tool-sandbox` in dev — extend the same `import.meta.env.DEV && buddyMode === '<mode>'` gate to recognize `'workbench'` and render `<WorkbenchShell />`. The `'tool-sandbox'` mode keeps working as a deep-link to the Tools tab for back-compat.

### Node surface — scripts and probes

- `youcoded/desktop/test-conpty/` — current shape preserved. Adds `INDEX.md` catalog and two new probes (transcript-emit, hook-relay-roundtrip).
- `youcoded/desktop/scripts/dev-tools/` — new directory. Houses:
  - `redact-transcript.js` — JSONL redactor.
  - `snapshot.js` — scenario → reducer-state JSON snapshot, with `--diff` and `--update`.

### Shared

- `youcoded/desktop/src/renderer/dev/fixtures/conversations/` — `synthetic.jsonl` + `synthetic.scenario.json`, plus `real-bundle/<name>.jsonl` + `<name>.scenario.json` pairs.
- `youcoded/desktop/src/renderer/dev/baselines/conversations/<scenario>.snapshot.json` — locked snapshots, committed to git.
- Existing per-tool fixtures at `dev/fixtures/*.jsonl` stay where they are.
- `youcoded/desktop/src/shared/transcript-parser.ts` — re-export shim:
  ```ts
  export { parseTranscriptLine, cwdToProjectSlug } from '../main/transcript-watcher';
  ```
  Zero functional change to production. Snapshot script imports from this shared address.

Tooling code lives inside the `youcoded/` repo (single deployable unit). The only workspace-root addition is `scripts/run-workbench.sh` — a thin launcher mirroring the existing `run-sandbox.sh` / `run-dev.sh` pattern at workspace root. All actual logic stays in `youcoded/`.

## Tab 1 — Tool cards

No change. Existing `ToolSandbox.tsx` becomes the Tools tab inside the workbench shell. Same fixtures (`dev/fixtures/*.jsonl`), same per-tool grouping, same HMR.

## Tab 2 — Conversations

The heart of the design. Two zones in the page:

**Top: scenario picker.** Lists every bundled scenario (synthetic + every real-bundle entry). Click to render. A drag-drop affordance accepts an arbitrary `.jsonl` from disk and renders it ad-hoc with default scenario state.

**Below: rendered chat frame.** A `<ScenarioProvider>` wraps the real `<App>`-shaped chat layout — header bar, chat view, status bar, footer, attention banner, permission overlay. The provider:

1. **Replays the JSONL through the existing transcript parser.** Calls `parseTranscriptLine` from `src/shared/transcript-parser.ts` for each line, dispatches the resulting `TranscriptEvent`s as `TRANSCRIPT_*` chat-reducer actions in order. End state is the same as if the transcript had streamed in live.
2. **Substitutes session/global state from the sidecar.** Pulls `model`, `cwd`, `gitBranch`, `contextUsedPct`, `todos`, `subagents`, `announcement`, `syncWarnings`, `attentionState`, `permissionMode` from the sidecar — with sensible defaults when keys are missing or no sidecar exists. The chat view, status bar widgets, and overlays read from these scenario-driven values via the same React contexts they use in production.

No mock components, no shadow rendering. Real `<ChatView>`, real `<HeaderBar>`, real `<StatusBar>`, real bubble + tool-card components.

### Scenario bundle format

```
dev/fixtures/conversations/
├── synthetic.jsonl
├── synthetic.scenario.json
└── real-bundle/
    ├── README.md                            ← one-line description per scenario
    ├── long-compaction.jsonl
    ├── long-compaction.scenario.json
    ├── interrupted-mid-tool.jsonl
    ├── interrupted-mid-tool.scenario.json
    └── ...
```

`<name>.scenario.json` shape (all keys optional):

```json
{
  "model": "claude-opus-4-7",
  "cwd": "/redacted/scenario",
  "gitBranch": "master",
  "contextUsedPct": 0.42,
  "todos": [{ "id": "1", "text": "Write tests", "status": "in_progress" }],
  "subagents": [],
  "announcement": null,
  "syncWarnings": [],
  "attentionState": "ok",
  "permissionMode": "normal"
}
```

When a key is missing, the provider falls back to a documented default (e.g. `model='claude-opus-4-7'`, `gitBranch='master'`, `attentionState='ok'`, no announcement, no warnings). When no sidecar exists at all (drag-drop case), the entire default scenario is used.

### Snapshot mode (Claude's verification path)

`youcoded/desktop/scripts/dev-tools/snapshot.js` is a pure-node script:

1. Loads the scenario JSONL + sidecar.
2. Imports `parseTranscriptLine` from `src/shared/transcript-parser.ts`.
3. Walks the JSONL, dispatches actions through the **chat reducer directly** (no React, no DOM) to build the final `SessionChatState`.
4. Applies sidecar overrides into a synthetic "scenario state" object.
5. Serializes everything into a deterministic JSON snapshot.

Snapshot JSON shape:

```json
{
  "scenario": "synthetic",
  "schemaVersion": 1,
  "timeline": [
    { "kind": "user", "text": "...", "pending": false },
    { "kind": "assistant-text", "text": "..." },
    { "kind": "tool", "name": "Bash", "status": "complete", "inputSummary": "ls -la", "resultSummary": "4 lines" },
    ...
  ],
  "toolCallsCount": 12,
  "orphanToolCalls": [],
  "attentionState": "ok",
  "stopReason": null,
  "statusbar": {
    "model": "claude-opus-4-7",
    "gitBranch": "master",
    "contextUsedPct": 0.42,
    "todosActive": 1,
    "subagentsActive": 0,
    "announcement": null,
    "syncWarningCount": 0
  }
}
```

Commands:

```bash
# Print snapshot to stdout
node scripts/dev-tools/snapshot.js synthetic

# Diff against committed baseline
node scripts/dev-tools/snapshot.js synthetic --diff

# Update baseline (after intentional change)
node scripts/dev-tools/snapshot.js synthetic --update

# Run --diff for every bundled scenario
node scripts/dev-tools/snapshot.js --all --diff
```

The pure-node approach is the load-bearing simplification: no Electron, no JSDOM, no Playwright. The snapshot is structural only — it catches "this transcript silently produces an orphaned tool card," "dedup dropped a user message," "attentionState ends in the wrong state," "todo count off by one." It does NOT catch cosmetic regressions (CSS, layout, color) — those stay in the visual workbench and require human eyes (or, later, a separate screenshot path if we ever add one).

### Synthetic-transcript coverage checklist

The single canonical synthetic transcript (`synthetic.jsonl`) must cover, in one continuous session:

- User message variants: short, multi-line, with code block, with markdown link.
- Assistant text variants: short, multi-paragraph, with code block, with table, with bullet list.
- `tool_use`/`tool_result` for every native tool: Bash, Edit, Read, Write, Glob, Grep, TodoWrite, Agent, WebFetch, WebSearch, Skill.
- At least one MCP tool example.
- A failed tool result (`is_error: true`).
- A grouped multi-tool turn (one assistant turn that emits several `tool_use` blocks before any text).
- An interrupt marker (`[Request interrupted by user]`).
- A compaction marker (the format CC writes when `/compact` runs).
- An extended-thinking heartbeat (the `thinking` block format).
- A non-`end_turn` stop reason (`max_tokens` or `refusal`) on at least one turn.
- Long markdown output (>1000 chars in one assistant text block) — exercises any truncation/scroll behavior.

The synthetic is hand-written, version-controlled, and locked by its snapshot baseline. Adding a new tool type or a new event shape requires (a) extending the synthetic, (b) extending the v1 checklist above to track the addition, (c) regenerating the snapshot baseline.

## Tab 3 — Theme cycle

One page. Renders the synthetic transcript fixture once per available theme (Light, Dark, Midnight, Crème, plus any others in the cycle list), stacked vertically with a theme-name label above each. Each instance is wrapped in its own `<ThemeProvider initialTheme="...">` inside the same `<ScenarioProvider>` — so all theme variants render the exact same chat content with their respective tokens applied.

No snapshot mode for this tab. Theme regressions are inherently cosmetic — broken contrast, missing background, wrong edge color — which structured snapshots wouldn't catch. The token computation itself is already covered by `theme-engine.test.ts`.

## Pre-binned scenarios & the redactor

### The synthetic primary

`dev/fixtures/conversations/synthetic.jsonl` + `synthetic.scenario.json`. Hand-crafted to maximize coverage per the checklist. Treated as load-bearing: changes require deliberate baseline updates. This is the canonical "what does the chat look like across the full surface area" reference.

### The real-anonymized bundle

3–5 scenarios pulled from `~/.claude/projects/`, each illustrating a *specific real-world shape* the synthetic can't fake authentically. Initial picks (subject to what's available locally):

- A long-running session that hit compaction at least once.
- A session where Destin interrupted CC mid-tool.
- A session with an MCP tool spike (multiple consecutive MCP calls).
- A session that died mid-turn (process exit during in-flight tool).
- An optional candidate: a session with extended-thinking heartbeats from an Opus turn.

Lives at `dev/fixtures/conversations/real-bundle/`, with a `README.md` documenting one-line descriptions of what each scenario illustrates.

### The redactor

`youcoded/desktop/scripts/dev-tools/redact-transcript.js` — node CLI. Reads a JSONL transcript, applies redaction passes, writes safe output. Operations in order:

1. **Path scrubbing.** Replace absolute paths and home-dir paths with `<HOME>/...`. Normalize forward slashes.
2. **Identity scrubbing.** Replace email addresses, GitHub handles, repo names, hostnames in tool args/results. The redactor takes a `--identities <file>.json` flag pointing to a name→placeholder map you maintain locally; same map produces same output across runs (so re-redacting later doesn't explode diffs).
3. **Secret patterns.** Strip anything matching common secret regexes (`gh[pous]_`, `ANTHROPIC-API-KEY`, `sk-ant-`, `ghp_`, `github_pat_`, `xoxb-`, etc.). The list lives in the script and grows when something new bites.
4. **Cwd rewrite.** Rewrite the JSONL's outer `cwd` field (every line that has one) to `/redacted/scenario`.
5. **Stable timestamps** (optional `--stable-timestamps` flag). Rewrite every `timestamp` field to a deterministic sequence so snapshot baselines don't churn when the redactor is re-run on the same input.

Output: redacted JSONL + a default `<name>.scenario.json` sidecar populated as follows:
- `cwd`: always `/redacted/scenario`.
- `gitBranch`: always `master`.
- `model`: detected from the input JSONL's `message.model` field on the most recent assistant turn (CC writes this). If no assistant turn carries a model, falls back to `claude-opus-4-7`.

You then hand-edit the sidecar to add scenario-specific state (announcements, sync warnings, attention state, todos) you want the chat frame to render.

The redactor is a reusable tool beyond this design — same script you'd run before attaching a transcript to a public bug report or sharing a session for review. That dual-use is intentional.

Curation flow: redact → review the output yourself for missed secrets/identities → drop the JSONL + sidecar into `real-bundle/` → add a one-line description to `real-bundle/README.md` → run `snapshot.js <name> --update` to lock the baseline.

## CC-coupling probe library

`youcoded/desktop/test-conpty/` keeps current shape. The methodology document at `test-conpty/README.md` is already the canonical "how to write more of these" reference and stays as-is.

### `test-conpty/INDEX.md`

A new catalog file with rows mapping each probe to the coupling it pins down. Schema:

```markdown
| Probe | Pins coupling | cc-dependencies row | Break symptom | Has baseline? |
|-------|---------------|---------------------|---------------|---------------|
| `cc-snapshot.mjs` | Paste threshold + echo behavior + version baseline | "PTY input bar echo" | Long sends silently fail to submit; or threshold drift | Yes (`snapshots/cc-<version>.json`) |
| `test-multiline-submit.mjs` | All three submit paths against real CC | "PTY paste classification" | Submits leave body in input bar with literal `\n` | No |
| ... | ... | ... | ... | ... |
```

Each row cross-references a row in `youcoded/docs/cc-dependencies.md` so the existing `review-cc-changes` release agent automatically learns about new couplings.

### V1 inventory

Carried over (existing):
- `cc-snapshot.mjs`
- `test-multiline-submit.mjs`
- `test-worker-submit.mjs`
- `test-attention-states.mjs`
- `test-spinner-fullcapture.mjs`
- `test-attention-false-match.mjs`

Two new probes:

**`test-transcript-emit.mjs`** — pre-trusts a temp cwd, drives real `claude` through a small scripted session that touches every tool type the parser cares about (Bash, Edit, Read at minimum), then reads back the resulting JSONL from `~/.claude/projects/<slug>/<session>.jsonl` and asserts each entry parses cleanly through `parseTranscriptLine` with the expected event shapes. Pins the parity-fixtures-vs-real-CC contract: today's parity tests run against hand-crafted JSONL, which can drift from what CC actually emits.

**`test-hook-relay-roundtrip.mjs`** — installs a temporary PreToolUse hook into a temp `~/.claude/settings.json` (saving and restoring the original), spawns CC with that settings, triggers a tool-use, asserts that `relay.js` writes the expected payload through the named pipe to a test consumer. Pins `youcoded-core/hooks/` ↔ CC ↔ HookRelay coupling.

### Run policy

No runner, no registry, no CI. Probes run on demand:
- At release time (per the existing release skill, which already orchestrates pre-release verification).
- When CC version bumps (per `cc-dependencies.md` workflow).
- When changing a probe-relevant area.

Token cost stays predictable. Each probe documents its expected runtime and token cost in its file header.

## Smoke test for the fixtures themselves

`youcoded/desktop/dev/fixtures/conversations.smoke.test.ts` — a vitest file that:

1. Imports every bundled scenario JSONL + sidecar.
2. Runs each through the snapshot script's core function (extracted as a shared helper).
3. Asserts no throw, no orphan tool calls (or only those marked as expected in the sidecar).
4. Validates the sidecar JSON shape against a schema.

Catches "I edited a fixture into an unparseable state" within `npm test`. Cheap, runs in milliseconds.

## Claude's verification workflows (concrete)

Three example workflows that crystallize how this tools-up:

**Claude is changing chat-reducer dedup logic.**
```bash
node scripts/dev-tools/snapshot.js --all --diff
```
Each scenario's snapshot diff shows up in stdout. Clean = no regression. Real diffs = Claude reads them and decides whether intended; updates baselines with `--update` if so.

**Destin is changing a chat bubble style.**
`bash scripts/run-workbench.sh` → Conversations tab → cycle through scenarios visually with HMR. Theme cycle tab to verify across themes. No baselines involved — pure visual review.

**Someone reports a broken transcript in production.**
Get the JSONL → drag-drop into the Conversations tab → watch the chat build. If rendering is wrong, the bug is in the renderer or reducer; if rendering matches what they saw, the bug is upstream (CC, hook relay, IPC). Halves the search space immediately.

## Phasing

Each phase independently shippable, in order:

1. **Workbench shell.** Add `?mode=workbench`, left-nav scaffolding, `run-workbench.sh`. Move existing `ToolSandbox` under it as the Tools tab. No new functionality — pure restructure. Existing `?mode=tool-sandbox` deep-link to the Tools tab preserved.
2. **Re-export shim.** Add `src/shared/transcript-parser.ts` with the one-line re-export. Verify `transcript-parity.test.ts` still passes. ~5 minutes.
3. **Conversations tab — synthetic only.** Build `ScenarioProvider`, scenario picker, drag-drop. Hand-write `synthetic.jsonl` + sidecar covering the v1 checklist. Render full chat frame with status bar.
4. **Snapshot script + baselines.** `scripts/dev-tools/snapshot.js`, baseline directory, `--diff` / `--update` / `--all` flags. Establish synthetic baseline. Wire smoke test.
5. **Theme cycle tab.** One-page render of synthetic across all themes.
6. **Redactor + real-anonymized bundle.** `scripts/dev-tools/redact-transcript.js`, redact 3–5 prod transcripts, drop them into `real-bundle/`, generate baselines, write `real-bundle/README.md`.
7. **Probe library inventory.** `test-conpty/INDEX.md`, `test-transcript-emit.mjs`, `test-hook-relay-roundtrip.mjs`. Update `youcoded/docs/cc-dependencies.md` with new probe rows.

Phases 1–4 are the load-bearing minimum. If we stop after phase 4 you already have the workbench shell, conversations tab with synthetic coverage, and Claude-driven snapshot verification — most of the value. Phases 5–7 are incremental enhancements.

## Out of scope (anti-scope-creep)

- **No screenshot / pixel-diff infrastructure.** Brittle, low signal-per-token, and structured snapshots cover the regression class that actually matters.
- **No headless Electron / Playwright / JSDOM.** Snapshot script stays pure node against the reducer. The "render in a browser" workflow stays manual visual review.
- **No CI integration for probes.** Real-`claude` spawns + token cost + CC startup variance don't fit CI. Probes run on demand.
- **No standalone status-bar tab.** Status bar rides atop conversations.
- **No overlays tab** (settings popup / command drawer / marketplace / theme-builder). Add later when friction warrants.
- **No Android-side workbench.** Renderer is shared; visual review from desktop covers the React UI. Android-specific UI can earn its own sandbox if needed later.
- **No multiplayer-game / remote-server / partykit sandboxes.**
- **No automated CC-version-bump probe runs.** Manual at release time.
- **No live-state recording from a running session.** The redactor takes static JSONLs; no "record this session" capture flow.

## Files touched (summary)

**New:**
- `youcoded/desktop/src/renderer/dev/workbench/WorkbenchShell.tsx`
- `youcoded/desktop/src/renderer/dev/workbench/tabs/ToolCardsTab.tsx`
- `youcoded/desktop/src/renderer/dev/workbench/tabs/ConversationsTab.tsx`
- `youcoded/desktop/src/renderer/dev/workbench/tabs/ThemeCycleTab.tsx`
- `youcoded/desktop/src/renderer/dev/workbench/ScenarioProvider.tsx`
- `youcoded/desktop/src/renderer/dev/fixtures/conversations/synthetic.jsonl`
- `youcoded/desktop/src/renderer/dev/fixtures/conversations/synthetic.scenario.json`
- `youcoded/desktop/src/renderer/dev/fixtures/conversations/real-bundle/*.jsonl` (3–5)
- `youcoded/desktop/src/renderer/dev/fixtures/conversations/real-bundle/*.scenario.json` (3–5)
- `youcoded/desktop/src/renderer/dev/fixtures/conversations/real-bundle/README.md`
- `youcoded/desktop/src/renderer/dev/baselines/conversations/*.snapshot.json`
- `youcoded/desktop/src/shared/transcript-parser.ts` (one-line re-export)
- `youcoded/desktop/scripts/dev-tools/snapshot.js`
- `youcoded/desktop/scripts/dev-tools/redact-transcript.js`
- `youcoded/desktop/test-conpty/INDEX.md`
- `youcoded/desktop/test-conpty/test-transcript-emit.mjs`
- `youcoded/desktop/test-conpty/test-hook-relay-roundtrip.mjs`
- `youcoded/desktop/dev/fixtures/conversations.smoke.test.ts`
- `scripts/run-workbench.sh` (workspace-root launcher mirroring `run-sandbox.sh`)

**Edited:**
- `youcoded/desktop/src/renderer/App.tsx` — extend the existing `?mode=` gate to recognize `'workbench'`.
- `youcoded/docs/cc-dependencies.md` — add rows for the two new probes.

**Untouched in production paths:**
- `src/main/transcript-watcher.ts` — only the new shim re-exports its functions.
- All existing chat/reducer/render code.

## Open questions for implementation planning

These are details to nail down during the implementation-plan step, not blocking the design:

- Exactly which scenario state keys does each status-bar widget read from? (Map widget → context source → required scenario field.)
- How does `ScenarioProvider` clean up between scenarios when switching tabs/picks? (Reducer reset + context-key-based remount, presumably.)
- What's the exact diff format `snapshot.js --diff` prints? (Plain JSON diff vs. structured stanza vs. unified diff.)
- Snapshot baseline conflict handling when multiple scenarios change in one PR.
