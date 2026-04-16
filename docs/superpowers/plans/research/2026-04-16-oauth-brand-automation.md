# Research — gcloud External-Consent Automation (Docs-Only)

**Date:** 2026-04-16
**Method:** Documentation review. No `gcloud` commands were run against any live GCP project.

## Sources consulted

- [gcloud iap oauth-brands (reference index)](https://docs.cloud.google.com/sdk/gcloud/reference/alpha/iap/oauth-brands) → command group exists; `alpha` prefix has been dropped for `oauth-brands`/`oauth-clients` but the surface is unchanged.
- [Programmatically creating OAuth clients for IAP](https://docs.cloud.google.com/iap/docs/programmatic-oauth-clients) → verbatim: API-created brands "are set to internal and must be manually set to public if desired." Output always shows `orgInternalOnly: true`.
- [Migrate from the IAP OAuth Admin API](https://docs.cloud.google.com/iap/docs/deprecations/migrate-oauth-client) → "You can no longer create or manage custom OAuth clients using the IAP OAuth 2.0 Admin API."
- [IAP Deprecations](https://docs.cloud.google.com/iap/docs/deprecations) → Admin API deprecated 2025-01-22; permanent shutdown staged through 2025, final cutoff 2026-03-19.
- [Google Developer Forum — OAuth Consent Screen automation limitations](https://discuss.google.dev/t/oauth-consent-screen-and-oauth-client-automation-limitations/134485) → "Unable to create OAuth Consent Screen with External, By default creating it as Internal." Scopes, test users, redirect URIs not configurable via Terraform/gcloud.
- [gcloud iam oauth-clients (Workforce Identity)](https://docs.cloud.google.com/iam/docs/workforce-manage-oauth-app) → verbatim: "OAuth application integration works only with Identity-Aware Proxy." Requires a workforce identity pool; not a replacement for consumer-facing OAuth.
- [Manage App Audience (support.google.com/cloud/answer/15549945)](https://support.google.com/cloud/answer/15549945) → describes the Audience setting (Internal vs. External) as a console-only surface on the Google Auth Platform page.
- [Manage OAuth App Branding (support.google.com/cloud/answer/15549049)](https://support.google.com/cloud/answer/15549049) → Google Auth Platform "Branding/Audience/Data Access" is console-only; first-time setup prompts "Get Started."
- [Simon Willison — Google OAuth for a CLI application](https://til.simonwillison.net/googlecloud/google-oauth-cli-application) → current practice for a Desktop client is still Console → APIs & Services → Credentials → Create Credentials → OAuth client ID → Desktop app.
- [803Tech blog — IAP OAuth Admin API deprecation (2025)](https://www.803tech.com/blog/xx1z62dxdznj1l0dordw7ot2cc6mbj) → confirms Google's strategic shift away from programmatic OAuth client provisioning.

## What's automatable via gcloud alone

Everything *project-scaffold* shaped:

```bash
gcloud projects create "$PROJECT_ID" --name="YouCoded"
gcloud config set project "$PROJECT_ID"
gcloud services enable \
  oauth2.googleapis.com \
  people.googleapis.com \
  gmail.googleapis.com \
  calendar-json.googleapis.com \
  drive.googleapis.com
gcloud alpha billing projects link "$PROJECT_ID" --billing-account="$BA"
```

Project creation, API enablement, billing link, IAM role grants, and service account creation are all scriptable. `gcloud iap oauth-brands list` still works for reading existing brand state.

## What still requires cloud-console clicks

Ordered, with rough time estimates for a user who has never done it:

1. **Open Google Auth Platform → click "Get Started"** on a fresh project (~15 s). No API equivalent.
2. **Fill in App info**: app name, user support email, developer contact email (~45 s).
3. **Select Audience = External** (~5 s). This is the blocker. `gcloud iap oauth-brands create` only produces `orgInternalOnly: true` brands; flipping to External requires a console click. The forum post quotes Google: the External option "should [be] edited via console."
4. **(Optional, recommended)** Add authorized domains, privacy policy / ToS links, and app logo (~60 s — or skipped for in-development apps).
5. **Add scopes** Claude will request (Drive, Calendar, Gmail, People): multi-select from a picker (~45 s). Not scriptable.
6. **Add test users** while in Testing mode (~30 s per email). Not scriptable.
7. **APIs & Services → Credentials → Create Credentials → OAuth client ID → Desktop app** (or Web + `http://localhost` redirect) to get the real `client_id`+`client_secret` (~30 s). *This is the step that actually produces the credentials YouCoded needs.*

Realistic total: **~3–5 minutes of console work**, most of it one-time per project.

## Newer API paths (and why they don't help)

- **`gcloud iap oauth-brands create`** — still exists, still only creates `orgInternalOnly: true` (Internal) brands. No flag to set External.
- **`gcloud iap oauth-clients create`** — produces an **IAP-locked** client. Its redirect URI is fixed to `https://iap.googleapis.com/v1/oauth/clientIds/CLIENT_ID:handleRedirect` and the API "does not allow any updates to the redirect URI or other attributes." **Not usable for a desktop/web user-consent flow.**
- **IAP OAuth Admin API deprecation** — deprecated 2025-01-22; the migration guide explicitly says "You can no longer create or manage custom OAuth clients" via API and directs users to the console. Google replaced it with a Google-managed OAuth client for IAP itself, which is irrelevant to third-party user-consent flows.
- **`gcloud iam oauth-clients`** — *looks* promising but the docs state "OAuth application integration works only with Identity-Aware Proxy." It is Workforce-Identity-Federation-only, not a consumer OAuth surface.
- **Terraform `google_iap_brand` / `google_iap_client`** — same underlying API; same Internal-only + IAP-locked constraints; the terraform-provider-google tracker (issue #21378) confirms no replacement.

**Bottom line: there is no non-alpha, non-IAP gcloud path for creating an External consent screen or a consumer OAuth client in 2026.** Google has actively moved *away* from programmatic OAuth client provisioning.

## Verdict

**YELLOW — 5 unavoidable console clicks**, clustered on two pages (Google Auth Platform + Credentials). Everything around them is scriptable.

Minimum manual set, in order:
1. Click "Get Started" on Google Auth Platform.
2. Select **External** audience.
3. Add scopes.
4. (If staying in Testing) add test users.
5. Credentials → Create OAuth client ID → Desktop app → copy `client_id`/`client_secret`.

## Recommendation

Design `bootstrap-gcp.sh` as a **hybrid script with two pause points**:

**Phase 1 (fully automated, ~20 s):**
```bash
gcloud projects create …
gcloud config set project …
gcloud services enable oauth2 people gmail calendar drive …
gcloud alpha billing projects link …
```
Print the project ID and a deep link: `https://console.cloud.google.com/auth/overview?project=<PROJECT_ID>`.

**Phase 2 (screenshot-guided, ~2 min):** show the user a one-screen checklist with annotated screenshots covering steps 1–4 above (Get Started → External → scopes → test users). Wait on stdin for "done."

**Phase 3 (screenshot-guided, ~30 s):** deep-link to `https://console.cloud.google.com/apis/credentials?project=<PROJECT_ID>`, screenshot showing "Create Credentials → OAuth client ID → Desktop app." Prompt the user to paste the resulting `client_id` and `client_secret` into a secure stdin capture; store via the OS keychain.

**Phase 4 (fully automated):** run the YouCoded OAuth authorization code flow against the pasted credentials, exchange for refresh token, persist.

This keeps the experience a single guided setup rather than a blind "open the console" checklist. Do **not** spend engineering effort trying to automate steps 1–5 further — per the deprecation trajectory, Google is hardening the console-only path, not opening a new API.
