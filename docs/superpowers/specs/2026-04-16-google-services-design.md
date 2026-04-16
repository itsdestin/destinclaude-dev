# Google Services Bundle — Design

**Status:** Approved; revised 2026-04-16 post-research. Ready to implement.
**Created:** 2026-04-16
**Owner:** Destin
**Supersedes in scope:** part of `docs/plans/marketplace-integrations-v2.md` (the monolithic cross-bundle plan). The Google portion of that plan is replaced by this document. Other bundles (Apple Services, iMessage, macOS Control, etc.) will each get their own spec.
**Research findings:** [docs/superpowers/plans/research/2026-04-16-refresh-token-findings.md](../plans/research/2026-04-16-refresh-token-findings.md), [oauth-brand-automation.md](../plans/research/2026-04-16-oauth-brand-automation.md), [gws-slides-coverage.md](../plans/research/2026-04-16-gws-slides-coverage.md). Summary under "Research outcomes" below.

---

## Goal

Ship a marketplace plugin named `google-services` that lets a non-technical user install Gmail, Google Drive, Google Docs, Google Sheets, Google Slides, and Google Calendar in a single setup command. After install, the user can ask Claude things like *"send an email to Mom"* or *"find last week's budget spreadsheet"* and the right skill activates.

This is the first of nine per-bundle specs in the marketplace-integrations workstream. It sets patterns (setup command shape, dev-time vs shipped tests, per-integration skill structure, user-facing language policy) the other bundles will reuse.

## Scope

**In scope (v1):** Gmail, Drive, Docs, Sheets, Slides, Calendar.

**Out of scope (v1):**
- Google Contacts — defer to v1.1; not on the landing-page chip list, no urgency.
- Google Messages — separate bundle.
- Google Chat (the Workspace chat app) — not advertised; skip.
- Shared-inbox / team-workspace flows — personal accounts only.

## Foundation

- **`googleworkspace/cli`** (`gws`) — official Google-maintained Rust CLI, Apache 2.0. Skills invoke `gws` subcommands directly via bash; no MCP wrapper. Pinned version in setup script; bumped quarterly.
- **`gcloud`** (Google Cloud SDK CLI) — used only during setup to bootstrap the user's personal GCP project + OAuth credentials. Installed via platform package manager (`brew install --cask google-cloud-sdk`, `winget install Google.CloudSDK`, `apt install google-cloud-sdk`) if missing. NOT bundled — SDK is ~500 MB.

## OAuth strategy

**User-brings-own GCP project with auto-reauth.** Each user creates their own throwaway Google Cloud project during `/google-services-setup`; `gcloud` automates what it can, screenshot-guided Cloud Console steps handle what it can't (see Step 3 below). `gws` manages the OAuth flow against the user's personal credentials. No YouCoded-owned verified app in v1.

Rationale: verification takes ~4–6 weeks with Google, requires a branded public homepage + privacy policy + demo video, and would make Destin the sole owner of an app every user depends on. v1 ships without it; v2 is parked as an enhancement (see "Out of scope").

**Known limitation — 7-day refresh-token expiry (Research Item 1, RED).** Google enforces a 7-day refresh-token lifetime for External-type apps in Testing publish status that request sensitive scopes (all six of ours qualify). Workaround research found none documented. Users therefore see an OAuth consent screen roughly once per week.

**Mitigation — auto-reauth driven by the wrapper, not the user.** The user never runs a "reauth" command. When any skill's `gws_run` call returns an auth-expired error, the wrapper exits with a structured AUTH_EXPIRED signal. The skill surfaces this to Claude, which tells the user conversationally (*"Your Google connection needs a quick refresh — I'll open a browser"*), runs the reauth helper, waits for the browser consent, and retries the original call. User friction per 7 days: one browser tab, click "Allow," back to work. No slash commands to remember. Full behavior speced under "Auto-reauth flow" below.

**v2 enhancement (parked):** YouCoded-owned verified Google Cloud app. Verification eliminates the 7-day cycle entirely; users would do one OAuth grant at install and never see another consent screen. Cost is ~4–6 weeks of Google review plus a public homepage + privacy policy + demo video, plus ongoing ownership. Worth doing once v1 proves the bundle has users.

## User-facing language policy

