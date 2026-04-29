# Google Services — Multi-Account Support — Design

**Status:** Drafted; pending Destin's review.
**Created:** 2026-04-29
**Owner:** Destin
**Builds on:** [2026-04-16-google-services-design.md](2026-04-16-google-services-design.md). Adds multi-account support to the existing `google-services` marketplace plugin without breaking single-account installs.
**Research findings:** Upstream `gws` had multi-account in v0.6, removed it in v0.7 ([CHANGELOG `e1505af`](https://github.com/googleworkspace/cli)). Open issue #439 asks for it back; no maintainer plan. Two undocumented escape-hatch env vars enable safe per-account state isolation.

---

## Goal

Let a single YouCoded user connect multiple Google accounts (e.g., personal Gmail + work Workspace) and have Claude route each Google action to the right one without the user thinking about config files, profiles, or auth state.

The UX target: a default account is silently used for most things; the first action of any new conversation is confirmed in plain language ("Okay to send this from your personal account?"); Drive operations always re-confirm because uploading to the wrong Drive is high-stakes; and switching between accounts mid-conversation is natural ("use my work account for the next one").

## Non-goals (v1)

- **Move (delete-from-source) for cross-account transfers.** Copy-only ships. Move adds partial-failure surface that copy doesn't have.
- **Bulk migration.** Google Takeout exists for moving entire accounts.
- **Drive permission/sharing cloning across accounts.** Cross-account permission grants require the destination user to invite source-account collaborators by email — not something the skill can do silently.
- **Active-account state files.** No on-disk marker tracks which account the current conversation is using. Skill guidance + conversation memory handle it.

## Foundation

The escape hatches that make per-account state isolation safe:

- `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=<path>` — redirects every on-disk artifact (`client_secret.json`, `credentials.enc`, `token_cache.json`, `.encryption_key`, discovery cache, timezone cache) into the named directory. Source: `auth_commands.rs:311-336` in upstream gws.
- `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` — bypasses the OS keyring (Windows Credential Manager / macOS Keychain / Linux Secret Service) entirely. The AES-256-GCM encryption key for `credentials.enc` lives in `<config_dir>/.encryption_key` instead.

**Both env vars are required.** `CONFIG_DIR` alone is insufficient: gws's keyring entry uses fixed strings (`service="gws-cli"`, `user=$USERNAME`) regardless of config dir, so a second `gws auth login` would overwrite the first account's encryption key in Windows Credential Manager and brick the first account's `credentials.enc`. Setting `KEYRING_BACKEND=file` moves the key into the per-account directory and isolates the AES key alongside the encrypted blob.

Verified locally on 2026-04-28: setting both env vars against an empty test directory caused `gws auth status` to report all paths under that directory and `keyring_backend: "file"`, confirming complete state redirection.

---

## Architecture

### Per-account config layout

```
~/.config/
  gws/                          # default account (existing single-account location)
    client_secret.json
    credentials.enc
    token_cache.json
    .encryption_key             # NEW (when keyring_backend=file is set)
  gws-work/                     # secondary account, name chosen by user
    client_secret.json          # copied from default's, same OAuth client
    credentials.enc
    token_cache.json
    .encryption_key
  gws-profiles.json             # registry — see below
```

**Backwards compatibility.** Existing single-account installs already live at `~/.config/gws/`. They become the v1 default with no migration: `gws-profiles.json` is created the first time there's any multi-account state worth persisting — either (a) the user collects "I might want to add later" emails during the mid-flow setup prompt, or (b) the user adds an actual second account. If neither happens, the registry never gets created and every gws-* skill falls back to the existing `~/.config/gws/` path. No flag day, no upgrade prompt.

The single-account fallback path also handles "registry exists but lists only one account" identically to "registry doesn't exist" — both cases skip the first-action confirmation. So a user who collects test users during initial setup but never adds a second account sees identical UX to one who declined the test-users prompt.

### Registry shape

`~/.config/gws-profiles.json` is the single source of truth for skills. Setup writes it; skills read it; reauth and remove update it.

```json
{
  "default": "personal",
  "accounts": [
    {
      "name": "personal",
      "email": "destinj101@gmail.com",
      "configDir": "~/.config/gws",
      "ownsGcpProject": true,
      "gcpProjectId": "youcoded-personal-lxsrip"
    },
    {
      "name": "work",
      "email": "destin@acme.com",
      "configDir": "~/.config/gws-work",
      "ownsGcpProject": false
    }
  ],
  "knownTestUsers": ["destin@acme.com", "school@university.edu"]
}
```

Fields:

- `default` — name of the account used when the user hasn't said otherwise. Always matches a `name` in `accounts`.
- `accounts[].name` — human-readable; what Claude calls it in confirmation prompts. Picked by the user during add-flow.
- `accounts[].email` — the Google account email the user signed in as. Surfaced in prompts to disambiguate similarly-named accounts.
- `accounts[].configDir` — absolute (or `~`-relative) path; what gets passed as `GOOGLE_WORKSPACE_CLI_CONFIG_DIR`.
- `accounts[].ownsGcpProject` — `true` when this account got its own GCP project (slow-path setup, e.g., locked-down workspace). `false` when it shares the default's OAuth client (fast-path).
- `accounts[].gcpProjectId` — present only when `ownsGcpProject: true`. Surfaced during remove flow so the user knows what's still in console.cloud.google.com.
- `knownTestUsers` — emails the user listed during initial setup as "may want to add later." Lets the add-account flow fast-path them without re-asking which path to take.

### Env-var routing

Every gws invocation through any skill prepends the same two env vars:

```bash
GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$config_dir" \
GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
gws ...
```

- Multi-account: `$config_dir` resolves to the active account's path from the registry.
- Single-account fallback (no registry file): `$config_dir` resolves to `~/.config/gws/` and the existing behavior is preserved verbatim.

**Keyring migration on upgrade.** Setting `KEYRING_BACKEND=file` against an existing single-account install whose AES key currently lives in Windows Credential Manager (or macOS Keychain / Linux Secret Service) is the migration moment. Two paths are acceptable, and the implementation chooses based on what `credential_store.rs:158-186` actually does:

- **If gws falls back to OS keyring transparently when `<config_dir>/.encryption_key` is missing:** silent migration — the env-var change alone is sufficient; the file gets populated on the next `gws auth login` (which happens within 7 days anyway via routine reauth). No upgrade prompt.
- **If gws fails on missing `.encryption_key`:** force one extra reauth on upgrade — the failed call's auth-error pattern triggers `youcoded-gws-reauth`, which runs `gws auth login` against the file backend, repopulates the blob and the key, and retries. The user sees one extra browser trip on first multi-account-aware launch.

Either path is acceptable. The "one extra browser trip on upgrade" UX is fine; reauth is the right primitive to handle it. No standalone migration helper is needed — the existing reauth skill is the migration helper. The implementation plan picks based on observed gws behavior.

---

## Setup flow

The existing `/google-services-setup` slash command is the single entry point — both for first-time setup and for ongoing management.

### First-time setup

The existing flow stays intact through the consent-screen creation step. Two new prompts get inserted:

**Mid-flow prompt (between consent-screen open and OAuth-client creation):**

After the user opens the OAuth consent screen page, the slash command pauses:

> "While you've got the consent screen open — do you plan to use any other Google accounts with YouCoded later (work, school, secondary)? Paste them now, one per line, and I'll have you add them all to Test Users at once. Or say 'just this one'."

Collected emails are saved to the registry's `knownTestUsers` field (the registry is created at this point if it doesn't exist; otherwise updated). The slash command then instructs the user to paste each email into the Test Users section.

**End-of-flow prompt (after primary account is signed in):**

After the existing smoke-test confirms the primary account works:

> "All set up. Want to add another account now? You already added [work@acme.com] to Test Users, so signing in is quick (~30 sec)."

If yes, run the add-account sub-flow (below) for each `knownTestUsers` email the user wants to add now. After all done, ask which account is the default.

If only the primary is signed in, no question — `default` is the primary's name.

### Add-account sub-flow

Used by both end-of-setup and ongoing management. Steps:

1. Ask the user for a name for this account ("work", "school", "consulting"). Suggest one based on the email's domain (e.g., everything before `@` for non-gmail.com domains, or the domain stem).
2. Look up the email in `knownTestUsers`:
   - **Already on the list:** copy `client_secret.json` from `~/.config/gws/` to `~/.config/gws-<name>/`. Run `gws auth login` against the new config dir with both env vars set. User signs in as that account in the browser. ~30 sec.
   - **Not on the list:** open Cloud Console to OAuth consent screen, instruct the user to add the email to Test Users, then proceed with the same copy-and-login. ~90 sec.
3. On consent failure (workspace blocks the OAuth client outright): offer the slow path — re-run the project-creation flow against the new account's own GCP project. ~10 min, always works. The new account's registry entry sets `ownsGcpProject: true`.
4. Update the registry: append the new account, do not change `default`.

### Re-running `/google-services-setup` when accounts already exist

The slash command detects an existing registry and opens a menu rather than re-running first-time setup:

> "You have 2 accounts set up: personal (default), work. What do you want to do?
> 1. Add another account
> 2. Remove an account
> 3. Change default
> 4. Refresh consent / fix something broken (re-run full setup against an account)"

This is the entry point for all ongoing account management. No separate `/gws-account` slash command is added — natural-language phrases ("add my work account", "switch default to personal") are routed by a new lightweight skill (see Skills section).

---

## In-conversation routing

The behavioral spec for how skills coordinate to give the user the right confirmation prompts. All of this is skill guidance — no on-disk active-account state.

### Where the protocol lives

`gws-shared/SKILL.md` (currently a reference doc for auth/flags/output) gets a new "Account selection" section that defines the canonical pattern. Every other `gws-*` skill (gmail, drive, sheets, calendar, etc.) gets a one-line preamble:

> *"Before invoking gws, follow the account-selection protocol in gws-shared."*

Single source of truth; skills don't duplicate the rules. When the protocol evolves (new prompt phrasing, new edge-case rule), it changes in one place.

### First gws action of a conversation

1. Read `~/.config/gws-profiles.json`.
   - If registry doesn't exist AND `~/.config/gws/credentials.enc` doesn't exist → zero-account state, see Zero-account fallback below.
   - If registry doesn't exist AND `~/.config/gws/credentials.enc` exists → single-account world; use `~/.config/gws/` directly, no question.
2. If registry exists with only one account → use it, no question.
3. If registry exists with multiple accounts → ask the user, default highlighted, action-aware phrasing:

   > "Okay to send this from your personal account (default)? Or use work?"

   Wording adapts to the action: "save this to," "send this from," "fetch this from," "search in." Never says "config dir," "profile," "account ID," "OAuth," or "credentials."

4. Once the user confirms, Claude carries the choice in conversation memory and routes every subsequent gws call against that account's `configDir` until either:
   - The user explicitly switches ("use my work account for the next one"), or
   - A Drive operation is requested (always re-confirms — see below).

### Drive operations — always re-confirm

Per spec, every direct user-initiated Drive operation re-confirms the account even if the conversation has an established active account:

> "Did you want that uploaded to your work account, or your personal one?"

Granularity: **per user-initiated Drive task**, not per API call. If the user says "upload these 5 files," that's one task → one confirm; the skill loops through 5 files using the chosen account without asking 5 times. If the user later says "upload one more," that's a new task → new confirm.

Operations covered: upload, download, locate/search, share, copy, move, delete, list-as-its-own-task. Internal `files.list` calls made as part of a larger task (e.g., recursing into a folder during transfer) inherit the task's chosen account and don't re-prompt.

### Cross-account in-conversation switching

When the user says "use my work account for the next one" or "send this from work instead," Claude updates its conversation-memory active account and routes the next call accordingly. No persistence — fresh conversations always start at the registry default again.

### Zero-account fallback

Any gws-* skill detecting no `~/.config/gws/credentials.enc` AND no registry (or a registry with empty `accounts`) falls back to:

> "You haven't connected a Google account yet — run /google-services-setup first."

The skill exits without invoking gws.

---

## Cross-account transfer skill

A new skill `gws-transfer` (`skills/gws-transfer/SKILL.md`) handles the three high-value cross-account scenarios. Single skill with runtime branching by resource type — keeps the surface small.

### What it handles in v1

1. **Drive copy** — file or folder, account A → account B. `files.get` (auth A, download to a temp file) + `files.create` (auth B, upload). Folders are recursive. Destination user becomes owner; original permissions/sharing don't transfer (target Google account doesn't know about source-account collaborators). Native types (Docs/Sheets/Slides) export via `files.export` and re-import; preserves content but not revision history.
2. **Gmail save** — copy a message or thread, account A → account B, via `users.messages.insert` (auth B). Preserves Subject/From/To/Date/body/attachments. Labels don't transfer (different label IDs across accounts); the skill optionally applies a target label like "from-work" if the user requests one.
3. **Calendar copy** — copy an event, account A → account B, via `events.insert` (auth B). Attendees, ACLs, and original organizer don't transfer (different attendee universes); the event becomes a new event owned by account B. Skill warns the user that attendees won't be notified.

