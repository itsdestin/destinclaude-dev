# Apple Services — Implementation Handoff

**Purpose:** Self-contained context for picking up Apple Services implementation in a new Claude Code session. Read CLAUDE.md first, then this file. Everything you need to continue is below or linked.

**Last updated:** 2026-04-17 (Phase 0 research complete, spec + plan revised, ready to start Phase 1 Task 1)
**Workstream branch:** `feature/apple-services-workstream` in `youcoded-dev` (worktree at `.worktrees/apple-services/`)
**Execution mode:** subagent-driven-development (dispatch one implementer subagent per task; 2-stage review after each)

---

## What is this?

`apple-services` is a new YouCoded marketplace plugin giving Claude access to the six Apple apps on the landing page: **Calendar, Reminders, Contacts, Notes, Mail, iCloud Drive**. macOS-only.

Architecture in one paragraph: a sibling Swift CLI repo (`itsdestin/apple-helper`, new) builds a universal Mach-O binary that calls EventKit + Contacts framework directly. Notes and Mail (no public APIs) go through AppleScript/JXA. iCloud Drive is plain filesystem. A single shell wrapper `apple-wrapper.sh` dispatches by integration. `/apple-services-setup` walks through macOS TCC grants in seven steps. The helper binary is copied to `~/.apple-services/bin/` at setup so TCC grants survive plugin updates.

## Canonical sources (read these first)

1. **`docs/superpowers/specs/2026-04-17-apple-services-design.md`** — design spec (revised post-Phase-0)
2. **`docs/superpowers/plans/2026-04-17-apple-services-implementation.md`** — 30-task implementation plan (revised post-Phase-0)
3. **`docs/superpowers/plans/research/2026-04-17-apple-*.md`** — 9 Phase 0 findings files
4. **`CLAUDE.md`** + `docs/PITFALLS.md` — YouCoded workspace conventions (already auto-loaded in any session here)

Do not skip reading the plan — it contains complete code for every task. This handoff is only an entry point.

## Current state (what's committed)

On `feature/apple-services-workstream` (rebased onto master):

```
ec6d51c research: Phase 0 findings for apple-services
630ee96 docs(apple-services): revise spec + plan per Phase 0 findings
b6139fb docs(apple-services): revised design spec + implementation plan
411304c chore: gitignore .worktrees/
```

On `master` (behind feature branch by the one research commit):

```
ec6d51c → (not on master)
630ee96 docs(apple-services): revise spec + plan per Phase 0 findings
b6139fb docs(apple-services): revised design spec + implementation plan
```

Research findings live in `docs/superpowers/plans/research/`:
- `2026-04-17-apple-license-check.md` (R1)
- `2026-04-17-apple-imcp-audit.md` (R2)
- `2026-04-17-apple-tcc-behavior.md` (R3 — BLOCKED, desk research only)
- `2026-04-17-apple-dhravya-inventory.md` (R4)
- `2026-04-17-apple-imcp-macos14.md` (R5)
- `2026-04-17-apple-swift-universal.md` (R6)
- `2026-04-17-apple-osascript-errors.md` (R7)
- `2026-04-17-apple-icloud-placeholders.md` (R8)
- `2026-04-17-apple-contacts-tcc.md` (R9)

**Nothing on disk yet for the actual implementation.** No `itsdestin/apple-helper` repo, no `wecoded-marketplace/apple-services/` directory.

## Workstream layout

This plan spans **two repos**, each with its own role:

| Repo | Status | What it holds |
|---|---|---|
| `itsdestin/apple-helper` (new sibling) | Not created yet | Swift source + CI that builds universal Mach-O and opens vendor PR against wecoded-marketplace |
| `wecoded-marketplace/apple-services/` (new plugin dir) | Not created yet | Prebuilt binary + AppleScript/JXA + wrapper + SKILLs + setup command |
| `youcoded-dev` (this workspace) | Has spec + plan + findings | Docs only — no code for apple-services lives here |

Worktree strategy:
- Phase 0 (research): `youcoded-dev/.worktrees/apple-services/` ← we're here
- Phase 1 (Swift helper): clone `itsdestin/apple-helper` to `C:\Users\desti\apple-helper` (outside youcoded-dev, per Task 1)
- Phase 2 (plugin tree): worktree `youcoded-dev/.worktrees/apple-services/` contains the wecoded-marketplace feature branch — will need a separate worktree or this one will host both the docs and the plugin work

