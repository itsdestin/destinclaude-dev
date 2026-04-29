# Multi-Account Google Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multi-account support to the existing `google-services` marketplace plugin so a single user can connect work + personal Google accounts and have Claude route Google actions to the right one.

**Architecture:** Per-account config dirs (`~/.config/gws/` for default, `~/.config/gws-<name>/` for secondaries) isolated via `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` + `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` env vars on every gws invocation. A `~/.config/gws-profiles.json` registry tracks accounts and the default. Skills coordinate first-action confirmations and Drive re-confirms via the `gws-shared` protocol. No active-account marker file — conversation memory only.

**Tech Stack:** Bash (setup scripts + lib), Markdown (SKILL.md files + slash command), JSON (registry, via `jq`), `gws` CLI v0.22.5+, `python3` (already a setup-time dep) for any complex JSON manipulation, `bats` for shell-script tests where useful.

**Spec:** [docs/superpowers/specs/2026-04-29-google-services-multi-account-design.md](../specs/2026-04-29-google-services-multi-account-design.md)

**Implementation repo:** All work in `wecoded-marketplace/google-services/`. Use a worktree of `wecoded-marketplace` (see Task 0). Paths in this plan are relative to `wecoded-marketplace/` repo root unless otherwise noted.

**Testing approach:** This plugin has no automated test framework; current verification is manual smoke-testing per `google-services/docs/DEV-VERIFICATION.md`. For new shell scripts (registry library, add-account, remove-account), the plan adds `bats` tests where logic warrants — `bats` is available on Destin's machine via Git Bash. SKILL.md edits and slash-command UX changes are verified by manual smoke runs (Phase 9).

---

## Task 0: Worktree + branch setup

**Files:**
- Worktree of `wecoded-marketplace` at `~/wecoded-marketplace-worktrees/multi-account/`

- [ ] **Step 1: Create worktree**

```bash
cd ~/youcoded-dev/wecoded-marketplace
git fetch origin
git worktree add ~/wecoded-marketplace-worktrees/multi-account -b feat/google-services-multi-account origin/master
cd ~/wecoded-marketplace-worktrees/multi-account
```

- [ ] **Step 2: Verify clean state**

```bash
git status
# Expected: "On branch feat/google-services-multi-account ... nothing to commit, working tree clean"
ls google-services/
# Expected: commands  docs  lib  plugin.json  setup  skills
```

- [ ] **Step 3: Create plan-tracking commit**

The plan itself lives in `youcoded-dev`, but make a small "starting work" commit in the worktree so the branch has an anchor:

```bash
git commit --allow-empty -m "chore(google-services): start multi-account branch"
```

---

## Phase 1 — Foundations: registry library

### Task 1: Registry library skeleton + tests

**Files:**
- Create: `google-services/lib/registry.sh`
- Create: `google-services/tests/registry.bats`

- [ ] **Step 1: Write the failing tests first**

Create `google-services/tests/registry.bats`:

```bash
#!/usr/bin/env bats

# Tests for lib/registry.sh — read/write helpers for ~/.config/gws-profiles.json

setup() {
  export TMP_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TMP_HOME/.config"
  export HOME="$TMP_HOME"
  export REGISTRY="$HOME/.config/gws-profiles.json"
  source "$BATS_TEST_DIRNAME/../lib/registry.sh"
}

@test "registry_path returns the expected path" {
  result="$(registry_path)"
  [ "$result" = "$HOME/.config/gws-profiles.json" ]
}

@test "registry_exists returns 1 when file does not exist" {
  run registry_exists
  [ "$status" -eq 1 ]
}

@test "registry_exists returns 0 when file exists" {
  echo '{}' > "$REGISTRY"
  run registry_exists
  [ "$status" -eq 0 ]
}

@test "registry_init creates file with empty accounts when called fresh" {
  registry_init
  [ -f "$REGISTRY" ]
  default="$(jq -r '.default' "$REGISTRY")"
  [ "$default" = "null" ]
  count="$(jq '.accounts | length' "$REGISTRY")"
  [ "$count" -eq 0 ]
}

@test "registry_init is a no-op when file already exists" {
  echo '{"default":"personal","accounts":[{"name":"personal","email":"a@b.com","configDir":"~/.config/gws","ownsGcpProject":true,"gcpProjectId":"p"}],"knownTestUsers":[]}' > "$REGISTRY"
  registry_init
  default="$(jq -r '.default' "$REGISTRY")"
  [ "$default" = "personal" ]
}

@test "registry_add_account appends an account" {
  registry_init
  registry_add_account "work" "work@acme.com" "$HOME/.config/gws-work" false ""
  count="$(jq '.accounts | length' "$REGISTRY")"
  [ "$count" -eq 1 ]
  email="$(jq -r '.accounts[0].email' "$REGISTRY")"
  [ "$email" = "work@acme.com" ]
}

@test "registry_remove_account removes an account by name" {
  registry_init
  registry_add_account "work" "work@acme.com" "$HOME/.config/gws-work" false ""
  registry_add_account "personal" "p@gmail.com" "$HOME/.config/gws" true "youcoded-personal-abc"
  registry_remove_account "work"
  count="$(jq '.accounts | length' "$REGISTRY")"
  [ "$count" -eq 1 ]
  remaining="$(jq -r '.accounts[0].name' "$REGISTRY")"
  [ "$remaining" = "personal" ]
}

@test "registry_set_default updates the default field" {
  registry_init
  registry_add_account "work" "work@acme.com" "$HOME/.config/gws-work" false ""
  registry_set_default "work"
  default="$(jq -r '.default' "$REGISTRY")"
  [ "$default" = "work" ]
}

@test "registry_get_default_config_dir returns the configDir of the default account" {
  registry_init
  registry_add_account "personal" "p@gmail.com" "$HOME/.config/gws" true ""
  registry_set_default "personal"
  result="$(registry_get_default_config_dir)"
  [ "$result" = "$HOME/.config/gws" ]
}

@test "registry_list_accounts emits one line per account: name<TAB>email<TAB>configDir" {
  registry_init
  registry_add_account "personal" "p@gmail.com" "$HOME/.config/gws" true ""
  registry_add_account "work" "work@acme.com" "$HOME/.config/gws-work" false ""
  result="$(registry_list_accounts)"
  echo "$result" | grep -q "^personal	p@gmail.com	$HOME/.config/gws$"
  echo "$result" | grep -q "^work	work@acme.com	$HOME/.config/gws-work$"
}

@test "registry_add_known_test_user appends an email and dedupes" {
  registry_init
  registry_add_known_test_user "x@y.com"
  registry_add_known_test_user "x@y.com"  # duplicate
  registry_add_known_test_user "z@w.com"
  count="$(jq '.knownTestUsers | length' "$REGISTRY")"
  [ "$count" -eq 2 ]
}

@test "registry_account_count returns the number of accounts" {
  registry_init
  result="$(registry_account_count)"
  [ "$result" -eq 0 ]
  registry_add_account "personal" "p@gmail.com" "$HOME/.config/gws" true ""
  result="$(registry_account_count)"
  [ "$result" -eq 1 ]
}
```

- [ ] **Step 2: Run the tests; verify they fail**

```bash
cd ~/wecoded-marketplace-worktrees/multi-account
bats google-services/tests/registry.bats
```

Expected: every test fails with `lib/registry.sh: No such file or directory` (or similar source error).

- [ ] **Step 3: Write the registry library**

Create `google-services/lib/registry.sh`:

