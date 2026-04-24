# Context — StatusBar Popup

**Date:** 2026-04-24
**Scope:** Desktop + Android (shared React UI)
**Repo:** `youcoded/` (renderer-only changes)

## Purpose

Turn the existing non-interactive **Context: N% Remaining** status bar pill into a clickable chip that opens a small popup with (a) a better explanation of what context is and why it matters, (b) a primary action to run `/compact`, optionally with focusing instructions, and (c) a secondary action to run `/clear`. This gives users a single discoverable surface for context management instead of asking them to remember slash commands.

## Problem

The context chip at `StatusBar.tsx:680-688` is a plain `<span>`. Two usability gaps follow:

1. **No explanation.** Users who don't already know what "context %" means have no way to learn in-app. The widget-config tooltip mentions it briefly ("How much of Claude's conversation memory remains. Lower means Claude may forget earlier context") but the tooltip is only visible while configuring the status bar — not while looking at the chip itself.
2. **No action path.** When the number drops low, the only remedy requires typing a slash command into the terminal. Users who don't know `/compact` exists live with a red chip they can't act on.

The consolidated popup solves both. It surfaces the actions next to the indicator that triggers the thought, and pairs them with inline education so a non-developer can learn the "why" the first time they open it.

## Scope — what's in and what's out

**In scope:**
- Renderer-only. No IPC, main-process, or Kotlin changes.
- Current session only. The popup reads `contextPercent` / `contextTokens` for the active session from the existing StatusBar props.
- Actions limited to `/compact`, `/compact <instructions>`, and `/clear`. All three are already wired in `slash-command-dispatcher.ts` — no dispatcher changes.

**Out of scope (deferred):**
- "What's using context" diagnostic breakdown (system prompt, skills, files, history). Claude Code does not expose the shape cleanly; we'd be guessing.
- Context-over-time history or sparkline. Cheap to add later if usage shows it matters.
- Auto-compact nudges or modals. The popup is user-triggered.
- Starting a brand-new session from the popup. Already covered by the session strip's "+" button; duplicating it invites confusion about which path is canonical.
- Cross-device sync of any state — the popup has no persistent state.

## Trigger & anchoring

The `<span>` at `StatusBar.tsx:680-688` becomes a `<button>` with the same pill styling (`flex items-center gap-1 px-1.5 py-0.5 rounded-sm bg-panel border border-edge-dim`) plus a `hover:` ring treatment matching the other clickable chips in the bar (usage-5h / usage-7d / theme — all already buttons with identical base styles). `aria-label="Context: {N}% remaining. Click to manage context."` for accessibility.

Clicking opens `ContextPopup` via `createPortal`. The popup uses the existing overlay primitives:
- `<Scrim layer={2}>` — theme-tinted backdrop, closes on click
- `<OverlayPanel layer={2}>` — the container (pulls `--overlay-bg`, `--overlay-blur`, `--shadow-strength` from theme tokens)

Because the status bar lives at the bottom of the window, the popup anchors **above** the chip (bottom edge of popup aligned to top edge of chip, plus a small gap). Horizontal position follows the chip's center, with clamping so the popup never overflows the window right edge. Same approach `ModelPickerPopup` uses for its tooltip portal.

Close triggers: Escape (via the existing `useEscClose` stack — register at layer 2), scrim click, header X button, or action dispatch (clicking Compact / Clear closes the popup after firing the command).

## Popup layout — main view

A single-column panel, ~320px wide, sections stacked with `gap-3` between them.

### Header row
- Title "Context" (left).
- `(i)` info button (right of title) — flips to the info view (section below).
- Close X (far right).

### Current state block
- Big number: `{contextPercent}%` in the same color the chip uses today (`contextColor()` — green / amber / red bands at existing thresholds).
- One line under it: `{contextTokens?.toLocaleString()} tokens remaining` (hidden gracefully if `contextTokens` is null).
- One plain-language hint line that keys off the color band:
  - `> 60%`: "Plenty of room — no action needed."
  - `20–60%`: "Getting tight — consider compacting soon."
  - `< 20%`: "Very low — compact now or Claude may start forgetting earlier context."