## Phase 0 findings summary (the critical context)

These findings already shaped the plan. When implementing, you need to know:

- **R1 license correction.** iMCP is **MIT**, not Apache-2.0. Repo moved: `loopwork/iMCP` → `mattt/iMCP`. Dhravya moved to `supermemoryai/apple-mcp`. Reminders-CLI confirmed MIT at `keith/Reminders-CLI`.
- **R2 — iMCP is Xcode-based, not SwiftPM.** Services live at `App/Services/{Calendar,Reminders,Contacts}.swift`, coupled to in-repo `Tool`/`Value`/`Ontology`/`JSONSchema` types. Only 9 of our 23 ops are covered. **Strategy: iMCP is reference-only.** We clone it locally to read, but we write EventKit/Contacts calls directly in `Sources/AppleHelper/`. iMCP is credited in NOTICE.md. Phase 0 R2 findings file has the op-coverage matrix.
- **R3 — TCC behavior (desk-research only, BLOCKED on empirical).**
  - Display string in TCC dialog: `CFBundleDisplayName` → `CFBundleName` → filename fallback (working theory).
  - Re-prompts on ad-hoc-signed binary hash change: **likely YES**, unavoidable for ad-hoc signing. Document as friction.
  - Automation TCC attributes to responsible (parent) process. Different host apps (Terminal, iTerm, YouCoded Electron) get **separate grants**.
  - **Cross-repo implication:** YouCoded desktop Electron app's Info.plist must carry `NSAppleEventsUsageDescription` + usage-descriptions for Calendar/Reminders/Contacts — see **Task 28b** in the plan.
- **R4 — Dhravya AppleScript is in TypeScript, not `.applescript` files.** We extract script bodies from `utils/notes.ts` + `utils/mail.ts`. Upstream SHA: `08e2c53`. Upstream list-returning paths return `[]` because `run-applescript` can't parse AppleScript record lists — **we rewrite list/search in JXA** (JavaScript for Automation) which emits real JSON via `JSON.stringify`.
- **R5 — macOS 14 floor holds.** No `@available` above 14 in iMCP services; EventKit's `requestFullAccessToEvents` is macOS 14. Clean.
- **R6 — Swift toolchain + universal binary confirmed.**
  - macos-14 GitHub Actions runner: Swift 5.10 (default Xcode 15.4) or 6.0 (Xcode 16.2 available). `// swift-tools-version:5.9` builds fine.
  - `swift build -c release --arch arm64 --arch x86_64` produces **single fat Mach-O** in one command (not a matrix + lipo merge).
  - **Output path:** `.build/apple/Products/Release/<product>` — NOT `.build/release/`. Easy to miss.
  - **Deprecation watch:** macos-14 runner begins deprecation 2026-07-06, fully removed 2026-11-02. Migrate CI to macos-15 before then.
- **R7 — osascript error codes (-1743 Automation denial, -1728 not-found) are stable on macOS 14/15.** Better Mail first-run probe: `tell application "Mail" to count every account` returns 0 instantly when unconfigured, avoiding the hanging `count messages of inbox` path.
- **R8 — iCloud placeholder detection on Sonoma+ needs TWO signals:**
  - Legacy `.<name>.icloud` dot-prefix stubs (pre-Sonoma filesystems, still possible on migrated data)
  - **APFS dataless files** (Sonoma+ default): filename unchanged, `stat` reports full "would-be" size, detect via `SF_DATALESS` flag (`0x40000000`) in `st_flags`. Use `stat -f%Xf <path>` to get flags.
  - **Reading a dataless file triggers synchronous iCloud materialization** — can stall on slow networks. Wrapper rejects with `UNAVAILABLE` rather than trying.
  - `brctl` is undocumented Apple-internal, don't depend on it.
- **R9 — Contacts framework grant and AppleScript Contacts grant are independent** TCC services (`kTCCServiceContacts` vs `kTCCServiceAppleEvents`). Informational; v1 only uses the framework path.

## The 30-task plan at a glance

Phase 0 (✅ DONE): dispatch 9 parallel research subagents, commit findings.

