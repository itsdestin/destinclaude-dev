# ESC Key Chat Passthrough — Design

**Status:** Draft
**Author:** Destin (via Claude)
**Date:** 2026-04-21

## Problem

Pressing ESC while the chat pane is focused does nothing today. Users who want to interrupt the underlying Claude Code session must switch to the terminal view and press ESC there. The expected behavior — "ESC interrupts Claude" — is universal muscle memory from using Claude Code directly.

Additionally, when Claude Code writes its interrupt marker to the transcript, the current pipeline renders it as a normal user bubble and never ends the in-flight turn in the reducer. Tools stay in `running` / `awaiting-approval`, `isThinking` stays true, and the attention banner drifts.

## Goals

1. Pressing ESC in the chat pane sends `\x1b` to the PTY of the active session, interrupting Claude.
2. If an overlay (drawer, popup, modal) is open, ESC closes the overlay first — the PTY only receives ESC when nothing else wants it.
3. When the transcript shows the Claude Code interrupt marker, the current turn is ended in the reducer: `stopReason = 'interrupted'`, in-flight tools flipped to `failed`, `isThinking` cleared.

## Non-goals

- Changing ESC behavior inside the terminal view (xterm already pipes ESC natively to node-pty).
- Adding any new keybinding beyond ESC.
- Surfacing a confirmation prompt before interrupting.

## Background

### What ESC does today

- **ChatView** has a global keydown listener for arrow-key scroll. No ESC handler (ChatView.tsx:226-254).
- **InputBar** has two global keydown listeners — auto-focus on typing and idle-unfocus timer reset. Neither touches ESC (InputBar.tsx:108-130, 135-153).
- **Terminal view** forwards ESC natively via xterm → node-pty → Claude Code.

### How overlays dismiss on ESC today

Every overlay/popup/drawer wires its own window-level `useEffect` that listens for `e.key === 'Escape'` and calls `onClose`. ~20+ copies across the codebase (CommandDrawer, ShareSheet, SkillEditor, ResumeBrowser, CloseSessionPrompt, AboutPopup, RatingSubmitModal, ReportReviewButton, MarketplaceScreen, FileViewerOverlay, MarketplaceDetailOverlay, LibraryScreen, QuickChips, BuddyChat, and others). There is no centralized "is any overlay open" signal.

**QuickChips** registers its ESC listener in the capture phase (`addEventListener(..., true)`) so it beats other handlers when multiple overlays are open — an existing workaround for ordering issues in the ad-hoc model.

**BuddyChat** uses ESC as a **toggle**, not close-only. Its semantics differ from every other overlay.

### PTY input path

Both platforms have a clean path for sending raw bytes to the PTY:

- **Desktop:** `window.claude.session.sendInput(sessionId, text)` → preload.ts → `ipc-handlers.ts:1074` → `session-manager.ts:180` → pty-worker.js.
- **Android:** same method in `remote-shim.ts:583` → WebSocket `session:input` → `SessionService.kt:697` → `PtyBridge.writeInput`.

A single `\x1b` byte (1 byte) does **not** trigger Ink's 500ms `PASTE_TIMEOUT` — that applies to writes ≥2 chars. No chunking or pacing is needed. See `docs/PITFALLS.md` → "PTY Writes" for why multi-byte writes ending in `\r` require pacing.

### Transcript interrupt markers

Claude Code writes a `type: "user"` message with a single text content block when the user interrupts:

- `[Request interrupted by user]` — interrupt during reply generation.
- `[Request interrupted by user for tool use]` — interrupt during/before tool execution.

Today these flow through `TRANSCRIPT_USER_MESSAGE` and render as user bubbles. No reducer action recognizes them.

## Design

Three pieces, layered.

### 1. Centralized ESC stack (`useEscClose` hook)

New file: `youcoded/desktop/src/renderer/hooks/use-esc-close.ts`. Exports:

```ts
export function EscCloseProvider({ children }: { children: ReactNode }): JSX.Element;
export function useEscClose(isOpen: boolean, onClose: () => void): void;
export function useEscStackEmpty(): boolean;   // for chat-passthrough guard
```

Behavior:

