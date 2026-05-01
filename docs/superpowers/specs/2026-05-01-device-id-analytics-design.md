# Device-ID Analytics — Redesign

**Status:** Drafted; pending Destin's review.
**Created:** 2026-05-01
**Owner:** Destin
**Builds on:** [2026-04-23-privacy-analytics-design.md](2026-04-23-privacy-analytics-design.md). Replaces the random-UUID `install_id` with a hashed-hardware `device_id`, drops the `install` event, and adds region-level geography. Hard cutover; pre-cutover history is abandoned.

---

## Goal

Make YouCoded's "active users" metric reflect **unique physical devices** instead of unique `~/.claude/youcoded-analytics.json` files. Today, every machine wipe, every separate `~/.claude` profile (`releaseTest` builds, dev VMs), and every fresh OS install rotates the `install_id` and inflates DAU/MAU. With <20 MAU and several developers' devices in the dataset, that contamination is a meaningful share of every percentage. A stable per-device hash, combined with an admin-device filter, gives a clean number.

Drop the `install` event entirely. "First seen" derived from the heartbeat stream is a more honest install signal than a random-UUID-creation event that fires whenever the analytics state file is regenerated.

## Non-goals

- **Engagement / message-content telemetry.** Out of scope by user mandate. The system stays a daily-attendance counter — we are NOT collecting session counts, message counts, plugin installs, or any in-app behavior.
- **Per-user identity.** A device is not a user. A user with a desktop and a phone counts as two devices; a household sharing one laptop counts as one. The spec promises devices, not users.
- **Backfill of pre-cutover data.** Existing 9 days of `install_id`-keyed rows have no derivable `device_id_hash`. They're abandoned. Pre-cutover queries are excluded by a `WHERE timestamp > <cutover>` clause.
- **Cross-tabulated dimensions.** No endpoint will combine region with version/platform/OS in one query. Single-dimension queries only.
- **Server-side hashing.** Decided against to keep raw machine IDs off the Worker entirely. See "Hash placement" below.
- **Small-cell suppression.** Decided against per Destin's call — admin-only endpoints, internal use only.

## Threat model

The privacy contract from the v1 design holds: **raw `device_id` material never leaves the user's device.** Concretely:

- Client computes `HMAC_SHA256(salt, machine_id || platform)` on launch.
- Only the 64-char hex hash crosses the network.
- The Worker stores only the hash. `count(DISTINCT blob2)` is the only way the hash appears in any admin response.
- A Worker compromise (memory dump, log leak) cannot recover raw machine IDs because they were never present.
- A binary-decompile attack (extracting the salt from the source) is uninteresting in isolation: the attacker still needs the target's raw `machine_id`, obtainable only with physical or root access to the target device.

The non-goal: defending against an attacker who has both the salt AND the target's raw machine_id AND the YouCoded hash database. They could confirm "this person uses YouCoded." For an analytics system serving an open-source side project, this threat model is acceptable.

---

## Architecture

### What changes, top-down

| Layer | Today | After |
|---|---|---|
| Client state file `~/.claude/youcoded-analytics.json` | `{installId, optIn, lastPingedDate, installReported}` | `{optIn, lastPingedDate, fallbackDeviceId?}` |
| Client event firing | `install` (once) + `heartbeat` (daily) | `heartbeat` (daily) only |
| Identity | Random UUID generated client-side | `HMAC_SHA256(salt, machine_id \|\| platform)` |
| Desktop machine_id source | n/a | `node-machine-id` (Windows MachineGuid / macOS IOPlatformUUID / Linux /etc/machine-id) |
| Android machine_id source | n/a | `Settings.Secure.ANDROID_ID` |
| Hash placement | n/a | Client-side. Salt baked into source. |
| HTTP endpoints | `POST /app/install`, `POST /app/heartbeat` | `POST /app/heartbeat` only |
| AE blob layout | blob1=eventType, blob2=installId, blob3=appVersion, blob4=platform, blob5=os, blob6=country | blob1=`'heartbeat'` (vestigial), blob2=device_id_hash, blob3-6 unchanged, **blob7=region** (new) |
| Admin queries | `count(DISTINCT blob2) AS users` | `count(DISTINCT blob2) AS devices`, gated by cutover clause + admin-device filter (escape via `?include_admins=1`) |
| `/admin/analytics/regions` | n/a | New endpoint, top-20, no suppression |
| `/admin/analytics/installs` | `count() WHERE blob1='install'` | Derived from `MIN(timestamp) GROUP BY blob2` (subject to AE SQL support — see Risks) |
| `/analytics` skill | "users" | "devices" — copy + table headers update |
| In-app privacy copy | "random UUID, never tied to your machine" | "irreversible hash of a hardware identifier — the raw ID never leaves your device" |