**Phase 1 — Swift helper repo `itsdestin/apple-helper`** (Tasks 1–10)
- T1 create repo, local clone, README, .gitignore
- T2 Package.swift + CLI skeleton (ArgumentParser) + Info.plist with usage-descriptions
- T3 JSON + error envelope + unit tests
- T4 clone iMCP locally as reference + write NOTICE.md (MIT) + VENDORED.md scaffold
- T5 Calendar ops (8) written directly on EventKit
- T6 Reminders ops (7) written directly on EventKit (needs async→sync bridging via semaphore)
- T7 Contacts ops (8) on Contacts framework
- T8 `--request-permissions` serial dialog flow
- T9 CI workflow (universal build + ad-hoc sign + SHA + auto-PR to wecoded-marketplace)
- T10 tag `apple-helper-v0.1.0`

**Phase 2 — Plugin tree `wecoded-marketplace/apple-services/`** (Tasks 11–25b)
- T11 worktree + scaffold plugin dir
- T12 plugin.json with `platforms: ["macos"]`
- T13 Notes AppleScript/JXA (7 files, snake_case to match op names)
- T14 Mail AppleScript/JXA (7 files including mark_read + mark_unread)
- T15 `apple-wrapper.sh` (dispatches helper / osascript / filesystem; SF_DATALESS detection for iCloud)
- T16 setup command steps 1–3 (platform + helper install + iCloud check)
- T17 setup steps 4–5 (EventKit/Contacts grants + Automation grants)
- T18 setup steps 6–7 (smoke probes + summary)
- T19 6 umbrella SKILL.md files
- T20 per-op SKILLs for calendar/reminders/contacts
- T21 per-op SKILLs for notes/mail
- T22 VENDORED.md + NOTICE.md + permissions-walkthrough.md
- T23 `.dev/DEV-VERIFICATION.md` human checklist
- T24 marketplace registry entries
- T25 CI validation updates
- T25b cross-reference youcoded-inbox providers

**Phase 3 — Release** (Tasks 26–29)
- T26 push feature branch
- T27 merge Phase 1 vendor PR (apple-helper CI opens it after T10)
- T28 human DEV-VERIFICATION pass (requires real Mac 14+, ~3 hrs)
- T28b cross-repo PR against `youcoded/desktop/` adding Info.plist usage-description keys
- T29 tag `apple-services-v0.1.0` + open plugin PR + merge + cleanup

## Next action: dispatch Task 1

**Task 1 summary:** Create the `itsdestin/apple-helper` GitHub repo, clone it locally outside `youcoded-dev`, add `.gitignore` + `README.md`, initial commit.

**Full Task 1 text is in the plan** at `docs/superpowers/plans/2026-04-17-apple-services-implementation.md` under `### Task 1: Create repo + local workspace`.

**Dispatch pattern (per subagent-driven-development skill):**