### Actions block

**Split button — "Compact conversation"** (primary):
- Main button area: click fires `dispatchSlashCommand('/compact', …)`. Popup closes.
- Right-edge chevron: click flips the actions block into an inline editor (does NOT close the popup):
  - Small `<textarea>` labeled "Keep these priorities (optional)"
  - Placeholder: `"e.g. keep code decisions and architecture; drop debugging output"`
  - Two buttons: **Compact with instructions** (primary — dispatches `/compact <trimmed text>`, closes popup) and **Back** (returns to default actions view, keeping the popup open).
  - If the text field is empty on submit, button is disabled (or falls back to plain `/compact`) — pick disabled for clarity.

The split-button itself is a new small primitive co-located in `ContextPopup.tsx` (no existing one in the codebase — checked). Visually: main button and chevron share a single border and rounded corners, separated by a 1px internal divider. Follows the existing button token set (`bg-accent text-on-accent` for primary).

**Secondary button — "Clear and start over"**:
- Quieter treatment (border + `bg-panel`, not filled accent).
- Under the button: one-line note — "Erases the visible timeline and resets Claude's memory for this session. No summary is kept."
- Click fires `dispatchSlashCommand('/clear', …)`. Popup closes.

Both actions require `sessionId` — if for any reason the active session is unavailable the buttons render disabled. Matches existing dispatcher expectations.

## Popup layout — info (i) view

Host popup keeps a `showInfo: boolean` state. When true, the main view hides and `<SettingsExplainer>` renders in the same panel frame. This is the exact pattern `RemoteButton`, `SyncPopup`, and `ThemeScreen` use — reuse the component, don't invent a new one.

Content (plain language, aimed at non-developers):

**Title:** "Context"

**Intro:** "Context is Claude's short-term memory for this conversation. The percentage shows how much room Claude has left before it starts forgetting the earliest messages."

**Section 1 — Why it matters**
- Paragraph: "The higher it is, the more Claude remembers — every file you opened, every decision you made together, the full thread of what you're building. When it gets low, Claude may forget files you discussed earlier, lose track of decisions, or repeat questions it already asked. Running out mid-task usually means worse answers and extra back-and-forth."

**Section 2 — What fills it up**
- Bullet: **Your messages and Claude's replies** — Every turn of the conversation stays in memory.
- Bullet: **Tool output** — When Claude reads files, runs commands, or lists directories, the results go into context too. This is usually the biggest contributor.
- Bullet: **Attached files and images** — Anything you drag into the input bar.
- Bullet: **Loaded skills** — Installed skills contribute their instructions to every turn.
- Paragraph closing: "Long sessions with lots of file reads fill it up fastest."

**Section 3 — What to do when it gets low**
- Bullet: **Compact** — Claude summarizes the conversation so far and keeps going in the same session. The thread stays alive. Use optional instructions to tell Claude what to prioritize keeping (e.g. code decisions vs. debugging output).
- Bullet: **Clear** — Wipes the conversation and starts fresh in the same session. No summary is kept. Good when you're switching to an unrelated task.
- Bullet: **New session** — Opens a separate conversation from scratch and leaves this one intact. Good when you want to preserve this conversation's state while working on something else. (Use the + button in the session strip at the top of the window.)

Back + Close buttons at the bottom — standard `SettingsExplainer` footer, no customization needed.

## Command wiring

No changes to `slash-command-dispatcher.ts`. The three relevant cases already exist:

- `/compact` at dispatcher line 81 — emits `COMPACTION_PENDING`, forwards `/compact[ <args>]\r` to PTY.
- `/clear` at dispatcher line 104 — emits `CLEAR_TIMELINE`, forwards `/clear\r` to PTY.

The popup's three buttons call `dispatchSlashCommand` with:
1. Plain compact: `{ input: '/compact' }`
2. Focused compact: `{ input: '/compact <trimmed instructions>' }`
3. Clear: `{ input: '/clear' }`

