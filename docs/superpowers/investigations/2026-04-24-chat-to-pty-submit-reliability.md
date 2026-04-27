# Chat → PTY Submit Reliability — Investigation

**Date:** 2026-04-24
**Status:** Investigation complete; recommendation pending decision; no production code changed
**Scope:** Windows desktop only (ConPTY-specific). Mac/Linux/Android use Linux PTY which doesn't exhibit the failure.

## Problem statement

When the user sends a message from YouCoded's chat input bar on Windows, the message text occasionally appears in Claude Code's TUI input bar with a literal newline appended, but never submits. The text just sits there. The user then has to switch to terminal view and press Enter manually (or retype).

The failure is intermittent — Destin estimates ~10% of submits fail under heavy load (Claude mid-stream of a long response, multiple messages already queued in CC's pending-message UI).

This investigation followed two earlier fix attempts (commits c4ad3ce on 2026-04-10 and 45c05fb on 2026-04-17), both of which reduced the failure rate but didn't eliminate it. The user's request was to think harder about a robust long-term solution.

## Background — what the code currently does

The chat send path is:

```
InputBar.sendMessage (renderer)
  → window.claude.session.sendInput(sessionId, body + '\r')   (single string)
  → ipcMain handler
  → SessionManager.sendInput
  → worker.send({ type: 'input', data: body + '\r' })
  → pty-worker.js case 'input':
       chunk body in 64-byte slices, 50 ms apart   (byte-loss workaround)
       wait ENTER_DELAY_MS = 600 ms                (paste-timeout workaround)
       ptyProcess.write('\r')
  → node-pty
  → Windows ConPTY input pipe
  → Claude Code (Ink TUI) reads stdin
```

The 600 ms gap was sized to exceed Ink's `PASTE_TIMEOUT = 500 ms` heuristic, so that Ink would treat `\r` as a fresh keystroke (submit) rather than as the trailing byte of a paste (literal newline).

Prior commit history relevant to this area:

| Commit | Date | What it did |
|--------|------|-------------|
| `c4ad3ce` | 2026-04-10 | Original 700-char chunking @ 100 ms to dodge "[Pasted N lines]" detection |
| `e54faa3` | 2026-04-11 20:37 | Switched to bracketed paste markers, removed chunking |
| `5788110` | 2026-04-11 21:23 | **Reverted** bracketed paste 47 minutes later with unverified explanation: *"likely due to Windows ConPTY interfering with the escape sequences or the post-paste state machine in Ink absorbing the trailing `\r`"* |
| `45c05fb` | 2026-04-17 | Refined to current: 64-byte chunks @ 50 ms + 600 ms enter gap |

## Investigation methodology

### Phase 1 — Initial hypothesis from code reading

Read `desktop/src/main/pty-worker.js` and every `sendInput` call site in the renderer. Verified that all chat-style senders use the same `text + '\r'` pattern that funnels into the worker's split logic. The 600 ms `ENTER_DELAY_MS` is enforced consistently.

Initial hypothesis: ConPTY backpressure can collapse the worker-side gap. The 600 ms is measured at the moment the worker hands bytes to ConPTY's input pipe, not at the moment Claude Code reads them. When Claude is busy rendering, body bytes accumulate in the pipe; when `\r` is also written, it joins the queue; when Claude finally reads, both arrive within Ink's 500 ms `PASTE_TIMEOUT` window and `\r` is interpreted as paste content (literal newline) instead of submit.

### Phase 2 — Live diagnostic trace

Instrumented `desktop/src/main/pty-worker.js` with a flag-gated trace mode. When `YOUCODED_PTY_TRACE=1` is set in the environment that launches the dev process, the worker writes per-event timestamped log lines to `~/.claude/youcoded-pty-trace-<pid>.log`:

- `IN`  — every `case 'input'` arrival, with length, `endsCR` flag, head/tail preview
- `CHUNK` — every body chunk write with index `k/M` and length
- `CR` — when the trailing `\r` is written
- `OUT` — every PTY data event the worker receives back from the child
- `PASSTHROUGH`, `SPAWN`, `EXIT` — bookkeeping

The instrumentation is a no-op when the flag is unset.

Destin ran `YOUCODED_PTY_TRACE=1 bash scripts/run-dev.sh` and reproduced the failure across 11 chat sends, including one definite "stuck in input bar with newline" case.

### Phase 3 — Reading the trace

Worker-side timing was rock-solid for every submit:

| # | Body (truncated) | CHUNK→CR gap |
|---|------------------|--------------|
| 1 | "hey sexy boy" | 617 ms |
| 2 | "count to 200 with one number per line" | 618 ms |
| 3 | "also touch me please" | 619 ms |
| 4 | "hi please" | 688 ms |
| 5 | "please please please touch me all over" | 625 ms |
| 6 | "broooooo i literally dont like this" | 612 ms |
| 7 | "rahhhhh" | 617 ms |
| 8 | "testing testing 123 123 what rare you doing sexy boy" | 616 ms |
| 9 | "cutie" | 613 ms |
| 10 | "cutie cutie cutie" | 620 ms |
| 11 | **"Ha — what's up? Got something you want to chat about? I was just testing the chat"** | **(2 chunks 64+11) → CR 788 ms after last chunk** |

Submit #11 was the failed one. Worker-side trace:

```
[280686 ms] IN  len=76 endsCR=true head="Ha — what's up? Got something you want t…" tail="st testing the chat\r"
[280688 ms] CHUNK k=1/2 len=64
[280743 ms] CHUNK k=2/2 len=11
[281531 ms] CR
[…3.8 seconds of nothing from Claude…]
[285365 ms] OUT 702 bytes — body finally echoed back into Claude's input bar
[306508 ms] OUT cursor blink at row 46 col 3 (input bar)
[311740 ms] OUT cursor blink
[313388 ms] OUT 2373 bytes — Claude resumes its prior "count to 200" output
```

Diagnosis: Claude's `read()` on stdin didn't fire for ~3.8 s after we wrote the body. In that window both body and `\r` sat together in ConPTY's pipe. When Claude finally read, the kernel returned the entire backlog in one buffer drain — Ink saw 77 bytes of input with microseconds between them, classified them as one paste, and `\r` became literal newline.

The worker-side 788 ms gap is real. **It is not real to Ink when Claude is rendering.** ConPTY's input pipe does not preserve inter-write gaps when the consumer is backpressured.

### Phase 4 — Considered bracketed paste as alternative

Reasoning: bracketed paste markers `\x1b[200~` … `\x1b[201~` are an explicit protocol that tells Ink "everything between these markers is paste content; bytes outside the markers are keystrokes." If supported, they remove the timing race entirely.

Looked at git history — bracketed paste *was* shipped briefly in commit `e54faa3` and reverted 47 minutes later. The revert commit's stated reason was unverified ("likely due to ConPTY interfering with escape sequences"). The original implementation sent `\x1b[200~ + body + \x1b[201~` as one big write with no chunking, which would lose bytes on long messages — different problem from what the revert message blamed. So the historical evidence was inconclusive.

### Phase 5 — External research

Spawned a research subagent to verify three specific claims against primary sources:

1. **Does Ink support bracketed paste natively?** Yes, but only since v7.0.0 (March 2026). Pre-v7 Ink only has the `PASTE_TIMEOUT = 500 ms` heuristic — markers are treated as literal input.
2. **Settling time after `\x1b[201~`?** None. Ink's parser commits paste synchronously; a `\r` byte appended immediately after `\x1b[201~` is processed as a keystroke in the same microtask.
3. **Does Windows ConPTY preserve `\x1b[200~` / `\x1b[201~` on its input pipe?** Mixed evidence. microsoft/terminal#12166 documents ConPTY rewriting input-side escape sequences for some children; #17656 shows clipboard pastes arriving as per-character key events under certain modes. **No primary source confirmed pass-through for a Node.js child reading raw stdin.** The agent recommended empirical testing.

The third finding made bracketed paste an unverified bet, not a known answer. Proceeded to empirical testing.

### Phase 6 — Standalone harness

Wrote `youcoded/desktop/test-conpty/{harness.mjs, child.mjs}`. The harness:

- Spawns a Node.js child via the same `node-pty` library production uses, on the same Windows ConPTY backend.
- Child puts stdin in raw mode and logs every received chunk (length, hex dump, decoded text) with monotonic timestamps.
- Optional `SLOW=1` env var makes the child busy-spin for 2 s at startup, simulating a backpressured TUI mid-render.
- Runs six scenarios covering atomic vs split writes, idle vs busy child, short vs long body, with and without paste markers.

**First-iteration results — all six scenarios showed bracketed paste markers stripped by ConPTY**, including in the simplest atomic-idle case. This was a strong signal but had one unverified assumption.

### Phase 7 — Harness gap and re-run

Caught a real methodology gap: the dummy child never wrote `\x1b[?2004h` (the "enable bracketed paste mode" sequence) on its stdout. Bracketed paste is normally negotiated — the application enables it on stdout, and the terminal forwards markers in. Without that signal, ConPTY may have legitimately stripped markers because "the child doesn't want them."

Patched `child.mjs` to write `\x1b[?2004h\x1b[?1004h` on startup (mimicking what Claude Code does — visible at line 5 of the live trace as the first output Claude emits). Re-ran the harness.

### Phase 8 — Final harness results

| # | Scenario | Child saw | START preserved? | END preserved? |
|---|----------|-----------|------------------|----------------|
| A | atomic-idle | `hello\r` (6 bytes) | no | no |
| B | atomic-busy | `hello\r` (6 bytes) | no | no |
| C | split-busy | body+`\r` (64 bytes) | no | no |
| D | body+CR busy (current bug repro) | `hello\r` (6 bytes) | n/a | n/a |
| E | atomic long busy | 300 x's + `\r` (301 bytes) | no | no |
| F | **split long busy** | 300 x's + **`\x1b[201~`** + `\r` (307 bytes) | no | **yes** |

Two findings:

- **ConPTY's bracketed paste handling on Windows is inconsistent**, not just stripping. Five scenarios stripped both markers; one scenario (F) preserved the END marker but not the START. The behavior depends on chunking, write spacing, and ordering in ways we don't control.
- **Half-arriving markers are worse than no markers**, because they would put Ink into a paste-without-end state.

Bracketed paste is therefore not a viable fix on Windows ConPTY, regardless of Ink version, regardless of child setup.

The harness also independently confirmed:

- **Scenario D nailed the production bug.** Even with a 600 ms gap between `body` and `\r` writes, a busy child reads them together. No worker-side timing fixes this.
- **Scenario C** showed ConPTY merging four writes spaced 50 ms apart into a single child read once the child is backpressured. Adding more inter-write gaps at the worker is fundamentally a no-op once the child is behind.
- **Scenarios E vs F** confirmed the existing 64-byte/50 ms body chunking is still load-bearing (E lost data, F preserved it) — that part of the current code stays regardless of which fix path we choose.

### Phase 9 — Claude Code version

`claude --version` → `2.1.120 (Claude Code)`. Shipped as a 251 MB packed Windows .exe; bundled Ink version isn't trivially readable without unpacking the SEA binary. Given the harness result, the version is moot — even Ink 7.x with native bracketed-paste handling can't help when ConPTY corrupts the markers in transit.

## What's actually true (corrected from PITFALLS)

The current `docs/PITFALLS.md` entry on bracketed paste says *"the escapes arrive but the byte loss still happens inside ConPTY."* This investigation showed that's wrong on the first half — the markers do not reliably arrive. The byte-loss observation is correct (Scenario E confirmed a 300-byte single write was rejected entirely under backpressure), but it's a separate problem solved by chunking.

PITFALLS should be updated when this investigation produces a fix.

## Options analyzed

After bracketed paste was eliminated:

| Option | Mechanism | Strengths | Weaknesses |
|--------|-----------|-----------|------------|
| **Echo-driven `\r`** | After body is written, watch worker's `onData` for body's last bytes echoed back, then send `\r` | Strongest correctness — reacts to observed child state, not guessed timing | Sentinel false-positives, ANSI interleaving in echo, single-slot race for concurrent submits, doesn't help in tight render loops, couples worker to CC's stdout format |
| **OUT-quiet-window heuristic** | Send `\r` after worker observes ≥200 ms of stdout silence following body write | Simpler than echo-driven, no ANSI parsing | Fails when Claude is in a continuous render loop (the exact case observed in trace) |
| **Don't-send-while-busy** | Gate sends in InputBar behind `!isThinking && !hasRunningTools`, queue locally on renderer | Simplest by far, no worker changes, guaranteed reliable | Loses Claude Code's own native pending-message UI |
| **Adaptive timing** | Use longer gap (e.g. 3000 ms) when reducer says Claude is busy | Trivial change | Same fundamental flaw as current — backpressure can collapse any gap |
| **Bracketed paste markers** | Wrap body in `\x1b[200~` … `\x1b[201~` | Would be canonical if it worked | **Eliminated** — ConPTY mangles markers (Phase 8) |
| **Confirmation-driven retry** | Send normally; if optimistic bubble's `pending: true` flag is still set after N seconds AND Claude is idle, send a follow-up `\r` | Simplest meaningful change. Reuses pending-flag infrastructure that already exists. Failure mode self-heals. Worker untouched. | Adds 3–5 s latency to recovery on the ~10% of failed first attempts. Open question on `TRANSCRIPT_USER_MESSAGE` lag. |

## Current recommendation

**Confirmation-driven retry.** Stop trying to make every first-time submit work via worker-side protocol tricks. Detect the failure using the existing `pending: true` flag on optimistic chat bubbles, and recover by sending a follow-up `\r` (no body — body is already in Claude's input bar from the first attempt).

Sketch:

```
After USER_PROMPT dispatched (pending: true):
  schedule timer for N seconds
  on TRANSCRIPT_USER_MESSAGE that clears pending → cancel timer
  on timer fire:
    if still pending AND attentionState === 'ok' AND !isThinking:
      window.claude.session.sendInput(sessionId, '\r')
      schedule second timer for M seconds
      on second timer fire (still pending && idle):
        mark bubble as failed, show retry button
```

Why this is the right call:

- **No worker change.** Worker stays generic — no coupling to CC's stdout format, no sentinel matching, no per-version tuning.
- **Reuses an existing source of truth.** The `pending`/confirmed flag on user timeline entries is already authoritative for "did Claude actually receive this message." Building on it is cheaper than inventing new signals.
- **Idle gate avoids double-submit.** Only retry when Claude is observably idle. When Claude is `isThinking`, the message could still be queued in CC's own queue — leave it alone.
- **Failure mode becomes visible to the user.** If even the retry fails, the bubble flips to a failed state. The current bug is silent.
- **Strictly better than today.** Worst case: same as today. Common case: self-healing within 3–5 s.

## Open questions

1. **`TRANSCRIPT_USER_MESSAGE` latency under load.** What's the typical gap between a successful PTY submit and the corresponding `TRANSCRIPT_USER_MESSAGE` event? If transcript writes can lag 5+ seconds during heavy assistant turns, the retry threshold needs to be high enough to avoid false retries (which would manifest as double-submits). Worth spot-checking against the existing trace data and any other available transcript timing samples before locking in N.
2. **Does pressing `\r` on multi-line input always submit?** When the failed first attempt left `body\n` in Claude's input bar (body followed by newline), does sending another `\r` submit "body\n" as a multi-line message, or does it just append yet another newline? If the latter, we'd need a different recovery (e.g. clear the input via `Ctrl+U` or similar before re-typing). Worth a one-off manual test in dev mode before implementing.
3. **Concurrent submits race.** What's the right behavior if a second send arrives while a first is mid-retry? Probably: queue them strictly in the renderer so retries don't tangle. Worth designing this before coding.

## Artifacts produced this session

| Path | Purpose | Disposition |
|------|---------|-------------|
| `youcoded/desktop/src/main/pty-worker.js` | Added `YOUCODED_PTY_TRACE=1`-gated diagnostic trace (no-op when unset) | **Keep.** Useful for future PTY debugging. Trace is opt-in and zero overhead by default. |
| `youcoded/desktop/test-conpty/harness.mjs` | Standalone ConPTY byte-fidelity test | **Keep.** Reusable for future questions about what ConPTY does and doesn't preserve. |
| `youcoded/desktop/test-conpty/child.mjs` | Dummy PTY child for harness | **Keep.** Pair with harness. |
| `~/.claude/youcoded-pty-trace-25092.log` | Live trace of failed submit | Reference data; can be deleted after this is decided. |
| `docs/PITFALLS.md` "Bracketed paste was tried and failed historically" entry | Currently describes the wrong cause | **Update** when fix is decided — note that markers are *stripped/mangled by ConPTY*, not just "race other timers." |

## Phase 10 — Empirical follow-up (2026-04-25, follow-up audit)

After re-reading this document, the assumptions in Phases 1–8 were re-tested with a separate harness (`youcoded/desktop/test-conpty/test-multiline-submit.mjs`) that spawns the real `claude` binary via node-pty (not a dummy child) on idle CC, with the workspace-trust prompt pre-resolved to remove startup variance. Submit detection: spotting CC's randomized `<gerund>ing…` spinner suffix in stdout post-write.

Six scenarios on idle CC v2.1.119:

| # | Scenario | Submitted? |
|---|----------|------------|
| 3 | "CTEST" + 600 ms gap + "\r" — control mirroring worker | ✓ |
| 1 | atomic "ATEST\r" (6 bytes) | ✓ |
| 2 | atomic "BTEST\r" + 1.5 s + "\r" | ✓ |
| 4 | atomic "D" + 100 × "z" + "\r" (101 bytes) | **✗** |
| 5 | "ETEST" + 700 ms + "\n" + 1.2 s + "\r" | ✓ |
| 6 | atomic 101-byte body+\r (induce bug) + 2.5 s + bare "\r" | **✓** |

This forces three corrections to Phases 1–8:

1. **The "any write ≥2 chars is paste" model is wrong.** Six-byte atomic writes ending in `\r` submit cleanly on idle CC. Whatever Ink does, it isn't classifying every 2+-byte write as paste. The actual paste classification is **length-gated** — short writes pass through as keystrokes regardless of how they're delivered.
2. **The bug is reproducible on idle CC at sufficient length.** Scenario 4 shows that an atomic 101-byte body+\r leaves CC in the literal-newline state on a freshly-started, totally-idle session. No backpressure, no busy spin, no render loop. The "ConPTY collapses the gap under backpressure" framing in Phase 3 is at most a partial picture: under busy state the bug may also manifest at lengths that would otherwise pass, but it is fundamentally a length problem first. Scenarios A–F's harness used a 6–13-char payload — below the threshold — which is why those scenarios couldn't observe Ink classification effects directly.
3. **The retry plan's Open Question #2 is answered: yes, a bare `\r` submits the multi-line "body\n + cursor" state.** Scenario 6 reproduced the bug state by atomic 101-byte write, waited 2.5 s, then sent a bare `\r`. Trace shows the body rendering as a user message bubble and the `Accomplishing…` spinner kicking in — i.e. CC submitted the entire multi-line content. `useSubmitConfirmation`'s strategy is empirically validated, even though the underlying mechanism it was designed against is not fully what the earlier phases claimed.

Implications for the recommendation:

- Confirmation-driven retry is correct in spirit, but the threshold to test is "writes longer than ~N chars that race the busy state," not "every submit." Most chat sends are short and submit fine; the ~10 % failure rate Destin observes comes from longer payloads.
- A length-bisection probe (binary search 6 → 100) would identify the exact paste threshold and could let the worker decide whether to take the risky path at all. Worth doing before locking in tuning constants.
- The `pty-worker.js` 64-byte / 50 ms chunking is doing real work — it splits long bodies into chunks each individually under the threshold, which probably explains why the production bug rate is ~10 % and not 100 %. The investigation correctly preserved that path.
- The `Don't-send-while-busy` and `queue-locally` alternatives in the options table are still worth implementing as a fallback, because retry-on-idle has a 3–5 s recovery latency that user-typed sends rarely tolerate gracefully on the second attempt.

The previous "bracketed-paste markers are unreliable on Windows ConPTY" finding (Phase 8) stands — it was independently verified and is unrelated to the length threshold.

## What I learned about my own process

Things I'd do differently next time:

1. **Verify the harness's premises before drawing conclusions.** First-iteration harness returned a clean "markers are stripped" result, and I was ready to run with it. The second iteration (with the child enabling bracketed paste mode on stdout) gave the more honest "inconsistent and not viable" answer. The first-iteration false confidence cost roughly one iteration cycle.
2. **Don't trust commit messages that say "likely."** The 47-minute revert in `5788110` blamed ConPTY for a failure that was probably actually byte loss from a non-chunked single write. Re-investigating the actual cause was load-bearing.
3. **Don't assume PITFALLS is current.** It said markers arrive but byte loss happens. Half of that turned out to be wrong. Always re-verify against current behavior, especially when the entry is older than the area you're touching.
4. **Don't over-engineer protocol fixes when retry+verify is available.** I spent significant effort on echo-driven matching, OUT-quiet-window heuristics, and bracketed paste before noticing that the `pending`-flag mechanism already gave us authoritative success/failure detection. The simpler answer was sitting in `chat-reducer.ts` the whole time. The user's pushback ("we're overcomplicating this") was correct and worth listening to earlier.