1. Read the full Task 1 text from the plan (don't summarize — give the subagent the complete text verbatim).
2. Dispatch an implementer subagent with:
   - Task 1 full text
   - Scene-setting: "You're implementing Task 1 of the Apple Services plan. Context: see docs/superpowers/plans/2026-04-17-apple-services-handoff.md. Work in a new local clone at `C:\Users\desti\apple-helper` (outside youcoded-dev). Don't touch anything in youcoded-dev."
   - Acceptance: repo exists on GitHub, local clone has README + .gitignore committed + pushed.
3. When implementer returns `DONE`, dispatch a **spec-compliance reviewer subagent** (uses `./spec-reviewer-prompt.md` from the skill) with the same Task 1 text.
4. If spec reviewer approves, dispatch a **code-quality reviewer subagent**.
5. If code reviewer approves, mark Task 1 complete and proceed to Task 2.
6. Any reviewer issues → implementer fixes → re-review loop until clean.

Tasks 1–10 are mostly mechanical (Package.swift, Swift CLI boilerplate, JSON encoding). Suitable for Haiku/Sonnet-class implementers. Task 4 (clone iMCP + NOTICE.md) and Task 9 (CI workflow) touch external services — prefer Sonnet.

Tasks 5–7 (EventKit + Contacts ops) need **macOS host** for smoke-testing (steps 3–4 of each). If the implementer is running without a Mac, they must mark those steps BLOCKED and note that human + Mac verification is required before merging.

## Known caveats / things to watch

1. **Git line-ending warnings.** Windows repo; `core.autocrlf` is on. You'll see `LF will be replaced by CRLF` warnings during commits. Harmless.
2. **Edit-tool paths.** When editing files, absolute paths resolve to the main workspace `C:\Users\desti\youcoded-dev\...`, not the worktree at `.worktrees/apple-services/`. If edits need to land on the feature branch, either (a) commit them in the main workspace and rebase the feature branch, or (b) use the full worktree path. Last session hit this — the spec+plan revisions landed on master via main-workspace paths, and the feature branch was rebased onto master to pick them up.
3. **Two repos, two Git identities.** `itsdestin/apple-helper` is brand new. First push requires the repo to exist (Task 1 Step 1 creates it via `gh repo create`).
4. **TCC state between smoke tests.** If running `apple-helper calendar list_calendars` during dev, macOS caches TCC decisions. To redo fresh-grant tests: `tccutil reset All` (or more targeted: `tccutil reset Calendar`).
5. **Sync concurrency.** YouCoded-dev has `write-guard.sh` hook that blocks writes if another active Claude session is mid-edit. If blocked, check `~/.claude/plugins/youcoded-core/.write-registry.json` or wait for the other session.
6. **Don't commit to master on non-trivial changes.** This workstream uses `feature/apple-services-workstream` as the integration branch. Phase 1 Swift-helper work happens in a separate local clone and has its own branch.
7. **Cross-repo Info.plist (R3 finding).** Task 28b flags a separate PR needed against `youcoded/desktop/` for the Electron bundle's Info.plist. Without those keys, Step 5 Automation dialogs on macOS will show empty descriptions and users may deny. Ship that PR before or alongside the apple-services plugin release.
8. **macos-14 runner deprecation.** GitHub's `macos-14` image begins deprecation 2026-07-06. CI will start printing warnings then. Schedule a migration to `macos-15` as a follow-up ticket.

## Key paths reference

```
# Docs + plan (youcoded-dev, committed)
docs/superpowers/specs/2026-04-17-apple-services-design.md
docs/superpowers/plans/2026-04-17-apple-services-implementation.md
docs/superpowers/plans/research/2026-04-17-apple-*.md  (9 findings files)
docs/superpowers/plans/2026-04-17-apple-services-handoff.md  (this file)

# Worktree (feature branch)
.worktrees/apple-services/  → branch feature/apple-services-workstream

# Phase 1 (will be created)
C:\Users\desti\apple-helper\  (new sibling repo, outside youcoded-dev)
~/reference/iMCP/             (reference clone, read-only, outside workspace)

# Phase 2 (will be created)
wecoded-marketplace/apple-services/  (new plugin dir, under existing repo)

# Install-time (end user, created by /apple-services-setup)
~/.apple-services/bin/apple-helper  (stable path for TCC persistence)
```

## If you need to verify something before proceeding

- **Is the plan current?** `git log --oneline docs/superpowers/plans/2026-04-17-apple-services-implementation.md` — latest commit should be `630ee96 docs(apple-services): revise spec + plan per Phase 0 findings`.
- **Are findings committed?** `git log --oneline docs/superpowers/plans/research/2026-04-17-apple-*.md` — latest should be `ec6d51c research: Phase 0 findings for apple-services`.
- **Which branch am I on?** `git -C .worktrees/apple-services branch --show-current` → `feature/apple-services-workstream`.
- **Is there any uncommitted apple-services work?** `git status --short` should not mention `apple-services` files unless you're mid-task.

## Handoff checklist (before dispatching the next implementer)

- [ ] CLAUDE.md read (auto-loaded; verify by content)
- [ ] Spec skimmed at least through the Architecture section
- [ ] Plan's Prerequisites + "Phase 0 findings that reshape this plan" sections read in full
- [ ] The specific task's full text read verbatim (not summarized) before dispatching
- [ ] If the task is macOS-dependent (Tasks 5/6/7 smoke steps, Task 10, Phase 3 verification), confirm implementer has Mac access or mark BLOCKED
- [ ] Subagent-driven-development skill invoked — fresh subagent per task, two-stage review after each

---

*This handoff is durable context. If you're continuing implementation, paste it (or reference it by path) at the start of the new session so the model has full context without re-deriving it.*