### What it explicitly doesn't do in v1

- **Move** (copy + delete-from-source). Doubles failure surface. Copy-only ships; delete is a separate explicit user action.
- **Bulk transfer of an entire account.** Out of scope; Google Takeout exists.
- **Drive permission/share-link cloning.** Requires the target user to invite source collaborators by email — can't be done silently.

### UX shape

Triggered by phrases like "copy this work doc to personal Drive," "save this email to my personal account," "duplicate this work calendar event to personal." The skill always confirms both ends explicitly, with both account names bolded:

> "Copying [work-quarterly-plan.docx] from your **work** Drive to your **personal** Drive. Confirm?"

For transfers, both source and destination are explicit — Claude does NOT assume "the conversation's active account is the destination." Conversation memory of the active account is irrelevant to transfers.

After confirmation, the skill runs both gws invocations (each with its own env-var routing), reports success with the new resource's URL/ID.

### Failure handling

If the source read succeeds but the destination write fails, the skill reports clearly:

> "Read from work succeeded, but writing to personal failed: [error]. Nothing was changed in your work account."

No partial-state cleanup needed for copy-only.

### Long-running cases

Folder copies and large Drive uploads can take minutes. The skill streams progress ("Copied 12 of 47 files…") rather than blocking silently. Existing gws-* skills don't need this because their operations are individually fast; transfer is the one place batched progress matters.

