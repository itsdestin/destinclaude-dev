# Apple Services Bundle — Design

**Status:** Draft — pending user review before transitioning to implementation plan.
**Created:** 2026-04-17
**Owner:** Destin
**Supersedes in scope:** the "Apple Services" section of `docs/superpowers/plans/2026-04-17-remaining-bundles-handoff.md`. That briefing's phased "3rd-party MCP → native Swift helper" recommendation is explicitly discarded; this spec evaluates the full option landscape fresh and commits to a different direction.
**Depends on:** `2026-04-17-marketplace-attributions-design.md` (to be written as a follow-up) for schema-field rendering and `VENDORED.md` validation. See Section 6 for coordination rules — neither PR blocks the other.
**Research findings (to be produced):** `docs/superpowers/plans/research/2026-04-17-apple-*.md` — 16 items enumerated in Section 7.

---

## Goal

Ship a marketplace plugin named `apple-services` that gives Claude general-purpose access to the six Apple services shown as chips on the landing page: **iCloud Drive, Apple Notes, Apple Reminders, Apple Calendar, Apple Mail, Apple Contacts.**

This bundle is **infrastructure** — a tools layer for Claude and for downstream plugins. It does not define use cases. Future plugins (journaling, task triage, scheduling assistants, etc.) compose these skills into flows. The quality bar is therefore "clean, fast, rich, and uniform" rather than "optimized for any single user scenario."

## Scope

**In scope (v1):** CRUD and search across all six services, matching Google Services' per-integration depth.

**Out of scope (v1):**
- **Shortcuts.app bridge** — power-user feature, additive, deferred to v1.x.
- **Meeting-attendee invitations** in Calendar — EventKit supports but adds design weight; defer.
- **Mail rule/signature management** — read/send/search is enough for v1.
- **Contact photos** (setting; reading is available via `image_data`).
- **`brctl` force-sync** for iCloud Drive — default mount behavior is fine for v1.
- **Cross-account flows** (multiple Apple IDs) — single signed-in account, matching Google Services v1.
- **Background daemons.** Every skill call is one-shot.

## Foundation

**Split backing per integration, unified surface.** Each of the six skills presents the same uniform error envelope and invocation shape, but underneath:

| Integration | Backing | Reason |
|---|---|---|
| Calendar | Swift helper binary calling EventKit | Native multi-calendar queries, reliable recurrence |
| Reminders | Swift helper binary calling EventKit | Stable IDs, clean CRUD |
| Contacts | Swift helper binary calling Contacts framework | AppleScript Contacts is painful for search and groups |
| Notes | AppleScript via `osascript` | No public API exists |
| Mail | AppleScript via `osascript` | No public API exists |
| iCloud Drive | Plain filesystem at `~/Library/Mobile Documents/com~apple~CloudDocs/` | Already mounted; nothing to build |

**`apple-helper`** — small Swift CLI, distributed as a universal (arm64+x86_64) Mach-O binary. Ad-hoc signed (`codesign --sign -`), NOT notarized, NOT Developer-ID signed. Matches YouCoded desktop's current unsigned posture. The binary is downloaded during `/apple-services-setup` from the plugin's GitHub releases, not checked into the plugin directory.

**AppleScript files** — vendored from open source (primarily `Dhravya/apple-mcp`) and adapted. Shipped in `applescript/` inside the plugin.

**Aggressive OSS borrowing policy** — substantial code is lifted from open source rather than written from scratch. Specifically:
- `loopwork/iMCP` — Swift service modules for Calendar, Reminders, Contacts (Apache-2.0 pending Phase 0 confirmation). The menu-bar-app packaging is discarded; the per-service modules are extracted and dropped into our CLI helper.
- `Dhravya/apple-mcp` — AppleScript snippets for Notes and Mail (MIT pending Phase 0 confirmation).
- `keith/Reminders-CLI` — Reference implementation for Reminders CLI surface and argument parsing (MIT pending Phase 0 confirmation).
- Apple's own EventKit and Contacts framework sample code as authoritative references.

Borrowed files are tracked in `VENDORED.md` (see Section 6). Upstream license terms are reproduced in `NOTICE.md`.

## TCC / permission strategy

Apple services have no OAuth tokens. Permission is managed by macOS's **TCC** (Transparency, Consent & Control) subsystem. Three distinct grants are involved:

| Grant | Scope | Granted to | Triggered by |
|---|---|---|---|
| Full Access — Calendars | EventKit read/write of calendars + events | `apple-helper` | `requestFullAccessToEvents` call in helper |
| Full Access — Reminders | EventKit read/write of reminders | `apple-helper` | `requestFullAccessToReminders` call in helper |
| Access — Contacts | Contacts framework read/write | `apple-helper` | `CNContactStore.requestAccess(for: .contacts)` |
| Automation — Notes | AppleScript control of Notes.app | parent process (see Phase 0 R9) | First `osascript` call to Notes |
| Automation — Mail | AppleScript control of Mail.app | parent process | First `osascript` call to Mail |

No TCC grants are needed for iCloud Drive (plain filesystem under user's home). No Full Disk Access is required for any op in scope.

**Recovery from revoked permissions** is handled uniformly via the `TCC_DENIED` error code (Section 4) — the user never runs a dedicated "reauth" command; `/apple-services-setup` is idempotent and doubles as the re-grant flow.

## User-facing language policy

Every string the user reads uses plain language. Internal code can use technical names (`apple-helper`, `osascript`, `EventKit`) because those are for us. The user never sees "CLI," "API," "framework," or "TCC" unless they see it on a macOS system dialog we can't control — in which case `/apple-services-setup` pre-frames what's about to appear.

Mirrors the Google Services policy exactly.

---

## Architecture

### Bundle layout

```
wecoded-marketplace/apple-services/
  plugin.json                          # v1.0.0, platform: macos
  VENDORED.md                          # per-file attribution tracking
  NOTICE.md                            # license texts for borrowed code

  commands/
    apple-services-setup.md            # /apple-services-setup slash command

  skills/
    apple-calendar/SKILL.md            # one sibling skill per integration
    apple-reminders/SKILL.md
    apple-contacts/SKILL.md
    apple-notes/SKILL.md
    apple-mail/SKILL.md
    icloud-drive/SKILL.md

  lib/
    apple-helper-wrapper.sh            # shared wrapper for the Swift binary
    applescript-runner.sh              # shared osascript wrapper (Notes/Mail)

  bin/
    apple-helper                       # universal Mach-O; downloaded by setup,
                                       # NOT checked into git

  helper/                              # Swift source for the binary
    Package.swift
    Sources/
      AppleHelper/                     # CLI entry, arg parsing, JSON output
      FromIMCP/                        # vendored iMCP service modules
        CalendarService.swift
        RemindersService.swift
        ContactsService.swift
      AppleHelperCore/                 # shared: JSON encoding, errors, TCC probes

  applescript/                         # vendored from Dhravya/apple-mcp
    notes/
      list.applescript
      read.applescript
      create.applescript
      update.applescript
      delete.applescript
      search.applescript
      list-folders.applescript
    mail/
      search.applescript
      read.applescript
      send.applescript
      create-draft.applescript
      list-mailboxes.applescript
      mark-read.applescript

  setup/
    strip-quarantine.sh                # xattr -d on downloaded binary
    permissions-walkthrough.md         # TCC walkthrough content (shown by setup)
    smoke-test.sh                      # post-install read-only probe per integration

  docs/
    DEV-VERIFICATION.md                # round-trip checklist (not shipped)
```

GitHub Actions requires `.github/workflows/` at a repository root, so the helper-build workflow lives at `wecoded-marketplace/.github/workflows/apple-helper-build.yml` (alongside the existing `validate-plugin-pr.yml`). It triggers on tags matching `apple-helper-v*`, builds the universal binary on `macos-latest`, and attaches it to a GitHub release in the marketplace repo. The plugin's `setup/` step 2 resolves the latest release by tag pattern.

### Binary invocation shape

Skills do not call `osascript` or `apple-helper` directly — they go through wrappers. The Swift helper's CLI surface looks like:

```bash
apple-helper calendar list --from 2026-04-17 --to 2026-04-24
apple-helper calendar create --title "Meeting" --start 2026-04-17T14:00 --end 2026-04-17T15:00
apple-helper reminders list --incomplete-only --list "Today"
apple-helper contacts search --query "jenny"
```

**Output contract:**
- Success: JSON array or object to stdout, exit code 0.
- Failure: JSON error object to stderr, nonzero exit code.
- TCC permission denied: exit code 2, stderr contains `TCC_DENIED:<service>` marker (modeled on Google Services' `AUTH_EXPIRED:<service>`).

### Wrapper responsibilities

**`lib/apple-helper-wrapper.sh`** wraps every Swift helper call:
- Locates the binary at `$PLUGIN_DIR/bin/apple-helper` (with `$APPLE_HELPER_BIN` override for testing).
- Detects missing binary → emits a clear message pointing to `/apple-services-setup`.
- Detects `TCC_DENIED:<service>` → emits uniform error telling Claude how to recover.
- Normalizes Swift JSON output for consumption by skills.

**`lib/applescript-runner.sh`** wraps every `osascript` call:
- Takes a script filename from `applescript/` plus argument substitutions.
- Catches AppleScript permission failures (error -1743) → same `TCC_DENIED:<service>` pattern.
- Enforces a 30-second timeout to catch stuck target apps (e.g. Mail.app in first-run wizard).
- Returns results as JSON where reasonable; raw text where not.

Both wrappers emit identical `TCC_DENIED` markers so Claude's recovery logic is uniform regardless of backing.

### Non-goals at the architecture layer

- **No caching.** Each call hits live Apple services.
- **No daemon or server.** The helper is a one-shot CLI; exits after each invocation.
- **No background sync.** iCloud Drive reads show what's local; nothing more.
- **No cross-account.** Single Apple ID, matching Google Services v1.

---

## Per-integration operation surfaces

Each skill exposes a focused operation set. Parameters and return shapes given here are contractual — they define what Claude sees.

### apple-calendar

| Op | Parameters | Returns |
|---|---|---|
| `list_calendars` | — | `[{id, title, color, writable}]` |
| `list_events` | `from`, `to`, `calendar_id?` | `[event]` across one or all calendars |
| `get_event` | `id` | `event` |
| `search_events` | `query`, `from`, `to` | `[event]` matching text in title/notes |
| `create_event` | `title`, `start`, `end`, `calendar_id`, `location?`, `notes?`, `recurrence?`, `all_day?` | `event` |
| `update_event` | `id` + any field above | `event` |
| `delete_event` | `id` | `{ok: true}` |
| `free_busy` | `from`, `to`, `calendar_ids?` | `[{start, end, busy}]` for downstream scheduling |

### apple-reminders

| Op | Parameters | Returns |
|---|---|---|
| `list_lists` | — | `[{id, title, color}]` |
| `list_reminders` | `list_id?`, `incomplete_only?` | `[reminder]` |
| `get_reminder` | `id` | `reminder` |
| `create_reminder` | `title`, `list_id`, `due?`, `priority?`, `notes?` | `reminder` |
| `update_reminder` | `id` + any field | `reminder` |
| `complete_reminder` | `id` | `{ok: true}` |
| `delete_reminder` | `id` | `{ok: true}` |

### apple-contacts

| Op | Parameters | Returns |
|---|---|---|
| `search` | `query` (fuzzy across name, phone, email, org) | `[contact]` |
| `get` | `id` | `contact` |
| `list_groups` | — | `[{id, name}]` |
| `list_group_members` | `group_id` | `[contact]` |
| `create` | `first`, `last?`, `phones[]?`, `emails[]?`, `organization?`, `notes?` | `contact` |
| `update` | `id` + any field | `contact` |
| `add_to_group` | `contact_id`, `group_id` | `{ok: true}` |
| `remove_from_group` | `contact_id`, `group_id` | `{ok: true}` |

### apple-notes

| Op | Parameters | Returns |
|---|---|---|
| `list_folders` | — | `[{name, note_count}]` |
| `list_notes` | `folder?` | `[{id, name, modified}]` |
| `get_note` | `id` | `{id, name, body_markdown, modified}` — HTML→markdown in wrapper |
| `search_notes` | `query`, `folder?` | `[{id, name, snippet}]` |
| `create_note` | `name`, `body_markdown`, `folder?` | `note` |
| `update_note` | `id`, `body_markdown`, `mode?` (replace/append/prepend) | `note` |
| `delete_note` | `id` | `{ok: true}` |

### apple-mail

| Op | Parameters | Returns |
|---|---|---|
| `list_mailboxes` | `account?` | `[{name, account, unread_count}]` |
| `search` | `query`, `mailbox?`, `from?`, `to?`, `since?`, `limit?` | `[{id, from, subject, date, preview}]` |
| `read_message` | `id` | `{id, from, to[], cc[], subject, date, body_text, body_html?, attachments[]}` |
| `send` | `to[]`, `cc[]?`, `bcc[]?`, `subject`, `body`, `attachments[]?` | `{ok: true}` |
| `create_draft` | same as `send` | `{id}` |
| `mark_read` / `mark_unread` | `id` | `{ok: true}` |

### icloud-drive

| Op | Parameters | Returns |
|---|---|---|
| `list` | `path`, `recursive?` | `[{name, type, size, modified}]` |
| `read` | `path` | text content, or `{binary: true, type, size}` |
| `write` | `path`, `content` | `{ok: true}` |
| `delete` | `path` | `{ok: true}` |
| `move` | `src`, `dst` | `{ok: true}` |
| `create_folder` | `path` | `{ok: true}` |
| `stat` | `path` | `{name, type, size, modified}` |

All paths are relative to `~/Library/Mobile Documents/com~apple~CloudDocs/`. The wrapper resolves them.

---

## Setup command flow

`/apple-services-setup` is a markdown slash command, linear, idempotent, aborts on unrecoverable error. Seven steps:

### Step 1 — Platform check

```bash
if [ "$(uname)" != "Darwin" ]; then
  echo "Apple Services only works on macOS — install on a Mac to use this bundle."
  exit 1
fi
```

Marketplace gates this bundle to `platform: macos`; this is a belt-and-suspenders check.

### Step 2 — Download the helper binary

1. Detect architecture via `arch`: `arm64` or `x86_64`.
2. Download `apple-helper-universal` from the pinned GitHub release URL.
3. Verify SHA256 against the published checksum.
4. Strip quarantine: `xattr -d com.apple.quarantine bin/apple-helper`.
5. `chmod +x bin/apple-helper`.

**Idempotency:** if `bin/apple-helper` exists and SHA matches expected, skip.
**Pre-frame:** "I'm downloading a small tool that lets Claude talk to Calendar, Reminders, and Contacts. About 1 MB, one-time."
**Failure path:** retry once, then print release URL and manual-install instructions.

### Step 3 — iCloud Drive availability check

```bash
if [ ! -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]; then
  echo "iCloud Drive isn't turned on."
  echo "Open System Settings → your name at the top → iCloud → iCloud Drive, turn it on, then re-run this."
  exit 1
fi
```

### Step 4 — EventKit + Contacts permissions

```bash
bin/apple-helper --request-permissions
```

The helper internally calls:
- `EKEventStore().requestFullAccessToEvents { ... }`
- `EKEventStore().requestFullAccessToReminders { ... }`
- `CNContactStore().requestAccess(for: .contacts) { ... }`

macOS shows three system dialogs in sequence.

**Pre-frame:** "macOS is about to show three permission dialogs — for Calendar, Reminders, and Contacts. Each one will say a tool called 'apple-helper' wants access. That's us. Click **Allow** on all three."
**Failure path:** helper exits with `TCC_DENIED:<service>`. Setup emits "Looks like [Calendar] access was denied. Open System Settings → Privacy & Security → [Calendars], find 'apple-helper' in the list and turn it on. Then re-run `/apple-services-setup`."
**Idempotency:** if grants already exist, `requestFullAccess*` returns immediately without re-prompting.

### Step 5 — Automation permissions for Notes and Mail

Trigger Automation prompts via trivial no-op scripts:

```bash
osascript -e 'tell application "Notes" to count notes'
osascript -e 'tell application "Mail" to count messages of inbox'
```

**Pre-frame:** "macOS is about to ask if Claude can control Notes and Mail. Click **OK** on both prompts."
**Failure path:** denial → "Automation access to [Notes] was denied. Open System Settings → Privacy & Security → Automation → find the terminal app Claude runs in → turn on [Notes]."
**Quirk:** if Mail isn't fully set up, `count messages of inbox` hangs. Run with 10s timeout; emit "Mail isn't fully set up yet — open Mail.app and finish account setup, then re-run."

### Step 6 — Smoke test each integration

Read-only probes:

| Integration | Probe | Expected |
|---|---|---|
| Calendar | `apple-helper calendar list_calendars` | ≥1 calendar |
| Reminders | `apple-helper reminders list_lists` | ≥1 list |
| Contacts | `apple-helper contacts search --query "" --limit 1` | array returned |
| Notes | `osascript list-folders.applescript` | ≥1 folder |
| Mail | `osascript list-mailboxes.applescript` | ≥1 mailbox |
| iCloud Drive | `stat ~/Library/Mobile Documents/com~apple~CloudDocs` | directory exists |

All six run regardless of individual failures. The summary reports pass/fail per integration with specific remediation.

### Step 7 — Success summary

```
✓ Apple Services is ready.

Calendar:       24 calendars found
Reminders:      5 lists found
Contacts:       ready
Notes:          3 folders found
Mail:           4 mailboxes found
iCloud Drive:   ready

Try asking Claude:
  • "What's on my calendar this week?"
  • "Remind me at 5pm to call mom"
  • "Find Jenny's phone number"
  • "What's in my Notes folder 'Tahoe'?"
  • "Search my email for the lease renewal"
  • "Save this to my iCloud Drive in Claude/drops"
```

### Idempotency contract

Re-running `/apple-services-setup` is always safe:
- Step 1: pure check.
- Step 2: skipped if binary hash matches.
- Step 3: pure check.
- Step 4: no prompt if already granted.
- Step 5: no prompt if already granted.
- Step 6: always runs.
- Step 7: always runs.

---

## Error handling

### Uniform error envelope

Every skill surface emits errors in one shape:

```json
{
  "error": {
    "code": "TCC_DENIED" | "NOT_FOUND" | "INVALID_ARG" | "UNAVAILABLE" | "INTERNAL",
    "service": "calendar" | "reminders" | "contacts" | "notes" | "mail" | "icloud",
    "message": "Human-readable description.",
    "recovery": "Short instruction."
  }
}
```

### Error code taxonomy

| Code | Meaning | Example |
|---|---|---|
| `TCC_DENIED` | macOS permission revoked or never granted | Calendar access toggled off in System Settings |
| `NOT_FOUND` | Object with given ID doesn't exist | `get_event` with a stale ID |
| `INVALID_ARG` | Input validation failed | `create_event` with `end` before `start` |
| `UNAVAILABLE` | Service reachable but not responsive | Mail.app in first-run wizard; `.icloud` placeholder |
| `INTERNAL` | Unexpected failure | Swift helper crashed, `osascript` unparseable output |

### Permission denial recovery

Apple has no OAuth tokens; TCC grant revocation is the functional equivalent of "auth expired." Every SKILL.md includes this section verbatim (customized per service):

```
## Handling permission denial

If a call fails with error code `TCC_DENIED`, macOS has either revoked
access or never granted it. Tell the user:

  "macOS says I don't have access to your [Calendar]. You can fix this
   two ways:
     1. Run /apple-services-setup and walk through the permission
        step again.
     2. Open System Settings → Privacy & Security → Calendars,
        and make sure 'apple-helper' is turned on.
   Let me know when that's done and I'll retry."

Do not retry automatically. Wait for the user to confirm, then resume.
```

### Binary-update re-prompt risk

Ad-hoc-signed binaries can invalidate TCC grants when the binary hash changes (Phase 0 R7 verifies). Mitigations:

1. **Consistent signing identity + entitlements** to maximize grant persistence.
2. **Version probe in wrapper** — `apple-helper-wrapper.sh` checks `apple-helper --version` against expected value; on mismatch, runs a permission probe. If the probe fails, emits `TCC_DENIED` with recovery pointing to `/apple-services-setup` instead of silently re-prompting.
3. **Accepted fallback** — if consistent identity doesn't preserve grants, we document as known minor friction (users see "macOS re-asked for Calendar access" once per update, click Allow, move on).

### AppleScript-specific failure modes

| Failure | Detection | Mapped to |
|---|---|---|
| Target app not installed | `osascript` error "Application isn't running" | `UNAVAILABLE` |
| Target app stuck in setup wizard | 30s wrapper timeout | `UNAVAILABLE` |
| Scripting command not on this macOS | `osascript` error -10000 | `INTERNAL` |
| Automation permission denied | `osascript` error -1743 | `TCC_DENIED` |

**macOS version floor:** 13.0 (Ventura). AppleScript vocabulary pinned to what's stable on 13+.

### iCloud Drive edge cases

- **`.icloud` placeholder files** — detected by extension; `read` returns `UNAVAILABLE` with recovery: "This file is in iCloud but not downloaded locally. Open Finder, right-click, Download Now, then retry."
- **Offline / sync paused** — no special handling; reads return what's on disk, writes succeed locally.
- **Files > 2 GB** — no streaming support in v1.

### Helper binary missing or corrupted

Wrapper verifies binary exists and is executable before each call. On mismatch, emits `UNAVAILABLE` with recovery: "Run /apple-services-setup to install the helper."

### Explicit non-behaviors

- **No automatic retries** — `TCC_DENIED` and `UNAVAILABLE` are user-fixable.
- **No silent degradation** — failures surface loudly; downstream plugins choose their own fallbacks.
- **No cross-service fallback** — skills are independent.

---

## Migration from youcoded-inbox

The `youcoded-inbox` skill already has working AppleScript providers for Notes, Reminders, and iCloud Drive (`wecoded-marketplace/youcoded-inbox/skills/claudes-inbox/providers/`). These are **inbox-specific** (watched-folder reads with same-day re-presentation guards), not general-purpose CRUD.

**v1 decision: parallel implementation, no changes to inbox.** Apple Services ships independently.

### Rationale

1. Inbox providers are stable and carry inbox-specific logic (re-presentation guards).
2. No config migration needed — inbox's `inbox_provider_config.*` keys in `~/.claude/toolkit-state/config.json` remain authoritative for inbox behavior.
3. Skill matcher routing naturally disambiguates utterances.
4. Consolidation into a shared library is premature — no evidence of drift damage and the marketplace has no cross-plugin dependency mechanism.

### Cross-references added

**In `youcoded-inbox/.../providers/apple-notes.md` (and `apple-reminders.md`, `icloud-drive.md`):**
```markdown
> For general-purpose Notes operations (search, CRUD across folders), see
> the apple-services marketplace bundle's `apple-notes` skill. This provider
> is inbox-specific and includes re-presentation logic the general-purpose
> skill does not.
```

**In `apple-services/skills/apple-notes/SKILL.md` (and siblings):**
```markdown
> For inbox-style watched-folder reading with same-day re-presentation
> guards, see the youcoded-inbox bundle. This skill is general-purpose
> and does not track "already shown today" state.
```

### Documented for future consolidation

`docs/DEV-VERIFICATION.md` contains a "Known overlap with youcoded-inbox" section listing:
- The three overlapping provider files.
- The architectural rationale for keeping them separate.
- Criteria that would justify consolidation: both growing similar bugs, a third consumer appearing, plugin-to-plugin deps becoming supported.

### What we don't do

- No migration script — nothing moves on disk.
- No deprecation of inbox providers.
- No shared-library extraction.
- No changes to inbox's config namespace.

---

## Attribution + vendored-code tracking

Cross-cutting mechanism (schema field, drift-check script, author nudges, CI enforcement) is defined in **Spec B** (`2026-04-17-marketplace-attributions-design.md`, to be written as a follow-up). This section defines Apple Services' specific content within that infrastructure.

### Attribution entries in `plugin.json`

```json
{
  "id": "apple-services",
  "name": "Apple Services",
  "attributions": [
    {
      "name": "iMCP",
      "url": "https://github.com/loopwork/iMCP",
      "license": "Apache-2.0",
      "scope": "Swift service modules for Calendar, Reminders, Contacts"
    },
    {
      "name": "apple-mcp",
      "url": "https://github.com/Dhravya/apple-mcp",
      "license": "MIT",
      "scope": "AppleScript snippets for Notes and Mail"
    },
    {
      "name": "Reminders-CLI",
      "url": "https://github.com/keith/Reminders-CLI",
      "license": "MIT",
      "scope": "Reference implementation for Reminders CLI surface and argument parsing"
    }
  ]
}
```

Additional entries added if Phase 0 turns up other useful borrows.

### `VENDORED.md` contents

At `wecoded-marketplace/apple-services/VENDORED.md`:

| File | Source repo | Upstream path | SHA pulled | License | Last pulled |
|---|---|---|---|---|---|
| `helper/Sources/FromIMCP/CalendarService.swift` | `loopwork/iMCP` | `Sources/iMCPServer/Services/CalendarService.swift` | *filled Phase 1* | Apache-2.0 | 2026-04-17 |
| `helper/Sources/FromIMCP/RemindersService.swift` | `loopwork/iMCP` | `Sources/iMCPServer/Services/RemindersService.swift` | *filled Phase 1* | Apache-2.0 | 2026-04-17 |
| `helper/Sources/FromIMCP/ContactsService.swift` | `loopwork/iMCP` | `Sources/iMCPServer/Services/ContactsService.swift` | *filled Phase 1* | Apache-2.0 | 2026-04-17 |
| `applescript/notes/*.applescript` | `Dhravya/apple-mcp` | *paths confirmed by Phase 0 R5* | *filled Phase 1* | MIT | 2026-04-17 |
| `applescript/mail/*.applescript` | `Dhravya/apple-mcp` | *paths confirmed by Phase 0 R5* | *filled Phase 1* | MIT | 2026-04-17 |

### `NOTICE.md` contents

License texts for every source in the `attributions` array, per Apache-2.0 and MIT requirements. Full license text reproduced, not just URL.

### Coordination with Spec B

Neither spec blocks the other's PR:

| Apple Services state | Spec B state | Result |
|---|---|---|
| Manifest has `attributions` field | Schema doesn't validate it yet | Field silently present but not rendered |
| Manifest has `attributions` field | Schema validates, UI renders | Full UX |
| No `attributions` field | Schema requires it when VENDORED.md exists | CI blocks Apple Services PR |

**Sequencing rule:** Spec B ships schema + UI as **optional** first; Apple Services lands with `attributions` populated; Spec B's follow-up PR makes the field required where VENDORED.md exists.

### Apple Services does not define

- `attributions` JSON schema shape (Spec B).
- `VENDORED.md` table format spec (Spec B).
- `scripts/check-upstream-drift.sh` (Spec B, shared).
- `/release` and `/feature` author-side nudges (Spec B).
- `validate-plugin-pr.yml` CI enforcement (Spec B).

---

## Phase 0 research items

Each item: question, resolution method, fallback. BLOCKING items must resolve before Phase 1 begins. Resolved in parallel subagents; each produces a findings file at `docs/superpowers/plans/research/2026-04-17-apple-<topic>.md`. Empirical waits over 1 hour are skipped per Google Services precedent.

### Cluster 1 — Borrowed-code audit (BLOCKING)

**R1. License verification.** Confirm iMCP (Apache-2.0 expected), Dhravya/apple-mcp (MIT expected), Reminders-CLI (MIT expected) by reading `LICENSE` at `HEAD`. **Fallback:** if copyleft, treat as reference only, rewrite (~2 extra days).

**R2. iMCP module extractability.** Read `Package.swift` and trace imports in Calendar/Reminders/Contacts service files. **Fallback:** extract larger subtree, or reimplement using iMCP as reference.

**R3. iMCP coverage vs our needs.** Map iMCP's exposed functions against Section 2 operation list. Produce coverage matrix. **Fallback:** write uncovered ops from Apple docs.

**R4. Does iMCP cover Notes or Mail?** Search iMCP's `Sources/`. **Fallback:** if absent, stay with AppleScript; if present, compare and choose.

**R5. Dhravya AppleScript inventory.** Enumerate `.applescript` / `.scpt` files in the repo. **Fallback:** write from scratch (~1 extra day).

**R6. iMCP per-module minimum macOS.** Inspect `@available` annotations; cross-check EventKit/Contacts API availability. **Fallback:** fork and rewrite calls that require macOS 15.3+.

### Cluster 2 — TCC behavior (BLOCKING)

**R7. TCC re-prompt on ad-hoc binary update.** Build two binaries with trivial differences; install sequentially; observe. ~1 hour. **Fallback:** document as known friction.

**R8. TCC attribution display string.** Build test helper; screenshot `requestFullAccessToEvents` prompt. Experiment with `CFBundleDisplayName` in embedded Info.plist. **Fallback:** whatever prompt says → pre-framed in setup copy.

**R9. AppleScript Automation permission scope.** Apple TCC docs + empirical test from Claude Code. **Fallback:** walkthrough copy adjusted to actual parent-process semantics.

**R10. `osascript` error code stability.** Apple Technical Note TN2167 + macOS-version-specific SO threads. **Fallback:** wrapper parses error text as well as numeric code.

### Cluster 3 — macOS API compatibility

**R11. `requestFullAccessToEvents` on macOS 13 (BLOCKING).** EventKit release notes + header `@available`. **Fallback:** version-branch the call (`if #available(macOS 14, *)`) or bump floor.

**R12. Swift version target (BLOCKING).** Check iMCP's `Package.swift` and `macos-latest` runner Swift version. **Fallback:** pin explicit Swift toolchain in CI.

**R13. Universal binary build recipe (non-blocking, needs answer before CI work).** SwiftPM + `lipo` — straightforward per Apple docs. **Fallback:** if SwiftPM cross-arch build produces surprises, build separate arm64 and x86_64 binaries in parallel matrix jobs and `lipo`-combine in a merge job.

### Cluster 4 — Runtime edge cases (non-blocking)

**R14. `.icloud` placeholder detection.** Apple `FileProvider` docs + empirical. **Fallback:** surface raw filesystem error.

**R15. Mail.app first-run detection.** AppleScript `name of window 1 of application "Mail"` comparison. **Fallback:** stick with timeout + generic message.

**R16. Contacts framework vs AppleScript Contacts independence.** Apple Contacts docs + empirical. **Fallback:** if linked, one fewer prompt; if separate, walkthrough already handles it.

### Time budget

Half a day to one day of parallel subagent work plus ~2 hours of human review. Any unfavorable BLOCKING finding triggers spec revision before Phase 1.

---

## Testing strategy

Three layers, matching Google Services.

### Layer 1 — Automated CI

Runs on `macos-latest` on every PR:

- Swift helper unit tests: argument parsing, JSON encoding, error envelope shape, TCC marker emission (pure logic, no EventKit).
- `shellcheck` over all `.sh` files.
- `osascript -s o` syntax check on all `.applescript` files.
- `plugin.json` schema validation via `validate-plugin-pr.yml`.
- `VENDORED.md` format check (defined in Spec B, consumed here).
- Universal binary sanity: `lipo -info` confirms both slices present.

Excluded from CI: TCC grants, real Apple accounts, app launches.

### Layer 2 — Shipped smoke probes

The step-6 probes in `/apple-services-setup`. Read-only per integration. Run at first install and every re-run. Catch: binary missing/corrupt, permissions revoked, target app broken.

### Layer 3 — Dev-time round-trip (`docs/DEV-VERIFICATION.md`)

Human checklist, not shipped. Executed before each release tag. Structure:

**Section A — Fresh install.** Reset TCC (`tccutil reset All`), uninstall helper, run setup from scratch, verify all 7 steps, verify smoke probes, re-run for idempotency.

**Section B — Per-integration CRUD round-trip.** For each integration: create → get → update → search → delete, with a human confirming visible changes in the relevant Apple app.

**Section C — Permission denial recovery.** Grant everything, revoke in System Settings, attempt op, verify `TCC_DENIED` surfaces correctly, verify Claude's recovery copy, re-grant, verify op resumes.

**Section D — Binary-update behavior.** Install v1, grant permissions, swap binary for v1.0.0+1, attempt ops, record whether macOS re-prompts. Informs release notes.

**Section E — Edge cases.** `.icloud` placeholder, Mail first-run, Contacts without "My Card", unicode names, empty states.

**Section F — Coexistence with youcoded-inbox.** Inbox + Apple Services installed side by side, both work.

### Phase 4 is human-only

Matching Google Services: **Phase 4 is explicitly NOT delegated to subagents.** Round-trip tests, permission prompts, and binary-update behavior require a real human at a real Mac with real Apple accounts. Phase 4's "tasks" are walkthrough steps from `DEV-VERIFICATION.md`, each with an expected outcome. Estimated time: ~2–3 hours concentrated.

### Regression-risk triage

| Subsystem | Blast radius |
|---|---|
| Shared wrappers | All 6 integrations — highest priority |
| Setup command | Blocks all new users |
| Swift helper | Calendar/Reminders/Contacts only |
| AppleScript for a service | That one service |
| iCloud Drive filesystem | iCloud Drive only |

**Shared-wrapper changes are never "just a hotfix" — always full DEV-VERIFICATION before tagging.**

---

## Implementation phases (overview)

Detailed task-level plan lives in the implementation plan (`docs/superpowers/plans/2026-04-17-apple-services-implementation.md`, to be written next via superpowers:writing-plans).

**Phase 0 — Research.** 16 items above, parallel subagents, findings files.
**Phase 1 — Vendor + Swift helper.** Pull iMCP modules, pull Dhravya AppleScript, write CLI plumbing, universal binary build in CI.
**Phase 2 — Skills + wrappers.** Six SKILL.md files, shared wrappers, error envelope, setup command, smoke probes.
**Phase 3 — Marketplace wiring.** `plugin.json`, `attributions` populated, `VENDORED.md`, `NOTICE.md`, registry entries.
**Phase 4 — Human DEV-VERIFICATION.** The 3-hour human pass.
**Phase 5 — Release.** Tag helper binary release, submit marketplace PR.

---

## Out of scope (documented)

- **Shortcuts.app bridge** — v1.x.
- **Meeting-attendee invitations** — v1.x.
- **Mail rules and signatures management** — no demand signal.
- **Contact photo editing** — read-only via `image_data`.
- **`brctl` force-sync** for iCloud Drive — v1.x if demand emerges.
- **Multiple Apple IDs** — single-account v1.
- **Background daemons** — every call one-shot.
- **Developer-ID signing and notarization (Path B)** — revisit whenever YouCoded desktop's .dmg gets signed; helper moves into `YouCoded.app/Contents/Resources/` at that point.
- **Linux / Windows parity** — macOS-only by nature.

---

## Open items parked for later iteration

- **Consolidation of youcoded-inbox's AppleScript providers with apple-services skills.** Criteria for revisiting in Section 5.
- **Shared-lib pattern across plugins.** Blocks deeper consolidation; not yet needed.
- **TCC grant persistence across helper updates.** Depends on Phase 0 R7; may inform a signed-binary (Path B) upgrade later.
