# Development Settings Panel

**Date:** 2026-04-21
**Status:** Design — pending implementation plan
**Scope:** YouCoded app (Desktop + Android). No changes to `youcoded-core`, `wecoded-themes`, `wecoded-marketplace`, or `youcoded-admin`.

## Summary

Add a **Development** entry to the Settings → Other section that opens a popup with three options:

1. **Report a Bug or Request a Feature** — capture description, summarize via Anthropic API, ship to GitHub via `gh issue create` (or browser-prefill fallback). Includes an alternate path that clones `youcoded-dev`, registers it as a project folder, and opens a new Claude session pre-loaded to investigate.
2. **Contribute to YouCoded** — explain `youcoded-dev`, install it, register it, optionally open a session in it.
3. **Known Issues and Planned Features** — open `https://github.com/itsdestin/youcoded/issues` in the browser.

The "let Claude fix it" path warns prominently about Claude usage cost.

## Goals & non-goals

**Goals:**
- Friction-free bug/feature reporting from inside the app
- Discoverable on-ramp to contributing without a dedicated docs page
- Single description capture — typed once, routed to either GitHub or a new session
- Cross-platform parity (Desktop + Android), per the shared-React-UI invariant

**Non-goals:**
- No new GitHub auth flow — reuse `gh` CLI auth where present, browser fallback otherwise
- No GitHub Projects / kanban integration
- No filtered "Known Issues" vs "Planned Features" views — single issues page in v1
- No tier detection ("Pro vs Max" warning is text-only, not gated)
- No remote-browser-aware UI ("workspace will install on your main computer" banner) — deferred

## User flow

### Settings entry

A new row appears in **Settings → Other**, between **Defaults** and **Donate**, in both the Android and Desktop variants of `SettingsPanel.tsx`:

> 🛠 **Development** — Report a bug, contribute, or browse known issues. ›

Same button + 32×20 icon slot + label + sub-label + chevron pattern as the existing Donate / About rows.

### `DevelopmentPopup`

Centered modal (L2 popup layer — `<Scrim layer={2}>` + `<OverlayPanel layer={2}>`). Three rows, same row pattern as the Other-section entries:

1. 🐞 **Report a Bug or Request a Feature** → opens `BugReportPopup`
2. 🤝 **Contribute to YouCoded** → opens `ContributePopup`
3. 📋 **Known Issues and Planned Features** → `window.open('https://github.com/itsdestin/youcoded/issues', '_blank')`, popup closes

### `BugReportPopup` — three-screen state machine

**Screen 1 — Describe.**
- Bug / Feature segmented toggle at top (default: Bug)
- Textarea: "What's happening? (Or what would you like to see?)"
- **Continue** button — disabled until description ≥10 characters

**Screen 2 — Review.** Shown after Continue. Description is preserved if the user navigates back.
- For **Bug:** summary paragraph at top (from Anthropic API). Below: collapsible "Logs to include" section with the redacted, editable log preview. Suspicious strings flagged by the summarizer appear as small ⚠ chips above the log preview, click to scrub.
- For **Feature:** summary only. No logs section.
- Two action buttons:
  - **Submit as GitHub Issue** (primary)
  - **Let Claude Try to Fix It** (Bug) / **Let Claude Try to Build It** (Feature) — secondary, with `⚠ High Claude usage — not recommended for Pro plans` caption underneath
- Small links: *Edit summary*, *Edit description* — both return to Screen 1 with state preserved

**Screen 3 — Result.**
- Submit path: *"Issue created: [#123](url)"*, **Open** + **Done** buttons. URL-fallback path: *"Opening GitHub in your browser…"*, **Done**.
- Claude path: streamed install progress, then *"New session opened in `~/youcoded-dev`."*, **Done**.

### `ContributePopup` — single screen

- Two short paragraphs:
  - What `youcoded-dev` is: workspace scaffold cloning all five sub-repos side by side
  - How to use it: open as a project folder, ask Claude to make changes, push PRs to the relevant **sub-repo** (not the workspace itself)