---

## Remove-account flow

A new helper script `setup/remove-account.sh` plus the menu entry in `/google-services-setup`. Reachable via the menu and via the `gws-account-management` skill (natural-language routing).

### What removal does

1. Show the user a clear confirmation, distinguishing local connection from Google-side data:

   > "I'll sign out of work@acme.com and remove its YouCoded connection. Your data in Google itself stays untouched — emails, Drive files, calendars all remain in the account. Confirm?"

2. On confirm:
   - Run `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=<dir> GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file gws auth logout` (revokes the refresh token at Google's end so the saved credentials become useless even if local files weren't deleted).
   - Delete `~/.config/gws-<name>/` and everything in it.
   - Remove the account's entry from `~/.config/gws-profiles.json`.

3. **If the removed account was the default** and others remain:

   > "That was your default account. Which account should I default to now? (1) personal, (2) consulting"

   Update `default` in the registry.

4. **If the removed account was the only account** — registry file is deleted. State returns to "single-account world but no account configured." Setup must be re-run before any gws-* skill works again. Confirmation copy is sterner:

   > "This is your only Google account. Removing it means you'll need to run /google-services-setup before YouCoded can do anything Google-related again. Confirm?"

5. **If the removed account had its own GCP project** (`ownsGcpProject: true`) — the script does NOT touch the GCP project (billing-affecting Google asset). It surfaces a one-line note:

   > "Note: this account had its own Google Cloud project (`youcoded-work-x9a3b`). The local connection is gone, but the project still exists in console.cloud.google.com if you want to delete it there."