```bash
#!/usr/bin/env bash
# registry.sh — read/write helpers for ~/.config/gws-profiles.json
#
# This file is sourced by other setup scripts (add-account.sh, remove-account.sh,
# the slash command's bash blocks, etc). It does NOT have a shebang-driven entry
# point; everything is a function.
#
# All functions assume `jq` is on PATH. jq ships with Git Bash on Windows and
# is in the apt/brew core on Linux/macOS — already a transitive setup dep.

# Path to the registry. Override REGISTRY env var for tests.
registry_path() {
  echo "${REGISTRY:-$HOME/.config/gws-profiles.json}"
}

# Exit 0 if registry exists, 1 otherwise.
registry_exists() {
  [ -f "$(registry_path)" ]
}

# Create an empty registry if one doesn't exist. No-op if it does.
registry_init() {
  local path
  path="$(registry_path)"
  [ -f "$path" ] && return 0
  mkdir -p "$(dirname "$path")"
  echo '{"default":null,"accounts":[],"knownTestUsers":[]}' > "$path"
  chmod 600 "$path" 2>/dev/null || true
}

# Append an account to the registry.
# Args: name email configDir ownsGcpProject gcpProjectId
# ownsGcpProject must be "true" or "false" (lowercase, JSON-bool-safe).
# gcpProjectId may be empty for fast-path accounts.
registry_add_account() {
  local name="$1" email="$2" config_dir="$3" owns="$4" project="$5"
  local path
  path="$(registry_path)"
  registry_init
  local entry
  if [ -n "$project" ]; then
    entry=$(jq -n \
      --arg name "$name" --arg email "$email" --arg dir "$config_dir" \
      --argjson owns "$owns" --arg proj "$project" \
      '{name:$name,email:$email,configDir:$dir,ownsGcpProject:$owns,gcpProjectId:$proj}')
  else
    entry=$(jq -n \
      --arg name "$name" --arg email "$email" --arg dir "$config_dir" \
      --argjson owns "$owns" \
      '{name:$name,email:$email,configDir:$dir,ownsGcpProject:$owns}')
  fi
  jq ".accounts += [$entry]" "$path" > "$path.tmp" && mv "$path.tmp" "$path"
}

# Remove an account by name. No-op if the account doesn't exist.
registry_remove_account() {
  local name="$1"
  local path
  path="$(registry_path)"
  [ -f "$path" ] || return 0
  jq --arg name "$name" '.accounts |= map(select(.name != $name))' "$path" \
    > "$path.tmp" && mv "$path.tmp" "$path"
}

# Set the default account.
# The caller is responsible for making sure the name exists.
registry_set_default() {
  local name="$1"
  local path
  path="$(registry_path)"
  jq --arg name "$name" '.default = $name' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
}

# Print the configDir of the default account, or empty string if no default.
registry_get_default_config_dir() {
  local path default_name
  path="$(registry_path)"
  [ -f "$path" ] || return 0
  default_name="$(jq -r '.default // ""' "$path")"
  [ -z "$default_name" ] && return 0
  jq -r --arg name "$default_name" \
    '.accounts[] | select(.name == $name) | .configDir' "$path"
}

# Print one line per account, tab-separated: name<TAB>email<TAB>configDir
registry_list_accounts() {
  local path
  path="$(registry_path)"
  [ -f "$path" ] || return 0
  jq -r '.accounts[] | "\(.name)\t\(.email)\t\(.configDir)"' "$path"
}

# Number of accounts.
registry_account_count() {
  local path
  path="$(registry_path)"
  [ -f "$path" ] || { echo 0; return 0; }
  jq '.accounts | length' "$path"
}

# Append an email to knownTestUsers (deduplicated).
registry_add_known_test_user() {
  local email="$1"
  local path
  path="$(registry_path)"
  registry_init
  jq --arg email "$email" '
    .knownTestUsers = (.knownTestUsers + [$email] | unique)
  ' "$path" > "$path.tmp" && mv "$path.tmp" "$path"
}

# Print the email list (one per line).
registry_list_known_test_users() {
  local path
  path="$(registry_path)"
  [ -f "$path" ] || return 0
  jq -r '.knownTestUsers[]' "$path"
}

# Delete the registry file. Used by remove-account when last account is removed.
registry_destroy() {
  local path
  path="$(registry_path)"
  rm -f "$path"
}

# Return the configDir for a named account.
registry_get_config_dir() {
  local name="$1"
  local path
  path="$(registry_path)"
  [ -f "$path" ] || return 0
  jq -r --arg name "$name" '.accounts[] | select(.name == $name) | .configDir' "$path"
}

# Return the email for a named account.
registry_get_email() {
  local name="$1"
  local path
  path="$(registry_path)"
  [ -f "$path" ] || return 0
  jq -r --arg name "$name" '.accounts[] | select(.name == $name) | .email' "$path"
}

# Return ownsGcpProject for a named account ("true" or "false").
registry_get_owns_gcp() {
  local name="$1"
  local path
  path="$(registry_path)"
  [ -f "$path" ] || return 0
  jq -r --arg name "$name" '.accounts[] | select(.name == $name) | .ownsGcpProject' "$path"
}

# Return gcpProjectId for a named account, or empty if unset.
registry_get_gcp_project() {
  local name="$1"
  local path
  path="$(registry_path)"
  [ -f "$path" ] || return 0
  jq -r --arg name "$name" '.accounts[] | select(.name == $name) | .gcpProjectId // ""' "$path"
}

# Print the name of the default account, or empty if none.
registry_get_default_name() {
  local path
  path="$(registry_path)"
  [ -f "$path" ] || return 0
  jq -r '.default // ""' "$path"
}
```

- [ ] **Step 4: Run the tests; verify they pass**

```bash
bats google-services/tests/registry.bats
```

Expected: all 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add google-services/lib/registry.sh google-services/tests/registry.bats
git commit -m "feat(google-services): registry library for ~/.config/gws-profiles.json"
```

---

## Phase 2 — Single-account env-var routing

Goal: switch every existing gws invocation to use the two env vars (`GOOGLE_WORKSPACE_CLI_CONFIG_DIR`, `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file`) targeting `~/.config/gws/`. No multi-account behavior yet — this is a no-op for users; it just sets the foundation. After this phase, all setup scripts and reauth use the env-var pattern.

### Task 2: Wrap reauth.sh with --config-dir flag

**Files:**
- Modify: `google-services/setup/reauth.sh`

- [ ] **Step 1: Read current reauth.sh**

Current contents (already in repo, lines 1-25):

```bash
#!/usr/bin/env bash
# reauth.sh
# Invoked by Claude (not by the user) when a skill signals AUTH_EXPIRED.
# Re-runs the browser OAuth flow ...

set -u

GWS_CREDS="$HOME/.config/gws/client_secret.json"

if [ ! -f "$GWS_CREDS" ]; then
  echo "No saved Google setup found. Run /google-services-setup first." >&2
  exit 1
fi

gws auth login || exit 1
exit 0
```

- [ ] **Step 2: Replace with multi-account-aware version**

Overwrite `google-services/setup/reauth.sh` with:

```bash
#!/usr/bin/env bash
# reauth.sh
# Invoked by Claude (not by the user) when a skill signals AUTH_EXPIRED.
# Re-runs the browser OAuth flow against a specified config dir, or against
# the default ~/.config/gws/ when --config-dir is omitted.
#
# Usage:
#   reauth.sh                              # default account at ~/.config/gws/
#   reauth.sh --config-dir <path>          # named account
#
# Exit 0 on success, 1 on failure (user closed browser, network error, no
# credentials saved).

set -u

CONFIG_DIR="$HOME/.config/gws"

while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir) CONFIG_DIR="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

CREDS="$CONFIG_DIR/client_secret.json"
if [ ! -f "$CREDS" ]; then
  echo "No saved Google setup found at $CONFIG_DIR. Run /google-services-setup first." >&2
  exit 1
fi

# Both env vars are required for safe per-account isolation. CONFIG_DIR alone
# leaves the AES key in the OS keyring under a fixed service name, where a
# second account's auth login would clobber the first. KEYRING_BACKEND=file
# moves the key into <CONFIG_DIR>/.encryption_key so each account's state is
# fully isolated. See spec section "Foundation" for full reasoning.
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$CONFIG_DIR"
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file

gws auth login || exit 1
exit 0
```

- [ ] **Step 3: Smoke test against an existing single-account install**

```bash
# This actually invokes the OAuth browser flow — only run if you want to reauth right now.
# Otherwise inspect the output for "Using keyring backend: file" or similar.
bash google-services/setup/reauth.sh --config-dir "$HOME/.config/gws" 2>&1 | head -5
```

Expected (smoke): the helper prints a Google auth URL on a line starting with two spaces, indicating it reached `gws auth login` with the env vars set.

- [ ] **Step 4: Verify keyring migration behavior** (one-time, important)

This is the implementation-time verification deferred from the spec. Run:

```bash
# What does gws do when KEYRING_BACKEND=file is set against a config dir
# whose .encryption_key file doesn't yet exist?
ls "$HOME/.config/gws/.encryption_key" 2>&1   # likely does NOT exist yet

GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$HOME/.config/gws" \
GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
gws auth status --format json 2>&1 | head -20
```

Two outcomes possible:

- (A) `auth status` reports the correct existing client_id and `token_valid: true` (or true-modulo-7-day-expiry). Means gws transparently fell back to the OS keyring for the AES key on this read. Fine — no migration helper needed; the file gets written on the next `auth login`.
- (B) `auth status` reports a decrypt failure or an empty encryption state. Means the file backend doesn't fall back; the user will need to reauth on first multi-account-aware launch. Also fine — the existing reauth skill is the migration helper.

Record which outcome was observed in `google-services/docs/DEV-VERIFICATION.md` (Phase 9 task) so future maintainers know.

- [ ] **Step 5: Commit**

```bash
git add google-services/setup/reauth.sh
git commit -m "feat(google-services): reauth.sh accepts --config-dir, uses file keyring backend

Single-account installs are unaffected (defaults to ~/.config/gws/).
Sets KEYRING_BACKEND=file unconditionally so per-account AES keys land in
<config_dir>/.encryption_key rather than the OS keyring (where multi-account
would clobber a single fixed service-name slot)."
```

### Task 3: Wrap smoke-test.sh with optional config-dir

**Files:**
- Modify: `google-services/setup/smoke-test.sh`

- [ ] **Step 1: Read current smoke-test.sh**

Already inspected — lines 1-56. Top-of-file `set -u`; runs 6 `gws` probes, exits nonzero if any fail.

- [ ] **Step 2: Add env-var prepend at top of script**

Edit `google-services/setup/smoke-test.sh`. After the existing `set -u` line, insert:

```bash
# Multi-account: each gws call routes via the active config dir + file keyring.
# Single-account fallback: defaults to ~/.config/gws/, identical to pre-multi-account behavior.
CONFIG_DIR="${GWS_CONFIG_DIR:-$HOME/.config/gws}"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$CONFIG_DIR"
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file
```

- [ ] **Step 3: Verify the script still passes a smoke check**

```bash
# Default (single-account) invocation:
bash google-services/setup/smoke-test.sh
# Expected: ✓ Gmail, ✓ Drive, etc.

# Per-account invocation:
GWS_CONFIG_DIR="$HOME/.config/gws" bash google-services/setup/smoke-test.sh
# Expected: same output.
```

- [ ] **Step 4: Commit**

```bash
git add google-services/setup/smoke-test.sh
git commit -m "feat(google-services): smoke-test.sh accepts GWS_CONFIG_DIR env var"
```

### Task 4: Wrap ingest-oauth-json.sh and bootstrap-gcp.sh with --config-dir

**Files:**
- Modify: `google-services/setup/ingest-oauth-json.sh`
- Modify: `google-services/setup/bootstrap-gcp.sh`

- [ ] **Step 1: Modify ingest-oauth-json.sh to accept a target config dir**

Currently the script writes the normalized credentials to a hardcoded `$HOME/.config/gws/client_secret.json`. Add a `--config-dir` argument that overrides this. The diff to apply:

Find the existing `GWS_DST` line (currently around line 85):

```bash
GWS_DST="$HOME/.config/gws/client_secret.json"
```

Replace with:

```bash
# Default to the primary account's location; --config-dir overrides for
# secondary-account add-flows.
GWS_CONFIG_DIR="$HOME/.config/gws"

