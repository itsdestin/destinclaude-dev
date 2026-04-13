# Civic Report Skill — Design Spec

**Date:** 2026-04-12
**Status:** Design approved, pending implementation plan
**Target repo:** `destincode-marketplace/skills/civic-report/`

## Overview

Civic Report is a DestinCode marketplace skill that produces a comprehensive, research-backed report on the user's federal representatives (President, VP, both US Senators, US House Rep) plus name-level info on their state officials (Governor, state senator, state rep), tailored to a user-supplied angle, tone, and section selection. Output is a single markdown file saved to the user's workspace.

The skill runs independently per user — no central service, no shared infrastructure. It is keyless by default (Census Geocoder, `@unitedstates/congress-legislators`, GovTrack, Wikipedia, Claude's `WebFetch` / `WebSearch`). An optional user-supplied free `api.data.gov` key unlocks enhanced campaign-finance data via FEC. When a rep has an election within 12 months, the skill conditionally offers opponent research.

## Goals and non-goals

**Goals (v1):**
- Generate an accurate, source-linked report on the user's federal reps given a US street address.
- Include state-official names (Governor, state senator, state rep) as a lightweight stub.
- Support user-directed personalization: angle, tone, scope of sections, depth.
- Offer opponent research when elections are within 12 months.
- Work fully keyless with graceful degradation; unlock enhanced finance data with an optional free key.
- Leave no central-service burden on the creator.

**Non-goals (v1):**
- Local officials (mayor, council, school board, county) — data too fragmented.
- Ballot measures / propositions.
- Judicial records.
- Historical reports for prior terms.
- Scheduled or recurring report generation.
- Sharing / export beyond writing the markdown file.
- Encyclopedia integration (DestinClaude toolkit) — possible v2.

## Packaging and distribution

Shipped as a single marketplace skill under `destincode-marketplace/skills/civic-report/`. Layout:

```
civic-report/
  SKILL.md                  # Claude-facing control flow + instructions
  plugin.json               # marketplace manifest (name, version, description)
  scripts/
    resolve-districts.js    # address → federal + state districts (Census Geocoder)
    fetch-members.js        # who represents those districts (congress-legislators JSON)
    fetch-voting.js         # GovTrack: party unity %, recent votes
    fetch-finance.js        # FEC via api.data.gov (optional key) or scraped fallback
    fetch-elections.js      # term-end dates → upcoming-election detection
    setup-key.js            # first-run optional key prompt + save
  prompts/
    report-template.md      # section scaffolding Claude fills in
    tone-instructions.md    # per-tone interpretive-lens guidance
  README.md                 # user-facing install / usage
```

**Runtime:** Node.js scripts (Claude Code ships with Node; aligns with existing marketplace tooling). Scripts output structured JSON to stdout; SKILL.md orchestrates them and tells Claude how to compose the narrative.

**Config storage:** `~/.claude/plugins/<skill-id>/config.local.json` for the optional `api.data.gov` key. Machine-specific, not synced (matches the toolkit's `config.local.json` convention).

## User flow

### First run (once per machine)

1. User invokes the skill.
2. Skill checks for `config.local.json`. If absent, runs `setup-key.js`:
   - Explains what an `api.data.gov` key unlocks (clean FEC campaign-finance data).
   - Links to `https://api.data.gov/signup/` (30-second free signup, no billing).
   - Prompts: "Paste your key, or press Enter to skip and use the keyless fallback."
   - Writes `config.local.json` either way (`{ "apiDataGovKey": "..." }` or `{ "skipped": true }`).
3. Key is stored plaintext; acceptable for a free, rate-limit-only key. Called out explicitly in the prompt.

### Per-report flow

1. **Address** — street, city, state, ZIP. Required. US-only.
2. **Angle** — free-text; suggested examples shown ("housing / guns / abortion / immigration / climate / economy / foreign policy / general"). User types own or picks one. Used to bias votes/statements surfacing.
3. **Tone** — one of: Neutral / Analytical / Devil's advocate / Cynic / Sarcastic / Historian.
4. **Scope** — "Full report (all 8 sections)" or "Custom (pick which sections to include)." If custom, user selects from the section list below.
5. **Depth** — Quick (~150 words/section) / Standard (~400) / Deep dive (~1000+).
6. Skill runs `resolve-districts.js` → `fetch-members.js` → `fetch-elections.js`.
7. **Batched opponent-research prompt.** If any rep has an election within 12 months, single prompt lists all of them:
   ```
   Upcoming elections detected:
     • US Senator Jane Smith — 8 months (Nov 2026)
     • US Rep John Doe — 8 months (Nov 2026)

   Include opponent research? [A] All  [N] None  [S] Select subset
   ```
   Opponent research folds into those reps' report sections as an "Upcoming election & opponents" subsection — not a separate top-level section.
8. Skill runs remaining fetchers (voting, finance) plus Claude-driven web research (scandals, statements, opponents if requested).
9. Claude composes the report using `report-template.md` as scaffolding, writes to `reports/civic-<YYYY-MM-DD>-<address-hash>.md` in the user's workspace, and links it.

## Report sections

User chooses Full or Custom from this list. Each federal rep gets the selected sections; state officials get a lightweight version (Basics + Claude's take when tone ≠ Neutral).

1. **Basics** — office, district, term, party, committee assignments.
2. **Ideological profile** — party-unity %, notable breaks from party, ideology score.
3. **Recent notable votes** — last 6–12 months, tied to user's angle when possible.
4. **Campaign finance** — top donors, industry breakdown, self-funding ratio. Omitted with note if no API key and scraping fallback fails.
5. **Scandals & controversies** — historical, sourced.
6. **Recent public statements** — speeches, interviews, social media (via news aggregators).
7. **Electoral context** — margin of last win, next election; includes opponent research for users who opted in.
8. **Claude's take** — only rendered when tone ≠ Neutral.

## Data sources and fallbacks

Each script has a keyless primary path and graceful degradation.

| Data | Primary (keyless) | Enhanced (key) | If fails |
|------|-------------------|----------------|----------|
| Address → district | Census Geocoder | — | Ask user for district manually |
| Federal member bios | `@unitedstates/congress-legislators` raw GitHub JSON | — | Hard-fail (shouldn't happen) |
| State officials (names only) | Ballotpedia page scrape + Wikipedia "List of current state legislators" | — | Flag section as "couldn't resolve" |
| Voting records & party unity | GovTrack API | — | WebFetch congress.gov vote pages |
| Campaign finance | WebFetch OpenSecrets public pages (rough summary) | FEC via `api.data.gov` key | Section omitted with explicit note |
| Scandals & controversies | Claude WebSearch + Wikipedia controversies sections | — | "No significant controversies found" |
| Recent statements | Claude WebSearch against news + official site | — | Skip section |
| Opponent research | Ballotpedia candidate pages + FEC filings + WebSearch | FEC enhanced if key present | "Limited data available" note |

**Fallback principles:**
- Every section can be omitted without breaking the report.
- Every omitted section says *why* (e.g., "Campaign finance data unavailable — add a free api.data.gov key to enable").
- No section ever fabricates. If WebSearch returns nothing, the report says so.

## Report generation

**Orchestration:** SKILL.md is the control flow. It instructs Claude to:
1. Run fetchers in sequence, feeding each script's JSON into a structured context object.
2. For narrative sections (scandals, statements, opponent research), perform `WebSearch` / `WebFetch` per rep, with explicit "return empty if nothing credible found — do not fabricate" instructions.
3. Fill the template using the assembled context.

**Template structure** (`prompts/report-template.md`):

```markdown
# Civic Report — {{address}}
Generated {{date}} · Angle: {{angle}} · Tone: {{tone}} · Depth: {{depth}}

## Federal
### {{rep.title}} {{rep.name}} ({{rep.party}})
[Basics] [Ideological profile] [Recent notable votes] [Campaign finance]
[Scandals & controversies] [Recent statements] [Electoral context & opponents]
[Claude's take — if tone ≠ Neutral]

## State
### Governor / State Senator / State Rep
[Basics only + Claude's take if tone ≠ Neutral]

## Sources
[footnote-style list of every URL consulted, grouped by rep]
```

**Tone application:** a tone-specific instruction block from `tone-instructions.md` is injected into Claude's context before composition. Example for Cynic: *"Assume self-interest as the default hypothesis. Follow the money. Flag hypocrisy and patterns of convenience. Facts must remain accurate — it's the interpretive lens that shifts, not the data."* Tone applies only to Claude's-take and narrative framing, never to Basics / Votes / Finance data sections.

**Depth application:** controls prose length per section (Quick ≈ 150 words, Standard ≈ 400, Deep ≈ 1000+). Does not control which sections are included — scope handles that.

**Source transparency:** every factual claim gets an inline footnote linking to the source URL. No source → no claim. Non-negotiable for a political report.

## Privacy

- Address is used only to resolve districts via Census Geocoder (keyless, no account), then discarded from memory.
- Report filename uses a short SHA-256 hash of the normalized address (`civic-2026-04-12-a3f91c.md`), not the raw address. The address *is* rendered in the report body since the user is looking at it; sharing is the user's choice.
- No telemetry, no phone-home, no remote logging. Every request goes directly from user's machine to public APIs or Claude's web tools.
- `config.local.json` stores the `api.data.gov` key in plaintext. Acceptable for a free rate-limit-only key; called out explicitly in the setup prompt.

## Edge cases

- **Non-US address** — Census Geocoder returns no match. Skill exits with "This skill currently only supports US addresses."
- **Vacant seat** — `congress-legislators` flags this; report renders "Seat vacant — special election [date]" and skips rep-specific sections for that seat.
- **Brand-new rep** (sworn in <6 months ago) — thin voting record. Template has a "new member" branch leaning on prior role, campaign promises, and first-N-votes rather than synthetic ideology scores.
- **At-large states** (WY, VT, etc.) — one House rep instead of district-specific.
- **DC / territories** — delegate (non-voting); rendered as such, no ideology scores.
- **Rate-limit hit** on GovTrack / FEC — exponential backoff with one retry, then degrade to "data unavailable this run — try again in a few minutes."
- **Conflicting sources** — when Wikipedia and Ballotpedia disagree on a fact, the report presents both with attribution rather than picking one.

## v2 candidates (parking lot, out of scope)

- State officials upgraded from names-only to full profile.
- Local officials via a separate `local-civic-report` skill with user-contributable municipality scrapers.
- "Diff since last report" — re-run and highlight what changed.
- DestinClaude encyclopedia integration for toolkit users.
- Ballot measure explainer companion skill.

## Open questions (for implementation planning)

- Exact marketplace-skill manifest fields (`plugin.json`) required by `destincode-marketplace`'s validation workflow — pin down during planning.
- Which existing marketplace skill, if any, has scripts + config flow we should mirror (rather than invent fresh). Check during planning.
- User-facing invocation — is this a `/civic-report` slash command, a named skill Claude discovers via description, or both? Planning should decide.