- `EscCloseProvider` wraps the app at the root (in App.tsx, above any overlay). It owns a single ordered stack of `{ id, onCloseRef }` entries and installs one window keydown listener.
- `useEscClose(isOpen, onClose)` pushes an entry when `isOpen` flips true, pops on flip-to-false or unmount. Stores `onClose` in a ref so identity changes across re-renders don't cause stack churn — the latest closure is always called.
- On ESC: pop the top of the stack (last-pushed = last-opened = "topmost") and call its `onClose`. Call `e.preventDefault()` + `e.stopPropagation()` so no other listener fires.
- If stack is empty, the listener returns without preventing default — the chat-passthrough listener picks up from there.

Implementation note: the provider's listener registers in **capture phase** so it runs before any leftover direct listener. This makes the refactor order-independent (old and new handlers can coexist during the migration).

### 2. Chat ESC passthrough (App.tsx)

Inside `App.tsx`, install one window keydown listener (bubble phase). On ESC:

```ts
function shouldForwardEscToPty(params: {
  defaultPrevented: boolean;   // provider sets this if it handled the ESC
  viewMode: 'chat' | 'terminal';
  hasActiveSession: boolean;
  buddyChatOpen: boolean;
}): boolean {
  return !params.defaultPrevented
      && params.viewMode === 'chat'
      && params.hasActiveSession
      && !params.buddyChatOpen;
}
```

When the guard returns true, call `window.claude.session.sendInput(activeSessionId, '\x1b')`.

- `defaultPrevented` comes from the KeyboardEvent itself. The provider calls `e.preventDefault()` after popping and invoking an overlay's `onClose`, so this flag is the authoritative "an overlay consumed it" signal — robust even though the stack is now empty post-pop.
- `viewMode` comes from the existing per-session view-mode state (`App.tsx:1555`).
- `hasActiveSession` is `!!activeSessionId`.
- `buddyChatOpen` is read from wherever BuddyChat's open state lives (it is intentionally *not* migrated to `useEscClose` — see "BuddyChat carveout" below).

**Listener ordering:** the provider registers in **capture phase**, the passthrough registers in **bubble phase**. Capture runs before bubble in the DOM event model, so the provider always gets first dibs on ESC. If the provider handles it (stack non-empty), it calls `preventDefault()`. The passthrough then sees `defaultPrevented === true` and returns. If the stack was empty at the time of the event, the provider is a no-op and `defaultPrevented` stays false, so the passthrough proceeds.

The decision function is extracted as a pure helper so it can be unit-tested without mounting the App.

### 3. Transcript interrupt detection + reducer handler

**`transcript-watcher.ts`**: in the branch that currently emits `TRANSCRIPT_USER_MESSAGE`, check the content. If it is a single text block whose text matches one of the two interrupt strings exactly, emit:

```ts
{
  type: 'TRANSCRIPT_INTERRUPT';
  sessionId: string;
  uuid: string;
  timestamp: number;
  kind: 'plain' | 'tool-use';
}
```

instead. The interrupt marker is *not* also emitted as `TRANSCRIPT_USER_MESSAGE` — we suppress the user bubble entirely.

**`chat-types.ts`**: add `TRANSCRIPT_INTERRUPT` to the `ChatAction` union.

**`chat-reducer.ts`**: new handler for `TRANSCRIPT_INTERRUPT`. Mirrors the `TRANSCRIPT_TURN_COMPLETE` shape described in `docs/chat-reducer.md`:

1. Find the current in-flight assistant turn (`currentTurnId`). If present, attach `stopReason: 'interrupted'` via spread-then-override on `assistantTurns`.
2. Spread `endTurn()` afterward. The helper handles: flip any `running` / `awaiting-approval` tool in `activeTurnToolIds` to `failed` with error `'Turn interrupted'`, clear `isThinking`, `streamingText`, `currentGroupId`, `currentTurnId`, reset `activeTurnToolIds` to a fresh Set, reset `attentionState` to `'ok'`.
3. If no in-flight turn exists (late marker, very early interrupt, or replay), still call `endTurn()`. It's idempotent — no crash, no orphan fields.

The override-before-endTurn ordering is identical to `TRANSCRIPT_TURN_COMPLETE`'s documented pattern and is required because `endTurn()` does not touch `assistantTurns`.

**`AssistantTurnBubble`**: the existing stopReason-to-copy map gains one entry: `interrupted → "Interrupted"`. The existing inline-footer render path surfaces it with no other changes.

## Data flow

**ESC with overlay open:**
```
keydown(Escape)
  → EscCloseProvider listener (capture) pops stack top → calls onClose → preventDefault
  → chat-passthrough listener (bubble) sees defaultPrevented → no-op
```