# Extract --config-dir if present; treat positional arg as before.
NEW_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir) GWS_CONFIG_DIR="$2"; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do NEW_ARGS+=("$1"); shift; done ;;
    *) NEW_ARGS+=("$1"); shift ;;
  esac
done
set -- "${NEW_ARGS[@]+"${NEW_ARGS[@]}"}"

GWS_DST="$GWS_CONFIG_DIR/client_secret.json"
```

(The argument-rewrite is required because the script already uses `${1:-}` to read the file path; we strip `--config-dir` out of `$@` before that read happens.)

- [ ] **Step 2: Modify bootstrap-gcp.sh to accept --account-name**

Currently the script always names the GCP project "YouCoded Personal" and looks for that exact name. For slow-path multi-account adds, the project should be named after the account (e.g., "YouCoded Work").

Find the existing `gcloud projects list --filter=` line (currently around line 29):

```bash
_projects=$(gcloud projects list --filter="name:YouCoded Personal" --format="value(projectId)" 2>/dev/null || true)
```

Add at the top of the script (after the `: "${YOUCODED_OUTPUT_DIR:?must be set}"` line):

```bash
# --account-name lets the slow-path add-account flow create a per-account GCP
# project ("YouCoded Work" instead of "YouCoded Personal"). Default preserves
# the existing first-time-setup project name.
ACCOUNT_NAME="Personal"
while [ $# -gt 0 ]; do
  case "$1" in
    --account-name) ACCOUNT_NAME="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Title-case the name for the human-readable project name. Bash 4+ ${var^}.
PROJECT_NAME_LABEL="YouCoded ${ACCOUNT_NAME^}"
PROJECT_ID_PREFIX="youcoded-$(echo "$ACCOUNT_NAME" | tr '[:upper:]' '[:lower:]')"
```

Then replace the project-list filter and project-id construction:

```bash
_projects=$(gcloud projects list --filter="name:$PROJECT_NAME_LABEL" --format="value(projectId)" 2>/dev/null || true)
```

And in the new-project branch:

```bash
PROJECT_ID="$PROJECT_ID_PREFIX-$SUFFIX"
gcloud projects create "$PROJECT_ID" --name="$PROJECT_NAME_LABEL" --quiet >/dev/null
echo "  ✓ Created your private YouCoded $ACCOUNT_NAME connection"
```

(The "Found existing" branch updates similarly: `echo "  ✓ Found existing YouCoded $ACCOUNT_NAME connection ($PROJECT_ID)"`.)

- [ ] **Step 3: Smoke test (optional — do not actually create a project)**

```bash
# Just verify the help/argv parsing accepts the flag without crashing
bash -n google-services/setup/bootstrap-gcp.sh
bash -n google-services/setup/ingest-oauth-json.sh
```

Expected: both exit 0 (syntax check passes).

- [ ] **Step 4: Commit**

```bash
git add google-services/setup/ingest-oauth-json.sh google-services/setup/bootstrap-gcp.sh
git commit -m "feat(google-services): ingest-oauth-json + bootstrap-gcp accept per-account args

ingest-oauth-json.sh: --config-dir flag overrides the hardcoded
~/.config/gws/ destination so the slow-path add-account flow can write
to a per-account dir.

bootstrap-gcp.sh: --account-name flag parameterizes the GCP project
display name and project-id prefix so secondary accounts get their own
project (e.g. 'YouCoded Work', 'youcoded-work-x9a3b')."
```

---

## Phase 3 — Add-account flow

### Task 5: add-account.sh skeleton (fast path)

**Files:**
- Create: `google-services/setup/add-account.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
# add-account.sh
# Adds a secondary Google account to a multi-account YouCoded setup.
#
# Two modes:
#   --fast-path: assumes the user already added this email to the existing
#     OAuth client's Test Users list. Copies the existing client_secret.json
#     into the new config dir and runs `gws auth login` against it.
#   --slow-path: full bootstrap of a new GCP project + new OAuth client for
#     this account. Used when the workspace blocks the existing client.
#
# Usage:
#   add-account.sh --name <name> --email <email> --fast-path
#   add-account.sh --name <name> --email <email> --slow-path
#
# Exit codes:
#   0 — account added successfully
#   1 — generic failure
#   2 — fast-path consent rejected (signal to the caller to retry as slow-path)

set -u

# shellcheck source=../lib/registry.sh
source "$(dirname "$0")/../lib/registry.sh"

NAME=""
EMAIL=""
MODE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="$2"; shift 2 ;;
    --email)       EMAIL="$2"; shift 2 ;;
    --fast-path)   MODE="fast"; shift ;;
    --slow-path)   MODE="slow"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$NAME" ] || [ -z "$EMAIL" ] || [ -z "$MODE" ]; then
  echo "Usage: add-account.sh --name <name> --email <email> --fast-path|--slow-path" >&2
  exit 1
fi

CONFIG_DIR="$HOME/.config/gws-$NAME"

case "$MODE" in
  fast)
    if [ ! -f "$HOME/.config/gws/client_secret.json" ]; then
      echo "No primary account found at ~/.config/gws/. Run /google-services-setup first." >&2
      exit 1
    fi
    mkdir -p "$CONFIG_DIR"
    cp "$HOME/.config/gws/client_secret.json" "$CONFIG_DIR/client_secret.json"

    # Run auth login. If the user's account is not on Test Users (or the
    # consent screen is rejected for any other reason), gws exits nonzero —
    # we surface as exit 2 so the caller can fall back to slow-path.
    if ! GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$CONFIG_DIR" \
         GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
         gws auth login; then
      # Cleanup the dir so a subsequent slow-path attempt starts fresh.
      rm -rf "$CONFIG_DIR"
      exit 2
    fi

    registry_init
    registry_add_account "$NAME" "$EMAIL" "$CONFIG_DIR" false ""
    # If this is the first secondary account, also record the primary in the
    # registry so it has a name and can be referenced.
    if [ "$(registry_account_count)" = "1" ]; then
      # Only the just-added secondary is listed; primary needs to be added too.
      # The slash command (Phase 4) is responsible for asking the user what
      # to call the primary account during the multi-account upgrade — fall
      # back to "personal" here as a safe default.
      registry_add_account "personal" "" "$HOME/.config/gws" true ""
      registry_set_default "personal"
    fi
    echo "  ✓ Connected $EMAIL as $NAME"
    ;;
  slow)
    # Slow path: full bootstrap of a per-account GCP project. Reuses the
    # existing helpers with --account-name + --config-dir to land everything
    # in the new account's config dir.
    : "${YOUCODED_OUTPUT_DIR:?must be set when invoking slow-path}"

    bash "$(dirname "$0")/bootstrap-gcp.sh" --account-name "$NAME" || exit 1
    # bootstrap-gcp.sh writes project.env to YOUCODED_OUTPUT_DIR; source it.
    # shellcheck source=/dev/null
    source "$YOUCODED_OUTPUT_DIR/project.env"

    # The slash command is responsible for the manual Cloud Console steps
    # (consent screen + OAuth client creation + JSON download) for the
    # slow-path. add-account.sh's job ends with bootstrap-gcp; ingest and
    # auth login happen back in the slash command after the user downloads
    # the JSON. So in slow-path mode this script only does the GCP project
    # creation, then exits 0 with the project_id printed for the slash
    # command to consume from the env file.
    echo "  ✓ Created GCP project $PROJECT_ID for $NAME"
    ;;
esac

exit 0
```

- [ ] **Step 2: Verify shell syntax**

```bash
bash -n google-services/setup/add-account.sh
```

Expected: exit 0.

- [ ] **Step 3: Add a bats test for argument parsing and registry mutation (mocked)**

Append to `google-services/tests/registry.bats` a new file `google-services/tests/add-account.bats`:

```bash
#!/usr/bin/env bats

# Tests for add-account.sh argument validation only. Real fast-path and
# slow-path flows are smoke-tested manually (Phase 9) because they invoke
# real `gws auth login` and require browser interaction.

@test "add-account.sh exits nonzero with no args" {
  run bash "$BATS_TEST_DIRNAME/../setup/add-account.sh"
  [ "$status" -ne 0 ]
}

@test "add-account.sh exits nonzero on unknown flag" {
  run bash "$BATS_TEST_DIRNAME/../setup/add-account.sh" --bogus
  [ "$status" -ne 0 ]
}

