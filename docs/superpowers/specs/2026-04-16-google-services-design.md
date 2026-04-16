# Google Services Bundle — Design

**Status:** Draft, awaiting user review.
**Created:** 2026-04-16
**Owner:** Destin
**Supersedes in scope:** part of `docs/plans/marketplace-integrations-v2.md` (the monolithic cross-bundle plan). The Google portion of that plan is replaced by this document. Other bundles (Apple Services, iMessage, macOS Control, etc.) will each get their own spec.

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

**User-brings-own GCP project, automated end-to-end via `gcloud` during `/google-services-setup`.** No YouCoded-owned verified app in v1.

Rationale: verification takes ~4–6 weeks with Google, requires a branded public homepage + privacy policy + demo video, and would make Destin the sole owner of an app every user depends on. User-brings-own sidesteps all of that at the cost of setup friction, which we mitigate by scripting every step of the GCP bootstrap via `gcloud`.

⚠ **Research-gated:** the 7-day refresh-token expiry for unverified-app sensitive scopes (see Open Research Items) could invalidate this choice. Spec commits to the branch contingent on research resolution.

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
    bootstrap-gcp.sh                   # gcloud-driven project + API enable + OAuth client
    smoke-test.sh                      # read-only probe per service, at end of setup
  lib/
    gws-wrapper.sh                     # shared helpers: auth-status, auth-error-handler
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

### Step 3 — Setting it up

All provisioning happens as one progress block with plain-language labels:

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
- **`gws` surface:** `gws slides get`; write-op support depends on Research Item 3's outcome (spec reverts to read-only Slides for v1 if `gws` lacks writes).
- **Skill description covers:** reading slide deck content, creating a new deck, exporting to PDF.
- **Dev-time round-trip:** create deck → add slide with "hello" → export to PDF → confirm non-empty → trash.
- **Shipped probe:** `gws slides get` on a recent deck ID from `gws drive list --mime-type slides --max 1`.
- **Gotchas:** `gws`'s Slides surface is historically thinner than Docs/Sheets. If write ops aren't supported, ship Slides as **read-only in v1**, document the gap, file a follow-up issue to add writes when `gws` gains them.

### Google Calendar

- **Scope:** `calendar`.
- **`gws` surface:** `gws calendar list`, `gws calendar events list / create / update / delete`.
- **Skill description covers:** checking what's on the calendar, creating events, moving, canceling, setting reminders, checking availability.
- **Dev-time round-trip:** create event 1 hour from now → list events → confirm present → delete.
- **Shipped probe:** `gws calendar events list --max 5` on primary calendar returns non-error.
- **Gotchas:** (a) Multiple calendars (personal/family/work) — default primary; skill recognizes when user names another. (b) Recurring events — single-instance vs series updates. (c) Time zones — surface primary TZ; format accordingly.

### Shared concerns across all six

- All skills source auth status from `gws auth status`. None keep their own state.
- `lib/gws-wrapper.sh` provides one shared auth-error helper: if `gws` returns an auth error, user sees *"Your Google Services connection needs refreshing — run `/google-services-setup` to reconnect."* Never six variants.
- Skill descriptions are calibrated during implementation so Claude picks exactly ONE skill per prompt — no split-brain routing. Tested with prompts like *"send an email with last week's budget sheet attached"* (should route to Gmail primary, Sheets as secondary tool inside Gmail, not a tie).

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

## Open research items

Answer before implementation begins. Each has a fallback if the answer is unfavorable.

### 1. 7-day refresh-token expiry for unverified-app sensitive scopes

- **Question:** In 2026, does Google still expire refresh tokens after 7 days for External-type OAuth apps in "Testing" publish status when requesting sensitive scopes (`gmail.modify`, `drive`, `calendar`)?
- **How to resolve:** Read Google's current OAuth policy docs. Provision a test project and observe token behavior over 10 days.
- **Fallback if unavoidable:**
  - (a) Narrow scope list to non-sensitive only — loses Gmail send, Drive write, Calendar modify. Heavy feature loss; almost certainly unacceptable.
  - (b) Pivot to YouCoded-owned verified app — spec reverts to Path 2 of the earlier OAuth fork; Destin owns verification.
  - (c) Accept weekly re-auth; make `/google-services-setup --reauth` a one-touch flow.
- **Decision belongs to Destin at research-resolution time, not now.**

### 2. "External" OAuth consent screen automation via `gcloud`

- **Question:** In 2026, can `gcloud alpha iap oauth-brands create` + `oauth-clients create` configure an External-type consent screen end-to-end, or does it still require cloud-console clicks?
- **How to resolve:** Run end-to-end in a throwaway GCP project. Observe what's left manual.
- **Fallback:** Add a ~60-second screenshot-guided walkthrough for the remaining clicks. Small UX cost; no design-level change.

### 3. `gws` Slides write coverage

- **Question:** Does `gws slides` support write operations (create slides, add content) in 2026, or read-only?
- **How to resolve:** `gws slides --help` on the pinned version; upstream release notes.
- **Fallback:** Ship Slides read-only in v1, document the gap, follow-up issue.

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
- [ ] Slides round-trip (or read-only if research item 3 rules out writes).
- [ ] Calendar round-trip: create event → list → delete.
- [ ] Migration: test machine with pre-installed `youcoded-drive` + `claudes-inbox` on hosted Gmail — setup cleans all artifacts.
- [ ] Skill discovery: compound prompts ("send an email with last week's budget sheet attached") route cleanly to one primary skill.
- [ ] Refresh-token behavior observed over 10 days to validate research item 1's answer.

---

## Out of scope (v1, parked for follow-ups)

- Google Contacts — v1.1 candidate.
- Google Messages — separate bundle spec.
- Google Chat — not advertised; skip indefinitely.
- Verified-app path / YouCoded-owned GCP app — could become necessary based on research item 1; not baseline v1.
- Slides write ops — if research item 3 finds `gws` lacks them.
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