**Every string the user reads uses plain language.** Internal scripts/commands can use technical names (`gws`, `gcloud`, API names, scope strings) because those are for us. But the user never sees "CLI," "API," "OAuth," "bootstrap," or "scope" unless they see it on a Google page we can't control — and in those cases, the setup command pre-frames what they're about to see.

The only place technical-looking words appear in user-facing copy is in the pre-consent warning screen (Step 4 below), because the user will see Google's literal text "Google hasn't verified this app" and needs matching language to orient.

---

## Architecture

### Plugin layout

```
wecoded-marketplace/google-services/
  plugin.json                          # marketplace metadata
  commands/
    google-services-setup.md           # /google-services-setup
  skills/
    gmail/SKILL.md
    google-drive/SKILL.md
    google-docs/SKILL.md
    google-sheets/SKILL.md
    google-slides/SKILL.md
    google-calendar/SKILL.md
  setup/
    install-gws.sh                     # detect + install gws (brew / cargo / prebuilt)
    install-gcloud.sh                  # detect + install gcloud (brew / winget / apt)
    bootstrap-gcp.sh                   # gcloud-driven project + API enable (scripted)
    consent-walkthrough.sh             # guided Cloud Console walkthrough + creds paste-back (manual)
    smoke-test.sh                      # read-only probe per service, at end of setup
    reauth.sh                          # 7-day auto-reauth helper — invoked by wrapper, not user
    migrate-legacy.sh                  # user-machine cleanup for retired artifacts
  lib/
    gws-wrapper.sh                     # gws_run function: forwards calls, exits 2 on AUTH_EXPIRED
  docs/
    DEV-VERIFICATION.md                # one-time round-trip checklist (dev, not shipped)
```

### How skills invoke Google services

Each skill calls `gws <subcommand>` directly via bash. `gws`'s JSON output is LLM-friendly and consumed directly by the skill. Skills don't store auth state themselves — `gws auth status` is the source of truth; OS keyring holds credentials.

### How setup works

`/google-services-setup` is a slash command (markdown command, not a skill). Linear script:

1. Platform gate
2. Install `gcloud` and `gws` if missing
3. `gcloud auth login` → browser 1
4. `bootstrap-gcp.sh`: create project, enable 6 APIs, create OAuth client, capture client_id + secret
5. Pre-framing screen: explain what the unverified-app warning will look like
6. `gws auth setup` with captured credentials → browser 2, user grants scopes
7. `smoke-test.sh` runs read-only probe per service
8. Migration cleanup (silent unless pre-existing artifacts detected)
9. Report pass/fail per integration; setup succeeds only if all six probes pass

### How skill discovery works

Each SKILL.md has a tight frontmatter description calibrated so Claude's built-in skill matcher picks exactly ONE skill per user prompt. No orchestration code.

### What's deliberately NOT in the architecture

- No custom MCP server — `gws` is already JSON-out by design
- No persistent state inside the plugin — `gws auth status` is the sole source of truth
- No shared "google-services" umbrella skill — six sibling skills only; umbrella was rejected as it bloats matcher descriptions

---

## User-facing flow (the shipped experience)

### Step 0 — System check

```
Getting Google apps ready for YouCoded...
```

Unsupported platform → clean abort with a plain-language message.

### Step 1 — Helper tools

If `gcloud` / `gws` missing:

```
YouCoded needs to install two small helper tools from Google
to connect to your account safely. This takes about 2 minutes
and about 500 MB of disk space. Continue? [y/n]
```

No CLI names. User declines → abort with manual-install instructions.

### Step 2 — Framing the two sign-ins

```
Next, YouCoded will open your browser twice to connect to Google:

  1. First, to create a private connection in your Google account
  2. Then, to ask your permission to use Gmail, Drive, Calendar,
     and your Google documents

The private connection is yours — it belongs to your Google
account, not to YouCoded or anyone else.

Press Enter to open your browser...
```

Runs `gcloud auth login`. Waits for completion.

### Step 3 — Setting it up (hybrid: scripted + ~3 minutes of guided clicks)

Per Research Item 2, `gcloud` can create the project and enable APIs, but **Google's OAuth consent-screen and client-ID configuration must be done in Cloud Console** for External-audience apps. The IAP OAuth Admin API that used to handle this programmatically was shut down on 2026-03-19. There is no current `gcloud` path that replaces it.