@test "add-account.sh requires --name --email --fast-path|--slow-path" {
  run bash "$BATS_TEST_DIRNAME/../setup/add-account.sh" --name work
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 4: Run the tests**

```bash
bats google-services/tests/add-account.bats
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add google-services/setup/add-account.sh google-services/tests/add-account.bats
git commit -m "feat(google-services): add-account.sh fast-path + slow-path skeleton

Fast path: copies primary's client_secret.json into the new account's
config dir and runs gws auth login against it. Exit 2 signals fast-path
consent rejection so the caller can fall back to slow-path.

Slow path: invokes bootstrap-gcp.sh --account-name to create a per-account
GCP project. Manual consent-screen + OAuth-client steps remain in the
slash command (driven by the user clicking through Cloud Console)."
```

---

## Phase 4 — Setup command updates

### Task 6: Mid-flow prompt for "any other accounts you'll want to use later?"

**Files:**
- Modify: `google-services/commands/google-services-setup.md`

- [ ] **Step 1: Locate the insertion point**

The new prompt goes inside Step 3C (after the user finishes adding their primary email to Test Users, before they continue to Step 3D). Currently Step 3C ends with:

```markdown
Handle "I hit a problem" the same way as 3B. Otherwise continue to 3D.
```

- [ ] **Step 2: Insert the new prompt block**

Replace the line above with the following block. The new content goes between "Handle..." and "Otherwise continue to 3D":

```markdown
Handle "I hit a problem" the same way as 3B.

Otherwise, before moving on, send this in chat:

> While you've got the Test Users page open — do you plan to use any other Google accounts with YouCoded later (work, school, secondary)? If so, list them now and I'll have you add them to Test Users in this same trip. Or say "just this one."

Wait for the user's reply. If they list emails:

1. Confirm what you heard back: "Got it — I'll have you add: work@acme.com, school@uni.edu."
2. Send this:

> Add each one to the Test Users list now (same blue **+ Add users** button), then come back and let me know when they're all there.

3. Save the emails into the registry's `knownTestUsers` field. Source the registry helpers and call:

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/registry.sh"
registry_init
for email in <space-separated emails the user listed>; do
  registry_add_known_test_user "$email"
done
```

4. Ask with `AskUserQuestion`:
   - **question:** "Are all the additional emails added?"
   - **header:** "Test users"
   - **options:**
     - label: "All added" — description: "I'll continue to the next page."
     - label: "I hit a problem" — description: "Tell me what happened."

If the user says "just this one" or "no," skip the registry step and continue.

Continue to 3D.
```

- [ ] **Step 3: Verify the file still parses as Markdown**

(No automation; just inspect with `head -250 google-services/commands/google-services-setup.md`. The slash command's `---` frontmatter divider plus the description field at the top remain unchanged.)

- [ ] **Step 4: Commit**

```bash
git add google-services/commands/google-services-setup.md
git commit -m "feat(google-services-setup): collect known test users mid-flow

After the user finishes adding their primary email to Test Users (Step 3C),
ask if any other accounts will be wanted later. Listed emails are saved to
~/.config/gws-profiles.json's knownTestUsers field so the future
add-account flow can fast-path them without re-opening Cloud Console."
```

### Task 7: End-of-flow "want to add another account now?" prompt

**Files:**
- Modify: `google-services/commands/google-services-setup.md`

- [ ] **Step 1: Locate the insertion point**

The new prompt goes after Step 7 (the migrate-legacy.sh cleanup), at the very end of the slash command. Currently the file ends after Step 7's failure-handling line.

- [ ] **Step 2: Append a new Step 8**

Append after the existing end of Step 7:

```markdown
## Step 8 — Want to add another account now?

This step runs only if Step 6 reported every app responding.

Source the registry and check if any `knownTestUsers` were collected during Step 3C:

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/registry.sh"
PENDING="$(registry_list_known_test_users 2>/dev/null)"
```

If `$PENDING` is empty, ask the user generally:

> Want to connect another Google account too? You can also do this anytime by running /google-services-setup again.

Otherwise, name the pending emails:

> Want to connect [work@acme.com] now? You added it to Test Users earlier, so signing in is quick.

Ask with `AskUserQuestion`:

- **question:** "Connect another account?"
- **header:** "Another account"
- **options:**
  - label: "Yes, add one" — description: "I'll walk you through signing in to the next account."
  - label: "Not now" — description: "All set. You can run /google-services-setup again to add accounts later."

If the user picks "Not now," send "All set" and stop.

If "Yes, add one":

1. If multiple `knownTestUsers` exist, ask which to connect first via `AskUserQuestion`. Otherwise use the single pending email.
2. Ask the user for a name for this account in chat (suggest one based on the email's domain — e.g. "work" for non-gmail.com domains, or use the part before @):

   > What should I call this account? (Suggestion: "work")

3. Run:

```bash
bash $CLAUDE_PLUGIN_ROOT/setup/add-account.sh \
  --name "<name>" --email "<email>" --fast-path
```

   Capture exit code. On exit 0, send: "Connected [email] as [name]."

4. **On exit 2 (fast-path consent rejected):** the workspace blocked the OAuth client. Tell the user in plain words:

   > That account's organization needs YouCoded to set up a separate connection. It's an extra ~10 minutes — want to do that now?

   Ask with `AskUserQuestion`:
   - label: "Yes, set it up" → run slow-path (see Step 8.1 below)
   - label: "Skip this one" → loop back to step 1 with the next pending email, or end if none

5. After a successful add, ask if the user wants to add another (loop back to step 1 with the remaining pending emails). When all are done OR the user picks "Not now," ask which account is the default if more than one exists:

   - Use `AskUserQuestion` with options for each account name + the current default highlighted.
   - If user picks a different default, run `registry_set_default "<name>"`.

### Step 8.1 — Slow-path fallback (per-account GCP project)

This sub-step runs only when Step 8's fast-path returned exit 2.

Hold the user's selected name and email in shell variables `$NEW_NAME` and `$NEW_EMAIL` from Step 8.

Run the project bootstrap:

```bash
bash $CLAUDE_PLUGIN_ROOT/setup/add-account.sh \
  --name "$NEW_NAME" --email "$NEW_EMAIL" --slow-path
source "$YOUCODED_OUTPUT_DIR/project.env"   # exports PROJECT_ID
```

Walk the user through the **same three Cloud Console pages from Step 3** but for the new project. Re-use the existing chat copy verbatim from Steps 3B/3C/3D (consent screen → test users → credentials), but:

1. Open each page against the **new** project ID:

```bash
bash $CLAUDE_PLUGIN_ROOT/setup/open-browser.sh \
  "https://console.cloud.google.com/auth/overview?project=$PROJECT_ID"
# … and for 3C and 3D, with /auth/audience and /apis/credentials respectively, same project.
```

2. Use `AskUserQuestion` after each page exactly as in Steps 3B/3C/3D.

3. Once the user has downloaded the credentials JSON, ingest into the **new account's config dir**:

```bash
NEW_CONFIG_DIR="$HOME/.config/gws-$NEW_NAME"
mkdir -p "$NEW_CONFIG_DIR"
bash $CLAUDE_PLUGIN_ROOT/setup/ingest-oauth-json.sh --config-dir "$NEW_CONFIG_DIR"
```

(If the ingest helper can't find the file in Downloads, fall back to asking the user for the path, identical to Step 3E's fallback flow but with the `--config-dir` flag preserved.)

4. Run the consent + first auth login against the new account's config dir:

```bash
GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$NEW_CONFIG_DIR" \
GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
gws auth login > "$YOUCODED_OUTPUT_DIR/gws-auth-$NEW_NAME.log" 2>&1 &
GWS_PID=$!
for _ in $(seq 1 100); do
  URL=$(grep -m1 "^  https://accounts.google.com" "$YOUCODED_OUTPUT_DIR/gws-auth-$NEW_NAME.log" 2>/dev/null | sed 's/^  //')
  [ -n "$URL" ] && break
  sleep 0.1
done
if [ -z "$URL" ]; then
  kill "$GWS_PID" 2>/dev/null
  exit 1
fi
bash "$CLAUDE_PLUGIN_ROOT/setup/open-browser.sh" "$URL"
wait "$GWS_PID"
```

(This mirrors the Step 5 pattern from first-time setup, with the env-vars set for the new account.)

5. On success, register with `ownsGcpProject=true`:

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/registry.sh"
registry_init
registry_add_account "$NEW_NAME" "$NEW_EMAIL" "$NEW_CONFIG_DIR" true "$PROJECT_ID"
# If this is the first secondary, also register the primary at ~/.config/gws/.
if [ "$(registry_account_count)" = "1" ]; then
  registry_add_account "personal" "" "$HOME/.config/gws" true ""
  registry_set_default "personal"
fi
```

Run the smoke test against the new account:

```bash
GWS_CONFIG_DIR="$NEW_CONFIG_DIR" bash $CLAUDE_PLUGIN_ROOT/setup/smoke-test.sh
```

Continue back at Step 8 step 5 (default-picking and loop for any remaining pending emails).
```

- [ ] **Step 3: Commit**

```bash
git add google-services/commands/google-services-setup.md
git commit -m "feat(google-services-setup): end-of-flow add-another-account prompt

After Step 7 (legacy cleanup), offer to connect another account. If
knownTestUsers were collected mid-flow, fast-path them via add-account.sh.
Fast-path consent rejection (exit 2) falls back to slow-path: per-account
GCP project + OAuth client. After all adds complete, prompt for which
account is the default."
```

### Task 8: Menu mode when registry already exists

**Files:**
- Modify: `google-services/commands/google-services-setup.md`

- [ ] **Step 1: Insert a new "Step 0.5" before Step 1**

After Step 0 (system check) and before Step 1, the slash command should detect an existing registry and offer the management menu rather than re-running first-time setup.

Insert a new section between Step 0 and Step 1:

```markdown
## Step 0.5 — Detect existing setup

Source the registry helper:

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/registry.sh"
```

Two cases:

**Case A: Registry exists with at least one account.** This is a returning user. Skip first-time setup; open the management menu.

```bash
registry_exists && [ "$(registry_account_count)" -gt 0 ]
```

If true, list current accounts in chat:

> You have [N] account(s) connected: [name1] (default), [name2]. What do you want to do?

Ask with `AskUserQuestion`:

- **question:** "What do you want to do?"
- **header:** "Manage accounts"
- **options:**
  - label: "Add another account" — description: "Connect another Google account."
  - label: "Remove an account" — description: "Sign out and remove a connection."
  - label: "Change default" — description: "Pick which account is used by default in new conversations."
  - label: "Refresh / fix something broken" — description: "Re-run full setup against an account."
  - label: "Cancel" — description: "Close this menu."

Routing:
- **Add another account** → jump to Step 8 (the add-another flow). It's idempotent and works whether or not knownTestUsers is empty.
- **Remove an account** → run the remove flow described in this command's Appendix A below.
- **Change default** → ask with `AskUserQuestion` listing each account name; run `registry_set_default "<name>"` on selection.
- **Refresh / fix** → ask which account, then re-run Steps 1-6 against that account's config dir (set `GWS_CONFIG_DIR=<configDir>` for the smoke test).
- **Cancel** → stop silently.

**Case B: Registry doesn't exist OR exists with zero accounts.** First-time setup. Continue to Step 1 normally.
```

- [ ] **Step 2: Append "Appendix A — Remove an account" at the end of the file**

After Step 8 / 8.1, append:

```markdown
---

## Appendix A — Remove an account

Used by the menu in Step 0.5 ("Remove an account").

List current accounts via `registry_list_accounts | cut -f1`. If only one account exists, the warning copy is sterner (see below).

Ask with `AskUserQuestion`:

- **question:** "Which account do you want to remove?"
- **header:** "Remove"
- **options:** one per registered account; label = name, description = email.

After selection, ask for confirmation:

> I'll sign out of [email] and remove its YouCoded connection. Your data in Google itself stays untouched — emails, Drive files, calendars all remain in the account. Confirm?

If only one account remains:

> This is your only Google account. Removing it means you'll need to run /google-services-setup before YouCoded can do anything Google-related again. Confirm?

If user confirms:

```bash
bash $CLAUDE_PLUGIN_ROOT/setup/remove-account.sh --name "<name>"
```

Capture exit. On success:

- If account was the default and others remain, ask which to make new default and call `registry_set_default`.
- If account had `ownsGcpProject=true`, mention the leftover project: "This account had its own Google Cloud project (`<projectId>`). The local connection is gone, but the project still exists in console.cloud.google.com if you want to delete it there."
- Send: "Removed [name]."
```

- [ ] **Step 3: Commit**

```bash
git add google-services/commands/google-services-setup.md
git commit -m "feat(google-services-setup): menu mode for returning users

When a registry exists with >=1 account, /google-services-setup detects
this in Step 0.5 and opens a management menu (add / remove / change
default / refresh / cancel) instead of re-running first-time setup.

Appendix A documents the remove-account flow."
```

---

## Phase 5 — Remove-account flow

### Task 9: remove-account.sh

**Files:**
- Create: `google-services/setup/remove-account.sh`
- Create: `google-services/tests/remove-account.bats`

- [ ] **Step 1: Write the failing tests first**

Create `google-services/tests/remove-account.bats`:

```bash
#!/usr/bin/env bats

# Tests for remove-account.sh. Real `gws auth logout` invocation is mocked
# via PATH redirection so tests don't require an actual Google account.

setup() {
  export TMP_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$TMP_HOME/.config/gws-work" "$TMP_HOME/.config/gws"
  export HOME="$TMP_HOME"
  export REGISTRY="$HOME/.config/gws-profiles.json"
  source "$BATS_TEST_DIRNAME/../lib/registry.sh"

  # Stub `gws` so `gws auth logout` doesn't try to talk to Google.
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/gws" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$STUB_DIR/gws"
  export PATH="$STUB_DIR:$PATH"

  # Seed the registry with two accounts.
  registry_init
  registry_add_account "personal" "p@gmail.com" "$HOME/.config/gws" true "youcoded-personal-abc"
  registry_add_account "work" "work@acme.com" "$HOME/.config/gws-work" false ""
  registry_set_default "personal"
}

@test "remove-account.sh removes a non-default account" {
  run bash "$BATS_TEST_DIRNAME/../setup/remove-account.sh" --name work
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.config/gws-work" ]
  count="$(registry_account_count)"
  [ "$count" -eq 1 ]
  default="$(registry_get_default_name)"
  [ "$default" = "personal" ]
}

@test "remove-account.sh deletes the registry when removing the last account" {
  registry_remove_account "work"  # remove work directly so only personal remains
  run bash "$BATS_TEST_DIRNAME/../setup/remove-account.sh" --name personal
  [ "$status" -eq 0 ]
  [ ! -f "$REGISTRY" ]
}

@test "remove-account.sh exits nonzero for unknown account name" {
  run bash "$BATS_TEST_DIRNAME/../setup/remove-account.sh" --name nonexistent
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run the tests; verify they fail**

```bash
bats google-services/tests/remove-account.bats
```

Expected: all fail with "remove-account.sh: No such file or directory".

- [ ] **Step 3: Write the script**

Create `google-services/setup/remove-account.sh`:

```bash
#!/usr/bin/env bash
# remove-account.sh
# Removes an account from a multi-account YouCoded setup.
#
# Steps:
#   1. Run `gws auth logout` against the account's config dir to revoke the
#      refresh token at Google's end.
#   2. Delete the config dir contents.
#   3. Remove the registry entry.
#   4. If the registry now has zero accounts, delete the registry file.
#
# Usage:
#   remove-account.sh --name <name>
#
# Exit codes:
#   0 — removed (or already gone)
#   1 — bad arguments / unknown account name

set -u

# shellcheck source=../lib/registry.sh
source "$(dirname "$0")/../lib/registry.sh"

NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "Usage: remove-account.sh --name <name>" >&2
  exit 1
fi

CONFIG_DIR="$(registry_get_config_dir "$NAME")"
if [ -z "$CONFIG_DIR" ]; then
  echo "No account named '$NAME' in registry." >&2
  exit 1
fi

# 1. Revoke at Google's end. Best-effort — proceed regardless of outcome.
GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$CONFIG_DIR" \
GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
gws auth logout >/dev/null 2>&1 || \
  echo "  (couldn't reach Google to revoke the token; the local connection is removed regardless)"

# 2. Delete the config dir.
rm -rf "$CONFIG_DIR"

# 3. Remove the registry entry.
registry_remove_account "$NAME"

# 4. If no accounts remain, delete the registry.
if [ "$(registry_account_count)" = "0" ]; then
  registry_destroy
fi

exit 0
```

- [ ] **Step 4: Run the tests; verify they pass**

```bash
chmod +x google-services/setup/remove-account.sh
bats google-services/tests/remove-account.bats
```

Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add google-services/setup/remove-account.sh google-services/tests/remove-account.bats
git commit -m "feat(google-services): remove-account.sh

Revokes the refresh token via gws auth logout (best-effort), deletes the
account's config dir, removes the registry entry, and deletes the registry
file when the last account is removed."
```

---

## Phase 6 — In-conversation routing protocol

### Task 10: Add "Account selection" section to gws-shared/SKILL.md

**Files:**
- Modify: `google-services/skills/gws-shared/SKILL.md`

- [ ] **Step 1: Insert a new "Account selection" section**

Insert immediately after the existing `## Authentication` section (currently around line 19-27 in the file). The new section becomes the canonical protocol that all gws-* skills reference.

```markdown
## Account selection

A single user may have multiple Google accounts connected (e.g., personal + work). The `gws-*` skills coordinate which account each operation uses.

### State on disk

- `~/.config/gws-profiles.json` — registry of connected accounts, the default, and emails the user mentioned at setup as "may want to add later." Created the first time a multi-account event happens; absent for single-account installs.
- `~/.config/gws/` — default account's config dir (always).
- `~/.config/gws-<name>/` — secondary account's config dir.

### Active-account state

There is **no on-disk file tracking which account the current conversation is using.** The active account lives in conversation memory only. You (Claude) carry it through the conversation; a fresh conversation starts with no active account.

### Routing protocol — first gws action of a conversation

Before invoking gws for the first time in a conversation:

1. Read `~/.config/gws-profiles.json`.
   - If the file doesn't exist AND `~/.config/gws/credentials.enc` exists → single-account world; use `~/.config/gws/`, no question.
   - If neither exists → zero-account state; tell the user "You haven't connected a Google account yet — run /google-services-setup first" and stop.
2. If the registry has only one account → use it, no question.
3. If the registry has multiple accounts → ask the user, with the default highlighted and action-aware phrasing:

   > Okay to send this from your **personal** account (default)? Or use **work**?

   Wording adapts to the action: "save this to," "send this from," "fetch this from," "search in." Never use technical terms like "config dir," "profile," "account ID," "OAuth," "credentials," or "scope."

4. Once the user picks, remember the choice for the rest of the conversation. Subsequent gws calls use the same account without re-asking, **except for Drive operations** (see below).

### Routing protocol — Drive operations

Every direct user-initiated Drive operation re-confirms the account, even if the conversation has an established active account from a prior Gmail/Calendar/Sheets interaction:

> Did you want that uploaded to your **work** account, or your **personal** one?

Granularity is **per user-initiated Drive task**, not per API call. If the user says "upload these 5 files," that's one task → one confirm; the skill loops the 5 files using the chosen account. If the user later says "now upload another," that's a new task → new confirm.

### Routing protocol — explicit switches

When the user says "use my work account for the next one" or "send this from work instead," update the conversation-memory active account immediately and route the next call to the new account.

### Invoking gws

Every gws invocation in every gws-* skill MUST prepend the two env vars that route to the active account's config dir:

```bash
GOOGLE_WORKSPACE_CLI_CONFIG_DIR="<active configDir>" \
GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
gws ...
```

For single-account installs, `<active configDir>` is `~/.config/gws/` and `KEYRING_BACKEND=file` is harmless — behavior is identical to the pre-multi-account flow.

### Reading the registry from a skill

Skills do not source `lib/registry.sh` directly. Read the JSON via standard tools:

```bash
DEFAULT="$(jq -r '.default // empty' "$HOME/.config/gws-profiles.json" 2>/dev/null)"
DEFAULT_DIR="$(jq -r --arg d "$DEFAULT" '.accounts[] | select(.name==$d) | .configDir' "$HOME/.config/gws-profiles.json" 2>/dev/null)"
```

If `~/.config/gws-profiles.json` doesn't exist, fall back to `$HOME/.config/gws/`.
```

- [ ] **Step 2: Commit**

```bash
git add google-services/skills/gws-shared/SKILL.md
git commit -m "feat(gws-shared): document multi-account routing protocol

Adds an Account selection section that's the canonical source of truth for
how gws-* skills decide which account to use. Covers first-action confirm,
Drive always-confirm, explicit switching, env-var prepending, and reading
the registry. All other gws-* skills will reference this section."
```

### Task 11: Add protocol reference to all Gmail skills

**Files:**
- Modify: `google-services/skills/gws-gmail/SKILL.md`
- Modify: `google-services/skills/gws-gmail-send/SKILL.md`
- Modify: `google-services/skills/gws-gmail-read/SKILL.md`
- Modify: `google-services/skills/gws-gmail-reply/SKILL.md`
- Modify: `google-services/skills/gws-gmail-reply-all/SKILL.md`
- Modify: `google-services/skills/gws-gmail-forward/SKILL.md`
- Modify: `google-services/skills/gws-gmail-triage/SKILL.md`
- Modify: `google-services/skills/gws-gmail-watch/SKILL.md`

- [ ] **Step 1: In each Gmail skill, find the existing PREREQUISITE line**

Each skill has a line like:

```markdown
> **PREREQUISITE:** Read `../gws-shared/SKILL.md` for auth, global flags, and security rules. If missing, run `gws generate-skills` to create it.
```

- [ ] **Step 2: Replace it with the account-selection-aware version**

In each of the 8 Gmail skill files, replace the PREREQUISITE line above with:

```markdown
> **PREREQUISITE:** Read `../gws-shared/SKILL.md` for auth, global flags, security rules, and **account selection** — every gws invocation must follow the routing protocol there (first-action confirm; env-var-routed config dir). If missing, run `gws generate-skills` to create it.

> **MULTI-ACCOUNT:** All `gws ...` examples below show the bare command for readability. At invocation time, prepend the env-var routing from gws-shared's Account selection section: `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=<active configDir> GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file gws ...`.
```

This adds a second blockquote right after the existing one. The existing example invocations stay clean; the multi-account note documents the wrap. Apply the same two-line change verbatim to all 8 Gmail skill files.

- [ ] **Step 3: Commit**

```bash
git add google-services/skills/gws-gmail*/SKILL.md
git commit -m "docs(gws-gmail): reference multi-account routing protocol

Every gmail skill's PREREQUISITE line now points to gws-shared's Account
selection section, plus a second-line note describing the env-var-prepend
pattern that wraps every example at invocation time."
```

### Task 12: Add protocol reference + Drive-always-confirm to Drive skills

**Files:**
- Modify: `google-services/skills/gws-drive/SKILL.md`
- Modify: `google-services/skills/gws-drive-upload/SKILL.md`

- [ ] **Step 1: In each Drive skill, replace the PREREQUISITE line**

In both Drive skill files, replace the existing PREREQUISITE line with these three blockquotes (the same two-line PREREQUISITE+MULTI-ACCOUNT pattern from Task 11, plus a Drive-specific re-confirm reminder):

```markdown
> **PREREQUISITE:** Read `../gws-shared/SKILL.md` for auth, global flags, security rules, and **account selection** — every gws invocation must follow the routing protocol there (first-action confirm; env-var-routed config dir). If missing, run `gws generate-skills` to create it.

> **MULTI-ACCOUNT:** All `gws ...` examples below show the bare command for readability. At invocation time, prepend the env-var routing from gws-shared's Account selection section: `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=<active configDir> GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file gws ...`.

> **DRIVE NOTE:** Per the account selection protocol in gws-shared, every direct user-initiated Drive operation **re-confirms** which account to use, even if the conversation has an established active account. Granularity is per user-initiated task — a "upload these 5 files" task = one confirm, not five.
```

- [ ] **Step 2: Commit**

```bash
git add google-services/skills/gws-drive*/SKILL.md
git commit -m "docs(gws-drive): reference multi-account protocol + always-re-confirm rule

Drive ops re-confirm account selection per user-initiated task even when a
prior Gmail/Calendar/Sheets call has set an active account in conversation
memory."
```

### Task 13: Add protocol reference to Sheets, Docs, Slides, Calendar skills

**Files:**
- Modify: `google-services/skills/gws-sheets/SKILL.md`
- Modify: `google-services/skills/gws-sheets-read/SKILL.md`
- Modify: `google-services/skills/gws-sheets-append/SKILL.md`
- Modify: `google-services/skills/gws-docs/SKILL.md`
- Modify: `google-services/skills/gws-docs-write/SKILL.md`
- Modify: `google-services/skills/gws-slides/SKILL.md`
- Modify: `google-services/skills/gws-calendar/SKILL.md`
- Modify: `google-services/skills/gws-calendar-agenda/SKILL.md`
- Modify: `google-services/skills/gws-calendar-insert/SKILL.md`

- [ ] **Step 1: In each of the 9 skills, replace the PREREQUISITE line**

Replace the existing PREREQUISITE line in each file with the same two-blockquote pattern from Task 11 step 2:

```markdown
> **PREREQUISITE:** Read `../gws-shared/SKILL.md` for auth, global flags, security rules, and **account selection** — every gws invocation must follow the routing protocol there (first-action confirm; env-var-routed config dir). If missing, run `gws generate-skills` to create it.

> **MULTI-ACCOUNT:** All `gws ...` examples below show the bare command for readability. At invocation time, prepend the env-var routing from gws-shared's Account selection section: `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=<active configDir> GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file gws ...`.
```

Apply verbatim to each of: `gws-sheets`, `gws-sheets-read`, `gws-sheets-append`, `gws-docs`, `gws-docs-write`, `gws-slides`, `gws-calendar`, `gws-calendar-agenda`, `gws-calendar-insert`.

- [ ] **Step 2: Commit**

```bash
git add google-services/skills/gws-sheets*/SKILL.md \
        google-services/skills/gws-docs*/SKILL.md \
        google-services/skills/gws-slides/SKILL.md \
        google-services/skills/gws-calendar*/SKILL.md
git commit -m "docs(gws-sheets,docs,slides,calendar): reference multi-account protocol

Every non-Gmail/Drive gws-* skill now references gws-shared's Account
selection section, plus the env-var-prepend note."
```

---

## Phase 7 — Reauth update

### Task 14: youcoded-gws-reauth — per-account refresh + opportunistic top-up

**Files:**
- Modify: `google-services/skills/youcoded-gws-reauth/SKILL.md`

- [ ] **Step 1: Read current youcoded-gws-reauth/SKILL.md**

```bash
cat google-services/skills/youcoded-gws-reauth/SKILL.md
```

(Already known structure: trigger patterns, recovery procedure, do-not list. Need to expand all three.)

- [ ] **Step 2: Replace the file with the multi-account-aware version**

Overwrite `google-services/skills/youcoded-gws-reauth/SKILL.md`:

```markdown
---
name: youcoded-gws-reauth
description: "Use when any Google Workspace command (gws gmail, gws drive, gws docs, gws sheets, gws slides, gws calendar) fails with an authentication error — invalid_grant, invalid_token, token has been expired or revoked, unauthorized_client, authorization required, or HTTP 401. Transparently runs the re-auth helper and retries the failed command so the user's original request completes without them needing to reconnect manually. Multi-account aware: identifies which account expired and offers an opportunistic top-up if other accounts are also stale."
---

# YouCoded: Google auto-reauth

Google OAuth refresh tokens last 7 days for unverified apps. Each connected account expires independently. When one lapses, gws commands against that account fail with auth errors. This skill handles recovery seamlessly so the user never has to run a slash command or think about it.

## Trigger

Any gws command fails with stderr or stdout containing one of:

- `invalid_grant`
- `invalid_token`
- `token has been expired or revoked`
- `unauthorized_client`
- `AuthenticationError`
- `authorization is required`
- `"code": 401`
- `"token_valid": false` (when checking `gws auth status`)

## Recovery procedure

1. Identify which account expired. The skill that just invoked gws set `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` for the call; that's the failing config dir. Map it to a human-readable name by reading the registry:

   ```bash
   FAILED_DIR="<config dir from the failing skill's invocation>"
   FAILED_NAME="$(jq -r --arg dir "$FAILED_DIR" \
     '.accounts[] | select(.configDir == $dir) | .name' \
     "$HOME/.config/gws-profiles.json" 2>/dev/null)"
   ```

   For single-account installs (no registry), the name is implicitly the user's only account; the user-facing copy can omit the name.

2. Tell the user in one short sentence: "Your [name] Google connection needs a quick refresh — opening your browser." For single-account installs, drop the "[name]" — just say "your Google connection."

3. Run:

   ```bash
   bash "$CLAUDE_PLUGIN_ROOT/setup/reauth.sh" --config-dir "$FAILED_DIR"
   ```

4. The helper prints a Google auth URL on a line starting with two spaces. Extract it and open for the user:

   ```bash
   URL=$(grep -m1 "^  https://accounts.google.com" <helper-stdout> | sed 's/^  //')
   bash "$CLAUDE_PLUGIN_ROOT/setup/open-browser.sh" "$URL"
   ```

5. Wait for the helper to exit. On exit 0, the original failing call's account is refreshed.

6. **Opportunistic top-up.** If the registry exists and lists more than one account, check the others' status:

   ```bash
   while IFS=$'\t' read -r name email config_dir; do
     [ "$name" = "$FAILED_NAME" ] && continue  # skip the one we just refreshed
     valid="$(GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$config_dir" \
              GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
              gws auth status --format json 2>/dev/null | \
              jq -r '.token_valid // false')"
     if [ "$valid" = "false" ]; then
       echo "$name"
     fi
   done < <(jq -r '.accounts[] | "\(.name)\t\(.email)\t\(.configDir)"' \
            "$HOME/.config/gws-profiles.json" 2>/dev/null)
   ```

   If any other accounts are expired, ask the user once:

   > "Refreshed your [first name] connection. Your [other name] connection is also expired — want me to refresh that too while we're here?"

   Use `AskUserQuestion`:
   - "Yes, refresh it" → run reauth.sh against that account's config dir; loop for any remaining expired ones.
   - "Not now" → carry on.

7. **Retry the original gws command** that failed, with the SAME `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` env var set. The user's request continues from where it left off.

8. On reauth.sh exit nonzero (user closed browser, network error, no saved credentials): stop and say "Your Google connection didn't refresh. Run /google-services-setup if it keeps happening."

## Do not

- **Do not** ask the user whether to reconnect — just do it. This is a routine, expected event every 7 days; a confirmation prompt is noise.
- **Do not** surface technical terms ("token," "OAuth," "refresh," "expired," "scope," "credentials") to the user. "Your Google connection needs a quick refresh" is the whole explanation they need.
- **Do not** re-run `/google-services-setup` — that's only for first-time setup or when reauth itself fails. Reauth alone is enough here.
- **Do not** force the user through the opportunistic top-up if they decline. One prompt per refresh; never re-ask within the same conversation.
```

