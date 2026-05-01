# Resume Active Sessions on Startup — Design

**Date:** 2026-05-01
**Status:** Design — pending implementation plan

## Problem

When YouCoded closes with sessions still live in the strip — because the user closed the window, the app crashed, or the OS killed it — the user loses their place. The existing `ResumeBrowser` lets them manually find any past session, but that's a "go look something up" experience. After an unintended close, the user wants a "we caught you, here's your work back" experience.

This spec defines that recovery flow: an opt-in, one-decision screen that appears on cold start when sessions were active and not deliberately closed.

## Scope

Distinct from the existing `ResumeBrowser` feature (manual browse + resume any past session from any project). This feature only handles **active-at-time-of-close** sessions and only fires automatically on cold start. It complements the ResumeBrowser, doesn't replace it.

In scope: desktop + Android, single-window restore, dead-and-clean-exit sessions treated identically, last-message preview.
Out of scope: multi-window restore (sessions all collapse into the main window for v1), reminders if the user picks "Start fresh", auto-resume without prompting.

## What gets tracked

A persisted list of currently-active sessions, stored at `~/.claude/youcoded-active-sessions.json`. Each entry captures:

- Desktop session ID
- Claude Code session ID (the JSONL filename)
- Project path / `cwd`
- Topic name snapshot (from `~/.claude/topics/topic-<id>` if present, else `"Untitled"`)
- Last-activity timestamp (epoch ms)

Only sessions that have had at least one real user prompt are tracked. Empty sessions are silently dropped — opening a tab and closing it without typing is not "in-flight work." Sessions that ended with `session-died` are treated identically to any other session in the list — no special flag, no extra badge, just offered for resume the same way.

The same file path is used on each platform: `~/.claude/youcoded-active-sessions.json`. On Android, `~/.claude` resolves inside the Termux env, which is a separate filesystem location from desktop's `~/.claude` — each platform owns its own copy of the file (matches the existing announcement-cache pattern). Cross-platform parity is at the JSON shape, not at the file location.

## When the list is updated

| Event | Effect |
|-------|--------|
| Session sends its first user prompt | Entry **added** |
| User closes a session via the X in the session strip | Entry **removed** |
| Topic file is written for the session | Entry's topic name **updated** |
| App quit, window close, crash, OS kill, session-died | List left **as-is** |

Writes are eager and atomic (write to a sibling temp file, then `rename`). On a crash, the file on disk is always within seconds of correct — no quit-hook dependency.

## Startup behavior

On cold start:

1. Read `youcoded-active-sessions.json`.
2. For each entry, check that the JSONL transcript still exists at `~/.claude/projects/<slug>/<sessionId>.jsonl`. Drop entries with missing transcripts silently.
3. If the resulting list is **empty** → render the normal welcome screen. The feature is invisible.
4. If the list has **one or more** entries → render the resume screen.

"Cold start" means the OS-level process start. On Android, this distinguishes "the OS killed us and we're booting fresh" (read the list) from "the user task-switched and is coming back" (`SessionService` is still alive, list is irrelevant). Warm resume from background never triggers the resume screen.

## The resume screen

A full-screen takeover replacing the welcome screen — not a modal, not a banner. The user must explicitly choose Resume or Start fresh; no ESC-to-dismiss.

### Layout (top to bottom)

- **Header:** `Welcome back. YouCoded closed with active sessions.` — calm tone, no scare copy.
- **Session cards** — vertically stacked rows, each containing:
  - Checkbox on the left, **all checked by default**.
  - Topic name (large; `Untitled` if no topic was written yet).
  - Project path + relative time (`youcoded-dev · 12 min ago`).
  - **Last user message** — one line, italic-quoted, ellipsis-truncated.
  - **Last assistant message** — one line, ellipsis-truncated.
  - Hover state on the whole row; clicking anywhere toggles the checkbox.
- **Footer:**
  - Primary button: `Resume all (N)` → `Resume selected (M)` once any are unchecked. Disabled at zero checked.
  - Secondary text link: `Start fresh`.

### Single-session case

If exactly one entry survives the precheck, the same layout renders — one card, primary button reads `Resume` (no count, no plural). The card is still rendered fully so the preview content is visible; "is this the conversation I want back?" is the same decision regardless of count.

### Last-message preview source

Last user / last assistant text comes from a tail-read of the session's JSONL via the existing `loadHistory` helper in `session-browser.ts`, asking for the last message of each role. Reads happen in parallel for all entries before the screen first renders.

## The resume-in-progress experience

When the user clicks Resume:

1. The resume screen unmounts immediately. The chat view appears.
2. The session strip already shows all selected sessions as tabs, each in a "resuming" visual state (dimmed + small spinner — same affordance the strip already uses for new-session bootstrap).
3. The most-recently-active selected session is focused. Its chat view shows historical messages (loaded via `loadHistory`) the moment they're available, with a `Reconnecting…` affordance at the bottom until the PTY is live.
4. As each session's PTY comes online, its tab transitions out of the "resuming" state. The user can switch tabs at any point; switching to a not-yet-ready tab shows the same loaded history + `Reconnecting…` affordance.
5. If a resume fails (Claude Code can't spawn, transcript can't load, etc.), the tab shows an error state with a single retry control. Other resumes are unaffected.

After successful resume, the active list reflects the restored sessions. Closing one via the X removes it from the list as normal. Another quit or crash re-offers whatever's still active.

## Start fresh

The secondary `Start fresh` link clears the active list entirely (the JSONL transcripts on disk are untouched — the user can still find them via `ResumeBrowser`) and transitions to the normal welcome screen.

No explanatory hint about ResumeBrowser is shown. The existing UI is discoverable without a one-time pointer.

## Edge cases

| Case | Behavior |
|------|----------|
| List file missing or unparseable | Treat as empty list. Normal welcome screen. Log warning. |
| All transcripts deleted | All entries fail precheck, list collapses to empty. Normal welcome screen. |
| Partial transcript loss | Show the resume screen with the entries that survive. Don't tell the user some were dropped. |
| Crash mid-resume | Active list still on disk. Successfully-resumed sessions are now properly tracked again (added on their first prompt). Sessions that hadn't yet spawned are still in the list from the prior session. Next startup re-offers them. Self-healing. |
| User closes every session via X then quits | List is empty at startup. No resume prompt. Matches the "I cleaned up before leaving" expectation. |
| Multiple windows on desktop | List is the union across all windows. v1 collapses everything into the main window on resume. |
| Android task-switch (warm resume) | `SessionService` is still alive; the resume list is not consulted. No prompt. |
| Topic not yet written | Card shows `Untitled`. |
| Session with empty transcript (transcript exists but has no `user` events) | Treated as transcript-missing — drop silently. Shouldn't happen in practice because tracking only begins on first prompt, but defensive. |

## Architecture notes

Implementation details for the planning phase to flesh out — not load-bearing for the design.

- **Persistence helper (desktop):** new Node module `desktop/src/main/active-sessions-store.ts` exporting pure-function lifecycle helpers (`addSession`, `removeSession`, `updateTopic`, `pruneMissingTranscripts`, `readList`, `writeListAtomic`) — testable without a running app.
- **Persistence helper (Android):** mirror in Kotlin at `app/.../runtime/ActiveSessionsStore.kt`, writing the same JSON shape into Android's own `~/.claude/youcoded-active-sessions.json` (inside the Termux env). Same pattern as `AnnouncementService.kt` mirroring `announcement-service.ts`. Both writers must agree on the field set; a small fixture test in each repo locks the shape.
- **New IPC message types:** `session:active-list-read` (returns the list, post-precheck) is the only one the renderer needs — lifecycle writes are triggered by reducer events, not user actions, and happen entirely in main / `SessionService`. The read message must be present in `preload.ts`, `remote-shim.ts`, `ipc-handlers.ts`, and `SessionService.kt` per cross-platform parity rules.
- **Resume screen component:** new `src/renderer/components/ResumeOnStartupScreen.tsx`. Mounted as a top-level state in `App.tsx` ahead of the welcome screen render path.
- **Reuse existing infrastructure:** the actual session resume mechanic (spawn Claude Code with `--resume <id>`, load history into the chat reducer) already exists from the `ResumeBrowser` feature. This design only adds the *triggering surface* — the resume screen itself — and the active-list persistence.

## Testing surface

Three things worth pinning to tests rather than hand-verification:

- **List file shape:** schema test on the JSON shape, locking the field set.
- **Lifecycle transitions:** unit tests for the pure-function store helpers (desktop) — covering add-on-first-prompt, remove-on-close-button, update-topic, prune-missing-transcript, atomic-write rollback. Kotlin mirror gets a smaller parity test that round-trips the same fixture JSON through `ActiveSessionsStore.kt`.
- **Resume screen rendering:** renderer test against a fixture list with varied states (no preview text, `Untitled`, single-item, all-checked vs. some-checked, zero-checked = button disabled).

## Open questions

None at design time. Implementation will surface concrete questions about animation timing, exact spinner styling, and IPC message-type naming — those belong in the plan.