- Primary button: **Install Workspace** — runs the same install pipeline as the Bug "let Claude fix it" path
- After install: result screen with *"Workspace installed at `~/youcoded-dev`. Added to your project folders. Open it in a new session?"* — **Open in New Session** + **Done**

### Key UX commitments baked into the flow

- Description captured **once** on Screen 1, then routed to either GitHub (issue body) or a new Claude session (input-bar prefill). Never asked twice.
- Summary shown to user before submission so they can correct or rephrase.
- High-usage warning lives next to the relevant button, not as a blocking modal.
- All popups use existing Overlay primitives — no new z-index decisions.
- "Let Claude fix it" prefills the input bar but does **not** auto-send — user hits Enter, keeping them in the loop on cost.

## Submission pipeline (description → GitHub)

### Step A — Capture & log tail

Renderer captures `{ kind: 'bug' | 'feature', description: string }`.
For bugs only, calls new IPC `dev:log-tail` → main process returns the last ~200 lines of `~/.claude/desktop.log` (or `$HOME/.claude/desktop.log` inside Termux on Android), with redaction already applied.

### Step B — Minimal redaction (main process)

Three patterns only:
- User home dir path → `~`
- `gh[opsu]_[A-Za-z0-9]{20,}` → `[REDACTED-GH-TOKEN]`
- `sk-ant-[A-Za-z0-9_-]{20,}` → `[REDACTED-ANTHROPIC-KEY]`

No aggressive token-shape scrubbing — false positives erode trust. The editable preview is the real safety net.

### Step C — Summarize

New IPC `dev:summarize-issue` → main process makes a single Anthropic API call using the user's existing Claude Code OAuth token. Prompt template:

> *You are summarizing a {bug report | feature request} from a YouCoded user for a GitHub issue. The user wrote: «description». {For bugs only:} The last 200 lines of their app log are: «log». Produce: (1) a one-line title (≤80 chars), (2) a one-paragraph summary that captures the user's intent without losing specifics, (3) a `flagged_strings` array listing anything in the log that looks sensitive (paths, IDs, possible secrets) so the user can decide whether to keep them.*

Returns `{ title: string, summary: string, flagged_strings: string[] }`.

If the summarizer fails (no token, API down, rate-limited): fall back gracefully — show the user's raw description in the summary slot with a note *"Summary unavailable — your description will be used as-is."* Submission still works.

### Step D — Build issue body

Renderer assembles the final markdown:

```
{summary}

---
**User description:**
{description}

**Environment:** YouCoded vX.Y.Z · {platform} · {os}

{For bugs only:}
**Logs (last N lines):**
<details><summary>desktop.log</summary>

```
{redacted, possibly user-edited log tail}
```

</details>
```

### Step E — Submit via `gh` (preferred)

New IPC `dev:submit-issue` → main process:

1. `gh auth status` — check authenticated
2. If yes: write body to a temp file, run `gh issue create --repo itsdestin/youcoded --title "{title}" --body-file {tmp} --label {bug|enhancement} --label youcoded-app:reported`, parse issue URL from stdout, return to renderer
3. If `gh` not installed / not authed / fails: fall back to URL prefill

**Android note:** `gh` is in `Bootstrap.kt`'s `corePackages` (always installed). The Bootstrap-built env (`linker64-env.sh` bash wrapper) handles the Go-binary LD_PRELOAD bypass. `~/.netrc` token sync from `gh`'s `hosts.yml` is already wired. So the Android path is identical: try `gh`, fall back to URL prefill.

### Step F — URL-prefill fallback

1. Smart-truncate body: keep summary + description + environment, replace log block with **last 50 lines only** (URL cap ~8KB)
2. Build `https://github.com/itsdestin/youcoded/issues/new?title={enc}&body={enc}&labels={bug|enhancement}`
3. `window.open(url, '_blank')`
4. Show *"Opening GitHub in your browser… review and submit there."* on Screen 3

