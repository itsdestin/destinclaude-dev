# Apple Services Bundle — Design

**Status:** Draft — revised 2026-04-17 after design-review critique. Pending user review before transitioning to implementation plan.
**Created:** 2026-04-17
**Owner:** Destin
**Supersedes in scope:** the "Apple Services" section of `docs/superpowers/plans/2026-04-17-remaining-bundles-handoff.md`. That briefing's phased "3rd-party MCP → native Swift helper" recommendation is explicitly discarded; this spec evaluates the full option landscape fresh and commits to a different direction.
**Depends on:** `2026-04-17-marketplace-attributions-design.md` (to be written as a follow-up) for schema-field rendering and `VENDORED.md` validation. See Section 6 for coordination rules — neither PR blocks the other. Platform-gating (showing macOS-only plugins on non-Mac hosts with a disabled Install button + note) is also defined in Spec B — see "Platform gating" below.
**Research findings (to be produced):** `docs/superpowers/plans/research/2026-04-17-apple-*.md` — 9 items enumerated in Section 7.
**macOS floor:** 14.0 (Sonoma). Fixed up front to avoid `if #available(macOS 14, *)` branching and to keep iMCP's stock modules importable without a fork. Users on macOS 13 see a clear "requires macOS 14 or later" message from `/apple-services-setup` step 1.

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

**`apple-helper`** — small Swift CLI, distributed as a universal (arm64+x86_64) Mach-O binary. Ad-hoc signed (`codesign --sign -`), NOT notarized, NOT Developer-ID signed. Matches YouCoded desktop's current unsigned posture.

**Binary delivery — vendored in the plugin tree, copied to a stable path at setup.** CI builds the universal binary on `apple-helper-v*` tags and commits it to `bin/apple-helper` in the plugin repo. Marketplace sync picks it up like any other plugin file; no network round-trip at install time. `/apple-services-setup` copies the binary to `~/.apple-services/bin/apple-helper` (outside the plugin tree) so TCC grants survive plugin updates and reinstalls. See "Binary lifecycle" under Architecture for the full flow.

**AppleScript files** — vendored from open source (primarily `Dhravya/apple-mcp`) and adapted. Shipped in `applescript/` inside the plugin.

**Aggressive OSS borrowing policy** — substantial code is lifted from open source rather than written from scratch. Specifically:
- `loopwork/iMCP` — Swift service modules for Calendar, Reminders, Contacts (Apache-2.0 pending Phase 0 confirmation). The menu-bar-app packaging is discarded; the per-service modules are extracted and dropped into our CLI helper.
- `Dhravya/apple-mcp` — AppleScript snippets for Notes and Mail (MIT pending Phase 0 confirmation).
- `keith/Reminders-CLI` — Reference implementation for Reminders CLI surface and argument parsing (MIT pending Phase 0 confirmation).
- Apple's own EventKit and Contacts framework sample code as authoritative references.

Borrowed files are tracked in `VENDORED.md` (see Section 6). Upstream license terms are reproduced in `NOTICE.md`.

## Platform gating

Apple Services is macOS-only. The bundle still **appears** in the wecoded-marketplace listing on Linux and Windows — hiding it would confuse users who read about it elsewhere — but its Install button is disabled with a note reading "Only available on Mac."

This requires Spec B to add two fields to the plugin schema:

- `platforms: ["macos"]` — if present, the desktop app renders the card with a disabled Install button and the per-platform note. Absent field = installable everywhere (current default).
- Apple Services sets `platforms: ["macos"]` in its `plugin.json`.

If Spec B ships after Apple Services, the field is silently ignored on older desktop-app versions and the user who tries to install on Linux hits Step 1's `uname` check. That's acceptable degradation, not a blocker. Step 1 remains the belt-and-suspenders check regardless.

## TCC / permission strategy

Apple services have no OAuth tokens. Permission is managed by macOS's **TCC** (Transparency, Consent & Control) subsystem. Three distinct grants are involved:

| Grant | Scope | Granted to | Triggered by |
|---|---|---|---|
| Full Access — Calendars | EventKit read/write of calendars + events | `apple-helper` | `requestFullAccessToEvents` call in helper |
| Full Access — Reminders | EventKit read/write of reminders | `apple-helper` | `requestFullAccessToReminders` call in helper |
| Access — Contacts | Contacts framework read/write | `apple-helper` | `CNContactStore.requestAccess(for: .contacts)` |
| Automation — Notes | AppleScript control of Notes.app | parent process (see Phase 0 R3) | First `osascript` call to Notes |
| Automation — Mail | AppleScript control of Mail.app | parent process | First `osascript` call to Mail |

No TCC grants are needed for iCloud Drive (plain filesystem under user's home). No Full Disk Access is required for any op in scope.

**Recovery from revoked permissions** is handled uniformly via the `TCC_DENIED` error code (Section 4) — the user never runs a dedicated "reauth" command; `/apple-services-setup` is idempotent and doubles as the re-grant flow.

## User-facing language policy

Every string the user reads uses plain language. Internal code can use technical names (`apple-helper`, `osascript`, `EventKit`) because those are for us. The user never sees "CLI," "API," "framework," or "TCC" unless they see it on a macOS system dialog we can't control — in which case `/apple-services-setup` pre-frames what's about to appear.

Mirrors the Google Services policy exactly.

---

## Architecture

### Bundle layout

Swift source lives in a sibling dev repo (`itsdestin/apple-helper`) — **not** in the shipped plugin. The plugin tree contains only the prebuilt binary + shell glue + AppleScript assets. CI in the sibling repo builds on `apple-helper-v*` tags and opens a PR against the marketplace repo that updates `bin/apple-helper` + `bin/apple-helper.sha256` in the plugin tree. Reviewing the PR is the gate.

```
wecoded-marketplace/apple-services/
  plugin.json                          # v0.1.0, platforms: ["macos"]
  VENDORED.md                          # per-file attribution tracking
  NOTICE.md                            # license texts for borrowed code

  commands/
    apple-services-setup.md            # /apple-services-setup slash command

  skills/                              # umbrella + focused per-op skills,
                                       # matching google-services pattern
    apple-calendar/SKILL.md            # umbrella (describes the surface)
    apple-calendar-agenda/SKILL.md     # focused: "what's on my calendar"
    apple-calendar-create/SKILL.md     # focused: create event
    apple-reminders/SKILL.md
    apple-reminders-add/SKILL.md
    apple-reminders-list/SKILL.md
    apple-contacts/SKILL.md
    apple-contacts-find/SKILL.md
    apple-notes/SKILL.md
    apple-notes-search/SKILL.md
    apple-notes-write/SKILL.md
    apple-mail/SKILL.md
    apple-mail-send/SKILL.md
    apple-mail-search/SKILL.md
    icloud-drive/SKILL.md

  lib/
    apple-wrapper.sh                   # single wrapper: dispatches to helper
                                       # binary or osascript by --backend flag

  bin/
    apple-helper                       # universal Mach-O, committed to git
                                       # by CI on apple-helper-v* tags
    apple-helper.sha256                # expected hash; setup verifies

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
    permissions-walkthrough.md         # TCC walkthrough content (shown by setup)

  .dev/                                # excluded from marketplace sync
    DEV-VERIFICATION.md                # round-trip checklist
```

### Binary lifecycle

1. **Build** — developer tags `apple-helper-vX.Y.Z` in `itsdestin/apple-helper`. CI builds universal binary on `macos-latest` via `swift build -c release` + `lipo`, ad-hoc signs (`codesign --sign -`), emits SHA256.
2. **Vendor** — CI opens a PR against `wecoded-marketplace` updating `apple-services/bin/apple-helper` + `.sha256`. PR description includes the upstream tag, the binary size, and the SHA.
3. **Distribute** — merging the PR ships the new binary via the normal marketplace sync. No separate GitHub release is needed on the marketplace side.
4. **Install at setup time** — `/apple-services-setup` copies `<plugin>/bin/apple-helper` to `~/.apple-services/bin/apple-helper` (stable, plugin-independent path), strips the quarantine xattr, and verifies SHA256. The wrapper script always invokes the copied binary, never the plugin-tree binary.

### Why the stable path

TCC grants are keyed to (code-sign identity, binary path) for ad-hoc-signed binaries. The plugin directory path is NOT stable: `~/.claude/plugins/marketplaces/youcoded/plugins/apple-services/` can change across Claude Code versions, plugin reinstalls, or marketplace-sync migrations. Copying to `~/.apple-services/bin/apple-helper` — a path this bundle controls — means TCC grants persist across plugin updates and reinstalls, so users re-grant only when we genuinely change the binary (see R3 below).

On re-setup, the copy is skipped if `~/.apple-services/bin/apple-helper` already exists and its SHA256 matches `bin/apple-helper.sha256` from the current plugin tree.

### Binary invocation shape

Skills do not call `osascript` or `apple-helper` directly — they go through a single wrapper `lib/apple-wrapper.sh`. The wrapper's own CLI is uniform across backings; it decides internally whether to shell out to the Swift helper or to `osascript`:

```bash
apple-wrapper.sh calendar list_calendars
apple-wrapper.sh calendar list_events --from 2026-04-17 --to 2026-04-24
apple-wrapper.sh calendar create_event --title "Meeting" --start 2026-04-17T14:00 --end 2026-04-17T15:00
apple-wrapper.sh reminders list_reminders --list "Today" --incomplete-only
apple-wrapper.sh notes search_notes --query "tahoe" --folder "Trips"
apple-wrapper.sh mail search --query "lease renewal" --limit 10
```

**CLI verb mapping is 1:1 with op names, snake_case.** Every op in the per-integration tables below (`list_calendars`, `create_event`, `list_reminders`, `search_notes`, `send`, etc.) is invokable as `apple-wrapper.sh <integration> <op> [args]`. No separate translation layer, no verb aliasing. Skills call `apple-wrapper.sh` with the same op name the tables document.

**Routing inside the wrapper:**

| Integration | Backend | Shell action |
|---|---|---|
| calendar, reminders, contacts | Swift helper | `exec ~/.apple-services/bin/apple-helper <integration> <op> ...` |
| notes, mail | AppleScript | `exec osascript "$PLUGIN_DIR/applescript/<integration>/<op>.applescript" ...args` |
| icloud | Filesystem | Pure bash (no shell-out) |

**Output contract** (identical across backends):
- Success: JSON array or object to stdout, exit code 0.
- Failure: JSON error envelope (Section 4) to stderr, nonzero exit code.
- TCC permission denied: exit code 2, stderr contains `TCC_DENIED:<service>` marker (modeled on Google Services' `AUTH_EXPIRED:<service>`).
- Stdout is always clean on success — no log chatter. Diagnostics go to stderr.

### Wrapper responsibilities

`lib/apple-wrapper.sh`:
- Looks up the integration→backend mapping above.
- For Swift-helper ops: locates binary at `~/.apple-services/bin/apple-helper` (override: `$APPLE_HELPER_BIN`); emits `UNAVAILABLE` with a pointer to `/apple-services-setup` if missing or non-executable.
- For AppleScript ops: resolves `$PLUGIN_DIR/applescript/<integration>/<op>.applescript`, passes positional args via `osascript ... -- arg1 arg2` (received as `on run argv` in the script), enforces per-op timeout (see below), catches error -1743 → emits `TCC_DENIED:<service>`.
- For iCloud ops: resolves path against `~/Library/Mobile Documents/com~apple~CloudDocs/`, rejects paths escaping that root, handles `.icloud` placeholders (returns `UNAVAILABLE`, never reads the stub).
- Normalizes all backend output to the uniform error envelope + JSON success shape.

**Per-op timeout** (not a single blanket value):
- Setup probes (step 6): 10 s.
- Read-mostly ops (`list_*`, `get_*`): 15 s.
- Search ops: 60 s (Mail searches on large mailboxes can legitimately take 30+ s).
- Write ops (`create_*`, `update_*`, `delete_*`, `send`): 20 s.

**Concurrency:** the wrapper acquires a per-target-app file lock (`flock` on `$TMPDIR/apple-services.<integration>.lock`) for Notes and Mail so two concurrent skill calls don't fight over the same `osascript` target. EventKit/Contacts ops via the Swift helper are thread-safe at the Apple API level; no lock needed.

### Non-goals at the architecture layer

- **No caching.** Each call hits live Apple services.
- **No daemon or server.** The helper is a one-shot CLI; exits after each invocation.
- **No background sync.** iCloud Drive reads show what's local; nothing more.
- **No cross-account.** Single Apple ID, matching Google Services v1.

---

## Per-integration operation surfaces

Each *operation* below is contractual — parameters and return shapes define what Claude sees.

**Skill granularity follows the Google Services pattern: one umbrella SKILL per integration plus focused per-op skills for the common operations.** The umbrella SKILL describes the full surface (useful when Claude needs to pick from many ops); the per-op skills give the Skill-tool matcher narrow, intent-specific descriptions for the high-traffic cases ("send an email," "add a reminder," "find a contact"). Umbrella + per-op skills dispatch to the same `apple-wrapper.sh` ops listed below — skills are routing/UX, ops are the contract.

Which ops get their own per-op skill is listed in the bundle layout's `skills/` tree above; the rest are reachable through the umbrella.

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

**Notes rich-content caveat:** Apple Notes stores rich HTML (images, drawings, tables, attachments). Markdown round-trips lose non-text content. `update_note` with `mode: replace` will destroy images, drawings, tables, and attachments in the target note. `append` and `prepend` preserve existing content and are the safe defaults for modifying a note Claude didn't originally create. The umbrella SKILL warns Claude about this; per-op skills for `update_note` default to `append`.

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

### Step 1 — Platform + version check

```bash
if [ "$(uname)" != "Darwin" ]; then
  echo "Apple Services only works on macOS — install on a Mac to use this bundle."
  exit 1
fi

# macOS floor: 14.0 (Sonoma). EventKit's Full Access APIs and iMCP service
# modules both require macOS 14+.
macos_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$macos_major" -lt 14 ]; then
  echo "Apple Services requires macOS 14 (Sonoma) or later. You're on $(sw_vers -productVersion)."
  echo "Update macOS from System Settings → General → Software Update, then re-run this."
  exit 1
fi
```

Spec B's marketplace-side `platforms: ["macos"]` gate handles the Linux/Windows case; these checks are belt-and-suspenders.

### Step 2 — Install the helper binary to a stable path

Universal binary ships inside the plugin at `$PLUGIN_DIR/bin/apple-helper` — no network fetch. Setup copies it to a stable, plugin-independent path so TCC grants persist across plugin updates:

```bash
install_dir="$HOME/.apple-services/bin"
mkdir -p "$install_dir"
cp "$PLUGIN_DIR/bin/apple-helper" "$install_dir/apple-helper"
xattr -d com.apple.quarantine "$install_dir/apple-helper" 2>/dev/null || true
chmod +x "$install_dir/apple-helper"

expected_sha=$(cat "$PLUGIN_DIR/bin/apple-helper.sha256")
actual_sha=$(shasum -a 256 "$install_dir/apple-helper" | cut -d' ' -f1)
[ "$expected_sha" = "$actual_sha" ] || { echo "Helper binary verification failed."; exit 1; }
```

**Idempotency:** if `$install_dir/apple-helper` exists and its SHA matches `bin/apple-helper.sha256`, the copy is skipped entirely (preserves TCC grants — no inode change).
**Pre-frame:** "Setting up a small tool that lets Claude talk to Calendar, Reminders, and Contacts. One-time, happens locally."
**Failure path:** SHA mismatch → emit "The bundled helper didn't match its checksum — your plugin install may be corrupted. Reinstall Apple Services from the marketplace and try again."

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
~/.apple-services/bin/apple-helper --request-permissions
```

The helper requests grants **serially** (awaits each dialog's result before triggering the next) so dialogs appear in a predictable order:

1. `EKEventStore().requestFullAccessToEvents { ... }`  (macOS 14 API; floor is 14 so no fallback needed)
2. `EKEventStore().requestFullAccessToReminders { ... }`
3. `CNContactStore().requestAccess(for: .contacts) { ... }`

**Pre-frame:** "macOS is about to show three permission dialogs, in this order: Calendar, then Reminders, then Contacts. Each will ask whether a tool called 'apple-helper' can access that data. Click **Allow** on all three."
**Failure path:** helper exits with `TCC_DENIED:<service>`. Setup emits "Looks like [Calendar] access was denied. Open System Settings → Privacy & Security → [Calendars], find 'apple-helper' in the list and turn it on. Then re-run `/apple-services-setup`."
**Display-name caveat:** the literal label in the TCC dialog is determined by `CFBundleDisplayName` in the binary's embedded Info.plist (Phase 0 R3). If the experiment lands on a different label, the pre-frame copy updates to match.
**Idempotency:** if grants already exist, `requestFullAccess*` returns immediately without re-prompting.

### Step 5 — Automation permissions for Notes and Mail

Trigger Automation prompts via trivial no-op scripts:

```bash
osascript -e 'tell application "Notes" to count notes'
osascript -e 'tell application "Mail" to count messages of inbox'
```

**Automation TCC scope:** the grant attaches to the *invoking* process, not to `osascript` itself. Which process that is depends on how Claude is running:

| Claude host | Invoking process seen by TCC | What the user sees in System Settings → Automation |
|---|---|---|
| YouCoded desktop (Electron) | The YouCoded app bundle | "YouCoded" → allow Notes / allow Mail |
| Claude Code CLI in Terminal.app | Terminal.app | "Terminal" → allow Notes / allow Mail |
| Claude Code CLI in iTerm2 | iTerm2 | "iTerm" → allow Notes / allow Mail |

Setup detects the parent context (`ps -o comm= -p $PPID` + check for YouCoded env vars) and substitutes the right app name into user-facing copy.

**Pre-frame (templated):** "macOS is about to ask if **{{host_app}}** can control Notes, then the same for Mail. Click **OK** on both prompts."
**Failure path:** denial → "Automation access was denied. Open System Settings → Privacy & Security → Automation → find **{{host_app}}** in the list and turn on the **Notes** (or **Mail**) toggle underneath it."
**Quirk:** if Mail isn't fully set up, `count messages of inbox` hangs. Run with 10 s timeout; emit "Mail isn't fully set up yet — open Mail.app, finish account setup, then re-run."

### Step 6 — Smoke test each integration

Read-only probes:

| Integration | Probe | Expected |
|---|---|---|
| Calendar | `apple-wrapper.sh calendar list_calendars` | ≥1 calendar |
| Reminders | `apple-wrapper.sh reminders list_lists` | ≥1 list |
| Contacts | `apple-wrapper.sh contacts list_groups` | ≥0 groups, no error |
| Notes | `apple-wrapper.sh notes list_folders` | ≥1 folder |
| Mail | `apple-wrapper.sh mail list_mailboxes` | ≥1 mailbox |
| iCloud Drive | `apple-wrapper.sh icloud list --path ""` | directory enumerable |

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

Ad-hoc-signed binaries can invalidate TCC grants when the binary hash changes (Phase 0 R3 verifies). Mitigations:

1. **Consistent signing identity + entitlements** to maximize grant persistence.
2. **Version probe in wrapper** — `apple-wrapper.sh` checks `apple-helper --version` against the value in `bin/apple-helper.sha256` metadata; on mismatch, runs a permission probe. If the probe fails, emits `TCC_DENIED` with recovery pointing to `/apple-services-setup` instead of silently re-prompting.
3. **Accepted fallback** — if consistent identity doesn't preserve grants, we document as known minor friction (users see "macOS re-asked for Calendar access" once per update, click Allow, move on).

### AppleScript-specific failure modes

| Failure | Detection | Mapped to |
|---|---|---|
| Target app not installed | `osascript` error "Application isn't running" | `UNAVAILABLE` |
| Target app stuck in setup wizard | 30s wrapper timeout | `UNAVAILABLE` |
| Scripting command not on this macOS | `osascript` error -10000 | `INTERNAL` |
| Automation permission denied | `osascript` error -1743 | `TCC_DENIED` |

**macOS version floor:** 14.0 (Sonoma). AppleScript vocabulary pinned to what's stable on 14+.

### iCloud Drive edge cases

- **`.icloud` placeholder files** — detected by extension; `read` returns `UNAVAILABLE` with recovery: "This file is in iCloud but not downloaded locally. Open Finder, right-click, Download Now, then retry."
- **Offline / sync paused** — no special handling; reads return what's on disk, writes succeed locally.
- **Files > 2 GB** — no streaming support in v1.

### Helper binary missing or corrupted

Wrapper verifies `~/.apple-services/bin/apple-helper` exists and is executable before each call. On missing or failing-to-exec, emits `UNAVAILABLE` with recovery: "Run /apple-services-setup to reinstall the helper."

On binary-update re-prompt (see R3): if `apple-helper --version` disagrees with the SHA in `bin/apple-helper.sha256`, the wrapper re-runs the copy-to-stable-path step automatically, then retries once. Only falls through to `TCC_DENIED` messaging if the retry also fails.

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
  "name": "apple-services",
  "description": "Calendar, Reminders, Contacts, Notes, Mail, and iCloud Drive in one setup. macOS only.",
  "version": "0.1.0",
  "author": { "name": "YouCoded" },
  "license": "MIT",
  "platforms": ["macos"],
  "attributions": [
    {
      "name": "iMCP",
      "url": "https://github.com/loopwork/iMCP",
      "license": "Apache-2.0",
      "scope": "Swift service modules (Calendar, Reminders, Contacts) compiled into bin/apple-helper"
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
| `bin/apple-helper` (universal Mach-O, built from `itsdestin/apple-helper` Swift sources; service modules vendored from `loopwork/iMCP`) | `loopwork/iMCP` | `Sources/iMCPServer/Services/{Calendar,Reminders,Contacts}Service.swift` | *filled Phase 1* | Apache-2.0 | 2026-04-17 |

*Note: Swift sources live in the sibling `itsdestin/apple-helper` dev repo. The marketplace plugin tree ships only the prebuilt binary; attribution and SHA tracking follow the binary into this repo. `itsdestin/apple-helper/VENDORED.md` tracks the upstream file-level SHAs for the iMCP modules that compose the binary.*
| `applescript/notes/*.applescript` | `Dhravya/apple-mcp` | *paths confirmed by Phase 0 R4* | *filled Phase 1* | MIT | 2026-04-17 |
| `applescript/mail/*.applescript` | `Dhravya/apple-mcp` | *paths confirmed by Phase 0 R4* | *filled Phase 1* | MIT | 2026-04-17 |

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

9 items, down from an earlier 16. Consolidations: the three iMCP sub-questions (extractability, op coverage, Notes/Mail coverage) collapse into one audit; TCC display-string + TCC re-prompt + Automation parent-process land in one TCC-behavior item; osascript error-code stability and Mail.app first-run detection fold into one AppleScript-quirks item.

### Cluster 1 — Borrowed-code audit (BLOCKING)

**R1. License verification.** Confirm iMCP (Apache-2.0 expected), Dhravya/apple-mcp (MIT expected), Reminders-CLI (MIT expected) by reading `LICENSE` at `HEAD`. **Fallback:** if copyleft, treat as reference only, rewrite (~2 extra days).

**R2. iMCP audit — extractability + coverage + scope.** Single audit covering: (a) can Calendar/Reminders/Contacts service modules compile outside iMCP's menu-bar host (read `Package.swift`, trace imports); (b) coverage matrix against Section 2's op list; (c) does iMCP also cover Notes or Mail (search `Sources/`). **Fallback:** uncovered ops written from Apple docs; Notes/Mail stay on AppleScript if iMCP doesn't cover them.

**R3. TCC behavior (empirical, ~2 hours).** Three sub-questions, one test session on a fresh macOS 14+ VM or `tccutil reset`-ed host: (i) display-string experiment — does `CFBundleDisplayName` in an embedded Info.plist control the dialog label? (ii) re-prompt on ad-hoc binary update — build v1, grant, replace binary with trivially-different v1.0.0+1 at the same path, observe whether macOS re-prompts; (iii) Automation scope confirmation — verify the parent-process attribution table in Step 5 matches reality from YouCoded desktop and from Terminal. **Fallback:** whatever the dialog says becomes the pre-frame copy; re-prompt becomes documented friction if unavoidable; parent-process copy adjusts per observed attribution.

**R4. Dhravya AppleScript inventory.** Enumerate `.applescript` / `.scpt` files and per-file license notices in `Dhravya/apple-mcp`. Map files against the Section 2 Notes + Mail ops. **Fallback:** write from scratch (~1 extra day).

### Cluster 2 — macOS API compatibility (BLOCKING)

**R5. iMCP per-module API availability vs macOS 14 floor.** Inspect `@available` on every service function we plan to call. Any `@available(macOS 15, *)` or later usage forces either a fork + rewrite or a floor bump. **Fallback:** fork the offending service module and implement against the macOS 14 API shape.

**R6. Swift version target + universal binary recipe.** Confirm iMCP's declared `swift-tools-version` works on whatever Swift ships with `macos-latest` GitHub-hosted runners. Confirm SwiftPM `-arch arm64 -arch x86_64` produces a universal Mach-O without post-processing, or whether a per-arch matrix + `lipo` merge is needed. **Fallback:** parallel arm64/x86_64 matrix jobs + `lipo -create` in a merge job.

### Cluster 3 — AppleScript + runtime quirks (non-blocking)

**R7. AppleScript error-code + first-run-detection spot-check.** Confirm error -1743 (Automation denial) and error -1728 ("Can't get object") surface from current macOS (14+) `osascript`. Spot-check whether `name of window 1 of application "Mail"` is a reliable first-run indicator. **Fallback:** wrapper parses error text as well as numeric code; stick with timeout + generic "Mail isn't fully set up" message.

**R8. `.icloud` placeholder detection.** Enumerate a directory with un-downloaded iCloud files; confirm entries appear as `.Filename.icloud` dot-prefixed files. Confirm `ls -a` / `readdir` surfaces them. **Fallback:** surface raw filesystem error; document as known edge.

**R9. Contacts framework vs AppleScript Contacts TCC independence.** Does granting Contacts access to the Swift helper also satisfy AppleScript `tell application "Contacts"`, or are they independent grants? (We don't use AppleScript for Contacts in v1, but this affects whether the inbox bundle's AppleScript Contacts usage would benefit from Apple Services grants.) **Fallback:** documented, no v1 behavioral change.

### Time budget

1.5–2 days of parallel subagent work plus ~2 hours of human review. R3 alone consumes ~2 hours of wall-clock because TCC state caches between attempts and requires `tccutil reset` + re-grant between experiments. Any unfavorable BLOCKING finding triggers spec revision before Phase 1.

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

**Phase 0 — Research.** 9 items above, parallel subagents, findings files.
**Phase 1 — Swift helper sibling repo.** Create `itsdestin/apple-helper`, pull iMCP modules, wire CLI plumbing + JSON output + TCC-denied marker, set up CI that builds universal binary on `apple-helper-v*` tags and opens a binary-update PR against `wecoded-marketplace`.
**Phase 2 — Plugin tree.** Pull Dhravya AppleScript, write `apple-wrapper.sh` (single wrapper, all three backends), umbrella + per-op SKILL.md files, `/apple-services-setup` command, smoke probes. First `apple-helper` build lands via a manual merged PR to bootstrap the vendoring loop.
**Phase 3 — Marketplace wiring.** `plugin.json` with `platforms: ["macos"]` and `attributions`, `VENDORED.md`, `NOTICE.md`, registry entries.
**Phase 4 — Human DEV-VERIFICATION.** The 3-hour human pass.
**Phase 5 — Release.** Tag `apple-helper-v0.1.0`, merge the auto-opened binary-update PR, then tag the marketplace plugin and submit the marketplace PR.

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
- **TCC grant persistence across helper updates.** Depends on Phase 0 R3; may inform a signed-binary (Path B) upgrade later.