### Conversation-memory side-effect

If the user removes the account currently active in the conversation, Claude's in-memory active-account state is now stale. The `gws-account-management` skill instructs Claude to clear that state and (on the next gws action) treat it as the conversation's first action again. Single-account-remaining case skips the question.

### Failure handling

If `gws auth logout` fails (network issue, token already revoked at Google's end), the script proceeds with local cleanup anyway and surfaces a one-line note:

> "Couldn't reach Google to revoke the token (offline?), but I removed the local connection. The token will expire on its own."

The user's local state is consistent regardless of network state.

---

## Reauth (hybrid)

The existing `youcoded-gws-reauth` skill expands rather than getting replaced. Two behavioral changes from today.

### Per-account refresh (reactive primary)

When a gws-* skill invokes gws against an account's config dir and the call returns an auth-error pattern (`invalid_grant`, `invalid_token`, `token has been expired or revoked`, etc. — the existing trigger list), the skill surfaces the failure with the account name attached:

> "Auth failed for work account (work@acme.com)."

That gives `youcoded-gws-reauth` the routing context it needs.

The reauth helper `setup/reauth.sh` gets a `--config-dir` flag:

```bash
bash "$CLAUDE_PLUGIN_ROOT/setup/reauth.sh" --config-dir "$HOME/.config/gws-work"
```

Internally:

```bash
GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$config_dir" \
GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
gws auth login
```

Single-account fallback (no `--config-dir` flag passed): defaults to `~/.config/gws/` so existing single-account behavior is preserved verbatim.

User-facing copy includes the account name:

> "Your work Google connection needs a quick refresh — opening your browser."

After success, the original failing skill retries against the same config dir.

### Opportunistic top-up

Right after a successful refresh, the skill checks the other registered accounts' status before returning. The check is local (`gws auth status` per account, no network round-trip beyond what gws does to validate the token cache):

```bash
for account in <other accounts in registry>; do
  GOOGLE_WORKSPACE_CLI_CONFIG_DIR=<dir> GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
    gws auth status --format json
  # parse "token_valid"
done
```

If any other accounts have `token_valid: false`, the skill bundles them into one prompt:

> "Refreshed your work connection. Your personal connection is also expired — want me to refresh that too while we're here?"

If the user agrees, refresh each in turn (one browser trip per account). If they decline, carry on. Single-account installs skip this branch entirely.

### Edge cases (unchanged from today)

- User closes browser mid-flow → exit nonzero → existing copy: "Your Google connection didn't refresh. Run /google-services-setup if it keeps happening."
- Network down → reauth fails fast with the same message.
- Stale conversation memory (user mentally switched accounts but Claude was still using the old one): the reauth refreshes whichever account was actually used in the failing call, which is the right behavior — the operation that failed is the one we want to recover.

---

## Skills summary

What changes in `skills/`:

| Skill | Change | Purpose |
|-------|--------|---------|
| `gws-shared` | Add "Account selection" section | Canonical first-action confirm + Drive re-confirm protocol |
| `gws-gmail` and sub-skills | Add 1-line reference to gws-shared protocol | First-action confirm |
| `gws-drive` and sub-skills | Add references to both protocol AND Drive-always-confirm rule | Per-task re-confirm |
| `gws-sheets`, `gws-docs`, `gws-slides`, `gws-calendar` | Add 1-line reference to gws-shared protocol | First-action confirm |
| `gws-transfer` (NEW) | Cross-account copy for Drive/Gmail/Calendar | Both-end-explicit confirm |
| `gws-account-management` (NEW) | Routes "add my work account", "switch default to X", "remove account" to `/google-services-setup` | Natural-language entry to ongoing management |
| `youcoded-gws-reauth` | Per-account refresh + opportunistic top-up | Hybrid reauth |

---

## Files & components summary

What changes on disk in the `google-services` plugin:

```
google-services/
  commands/
    google-services-setup.md       # MAJOR EDIT — mid-flow + end-of-flow prompts; menu mode
  skills/
    gws-shared/SKILL.md            # EDIT — add Account selection section
    gws-gmail/SKILL.md             # EDIT — add protocol reference
    gws-gmail-*/SKILL.md           # EDIT — add protocol reference
    gws-drive/SKILL.md             # EDIT — protocol + Drive-always-confirm
    gws-sheets/SKILL.md            # EDIT — add protocol reference
    gws-sheets-*/SKILL.md          # EDIT — add protocol reference
    gws-docs/SKILL.md              # EDIT — add protocol reference
    gws-slides/SKILL.md            # EDIT — add protocol reference
    gws-calendar/SKILL.md          # EDIT — add protocol reference
    gws-calendar-*/SKILL.md        # EDIT — add protocol reference
    gws-transfer/SKILL.md          # NEW
    gws-account-management/SKILL.md # NEW
    youcoded-gws-reauth/SKILL.md   # EDIT — per-account, opportunistic top-up
  setup/
    bootstrap-gcp.sh               # EDIT — accept account-name arg for slow-path
    ingest-oauth-json.sh           # EDIT — accept config-dir arg
    reauth.sh                      # EDIT — --config-dir flag, env-var prepend
    add-account.sh                 # NEW — fast-path or slow-path add
    remove-account.sh              # NEW
    smoke-test.sh                  # EDIT — accept account-name; multi-account smoke option
```

User-facing files outside the plugin:

```
~/.config/
  gws/                             # default account (existing location)
  gws-<name>/                      # secondary accounts (NEW)
  gws-profiles.json                # registry (NEW; created on first add-account)
```

---

## Testing approach

The marketplace plugin has no automated test framework today. Verification is manual smoke-testing, supplemented by a small set of contract checks in `docs/DEV-VERIFICATION.md`. The multi-account work adds:

1. **Single-account regression smoke test.** Run an existing single-account install through every gws-* skill end-to-end without setting up a second account. Goal: verify the new env-var routing and `KEYRING_BACKEND=file` change don't break existing users.
2. **Two-account fast-path smoke test.** Set up a second personal Gmail account via the fast path. Verify: registry written correctly, both accounts listed by `gws auth status` against their respective dirs, first-action confirmation appears in a fresh conversation, Drive ops re-confirm, reauth refreshes the right account.
3. **Two-account slow-path smoke test.** Set up a second account via the slow path (deliberately decline the consent screen on the fast path). Verify: separate GCP project created, account works, registry records `ownsGcpProject: true`.
4. **Cross-account transfer smoke test.** Drive file copy, Gmail message save, Calendar event copy. Verify destination is account B, source unchanged in account A.
5. **Remove-account smoke test.** Remove a non-default account → registry updated. Remove the default → prompted for new default. Remove the only account → registry deleted, single-account fallback engages.
6. **Reauth smoke test.** Wait for token expiry (or revoke manually via Google account security settings). Verify reauth runs against the right account, opportunistic top-up offers other expired accounts, retry of the original call succeeds.

The DEV-VERIFICATION.md doc grows by these six entries.

---

## Out of scope / deferred

- **Move (copy + delete-from-source) for cross-account transfers.** Defer until v2 once copy-only proves the transfer skill is useful.
- **Drive permission cloning.** Requires destination user to invite source collaborators by email; can't be done silently.
- **Bulk migration.** Google Takeout exists.
- **Per-skill account override flag** (e.g., `gws-gmail send --account work`). Out of scope; conversation memory + explicit switch phrases cover this case adequately.
- **Concurrent multi-account use within a single skill invocation** (e.g., a single gws-* skill call that reads from two accounts in parallel). Cross-account transfer handles the transfer case sequentially; truly concurrent fan-out is a future enhancement not driven by current need.
- **Workspace admin-managed OAuth client templates.** A future option for environments where the user's IT issues a domain-internal OAuth client. v1 ships personal-OAuth-client only.

## Open questions

None outstanding. All UX, storage, and routing decisions resolved during brainstorming on 2026-04-29.