### GitHub label prerequisites

Labels `bug`, `enhancement`, and `youcoded-app:reported` must exist on `itsdestin/youcoded` before shipping — `gh issue create` errors if the label doesn't exist. One-time manual setup in the repo settings.

## Workspace install + new-session pipeline

Shared by the Bug "Let Claude fix it" path and the Contribute "Install Workspace" path. Driven by IPC `dev:install-workspace` with progress streamed via `dev:install-progress`.

### Pre-flight (main process)

1. **Resolve target path:** Desktop → `path.join(os.homedir(), 'youcoded-dev')`. Android → same shape, using Bootstrap's `$HOME` resolution (Termux env home dir).
2. **Idempotency probe:** if the target dir exists, run `git -C <path> remote get-url origin`:
   - URL matches `*itsdestin/youcoded-dev*` → "already installed" path: skip clone, jump to update step
   - URL exists but doesn't match → fail: *"`~/youcoded-dev` already exists but isn't the YouCoded dev workspace. Move or rename it and try again."* — no destructive action.
   - Dir exists, no `.git` → same fail message.
3. **Verify git is available:** `which git` / `where git`. On Android, git is in `corePackages`. If missing on Desktop: surface install hint, abort.

### Install / update phase

Streamed back to renderer via `dev:install-progress`:

> Cloning workspace…
> Cloning sub-repos (this may take a minute)…
> Setting up…

Concretely:
- **Fresh install:** `git clone --depth 50 https://github.com/itsdestin/youcoded-dev <path>`
- **Update:** `git -C <path> pull --ff-only`
- Always: `bash setup.sh` from inside the workspace. Already idempotent — `git pull` per sub-repo.
- Combined stdout/stderr buffered; only the last few lines stream to the renderer. Full output written to `desktop.log` via existing logger.

**Partial-success handling:** if `setup.sh` fails on one or more sub-repo clones (commonly: GitHub rate limiting), the workspace itself is usable. Proceed with a yellow note: *"Workspace installed, but one or more sub-repos didn't clone. Run `setup.sh` again later to retry."* Better than throwing the install away on transient failure.

### Post-install: register as project folder

Call existing `window.claude.folders.add(<path>)`. Implementation must verify the existing handler is idempotent — if not, wrap in a list-then-add check.

### Spawn new session

Existing `window.claude.session.create({ cwd, model, skipPermissions, ... })` IPC. Defaults pulled from `window.claude.defaults?.get?.()`.

Three call sites, three prompt prefills:

- **Bug → "Let Claude Try to Fix It":**
  > *I just filed (or am about to file) a bug against YouCoded. Here's what I described: «description». Investigate the codebase in this workspace and propose a fix. Read `docs/PITFALLS.md` first, and check both desktop and Android touchpoints if the bug could affect either.*

- **Feature → "Let Claude Try to Build It":**
  > *I want to add a new feature to YouCoded. Here's what I'm asking for: «description». Read `docs/PITFALLS.md`, then use the brainstorming skill to design it before writing code. Both desktop and Android share the React UI — keep that in mind.*

- **Contribute → "Open in New Session":** no prefill.

Prompt prefill mechanism: extend `session.create` to accept `initialInput?: string` that the renderer puts in the input bar after the session is selected. **Verify during planning** whether this hook already exists; if not, this is a small addition to `session-manager.ts` + `InputBar.tsx`.

If `initialInput` extension can't be wired cheaply: graceful fallback is to spawn the session with no prefill and show a one-shot toast *"Paste this into the new session: «description»"* with a Copy button.

### Concurrency guard

Single in-flight flag in `dev-tools.ts`. Second `dev:install-workspace` call while one is running returns *"Install already in progress."*

## Cross-platform parity & files touched

### New IPC message types

Names must match exactly across `preload.ts`, `ipc-handlers.ts`, and `SessionService.kt`.

