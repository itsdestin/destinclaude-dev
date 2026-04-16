# Google Services Bundle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `google-services` marketplace plugin — one installable bundle that connects a user's Gmail, Drive, Docs, Sheets, Slides, and Calendar via `googleworkspace/cli` (`gws`) with a single setup command that automates GCP project provisioning via `gcloud`.

**Architecture:** Six sibling skills (`skills/gmail/`, `skills/google-drive/`, etc.) under one plugin, plus a `/google-services-setup` slash command that installs helper tools, bootstraps the user's personal GCP project, grants OAuth scopes, and runs read-only probes. No custom MCP; skills call `gws` directly. All auth state owned by `gws` keyring, never by the plugin.

**Tech Stack:** Bash scripts, Markdown skills with YAML frontmatter, JSON manifests, `gws` (Rust CLI), `gcloud` (Google Cloud SDK), `shellcheck` for script linting.

**Spec:** [docs/superpowers/specs/2026-04-16-google-services-design.md](../specs/2026-04-16-google-services-design.md). Keep the spec open while implementing — every task references a spec section.

**Cross-repo scope.** Implementation touches three repos:
- `wecoded-marketplace/` — the new plugin (majority of work)
- `youcoded-core/` — one hook edit (tool-router.sh)
- `wecoded-marketplace/youcoded-messaging/` — delete the `imessages/` subdirectory

**Worktree rule (from workspace CLAUDE.md).** Create isolated worktrees for each repo being modified. Work within them, merge + push at phase boundaries.

---

## Phase 0 — Research (unblocks implementation)

Resolve all three open research items from the spec before writing any plugin code. If any comes back unfavorable, stop and return to brainstorming — do not proceed blind.

### Task 0.1: Resolve 7-day refresh-token expiry question

**Spec reference:** Open Research Item 1.