### Privacy invariants preserved

1. Raw machine IDs never reach the Worker (client-side hashing).
2. `blob2` (the hash) appears only inside `count(DISTINCT)` aggregates in admin queries — same contract as v1.
3. IP is read at request time for `CF-IPCountry` / `CF-IPRegionCode`, never stored.
4. Opt-out is a single user-controlled boolean. When off, no events fire and no hash is computed.

---

## Client design

### Desktop — `youcoded/desktop/src/main/analytics-service.ts`

**State file shape:**
```ts
interface AnalyticsState {
  optIn: boolean;
  lastPingedDate: string;       // YYYY-MM-DD UTC, "" when never pinged
  fallbackDeviceId?: string;    // present only if machine_id read failed
}
```

Migration: on read, drop `installId` / `installReported` if present. (They're harmless if left, but cleaner to remove. Migration is a no-op overwrite on first launch of the new version.)

**Dependency:** add `node-machine-id` to `package.json`. Mature single-purpose dep with sync API; no native compile.

**Identity computation:**
```ts
function deviceIdHash(state: AnalyticsState): string {
  let raw = "";
  try {
    raw = machineIdSync({ original: true });
  } catch { /* swallow — caught by length check below */ }

  if (!raw || raw.length < 8) {
    if (!state.fallbackDeviceId) {
      state.fallbackDeviceId = randomUUID();
      writeState(state);
    }
    raw = `fallback:${state.fallbackDeviceId}`;
  }

  return createHmac("sha256", SALT)
    .update(`${raw}|${process.platform}`)
    .digest("hex");
}
```

The `fallback:` prefix prevents collision between a genuine UUID-shaped machine_id and a fallback UUID. The `|platform` suffix is defense-in-depth.

**Salt:** a 32-byte (64 hex char) random string baked into a `const SALT` in the analytics-service module. Generated once during implementation via `crypto.randomBytes(32).toString('hex')`, committed to the repo. This is intentionally not a secret-from-decompile; see the threat model above.

**Event firing — `runAnalyticsOnLaunch()`:**
```ts
const state = readState();
if (!state.optIn) return;

const today = todayUtc();
if (state.lastPingedDate === today) return;

const hash = deviceIdHash(state);  // may persist fallbackDeviceId
const ok = await postEvent("/app/heartbeat", {
  deviceIdHash: hash,
  appVersion: app.getVersion(),
  platform: "desktop",
  os: mapOs(process.platform),
});

if (ok) {
  state.lastPingedDate = today;
  writeState(state);
}
```

The `install` POST and `installReported` flag are both removed.

### Android — `youcoded/app/src/main/kotlin/com/youcoded/app/analytics/AnalyticsService.kt`

Mirror behavior. Reads `Settings.Secure.ANDROID_ID` instead of node-machine-id; falls back to a persisted UUID if the read returns null or empty (rare on modern Android — only happens on factory-reset transitional states or pre-API-17 devices YouCoded doesn't target). Same HMAC, same SALT, same heartbeat firing logic.

**Salt parity with desktop:** strictly speaking unnecessary because `|platform` is in the HMAC input (so cross-platform hashes diverge for the same device anyway). But sharing one salt is simpler than maintaining two. We pick a single salt and duplicate it in both source trees, with a parity test pinning the same expected hash for a fixed (machine_id, platform) input.

### Tests

- `analytics-service.test.ts` (existing — extend):
  - First launch with machine_id available → hashes machine_id, no `fallbackDeviceId` written.
  - First launch with machine_id read failure → generates `fallbackDeviceId`, hashes prefixed string.
  - Same UTC day re-launch → no heartbeat.
  - Next-day launch → heartbeat fires with stable hash.
  - Opt-out → no event, no `fallbackDeviceId` ever written.
- `analytics-hash-parity.test.ts` (new):
  - Given fixed `(machine_id="known-string", platform="darwin")`, asserts the hash equals a hardcoded expected value.
  - Catches silent salt drift between desktop and Android (Android's parallel test runs the same input through `AnalyticsService.kt`'s HMAC and asserts the same output).

---

## Worker design

### Endpoints

- **DELETE** `POST /app/install`. Routes file: remove the handler.
- **MODIFY** `POST /app/heartbeat`. New payload schema:
  ```ts
  {
    deviceIdHash: string,       // /^[a-f0-9]{64}$/
    appVersion: string,
    platform: "desktop" | "android",
    os: string                  // "win" | "mac" | "linux" | ""
  }
  ```
  Validation: if `deviceIdHash` is missing or doesn't match the regex, return 200 with no AE write. (See "Rollout sequence" — fire-and-forget endpoint, returning 400 would cause old clients on `installId`-only payloads to retry forever. Silent drop lets the old client advance its `lastPingedDate` and stop bothering the Worker until it's updated.) Once dual acceptance is dropped (rollout step 6), this becomes a 400.

### `lib/analytics.ts`

```ts
export interface AppEventPayload {
  deviceIdHash: string;
  appVersion: string;
  platform: "desktop" | "android";
  os: string;
  country: string;   // server-derived from CF-IPCountry
  region: string;    // server-derived from CF-IPRegionCode (NEW)
}

export function writeAppEvent(env: Env, payload: AppEventPayload): void {
  env.APP_ANALYTICS?.writeDataPoint({
    blobs: [
      "heartbeat",            // blob1 — vestigial, retained for forward-compat
      payload.deviceIdHash,   // blob2 — semantically different from pre-cutover
      payload.appVersion,     // blob3
      payload.platform,       // blob4
      payload.os,             // blob5
      payload.country,        // blob6
      payload.region,         // blob7 — NEW
    ],
    doubles: [],
    indexes: ["heartbeat"],
  });
}
```

Blob1 is now constant `"heartbeat"`. It's kept rather than dropped so a future second event type has an existing discriminator slot.

### Cutover mechanic

Add `CUTOVER_TIMESTAMP` to `wrangler.toml` `[vars]` — ISO 8601 string set to the release date of version N (e.g., `"2026-05-15T00:00:00Z"`). Every analytics query appends:

```sql
AND timestamp > toDateTime('${env.CUTOVER_TIMESTAMP}')
```

Cloudflare AE supports `toDateTime()` for string→timestamp coercion. Pre-cutover rows (where `blob2` was `install_id`-shaped) are excluded from every query result. After 90 days, the clause becomes a no-op (no rows older than 90 days exist anyway).

### Admin filter

- Secret: `KNOWN_DEV_DEVICES` — comma-separated list of device hashes. Set via `wrangler secret put`, NOT in `[vars]` (avoids the var-clobbers-secret pitfall flagged in `docs/PITFALLS.md → Cloudflare Workers`).
- Query helper:
  ```ts
  function adminFilterClause(env: Env, c: Context): string {
    if (c.req.query("include_admins") === "1") return "";
    const hashes = (env.KNOWN_DEV_DEVICES ?? "")
      .split(",").map(s => s.trim()).filter(Boolean)
      .map(h => h.replace(/[^a-f0-9]/g, ""))   // hex-only sanitize
      .filter(h => h.length === 64)
      .map(h => `'${h}'`);
    if (!hashes.length) return "";
    return `AND blob2 NOT IN (${hashes.join(",")})`;
  }
  ```
  Hex-only sanitization is mandatory because we're string-interpolating into SQL. Same defensive pattern as the existing `clampDays()` for `?days=N`.

- Escape hatch: `?include_admins=1` on any `/admin/analytics/*` request returns numbers including admin devices (debug only).

### Updated query family

All six existing endpoints get the cutover clause and admin filter prepended. The column rename `users → devices` propagates through the response shapes. Example MAU query:

```sql
SELECT count(DISTINCT blob2) AS devices
FROM youcoded_app_events
WHERE blob1 = 'heartbeat'
  AND timestamp > toDateTime('${env.CUTOVER_TIMESTAMP}')
  AND timestamp > NOW() - INTERVAL '30' DAY
  ${adminFilterClause(env, c)}
```

**New endpoint** — `GET /admin/analytics/regions`:

```sql
SELECT blob7 AS region, count(DISTINCT blob2) AS devices
FROM youcoded_app_events
WHERE blob1 = 'heartbeat'
  AND timestamp > toDateTime('${env.CUTOVER_TIMESTAMP}')
  AND timestamp > NOW() - INTERVAL '30' DAY
  ${adminFilterClause(env, c)}
GROUP BY region ORDER BY devices DESC LIMIT 20
```

Returns ISO 3166-2 codes (`US-CA`, `CA-ON`, `GB-ENG`, etc.). No `HAVING users >= N` — admin-only endpoint, full data.

### "Installs per day" — derived

`/admin/analytics/installs` keeps its name and shape but the underlying query becomes "first-seen device per day":

```sql
SELECT toDate(first_seen) AS day, count() AS installs
FROM (
  SELECT blob2, MIN(timestamp) AS first_seen
  FROM youcoded_app_events
  WHERE blob1 = 'heartbeat'
    AND timestamp > toDateTime('${env.CUTOVER_TIMESTAMP}')
    ${adminFilterClause(env, c)}
  GROUP BY blob2
)
WHERE first_seen > NOW() - INTERVAL '${days}' DAY
GROUP BY day ORDER BY day
```

**Risk:** Cloudflare AE's SQL subset MAY NOT support subqueries in `FROM`. If the query 422s during implementation, fallback is the **two-query pattern**: fetch `(blob2, MIN(timestamp))` rows from AE, group by date in JS inside the route handler. The implementation plan must validate this against the live AE API early. If neither subqueries nor a clean two-query fallback work, the option is to drop `/admin/analytics/installs` entirely (devices is the headline anyway) — but that's last resort.

### Tests

- `worker/src/admin/analytics.test.ts` — extend:
  - Each endpoint returns `devices` column instead of `users`.
  - Admin filter excludes hashes in `KNOWN_DEV_DEVICES` from every endpoint.
  - `?include_admins=1` returns un-filtered numbers.
  - Cutover clause excludes a synthetic row inserted with `timestamp` before the cutover.
  - New `/admin/analytics/regions` returns expected shape.
  - 422-or-fallback test for the installs-derivation query (whichever path we land on).
- `worker/src/lib/analytics.test.ts` — extend:
  - Region included in payload.
  - blob order matches the SQL queries' assumptions (regression guard).

---

## Privacy disclosure

Sites to update (grep for the current `random UUID, never tied to your machine` text to find every spot):

1. Desktop `AboutPopup.tsx` — Privacy section.
2. `wecoded-marketplace/landing/` FAQ — wherever the current analytics copy lives.
3. Any developer docs in `docs/` referencing the old wording.

Proposed replacement text:

> **Anonymous usage analytics**
>
> If enabled, YouCoded sends one ping per day with: an irreversible hash of your device's hardware ID, the app version, the platform (desktop/android), and your OS family. The raw hardware ID never leaves your device — it's hashed locally with a secret key before transmission, so the hash cannot be reversed back to the original ID.
>
> Your IP address is read once per request to determine your country and approximate region (e.g., US state) for aggregate metrics. IP addresses are never stored.
>
> No message content, no usernames, no tokens, no file paths — only the data listed above. You can disable this in Settings → Privacy at any time.

The exact wording is finalized during implementation; this is the substance.

---

## `/analytics` skill changes

`youcoded-admin/skills/analytics/SKILL.md` text updates:

| Field | Old | New |
|---|---|---|
| Headline DAU label | "DAU (today)" | "Devices active today" |
| Headline MAU label | "MAU (rolling 30-day)" | "Devices active (rolling 30d)" |
| Installs label | "New installs (7d)" | "New devices (7d)" |
| Versions label | "Top versions" | (unchanged) |
| Platforms label | "Platform split" | (unchanged) |
| Countries label | "Top countries" | (unchanged) |
| Regions row | (none) | "Top regions: US-CA 5, US-TX 3, …" |
| Footer | (none) | "Counted unique devices, excluding admin devices." |

Bare-summary parallel fetch grows from 6 endpoints to 7 (adds `/admin/analytics/regions`). Negligible cost.

---

## Rollout sequence

1. **Worker change deploys first.** During the soak (until version N is the only version in the wild), the Worker accepts EITHER `installId` OR `deviceIdHash` in the heartbeat payload. Old-client heartbeats with `installId` are dropped on the floor (not written to AE) — the Worker validates `deviceIdHash` is present and well-formed, otherwise no write. Cleaner than dual-writing because pre-cutover rows are excluded from queries anyway.
2. **Desktop + Android version N ship together** with the new analytics client. New clients send `deviceIdHash`.
3. **Set `CUTOVER_TIMESTAMP` env var** to the release timestamp of version N.
4. **Populate `KNOWN_DEV_DEVICES` secret** by running version N once on each of Destin's known devices (laptop, dev VM, releaseTest installs) and reading the hash from the worker logs. Alternative: a debug-only IPC in the desktop app prints the hash to console — implementation detail, decided during the plan.
5. **`/analytics` skill text updates** ship as a separate commit — can land any time after the Worker is live. (The skill lives at `~/.claude/skills/analytics/`; updates to `youcoded-admin/skills/analytics/` need to be re-copied.)
6. **Drop the dual `installId|deviceIdHash` acceptance** from the Worker once telemetry shows zero pre-N-version heartbeats arriving (~2 weeks post-release based on prior version-adoption curves).

---

## Risks and open items

1. **Cloudflare AE subquery support.** The "installs derived from first-seen" query uses `FROM (subquery)`. AE's SQL subset is narrow (`uniq()` rejected, `INTERVAL` requires quoted strings). **Validated 2026-05-01:** AE accepts subqueries in FROM. The derived `/admin/analytics/installs?days=7` returned correct rows (`[{"day":"2026-04-25","installs":"1"},...,{"day":"2026-05-01","installs":"4"}]`) on first deploy. Two-query fallback retired.
2. **node-machine-id on Linux without systemd.** A small slice of Linux users on minimal/embedded distros may not have `/etc/machine-id`. They take the fallback-UUID path, which behaves like the legacy install_id (rotates on `~/.claude` wipe). Acceptable degradation.
3. **VM/container collisions.** Linux VMs spawned from the same disk image can share `/etc/machine-id`. Two such VMs on the same machine count as one device. Acceptable; corner case unlikely at YouCoded scale.
4. **First-seen-resets-after-90-day-silence edge case.** A device active >90 days ago but silent for >90 days will look "new" on return because all its old heartbeats aged out. Worth documenting in the `/analytics` skill comments; not worth defending against at current scale.
5. **MachineGuid regenerates on Windows reinstall.** Same machine, fresh Windows install → new hash. This is correct — a re-imaged machine arguably IS a new device — but worth noting.
6. **Salt rotation has no migration path.** If we ever change SALT, every device's hash changes, fragmenting the device count. The plan: don't rotate the salt unless we accept the fragmentation. If we ever HAVE to (compromise scenario), it'd be a deliberate "reset and start over."
7. **Privacy copy must be updated in lockstep with the Worker change.** A user who reads the AboutPopup *before* the Worker change ships sees the new copy mentioning region/state, but the Worker isn't yet writing region. Order: ship Worker first, then UI. Or accept the brief inconsistency (likely fine — copy and Worker land within minutes of each other).

---

## Appendix A: Full updated SQL query set

(Reference for implementation. Each query interpolates `${env.CUTOVER_TIMESTAMP}` and the `${adminFilterClause(env, c)}` helper output.)

```sql
-- DAU
SELECT toDate(timestamp) AS day, count(DISTINCT blob2) AS devices
FROM youcoded_app_events
WHERE blob1 = 'heartbeat'
  AND timestamp > toDateTime('${CUTOVER}')
  AND timestamp > NOW() - INTERVAL '${days}' DAY
  ${adminFilter}
GROUP BY day ORDER BY day

-- MAU
SELECT count(DISTINCT blob2) AS devices
FROM youcoded_app_events
WHERE blob1 = 'heartbeat'
  AND timestamp > toDateTime('${CUTOVER}')
  AND timestamp > NOW() - INTERVAL '30' DAY
  ${adminFilter}

-- Installs (subquery path; fallback is two-query in JS)
SELECT toDate(first_seen) AS day, count() AS installs
FROM (
  SELECT blob2, MIN(timestamp) AS first_seen
  FROM youcoded_app_events
  WHERE blob1 = 'heartbeat'
    AND timestamp > toDateTime('${CUTOVER}')
    ${adminFilter}
  GROUP BY blob2
)
WHERE first_seen > NOW() - INTERVAL '${days}' DAY
GROUP BY day ORDER BY day

-- Versions (rolling 24h)
SELECT blob3 AS version, count(DISTINCT blob2) AS devices
FROM youcoded_app_events
WHERE blob1 = 'heartbeat'
  AND timestamp > toDateTime('${CUTOVER}')
  AND timestamp > NOW() - INTERVAL '1' DAY
  ${adminFilter}
GROUP BY version ORDER BY devices DESC

-- Platforms (rolling 30d)
SELECT blob4 AS platform, count(DISTINCT blob2) AS devices
FROM youcoded_app_events
WHERE blob1 = 'heartbeat'
  AND timestamp > toDateTime('${CUTOVER}')
  AND timestamp > NOW() - INTERVAL '30' DAY
  ${adminFilter}
GROUP BY platform ORDER BY devices DESC

-- Countries (rolling 30d, top 20)
SELECT blob6 AS country, count(DISTINCT blob2) AS devices
FROM youcoded_app_events
WHERE blob1 = 'heartbeat'
  AND timestamp > toDateTime('${CUTOVER}')
  AND timestamp > NOW() - INTERVAL '30' DAY
  ${adminFilter}
GROUP BY country ORDER BY devices DESC LIMIT 20

-- Regions (rolling 30d, top 20) — NEW
SELECT blob7 AS region, count(DISTINCT blob2) AS devices
FROM youcoded_app_events
WHERE blob1 = 'heartbeat'
  AND timestamp > toDateTime('${CUTOVER}')
  AND timestamp > NOW() - INTERVAL '30' DAY
  ${adminFilter}
GROUP BY region ORDER BY devices DESC LIMIT 20
```