- [ ] **Step 3: Commit**

```bash
git add google-services/skills/youcoded-gws-reauth/SKILL.md
git commit -m "feat(youcoded-gws-reauth): per-account refresh + opportunistic top-up

Identifies the failing account by reading the registry against the
GOOGLE_WORKSPACE_CLI_CONFIG_DIR the calling skill used. After a successful
refresh, checks status of all other accounts and offers (one prompt) to
refresh any other expired ones in the same browser session."
```

---

## Phase 8 — New skills

### Task 15: gws-account-management skill

**Files:**
- Create: `google-services/skills/gws-account-management/SKILL.md`

- [ ] **Step 1: Create the skill**

Create `google-services/skills/gws-account-management/SKILL.md`:

```markdown
---
name: gws-account-management
description: "Use when the user wants to add, remove, list, or change the default across their connected Google accounts in YouCoded. Triggers on phrases like 'add my work account', 'connect another Google account', 'remove that account', 'switch default to personal', 'use my work account by default', 'which Google accounts do I have', 'list my accounts'. Routes the request into /google-services-setup, which has a management menu when the user already has accounts set up."
metadata:
  openclaw:
    category: "productivity"
---

# Google account management (multi-account routing)

This is a thin routing skill — it doesn't do anything itself; it sends the user into `/google-services-setup`, which detects the existing registry and opens the right menu.

## When to invoke

Any phrase from the user that reads as managing their connected Google accounts (not actually using them — sending email, etc.):

- "add my work account"
- "connect another Google account"
- "remove that account"
- "remove my work connection"
- "switch default to personal"
- "use my work account as the default"
- "which accounts do I have connected"
- "show my Google accounts"

## Action

For account-listing requests ("show my Google accounts," "which accounts do I have"), answer directly:

```bash
if [ -f "$HOME/.config/gws-profiles.json" ]; then
  jq -r '
    "Default: \(.default // "none")\n\nAccounts:\n" +
    (.accounts | map("- \(.name) (\(.email))") | join("\n"))
  ' "$HOME/.config/gws-profiles.json"