**Files:**
- Create (temporary, delete after): throwaway test GCP project (in Destin's Google account)
- Create: `docs/superpowers/plans/research/2026-04-16-refresh-token-findings.md`

- [ ] **Step 1: Read current Google OAuth policy docs**

Visit https://developers.google.com/identity/protocols/oauth2 and https://support.google.com/cloud/answer/10311615. Document what they say (as of research date) about refresh-token lifetime for External-type apps in "Testing" publishing status with sensitive scopes like `gmail.modify`, `drive`, `calendar`.

Write findings to `docs/superpowers/plans/research/2026-04-16-refresh-token-findings.md` under heading "Policy read."

- [ ] **Step 2: Provision a real test project with Gmail sensitive scope**

Run:
```bash
gcloud projects create youcoded-refresh-test-$(date +%s) --name="Refresh Test"
gcloud config set project youcoded-refresh-test-<id>
gcloud services enable gmail.googleapis.com
# Create OAuth brand + client (use gcloud alpha iap oauth-brands / oauth-clients)
# Complete OAuth flow requesting scope https://www.googleapis.com/auth/gmail.modify
# Record token issued_at timestamp and refresh_token value
```

Document the commands used and token details in the findings file under "Test project provisioning."

- [ ] **Step 3: Wait 8-10 days, attempt token refresh**

Do not touch the project. After 8-10 days, attempt to use the refresh token. Record outcome:
- SUCCESS → the 7-day policy does not apply or has been lifted
- FAIL with `invalid_grant` → policy still applies

Document in findings file under "Refresh attempt result."

- [ ] **Step 4: Write conclusion + recommendation**

In the findings doc, write a "Conclusion" section with one of:
- **GREEN:** 7-day expiry no longer applies. Proceed with user-brings-own OAuth as speced.
- **YELLOW:** Expiry applies BUT `gws` has a workaround (document the workaround).
- **RED:** Expiry applies with no workaround. Recommend which fallback from the spec to pursue: (a) narrow scopes, (b) verified app, (c) weekly re-auth.

- [ ] **Step 5: Commit findings**

```bash
cd C:/Users/desti/youcoded-dev
git add docs/superpowers/plans/research/2026-04-16-refresh-token-findings.md
git commit -m "research: resolve 7-day refresh-token question for google-services spec

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Tear down the throwaway project**

```bash
gcloud projects delete youcoded-refresh-test-<id>
```

### Task 0.2: Resolve gcloud External-consent automation question

**Spec reference:** Open Research Item 2.

**Files:**
- Create (temporary, delete after): throwaway test GCP project
- Create: `docs/superpowers/plans/research/2026-04-16-oauth-brand-automation.md`

- [ ] **Step 1: Attempt end-to-end brand + client creation via gcloud alone**

Run (replace IDs/emails as needed):
```bash
PROJECT_ID=youcoded-brand-test-$(date +%s)
gcloud projects create $PROJECT_ID
gcloud config set project $PROJECT_ID
gcloud services enable iap.googleapis.com gmail.googleapis.com

# Attempt External-type brand creation
gcloud alpha iap oauth-brands create \
  --application_title="YouCoded Test" \
  --support_email="destinmoss.work@gmail.com"

# Inspect what gets created
gcloud alpha iap oauth-brands list

# Attempt OAuth client creation
gcloud alpha iap oauth-clients create $BRAND_NAME --display_name="YouCoded Test"
gcloud alpha iap oauth-clients list $BRAND_NAME
```

Document every output + error in the findings file under "Command log."

- [ ] **Step 2: Manually inspect the consent screen in the cloud console**

Visit https://console.cloud.google.com/apis/credentials/consent?project=$PROJECT_ID.

Record: (a) was the brand created? (b) is it "External" or "Internal"? (c) what fields are filled / unfilled? (d) what's the publishing status?

Document in the findings file under "Console inspection."

- [ ] **Step 3: Write conclusion + recommendation**

Under "Conclusion":
- **GREEN:** gcloud alone configures External consent fully. `bootstrap-gcp.sh` is a pure script.
- **YELLOW:** gcloud gets partway; N specific fields require console clicks. Document which.
- **RED:** gcloud's External brand support is broken; users must do all of it in the console.

Recommend which UX for the setup command: (a) pure script, (b) hybrid script + screenshot walkthrough for the manual bits, (c) script opens console to the right page and guides user.

- [ ] **Step 4: Commit findings and tear down**

```bash
cd C:/Users/desti/youcoded-dev
git add docs/superpowers/plans/research/2026-04-16-oauth-brand-automation.md
git commit -m "research: resolve gcloud External-consent automation question

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"

gcloud projects delete $PROJECT_ID
```

### Task 0.3: Resolve `gws` Slides write coverage question

**Spec reference:** Open Research Item 3.

**Files:**
- Create: `docs/superpowers/plans/research/2026-04-16-gws-slides-coverage.md`

- [ ] **Step 1: Install gws and enumerate the slides surface**

On macOS:
```bash
brew install googleworkspace/tap/gws
# or the equivalent install path
gws --version
gws slides --help
```

Document full output of `gws slides --help` in findings under "Command surface."

- [ ] **Step 2: Consult upstream release notes**

Visit https://github.com/googleworkspace/cli/releases. Search for "slides" in each release back to v0.15.

Document findings under "Release-note history."

- [ ] **Step 3: Write conclusion**

Under "Conclusion":
- **GREEN:** Full write support (create, add slide, update text). Spec's Slides section stays as-is.
- **YELLOW:** Partial writes (e.g., create-deck but not add-slide). Document what's in.
- **RED:** Read-only. Ship Slides read-only in v1, file follow-up.

- [ ] **Step 4: Commit findings**

```bash
cd C:/Users/desti/youcoded-dev
git add docs/superpowers/plans/research/2026-04-16-gws-slides-coverage.md
git commit -m "research: resolve gws Slides write coverage question

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 0.4: Phase 0 checkpoint — go / no-go

**Files:**
- Modify: `docs/superpowers/specs/2026-04-16-google-services-design.md` (add "Research resolved" section with dated results and any branch taken)

- [ ] **Step 1: Review all three findings docs**

Read each findings file. Summarize the three outcomes in one paragraph.

- [ ] **Step 2: Apply any spec updates**

If any research item returned RED or YELLOW, update the spec's relevant section to reflect the resolved branch. For example:
- If Item 1 is RED → update "OAuth strategy" section to reflect chosen fallback
- If Item 2 is YELLOW → update Step 3 of user-facing flow to document the manual cloud-console insert
- If Item 3 is RED → update "Google Slides" per-integration section to "read-only in v1"

- [ ] **Step 3: Decide go / no-go for Phase 1**

If all three are GREEN or recoverable YELLOW → proceed to Phase 1.

If Item 1 is RED and the chosen fallback is "verified app" → **STOP.** This plan is no longer valid; return to brainstorming to re-design OAuth strategy. Do not proceed.

- [ ] **Step 4: Commit spec update**

```bash
cd C:/Users/desti/youcoded-dev
git add docs/superpowers/specs/2026-04-16-google-services-design.md
git commit -m "docs(google-services): record Phase 0 research outcomes in spec

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 1 — Worktrees and scaffolding

### Task 1.1: Set up worktrees for all affected repos

**Files:**
- Create: `wecoded-marketplace/` worktree at `C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace`
- Create: `youcoded-core/` worktree at `C:/Users/desti/youcoded-dev/.worktrees/google-services-core`

- [ ] **Step 1: Sync both repos with origin**

```bash
cd C:/Users/desti/youcoded-dev/wecoded-marketplace && git fetch origin && git pull origin master
cd C:/Users/desti/youcoded-dev/youcoded-core && git fetch origin && git pull origin master
```

- [ ] **Step 2: Create the marketplace worktree**

```bash
cd C:/Users/desti/youcoded-dev/wecoded-marketplace
git worktree add ../.worktrees/google-services-marketplace -b feat/google-services
```

- [ ] **Step 3: Create the core worktree**

```bash
cd C:/Users/desti/youcoded-dev/youcoded-core
git worktree add ../.worktrees/google-services-core -b feat/google-services-hook-cleanup
```

- [ ] **Step 4: Verify worktrees exist**

```bash
cd C:/Users/desti/youcoded-dev/wecoded-marketplace && git worktree list
cd C:/Users/desti/youcoded-dev/youcoded-core && git worktree list
```

Expected: both output include the new `.worktrees/google-services-*` paths.

### Task 1.2: Create the plugin directory skeleton

**Spec reference:** Architecture — Plugin layout.

**Files:**
- Create: `wecoded-marketplace/google-services/plugin.json`
- Create: `wecoded-marketplace/google-services/commands/` (empty dir)
- Create: `wecoded-marketplace/google-services/skills/` (empty dir)
- Create: `wecoded-marketplace/google-services/setup/` (empty dir)
- Create: `wecoded-marketplace/google-services/lib/` (empty dir)
- Create: `wecoded-marketplace/google-services/docs/` (empty dir)
- Create: `wecoded-marketplace/google-services/.gitkeep` files for empty dirs

- [ ] **Step 1: Create directories**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
mkdir -p google-services/commands google-services/skills google-services/setup google-services/lib google-services/docs
# Placeholders so git tracks the dirs
touch google-services/commands/.gitkeep google-services/skills/.gitkeep google-services/setup/.gitkeep google-services/lib/.gitkeep google-services/docs/.gitkeep
```

- [ ] **Step 2: Write plugin.json**

Write `wecoded-marketplace/google-services/plugin.json`:

```json
{
  "name": "google-services",
  "displayName": "Google Services",
  "description": "Connect Gmail, Drive, Docs, Sheets, Slides, and Calendar with one setup. Works on personal Google accounts.",
  "longDescription": "Google Services gives YouCoded access to your Gmail, Drive, Docs, Sheets, Slides, and Calendar in a single install. Run /google-services-setup once and YouCoded will walk you through connecting your account — no technical setup required. Your account stays yours: every credential is stored in your OS keyring, and the connection is made through a private Google Cloud project that only you can access.\n\nAfter setup, ask Claude things like \"send an email to Mom,\" \"find my budget spreadsheet from last week,\" or \"what's on my calendar tomorrow\" — Claude picks the right Google app automatically.",
  "version": "0.1.0",
  "author": "YouCoded",
  "category": "integrations",
  "tags": ["google", "gmail", "drive", "docs", "sheets", "slides", "calendar", "workspace"],
  "publishedAt": "2026-04-16",
  "sourceMarketplace": "youcoded"
}
```

- [ ] **Step 3: Validate the JSON parses**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
python -c "import json; json.load(open('google-services/plugin.json'))" && echo OK
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add google-services/
git commit -m "feat(google-services): scaffold plugin directory + plugin.json

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 1.3: Register google-services in wecoded-marketplace/index.json

**Spec reference:** Migration section.

**Files:**
- Modify: `wecoded-marketplace/index.json` — add google-services entry, leave deprecated google-workspace entry in place for now (deleted in Phase 6)

- [ ] **Step 1: Read the current index.json to understand entry shape**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
python -c "import json; entries = json.load(open('index.json')); print(json.dumps(entries[0], indent=2))"
```

Record the exact schema — `id`, `displayName`, `description`, `version`, `sourceMarketplace`, `sourceRef`, tags, etc.

- [ ] **Step 2: Add the google-services entry**

Open `index.json` and add an entry matching the shape observed in Step 1, with:
- `id`: "google-services"
- `sourceRef`: "./google-services"
- `sourceMarketplace`: "youcoded"
- version: "0.1.0"
- fields copied from `google-services/plugin.json`

- [ ] **Step 3: Validate JSON parses**

```bash
python -c "import json; json.load(open('index.json'))" && echo OK
```

- [ ] **Step 4: Commit**

```bash
git add index.json
git commit -m "feat(marketplace): register google-services plugin in index

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — Setup infrastructure (shell scripts)

All scripts live in `wecoded-marketplace/google-services/setup/`. Each is tested with `shellcheck` as a baseline lint, plus a manual smoke invocation where practical. All use `set -euo pipefail` for fail-fast semantics and all user-facing text follows the non-technical-language policy from the spec.

### Task 2.1: Write install-gcloud.sh

**Spec reference:** Architecture — Plugin layout; User-facing flow Step 1.

**Files:**
- Create: `wecoded-marketplace/google-services/setup/install-gcloud.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# install-gcloud.sh
# Detects whether gcloud is installed; if not, prompts the user and installs
# it via the platform's package manager.
# User-facing text follows the non-technical-language policy — no "CLI," "SDK,"
# or other jargon in user-visible strings.

set -euo pipefail

if command -v gcloud >/dev/null 2>&1; then
  echo "Google helper tool already installed."
  exit 0
fi

echo ""
echo "YouCoded needs to install a small helper tool from Google"
echo "to connect to your account safely. This takes about 2 minutes"
echo "and about 500 MB of disk space."
echo ""
read -r -p "Install it now? [y/N] " reply
case "$reply" in
  [Yy]*) ;;
  *)
    echo ""
    echo "Setup cancelled. You can install the tool manually by visiting"
    echo "https://cloud.google.com/sdk/docs/install then run /google-services-setup again."
    exit 1
    ;;
esac

OS=$(uname -s)
case "$OS" in
  Darwin)
    if ! command -v brew >/dev/null 2>&1; then
      echo "Homebrew is required on macOS. Install from https://brew.sh and re-run setup."
      exit 1
    fi
    brew install --cask google-cloud-sdk
    ;;
  Linux)
    if command -v apt-get >/dev/null 2>&1; then
      # Follow Google's official apt instructions
      echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
      curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
      sudo apt-get update && sudo apt-get install -y google-cloud-cli
    else
      echo "Your Linux distribution isn't supported by this installer."
      echo "Install the Google helper tool manually from https://cloud.google.com/sdk/docs/install"
      echo "then re-run /google-services-setup."
      exit 1
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    if ! command -v winget >/dev/null 2>&1; then
      echo "winget (Windows Package Manager) is required. Install from the Microsoft Store,"
      echo "then re-run /google-services-setup."
      exit 1
    fi
    winget install --id Google.CloudSDK --accept-package-agreements --accept-source-agreements
    ;;
  *)
    echo "Unsupported operating system: $OS"
    exit 1
    ;;
esac

# Verify the install
if ! command -v gcloud >/dev/null 2>&1; then
  # On some platforms gcloud is installed but not yet on PATH in this shell
  echo ""
  echo "Installation complete, but you may need to restart your terminal"
  echo "to use the tool. After restarting, run /google-services-setup again."
  exit 2
fi

echo "Google helper tool installed."
```

- [ ] **Step 2: Make it executable and add the Windows git bit**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
chmod +x google-services/setup/install-gcloud.sh
git update-index --chmod=+x google-services/setup/install-gcloud.sh
```

- [ ] **Step 3: Lint with shellcheck**

```bash
shellcheck google-services/setup/install-gcloud.sh
```

Expected: no warnings. Fix any that appear.

- [ ] **Step 4: Dry-run on this machine (gcloud should already be present from research phase)**

```bash
bash google-services/setup/install-gcloud.sh
```

Expected: prints "Google helper tool already installed." and exits 0.

- [ ] **Step 5: Commit**

```bash
git add google-services/setup/install-gcloud.sh
git commit -m "feat(google-services): add install-gcloud.sh setup helper

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.2: Write install-gws.sh

**Spec reference:** Architecture — Plugin layout; Foundation.

**Files:**
- Create: `wecoded-marketplace/google-services/setup/install-gws.sh`

- [ ] **Step 1: Determine pinned gws version**

Check https://github.com/googleworkspace/cli/releases and pick the latest stable (not pre-release). Record version string (e.g., `v0.22.5`) for use in the script.

- [ ] **Step 2: Write the script**

```bash
#!/usr/bin/env bash
# install-gws.sh
# Detects whether the pinned version of gws is installed; if not, installs it
# via brew/cargo/prebuilt binary depending on the platform.

set -euo pipefail

GWS_PINNED_VERSION="v0.22.5"  # Update quarterly; last bumped 2026-04-16

if command -v gws >/dev/null 2>&1; then
  installed_version=$(gws --version 2>/dev/null | awk '{print $NF}')
  if [ "$installed_version" = "$GWS_PINNED_VERSION" ]; then
    echo "Google Workspace helper already installed."
    exit 0
  fi
  echo "Found gws $installed_version; updating to pinned $GWS_PINNED_VERSION..."
fi

OS=$(uname -s)
case "$OS" in
  Darwin)
    if command -v brew >/dev/null 2>&1; then
      brew install googleworkspace/tap/gws
    else
      echo "Homebrew is required on macOS. Install from https://brew.sh and re-run setup."
      exit 1
    fi
    ;;
  Linux)
    if command -v cargo >/dev/null 2>&1; then
      cargo install --locked --version "${GWS_PINNED_VERSION#v}" gws
    else
      echo "Rust's cargo is required for the Linux install path of this tool."
      echo "Install Rust from https://rustup.rs and re-run /google-services-setup."
      exit 1
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    # Use the prebuilt Windows binary from the GitHub release
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64) GWS_ASSET="gws-windows-x86_64.zip" ;;
      *) echo "Unsupported Windows architecture: $ARCH"; exit 1 ;;
    esac
    URL="https://github.com/googleworkspace/cli/releases/download/${GWS_PINNED_VERSION}/${GWS_ASSET}"
    INSTALL_DIR="$HOME/.youcoded/bin"
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$URL" -o /tmp/gws.zip
    unzip -o /tmp/gws.zip -d "$INSTALL_DIR"
    chmod +x "$INSTALL_DIR/gws.exe"
    # Note: $INSTALL_DIR should be on PATH; prompt user if not
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
      echo ""
      echo "Add $INSTALL_DIR to your PATH to complete the install,"
      echo "then re-run /google-services-setup."
      exit 2
    fi
    ;;
  *)
    echo "Unsupported operating system: $OS"
    exit 1
    ;;
esac

# Verify
if ! command -v gws >/dev/null 2>&1; then
  echo ""
  echo "Installation complete, but you may need to restart your terminal."
  echo "After restarting, run /google-services-setup again."
  exit 2
fi

echo "Google Workspace helper installed."
```

- [ ] **Step 3: Make executable, lint, smoke-test**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
chmod +x google-services/setup/install-gws.sh
git update-index --chmod=+x google-services/setup/install-gws.sh
shellcheck google-services/setup/install-gws.sh
bash google-services/setup/install-gws.sh
```

Expected: shellcheck passes; script either reports "already installed" or performs a fresh install.

- [ ] **Step 4: Commit**

```bash
git add google-services/setup/install-gws.sh
git commit -m "feat(google-services): add install-gws.sh setup helper (pinned $GWS_PINNED_VERSION)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.3: Write bootstrap-gcp.sh

**Spec reference:** User-facing flow Step 3; Research Item 2 outcome.

**Files:**
- Create: `wecoded-marketplace/google-services/setup/bootstrap-gcp.sh`

- [ ] **Step 1: Re-read Task 0.2 findings**

Open `docs/superpowers/plans/research/2026-04-16-oauth-brand-automation.md`. Note which steps need cloud-console clicks (if any) — the bootstrap script must pause and guide the user through those at the right points.

- [ ] **Step 2: Write the script (GREEN research path shown; adapt if research returned YELLOW)**

```bash
#!/usr/bin/env bash
# bootstrap-gcp.sh
# Drives gcloud to create the user's personal YouCoded GCP project, enable the
# six Google APIs, configure OAuth consent (External type, Testing publish
# status), and emit the OAuth client_id + client_secret for gws to consume.
#
# Idempotent: on re-run, detects the existing youcoded-* project and resumes.
# Emits progress as plain-language lines prefixed with "  ✓" for the slash
# command to echo directly.

set -euo pipefail

APIS=(gmail.googleapis.com drive.googleapis.com docs.googleapis.com
      sheets.googleapis.com slides.googleapis.com calendar-json.googleapis.com)

# Inputs from environment (set by /google-services-setup)
: "${YOUCODED_OUTPUT_DIR:?must be set}"  # where to write client_id + client_secret

# ------- Idempotency: detect existing project -------
EXISTING_PROJECT=$(gcloud projects list --filter="name:YouCoded Personal" --format="value(projectId)" 2>/dev/null | head -n1)

if [ -n "$EXISTING_PROJECT" ]; then
  PROJECT_ID="$EXISTING_PROJECT"
  echo "  ✓ Found existing YouCoded connection ($PROJECT_ID)"
else
  # Random 6-char suffix to avoid ID collisions across users
  SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)
  PROJECT_ID="youcoded-personal-$SUFFIX"
  gcloud projects create "$PROJECT_ID" --name="YouCoded Personal" --quiet >/dev/null
  echo "  ✓ Created your private YouCoded connection"
fi

gcloud config set project "$PROJECT_ID" --quiet >/dev/null

# ------- Enable the six APIs (idempotent) -------
for api in "${APIS[@]}"; do
  case "$api" in
    gmail.googleapis.com)       label="Gmail" ;;
    drive.googleapis.com)       label="Drive" ;;
    docs.googleapis.com)        label="Docs" ;;
    sheets.googleapis.com)      label="Sheets" ;;
    slides.googleapis.com)      label="Slides" ;;
    calendar-json.googleapis.com) label="Calendar" ;;
  esac
  if gcloud services list --enabled --filter="name:$api" --format="value(name)" | grep -q "$api"; then
    echo "  ✓ $label already unlocked"
  else
    gcloud services enable "$api" --quiet >/dev/null
    echo "  ✓ Unlocked $label"
  fi
done

# ------- OAuth consent brand (External) -------
# NOTE: If Task 0.2 research returned YELLOW, insert the screenshot-guided
# manual-click walkthrough here and skip the gcloud brand commands.

BRAND_NAME=$(gcloud alpha iap oauth-brands list --format="value(name)" 2>/dev/null | head -n1)
if [ -z "$BRAND_NAME" ]; then
  gcloud alpha iap oauth-brands create \
    --application_title="YouCoded Personal" \
    --support_email="$(gcloud config get-value account)" \
    --quiet >/dev/null
  BRAND_NAME=$(gcloud alpha iap oauth-brands list --format="value(name)" | head -n1)
fi

# ------- OAuth client -------
CLIENT_INFO=$(gcloud alpha iap oauth-clients list "$BRAND_NAME" --format="value(name,secret)" 2>/dev/null | head -n1)
if [ -z "$CLIENT_INFO" ]; then
  CLIENT_INFO=$(gcloud alpha iap oauth-clients create "$BRAND_NAME" \
    --display_name="YouCoded Personal" \
    --format="value(name,secret)" 2>/dev/null)
fi

CLIENT_ID=$(echo "$CLIENT_INFO" | awk '{print $1}' | awk -F/ '{print $NF}')
CLIENT_SECRET=$(echo "$CLIENT_INFO" | awk '{print $2}')

# ------- Emit credentials to the output dir for gws auth setup -------
mkdir -p "$YOUCODED_OUTPUT_DIR"
cat > "$YOUCODED_OUTPUT_DIR/oauth-credentials.json" <<EOF
{
  "client_id": "$CLIENT_ID",
  "client_secret": "$CLIENT_SECRET",
  "project_id": "$PROJECT_ID"
}
EOF

echo "  ✓ Configured OAuth consent screen"
echo "  ✓ Generated OAuth credentials"
```

- [ ] **Step 3: Make executable, lint**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
chmod +x google-services/setup/bootstrap-gcp.sh
git update-index --chmod=+x google-services/setup/bootstrap-gcp.sh
shellcheck google-services/setup/bootstrap-gcp.sh
```

Expected: shellcheck passes.

- [ ] **Step 4: Run end-to-end against a throwaway project**

```bash
export YOUCODED_OUTPUT_DIR=/tmp/google-services-test-$$
bash google-services/setup/bootstrap-gcp.sh
cat "$YOUCODED_OUTPUT_DIR/oauth-credentials.json"
```

Expected: output file exists with `client_id`, `client_secret`, `project_id`. Each `✓` line appears. Re-run — should detect the existing project and skip recreation (test idempotency).

Tear down after: `gcloud projects delete <project-id>`.

- [ ] **Step 5: Commit**

```bash
git add google-services/setup/bootstrap-gcp.sh
git commit -m "feat(google-services): add bootstrap-gcp.sh (idempotent GCP provisioning)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.4: Write smoke-test.sh

**Spec reference:** User-facing flow Step 6; per-integration "Shipped probe" lines.

**Files:**
- Create: `wecoded-marketplace/google-services/setup/smoke-test.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# smoke-test.sh
# Runs a read-only probe against each of the six Google services after setup
# completes. Each probe is a minimal gws call that verifies the OAuth scope
# for that service was granted. No writes. Output is parsed by the slash
# command to show ✓ / ✗ per service.

set -u  # not -e: we want to test all six and report outcomes, not abort on first fail

declare -A RESULTS

probe() {
  local label="$1"; shift
  local hint="$1"; shift
  if "$@" >/dev/null 2>&1; then
    RESULTS[$label]="PASS"
    echo "  ✓ $label"
  else
    RESULTS[$label]="FAIL:$hint"
    echo "  ✗ $label — $hint"
  fi
}

probe "Gmail"    "may need to re-approve the Gmail permission"    gws gmail list --max 5
probe "Drive"    "may need to re-approve the Drive permission"    gws drive list --max 5
probe "Docs"     "may need to re-approve the Docs permission"     gws docs list --max 1  # gws drive list --mime-type doc is alt
probe "Sheets"   "may need to re-approve the Sheets permission"   gws sheets list --max 1
probe "Slides"   "may need to re-approve the Slides permission"   gws slides list --max 1
probe "Calendar" "may need to re-approve the Calendar permission" gws calendar events list --max 5

# Exit nonzero if any probe failed
for label in "${!RESULTS[@]}"; do
  case "${RESULTS[$label]}" in
    PASS) ;;
    *) exit 1 ;;
  esac
done

exit 0
```

Adjust the `gws <service> list` commands if Task 0.3 research revealed different subcommand names. Some services (Docs, Sheets, Slides) might not have a top-level `list`; the fallback is `gws drive list --mime-type <type>`.

- [ ] **Step 2: Make executable, lint**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
chmod +x google-services/setup/smoke-test.sh
git update-index --chmod=+x google-services/setup/smoke-test.sh
shellcheck google-services/setup/smoke-test.sh
```

- [ ] **Step 3: Run against Destin's real `gws auth` state (assuming prior setup completed)**

```bash
bash google-services/setup/smoke-test.sh
echo "exit: $?"
```

Expected: six `✓` lines, exit 0.

- [ ] **Step 4: Commit**

```bash
git add google-services/setup/smoke-test.sh
git commit -m "feat(google-services): add smoke-test.sh (read-only probes)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.5: Write lib/gws-wrapper.sh

**Spec reference:** Per-integration detail — Shared concerns.

**Files:**
- Create: `wecoded-marketplace/google-services/lib/gws-wrapper.sh`

- [ ] **Step 1: Write the wrapper**

```bash
#!/usr/bin/env bash
# gws-wrapper.sh
# Shared helpers for the six google-services skills. Sourced (not exec'd) by
# each skill when it needs to run gws and interpret auth errors uniformly.
#
# Skills use `gws_run` instead of calling `gws` directly so auth-error
# surfacing stays consistent — never six copies of "please run /google-services-setup".

gws_auth_status() {
  # Returns 0 if gws is authenticated for this user's default account, 1 otherwise.
  gws auth status --json 2>/dev/null | grep -q '"authenticated": true'
}

gws_run() {
  # Run any gws subcommand. If it fails with an auth error, emit the shared
  # reconnect message and return 1. Otherwise forward exit code + output.
  local out
  if ! out=$(gws "$@" 2>&1); then
    case "$out" in
      *"token has been expired or revoked"*|*"invalid_grant"*|*"unauthorized"*|*"AuthenticationError"*)
        echo "Your Google Services connection needs refreshing — run /google-services-setup to reconnect."
        return 1
        ;;
      *)
        echo "$out" >&2
        return 1
        ;;
    esac
  fi
  echo "$out"
}
```

- [ ] **Step 2: Make executable, lint**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
chmod +x google-services/lib/gws-wrapper.sh
git update-index --chmod=+x google-services/lib/gws-wrapper.sh
shellcheck google-services/lib/gws-wrapper.sh
```

- [ ] **Step 3: Test the wrapper by sourcing and calling**

```bash
bash -c 'source google-services/lib/gws-wrapper.sh && gws_run gmail list --max 1 && echo OK'
```

Expected: `OK` if auth is working; the reconnect message if not.

- [ ] **Step 4: Commit**

```bash
git add google-services/lib/gws-wrapper.sh
git commit -m "feat(google-services): add gws-wrapper.sh shared helpers

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 2.6: Write the /google-services-setup slash command

**Spec reference:** User-facing flow (entire section).

**Files:**
- Create: `wecoded-marketplace/google-services/commands/google-services-setup.md`

- [ ] **Step 1: Write the command markdown**

Markdown slash commands run as a prompt template Claude follows. The contents tell Claude what to do; Claude executes bash steps via its tool access.

```markdown
---
description: "Set up Google Services (Gmail, Drive, Docs, Sheets, Slides, Calendar) with one command. Installs helper tools, connects your Google account, and verifies each service works."
---

Run the Google Services bundle setup. Follow these steps in order. Show the user each line exactly as specified — all user-visible text below is final copy, do NOT paraphrase.

## Step 0 — System check

Echo:

```
Getting Google apps ready for YouCoded...
```

Detect the OS with `uname -s`. If the OS is not one of Darwin / Linux / MINGW*/MSYS*/CYGWIN*, abort with:

```
Sorry — Google Services setup doesn't support your system yet.
```

## Step 1 — Helper tools

Run `bash $PLUGIN_DIR/setup/install-gcloud.sh` and `bash $PLUGIN_DIR/setup/install-gws.sh` in that order. Each may prompt the user for install consent; honor their response. If either exits with code 2 (install complete but PATH not updated), stop and tell the user to restart their terminal and re-run `/google-services-setup`.

## Step 2 — First sign-in

Echo the framing text:

```
Next, YouCoded will open your browser twice to connect to Google:

  1. First, to create a private connection in your Google account
  2. Then, to ask your permission to use Gmail, Drive, Calendar,
     and your Google documents

The private connection is yours — it belongs to your Google
account, not to YouCoded or anyone else.

Press Enter to open your browser...
```

Wait for Enter, then run `gcloud auth login`. If it exits nonzero, abort with:

```
Sign-in didn't complete. Run /google-services-setup again when you're ready.
```

## Step 3 — Setting it up

Echo "Setting up..." then run:

```
export YOUCODED_OUTPUT_DIR=$HOME/.youcoded/google-services
bash $PLUGIN_DIR/setup/bootstrap-gcp.sh
```

The bootstrap script emits each `  ✓` line itself — do not add extras. If it exits nonzero, abort with the error message printed by the script.

## Step 4 — Unverified-app warning

Read the generated client_id to show the exact project ID:

```bash
PROJECT_ID=$(python -c "import json; print(json.load(open('$YOUCODED_OUTPUT_DIR/oauth-credentials.json'))['project_id'])")
```

Then echo (substituting `$PROJECT_ID`):

```
⚠ Heads up: on the next screen, Google will show you a warning
that says "Google hasn't verified this app."

This is expected and safe. The "app" is you — YouCoded just set
up a private connection inside your own Google account, and now
you're giving yourself permission to use it.

To continue through Google's warning:
  • Click "Advanced"
  • Click "Go to $PROJECT_ID (unsafe)"

Press Enter to continue...
```

Wait for Enter.

## Step 5 — Grant permissions

Echo:

```
Opening Google's permission page...

Google will ask whether YouCoded can read your email, access
your Drive files, and so on. Please check every box — leaving
any unchecked will cause some features to not work.
```

Run `gws auth setup` using the credentials from `$YOUCODED_OUTPUT_DIR/oauth-credentials.json`. If it exits nonzero, abort with:

```
Looks like you didn't finish approving the permissions. When
you're ready, run /google-services-setup again — this time click
"Advanced" then "Continue" on Google's warning screen.
```

## Step 6 — Make sure it actually works

Echo "Testing your connection..." then run `bash $PLUGIN_DIR/setup/smoke-test.sh`.

If exit 0: echo the "All set!" block:

```
All set! Try asking YouCoded something like:
  "Send an email to Mom"
  "Find my budget spreadsheet from last week"
  "What's on my calendar tomorrow?"
```

If exit nonzero: the smoke-test script already printed which service failed. Add:

```
Setup not yet complete. Run /google-services-setup again to retry the failing service.
```

Do NOT report success when any probe failed.

## Step 7 — Migration cleanup

Run `bash $PLUGIN_DIR/setup/migrate-legacy.sh` (exists only if legacy artifacts detected; script echoes its own `  ✓` line or nothing). The migrate script is added in Phase 6 of implementation; if not present yet, skip this step silently.

---

Throughout all steps: user-facing language only. Never surface "API," "gws," "gcloud," "OAuth scope," etc. in strings the user reads. Internal log lines for debugging are fine.
```

- [ ] **Step 2: Commit**

```bash
git add google-services/commands/google-services-setup.md
git commit -m "feat(google-services): add /google-services-setup slash command

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 3 — Skills (six sibling SKILL.md files)

Each skill is a short, focused Markdown file with YAML frontmatter. The `description` field is how Claude's skill matcher decides when to invoke — calibrate so each skill has a tight, non-overlapping trigger. Body is ~100-250 words: what this skill does, what `gws` commands it wraps, how to use them, and links to the wrapper helper.

### Task 3.1: Write skills/gmail/SKILL.md

**Spec reference:** Per-integration detail — Gmail.

**Files:**
- Create: `wecoded-marketplace/google-services/skills/gmail/SKILL.md`

- [ ] **Step 1: Write the skill**

```markdown
---
name: gmail
description: "Use when the user wants to send, read, search, label, or draft email in their Gmail inbox. Triggers on: send an email, check my inbox, find emails from, reply to, draft a message, add a label. Does NOT handle Google Chat or Google Messages (those are other bundles)."
---

# Gmail

Connects to the user's Gmail via `gws gmail`. Auth is managed by `/google-services-setup` — this skill assumes `gws auth status` is valid.

## Core commands

Source the shared wrapper before invoking:

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/gws-wrapper.sh"
```

Then use `gws_run gmail <...>` (never call `gws` directly — the wrapper emits the shared reconnect message on auth errors):

| Task | Command |
|------|---------|
| List recent | `gws_run gmail list --max 10` |
| Read one | `gws_run gmail read <message-id>` |
| Send | `gws_run gmail send --to "<email>" --subject "<s>" --body "<b>"` |
| Draft | `gws_run gmail draft --to "<email>" --subject "<s>" --body "<b>"` |
| Add label | `gws_run gmail label add <message-id> <label-name>` |
| Search | `gws_run gmail list --query "from:alice@example.com"` |

## Format handling

`gws gmail read` returns both HTML and plaintext bodies. Prefer plaintext when summarizing for the user; use HTML when preserving formatting matters (forwarding, etc.).

## Localized labels

If the user's Gmail language is non-English, system labels (Inbox, Sent, Drafts) are returned in their localized names. When filtering by label, prefer the gmail system label ID (e.g., `INBOX`) over the visible name.

## Drafts vs sent

When the user asks to "send," use `gws_run gmail send`. When they ask to "draft" or "prepare," use `gws_run gmail draft`. Never leave both a draft AND a sent copy — pick one.

## Auth failure

If `gws_run` returns the "needs refreshing" message, surface it verbatim and stop.
```

- [ ] **Step 2: Validate YAML frontmatter parses**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
python -c "import yaml; f=open('google-services/skills/gmail/SKILL.md'); content=f.read(); fm=content.split('---')[1]; print(yaml.safe_load(fm))"
```

Expected: dict with `name` and `description` keys.

- [ ] **Step 3: Commit**

```bash
git add google-services/skills/gmail/SKILL.md
git commit -m "feat(google-services): add gmail skill

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.2: Write skills/google-drive/SKILL.md

**Spec reference:** Per-integration detail — Google Drive.

**Files:**
- Create: `wecoded-marketplace/google-services/skills/google-drive/SKILL.md`

- [ ] **Step 1: Write the skill**

```markdown
---
name: google-drive
description: "Use when the user wants to find, download, upload, move, rename, or trash files stored in Google Drive. Triggers on: find my file, upload this to Drive, download from Drive, move a file, where's my X file. Does NOT handle reading/editing document CONTENT — that's google-docs/sheets/slides."
---

# Google Drive

Handles files-as-objects in Drive. Document content belongs to the google-docs / google-sheets / google-slides skills.

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/gws-wrapper.sh"
```

## Core commands

| Task | Command |
|------|---------|
| List | `gws_run drive list --max 20` |
| Search | `gws_run drive list --query "name contains 'budget'"` |
| Download | `gws_run drive download <file-id> --out <local-path>` |
| Upload | `gws_run drive upload <local-path> --folder <folder-id>` |
| Move | `gws_run drive move <file-id> --to-folder <folder-id>` |
| Rename | `gws_run drive rename <file-id> --to "<new-name>"` |
| Trash | `gws_run drive trash <file-id>` |

## Shared Drives vs My Drive

Default searches and operations target My Drive. If the user mentions a specific shared drive ("in the Finance shared drive"), pass `--drive <drive-id>`. List shared drives with `gws_run drive shared-drives list`.

## MIME conversions

Google-native formats (Docs, Sheets, Slides) download as their native Google format by default. To convert to Office formats, pass `--export-mime application/vnd.openxmlformats-officedocument.wordprocessingml.document` (or the Excel / PowerPoint equivalent).

## Auth failure

Shared wrapper handles it — surface verbatim and stop.
```

- [ ] **Step 2: Validate + commit**

Same pattern as Task 3.1.

```bash
python -c "import yaml; f=open('google-services/skills/google-drive/SKILL.md'); content=f.read(); fm=content.split('---')[1]; print(yaml.safe_load(fm))"
git add google-services/skills/google-drive/SKILL.md
git commit -m "feat(google-services): add google-drive skill

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.3: Write skills/google-docs/SKILL.md

**Spec reference:** Per-integration detail — Google Docs.

**Files:**
- Create: `wecoded-marketplace/google-services/skills/google-docs/SKILL.md`

- [ ] **Step 1: Write the skill**

```markdown
---
name: google-docs
description: "Use when the user wants to read, edit, create, or export the CONTENT of a Google Doc. Triggers on: write a doc about, edit my doc, what does my X doc say, create a doc, export to PDF. Handles document content; does NOT handle finding-the-file operations — those belong to google-drive."
---

# Google Docs

Content-level operations on Google Docs. File-level operations (find, move, trash) belong to google-drive.

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/gws-wrapper.sh"
```

## Core commands

| Task | Command |
|------|---------|
| Read | `gws_run docs get <doc-id>` |
| Create | `gws_run docs create --title "<t>" --body "<b>"` |
| Update | `gws_run docs update <doc-id> --body "<b>"` |
| Export to PDF | `gws_run docs export <doc-id> --format pdf --out <path>` |

## Structured content

`gws docs get` returns JSON with structured blocks (paragraphs, tables, lists, images). When summarizing for the user, flatten to plain text. When preserving structure matters (e.g., they ask "what's in the third table?"), keep the structure.

## Finding a doc

If the user names the doc ("read my budget doc"), call google-drive first to find the ID, then pass the ID here.

## Auth failure

Wrapper handles it.
```

- [ ] **Step 2: Validate + commit**

```bash
python -c "import yaml; f=open('google-services/skills/google-docs/SKILL.md'); content=f.read(); fm=content.split('---')[1]; print(yaml.safe_load(fm))"
git add google-services/skills/google-docs/SKILL.md
git commit -m "feat(google-services): add google-docs skill

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.4: Write skills/google-sheets/SKILL.md

**Spec reference:** Per-integration detail — Google Sheets.

**Files:**
- Create: `wecoded-marketplace/google-services/skills/google-sheets/SKILL.md`

- [ ] **Step 1: Write the skill**

```markdown
---
name: google-sheets
description: "Use when the user wants to read cell values, write values, append rows, or create a new spreadsheet. Triggers on: what's in my spreadsheet, update cell, add a row, create a sheet, read column X. File-find operations ('where is my X sheet') belong to google-drive."
---

# Google Sheets

Content-level operations on Google Sheets. Finding the file belongs to google-drive.

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/gws-wrapper.sh"
```

## Core commands

| Task | Command |
|------|---------|
| Get sheet metadata | `gws_run sheets get <sheet-id>` |
| Create | `gws_run sheets create --title "<t>"` |
| Read values | `gws_run sheets values get <sheet-id> --range "A1:D10"` |
| Update values | `gws_run sheets values update <sheet-id> --range "A1" --values '[["hello"]]'` |
| Append row | `gws_run sheets values append <sheet-id> --range "Sheet1" --values '[["v1","v2"]]'` |

## Values vs formulas

`values get` returns calculated values by default. To get formula text, pass `--value-render-option FORMULA`. When the user asks "what's the formula in A1," use FORMULA mode; otherwise default to calculated.

## A1 vs R1C1

Default A1. Use R1C1 only if the user explicitly asks in that notation.

## Finding a sheet

Call google-drive first if the user names it rather than gives an ID.

## Auth failure

Wrapper handles it.
```

- [ ] **Step 2: Validate + commit**

```bash
python -c "import yaml; f=open('google-services/skills/google-sheets/SKILL.md'); content=f.read(); fm=content.split('---')[1]; print(yaml.safe_load(fm))"
git add google-services/skills/google-sheets/SKILL.md
git commit -m "feat(google-services): add google-sheets skill

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.5: Write skills/google-slides/SKILL.md

**Spec reference:** Per-integration detail — Google Slides. Branch depends on Task 0.3 research outcome.

**Files:**
- Create: `wecoded-marketplace/google-services/skills/google-slides/SKILL.md`

- [ ] **Step 1: Confirm write-support state from Task 0.3 findings**

Open `docs/superpowers/plans/research/2026-04-16-gws-slides-coverage.md`. Use the GREEN skill below if research found full writes; use the RED variant if read-only only.

- [ ] **Step 2: Write the skill (GREEN version shown)**

```markdown
---
name: google-slides
description: "Use when the user wants to read, create, or export a Google Slides deck. Triggers on: what's in my presentation, create a deck, read slide 3, export deck as PDF. File-find operations belong to google-drive."
---

# Google Slides

Content-level operations on Google Slides decks. File-find operations belong to google-drive.

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/gws-wrapper.sh"
```

## Core commands

| Task | Command |
|------|---------|
| Read deck | `gws_run slides get <deck-id>` |
| Create deck | `gws_run slides create --title "<t>"` |
| Add slide | `gws_run slides slide add <deck-id> --layout TITLE_AND_BODY` |
| Export PDF | `gws_run slides export <deck-id> --format pdf --out <path>` |

## Slide structure

`slides get` returns JSON with slides, each containing pageElements (text boxes, images, shapes). When summarizing for the user, extract the text content from text boxes.

## Auth failure

Wrapper handles it.
```

**RED variant (read-only — use if Task 0.3 returned RED):**

Replace "## Core commands" onward with a table containing only the `get` and `export` rows, and add this note:

```markdown
## v1 limitation

This version of the bundle supports reading and exporting Slides decks. Creating or editing slides is not yet available — `gws` does not support those operations at this version. Follow-up issue: #TODO.
```

- [ ] **Step 3: Validate + commit**

```bash
python -c "import yaml; f=open('google-services/skills/google-slides/SKILL.md'); content=f.read(); fm=content.split('---')[1]; print(yaml.safe_load(fm))"
git add google-services/skills/google-slides/SKILL.md
git commit -m "feat(google-services): add google-slides skill

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 3.6: Write skills/google-calendar/SKILL.md

**Spec reference:** Per-integration detail — Google Calendar.

**Files:**
- Create: `wecoded-marketplace/google-services/skills/google-calendar/SKILL.md`

- [ ] **Step 1: Write the skill**

```markdown
---
name: google-calendar
description: "Use when the user wants to check, create, update, or delete events in their Google Calendar. Triggers on: what's on my calendar, schedule a meeting, cancel my 3pm, when am I free, add a reminder. Handles multiple calendars (personal, family, work) with primary as default."
---

# Google Calendar

```bash
source "$CLAUDE_PLUGIN_ROOT/lib/gws-wrapper.sh"
```

## Core commands

| Task | Command |
|------|---------|
| List calendars | `gws_run calendar list` |
| List events | `gws_run calendar events list --max 10` |
| Create event | `gws_run calendar events create --summary "<s>" --start "<iso>" --end "<iso>"` |
| Update event | `gws_run calendar events update <event-id> --summary "<new>"` |
| Delete event | `gws_run calendar events delete <event-id>` |

## Multiple calendars

Default is primary. If the user names a specific calendar ("on my Family calendar"), pass `--calendar <calendar-id>` — find the ID from `gws_run calendar list`.

## Recurring events

When the user asks to update or delete "just this one" of a recurring event, pass the instance's event ID (has a suffix like `_20261023T090000Z`). When they mean the whole series, use the base event ID. If ambiguous, ask.

## Time zones

Events return in each calendar's default TZ. When formatting for the user, convert to the user's primary calendar's TZ (fetch from `gws_run calendar list`). Always display TZ abbreviation when it differs from the user's.

## Availability

For "when am I free today" / "free/busy" questions, use `gws_run calendar freebusy --start <iso> --end <iso> --calendars primary`.

## Auth failure

Wrapper handles it.
```

- [ ] **Step 2: Validate + commit**

```bash
python -c "import yaml; f=open('google-services/skills/google-calendar/SKILL.md'); content=f.read(); fm=content.split('---')[1]; print(yaml.safe_load(fm))"
git add google-services/skills/google-calendar/SKILL.md
git commit -m "feat(google-services): add google-calendar skill

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — Dev-time verification

From the spec's "Dev-time verification checklist (not shipped)." This phase gates shipping — no merge until every box is checked.

### Task 4.1: Write DEV-VERIFICATION.md

**Files:**
- Create: `wecoded-marketplace/google-services/docs/DEV-VERIFICATION.md`

- [ ] **Step 1: Copy the checklist from the spec**

```markdown
# Dev-time Verification

This checklist runs on a clean test machine before `google-services` is allowed to ship. NOT shipped to users — lives here only for our pre-ship gate.

- [ ] `/google-services-setup` completes end-to-end on macOS, Windows, Linux with no pre-existing `gcloud` or `gws` installed.
- [ ] Idempotent re-run with existing valid auth reports "already set up" and skips to probes.
- [ ] Partial-state re-run (simulate network drop between API-enable and OAuth-client-create) detects existing project and resumes correctly, does NOT create a second project.
- [ ] Gmail round-trip: send draft to self → fetch → delete. Leaves no residue.
- [ ] Drive round-trip: upload → list → download → trash.
- [ ] Docs round-trip: create → read → trash.
- [ ] Sheets round-trip: create → write A1 → read A1 → trash.
- [ ] Slides round-trip (or read-only if Research Item 3 ruled out writes).
- [ ] Calendar round-trip: create event → list → delete.
- [ ] Migration: test machine with pre-installed `youcoded-drive` + `claudes-inbox` on hosted Gmail — setup cleans all artifacts.
- [ ] Skill discovery: compound prompts ("send an email with last week's budget sheet attached") route cleanly to one primary skill.
- [ ] Refresh-token behavior observed over 10 days to validate Research Item 1's answer.
```

- [ ] **Step 2: Commit**

```bash
git add google-services/docs/DEV-VERIFICATION.md
git commit -m "docs(google-services): add dev-time verification checklist

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 4.2: Run the round-trip checks manually

**Files:** none modified; updates `DEV-VERIFICATION.md` as boxes tick.

For each round-trip below, run the exact commands, verify expected state, then check the box. Do NOT skip cleanup — a failed cleanup on any round-trip means the skill is shipping with a bug.

- [ ] **Step 1: Gmail round-trip**

```bash
# Send a draft to yourself
msgid=$(gws gmail draft --to destinmoss.work@gmail.com --subject "YouCoded Smoke Test" --body "hello" --json | jq -r .id)
# Verify it exists
gws gmail read "$msgid" | grep -q "hello" && echo OK
# Delete
gws gmail delete "$msgid"
# Confirm gone
gws gmail read "$msgid" 2>&1 | grep -q "not found" && echo CLEANED
```

Expected: `OK` then `CLEANED`. Check the box in DEV-VERIFICATION.md.

- [ ] **Step 2: Drive round-trip**

```bash
echo "smoke" > /tmp/yc-smoke.txt
fileid=$(gws drive upload /tmp/yc-smoke.txt --json | jq -r .id)
gws drive download "$fileid" --out /tmp/yc-smoke-back.txt
diff /tmp/yc-smoke.txt /tmp/yc-smoke-back.txt && echo OK
gws drive trash "$fileid" && echo CLEANED
rm /tmp/yc-smoke.txt /tmp/yc-smoke-back.txt
```

- [ ] **Step 3: Docs round-trip**

```bash
docid=$(gws docs create --title "YouCoded Smoke" --body "hello" --json | jq -r .documentId)
gws docs get "$docid" | grep -q "hello" && echo OK
gws drive trash "$docid" && echo CLEANED
```

- [ ] **Step 4: Sheets round-trip**

```bash
sid=$(gws sheets create --title "YouCoded Smoke" --json | jq -r .spreadsheetId)
gws sheets values update "$sid" --range "A1" --values '[["hello"]]'
gws sheets values get "$sid" --range "A1" | grep -q "hello" && echo OK
gws drive trash "$sid" && echo CLEANED
```

- [ ] **Step 5: Slides round-trip**

(Skip writes if research item 3 returned RED. In that case, test read-only: fetch a deck by ID and verify structure parses.)

```bash
deckid=$(gws slides create --title "YouCoded Smoke" --json | jq -r .presentationId)
gws slides slide add "$deckid" --layout TITLE_AND_BODY
gws slides get "$deckid" | jq '.slides | length' | grep -q "^[1-9]" && echo OK
gws drive trash "$deckid" && echo CLEANED
```

- [ ] **Step 6: Calendar round-trip**

```bash
start=$(date -u -v+1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+1 hour" +"%Y-%m-%dT%H:%M:%SZ")
end=$(date -u -v+2H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+2 hour" +"%Y-%m-%dT%H:%M:%SZ")
eid=$(gws calendar events create --summary "YC Smoke" --start "$start" --end "$end" --json | jq -r .id)
gws calendar events list --max 5 | grep -q "YC Smoke" && echo OK
gws calendar events delete "$eid" && echo CLEANED
```

- [ ] **Step 7: Commit the checklist updates**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
git add google-services/docs/DEV-VERIFICATION.md
git commit -m "verify(google-services): round-trip checks pass for all 6 services

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 4.3: Skill-matcher compound-prompt test

**Files:** none modified permanently; `DEV-VERIFICATION.md` checkbox ticks.

- [ ] **Step 1: Start a fresh Claude Code session with google-services installed**

Install the plugin locally from the worktree path, then start a new session.

- [ ] **Step 2: Run the compound-prompt test**

Send each prompt and record which skill(s) activate. A "clean" match means exactly one primary skill.

| Prompt | Primary skill expected | Secondary (tool-use) OK |
|--------|------------------------|-------------------------|
| "send an email to Mom" | gmail | — |
| "find my budget spreadsheet" | google-drive | — |
| "what does my budget spreadsheet say about March?" | google-sheets | google-drive (finds the file) |
| "send an email with last week's budget sheet attached" | gmail | google-drive / google-sheets |
| "add a meeting with Alice tomorrow at 3" | google-calendar | — |
| "create a doc with the notes from my last email" | google-docs | gmail |

Document any mismatch (wrong primary, no match, two primaries) in DEV-VERIFICATION.md. If mismatches found, tune the SKILL.md `description` fields and re-run.

- [ ] **Step 3: Commit any SKILL.md tuning + check the box**

```bash
git add google-services/skills/*/SKILL.md google-services/docs/DEV-VERIFICATION.md
git commit -m "tune(google-services): skill descriptions calibrated for compound prompts

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 4.4: Idempotency + partial-state resume test

**Files:** `DEV-VERIFICATION.md` checkboxes tick.

- [ ] **Step 1: Re-run the setup on a machine already set up**

```bash
/google-services-setup
```

Expected output begins "Found existing YouCoded connection..." and ends with the full set of ✓ probes. No second project created.

- [ ] **Step 2: Simulate partial-state**

Create a throwaway user account, run setup to completion of Step 3 API-enable, then kill it (Ctrl-C) before OAuth client creation.

Re-run `/google-services-setup`. Expected: detects existing project, resumes at OAuth client creation, completes.

- [ ] **Step 3: Commit**

```bash
git add google-services/docs/DEV-VERIFICATION.md
git commit -m "verify(google-services): idempotency and partial-state resume confirmed

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — Migration (clean cutover)

All in the same PR that ships google-services. Split across two worktrees (marketplace + core) because different repos.

### Task 5.1: Rewrite claudes-inbox/providers/gmail.md

**Worktree:** `wecoded-marketplace` (google-services-marketplace worktree).

**Spec reference:** Migration.

**Files:**
- Modify: `wecoded-marketplace/youcoded-inbox/skills/claudes-inbox/providers/gmail.md`

- [ ] **Step 1: Read the current file**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
cat youcoded-inbox/skills/claudes-inbox/providers/gmail.md
```

Record: (a) what provider interface the inbox skill expects, (b) which `mcp__claude_ai_Gmail__*` calls need replacement.

- [ ] **Step 2: Rewrite body using gws**

Replace every `mcp__claude_ai_Gmail__list_messages` / `mcp__claude_ai_Gmail__get_message` call with the equivalent `gws gmail list` / `gws gmail read`. Preserve the provider's outer contract — the inbox skill should not need to change.

- [ ] **Step 3: Run the inbox skill end-to-end manually**

If claudes-inbox has its own setup flow, run it and confirm messages are still ingested.

- [ ] **Step 4: Commit**

```bash
git add youcoded-inbox/skills/claudes-inbox/providers/gmail.md
git commit -m "refactor(youcoded-inbox): migrate Gmail provider from hosted MCP to gws

Aligns with google-services bundle which replaces the hosted Gmail MCP path.
See docs/superpowers/specs/2026-04-16-google-services-design.md migration section.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 5.2: Delete youcoded-drive directory

**Worktree:** `wecoded-marketplace`.

**Files:**
- Delete: `wecoded-marketplace/youcoded-drive/` (entire directory)
- Modify: `wecoded-marketplace/index.json` (remove youcoded-drive entry)

- [ ] **Step 1: Confirm youcoded-drive is entirely superseded**

```bash
grep -r "youcoded-drive" wecoded-marketplace/ --exclude-dir=youcoded-drive
```

Should return only: `index.json` entry and any references in the Google Services docs. Anything else found needs evaluation — do not delete yet, surface to Destin.

- [ ] **Step 2: Delete the directory**

```bash
git rm -r youcoded-drive/
```

- [ ] **Step 3: Remove the index entry**

Open `index.json`, delete the object with `"id": "youcoded-drive"`. Validate JSON parses.

```bash
python -c "import json; json.load(open('index.json'))" && echo OK
```

- [ ] **Step 4: Commit**

```bash
git add -u
git commit -m "chore(marketplace): retire youcoded-drive (superseded by google-services)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 5.3: Delete deprecated google-workspace entry

**Worktree:** `wecoded-marketplace`.

**Files:**
- Modify: `wecoded-marketplace/index.json`

- [ ] **Step 1: Remove the entry**

Open `index.json`, delete the object with `"id": "google-workspace"` (the one with `"deprecated": true`). Validate JSON.

```bash
python -c "import json; json.load(open('index.json'))" && echo OK
```

- [ ] **Step 2: Commit**

```bash
git add index.json
git commit -m "chore(marketplace): delete deprecated google-workspace metadata entry

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 5.4: Delete youcoded-messaging/imessages subdirectory

**Worktree:** `wecoded-marketplace`.

**Files:**
- Delete: `wecoded-marketplace/youcoded-messaging/imessages/` (entire subdir)

- [ ] **Step 1: Confirm the Anthropic iMessage plugin is the intended replacement**

```bash
grep -A 5 '"imessage"' wecoded-marketplace/index.json
```

Should show the Anthropic-sourced imessage entry present.

- [ ] **Step 2: Delete**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
git rm -r youcoded-messaging/imessages/
```

- [ ] **Step 3: Update youcoded-messaging's plugin.json if it references iMessage in its description**

```bash
cat youcoded-messaging/plugin.json
```

Edit to remove iMessage references; scope the description to Google Messages only. (The Google Messages bundle's own spec will further restructure this plugin.)

- [ ] **Step 4: Commit**

```bash
git add -u youcoded-messaging/
git commit -m "chore(youcoded-messaging): remove iMessage (Anthropic plugin supersedes)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 5.5: Remove Gmail/Calendar blocks from tool-router.sh

**Worktree:** `youcoded-core` (google-services-core worktree).

**Files:**
- Modify: `youcoded-core/hooks/tool-router.sh`

- [ ] **Step 1: Read the current hook**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-core
cat hooks/tool-router.sh
```

Locate the `mcp__claude_ai_Gmail__*` and `mcp__claude_ai_Google_Calendar__*` block + redirect clauses.

- [ ] **Step 2: Remove the blocks, keep the rest of the router**

Delete only the Gmail and Calendar clauses. Other tool routes (if any) stay.

- [ ] **Step 3: Verify the hook still runs without error**

```bash
bash hooks/tool-router.sh < /dev/null
echo "exit: $?"
```

Expected: exits cleanly.

- [ ] **Step 4: Commit**

```bash
git add hooks/tool-router.sh
git commit -m "chore(hooks): remove Gmail and Calendar redirects from tool-router

google-services bundle provides real Gmail/Calendar integrations, so the
redirect-to-not-yet-built-gws block in this hook is no longer needed.
See docs/superpowers/specs/2026-04-16-google-services-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 5.6: Write migrate-legacy.sh

**Worktree:** `wecoded-marketplace`.

**Spec reference:** User-facing flow Step 7.

**Files:**
- Create: `wecoded-marketplace/google-services/setup/migrate-legacy.sh`

- [ ] **Step 1: Write the migration script**

```bash
#!/usr/bin/env bash
# migrate-legacy.sh
# Run at end of /google-services-setup. Detects artifacts from the predecessor
# integrations on the user's machine and cleans them up silently.

set -u

any_cleaned=0

# rclone gdrive: remote (from youcoded-drive)
if command -v rclone >/dev/null 2>&1; then
  if rclone listremotes 2>/dev/null | grep -q "^gdrive:$"; then
    rclone config delete gdrive >/dev/null 2>&1 || true
    any_cleaned=1
  fi
fi

# Disable deprecated google-workspace plugin if enabled
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q "\"google-workspace@" "$SETTINGS"; then
  # Remove the entry via python (preserves JSON formatting)
  python - <<'PY' "$SETTINGS"
import json, sys
p = sys.argv[1]
with open(p) as f: s = json.load(f)
ep = s.get("enabledPlugins", {})
for k in list(ep.keys()):
    if k.startswith("google-workspace@"):
        del ep[k]
with open(p, "w") as f: json.dump(s, f, indent=2)
PY
  any_cleaned=1
fi

# Emit a single line only if something was cleaned
if [ "$any_cleaned" = "1" ]; then
  echo "  ✓ Cleaning up old Google connections"
fi

exit 0
```

- [ ] **Step 2: Make executable, lint**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
chmod +x google-services/setup/migrate-legacy.sh
git update-index --chmod=+x google-services/setup/migrate-legacy.sh
shellcheck google-services/setup/migrate-legacy.sh
```

- [ ] **Step 3: Test on a machine with rclone gdrive configured**

If a test machine with the legacy state is available, run and verify cleanup.

- [ ] **Step 4: Commit**

```bash
git add google-services/setup/migrate-legacy.sh
git commit -m "feat(google-services): add migrate-legacy.sh for user-machine cleanup

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 5.7: Migration end-to-end test

**Worktree:** both.

**Files:** `DEV-VERIFICATION.md` checkbox ticks.

- [ ] **Step 1: Provision a test machine with all legacy state present**

Install youcoded-drive + claudes-inbox + enable google-workspace in settings + configure rclone gdrive.

- [ ] **Step 2: Run /google-services-setup end-to-end**

Observe: Step 7 removes rclone gdrive, disables google-workspace in settings, leaves youcoded-inbox intact (only its provider body changed, which was in the marketplace PR, not the user machine).

- [ ] **Step 3: Verify clean state**

```bash
rclone listremotes | grep -v "^gdrive:" || echo NO_GDRIVE
grep "google-workspace" ~/.claude/settings.json || echo NO_GW_ENTRY
```

Both should print their "NO" lines.

- [ ] **Step 4: Commit DEV-VERIFICATION.md tick**

```bash
cd C:/Users/desti/youcoded-dev/.worktrees/google-services-marketplace
git add google-services/docs/DEV-VERIFICATION.md
git commit -m "verify(google-services): migration cutover confirmed on test machine

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Phase 6 — Ship

### Task 6.1: Merge both worktrees to master, push

- [ ] **Step 1: Merge marketplace worktree**

```bash
cd C:/Users/desti/youcoded-dev/wecoded-marketplace
git fetch origin && git pull origin master  # ensure up to date
git merge --no-ff feat/google-services -m "feat: google-services bundle (Phase 1–5 complete)"
git push origin master
```

- [ ] **Step 2: Merge core worktree**

```bash
cd C:/Users/desti/youcoded-dev/youcoded-core
git fetch origin && git pull origin master
git merge --no-ff feat/google-services-hook-cleanup -m "chore(hooks): remove tool-router Gmail/Calendar blocks (paired with google-services)"
git push origin master
```

- [ ] **Step 3: Verify both master branches contain the merges**

```bash
cd C:/Users/desti/youcoded-dev/wecoded-marketplace && git log --oneline master -5
cd C:/Users/desti/youcoded-dev/youcoded-core && git log --oneline master -5
```

### Task 6.2: Clean up worktrees + branches

- [ ] **Step 1: Remove marketplace worktree**

```bash
cd C:/Users/desti/youcoded-dev/wecoded-marketplace
# Verify the feature commits are on master first
git branch --contains $(git rev-parse feat/google-services) | grep -q master || { echo "NOT MERGED"; exit 1; }
git worktree remove ../.worktrees/google-services-marketplace
git branch -D feat/google-services
```

- [ ] **Step 2: Remove core worktree**

```bash
cd C:/Users/desti/youcoded-dev/youcoded-core
git branch --contains $(git rev-parse feat/google-services-hook-cleanup) | grep -q master || { echo "NOT MERGED"; exit 1; }
git worktree remove ../.worktrees/google-services-core
git branch -D feat/google-services-hook-cleanup
```

### Task 6.3: Retire the monolithic marketplace-integrations-v2.md plan

**Spec reference:** none (workspace hygiene).

**Files:**
- Modify: `docs/plans/marketplace-integrations-v2.md` — delete file, or replace with a one-line pointer to the new per-bundle specs

- [ ] **Step 1: Verify Google Services ships and the old plan's Google content is superseded**

Confirm the merge from Task 6.1 is on master and the spec at `docs/superpowers/specs/2026-04-16-google-services-design.md` exists.

- [ ] **Step 2: Replace old plan with a pointer**

Overwrite `docs/plans/marketplace-integrations-v2.md` with:

```markdown
# Marketplace Integrations — Superseded

This monolithic plan has been decomposed into per-bundle specs under
`docs/superpowers/specs/`. See:

- Google Services — [2026-04-16-google-services-design.md](../superpowers/specs/2026-04-16-google-services-design.md) (shipped)
- Apple Services — pending
- iMessage — pending
- Google Messages — pending
- macOS Control — pending
- Windows Control — pending
- Todoist — pending
- GitHub — pending
- Chrome — pending

The original document is preserved in git history pre-dating this commit.
```

- [ ] **Step 3: Commit**

```bash
cd C:/Users/desti/youcoded-dev
git add docs/plans/marketplace-integrations-v2.md
git commit -m "docs: retire monolithic marketplace-integrations plan

Decomposed into per-bundle specs under docs/superpowers/specs/. First bundle
(google-services) has shipped.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

### Task 6.4: Post-ship: refresh-token observation window

**Files:** `docs/superpowers/plans/research/2026-04-16-refresh-token-findings.md` updates if outcome differs from Task 0.1's prediction.

- [ ] **Step 1: Set a calendar reminder for 10 days from ship date**

At day 10, pull up Destin's personal setup and attempt a `gws gmail list --max 1`.

- [ ] **Step 2: Record outcome**

If it works: no-op; close the research item.
If it fails: confirm Task 0.1's fallback branch was correct. If the fallback wasn't taken (e.g., Task 0.1 returned GREEN but reality is RED at 10 days), file an urgent fix issue and re-open the OAuth strategy question.

---

## Self-review

### Spec coverage

| Spec section | Task(s) that implement it |
|--------------|---------------------------|
| Goal | Phase 1–5 as a whole |
| Scope — In scope | Tasks 3.1–3.6 (six skills) |
| Scope — Out of scope | Documented in plugin.json + spec; no task needed |
| Foundation — gws | Task 2.2 (install-gws.sh) |
| Foundation — gcloud | Task 2.1 (install-gcloud.sh) |
| OAuth strategy | Task 0.1 research + Task 2.3 (bootstrap-gcp.sh) |
| User-facing language policy | Enforced in Task 2.6 (slash command); spot-checked in every Phase 2/3 task |
| Architecture — Plugin layout | Task 1.2 |
| Architecture — How skills invoke gws | Tasks 2.5 (wrapper) + 3.1–3.6 (skills) |
| Architecture — How setup works | Task 2.6 |
| Architecture — Skill discovery | Tasks 3.1–3.6 + Task 4.3 (matcher test) |
| User-facing flow Step 0–7 | Task 2.6 (slash command authoritative) |
| Per-integration — Gmail | Task 3.1 |
| Per-integration — Drive | Task 3.2 |
| Per-integration — Docs | Task 3.3 |
| Per-integration — Sheets | Task 3.4 |
| Per-integration — Slides | Task 3.5 + research branch in Task 0.3 |
| Per-integration — Calendar | Task 3.6 |
| Per-integration — Shared concerns | Task 2.5 |
| Migration — registry changes | Tasks 5.1–5.4 |
| Migration — user-machine reconciliation | Task 5.6 |
| Migration — pre-ship verification | Task 5.7 |
| Failure modes | Handled in scripts (Tasks 2.1–2.4); no dedicated spec section task |
| Research items 1–3 | Tasks 0.1–0.4 |
| Dev-time verification checklist | Tasks 4.1–4.4 |
| Out of scope (v1) | Not implemented by design |

No gaps.

### Placeholder scan

All code blocks contain real code. The one "TODO" reference (in Slides RED-variant skill) is an explicit follow-up issue pointer, not an unfinished step.

### Type consistency

- `gws_run` function — consistent across all six skills (Tasks 3.1–3.6) and the wrapper (Task 2.5).
- `CLAUDE_PLUGIN_ROOT` — used identically in all skill SKILL.md files.
- `YOUCODED_OUTPUT_DIR` — set in the slash command (Task 2.6), consumed in bootstrap-gcp.sh (Task 2.3). Name matches.
- `PROJECT_ID` — set by bootstrap-gcp.sh, consumed for the warning screen in Task 2.6. Matches.

No drift.