Step 3 is therefore split into four sub-steps. The user sees the whole thing as a single flow with progress lines; internally it's scripted → guided → paste → scripted.

**Step 3A — Scripted scaffolding (no user input).**

```
Setting up...
  ✓ Connected to your Google account
  ✓ Created your private YouCoded connection
  ✓ Unlocked Gmail
  ✓ Unlocked Drive
  ✓ Unlocked Docs
  ✓ Unlocked Sheets
  ✓ Unlocked Slides
  ✓ Unlocked Calendar
```

**Step 3B — Consent screen walkthrough.** Setup command opens Cloud Console's OAuth Consent Screen page to the right project via `gcloud` deep-link, then prints:

```
One quick thing I can't do for you automatically.

Google needs you to set up the permissions screen yourself. I've
opened the page in your browser — follow along:

  1. Click "Get Started"
  2. Choose audience: "External"   (important — not "Internal")
  3. App name: "YouCoded Personal"
  4. Support email: your own email
  5. Click Save and Continue through the next screens
  6. On the "Test users" screen, add your own email as a test user
  7. Click Back to Dashboard

Press Enter when you're done...
```

Screenshot of each numbered step shown in a side panel or inline-ASCII diagram.

**Step 3C — OAuth client ID paste-back.** Setup command opens Cloud Console's Credentials page, prints:

```
One more page. Still the same browser tab.

  1. Click "Create Credentials" → "OAuth client ID"
  2. Application type: "Desktop app"
  3. Name: "YouCoded Personal"
  4. Click Create
  5. Copy the Client ID and Client Secret from the box that appears
  6. Paste them below when prompted

Client ID: <prompt>
Client Secret: <prompt>
```

Setup writes the pasted credentials to `$HOME/.youcoded/google-services/oauth-credentials.json`.

**Step 3D — Automated OAuth flow.** `gws auth setup` is invoked with the pasted credentials. Browser #2 opens for the permission grant (proceeds to Step 4 below).

**Why this UX is acceptable.** The console steps are ~3 minutes, only happen once (not every 7 days — the reauth flow reuses these credentials), and every step has a screenshot. Users who never touch Cloud Console can still complete it because the instructions are literal click-by-click.

### Step 4 — Unverified-app warning explained in advance

```
⚠ Heads up: on the next screen, Google will show you a warning
that says "Google hasn't verified this app."

This is expected and safe. The "app" is you — YouCoded just set
up a private connection inside your own Google account, and now
you're giving yourself permission to use it.

To continue through Google's warning:
  • Click "Advanced"
  • Click "Go to youcoded-... (unsafe)"

Press Enter to continue...
```

This copy is load-bearing. Without it, non-technical users bail at the warning.

### Step 5 — Grant permissions

```
Opening Google's permission page...

Google will ask whether YouCoded can read your email, access
your Drive files, and so on. Please check every box — leaving
any unchecked will cause some features to not work.
```

Runs `gws auth setup` with the credentials from Step 3.

### Step 6 — Make sure it actually works

Runs `smoke-test.sh`:

```
Testing your connection...
  ✓ Gmail
  ✓ Drive
  ✓ Docs
  ✓ Sheets
  ✓ Slides
  ✓ Calendar

All set! Try asking YouCoded something like:
  "Send an email to Mom"
  "Find my budget spreadsheet from last week"
  "What's on my calendar tomorrow?"
```

Any probe fails → plain-language cause, one-click retry for just that service, and **setup does NOT report success.**

### Step 7 — Migration cleanup (silent unless needed)

```
Cleaning up old Google connections...  ✓
```

Details of what's removed are in the Migration section below. User doesn't need to know the artifact names unless cleanup fails — then we surface specifics.

### Idempotency

Re-running `/google-services-setup`: detects existing `youcoded-*` project and valid `gws auth status`, skips to smoke tests. If probes pass, reports "already set up." If they fail, offers targeted re-auth.

---

## Per-integration detail

Each of the six services gets the same shape: scope, `gws` surface, what the SKILL.md description must cover, dev-time round-trip, shipped read-only probe, known gotchas.

### Gmail