else
  if [ -f "$HOME/.config/gws/credentials.enc" ]; then
    echo "You have one Google account connected."
  else
    echo "No Google accounts connected. Run /google-services-setup to set one up."
  fi
fi
```

For management requests (add / remove / change default), suggest the slash command:

> "I can run /google-services-setup — it'll open the account-management menu. Want me to?"

If the user agrees, invoke the slash command (handle as a normal slash-command-from-skill flow). Pass through the user's intent so the slash command can pre-pick the menu option:

- "add" → user picks "Add another account"
- "remove" → user picks "Remove an account"
- "default" → user picks "Change default"

## Do not

- **Do not** call `add-account.sh` or `remove-account.sh` directly from this skill. They have prerequisites (knownTestUsers state, pre-existing config dirs) that the slash command sets up. Always route through the slash command.
- **Do not** invoke `/google-services-setup` for actual *use* of an account ("send an email from work" is not management — that's a gws-gmail-send call with the account-selection protocol from gws-shared).
```

- [ ] **Step 2: Verify file exists and is well-formed**

```bash
test -f google-services/skills/gws-account-management/SKILL.md
head -5 google-services/skills/gws-account-management/SKILL.md
# Expected: starts with --- name: gws-account-management ...
```

- [ ] **Step 3: Commit**

