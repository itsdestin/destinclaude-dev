# Remaining Marketplace Bundles — Session Handoff

**Created:** 2026-04-17
**Purpose:** Enable fresh Claude Code sessions to pick up any of the 8 remaining marketplace bundle designs without re-deriving the overall strategy. Each bundle will go through its own full brainstorming → spec → plan → execute cycle, using patterns established by Google Services.

---

## What already happened (required reading before starting any bundle)

The original monolithic plan at `docs/plans/marketplace-integrations-v2.md` was evaluated and decomposed into 9 per-bundle specs. Google Services shipped first and established the patterns.

**Core decision:** Landing page keeps all 18 integration chips for marketing breadth. Marketplace collapses them into 9 installable bundles grouped by user mental model and shared backing tech.

**Required reading (in order):**
1. `docs/superpowers/specs/2026-04-16-google-services-design.md` — the template spec. Read the Architecture, Per-integration detail, Auto-reauth flow, and Migration sections carefully.
2. `docs/superpowers/plans/2026-04-16-google-services-implementation.md` — the template plan. Read Phase 0 research structure, Phases 1-5 task shapes, and the Self-review at the end.
3. `docs/superpowers/plans/research/` — three research-findings files. Shows the docs-only research approach (no empirical observation when time-gated).
4. `docs/PITFALLS.md` — Plugin Installation & Claude Code Registries section (the four-registry pattern).

---

## Bundle status

| Bundle | Status | Complexity | Priority signal |
|---|---|---|---|
| Google Services | ✅ Shipped (23 commits on `feat/google-services`, awaiting Phase 4 manual verification + Phase 6 merge) | HIGH | — |
| iMessage | Pending | LOW | Easy win; Anthropic plugin already exists |
| Chrome | Pending | LOW | MCP already shipped; thin setup wrapper |
| GitHub | Pending | LOW | MCP already shipped; thin setup wrapper |
| Todoist | Pending | LOW | MCP already shipped; thin setup wrapper |
| Google Messages | Pending | MEDIUM | mautrix-gmessages binary already works |
| Windows Control | Pending | MEDIUM | MCP works; repackaging + recipes |
| macOS Control | Pending | HIGH | Green-field recipe library |
| Apple Services | Pending | HIGHEST | Research gates (TCC attribution, Swift CI) |

**Recommended order for next sessions:** iMessage → Chrome → GitHub → Todoist (banking easy wins to establish pattern), then Google Messages → macOS Control, then Windows Control, then Apple Services (hardest research last).

---

## Established patterns (reuse across all bundles)

From Google Services. These are load-bearing — do not deviate without explicit reason:

### Bundle structure

```
wecoded-marketplace/<bundle-name>/
  plugin.json
  commands/
    <bundle-name>-setup.md
  skills/
    <integration-1>/SKILL.md      # one sibling skill per integration, tight matcher descriptions
    <integration-2>/SKILL.md
    ...
  setup/
    install-*.sh                   # platform-detection installers for helper tools
    *.sh                           # other setup scripts
  lib/
    <bundle>-wrapper.sh            # shared command-forwarder if skills share backing (e.g. gws_run)
  docs/
    DEV-VERIFICATION.md            # internal pre-ship checklist, not shipped to users
```

### Principles