- **Scope:** `gmail.modify` (read + send + label; excludes full mailbox delete).
- **`gws` surface:** `gws gmail list / read / send / draft / label`.
- **Skill description covers:** sending email, reading email, searching inbox, managing labels, drafting replies. Must NOT match Google Chat or Google Messages prompts.
- **Dev-time round-trip:** send draft to self → fetch by subject → confirm body matches → delete message and draft.
- **Shipped probe:** `gws gmail list --max 5` returns non-error.
- **Gotchas:** (a) Drafts-vs-Sent distinction — don't leave draft residue. (b) HTML vs plaintext bodies — skill should normalize. (c) Localized label names for users whose Gmail UI is non-English.

### Google Drive

- **Scope:** `drive` (full — needed for list + read + write in any user-owned folder).
- **`gws` surface:** `gws drive list / download / upload / move / rename / trash`.
- **Skill description covers:** finding files, downloading, uploading, moving or renaming, putting things "in my Drive." Must NOT match Docs/Sheets/Slides prompts that want document content — those skills handle content; Drive handles files-as-objects.
- **Dev-time round-trip:** upload 1-byte test file → list by name → download → confirm bytes match → trash.
- **Shipped probe:** `gws drive list --max 5` returns non-error.
- **Gotchas:** (a) Shared Drives vs My Drive — different IDs; skill defaults to My Drive but recognizes shared-drive prompts. (b) MIME conversions (Google-native vs Office formats) — documented in skill body.

### Google Docs

- **Scope:** `documents`.
- **`gws` surface:** `gws docs get / create / update / export`.
- **Skill description covers:** reading a doc's contents, editing, creating new, exporting to PDF/Word. Content-level; Drive handles the file, Docs handles inside.
- **Dev-time round-trip:** create doc with "hello" → read back → confirm content → trash via `gws drive trash`.
- **Shipped probe:** `gws docs get` on a recent doc ID from `gws drive list --mime-type doc --max 1` — verifies read scope; no write.
- **Gotchas:** (a) Structured content response (paragraphs, tables, images), not plain text — skill handles the structure. (b) Revision history ops not in v1.

### Google Sheets

- **Scope:** `spreadsheets`.
- **`gws` surface:** `gws sheets get / create / values get / values update / append`.
- **Skill description covers:** reading values, writing values, appending rows, creating a new sheet, searching across sheets.
- **Dev-time round-trip:** create sheet → write `A1=hello` → read back A1 → confirm → trash.
- **Shipped probe:** `gws sheets get` on a recent sheet ID from `gws drive list --mime-type sheet --max 1`.
- **Gotchas:** (a) Formulas vs calculated values — default to values; skill is explicit when user asks for formulas. (b) A1 vs R1C1 — default A1.

### Google Slides

- **Scope:** `presentations`.
- **`gws` surface:** `gws slides presentations create / get / batchUpdate` (full read + write). Export and deck-listing hop to `gws drive files export` and `gws drive files list --q "mimeType='application/vnd.google-apps.presentation'"` respectively — per Research Item 3, Slides does not own those surfaces on the Google side either.
- **Skill description covers:** reading slide deck content, creating a new deck, adding or editing slides, exporting to PDF.
- **Dev-time round-trip:** create deck → `batchUpdate` to add slide + insert text → `get` and confirm slide count ≥ 2 + text present → export to PDF via drive → `gws drive trash`.
- **Shipped probe:** `gws drive files list --max 1 --q "mimeType='application/vnd.google-apps.presentation'"` then `gws slides presentations get <id>`.
- **Gotchas:** (a) `batchUpdate` is verbose — Claude tends to chain many requests one-at-a-time when it should batch. Skill includes 2–3 batch recipes as examples. (b) Cross-service hops: the skill declares `google-drive` as a soft dependency for export and list.

### Google Calendar

- **Scope:** `calendar`.
- **`gws` surface:** `gws calendar list`, `gws calendar events list / create / update / delete`.
- **Skill description covers:** checking what's on the calendar, creating events, moving, canceling, setting reminders, checking availability.
- **Dev-time round-trip:** create event 1 hour from now → list events → confirm present → delete.
- **Shipped probe:** `gws calendar events list --max 5` on primary calendar returns non-error.
- **Gotchas:** (a) Multiple calendars (personal/family/work) — default primary; skill recognizes when user names another. (b) Recurring events — single-instance vs series updates. (c) Time zones — surface primary TZ; format accordingly.