```bash
git add google-services/skills/gws-account-management/SKILL.md
git commit -m "feat(google-services): gws-account-management skill

Natural-language routing for 'add my work account', 'remove that account',
'switch default', 'list my accounts'. Lists accounts directly from the
registry; routes management actions into /google-services-setup's menu."
```

### Task 16: gws-transfer skill (Drive copy)

**Files:**
- Create: `google-services/skills/gws-transfer/SKILL.md`

- [ ] **Step 1: Create the skill with Drive-copy section first**

Create `google-services/skills/gws-transfer/SKILL.md`:

```markdown
---
name: gws-transfer
description: "Use when the user wants to copy or move content between two of their connected Google accounts — phrases like 'copy this work doc to my personal Drive', 'save this email to my personal account', 'duplicate this work calendar event to personal', 'move that file to my personal Drive'. Handles cross-account transfer of Drive files/folders, Gmail messages, and Calendar events. v1 is copy-only (no source-side delete)."
metadata:
  openclaw:
    category: "productivity"
    requires:
      bins:
        - gws
---

# Cross-account transfer

> **PREREQUISITE:** Read `../gws-shared/SKILL.md` for auth, global flags, and the **account selection** routing protocol. This skill diverges from the standard protocol — for transfers, both source and destination are explicit, not inferred from conversation memory.

Copy a Google resource from one of the user's connected Google accounts into another. v1 supports Drive files, Drive folders, Gmail messages/threads, and Calendar events.

## Universal confirmation pattern

ALWAYS confirm both source and destination explicitly before any transfer:

> "Copying [resource description] from your **[source-name]** [service] to your **[dest-name]** [service]. Confirm?"

Both account names are bolded for visual disambiguation. Do NOT assume the conversation's active account is the destination — for transfers, both ends are always explicit.

## Drive — file or folder copy

For a single Drive file:

```bash
SRC_DIR="<source account configDir from registry>"
DST_DIR="<dest account configDir from registry>"
FILE_ID="<source file ID>"
TEMP="$(mktemp)"

# 1. Read source file metadata to get name and mimeType
META="$(GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$SRC_DIR" \
        GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
        gws drive files get --params "{\"fileId\":\"$FILE_ID\",\"fields\":\"id,name,mimeType\"}")"
NAME="$(echo "$META" | jq -r '.name')"
MIME="$(echo "$META" | jq -r '.mimeType')"

# 2. Download. Native Google types (Docs/Sheets/Slides) need files.export.
case "$MIME" in
  application/vnd.google-apps.document)
    GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$SRC_DIR" GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
      gws drive files export -o "$TEMP" \
      --params "{\"fileId\":\"$FILE_ID\",\"mimeType\":\"application/vnd.openxmlformats-officedocument.wordprocessingml.document\"}"
    UPLOAD_MIME="application/vnd.google-apps.document"  # re-imports as Doc
    ;;
  application/vnd.google-apps.spreadsheet)
    GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$SRC_DIR" GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
      gws drive files export -o "$TEMP" \
      --params "{\"fileId\":\"$FILE_ID\",\"mimeType\":\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\"}"
    UPLOAD_MIME="application/vnd.google-apps.spreadsheet"
    ;;
  application/vnd.google-apps.presentation)
    GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$SRC_DIR" GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
      gws drive files export -o "$TEMP" \
      --params "{\"fileId\":\"$FILE_ID\",\"mimeType\":\"application/vnd.openxmlformats-officedocument.presentationml.presentation\"}"
    UPLOAD_MIME="application/vnd.google-apps.presentation"
    ;;
  *)
    GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$SRC_DIR" GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
      gws drive files get -o "$TEMP" --params "{\"fileId\":\"$FILE_ID\",\"alt\":\"media\"}"
    UPLOAD_MIME="$MIME"
    ;;
esac

# 3. Upload to destination
GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$DST_DIR" GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
  gws drive files create --upload "$TEMP" \
  --json "{\"name\":\"$NAME\"}" \
  --upload-content-type "$UPLOAD_MIME"

# 4. Cleanup
rm -f "$TEMP"
```

For a folder, recurse: list the folder's children with `gws drive files list --params '{"q":"\\"<FOLDER_ID>\\" in parents"}' --page-all`, create a new folder in destination with `mimeType=application/vnd.google-apps.folder`, then copy each child into it. Stream progress to the user: "Copied 12 of 47 files…"

## Gmail — save a message or thread to another account

```bash
SRC_DIR="<source account configDir>"
DST_DIR="<dest account configDir>"
MSG_ID="<source message ID>"

# Get the raw RFC 822 message bytes from source
RAW="$(GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$SRC_DIR" GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
  gws gmail users messages get --params "{\"userId\":\"me\",\"id\":\"$MSG_ID\",\"format\":\"raw\"}" \
  | jq -r '.raw')"

# Insert into destination's mailbox without going through SMTP delivery
GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$DST_DIR" GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
  gws gmail users messages insert --params "{\"userId\":\"me\"}" \
  --json "{\"raw\":\"$RAW\"}"
```

For a whole thread, get the thread first (`gws gmail users threads get`), iterate over `.messages[]`, and insert each one into the destination. The destination's Gmail will not group them as a single thread automatically (different RFC References / Message-IDs); this is a known limitation.

Tell the user upfront: "Labels won't carry over (different label IDs across accounts). Want me to apply a target label like 'from-work' on the imported message?" If yes, run `gws gmail users labels create` (idempotent) then `gws gmail users messages modify` to apply it.

## Calendar — copy an event

```bash
SRC_DIR="<source account configDir>"
DST_DIR="<dest account configDir>"
EVENT_ID="<source event ID>"
SRC_CAL="${SRC_CAL:-primary}"
DST_CAL="${DST_CAL:-primary}"