- **One bundle = one plugin = one setup command = N sibling skills** (one per integration chip it covers). Umbrella skills rejected; each integration gets its own focused SKILL.md so Claude's matcher routes accurately.
- **User-facing language policy:** every string the user reads is plain language. No "CLI," "API," "OAuth," "scope," etc. unless the user sees it on a Google/Apple/Microsoft page we can't control — in which case pre-frame what they're about to see.
- **Setup command = markdown slash command**, not a skill. It runs linearly, has clear step blocks, aborts on error, is idempotent on re-run.
- **Dev-time vs shipped tests:** dev-time comprehensive round-trip checklist lives in `docs/DEV-VERIFICATION.md` (not shipped, run before ship). Shipped behavior includes a read-only probe per integration inside the setup command — proves auth worked, does not mutate state.
- **Skills use a shared wrapper**, never invoke backing tech directly. Wrapper owns auth-error detection + uniform error messaging.
- **Auto-reauth or equivalent recovery:** where backing tech has token lifecycle (e.g. OAuth), the wrapper exits code 2 + emits stable `AUTH_EXPIRED:<service>` stderr marker, and a uniform "## Handling auth expiry" section in every SKILL.md tells Claude how to recover. The user never runs a reauth command.
- **Clean cutover migration:** when a new bundle retires existing artifacts, delete/edit them in the same PR that ships the new bundle. Keep a user-machine migration helper (`migrate-legacy.sh`) for already-installed state.
- **Four-registry pattern for marketplace:** any time you add/remove a plugin, check `index.json`, `marketplace.json`, `skills/index.json`, and `featured.json` — all four can have independent entries. Also watch for `overrides/<plugin>.json`. Don't rely on the task's literal file list; grep first.

### Research gates

- Before writing implementation, enumerate open questions. Document each with: question, how to resolve via docs, fallback plan if unfavorable.
- Resolve research in parallel subagents (general-purpose). Each produces a findings file under `docs/superpowers/plans/research/`.
- Explicitly skip empirical waits over 1 hour (e.g. 10-day token observation). Doc-based research is sufficient for v1.
- Apply research outcomes to spec + plan before implementation begins.

### Subagent-driven execution

- Batch by phase, one subagent per phase, for mechanical work (transcribe code from plan into files, commit one task at a time).
- Keep Phase 4 (verification) for the human — round-trip tests and auto-reauth E2E require real accounts + credential interaction no subagent can drive.
- Always re-verify subagent work at cross-file boundaries (e.g. parallel registries).

---

## Per-bundle briefings

Each briefing is a self-contained context dump a fresh session can paste into its own context. Includes: scope, current state, options previously considered, known research items, existing artifacts to migrate.

---

### 1. iMessage

**Landing-page chips:** iMessage (just the one).

**Current state:** The Anthropic official iMessage plugin is **already present** in our marketplace at `wecoded-marketplace/index.json` with `id: "imessage"`, `sourceMarketplace: "anthropic"`, `sourceRef: "./external_plugins/imessage"`. Directory: `wecoded-marketplace/external_plugins/imessage/`.

**How it works** (from the Anthropic plugin): polls `~/Library/Messages/chat.db` once per second for new messages (watermark-based, no replay on restart); sends via `osascript` to Messages.app. Pure SQLite + AppleScript, no external services, no background server.

**Requirements:** macOS. Full Disk Access (to read chat.db) + Automation permission (for `osascript` sends).

**Work needed (the whole bundle):**
- **Do NOT reimplement.** Use the existing Anthropic plugin as-is.
- Write `/imessage-setup` slash command that walks users through:
  1. Detect macOS + Messages.app signed-in state
  2. Full Disk Access grant (screenshot-heavy walkthrough — System Settings → Privacy & Security → Full Disk Access)
  3. Automation permission (triggered by first `osascript` call — pre-frame the OS prompt)
  4. Smoke test: send iMessage to user's own number, poll chat.db, confirm roundtrip
- Possibly also: a thin `SKILL.md` that points Claude at the existing plugin's MCP tool surface. Check what's in `external_plugins/imessage/` to see if it already ships a usable skill description.

**Relationship to other bundles:** None. iMessage stands alone.

**Simplest of all bundles — mostly UX copy + permission walkthrough around an existing plugin.**

---

### 2. Chrome

**Landing-page chips:** Chrome browser automation.

**Current state:** `chrome-devtools-mcp` is already shipped in the marketplace (check `wecoded-marketplace/index.json` for the exact entry). Works today.

**How it works:** Chrome DevTools Protocol over MCP — lets Claude open URLs, read page content, click, type, capture screenshots, execute JS in-page.

**Requirements:** Chrome installed. DevTools Protocol enabled (Chrome must be launched with `--remote-debugging-port=9222` or equivalent).