### Shared concerns across all six

- All skills source auth status from `gws auth status`. None keep their own state.
- `lib/gws-wrapper.sh` exposes one function, `gws_run`, that every skill calls instead of invoking `gws` directly. It forwards the command, inspects output for auth-expiry signatures, and exits with code **2** and a stable `AUTH_EXPIRED:<service>` line on the auth path. Skills never duplicate this logic.
- Every SKILL.md includes a uniform **"## Handling auth expiry"** section with the exact phrasing Claude uses to recover from an exit-2 signal. See "Auto-reauth flow" below for the contract.
- Skill descriptions are calibrated during implementation so Claude picks exactly ONE skill per prompt — no split-brain routing. Tested with prompts like *"send an email with last week's budget sheet attached"* (should route to Gmail primary, Sheets as secondary tool inside Gmail, not a tie).

---

## Auto-reauth flow

Because the user's OAuth refresh token expires every 7 days (see OAuth strategy), every skill must gracefully recover from `invalid_grant` mid-conversation. The user never runs a reauth command; Claude drives the recovery.

### The contract

1. **Skill calls `gws_run <service> <args...>`.** The wrapper forwards to `gws`, catches auth errors, and returns exit **0** on success or exit **2** on auth expiry. Any other error keeps its original exit code.
2. **On exit 2**, the wrapper has already written a single line to stderr: `AUTH_EXPIRED:<service>` (e.g., `AUTH_EXPIRED:gmail`). This is a stable marker the skill parses; it is NOT user-facing text.
3. **Skill catches exit 2**, stops its current operation, and prints a brief marker Claude can read: e.g., `[reauth-required: gmail]`.
4. **Claude, seeing the marker**, tells the user in natural language: *"Your Google connection needs a quick refresh — I'm opening a browser. Approve the permissions and I'll finish {original task}."*
5. **Claude runs `bash $CLAUDE_PLUGIN_ROOT/setup/reauth.sh`.** This helper:
   - Reads `$HOME/.youcoded/google-services/oauth-credentials.json` (stored during initial setup)
   - Invokes `gws auth setup` with those credentials — opens the OS's default browser to Google's OAuth consent page
   - Blocks until the OAuth flow completes (success or user cancels)
   - Exits 0 on success, 1 on failure
6. **On reauth success**, Claude retries the original `gws_run` call with the same arguments. If it succeeds, Claude proceeds as if nothing happened and completes the user's request.
7. **On reauth failure** (user closed the browser, refresh timed out), Claude tells the user plainly: *"I couldn't refresh the Google connection. Want me to try again, or come back to this later?"*

### What the user sees per 7 days

- Asks Claude something Google-related
- Brief message from Claude: *"Quick refresh — approve in your browser."*
- Familiar OAuth consent page opens (same one from first-time setup)
- Clicks "Allow"
- Browser closes; Claude completes the original request
- Total friction: ~10 seconds of clicking

### What this flow does NOT re-do

- **It does NOT re-run `bootstrap-gcp.sh`.** The GCP project, APIs, and OAuth client already exist from initial setup. `reauth.sh` reuses the stored `oauth-credentials.json`.
- **It does NOT show the unverified-app warning.** That warning is shown on first consent, not on subsequent consent grants to the same client ID. User goes straight to the scope-grant page.
- **It does NOT re-run smoke tests.** Once the reauth succeeds, the original skill retries its own operation. That retry is the proof it worked.

### Implementer notes (not in shipped behavior)

- `gws auth setup` must be callable non-interactively with pre-supplied credentials. Confirm at implementation time. If it insists on prompting, the reauth helper shells out to a different entry point (likely `gws auth refresh --force` or manual `gws auth token` + browser open).
- The AUTH_EXPIRED signature in `gws`'s error output is version-sensitive. Pin the wrapper's regex to the pinned `gws` version and re-verify on every version bump.

---

## Migration — clean cutover, same PR

All changes land atomically with the `google-services` ship. Nothing lingers on master.