# Get source event
EVENT="$(GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$SRC_DIR" GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
  gws calendar events get --params "{\"calendarId\":\"$SRC_CAL\",\"eventId\":\"$EVENT_ID\"}")"

# Strip fields that don't transfer cleanly: id, organizer, attendees, conferenceData
PAYLOAD="$(echo "$EVENT" | jq 'del(.id, .iCalUID, .organizer, .attendees, .conferenceData, .htmlLink, .creator, .etag, .kind)')"

# Insert into destination
GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$DST_DIR" GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
  gws calendar events insert --params "{\"calendarId\":\"$DST_CAL\"}" \
  --json "$PAYLOAD"
```

Tell the user upfront: "Attendees, ACL, and the original organizer don't transfer. The event becomes a new event you own. Existing attendees won't be notified."

## Failure handling

If the source-read step fails: report and stop. No destination state changed.

If the source-read succeeds but the destination-write fails: report clearly:

> "Read from [source-name] succeeded, but writing to [dest-name] failed: [error]. Nothing was changed in your [source-name] account."

For Drive folder transfers (multi-step), report partial progress: "Copied 12 of 47 files before failing on file 13: [error]. The 12 already copied are in your [dest-name] Drive."

## Out of scope

- **Move** (copy + delete-from-source). v1 is copy-only.
- **Drive permission/share-link cloning.** Cross-account permission grants require the destination user to invite source-account collaborators by email — not a thing the skill can do silently.
- **Bulk transfer of an entire account.** Use Google Takeout instead.

## Do not

- **Do not** infer the destination from conversation memory. Both ends are always explicit, always confirmed.
- **Do not** delete from the source after successful copy. v1 is copy-only.
- **Do not** assume the user wants identical labels (Gmail) or attendees (Calendar) on the destination — surface the loss explicitly.
```

- [ ] **Step 2: Commit**

```bash
git add google-services/skills/gws-transfer/SKILL.md
git commit -m "feat(google-services): gws-transfer skill (Drive/Gmail/Calendar)

Cross-account copy for v1: Drive files/folders (with Docs/Sheets/Slides
export+import), Gmail messages/threads via users.messages.insert,
Calendar events via events.insert. Always confirms both source and
destination explicitly. Copy-only — move is deferred to v2."
```

---

## Phase 9 — Verification

### Task 17: Update DEV-VERIFICATION.md with multi-account smoke tests

**Files:**
- Modify: `google-services/docs/DEV-VERIFICATION.md`

- [ ] **Step 1: Read the current DEV-VERIFICATION.md**

```bash
cat google-services/docs/DEV-VERIFICATION.md
```

- [ ] **Step 2: Append a "Multi-account verification (2026-04-29)" section**

Append at the end of the file:

```markdown
---

## Multi-account verification (2026-04-29)

Six smoke tests added with multi-account support. Run after any change to the registry library, add/remove/reauth scripts, or the gws-shared protocol.

### 1. Single-account regression smoke

Goal: verify the new env-var routing + `KEYRING_BACKEND=file` change doesn't break existing single-account installs.

```bash
# Pre: a working single-account setup at ~/.config/gws/.
GWS_CONFIG_DIR="$HOME/.config/gws" bash google-services/setup/smoke-test.sh
```

Expected: all 6 ✓ outputs, exit 0. Same as pre-multi-account behavior.

### 2. Two-account fast-path smoke

```bash
# 1. Pre: existing setup. Run /google-services-setup → pick "Add another account."
# 2. Use a second personal Gmail you've already added to Test Users.
# 3. After completion, verify:
test -d "$HOME/.config/gws-second"
test -f "$HOME/.config/gws-profiles.json"
jq '.accounts | length' "$HOME/.config/gws-profiles.json"  # → 2
GWS_CONFIG_DIR="$HOME/.config/gws-second" bash google-services/setup/smoke-test.sh  # → all ✓
```

### 3. Two-account slow-path smoke

Same as #2 but with a deliberately-locked-down Workspace account that rejects the existing OAuth client. add-account.sh should exit 2 on fast-path; the slash command falls back to slow-path. Verify the account ends up with `ownsGcpProject: true` in the registry, and that a separate GCP project was created.

### 4. First-action confirmation smoke

```bash
# Pre: registry has 2+ accounts, one default.
# In a fresh chat conversation, ask Claude: "send a quick test email to myself"
# Expected: Claude asks "Okay to send this from your <default> account, or use <other>?"
# Choose <other>. Claude sends the email from <other>'s account.
```

### 5. Drive-always-confirm smoke

```bash
# Same conversation as #4 — Claude has now established <other> as the active account.
# Ask: "Find my budget spreadsheet"
# Expected: Claude RE-confirms: "Did you want to search your <default> Drive or your <other> Drive?"
# Even though Gmail just used <other>.
```

### 6. Reauth + opportunistic top-up smoke

```bash
# Pre: 2 accounts, one of them has a stale token (wait 7 days, or revoke at https://myaccount.google.com/permissions).
# Trigger any gws-* skill against the stale account.
# Expected:
# - Claude says "Your <name> connection needs a quick refresh — opening your browser"
# - After successful refresh, IF other accounts also have stale tokens:
#   "Refreshed your <name>. Your <other> connection is also expired — refresh that too?"
# - On "Yes," reauth runs against <other> too.
# - Original failing call is retried successfully.
```

### Keyring migration outcome (record once, on the implementer's machine)

When KEYRING_BACKEND=file is first applied to an existing single-account install whose AES key is currently in Windows Credential Manager / macOS Keychain / Linux Secret Service, what happens on the first gws call?

- [ ] **Outcome A** (silent migration): `gws auth status` succeeds; gws transparently fell back to the OS keyring for the AES key, with the file getting written on the next `auth login`.
- [ ] **Outcome B** (forced reauth on upgrade): `gws auth status` reports a decryption failure or empty state; the user reauths once and the file is populated.

Date verified: ____________
Outcome: ______
Notes: ____________
```

- [ ] **Step 3: Commit**

```bash
git add google-services/docs/DEV-VERIFICATION.md
git commit -m "docs(google-services): add multi-account verification smoke tests

Six smoke tests (single-account regression, two-account fast/slow paths,
first-action confirm, Drive-always-confirm, reauth top-up) plus a slot for
recording the keyring-migration behavior on first upgrade."
```

### Task 18: End-to-end manual verification

**No code in this task** — this is a hands-on validation step the implementer runs before opening the PR.

- [ ] **Step 1: Run smoke test 1** (single-account regression). Verify all 6 services still pass for the existing single-account install.

- [ ] **Step 2: Run smoke test 2** (two-account fast-path). Use a second Gmail address. Verify Test Users list, registry shape, smoke test against the new account, and first-action confirmation in a fresh conversation.

- [ ] **Step 3: Run smoke tests 4-5** (first-action confirm, Drive always-confirm). Verify the account-selection prompts appear at the right moments and Drive re-confirms even when prior Gmail/Calendar set an active account.

- [ ] **Step 4: Run smoke test 6** (reauth top-up). Either wait 7 days or manually revoke a token at https://myaccount.google.com/permissions to force reauth. Verify the account name appears in the prompt and the opportunistic top-up offers other expired accounts.

- [ ] **Step 5: Record the keyring-migration outcome** in DEV-VERIFICATION.md.

- [ ] **Step 6: Run the bats test suite**

```bash
bats google-services/tests/registry.bats
bats google-services/tests/add-account.bats
bats google-services/tests/remove-account.bats
```

Expected: all pass.

- [ ] **Step 7: Open a PR**

```bash
git push origin feat/google-services-multi-account
gh pr create --title "feat(google-services): multi-account support" \
  --body "$(cat <<'EOF'
## Summary

- Adds support for connecting multiple Google accounts (e.g., personal + work) to the google-services plugin
- Per-account config dirs (`~/.config/gws/` for default, `~/.config/gws-<name>/` for secondaries) isolated via `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` + `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file`
- Registry at `~/.config/gws-profiles.json` tracks accounts + default
- New cross-account transfer skill (Drive copy, Gmail save, Calendar copy)
- New account-management skill for natural-language routing
- Multi-account-aware reauth with opportunistic top-up

Spec: youcoded-dev/docs/superpowers/specs/2026-04-29-google-services-multi-account-design.md

## Test plan

- [ ] Single-account regression smoke (DEV-VERIFICATION.md test 1)
- [ ] Two-account fast-path smoke (test 2)
- [ ] First-action confirmation smoke (test 4)
- [ ] Drive-always-confirm smoke (test 5)
- [ ] Reauth + opportunistic top-up smoke (test 6)
- [ ] Keyring-migration outcome recorded
- [ ] All bats tests pass

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review checklist for the implementer

Before requesting review on the PR:

- [ ] Every gws invocation across all SKILL.md files prepends BOTH `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` and `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file`. Grep:
  ```bash
  grep -rn 'gws ' google-services/skills/ | grep -v 'GOOGLE_WORKSPACE_CLI_CONFIG_DIR'
  ```
  All hits should be either documentation prose (not actual invocation) or already wrapped.

- [ ] No skill references `marker file`, `active account file`, or any on-disk-active-state artifact.

- [ ] All 6 DEV-VERIFICATION.md smoke tests pass on the implementer's machine.

- [ ] Registry JSON shape matches the spec exactly: `default`, `accounts[].{name,email,configDir,ownsGcpProject,gcpProjectId}`, `knownTestUsers[]`.

- [ ] `lib/registry.sh` is sourced (not invoked as a script) by every consumer; never has a `main` entry point.

- [ ] Keyring-migration outcome (A or B) is recorded in DEV-VERIFICATION.md with date.