| Type | Purpose | Direction |
|---|---|---|
| `dev:log-tail` | Last ~200 lines of `desktop.log`, redacted | request/response |
| `dev:summarize-issue` | `{kind, description, log?}` → `{title, summary, flagged_strings[]}` | request/response |
| `dev:submit-issue` | `{title, body, label}` → `{ok, url}` or `{ok: false, fallbackUrl}` | request/response |
| `dev:install-workspace` | Clone-or-update + `setup.sh` + folder registration → `{path, alreadyInstalled}` | request/response |
| `dev:install-progress` | Stream progress lines while install is running | push (main → renderer) |
| `dev:open-session-in` | Create session with `cwd` + optional `initialInput` | request/response |

### Desktop files

- `desktop/src/main/preload.ts` — declare `window.claude.dev.*` (six methods)
- `desktop/src/main/ipc-handlers.ts` — register all six handlers
- `desktop/src/main/dev-tools.ts` *(new)* — log tail + redaction, `gh` wrapper, install pipeline
- `desktop/src/main/dev-summarizer.ts` *(new)* — Anthropic API call, prompt template, response parsing
- `desktop/src/main/session-manager.ts` — extend `session.create` to accept `initialInput?` (only if hook doesn't already exist; verify during planning)
- `desktop/src/renderer/remote-shim.ts` — mirror `window.claude.dev.*` for remote browsers
- `desktop/src/renderer/components/SettingsPanel.tsx` — add Development row in **both** the Android block (~line 1972) **and** the Desktop block (~line 2263)
- `desktop/src/renderer/components/development/DevelopmentPopup.tsx` *(new)*
- `desktop/src/renderer/components/development/BugReportPopup.tsx` *(new)*
- `desktop/src/renderer/components/development/ContributePopup.tsx` *(new)*
- `desktop/src/renderer/components/development/index.ts` *(new, optional)*

### Android files

- `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` — `when` cases in `handleBridgeMessage()` for all six message types. Reuse Bootstrap-built env so `gh`, `git`, `bash` resolve.
- `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/DevTools.kt` *(new)* — Kotlin equivalent of `dev-tools.ts`
- Verify `gh` and `git` are reachable via Bootstrap env without extra wiring (they should be — both in `corePackages`).

### Cross-cutting docs

- `youcoded/docs/cc-dependencies.md` — add entry for `gh` CLI dependency (we now depend on `gh` exit codes / output format)
- `docs/PITFALLS.md` — short entry on dev-tools IPC parity, GitHub label-creation prerequisite, `setup.sh` idempotency assumption

### Files NOT touched

- `~/.claude/plugins/youcoded-core/*` — no plugin/skill involvement
- `wecoded-marketplace`, `wecoded-themes` — unrelated
- `youcoded-admin` — release skill, irrelevant

## Error handling & edge cases

| Scenario | Handling |
|---|---|
| `git clone` fails | Show *"Couldn't reach github.com — check your connection and try again"* with Retry. Full stderr to `desktop.log`. |
| `setup.sh` partial success | Yellow note *"Workspace installed, but one or more sub-repos didn't clone…"* Proceed. |
| Anthropic API failure | Show user's description as-is in summary slot with note. Submission still works. |
| `gh` not installed | Silent fallback to URL prefill. No error UI. |
| `gh auth status` fails | Silent fallback. |
| `gh issue create` fails after auth check passed | Show *"GitHub submission failed — opening browser fallback"*, switch to URL flow. |
| `gh` returns 0 but stdout isn't a URL | Treat as success without specific URL. Show *"Issue submitted to GitHub"*. |
| `desktop.log` missing/unreadable | Empty log section. Bug report still works. |
| Target dir exists, wrong remote | Hard-fail with explicit message. No rename / move / delete. Cancel only. |
| Target dir exists, no `.git` | Same as above. |
| Target dir is a symlink | Resolve symlink first; check resolved path. |
| Double-click install | In-flight flag returns *"Install already in progress"* on second call. |
| `folders.add(path)` already has path | Must be idempotent. Wrap in list-then-add if existing handler isn't. |
| `session.create` fails | Show error with path on install screen. Don't auto-retry. Workspace install itself still succeeded. |
| `initialInput` extension not wired | Toast fallback with Copy button preserves user's prose. |
| Concurrent writes to tracked files | None of our IPCs touch `write-guard.sh` tracked files. No special handling. Documented in spec only. |
| Remote browser user | Submit-issue runs on desktop host (where `gh` lives). Install runs on host. Future work: detect remote and clarify in UI. |

## Testing approach

Existing pattern: Vitest, tests mostly flat in `desktop/tests/`, IPC handlers tested with mocked Electron + `child_process`.

### Unit tests (highest leverage)

`tests/dev-redaction.test.ts`
- Home dir → `~` substitution across all four platform shapes
- `gh[opsu]_…` redaction — all four prefix variants
- `sk-ant-…` redaction
- Multiple secrets per line
- No false positive on a 20-char hex hash that isn't a token
- Idempotent

`tests/dev-issue-body.test.ts`
- Body shape correct for bug + feature
- `<details>` log block only for bug
- Smart-truncate keeps last 50 lines, prepends `… (N earlier lines omitted)`
- Environment line includes platform + version

`tests/dev-url-prefill.test.ts`
- Encoding correct for quotes, newlines, ampersands, unicode
- `labels=` parameter present and correct
- URL stays under 8KB even with worst-case description (hard-cap description in truncate path)

`tests/dev-idempotency.test.ts`
- `git remote get-url origin` parser identifies matching vs non-matching remote
- Handles `.git` suffix, `https://` vs `git@`, trailing slash
- Empty / non-git directory classification

### IPC handler tests

`tests/dev-ipc-handlers.test.ts`
- All six `dev:*` handlers registered
- `dev:log-tail` returns redacted content even when raw log contains secrets
- `dev:submit-issue` falls back to URL when `gh auth status` exits non-zero
- `dev:install-workspace` second-call-while-in-flight returns "already in progress"

### Parity test

Extend existing `tests/ipc-channels.test.ts` to assert all six new `dev:*` types appear in **both** the desktop preload-method list **and** the SessionService Kotlin handler list (parsed from source). Regression net for the parity invariant from PITFALLS.

### Component tests

`tests/development-popup.test.tsx`
- Clicking "Report a Bug or Request a Feature" opens BugReportPopup
- Bug/Feature toggle changes the GitHub label passed to submit
- Continue button disabled below 10 chars, enabled at/above
- Edit-summary link returns to Screen 1 with description preserved

### Out of scope for automated tests

- Live `gh issue create` calls (need a real repo + token; manual smoke instead)
- Live `git clone` (network-dependent; manual smoke)
- Anthropic API summarization output content (mock the API call; assert correct prompt sent + correct shape parsed; quality is a manual eval)

### Manual smoke checklist (executed once before merging)

1. Bug submit, `gh` authed → issue appears with right labels, log block present
2. Bug submit, `gh` un-authed → browser opens with prefilled URL, truncated log
3. Feature submit → label is `enhancement`, no log block
4. "Let Claude fix it" → workspace clones, folder registered (visible in folder picker), session opens with prefilled prompt
5. Re-run "Let Claude fix it" with workspace already there → silent re-use, `setup.sh` re-runs, session opens
6. Existing `~/youcoded-dev` with wrong remote → clear error, no destructive action
7. All flows on Android (Termux env)

## Open items deferred to planning

- Verify whether `session.create` already supports an initial-input prefill mechanism, or whether we need to add `initialInput?` to the IPC + InputBar
- Verify `window.claude.folders.add(path)` is idempotent
- Confirm `gh` on Android works through the Bootstrap env without additional `linker64-env.sh` adjustments (should "just work" — verify)
- Confirm GitHub repo `itsdestin/youcoded` has labels `bug`, `enhancement`, `youcoded-app:reported` — create if not
