# Research — 7-day Refresh-Token Expiry (Documentation-Only)

**Date:** 2026-04-16
**Method:** Documentation review. Empirical observation skipped per scope decision.
**Researcher:** subagent (Claude, Opus 4.7)

## Policy sources consulted

- https://developers.google.com/identity/protocols/oauth2 — Canonical OAuth 2.0 reference. Last-updated footer: **2026-04-03 UTC**. Contains the definitive statement of the 7-day rule (quoted below).
- https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification — "Sensitive scope verification" page. Confirms unverified apps face "a tester warning screen... a user cap... and the refresh token lifetime is limited."
- https://support.google.com/cloud/answer/15549945 — "Manage App Audience" (the successor to older publishing-status docs). Describes the Publish-app button and states projects "In production should complete the verification process... if it meets one or more of the OAuth verification criteria."
- https://support.google.com/cloud/answer/10311615 — OAuth consent-screen branding doc. **No refresh-token content.** Only 7-day mention is a verification-result freshness window (irrelevant).
- https://support.google.com/cloud/answer/13463073 — OAuth app-verification overview. Mentions sensitive/restricted scope categories but **says nothing about token lifetime.**
- https://github.com/googleworkspace/cli/issues (reviewed #137, #187, #198, #220) — No issue in the official gws CLI tracker discusses the 7-day refresh-token policy. The open auth issues are credential-persistence / 401-on-save bugs, unrelated to the testing-mode lifetime cap.

## Findings

Google's own developer docs state the rule explicitly (as of 2026-04-03):

> "A Google Cloud Platform project with an OAuth consent screen configured for an external user type and a publishing status of 'Testing' is issued a refresh token expiring in 7 days"
> — developers.google.com/identity/protocols/oauth2

The documented exception is narrow:

> "...unless the only OAuth scopes requested are a subset of name, email address, and user profile (through the `userinfo.email`, `userinfo.profile`, `openid` scopes or their OpenID Connect equivalents). For such requests, authorizations will not expire after 7 days."

**Every scope in our target set** (`gmail.modify`, `drive`, `calendar`, `documents`, `spreadsheets`, `presentations`) is classified sensitive or restricted by Google's scope policy — none fall into the exception. So for a brand-new "bring-your-own-GCP" project in Testing, the 7-day expiry applies unconditionally.

The sensitive-scope-verification page confirms the restriction is tied to **unverified** state, not strictly to the Testing label: "Your app is still subject to a tester warning screen, a user cap is in effect, and the refresh token lifetime is limited." This phrasing appears in the context of apps that have submitted for verification but not yet been approved, implying the 7-day limit persists into an unverified-but-Published state.

## Ambiguities

1. **Unverified Production:** No Google page I read explicitly states "if you click Publish app but never submit for verification, your tokens last longer than 7 days." The sensitive-scope-verification language strongly implies the limit follows the *unverified* status, not the *Testing* label. Community threads (n8n, HomeSeer, adwords-api groups) treat "publish to Production" as the fix, but Google's own docs don't cleanly separate "Production + unverified" from "Testing."
2. **Six-month idle rule:** A separate Google policy invalidates any refresh token unused for 6 consecutive months. Orthogonal to the 7-day rule but worth mentioning since it also affects bring-your-own-GCP UX.
3. **100-token-per-client cap:** OAuth clients are capped at 100 refresh tokens per Google Account. For single-user BYO projects this is irrelevant, but if a user ever re-authorizes in a loop (tools misconfigured) they'll silently evict their own tokens.

## Workarounds

1. **Publish to Production without submitting for verification.** User clicks "Publish app" in the GCP console. Consent screen shows an "unverified app" warning (users click "Advanced → Go to <app> (unsafe)"). Per community reports and the partial Google phrasing, this *may* lift the 7-day limit while leaving the 100-user cap in place. **Docs do not guarantee this.** It's the closest thing to a documented escape hatch, but Google has been tightening this path over time.
2. **Submit for verification.** Restores normal token lifetimes but requires a verified domain, homepage, privacy policy, demo video, and ~4–6 weeks of review for restricted scopes (Gmail/Drive). Not feasible for a user's throwaway project.
3. **Restrict to non-sensitive scopes.** `userinfo.email` / `userinfo.profile` / `openid` alone avoid the 7-day rule — but they give no Gmail/Drive/Calendar access, so this is a no-go for the feature as speced.
4. **Re-auth UX.** Ship weekly re-auth as the intended UX and make it smooth (toast + one-click re-consent).

## Verdict

**RED (with a YELLOW asterisk).**

The 7-day expiry definitively applies to our spec as written: External + Testing + sensitive/restricted scopes. There is no clean, Google-documented workaround that a non-technical user can execute on their own throwaway project. The "publish to Production unverified" path is the only plausible workaround and it (a) is not explicitly documented to lift the limit, (b) shows a scary "unsafe app" warning to the user during consent, and (c) is a surface Google has signaled they may restrict further.

## Recommendation

Do **not** ship BYO-GCP with sensitive scopes as the default. Pick one:

1. **(Preferred) Pivot to a YouCoded-owned verified app** for Gmail/Drive/Calendar/Docs/Sheets/Slides. This costs 4–6 weeks of Google verification review and ongoing compliance (CASA audit for restricted scopes) but yields a normal UX.
2. **Ship BYO-GCP for non-sensitive scopes only** (profile/email/openid) as a v1, with a "connect via YouCoded app" upgrade path for the heavy scopes once the verified app exists.
3. **If BYO-GCP must ship now with sensitive scopes,** surface the 7-day expiry as a first-class UX fact: schedule a re-auth reminder at day 6, keep tokens encrypted locally so re-auth is one click, and document the Production-publish workaround in-app as an "advanced" toggle with the tradeoffs spelled out.

Option 2 is the lowest-regret path: it ships quickly, honors the spec's fallback list, and doesn't burn user trust on a weekly re-auth treadmill.