**ESC with no overlay, chat view, active session:**
```
keydown(Escape)
  → EscCloseProvider listener: stack empty → no-op
  → chat-passthrough listener: guard passes → window.claude.session.sendInput(sid, '\x1b')
    → IPC → session-manager → pty-worker → PTY → Claude Code
    → Claude Code writes "[Request interrupted by user]" (or "for tool use") to JSONL
  → transcript-watcher parses → emits TRANSCRIPT_INTERRUPT
  → reducer: attach stopReason='interrupted' to current turn, then endTurn()
  → UI: thinking indicator clears, in-flight tools show as failed, turn footer shows "Interrupted"
```

**ESC in terminal view:**
```
keydown(Escape)
  → EscCloseProvider listener: stack empty → no-op
  → chat-passthrough listener: viewMode === 'terminal' → no-op
  → xterm native path: forwards \x1b to node-pty → PTY (existing behavior, unchanged)
```

## Edge cases

- **ESC while typing in chat input textarea** → forwards to PTY. The textarea isn't a modal; ESC there does nothing useful today. InputBar's existing listeners don't preventDefault or consume ESC.
- **ESC while session is idle** → harmless. Claude Code ignores ESC with no turn in-flight; no transcript marker is written; no `TRANSCRIPT_INTERRUPT` is dispatched.
- **ESC with no active session** → guard returns false. No send.
- **Two overlays open simultaneously** → stack-top (last-opened) closes. Today both close because they each wire their own listener. Silent bug fix.
- **Interrupt arrives when no in-flight turn** → `endTurn()` is safe to call when state is already clear. No crash, no orphan.
- **Interrupt during tool approval dialog** → the `for tool use` variant routes through the same reducer handler. `endTurn()` flips the awaiting-approval tool to `failed` with error `'Turn interrupted'`; existing UI renders this via its normal tool-failure path.
- **Remote browsers** → inherit the feature for free. Same React UI, same `window.claude.session.sendInput` shim over WebSocket, same `transcript-watcher` on the desktop host broadcasting via `chat:hydrate` + live events.
- **User types the literal string `[Request interrupted by user]`** → treated as interrupt. Acceptable false-positive: the string is rare enough in organic user text that distinguishing it would require fragile heuristics (no UUID or flag differentiates it in the transcript). Documented as a known edge.

## BuddyChat carveout

BuddyChat uses ESC as an **open/close toggle**, not close-only. It does not fit the `useEscClose` model. Keep its existing direct listener unchanged. The chat-passthrough guard explicitly checks `!buddyChatOpen` so ESC with BuddyChat open doesn't also fire the PTY interrupt. Annotate the guard with a WHY comment:

```ts
// BuddyChat uses ESC as a toggle, not close-only — skip PTY interrupt when it's open
// so a single ESC doesn't both toggle buddy and interrupt Claude.
```

If BuddyChat ever moves to a different keybinding for toggle, delete the carveout and remove the parameter.

## Migration of existing overlays

Mechanical replacement, ~20 files. For each overlay with the current pattern:

```tsx
useEffect(() => {
  if (!open) return;
  const handler = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
  window.addEventListener('keydown', handler);
  return () => window.removeEventListener('keydown', handler);
}, [open, onClose]);
```

Replace with:

```tsx
useEscClose(open, onClose);
```

**QuickChips**: its capture-phase listener becomes unnecessary (`QuickChips.tsx:251-262`). Delete the capture logic and use `useEscClose` — stack ordering naturally wins.

**Components with `inFlight` guards** (RatingSubmitModal, ReportReviewButton): wrap the `onClose` with the same guard before passing to `useEscClose`:

```tsx
const guardedClose = useCallback(() => { if (!inFlight) onClose(); }, [inFlight, onClose]);
useEscClose(open, guardedClose);
```

## PITFALLS doc update

Add one entry to `docs/PITFALLS.md` under a new section "Keyboard Routing" (or append to an existing related section):

> **ESC handling routes through `useEscClose` stack → chat-passthrough guard.** Don't add parallel window-level ESC listeners; they break stack ordering and can race the chat-passthrough to the PTY. Exceptions: BuddyChat (uses ESC as toggle, not close-only) and xterm (terminal view forwards ESC natively). If you need a new ESC behavior, add it to the stack or gate it behind the existing guard.

## Testing

### Unit tests (new)

