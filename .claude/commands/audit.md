---
description: Verify all documentation (CLAUDE.md, docs/, .claude/rules/, PITFALLS.md, memory files) against current code. Report drift with concrete fix instructions.
---

# /audit — Documentation Drift Verification

Re-runs the Phase 0 audit methodology to detect drift between documentation claims and actual code. Produces an updated `docs/AUDIT.md` with findings AND explicit fix instructions for every drift item.

## Usage

- `/audit` — audits all subsystems
- `/audit ipc` — audits only cross-platform IPC
- `/audit chat` — audits only chat reducer
- `/audit android` — audits only Android runtime
- `/audit toolkit` — audits only YouCoded toolkit
- `/audit release` — audits only build/release flow
- `/audit stale` — only checks last_verified dates and commit activity; does not re-verify

## Audit Methodology

### Step 1: Sync first
Run `bash setup.sh` to pull latest from all sub-repos. Stale git state invalidates findings.

### Step 2: Launch parallel verification subagents

Use the Agent tool with `subagent_type: Explore` for each scope. Each agent verifies one subsystem's claims against actual code. Run up to 3 in parallel.

Agents to launch (based on scope):

**IPC Audit agent** — verifies claims in:
- `docs/shared-ui-architecture.md`
- `.claude/rules/ipc-bridge.md`
- PITFALLS sections: "Cross-Platform"
- Memory: `arch_shared_ui_why.md`

Must check:
- `remote-shim.ts` platform detection logic
- `LocalBridgeServer.kt` port number
- `SessionService.handleBridgeMessage()` message type count
- `preload.ts` vs `remote-shim.ts` window.claude shape parity
- Protocol format (type+id+payload structure)

**Chat Reducer Audit agent** — verifies claims in:
- `docs/chat-reducer.md`
- `.claude/rules/chat-reducer.md`
- PITFALLS sections: "Chat Reducer"

Must check:
- `toolCalls` Map never-cleared invariant
- `activeTurnToolIds` Set existence and usage
- `endTurn()` helper signature and behavior
- Thinking timeout condition logic
- Dedup mechanism (confirm still content-based, no optimistic flag)

**Android Audit agent** — verifies claims in:
- `docs/android-runtime.md`
- `.claude/rules/android-runtime.md`
- PITFALLS sections: "Android Runtime"

Must check:
- `Bootstrap.buildRuntimeEnv()` sets LD_LIBRARY_PATH
- TMPDIR path (confirm $HOME/.cache/tmpdir, not $HOME/tmp)
- termux-exec linker variant deployment
- claude-wrapper.js canonical asset location
- PtyBridge + DirectShellBridge both use shared env
- sessionFinished StateFlow still the reactive source

**Toolkit Audit agent** — verifies claims in:
- `docs/toolkit-structure.md`
- `.claude/rules/youcoded-core-toolkit.md`
- Memory: `arch_three_layer_toolkit.md`, `arch_sync_design.md`, `arch_hook_enforcement.md`

Must check:
- Root + 3 layer plugin.json structure and versions
- hooks-manifest.json hook count and matchers
- Settings.json drift vs manifest
- session-start.sh responsibilities
- write-guard.sh and worktree-guard.sh behavior

**Release Audit agent** — verifies claims in:
- `docs/build-and-release.md`
- PITFALLS sections: "Releases"
- Memory: `arch_release_flow.md`

Must check:
- `build-web-ui.sh` existence and current behavior
- Android versionCode/versionName current values in build.gradle.kts
- Both workflows trigger on `v*` tag pattern
- auto-tag.yml behavior for plugin.json version changes

### Step 3: Recent-commits scan

For each sub-repo, run `git log --oneline -20` and identify:
- Architectural changes (renames, deletions, new subsystems)
- New files/directories not referenced in any doc/rule
- Deleted or renamed files that docs/rules still reference

### Step 4: Stale detection

For each rules file and doc, check `last_verified` frontmatter against `git log -1 --format=%ci` on referenced code paths. Flag any rules whose scoped code has been modified since last verification.

### Step 5: Produce report

Rewrite `docs/AUDIT.md` with structure:

```markdown
# Codebase Audit — <DATE>

## Summary
- Items verified: N
- Drift detected: N
- Stale (code changed since last verify): N
- New features undocumented: N
- References to removed files: N

## Confirmed (no action needed)
[Checklist of verified claims]

## Drift — Action Required
For each drift item:

### <Finding title>
- **Claim**: <what docs said>
- **Actual**: <what code does now>
- **Where**: <file:line of the drift>
- **Impact**: <what breaks if Claude acts on stale info>
- **Fix**:
  1. Edit `<file>` at `<section/line>`
  2. Change "<old text>" to "<new text>"
  3. Update `last_verified` in frontmatter to today
  4. Verify by: <specific check>

## Undocumented Features
[New code areas with no corresponding rule/doc; fix by creating...]

## Stale References
[Files no longer exist / renamed; fix by removing/updating...]

## Knowledge Debt Noted
[Items from knowledge-debt.md still unresolved]
```

### Step 6: Update last_verified dates

For each doc/rule/memory file that was verified as ACCURATE (not just checked), update its `last_verified` frontmatter field to today's date AND record the current HEAD commit of the code area it describes.

### Step 7: Log to knowledge-debt.md

For each drift item that wasn't fixed in this session, append to `docs/knowledge-debt.md` with the fix instructions so it persists across sessions.

## Fix Instructions Must Be Concrete

Every drift entry in the report MUST include:
1. **Exact file to edit** (absolute path)
2. **Section or line range** (so the fix is localized)
3. **Old text vs new text** (or specific content change)
4. **Verification command** (how to confirm the fix worked — e.g., "grep for X", "re-run `/audit ipc`")

Fix instructions are the whole point — without them, Claude just complains about drift without helping the user resolve it.

## After Running

- Review `docs/AUDIT.md` — the drift section is your fix backlog
- Apply fixes (ideally one PR per subsystem)
- Re-run `/audit <subsystem>` to confirm resolution
- Entries persist in `docs/knowledge-debt.md` until fixed

## When to Run

- **Before any release** — prevents shipping with stale docs
- **After major refactors** — touching IPC, reducer, or runtime
- **Monthly baseline** — even if nothing "feels" off
- **When Claude surprises you** — mentions a file that doesn't exist, claims behavior that isn't current, etc.
- **Quarterly full sweep** — run `/audit` (no scope) to verify everything