**Registry changes:**
- **DELETE** `wecoded-marketplace/index.json` `google-workspace` entry.
- **DELETE** `wecoded-marketplace/youcoded-drive/` directory entirely.
- **EDIT** `wecoded-marketplace/youcoded-inbox/skills/claudes-inbox/providers/gmail.md` — rewrite body from `mcp__claude_ai_Gmail__*` to `gws gmail list / read`. Provider's outer contract stays stable; inbox skill doesn't change.
- **EDIT** `youcoded-core/hooks/tool-router.sh` — remove the `mcp__claude_ai_Gmail__*` and `mcp__claude_ai_Google_Calendar__*` block/redirect clauses. Rest of router intact.
- **EDIT** `wecoded-marketplace/youcoded-messaging/` — delete the `imessages/` subdirectory (Anthropic plugin supersedes). Keep `gmessages/`; its repackaging belongs to the Google Messages bundle's spec, not this one.

**User-machine reconciliation** (handled by `/google-services-setup` Step 7):
Silently removes prior plugin enabled flags, rclone `gdrive:` remote config, and any cached auth state from the deprecated `google-workspace` metadata. User sees one line.

**Pre-ship verification:** On a test system with `youcoded-drive` installed and `claudes-inbox` wired to the hosted Gmail MCP, `/google-services-setup` must correctly detect, remove, and leave the system in a clean state — no dangling references, no leftover config.

---

## Failure modes

Five classes, each with defined handling. Edge cases captured during implementation.

1. **Helper-tool install fails** (user declines / package manager absent / download fails). Clean abort with manual-install instructions. No project created, no state to reconcile.

2. **First sign-in fails, times out, or user cancels.** Clean abort. No project, no state. Re-run fresh.

3. **Provisioning fails mid-way** (API quota, network drop, transient Google error). Partial state is possible. Setup MUST be idempotent: on re-run, detect the existing `youcoded-*` project and resume, never create a second project. Resume logic covers "project exists but N of 6 APIs enabled" and "APIs enabled but OAuth client not yet created."

4. **User bails at the unverified-app warning.** Browser 2 never completes; `gws auth setup` times out. Setup reports: *"Looks like you didn't finish approving the permissions. When you're ready, run `/google-services-setup` again — this time click 'Advanced' then 'Continue' on Google's warning screen."* Re-run skips to Step 4 using the existing project.

5. **Read-only probe fails for one or more services.** Report which service, which scope is likely missing, offer targeted re-auth for just that scope. Setup does NOT report success. Bundle won't claim Gmail works if the Gmail probe failed.

Edge cases documented but not expanded here (handled at implementation): network disconnect mid-bootstrap, Google account locked for security review, user on a Google Workspace account whose admin disallows personal OAuth apps, gcloud SDK version mismatch with `bootstrap-gcp.sh`.

---

## Research outcomes (resolved 2026-04-16)

Three items were surfaced during brainstorming and researched via documentation before this spec was finalized. Empirical observation (e.g., the 10-day refresh-token watch) was deliberately skipped; findings are based on Google's current policy docs, official `gcloud` reference, community forums, and `gws` source. Full reports live at `docs/superpowers/plans/research/`.

### 1. 7-day refresh-token expiry — 🔴 RED

Google's current OAuth docs (last updated 2026-04-03) still enforce the 7-day refresh-token lifetime for External + Testing-status apps that request sensitive scopes. Every scope we need (`gmail.modify`, `drive`, `calendar`, `documents`, `spreadsheets`, `presentations`) qualifies. No documented workaround exists. Community lore about "publish to Production unverified" is unverified and contradicted by the policy language that ties the 7-day limit to unverified *state*, not the Testing *label*.

**Decision taken:** Accept the 7-day expiry as a known limitation. Mitigate via the auto-reauth flow (see "Auto-reauth flow" section) so the user never has to run a reauth command — Claude drives it in-conversation. v2 YouCoded-owned verified app is parked as a future enhancement.

**Source:** `docs/superpowers/plans/research/2026-04-16-refresh-token-findings.md`.

### 2. `gcloud` External-consent automation — 🟡 YELLOW

`gcloud alpha iap oauth-brands create` only produces Internal-type brands in 2026. The IAP OAuth Admin API that handled programmatic External-brand provisioning was deprecated 2025-01-22 and fully shut down 2026-03-19 (three weeks before this spec). Google is moving *away* from programmatic OAuth client management, not toward it. ~3–5 minutes of manual Cloud Console work per user is unavoidable.