**`use-esc-close.test.tsx`** — stack semantics:
- Single overlay: open → ESC calls `onClose`, pops stack. Closed → ESC does nothing.
- Two overlays A then B: ESC closes B only; second ESC closes A.
- Unmount while open: entry removed from stack.
- `onClose` identity changes across re-renders: latest `onClose` called, not stale.
- `useEscStackEmpty()` returns true initially, false while open, true after close.

**`shouldForwardEscToPty.test.ts`** — pure function truth table: all 16 combinations of the 4 booleans.

**`transcript-watcher.test.ts`** (extend existing):
- User message with exactly `[Request interrupted by user]` → emits `TRANSCRIPT_INTERRUPT { kind: 'plain' }`, does NOT emit `TRANSCRIPT_USER_MESSAGE`.
- User message with exactly `[Request interrupted by user for tool use]` → emits `TRANSCRIPT_INTERRUPT { kind: 'tool-use' }`.
- User message with any other text → emits `TRANSCRIPT_USER_MESSAGE` (regression check).
- User message with interrupt text embedded in longer content (e.g. `"Hey, [Request interrupted by user]"`) → emits `TRANSCRIPT_USER_MESSAGE`. Only exact match triggers interrupt.

**`chat-reducer.test.ts`** (extend existing):
- `TRANSCRIPT_INTERRUPT` with in-flight turn + 1 running tool + 1 awaiting-approval tool → current turn `stopReason === 'interrupted'`; both tools flipped to `failed` with error `'Turn interrupted'`; `isThinking === false`; `activeTurnToolIds` empty; `attentionState === 'ok'`.
- `TRANSCRIPT_INTERRUPT` with no in-flight turn → state after matches `endTurn()` semantics. No crash.

### Manual verification (before merge)

Both desktop and Android APK, all three scenarios:

1. Chat view, Claude thinking → press ESC → turn ends, "Interrupted" footer appears under the turn, next prompt works (no stuck state).
2. Chat view, Settings drawer open → press ESC → drawer closes, Claude keeps thinking.
3. Terminal view (Ctrl+`) → press ESC → Claude interrupts via xterm's native path; chat-passthrough listener does NOT fire (add a temporary log during verification to confirm).

Plus one remote-browser pass: connect a browser via WebSocket, repeat scenarios 1 and 2.

## Files touched

**New:**
- `youcoded/desktop/src/renderer/hooks/use-esc-close.ts`
- `youcoded/desktop/src/renderer/hooks/use-esc-close.test.tsx`
- `youcoded/desktop/src/renderer/state/should-forward-esc-to-pty.ts`
- `youcoded/desktop/src/renderer/state/should-forward-esc-to-pty.test.ts`

**Modified:**
- `youcoded/desktop/src/renderer/App.tsx` — mount `EscCloseProvider`, install passthrough listener.
- `youcoded/desktop/src/renderer/state/chat-types.ts` — add `TRANSCRIPT_INTERRUPT` action.
- `youcoded/desktop/src/renderer/state/chat-reducer.ts` — handle `TRANSCRIPT_INTERRUPT`.
- `youcoded/desktop/src/main/transcript-watcher.ts` — detect interrupt markers.
- `youcoded/desktop/src/renderer/components/AssistantTurnBubble.tsx` — add `interrupted` → `"Interrupted"` copy.
- `youcoded/desktop/src/renderer/components/CommandDrawer.tsx`, `ShareSheet.tsx`, `SkillEditor.tsx`, `ResumeBrowser.tsx`, `CloseSessionPrompt.tsx`, `AboutPopup.tsx`, `RatingSubmitModal.tsx`, `ReportReviewButton.tsx`, `MarketplaceScreen.tsx`, `FileViewerOverlay.tsx`, `MarketplaceDetailOverlay.tsx`, `LibraryScreen.tsx`, `QuickChips.tsx`, and any other popups currently wiring their own ESC `useEffect` — migrate to `useEscClose`.
- `docs/PITFALLS.md` — add "Keyboard Routing" entry.

**Unchanged by design:**
- `youcoded/desktop/src/renderer/components/BuddyChat.tsx` — ESC is a toggle, not close-only.
- `youcoded/desktop/src/renderer/components/TerminalView.tsx` — xterm's native ESC forwarding is the terminal-view path.
- Android Kotlin code — protocol unchanged; `session:input` already carries arbitrary bytes.