`sessionId` comes from the StatusBar's active-session prop chain (same prop the chip already reads `contextPercent` from). All existing side effects — pending card, `COMPACTION_COMPLETE` marker with "freed X tokens", `CLEAR_TIMELINE` reducer action — fire unchanged.

## State & props

`ContextPopup` is stateless apart from two local `useState`s:
- `showInfo: boolean` — toggles main / info view.
- `customizing: boolean` — toggles the actions block between the default buttons and the focused-compact editor.
- `instructions: string` — textarea contents when customizing.

Props from `StatusBar`:
- `open: boolean`, `onClose: () => void`
- `anchorRect: DOMRect | null` — position for the portal
- `contextPercent: number | null`, `contextTokens: number | null`
- `sessionId: string | null`
- `onDispatch: (input: string) => void` — a thin wrapper around `dispatchSlashCommand`. `StatusBar.tsx` does not own dispatcher wiring today (App.tsx and InputBar are the only call sites), so the implementation plan must thread the wrapper down from `App.tsx` — the component that already passes StatusBar its status-data props. The wrapper supplies the dispatcher's required callbacks (`dispatch`, `getUsageSnapshot`, `onToast`) from App.tsx scope and takes only `input: string` + implicit active `sessionId` so the popup stays decoupled from the dispatcher's full input shape.

No new global state. No new reducer actions. No new IPC types.

## Files touched

**New:**
- `youcoded/desktop/src/renderer/components/ContextPopup.tsx` — popup component, inline split-button primitive, inline explainer content.

**Edited:**
- `youcoded/desktop/src/renderer/components/StatusBar.tsx` — convert the context span into a button, manage popup `open` state + anchor rect, render the popup.

That's it. Unit test coverage follows the existing popup pattern (see `ModelPickerPopup` — light; renders + click handlers). Explainer content is static so needs no test beyond a smoke render.

## Platform considerations

The React renderer is shared between Electron and the Android WebView (see `docs/shared-ui-architecture.md`). This feature is **pure UI** with no platform-specific branches — it works on both surfaces automatically. No `preload.ts` / `remote-shim.ts` parity work, no `SessionService.kt` handler, no IPC type strings to keep in sync. Documented here explicitly because the cross-platform checklist in `PITFALLS.md` is the default mental model and a reader should know this is one of the rare cases where the default checklist genuinely doesn't apply.

## Accessibility

- Chip becomes a real `<button>` with `aria-haspopup="dialog"`, `aria-expanded`, and `aria-label`.
- Popup is a `role="dialog"` with `aria-modal="true"` (consistent with other L2 overlays) and focus is trapped until close.
- First focusable element on open: the `(i)` info button (chosen because users reading the pill are most likely first-time users who benefit from the explainer — change if user testing shows otherwise).
- Escape closes. Enter on the main compact button dispatches.
- Info view gets a visible "Back" control (SettingsExplainer default) and preserves focus return to the `(i)` button on back.

## Theming

Everything is token-driven via `<OverlayPanel layer={2}>`. No hardcoded colors, blurs, shadows, or z-indexes — per the Overlay Layer System rule in `docs/shared-ui-architecture.md`. The big `{N}%` figure uses `contextColor()` (already theme-independent by design — status colors are a deliberate exception in the theme rules).

## Success criteria

- Clicking the Context chip opens the popup; Escape, scrim, and X all close it.
- Clicking **Compact conversation** runs `/compact` via the existing dispatcher; the pending card appears in chat.
- Clicking the chevron opens the inline editor; typing instructions and submitting dispatches `/compact <instructions>`; dispatcher forwards it verbatim to the PTY.
- Clicking **Clear and start over** runs `/clear`; timeline clears and PTY receives `/clear`.
- The `(i)` button flips to the explainer; Back returns to the main view.
- The popup renders identically on desktop Electron and Android WebView (verified by building the web UI and launching the Android app).
- No regressions in StatusBar chip rendering when `contextPercent` is null (e.g. session not yet started).