**Decision taken:** Accept the manual steps. Split `/google-services-setup` Step 3 into the four-phase hybrid flow (scripted scaffold → guided console walkthrough → paste credentials → automated OAuth). Screenshot-backed click-by-click instructions at each manual step.

**Source:** `docs/superpowers/plans/research/2026-04-16-oauth-brand-automation.md`.

### 3. `gws` Slides write coverage — 🟢 GREEN

`gws` builds its command tree dynamically from Google's Discovery Service at runtime; `gws slides` at v0.22.5 exposes `presentations.create`, `presentations.get`, `presentations.batchUpdate`, and the `pages` sub-resource. `batchUpdate` is Google's universal mutation entrypoint — all write operations (add/remove slides, insert text, replace content, change layouts, images, tables) route through it. Two apparent gaps are actually Drive-side: PDF export lives on `gws drive files export`, and deck listing on `gws drive files list`.

**Decision taken:** Ship Slides with full read + write + export, documenting in the Slides skill that export and listing hop to the drive surface.

**Source:** `docs/superpowers/plans/research/2026-04-16-gws-slides-coverage.md`.

---

## Dev-time verification checklist (not shipped)

Before declaring this plugin ready to ship, we run this checklist on a clean test machine. Lives in `setup/` only as `DEV-VERIFICATION.md`; not included in the installed plugin.

- [ ] `/google-services-setup` completes end-to-end on macOS, Windows, Linux with no pre-existing `gcloud` or `gws` installed.
- [ ] Idempotent re-run with existing valid auth reports "already set up" and skips to probes.
- [ ] Partial-state re-run (simulate network drop between API-enable and OAuth-client-create) detects existing project and resumes correctly, does NOT create a second project.
- [ ] Gmail round-trip: send draft to self → fetch → delete. Leaves no residue.
- [ ] Drive round-trip: upload → list → download → trash.
- [ ] Docs round-trip: create → read → trash.
- [ ] Sheets round-trip: create → write A1 → read A1 → trash.
- [ ] Slides round-trip: create deck → batchUpdate to add slide + text → get → `gws drive files export` to PDF → `gws drive trash`.
- [ ] Calendar round-trip: create event → list → delete.
- [ ] Migration: test machine with pre-installed `youcoded-drive` + `claudes-inbox` on hosted Gmail — setup cleans all artifacts.
- [ ] Skill discovery: compound prompts ("send an email with last week's budget sheet attached") route cleanly to one primary skill.
- [ ] Auto-reauth: force an `invalid_grant` (e.g., revoke a token in Google account settings), invoke any skill, verify Claude recovers end-to-end via `reauth.sh` and retries successfully.

---

## Out of scope (v1, parked for follow-ups)

- Google Contacts — v1.1 candidate.
- Google Messages — separate bundle spec.
- Google Chat — not advertised; skip indefinitely.
- **YouCoded-owned verified Google Cloud app (v2 enhancement).** Would eliminate the 7-day reauth cycle by migrating every user from their own BYO-GCP project to a single YouCoded-owned verified app. Requires ~4–6 weeks of Google review, a public YouCoded homepage, published privacy policy, demo video, and ongoing ownership by Destin. Revisit once v1 has measurable usage — verification is expensive to maintain and doesn't pay back without a user base.
- Shared Drive / Workspace tenant-admin flows.

---

## References

- `docs/plans/marketplace-integrations-v2.md` — the monolithic predecessor plan being decomposed into per-bundle specs.
- `docs/PITFALLS.md` — cross-cutting gotchas (IPC parity, release pitfalls, plugin-installation registries).
- `docs/toolkit-structure.md` — hooks manifest model, skill layout conventions, command format.
- `googleworkspace/cli` — upstream CLI (Apache 2.0, official Google).
- `wecoded-marketplace/index.json` — current marketplace registry; entries affected by migration section.
- `wecoded-marketplace/youcoded-drive/` — rclone Drive skill being retired.
- `wecoded-marketplace/youcoded-inbox/skills/claudes-inbox/providers/gmail.md` — hosted-Gmail provider being rewritten.
- `youcoded-core/hooks/tool-router.sh` — Gmail/Calendar block being removed.