**Work needed:**
- Write `/chrome-setup` slash command:
  1. Detect Chrome install
  2. Verify `chrome-devtools-mcp` plugin is enabled in `~/.claude/settings.json`
  3. Walk user through enabling DevTools Protocol (may involve launching Chrome with a flag, or a Chrome extension, depending on the MCP's approach)
  4. Smoke test: open `about:blank`, navigate to a URL, confirm page content readback
- Plugin itself already exists; this is a setup-command-only bundle.

**Research items:** None major. Check current `chrome-devtools-mcp` docs for the exact DevTools-enable mechanism.

**Thin bundle — mostly a setup wrapper.**

---

### 3. GitHub

**Landing-page chips:** GitHub.

**Current state:** GitHub's official MCP is present in our marketplace as an Anthropic-sourced plugin. Works today via `gh` auth.

**How it works:** GitHub MCP wraps the GitHub API; `gh auth login` handles OAuth.

**Work needed:**
- Write `/github-setup` slash command:
  1. Detect `gh` CLI install (install via `brew install gh` / `winget install GitHub.cli` / `apt install gh` if missing)
  2. `gh auth login` — browser OAuth
  3. Verify MCP plugin is enabled in settings
  4. Smoke test: `gh api user` returns the authenticated user's login
- Plugin already exists; this is a setup-command wrapper.

**Research items:** Confirm the GitHub MCP's exact scope list and whether setup needs to pre-request specific scopes.

**Thin bundle.**

---

### 4. Todoist

**Landing-page chips:** Todoist.

**Current state:** Todoist skill already in the marketplace. Listed in `youcoded-core/mcp-manifest.json` with `auto: false` — requires OAuth setup, not auto-registered.

**How it works:** Todoist MCP server authenticated via API token (not full OAuth — API tokens are per-user, generated at https://todoist.com/app/settings/integrations/developer).

**Work needed:**
- Write `/todoist-setup` slash command:
  1. Prompt user to visit https://todoist.com/app/settings/integrations/developer, create an API token, paste it
  2. Store securely — where? Options: OS keyring (preferred), encrypted file at `$HOME/.youcoded/todoist/token`, or `settings.json` with an env-var reference. Research what the existing Todoist MCP expects.
  3. Write the token into the MCP's expected location
  4. Verify MCP enabled in settings
  5. Smoke test: fetch inbox project, confirm 200 response
- Skill already exists; this is setup-only.

**Research items:** Confirm where the existing Todoist MCP reads its token (env var? config file? keyring?). If it's env-var only, setup needs to write to shell profile or `settings.json`'s env block.

**Thin bundle.**

---

### 5. Google Messages

**Landing-page chips:** Google Messages (RCS/SMS via Messages for Web).

**Current state:** `wecoded-marketplace/youcoded-messaging/gmessages/` contains the `mautrix-gmessages` Go binary (still present after Phase 5 only deleted the `imessages/` subdir). The plugin itself is still registered as `youcoded-messaging` — scope is now Google Messages only.

**How it works:** `mautrix-gmessages` is a Matrix bridge that connects to Messages for Web via QR-code pairing. User scans a QR code with their phone's Messages app to authorize; the Go binary polls the web session for new messages and sends via the same channel.

**Requirements:** Phone running Google Messages app, QR-code scan during pairing, ongoing internet connection between the binary and Google's Messages for Web backend.

**Work needed:**
- Decide naming: rename `youcoded-messaging` plugin to `google-messages` (cleaner now that iMessage is gone), OR keep the name and scope the description to "Google Messages only" (less work, slight confusion).
- Write `/google-messages-setup` slash command:
  1. Install `mautrix-gmessages` binary (already bundled in the plugin, or download from upstream?)
  2. Walk user through QR-code pairing — this is UX-heavy: render the QR code (the binary emits it), user scans with their phone, confirm pairing
  3. Configure Matrix bridge or whatever transport sits between the binary and Claude's skill
  4. Smoke test: send RCS to user's own number, poll for it on the other side
- Update the existing `youcoded-messaging` plugin scope (description, plugin.json, index.json entries)
- Possibly: migrate the `gmessages/` subdir out of `youcoded-messaging/` into its own plugin dir for clarity

**Research items:**
- What does the current `mautrix-gmessages` setup look like in `youcoded-messaging/`? Is there existing setup code? A Matrix homeserver required, or is it self-contained?
- QR-code UX in a terminal — does the binary emit text-renderable QR, or does it need a browser?
- What happens when the phone pairing drops (battery dead, app uninstalled)? Recovery flow.

**Migration:** the plugin rename/repackage is non-trivial; treat like Google Services' clean-cutover migration step.

---

### 6. Windows Control

**Landing-page chips:** Windows desktop automation.

**Current state:** `mcp__windows-control` registered in `youcoded-core/mcp-manifest.json` with `platform: "windows"`, `command: "uvx"`, `args: ["windows-mcp"]`, `auto: true`. Bundled in the core runtime, NOT a marketplace plugin today. Works.

**How it works:** `windows-mcp` (via `uvx`) exposes Windows desktop operations — app launch, click, type, screenshot, PowerShell execution, window management.

**Work needed:**
- **Move MCP from core runtime → marketplace plugin.** Unregister from `youcoded-core/mcp-manifest.json`; register as a bundled MCP inside a new `windows-control` marketplace plugin (analogous to how other plugins declare their own MCP servers).
- Write `/windows-setup` slash command:
  1. Detect Windows + `uvx` (install Python + pip if needed? `uvx` comes with `uv`)
  2. Verify `windows-mcp` installable and running
  3. Verify plugin enabled in `settings.json`
  4. Smoke test: screenshot active window, list open window titles, open Notepad and type test string
- **Add Windows app recipe library**, analogous to what macOS Control will have:
  - PowerShell-based app automation recipes (Spotify for Windows, File Explorer, Excel, etc.)
  - SendKeys patterns for app-specific flows
  - Tier 1 (ship), Tier 2 (follow-up), Tier 3 (user-extensible)

**Research items:**
- How do other marketplace plugins bundle an MCP server today? Check for patterns in existing plugins.
- Does `uvx` work consistently across Windows installs, or are there PATH issues with non-standard Python setups?

**Relationship to other bundles:** Analogous to macOS Control — same recipe library approach, different platform.

**Lower priority than macOS Control because the MCP already works; this is primarily repackaging.**

---

### 7. macOS Control

**Landing-page chips:** Safari + Spotify + Apple Music + Finder + Terminal + Zoom + MS Office (Word/Excel/PowerPoint) + potentially many more.

**Current state:** **Nothing implemented.** Green-field.

**Architecture from the original v2 plan (reuse as starting point):**

**Primitives:**
- `osascript` (built-in macOS) — AppleScript runner for semantic app control, menu navigation, app-specific dictionaries
- `cliclick` (install via `brew install cliclick`) — raw cursor/mouse coords, drags, keystrokes; for where System Events is flaky
- `screencapture` (built-in) — screenshots, window capture, region capture, interactive
- `shortcuts` CLI (built-in, macOS 12+) — invoke the user's own Shortcuts.app automations

**Recipe library structure:**
```
macos-control/
  SKILL.md                            # one umbrella skill; frontmatter enumerates every supported app by name
  lib/
    applescript-runner.sh             # osascript wrapper with structured JSON output
    cliclick-helper.sh
    screencapture-helper.sh
  recipes/
    spotify.md                        # read on-demand when user asks about Spotify
    apple-music.md
    safari.md
    finder.md
    terminal.md
    system-events.md
    zoom.md
    microsoft-office.md
    _template.md                      # for user-added recipes
  setup/
    install.sh                        # brew install cliclick; verify built-ins
    permissions.md                    # Automation + Accessibility permission walkthrough
```

**SKILL.md frontmatter enumerates every supported app by name** (Spotify, Apple Music, Safari, Finder, Terminal, iTerm2, Zoom, Word, Excel, PowerPoint, etc.) so Claude's skill matcher activates on utterances like "pause Spotify" or "open this folder in Finder." Recipe bodies are read on-demand after the skill activates — not loaded upfront.

**Recipe tiers:**
- **Tier 1 (ship):** Spotify, Apple Music, Safari, Finder, Terminal/iTerm2, System Events (global keystrokes, app launch/quit/switch), Zoom, MS Office (Word/Excel/PowerPoint)
- **Tier 2 (follow-up):** Slack, Discord, Obsidian, Notion, VS Code, Figma — mostly System Events or URL schemes
- **Tier 3 (user-extensible):** document the recipe format; users drop their own `recipes/<app>.md`

**Requirements:** macOS. Accessibility permission (for `cliclick`). Automation permission per app (triggered by first `osascript` call). macOS ≥ 12 for `shortcuts` CLI.

**Work needed:** substantial — this is the biggest v1 bundle after Google Services. Design each recipe, calibrate the SKILL.md frontmatter description so Claude picks it only when the user explicitly names a supported app.

**Research items:**
- What does a good structured JSON output look like from `osascript` for Claude to parse?
- How to handle the per-app Automation permission cascade without overwhelming the user on first use?
- Does the `shortcuts` CLI expose a runtime inventory of the user's Shortcuts, so the recipe library could dynamically extend?

**Relationship to other bundles:** Safari chip on landing page routes here (NOT to a dedicated Safari bundle).

**Note:** does NOT cover iCloud Drive file operations (that's Apple Services' job if it happens at all).

---

### 8. Apple Services

**Landing-page chips:** iCloud Drive + Apple Notes + Apple Reminders + Apple Calendar + Apple Mail + Apple Contacts (six chips).

**Current state:** **Nothing implemented.** Green-field and the highest technical risk of any bundle.

**Architecture from the v2 plan (decisions to revisit in this bundle's own brainstorming):**

**Primary backing:** native EventKit (for Calendar/Reminders/Contacts) + AppleScript (for Notes/Mail) + iCloud Drive (approach TBD — possibly `brctl` or Files.app integration).

**Phased approach:**

**Phase 1 — ship on a third-party EventKit MCP.** Candidates previously considered:
- [PsychQuant/che-ical-mcp](https://github.com/kiki830621/che-ical-mcp) — 24 tools, iCloud + Google + Exchange, active. Leading candidate.
- [FradSer/mcp-server-apple-events](https://github.com/FradSer/mcp-server-apple-events) — Calendar + Reminders, narrower
- [Krishna-Desiraju/apple-reminders-swift-mcp-server](https://github.com/Krishna-Desiraju/apple-reminders-swift-mcp-server) — Reminders-only but full CRUD

**Phase 2 — YouCoded-native EventKit helper.** A small Swift binary inside `YouCoded.app/Contents/Resources/helpers/eventkit-helper`, signed with YouCoded's Developer ID, notarized as part of the existing release. Claude Code spawns it as a stdio MCP server.

**Rejected options:**
- **iMCP** — requires a GUI app to be running, macOS 15.3+ floor, third-party maintainer dependency. Rejected for v1.
- **supermemoryai/apple-mcp** — archived January 2026, no successor.

**Notes + Mail: AppleScript** in both phases. `osascript` wrappers, ~100 lines each. Notes requires Automation permission per app. Mail may additionally need Full Disk Access for some operations.

**Requirements:**
- macOS ≥ 13 (EventKit base)
- Phase 1: whatever the chosen 3rd-party MCP requires (typically Swift 5.9+ / Xcode CLI tools, or pre-built binary)
- Phase 2: nothing user-facing beyond the YouCoded installer

**Research items (ALL blocking Phase 2, must resolve before implementation):**

1. **TCC attribution test.** Does a Swift helper bundled inside `YouCoded.app/Contents/Resources/` and signed with YouCoded's Developer ID inherit YouCoded's TCC identity? Test is ~30 lines of Swift calling `requestFullAccessToEvents`, bundled + spawned through the production path (Electron main → Claude Code → helper). If prompt says "Allow YouCoded" → clean UX win. If prompt says the binary name → works, less clean.
2. **Does YouCoded's current CI build Swift?** Checked during Google Services Phase 0 research: **NO.** Adding a Swift build step to the macOS release pipeline is 1–3 days depending on what exists today. Required before Phase 2 commitment.
3. **Phase 1 vendor choice.** Which of the 3rd-party EventKit MCPs to adopt: active maintenance, distribution model (pre-built binary vs source build), scope coverage.

**Migration:** none — nothing Apple-adjacent currently ships.

**Highest complexity bundle. Do this LAST.** The research gates alone are multi-day.

---

## Session kickoff prompt template

Paste this into a fresh Claude Code session to begin any remaining bundle. Replace `{BUNDLE}` with the bundle name.

```
I'm starting the next YouCoded marketplace bundle: {BUNDLE}.

Context lives in the workspace at C:/Users/desti/youcoded-dev. Required reading, in order:

1. docs/superpowers/plans/2026-04-17-remaining-bundles-handoff.md
   — overall decomposition strategy + per-bundle briefings. Find the briefing for {BUNDLE}.

2. docs/superpowers/specs/2026-04-16-google-services-design.md
   — the template spec. Architecture, Per-integration detail, Auto-reauth flow, Migration sections show the patterns.

3. docs/superpowers/plans/2026-04-16-google-services-implementation.md
   — the template plan. Phase 0 research structure, Phases 1-5 task shapes.

4. docs/PITFALLS.md — especially "Plugin Installation & Claude Code Registries" and "Working With Destin".

After reading, start by invoking the superpowers:brainstorming skill. Walk me through the full brainstorming → design → spec flow for {BUNDLE}, reusing patterns from Google Services where they apply. Do NOT re-derive architectural decisions that already have cross-bundle answers in the handoff doc (bundle structure, user-facing language policy, test distinction, wrapper pattern, four-registry pattern, clean cutover migration).

When we have a spec, commit it to docs/superpowers/specs/YYYY-MM-DD-{bundle}-design.md.
Then transition to superpowers:writing-plans for the implementation plan.
Then superpowers:subagent-driven-development for execution.

Skip empirical waits > 1 hour — use docs-only research for any time-gated questions.
```

Customize the prompt per bundle — for example, for iMessage add: "*Note: the Anthropic iMessage plugin already exists in our marketplace; this bundle is mostly setup UX + permission walkthroughs, not a reimplementation.*"

---

## Cross-bundle concerns (park now, revisit after 2-3 bundles ship)

These might emerge as shared infrastructure worth extracting:

- **Shared setup-command framework** — after 2-3 setup commands exist, common patterns (platform detect, dep install, permission walkthrough, smoke test, idempotency) may warrant extraction into a shared helper library. Don't extract prematurely.
- **Shared auto-reauth pattern** — if non-Google bundles also have OAuth refresh cycles (Todoist? GitHub?), consider whether `AUTH_EXPIRED:<service>` convention generalizes or whether each bundle's reauth UX is idiosyncratic enough to stay bespoke.
- **Shared recipe format for *-Control bundles** — macOS Control and Windows Control both want per-app recipe libraries. After both exist, consider whether recipe format (YAML? Markdown with frontmatter?) can converge.
- **Integration between bundles** — e.g., a prompt like "email me the budget spreadsheet" touches Gmail + Drive + Sheets + possibly a messaging bundle. Skill matcher routes ONE primary + zero or more tool-use secondaries; confirm this holds across bundles.

---

## Out-of-scope for v1 (all bundles)

Documented here so future sessions don't accidentally re-open them:

- **Verified Google / Apple / Microsoft apps** — eliminates token-lifecycle friction but requires weeks of vendor review and ongoing ownership. Revisit once v1 has measurable usage.
- **Shared Drive / Workspace tenant-admin flows** — personal accounts only.
- **Cross-account flows** (e.g., multiple Google accounts, multiple Apple IDs) — single-account v1.
- **Linux Control** — no Linux desktop automation bundle yet.

---

## Maintenance

- When a bundle ships, update its row in the "Bundle status" table above.
- When a cross-bundle pattern gets extracted, document the shared helper here and note which bundles adopted it.
- When a new integration chip shows up on the landing page, decide which bundle owns it and add to that bundle's briefing.
