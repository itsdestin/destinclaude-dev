# Device-ID Analytics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the random-UUID `install_id` with an HMAC of the device's hardware ID. Drop the `install` event, derive "new installs" from first-seen heartbeats. Add region (ISO 3166-2) via `CF-IPRegionCode`. Add a Worker-side admin filter that excludes Destin's own devices from `/admin/analytics/*` responses.

**Architecture:**
- **Client (desktop + Android):** read platform-stable machine ID, hash with `HMAC_SHA256(salt, machine_id || platform)` client-side, send only the 64-char hex hash. Fall back to a persisted UUID if the machine ID read fails.
- **Worker:** new `deviceIdHash` payload field; legacy `installId` payloads accepted but silently dropped (no AE write) during the soak window. Admin queries get `WHERE timestamp > CUTOVER AND blob2 NOT IN (KNOWN_DEV_DEVICES)` injected.
- **Hard cutover:** the `CUTOVER_TIMESTAMP` env var excludes pre-cutover (install_id-keyed) rows from every query. Old data ages out at 90 days.

**Tech Stack:** Node.js / TypeScript (Worker, desktop), Kotlin (Android), Vitest (Worker, desktop), JUnit (Android), `node-machine-id` (npm), `Settings.Secure.ANDROID_ID` (Android), Cloudflare Analytics Engine SQL, Hono (Worker routes).

**Repos touched (multi-repo plan):**
- `wecoded-marketplace/` (Worker)
- `youcoded/` (desktop + Android)
- `youcoded-admin/` (analytics skill)
- `youcoded-dev/` (no code; only the spec/plan files)

Each task says explicitly which repo it lives in.

---

## Phase 1 — Worker (wecoded-marketplace)

### Task 1: AE SQL pre-flight — validate subquery support

The spec's "installs derived from first-seen device" query uses `FROM (subquery)`. Cloudflare AE's SQL subset is narrow and has surprised us before (`uniq()` rejected, `INTERVAL` requires quoted strings). Confirm subqueries work BEFORE building the query into the route, so we can fall back to a two-query path early if not.

**Repo:** `wecoded-marketplace/`
**Files:** none — this is a discovery task.

- [ ] **Step 1: Run a probe query against the live AE API**

```bash
cd wecoded-marketplace/worker
# Pull the analytics token + account id from the worker secret env
# (or use `wrangler tail` with a temp probe route — whichever is faster).
curl -s -X POST \
  "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/analytics_engine/sql" \
  -H "Authorization: Bearer $CF_ANALYTICS_TOKEN" \
  -H "Content-Type: text/plain" \
  --data "SELECT toDate(first_seen) AS day, count() AS installs FROM (SELECT blob2, MIN(timestamp) AS first_seen FROM youcoded_app_events WHERE blob1='heartbeat' GROUP BY blob2) WHERE first_seen > NOW() - INTERVAL '7' DAY GROUP BY day ORDER BY day"
```

Expected: HTTP 200 with a `{ meta, data }` JSON body (data may be empty — that's fine, we're checking the SQL parses).

If 422 with "expected token" or similar parse error → subqueries unsupported, take the **two-query fallback** in Task 6 instead of the subquery query.

- [ ] **Step 2: Document the result inline in the spec**

Open `docs/superpowers/specs/2026-05-01-device-id-analytics-design.md` (in `youcoded-dev`). Find the "Risks and open items" section, item 1. Replace "If subqueries don't work, fallback path is two-queries-and-JS. Validate during implementation" with one of:

- `**Validated 2026-05-XX:** AE accepts subqueries in FROM. Subquery path used in implementation.`
- `**Validated 2026-05-XX:** AE returned 422 on subqueries. Two-query fallback used in implementation. Task 6 reflects this.`

- [ ] **Step 3: Commit the spec update**

```bash
cd youcoded-dev
git add docs/superpowers/specs/2026-05-01-device-id-analytics-design.md
git commit -m "spec(analytics): pin AE subquery validation result"
```

---

### Task 2: Add `CUTOVER_TIMESTAMP` and update `wrangler.toml`

We add the var BUT leave it unset for now — set after clients ship in Task 14.

**Repo:** `wecoded-marketplace/`
**Files:**
- Modify: `wecoded-marketplace/worker/wrangler.toml`

- [ ] **Step 1: Add the var to `wrangler.toml`**

Open `wecoded-marketplace/worker/wrangler.toml` and add a `[vars]` section (or merge if one already exists). Insert after the `[ai]` block, before `[env.test]`:

```toml
[vars]
# Set to the deploy timestamp of the device-id-keyed client (version N) once
# version N is the dominant client. Until then, leave empty — analytics
# queries will use a 1970 fallback so all post-deploy rows pass through.
CUTOVER_TIMESTAMP = ""
```

Also add to `[env.test.vars]`:
```toml
CUTOVER_TIMESTAMP = ""
```

- [ ] **Step 2: Update env.d.ts** to declare the new var

Open `wecoded-marketplace/worker/src/types.ts` (or `wecoded-marketplace/worker/test/env.d.ts` if that's the source of types — check both). Add `CUTOVER_TIMESTAMP: string;` to the `Env` interface. If the field is untyped today, add it explicitly.

If unsure where the Env type lives, run:
```bash
grep -n "ADMIN_USER_IDS" wecoded-marketplace/worker/src/types.ts wecoded-marketplace/worker/test/env.d.ts 2>/dev/null
```
The file containing that field is the same file you add `CUTOVER_TIMESTAMP` to.

- [ ] **Step 3: Run the worker test suite to confirm nothing broke**

```bash
cd wecoded-marketplace/worker
npm test
```

Expected: all existing tests pass. (The empty-string `CUTOVER_TIMESTAMP` is a no-op for now since we haven't wired it into queries yet.)

- [ ] **Step 4: Commit**

```bash
cd wecoded-marketplace
git add worker/wrangler.toml worker/src/types.ts worker/test/env.d.ts
git commit -m "feat(worker): add CUTOVER_TIMESTAMP env var (unset for now)"
```

---

### Task 3: Update `lib/analytics.ts` — new `deviceIdHash` field, add region, add blob7

We change the writer signature. The discriminator slot (`blob1`) stays — kept for forward compat per spec.

**Repo:** `wecoded-marketplace/`
**Files:**
- Modify: `wecoded-marketplace/worker/src/lib/analytics.ts`
- Modify: `wecoded-marketplace/worker/test/analytics-lib.test.ts`

- [ ] **Step 1: Write a failing test for the new payload shape**

Open `wecoded-marketplace/worker/test/analytics-lib.test.ts`. Add a new test case:

```ts
it("writes blob7 region when present in payload", () => {
  const writes: any[] = [];
  const env = {
    APP_ANALYTICS: { writeDataPoint: (dp: any) => writes.push(dp) },
  } as any;
  writeAppEvent(env, {
    deviceIdHash: "a".repeat(64),
    appVersion: "1.3.0",
    platform: "desktop",
    os: "mac",
    country: "US",
    region: "US-CA",
  });
  expect(writes).toHaveLength(1);
  expect(writes[0].blobs).toEqual([
    "heartbeat",
    "a".repeat(64),
    "1.3.0",
    "desktop",
    "mac",
    "US",
    "US-CA",
  ]);
});
```

- [ ] **Step 2: Run the test — expect FAIL**

```bash
cd wecoded-marketplace/worker
npm test -- test/analytics-lib.test.ts
```

Expected: FAIL on the new test (writeAppEvent doesn't accept `deviceIdHash` or `region` yet).

- [ ] **Step 3: Update `lib/analytics.ts` to the new shape**

Replace the entire file `wecoded-marketplace/worker/src/lib/analytics.ts` with:

```ts
// Privacy-by-construction wrapper around env.APP_ANALYTICS.writeDataPoint.
// Enforces the blob order that all /admin/analytics/* SQL queries assume.
// No caller outside this file should ever touch env.APP_ANALYTICS directly.
import type { Env } from "../types";

export interface AppEventPayload {
  deviceIdHash: string;       // 64-char hex (HMAC-SHA256 client-side)
  appVersion: string;
  platform: "desktop" | "android";
  os: string;                 // "win" | "mac" | "linux" for desktop; "" on android
  country: string;            // ISO 2-letter from CF-IPCountry, or ""
  region: string;             // ISO 3166-2 from CF-IPRegionCode, or ""
}

// The optional chaining is load-bearing: tests run with APP_ANALYTICS undefined
// because vitest-pool-workers can't resolve the binding. Production always has it.
export function writeAppEvent(env: Env, payload: AppEventPayload): void {
  env.APP_ANALYTICS?.writeDataPoint({
    blobs: [
      "heartbeat",            // blob1 — vestigial, retained for forward-compat
      payload.deviceIdHash,   // blob2 — semantically replaces install_id
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

The old `AppEventType` export and the `eventType` param are gone. Any caller passing `eventType` will fail at compile time — that's intentional, Task 4 fixes the only caller (`routes.ts`).

- [ ] **Step 4: Run the test — expect PASS**

```bash
npm test -- test/analytics-lib.test.ts
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd wecoded-marketplace
git add worker/src/lib/analytics.ts worker/test/analytics-lib.test.ts
git commit -m "feat(worker): analytics payload — deviceIdHash + region (blob7)"
```

---

### Task 4: Update `app/routes.ts` — accept new payload, soak both shapes

Backwards-compatible change. `parseBody` accepts EITHER `installId` (legacy UUID) OR `deviceIdHash` (new hex64). Old payloads return 200 but are NOT written to AE — silent drop.

**Repo:** `wecoded-marketplace/`
**Files:**
- Modify: `wecoded-marketplace/worker/src/app/routes.ts`
- Modify: `wecoded-marketplace/worker/test/app-routes.test.ts`

- [ ] **Step 1: Write failing tests for the new behavior**

Open `wecoded-marketplace/worker/test/app-routes.test.ts`. Replace the file's contents with:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { env } from "cloudflare:test";
import app from "../src/index";

const LEGACY_PAYLOAD = {
  installId: "c4b2a8f0-0000-4000-8000-000000000000",
  appVersion: "1.2.1",
  platform: "desktop",
  os: "mac",
};
const NEW_PAYLOAD = {
  deviceIdHash: "a".repeat(64),
  appVersion: "1.3.0",
  platform: "desktop",
  os: "mac",
};

describe("POST /app/heartbeat — new device-hash payload", () => {
  let writes: any[];
  let writeDataPoint: any;

  beforeEach(() => {
    writes = [];
    writeDataPoint = vi.fn((dp: any) => writes.push(dp));
    (env as any).APP_ANALYTICS = { writeDataPoint };
  });

  afterEach(() => {
    delete (env as any).APP_ANALYTICS;
  });

  it("accepts deviceIdHash and writes to AE", async () => {
    const res = await app.request("/app/heartbeat", {
      method: "POST",
      headers: { "Content-Type": "application/json", "CF-IPCountry": "US", "CF-IPRegionCode": "CA" },
      body: JSON.stringify(NEW_PAYLOAD),
    }, env);
    expect(res.status).toBe(200);
    expect(writes).toHaveLength(1);
    expect(writes[0].blobs[1]).toBe("a".repeat(64));
    expect(writes[0].blobs[5]).toBe("US");
    expect(writes[0].blobs[6]).toBe("CA");
  });

  it("accepts legacy installId payload but does NOT write to AE (soak drop)", async () => {
    const res = await app.request("/app/heartbeat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(LEGACY_PAYLOAD),
    }, env);
    expect(res.status).toBe(200);
    expect(writes).toHaveLength(0);
  });

  it("rejects malformed deviceIdHash (wrong length)", async () => {
    const res = await app.request("/app/heartbeat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...NEW_PAYLOAD, deviceIdHash: "abc" }),
    }, env);
    expect(res.status).toBe(400);
  });

  it("rejects payload with neither installId nor deviceIdHash", async () => {
    const res = await app.request("/app/heartbeat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ appVersion: "1.0", platform: "desktop", os: "mac" }),
    }, env);
    expect(res.status).toBe(400);
  });
});

describe("POST /app/install — deprecated, returns 410", () => {
  it("returns 410 Gone with no AE write", async () => {
    const writes: any[] = [];
    (env as any).APP_ANALYTICS = { writeDataPoint: (dp: any) => writes.push(dp) };
    const res = await app.request("/app/install", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(LEGACY_PAYLOAD),
    }, env);
    expect(res.status).toBe(410);
    expect(writes).toHaveLength(0);
    delete (env as any).APP_ANALYTICS;
  });
});
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
cd wecoded-marketplace/worker
npm test -- test/app-routes.test.ts
```

Expected: All four new tests fail. (Old `/app/install` 200 behavior + old `parseBody` regex.)

- [ ] **Step 3: Replace `wecoded-marketplace/worker/src/app/routes.ts` with the new logic**

```ts
import { Hono } from "hono";
import type { HonoEnv } from "../types";
import { badRequest, tooMany } from "../lib/errors";
import { checkRateLimit } from "../lib/rate-limit";
import { writeAppEvent } from "../lib/analytics";

export const appRoutes = new Hono<HonoEnv>();

const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const HEX_64 = /^[a-f0-9]{64}$/i;
const PLATFORMS = new Set(["desktop", "android"]);
const MAX_VERSION_LEN = 32;
const MAX_OS_LEN = 16;

interface AppEventBody {
  installId?: unknown;        // LEGACY — accepted but no AE write
  deviceIdHash?: unknown;     // NEW — required for AE write
  appVersion?: unknown;
  platform?: unknown;
  os?: unknown;
}

interface ParsedBody {
  deviceIdHash: string | null;   // null for legacy installId-only payloads
  appVersion: string;
  platform: "desktop" | "android";
  os: string;
}

// Validates the payload. Accepts either legacy `installId` (UUID) or new
// `deviceIdHash` (hex64). The discriminator: deviceIdHash is preferred when
// both are present. Legacy installId-only payloads return ParsedBody with
// deviceIdHash=null, signaling "do not write to AE."
function parseBody(body: AppEventBody): ParsedBody {
  const installId = typeof body.installId === "string" ? body.installId : "";
  const deviceIdHash = typeof body.deviceIdHash === "string" ? body.deviceIdHash : "";
  const appVersion = typeof body.appVersion === "string" ? body.appVersion : "";
  const platform = typeof body.platform === "string" ? body.platform : "";
  const os = typeof body.os === "string" ? body.os : "";

  const validInstallId = installId !== "" && UUID_V4.test(installId);
  const validDeviceHash = deviceIdHash !== "" && HEX_64.test(deviceIdHash);

  // Reject if both are present but malformed, OR neither is present, OR an
  // installId is present but malformed (catches typos in current clients).
  if (!validInstallId && !validDeviceHash) throw badRequest("invalid request");
  if (deviceIdHash !== "" && !validDeviceHash) throw badRequest("invalid request");
  if (installId !== "" && !validInstallId) throw badRequest("invalid request");

  if (!appVersion || appVersion.length > MAX_VERSION_LEN) throw badRequest("invalid request");
  if (!PLATFORMS.has(platform)) throw badRequest("invalid request");
  if (os.length > MAX_OS_LEN) throw badRequest("invalid request");

  return {
    deviceIdHash: validDeviceHash ? deviceIdHash : null,
    appVersion,
    platform: platform as "desktop" | "android",
    os,
  };
}

function clientIp(c: any): string {
  return c.req.header("CF-Connecting-IP") || c.req.header("X-Forwarded-For") || "unknown";
}

async function handleHeartbeat(c: any) {
  const ip = clientIp(c);
  if (!(await checkRateLimit(`app-heartbeat:${ip}`, 30, 3600))) {
    throw tooMany("too many requests");
  }
  const body = (await c.req.json().catch(() => ({}))) as AppEventBody;
  const parsed = parseBody(body);

  // Legacy installId-only payload: 200 OK, no AE write. Lets old clients
  // advance their lastPingedDate and stop retrying.
  if (parsed.deviceIdHash === null) {
    return c.json({ ok: true });
  }

  const country = c.req.header("CF-IPCountry") || "";
  const region = c.req.header("CF-IPRegionCode") || "";
  writeAppEvent(c.env, {
    deviceIdHash: parsed.deviceIdHash,
    appVersion: parsed.appVersion,
    platform: parsed.platform,
    os: parsed.os,
    country,
    region,
  });
  return c.json({ ok: true });
}

// POST /app/heartbeat — fired at most once/day per device.
appRoutes.post("/app/heartbeat", handleHeartbeat);

// POST /app/install — DEPRECATED. Returns 410 Gone. Legacy clients still
// post here; the response body says nothing (clients fire-and-forget),
// they just stop expecting an "ok" and never advance state. They WILL
// keep retrying once per launch, but the rate limit + 410 keeps it cheap.
appRoutes.post("/app/install", (c) => c.json({ deprecated: true }, 410));
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
npm test -- test/app-routes.test.ts
```

Expected: All four new tests pass.

- [ ] **Step 5: Run the full worker test suite**

```bash
npm test
```

Expected: all tests pass. (Other tests don't depend on the install route or the legacy payload shape.)

- [ ] **Step 6: Commit**

```bash
cd wecoded-marketplace
git add worker/src/app/routes.ts worker/test/app-routes.test.ts
git commit -m "feat(worker): heartbeat accepts deviceIdHash; deprecate /app/install (410)"
```

---

### Task 5: Add `lib/admin-filter.ts` helper

The `adminFilterClause()` function is shared across every admin analytics endpoint. Extracting it now keeps the SQL-injection-safe sanitizer in one place.

**Repo:** `wecoded-marketplace/`
**Files:**
- Create: `wecoded-marketplace/worker/src/lib/admin-filter.ts`
- Create: `wecoded-marketplace/worker/test/admin-filter.test.ts`

- [ ] **Step 1: Write failing tests**

Create `wecoded-marketplace/worker/test/admin-filter.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { adminFilterClause, cutoverClause } from "../src/lib/admin-filter";

describe("adminFilterClause", () => {
  it("returns empty string when KNOWN_DEV_DEVICES is unset", () => {
    expect(adminFilterClause({ KNOWN_DEV_DEVICES: "" } as any, false)).toBe("");
    expect(adminFilterClause({ KNOWN_DEV_DEVICES: undefined } as any, false)).toBe("");
  });

  it("returns empty string when include_admins=true", () => {
    expect(adminFilterClause({ KNOWN_DEV_DEVICES: "a".repeat(64) } as any, true)).toBe("");
  });

  it("returns NOT IN clause for valid 64-hex hashes", () => {
    const env = {
      KNOWN_DEV_DEVICES: `${"a".repeat(64)},${"b".repeat(64)}`,
    } as any;
    const clause = adminFilterClause(env, false);
    expect(clause).toBe(`AND blob2 NOT IN ('${"a".repeat(64)}','${"b".repeat(64)}')`);
  });

  it("strips non-hex characters defensively", () => {
    const env = {
      KNOWN_DEV_DEVICES: `${"a".repeat(64)}'); DROP TABLE--`,
    } as any;
    const clause = adminFilterClause(env, false);
    // The injection attempt is reduced to hex chars only; the dropped string
    // becomes a < 64-char hash and is rejected by the length filter.
    expect(clause).toBe(`AND blob2 NOT IN ('${"a".repeat(64)}')`);
  });

  it("rejects hashes that aren't exactly 64 hex chars", () => {
    const env = {
      KNOWN_DEV_DEVICES: `short,${"a".repeat(64)},${"b".repeat(63)}`,
    } as any;
    const clause = adminFilterClause(env, false);
    expect(clause).toBe(`AND blob2 NOT IN ('${"a".repeat(64)}')`);
  });
});

describe("cutoverClause", () => {
  it("returns empty when CUTOVER_TIMESTAMP is unset", () => {
    expect(cutoverClause({ CUTOVER_TIMESTAMP: "" } as any)).toBe("");
    expect(cutoverClause({ CUTOVER_TIMESTAMP: undefined } as any)).toBe("");
  });

  it("returns AND clause when set", () => {
    expect(cutoverClause({ CUTOVER_TIMESTAMP: "2026-05-15T00:00:00Z" } as any))
      .toBe("AND timestamp > toDateTime('2026-05-15T00:00:00Z')");
  });

  it("strips characters that would break SQL string quoting", () => {
    // ISO 8601 chars only: digits, T, Z, :, -. Apostrophes and other risky
    // chars get filtered.
    expect(cutoverClause({ CUTOVER_TIMESTAMP: "2026-05-15'); DROP--" } as any))
      .toBe("AND timestamp > toDateTime('2026-05-15')");
  });
});
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
cd wecoded-marketplace/worker
npm test -- test/admin-filter.test.ts
```

Expected: All fail (file doesn't exist yet).

- [ ] **Step 3: Create the helper**

Create `wecoded-marketplace/worker/src/lib/admin-filter.ts`:

```ts
// SQL fragment helpers for admin analytics queries. Both helpers return
// strings that are safe to interpolate into a SQL query because they
// strictly sanitize the values they pull from env vars.
//
// Why strings, not parameterized queries: Cloudflare's AE SQL endpoint
// takes raw text/plain SQL; there's no parameter binding API.
import type { Env } from "../types";

// Returns "AND blob2 NOT IN ('hash1','hash2',...)" or "" if filter disabled.
// Hex-only sanitization is mandatory — these strings get string-interpolated
// into SQL. Hashes with any non-hex char are filtered to hex-only, then
// dropped if the cleaned length isn't exactly 64.
export function adminFilterClause(env: Env, includeAdmins: boolean): string {
  if (includeAdmins) return "";
  const raw = env.KNOWN_DEV_DEVICES ?? "";
  if (!raw) return "";
  const hashes = raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((h) => h.replace(/[^a-f0-9]/gi, "").toLowerCase())
    .filter((h) => h.length === 64)
    .map((h) => `'${h}'`);
  if (!hashes.length) return "";
  return `AND blob2 NOT IN (${hashes.join(",")})`;
}

// Returns "AND timestamp > toDateTime('<iso>')" or "" if cutover disabled.
// The timestamp string is sanitized to ISO 8601 charset only (digits, T, Z,
// :, -, .) — anything else (apostrophes, semicolons, etc.) is stripped.
export function cutoverClause(env: Env): string {
  const raw = env.CUTOVER_TIMESTAMP ?? "";
  if (!raw) return "";
  const cleaned = raw.replace(/[^0-9TZ:.\-]/g, "");
  if (!cleaned) return "";
  return `AND timestamp > toDateTime('${cleaned}')`;
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
npm test -- test/admin-filter.test.ts
```

Expected: All eight assertions pass.

- [ ] **Step 5: Commit**

```bash
cd wecoded-marketplace
git add worker/src/lib/admin-filter.ts worker/test/admin-filter.test.ts
git commit -m "feat(worker): admin-filter helpers — KNOWN_DEV_DEVICES + CUTOVER_TIMESTAMP"
```

---

### Task 6: Update `admin/analytics.ts` — column rename, cutover, admin filter, regions endpoint, derived installs

This is the largest single change. We rewrite all six existing routes and add the seventh (regions).

**Repo:** `wecoded-marketplace/`
**Files:**
- Modify: `wecoded-marketplace/worker/src/admin/analytics.ts`
- Modify: `wecoded-marketplace/worker/test/admin-analytics.test.ts`

- [ ] **Step 1: Write failing tests for the new shape**

Open `wecoded-marketplace/worker/test/admin-analytics.test.ts`. Replace existing `dau`/`mau` describes with versions that assert the new column name and SQL fragments. Add new describes for `regions` and the admin filter behavior.

Use this structure (consolidate by topic; full file rewrite):

```ts
import { env, SELF } from "cloudflare:test";
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

async function seedAdmin(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  await env.DB.prepare("INSERT INTO users (id, github_login, created_at) VALUES (?, ?, ?)")
    .bind("github:admin", "admin", now).run();
  const token = "tok-admin";
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest(
    "SHA-256", new TextEncoder().encode(token))))
    .map(b => b.toString(16).padStart(2, "0")).join("");
  await env.DB.prepare("INSERT INTO sessions (token_hash, user_id, created_at, last_used_at) VALUES (?, ?, ?, ?)")
    .bind(hash, "github:admin", now, now).run();
  return token;
}

function mockCfSql(rows: unknown[]) {
  globalThis.fetch = vi.fn(async () =>
    new Response(JSON.stringify({ meta: [], data: rows }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    })
  ) as any;
}

const origFetch = globalThis.fetch;

async function clearAuth() {
  for (const t of ["sessions", "users"]) {
    await env.DB.prepare(`DELETE FROM ${t}`).run();
  }
}

describe("GET /admin/analytics/dau", () => {
  beforeEach(async () => { await clearAuth(); mockCfSql([{ day: "2026-05-15", devices: 5 }]); });
  afterEach(() => { globalThis.fetch = origFetch; });

  it("returns 401 without auth", async () => {
    const res = await SELF.fetch("https://test.local/admin/analytics/dau");
    expect(res.status).toBe(401);
  });

  it("returns 'devices' column for an admin", async () => {
    const token = await seedAdmin();
    const res = await SELF.fetch("https://test.local/admin/analytics/dau", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const body = await res.json<Array<{ day: string; devices: number }>>();
    expect(body).toEqual([{ day: "2026-05-15", devices: 5 }]);
    const sql = (globalThis.fetch as any).mock.calls[0][1].body as string;
    expect(sql).toContain("count(DISTINCT blob2) AS devices");
  });

  it("includes cutover clause when CUTOVER_TIMESTAMP is set", async () => {
    (env as any).CUTOVER_TIMESTAMP = "2026-05-15T00:00:00Z";
    const token = await seedAdmin();
    await SELF.fetch("https://test.local/admin/analytics/dau", {
      headers: { Authorization: `Bearer ${token}` },
    });
    const sql = (globalThis.fetch as any).mock.calls[0][1].body as string;
    expect(sql).toContain("toDateTime('2026-05-15T00:00:00Z')");
    delete (env as any).CUTOVER_TIMESTAMP;
  });

  it("includes admin filter when KNOWN_DEV_DEVICES is set", async () => {
    (env as any).KNOWN_DEV_DEVICES = `${"a".repeat(64)},${"b".repeat(64)}`;
    const token = await seedAdmin();
    await SELF.fetch("https://test.local/admin/analytics/dau", {
      headers: { Authorization: `Bearer ${token}` },
    });
    const sql = (globalThis.fetch as any).mock.calls[0][1].body as string;
    expect(sql).toContain(`AND blob2 NOT IN ('${"a".repeat(64)}','${"b".repeat(64)}')`);
    delete (env as any).KNOWN_DEV_DEVICES;
  });

  it("?include_admins=1 omits the admin filter", async () => {
    (env as any).KNOWN_DEV_DEVICES = "a".repeat(64);
    const token = await seedAdmin();
    await SELF.fetch("https://test.local/admin/analytics/dau?include_admins=1", {
      headers: { Authorization: `Bearer ${token}` },
    });
    const sql = (globalThis.fetch as any).mock.calls[0][1].body as string;
    expect(sql).not.toContain("NOT IN");
    delete (env as any).KNOWN_DEV_DEVICES;
  });
});

describe("GET /admin/analytics/regions", () => {
  beforeEach(async () => {
    await clearAuth();
    mockCfSql([
      { region: "US-CA", devices: 5 },
      { region: "US-TX", devices: 3 },
    ]);
  });
  afterEach(() => { globalThis.fetch = origFetch; });

  it("returns top regions for an admin", async () => {
    const token = await seedAdmin();
    const res = await SELF.fetch("https://test.local/admin/analytics/regions", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const body = await res.json<Array<{ region: string; devices: number }>>();
    expect(body).toEqual([
      { region: "US-CA", devices: 5 },
      { region: "US-TX", devices: 3 },
    ]);
    const sql = (globalThis.fetch as any).mock.calls[0][1].body as string;
    expect(sql).toContain("blob7 AS region");
    expect(sql).toContain("LIMIT 20");
  });

  it("returns 401 without auth", async () => {
    const res = await SELF.fetch("https://test.local/admin/analytics/regions");
    expect(res.status).toBe(401);
  });
});

describe("GET /admin/analytics/installs (derived from first-seen)", () => {
  beforeEach(async () => {
    await clearAuth();
    mockCfSql([{ day: "2026-05-15", installs: 7 }]);
  });
  afterEach(() => { globalThis.fetch = origFetch; });

  it("returns derived first-seen counts for an admin", async () => {
    const token = await seedAdmin();
    const res = await SELF.fetch("https://test.local/admin/analytics/installs?days=7", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const body = await res.json<Array<{ day: string; installs: number }>>();
    expect(body).toEqual([{ day: "2026-05-15", installs: 7 }]);
    const sql = (globalThis.fetch as any).mock.calls[0][1].body as string;
    expect(sql).toContain("MIN(timestamp) AS first_seen");
  });
});
```

The other endpoints (mau, versions, platforms, countries) follow the same pattern as `dau` — but for brevity, you only need parity tests on one of them in addition to dau. The "column rename + cutover + admin filter" test on dau implicitly proves the helpers work; the per-endpoint tests just confirm the right SQL shape per endpoint. Add a single sanity test per endpoint asserting the `'devices'` column name appears in the SQL.

- [ ] **Step 2: Run tests — expect FAIL**

```bash
npm test -- test/admin-analytics.test.ts
```

Expected: most tests fail. (Old code returns `users` column, has no cutover clause, no filter, no regions endpoint.)

- [ ] **Step 3: Replace `wecoded-marketplace/worker/src/admin/analytics.ts`**

Replace the entire file with:

```ts
// Privacy-by-construction contract: every query in this file aggregates
// device_id (blob2) via count(DISTINCT) or omits it from SELECT entirely.
// Raw device_id_hashes never leave the Worker — don't add a route that
// returns them, even for debugging.
//
// SQL dialect: Cloudflare Analytics Engine uses a narrow SQL subset — NOT
// full ClickHouse. Quirks learned the hard way (422 responses):
// - Cardinality is `count(DISTINCT col)`. ClickHouse's `uniq()` is rejected.
// - `INTERVAL '30' DAY` — count must be a QUOTED STRING LITERAL.
// - `count()` alone works; use `count(DISTINCT col)` for cardinality.
// See: https://developers.cloudflare.com/analytics/analytics-engine/sql-reference/
import { Hono } from "hono";
import type { HonoEnv } from "../types";
import { requireAdminAuth } from "../auth/admin-middleware";
import { forbidden } from "../lib/errors";
import { runAnalyticsQuery } from "../lib/analytics-query";
import { adminFilterClause, cutoverClause } from "../lib/admin-filter";

function isAdmin(env: { ADMIN_USER_IDS: string }, userId: string): boolean {
  const admins = env.ADMIN_USER_IDS.split(",").map((s) => s.trim()).filter(Boolean);
  return admins.includes(userId);
}

function clampDays(raw: string | undefined, fallback: number): number {
  const n = Number(raw ?? fallback);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(1, Math.min(90, Math.floor(n)));
}

function includeAdmins(query: string | undefined): boolean {
  return query === "1";
}

export const adminAnalyticsRoutes = new Hono<HonoEnv>();

// GET /admin/analytics/dau?days=30 — devices active per day for the last N days.
adminAnalyticsRoutes.get("/admin/analytics/dau", requireAdminAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const days = clampDays(c.req.query("days"), 30);
  const cutover = cutoverClause(c.env);
  const filter = adminFilterClause(c.env, includeAdmins(c.req.query("include_admins")));
  const rows = await runAnalyticsQuery<{ day: string; devices: number }>(
    c.env,
    `SELECT toDate(timestamp) AS day, count(DISTINCT blob2) AS devices
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' ${cutover} AND timestamp > NOW() - INTERVAL '${days}' DAY ${filter}
     GROUP BY day ORDER BY day`
  );
  return c.json(rows);
});

// GET /admin/analytics/mau — rolling 30-day distinct devices.
adminAnalyticsRoutes.get("/admin/analytics/mau", requireAdminAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const cutover = cutoverClause(c.env);
  const filter = adminFilterClause(c.env, includeAdmins(c.req.query("include_admins")));
  const rows = await runAnalyticsQuery<{ devices: number }>(
    c.env,
    `SELECT count(DISTINCT blob2) AS devices
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' ${cutover} AND timestamp > NOW() - INTERVAL '30' DAY ${filter}`
  );
  return c.json({ mau: rows[0]?.devices ?? 0 });
});

// GET /admin/analytics/installs?days=N — derived from first-seen device per day.
//
// Subquery support in AE SQL was validated in plan Task 1. If the validation
// concluded subqueries are NOT supported, replace the SELECT below with a
// two-query JS path: fetch (blob2, MIN(timestamp)) rows, group by day in JS.
adminAnalyticsRoutes.get("/admin/analytics/installs", requireAdminAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const days = clampDays(c.req.query("days"), 90);
  const cutover = cutoverClause(c.env);
  const filter = adminFilterClause(c.env, includeAdmins(c.req.query("include_admins")));
  const rows = await runAnalyticsQuery<{ day: string; installs: number }>(
    c.env,
    `SELECT toDate(first_seen) AS day, count() AS installs
     FROM (
       SELECT blob2, MIN(timestamp) AS first_seen
       FROM youcoded_app_events
       WHERE blob1 = 'heartbeat' ${cutover} ${filter}
       GROUP BY blob2
     )
     WHERE first_seen > NOW() - INTERVAL '${days}' DAY
     GROUP BY day ORDER BY day`
  );
  return c.json(rows);
});

// GET /admin/analytics/versions — rolling 24h devices by version.
adminAnalyticsRoutes.get("/admin/analytics/versions", requireAdminAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const cutover = cutoverClause(c.env);
  const filter = adminFilterClause(c.env, includeAdmins(c.req.query("include_admins")));
  const rows = await runAnalyticsQuery<{ version: string; devices: number }>(
    c.env,
    `SELECT blob3 AS version, count(DISTINCT blob2) AS devices
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' ${cutover} AND timestamp > NOW() - INTERVAL '1' DAY ${filter}
     GROUP BY version ORDER BY devices DESC`
  );
  return c.json(rows);
});

// GET /admin/analytics/platforms — rolling 30-day split.
adminAnalyticsRoutes.get("/admin/analytics/platforms", requireAdminAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const cutover = cutoverClause(c.env);
  const filter = adminFilterClause(c.env, includeAdmins(c.req.query("include_admins")));
  const rows = await runAnalyticsQuery<{ platform: string; devices: number }>(
    c.env,
    `SELECT blob4 AS platform, count(DISTINCT blob2) AS devices
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' ${cutover} AND timestamp > NOW() - INTERVAL '30' DAY ${filter}
     GROUP BY platform ORDER BY devices DESC`
  );
  return c.json(rows);
});

// GET /admin/analytics/countries — rolling 30-day top 20.
adminAnalyticsRoutes.get("/admin/analytics/countries", requireAdminAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const cutover = cutoverClause(c.env);
  const filter = adminFilterClause(c.env, includeAdmins(c.req.query("include_admins")));
  const rows = await runAnalyticsQuery<{ country: string; devices: number }>(
    c.env,
    `SELECT blob6 AS country, count(DISTINCT blob2) AS devices
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' ${cutover} AND timestamp > NOW() - INTERVAL '30' DAY ${filter}
     GROUP BY country ORDER BY devices DESC LIMIT 20`
  );
  return c.json(rows);
});

// GET /admin/analytics/regions — rolling 30-day top 20 ISO 3166-2 regions. NEW.
adminAnalyticsRoutes.get("/admin/analytics/regions", requireAdminAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const cutover = cutoverClause(c.env);
  const filter = adminFilterClause(c.env, includeAdmins(c.req.query("include_admins")));
  const rows = await runAnalyticsQuery<{ region: string; devices: number }>(
    c.env,
    `SELECT blob7 AS region, count(DISTINCT blob2) AS devices
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' ${cutover} AND timestamp > NOW() - INTERVAL '30' DAY ${filter}
     GROUP BY region ORDER BY devices DESC LIMIT 20`
  );
  return c.json(rows);
});
```

If Task 1 concluded subqueries aren't supported, replace the `installs` route with this two-query body:

```ts
adminAnalyticsRoutes.get("/admin/analytics/installs", requireAdminAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const days = clampDays(c.req.query("days"), 90);
  const cutover = cutoverClause(c.env);
  const filter = adminFilterClause(c.env, includeAdmins(c.req.query("include_admins")));
  const rows = await runAnalyticsQuery<{ device: string; first_seen: string }>(
    c.env,
    `SELECT blob2 AS device, MIN(timestamp) AS first_seen
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' ${cutover} ${filter}
     GROUP BY device`
  );
  const cutoffMs = Date.now() - days * 86_400_000;
  const counts = new Map<string, number>();
  for (const r of rows) {
    const t = Date.parse(r.first_seen);
    if (Number.isNaN(t) || t < cutoffMs) continue;
    const day = new Date(t).toISOString().slice(0, 10);
    counts.set(day, (counts.get(day) ?? 0) + 1);
  }
  const result = [...counts.entries()]
    .map(([day, installs]) => ({ day, installs }))
    .sort((a, b) => a.day.localeCompare(b.day));
  return c.json(result);
});
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
npm test -- test/admin-analytics.test.ts
```

Expected: all tests pass.

- [ ] **Step 5: Run the full worker test suite**

```bash
npm test
```

Expected: all tests pass. (No other suites depend on these endpoints' shapes.)

- [ ] **Step 6: Commit**

```bash
cd wecoded-marketplace
git add worker/src/admin/analytics.ts worker/test/admin-analytics.test.ts
git commit -m "feat(worker): admin analytics — devices column, cutover, admin filter, /regions"
```

---

### Task 7: Deploy Worker

The Worker change is backward-compatible (legacy installId payloads still get 200; new deviceIdHash payloads work). Safe to deploy alone.

- [ ] **Step 1: Deploy the Worker**

```bash
cd wecoded-marketplace/worker
npx wrangler deploy
```

Expected: deploy succeeds, prints the worker URL.

- [ ] **Step 2: Smoke-test the deployed routes**

```bash
# Heartbeat with a fake new payload — expect 200 and (if APP_ANALYTICS configured) an AE write
curl -s -X POST https://wecoded-marketplace-api.destinj101.workers.dev/app/heartbeat \
  -H "Content-Type: application/json" \
  -d '{"deviceIdHash":"'"$(node -e 'console.log("a".repeat(64))')"'","appVersion":"1.3.0-test","platform":"desktop","os":"mac"}'
# Expect: {"ok":true}

# /app/install — expect 410
curl -s -X POST https://wecoded-marketplace-api.destinj101.workers.dev/app/install \
  -H "Content-Type: application/json" \
  -d '{"installId":"c4b2a8f0-0000-4000-8000-000000000000","appVersion":"1.0","platform":"desktop","os":"mac"}' \
  -o /dev/null -w "%{http_code}\n"
# Expect: 410
```

- [ ] **Step 3: Validate /admin/analytics/regions reachable**

```bash
# Auth via gh PAT — same as /analytics skill
gh_token=$(gh auth token)
curl -s https://wecoded-marketplace-api.destinj101.workers.dev/admin/analytics/regions \
  -H "X-GitHub-PAT: $gh_token"
# Expect: [] (no rows yet) or sample data if any heartbeats received
```

If 422 from the AE SQL endpoint with "unknown function" or similar, revisit Task 6 — likely a SQL dialect issue.

- [ ] **Step 4: No commit** — deploy is the deliverable. Worker phase complete.

---

## Phase 2 — Desktop client (youcoded)

### Task 8: Add `node-machine-id` dependency

**Repo:** `youcoded/`
**Files:**
- Modify: `youcoded/desktop/package.json`
- Modify: `youcoded/desktop/package-lock.json`

- [ ] **Step 1: Install the dep**

```bash
cd youcoded/desktop
npm install node-machine-id
```

Expected: lockfile updated, no peer warnings.

- [ ] **Step 2: Verify it loads in Node**

```bash
node -e "console.log(require('node-machine-id').machineIdSync())"
```

Expected: a hex/UUID string. (E.g., `00000000-0000-0000-0000-...` on macOS, a 32-hex-char registry value on Windows.)

- [ ] **Step 3: Commit**

```bash
cd youcoded
git add desktop/package.json desktop/package-lock.json
git commit -m "feat(desktop): add node-machine-id for stable device hashing"
```

---

### Task 9: Generate the SALT and write to a shared constants file

The salt is a 32-byte hex string baked into both desktop and Android source. Single source of truth: a shared file (`shared/analytics-salt.ts` for desktop, `app/.../analytics/Salt.kt` for Android — different files, same value).

**Repo:** `youcoded/`
**Files:**
- Create: `youcoded/desktop/src/main/analytics-salt.ts`

- [ ] **Step 1: Generate a salt**

```bash
cd youcoded
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Output: a 64-char hex string. Copy it. (The same string goes into Android in Task 12.)

- [ ] **Step 2: Create the constants file**

Create `youcoded/desktop/src/main/analytics-salt.ts` with the generated salt:

```ts
// Static salt for HMAC-SHA256 over the device's machine_id + platform.
// Baked into the source by design — see docs/superpowers/specs/2026-05-01-device-id-analytics-design.md
// "Threat model" for why decompile-resistance is not a goal.
//
// MUST match Android's Salt.kt. Changing this value re-hashes every device,
// fragmenting all device-counted metrics. Do not rotate without intent.
export const ANALYTICS_SALT = "<paste the hex string from step 1 here>";
```

Replace `<paste the hex string from step 1 here>` with the actual generated string.

- [ ] **Step 3: Commit**

```bash
cd youcoded
git add desktop/src/main/analytics-salt.ts
git commit -m "feat(desktop): pin analytics SALT for device-hash HMAC"
```

---

### Task 10: Rewrite `analytics-service.ts` with hashed device ID

**Repo:** `youcoded/`
**Files:**
- Modify: `youcoded/desktop/src/main/analytics-service.ts`
- Modify: `youcoded/desktop/src/main/analytics-service.test.ts`

- [ ] **Step 1: Replace tests with the new behavior**

Replace `youcoded/desktop/src/main/analytics-service.test.ts` with:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

vi.mock("electron", () => ({ app: { getVersion: () => "9.9.9" } }));

const STATE_FILE = path.join(os.homedir(), ".claude", "youcoded-analytics.json");

describe("analytics-service.runAnalyticsOnLaunch", () => {
  const origFetch = globalThis.fetch;

  beforeEach(() => {
    try { fs.unlinkSync(STATE_FILE); } catch {}
    vi.doMock("node-machine-id", () => ({
      machineIdSync: () => "test-machine-id-stable",
    }));
    globalThis.fetch = vi.fn(async () =>
      new Response(JSON.stringify({ ok: true }), { status: 200 })
    ) as any;
  });

  afterEach(() => {
    globalThis.fetch = origFetch;
    try { fs.unlinkSync(STATE_FILE); } catch {}
    vi.doUnmock("node-machine-id");
  });

  async function importFresh() {
    vi.resetModules();
    return (await import("./analytics-service")) as typeof import("./analytics-service");
  }

  it("first launch: posts ONE heartbeat with deviceIdHash, saves lastPingedDate", async () => {
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    const calls = (globalThis.fetch as any).mock.calls;
    expect(calls).toHaveLength(1);
    const url = calls[0][0] as string;
    const body = JSON.parse(calls[0][1].body as string);
    expect(url).toMatch(/\/app\/heartbeat$/);
    expect(body.deviceIdHash).toMatch(/^[a-f0-9]{64}$/);
    expect(body.installId).toBeUndefined();
    expect(body.appVersion).toBe("9.9.9");
    expect(body.platform).toBe("desktop");
    const state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
    expect(state.lastPingedDate).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(state.installId).toBeUndefined();
    expect(state.fallbackDeviceId).toBeUndefined();  // machine-id read succeeded
  });

  it("does NOT post /app/install (event was retired)", async () => {
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    const calls = (globalThis.fetch as any).mock.calls.map((c: any[]) => c[0] as string);
    expect(calls.some((u) => u.endsWith("/app/install"))).toBe(false);
  });

  it("second launch same day: no posts", async () => {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify({
      optIn: true,
      lastPingedDate: new Date().toISOString().slice(0, 10),
    }));
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it("opt-out: zero network calls", async () => {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify({
      optIn: false,
      lastPingedDate: "",
    }));
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it("network failure: state.lastPingedDate not advanced", async () => {
    globalThis.fetch = vi.fn(async () => { throw new Error("net"); }) as any;
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    const state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
    expect(state.lastPingedDate ?? "").toBe("");
  });

  it("machine-id read failure: persists fallbackDeviceId, hashes prefixed string", async () => {
    vi.doMock("node-machine-id", () => ({
      machineIdSync: () => { throw new Error("no /etc/machine-id"); },
    }));
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    const state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
    expect(state.fallbackDeviceId).toMatch(/^[0-9a-f-]{36}$/i);
    const body = JSON.parse((globalThis.fetch as any).mock.calls[0][1].body);
    expect(body.deviceIdHash).toMatch(/^[a-f0-9]{64}$/);
  });

  it("legacy installId/installReported in state file: silently dropped", async () => {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify({
      installId: "c4b2a8f0-0000-4000-8000-000000000000",
      installReported: true,
      optIn: true,
      lastPingedDate: "1970-01-01",
    }));
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    const state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
    expect(state.installId).toBeUndefined();
    expect(state.installReported).toBeUndefined();
    expect(state.optIn).toBe(true);
  });
});
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
cd youcoded/desktop
npm test -- src/main/analytics-service.test.ts
```

Expected: most fail (current service still posts /install + uses installId).

- [ ] **Step 3: Replace `analytics-service.ts`**

Replace `youcoded/desktop/src/main/analytics-service.ts` with:

```ts
// Sends one /app/heartbeat per UTC day, gated by an opt-out toggle.
// Identity is HMAC_SHA256(SALT, machine_id || platform), computed
// client-side. Fire-and-forget — any failure is swallowed and retried
// next launch. Zero behavioral impact if the network is unreachable.
//
// Privacy: the raw machine_id never leaves the device. See the design
// spec at docs/superpowers/specs/2026-05-01-device-id-analytics-design.md
// for the threat model.
import { app } from "electron";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { randomUUID, createHmac } from "node:crypto";
import { machineIdSync } from "node-machine-id";
import { ANALYTICS_SALT } from "./analytics-salt";

const API_BASE = "https://wecoded-marketplace-api.destinj101.workers.dev";
const ANALYTICS_FILE = path.join(os.homedir(), ".claude", "youcoded-analytics.json");

interface AnalyticsState {
  optIn: boolean;
  lastPingedDate: string;       // YYYY-MM-DD UTC, or "" when never pinged
  fallbackDeviceId?: string;    // present only if machine_id read failed
}

function defaultState(): AnalyticsState {
  return { optIn: true, lastPingedDate: "" };
}

function mapOs(platform: NodeJS.Platform): string {
  if (platform === "win32") return "win";
  if (platform === "darwin") return "mac";
  if (platform === "linux") return "linux";
  return "";
}

function todayUtc(): string {
  return new Date().toISOString().slice(0, 10);
}

function readState(): AnalyticsState {
  try {
    const raw = fs.readFileSync(ANALYTICS_FILE, "utf8");
    const parsed = JSON.parse(raw) as Partial<AnalyticsState> & {
      installId?: string;
      installReported?: boolean;
    };
    // Drop legacy fields silently.
    return {
      optIn: typeof parsed.optIn === "boolean" ? parsed.optIn : true,
      lastPingedDate: typeof parsed.lastPingedDate === "string" ? parsed.lastPingedDate : "",
      fallbackDeviceId: typeof parsed.fallbackDeviceId === "string" ? parsed.fallbackDeviceId : undefined,
    };
  } catch {
    return defaultState();
  }
}

function writeState(state: AnalyticsState): void {
  fs.mkdirSync(path.dirname(ANALYTICS_FILE), { recursive: true });
  fs.writeFileSync(ANALYTICS_FILE, JSON.stringify(state, null, 2));
}

export function getOptIn(): boolean {
  return readState().optIn;
}

export function setOptIn(value: boolean): void {
  const state = readState();
  state.optIn = value;
  writeState(state);
}

// Computes the device-id hash. Mutates `state.fallbackDeviceId` and persists
// it if the machine_id read fails (and a fallback isn't already saved).
export function deviceIdHash(state: AnalyticsState): string {
  let raw = "";
  try {
    raw = machineIdSync({ original: true });
  } catch {
    // swallowed — caught by the length check below
  }
  if (!raw || raw.length < 8) {
    if (!state.fallbackDeviceId) {
      state.fallbackDeviceId = randomUUID();
      writeState(state);
    }
    raw = `fallback:${state.fallbackDeviceId}`;
  }
  return createHmac("sha256", ANALYTICS_SALT)
    .update(`${raw}|${process.platform}`)
    .digest("hex");
}

async function postEvent(path: string, body: unknown): Promise<boolean> {
  try {
    const res = await fetch(`${API_BASE}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return res.ok;
  } catch {
    return false;
  }
}

export async function runAnalyticsOnLaunch(): Promise<void> {
  const state = readState();
  if (!state.optIn) return;

  const today = todayUtc();
  if (state.lastPingedDate === today) return;

  const hash = deviceIdHash(state);

  const ok = await postEvent("/app/heartbeat", {
    deviceIdHash: hash,
    appVersion: app.getVersion(),
    platform: "desktop" as const,
    os: mapOs(process.platform),
  });
  if (ok) {
    state.lastPingedDate = today;
    writeState(state);
  }
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
npm test -- src/main/analytics-service.test.ts
```

Expected: all 7 tests pass.

- [ ] **Step 5: Run the full desktop test suite**

```bash
npm test
```

Expected: pass. (Other tests don't import this module's internals.)

- [ ] **Step 6: Verify desktop still builds**

```bash
npm run build
```

Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
cd youcoded
git add desktop/src/main/analytics-service.ts desktop/src/main/analytics-service.test.ts
git commit -m "feat(desktop): hashed deviceIdHash analytics, drop install POST"
```

---

### Task 11: Update privacy copy (AboutPopup, landing page, PITFALLS)

The spec lists three sites where analytics privacy text appears: in-app (`AboutPopup.tsx`), landing page (`wecoded-marketplace/landing/`), and architectural docs (`docs/PITFALLS.md` analytics section). All three change in lockstep.

**Repos:** `youcoded/`, `wecoded-marketplace/`, `youcoded-dev/`

- [ ] **Step 1: Find every site that mentions analytics**

```bash
cd youcoded-dev
# In-app copy
grep -n "anonymous analytics data\|anonymous usage\|install_id\|UUID" \
  youcoded/desktop/src/renderer/components/AboutPopup.tsx

# Landing page (search whole landing dir)
grep -rn "anonymous analytics\|anonymous usage\|install_id\|hash of\|device" \
  wecoded-marketplace/landing/ 2>/dev/null

# Architectural docs
grep -n "install_id\|writeAppEvent\|youcoded_app_events\|blob2" \
  docs/PITFALLS.md
```

Note the line numbers from each. There are typically two copies in `AboutPopup.tsx` (terse + expanded). Landing page may be one or more `.md`/`.html`/`.astro` files.

- [ ] **Step 2: Update `AboutPopup.tsx`**

Open `youcoded/desktop/src/renderer/components/AboutPopup.tsx`. Find each block that describes the analytics data fields. Replace each block's body with this list (preserve whatever JSX wrapping is already there — `<ul>`/`<p>`/etc. — just substitute the substantive text):

```
By default, your device may send anonymous usage data to YouCoded once per day:
- An irreversible hash of your device's hardware ID (the raw ID never leaves your device)
- The app version, platform (desktop/android), and OS family
- Your country and approximate region (e.g., US state), derived from your IP address by Cloudflare. IP addresses are never stored.

No message content, no usernames, no tokens, no file paths. You can disable this in Settings → Privacy at any time.
```

- [ ] **Step 3: Verify desktop build**

```bash
cd youcoded/desktop
npm run build
```

Expected: build succeeds.

- [ ] **Step 4: Commit the desktop change**

```bash
cd youcoded
git add desktop/src/renderer/components/AboutPopup.tsx
git commit -m "docs(desktop): privacy copy — device hash + region"
```

- [ ] **Step 5: Update landing-page privacy copy**

For each file the step-1 grep matched in `wecoded-marketplace/landing/`, replace the analytics-data description with the same list as in step 2 (adapted to the file's markup — Markdown, HTML, MDX, or whatever the landing uses).

If the landing page has a "Privacy" or "Analytics" FAQ entry with a longer explanation, expand the list with the legal-comfort sentence:

> The hash is computed using HMAC-SHA256 with a static key built into the app — it can't be reversed back to your hardware ID. We use it to deduplicate the same device across reinstalls without ever storing anything that identifies your machine.

- [ ] **Step 6: Commit the landing-page change**

```bash
cd wecoded-marketplace
git add landing/
git commit -m "docs(landing): privacy copy — device hash + region"
```

- [ ] **Step 7: Update `docs/PITFALLS.md` analytics section**

Open `youcoded-dev/docs/PITFALLS.md` and find the "## Analytics" section. The current section describes `install_id`-as-blob2, two event types, and country-only geography. Update it to reflect the new reality:

- `blob2` is now `device_id_hash` (HMAC-SHA256 client-side), not `install_id`.
- Only one event type now (`heartbeat`); blob1 is vestigial.
- `blob7` is `region` (ISO 3166-2).
- `KNOWN_DEV_DEVICES` filters admin queries by default; `?include_admins=1` is the escape hatch.
- `CUTOVER_TIMESTAMP` excludes pre-cutover (install_id-keyed) data.
- The "Never log raw `install_id` server-side" invariant is now "Never log raw machine_id, raw `device_id_hash`, or anything that pre-dates the HMAC step." (The hash itself is fine in admin SQL; the raw machine_id should never be in worker logs because it never reaches the worker.)

Pin a `last_verified` date at the top of the section if the doc uses that frontmatter — or update an existing date.

- [ ] **Step 8: Commit the PITFALLS update**

```bash
cd youcoded-dev
git add docs/PITFALLS.md
git commit -m "docs(pitfalls): update Analytics section for device-hash redesign"
```

---

## Phase 3 — Android client (youcoded)

### Task 12: Mirror analytics changes in Kotlin

**Repo:** `youcoded/`
**Files:**
- Create: `youcoded/app/src/main/kotlin/com/youcoded/app/analytics/Salt.kt`
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/analytics/AnalyticsService.kt`
- Modify: `youcoded/app/src/test/kotlin/com/youcoded/app/analytics/AnalyticsServiceTest.kt`

- [ ] **Step 1: Create the salt constants file**

Create `youcoded/app/src/main/kotlin/com/youcoded/app/analytics/Salt.kt`:

```kotlin
package com.youcoded.app.analytics

// Static salt for HMAC-SHA256 over the device's ANDROID_ID + platform.
// MUST match desktop/src/main/analytics-salt.ts ANALYTICS_SALT.
// See docs/superpowers/specs/2026-05-01-device-id-analytics-design.md.
const val ANALYTICS_SALT = "<paste the same hex string from desktop Task 9>"
```

Replace the placeholder with the EXACT same hex string used in desktop Task 9 step 2.

- [ ] **Step 2: Replace the test file**

Replace `youcoded/app/src/test/kotlin/com/youcoded/app/analytics/AnalyticsServiceTest.kt` with:

```kotlin
package com.youcoded.app.analytics

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AnalyticsServiceTest {
    private lateinit var server: MockWebServer
    private lateinit var homeDir: File

    @Before
    fun setUp() {
        server = MockWebServer().apply { start() }
        homeDir = Files.createTempDirectory("analytics-test").toFile()
    }

    @After
    fun tearDown() {
        server.shutdown()
        homeDir.deleteRecursively()
    }

    private fun newService(machineId: String = "test-machine-id-stable") = AnalyticsService(
        apiBase = server.url("/").toString().trimEnd('/'),
        homeDir = homeDir,
        appVersion = "1.3.0",
        machineIdReader = { machineId },
    )

    private fun stateFile() = File(homeDir, ".claude/youcoded-analytics.json")

    @Test
    fun `first launch posts ONE heartbeat with deviceIdHash`() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))
        val svc = newService()
        svc.runOnLaunch()

        assertEquals(1, server.requestCount)
        val req = server.takeRequest()
        assertEquals("/app/heartbeat", req.path)
        val body = JSONObject(req.body.readUtf8())
        assertTrue(body.getString("deviceIdHash").matches(Regex("^[a-f0-9]{64}$")))
        assertFalse(body.has("installId"))
        assertEquals("android", body.getString("platform"))
        assertEquals("1.3.0", body.getString("appVersion"))

        val state = svc.debugReadState()
        assertEquals(AnalyticsService.todayUtc(), state.lastPingedDate)
        assertNull(state.fallbackDeviceId)
    }

    @Test
    fun `no longer posts to app install`() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))
        val svc = newService()
        svc.runOnLaunch()
        // Only one request — nothing went to /app/install.
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `same-day relaunch does nothing`() {
        stateFile().parentFile!!.mkdirs()
        stateFile().writeText(
            """{"optIn":true,"lastPingedDate":"${AnalyticsService.todayUtc()}"}"""
        )
        val svc = newService()
        svc.runOnLaunch()
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `opt-out short-circuits`() {
        stateFile().parentFile!!.mkdirs()
        stateFile().writeText("""{"optIn":false,"lastPingedDate":""}""")
        val svc = newService()
        svc.runOnLaunch()
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `network failure does not advance lastPingedDate`() {
        server.enqueue(MockResponse().setResponseCode(500))
        val svc = newService()
        svc.runOnLaunch()
        val state = svc.debugReadState()
        assertEquals("", state.lastPingedDate)
    }

    @Test
    fun `machine_id read failure persists fallbackDeviceId`() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))
        val svc = newService(machineId = "")  // empty -> triggers fallback
        svc.runOnLaunch()
        val state = svc.debugReadState()
        assertTrue(state.fallbackDeviceId!!.matches(Regex("^[0-9a-f-]{36}$")))
        val body = JSONObject(server.takeRequest().body.readUtf8())
        assertTrue(body.getString("deviceIdHash").matches(Regex("^[a-f0-9]{64}$")))
    }

    @Test
    fun `legacy installId in state file is silently dropped`() {
        stateFile().parentFile!!.mkdirs()
        stateFile().writeText(
            """{"installId":"c4b2a8f0-0000-4000-8000-000000000000","installReported":true,"optIn":true,"lastPingedDate":"1970-01-01"}"""
        )
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))
        val svc = newService()
        svc.runOnLaunch()
        val state = svc.debugReadState()
        assertEquals(AnalyticsService.todayUtc(), state.lastPingedDate)
        // The state file no longer contains installId/installReported after this run.
        val rewritten = JSONObject(stateFile().readText())
        assertFalse(rewritten.has("installId"))
        assertFalse(rewritten.has("installReported"))
    }

    @Test
    fun `hash is stable across runs`() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))
        val svc1 = newService()
        svc1.runOnLaunch()
        val firstHash = JSONObject(server.takeRequest().body.readUtf8()).getString("deviceIdHash")

        // Reset state to force a re-send tomorrow.
        stateFile().writeText("""{"optIn":true,"lastPingedDate":""}""")
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))
        val svc2 = newService()
        svc2.runOnLaunch()
        val secondHash = JSONObject(server.takeRequest().body.readUtf8()).getString("deviceIdHash")

        assertEquals(firstHash, secondHash)
    }
}
```

- [ ] **Step 3: Run tests — expect FAIL**

```bash
cd youcoded
./gradlew :app:testDebugUnitTest --tests "com.youcoded.app.analytics.AnalyticsServiceTest"
```

Expected: most tests fail (the constructor signature now expects `machineIdReader`; the post path expects `/app/install` first).

- [ ] **Step 4: Replace `AnalyticsService.kt`**

Replace `youcoded/app/src/main/kotlin/com/youcoded/app/analytics/AnalyticsService.kt` with:

```kotlin
// Mirror of desktop/src/main/analytics-service.ts. Posts /app/heartbeat once
// per UTC day with a HMAC of (machine_id || platform). Fire-and-forget.
//
// Privacy: the raw machine_id never leaves the device. See the design
// spec at docs/superpowers/specs/2026-05-01-device-id-analytics-design.md.
package com.youcoded.app.analytics

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.TimeZone
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

data class AnalyticsState(
    val optIn: Boolean = true,
    val lastPingedDate: String = "",
    val fallbackDeviceId: String? = null,
)

class AnalyticsService(
    private val apiBase: String,
    private val homeDir: File,
    private val appVersion: String,
    private val http: OkHttpClient = OkHttpClient(),
    private val machineIdReader: () -> String = ::readAndroidId,
) {
    private val stateFile get() = File(homeDir, ".claude/youcoded-analytics.json")

    fun runOnLaunch() {
        var state = readState()
        if (!state.optIn) return

        val today = todayUtc()
        if (state.lastPingedDate == today) return

        val (newState, hash) = computeDeviceIdHash(state)
        state = newState

        val payload = JSONObject().apply {
            put("deviceIdHash", hash)
            put("appVersion", appVersion)
            put("platform", "android")
            put("os", "")
        }
        if (postEvent("/app/heartbeat", payload)) {
            state = state.copy(lastPingedDate = today)
            writeState(state)
        }
    }

    fun getOptIn(): Boolean = readState().optIn

    fun setOptIn(value: Boolean) {
        val state = readState()
        writeState(state.copy(optIn = value))
    }

    fun debugReadState(): AnalyticsState = readState()

    private fun computeDeviceIdHash(state: AnalyticsState): Pair<AnalyticsState, String> {
        var current = state
        var raw = try { machineIdReader() } catch (_: Exception) { "" }
        if (raw.length < 8) {
            if (current.fallbackDeviceId == null) {
                current = current.copy(fallbackDeviceId = UUID.randomUUID().toString())
                writeState(current)
            }
            raw = "fallback:${current.fallbackDeviceId}"
        }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(ANALYTICS_SALT.toByteArray(), "HmacSHA256"))
        val digest = mac.doFinal("$raw|android".toByteArray())
        val hash = digest.joinToString("") { "%02x".format(it) }
        return current to hash
    }

    private fun readState(): AnalyticsState {
        if (!stateFile.exists()) return AnalyticsState()
        return try {
            val json = JSONObject(stateFile.readText())
            AnalyticsState(
                optIn = json.optBoolean("optIn", true),
                lastPingedDate = json.optString("lastPingedDate", ""),
                fallbackDeviceId = if (json.has("fallbackDeviceId") && !json.isNull("fallbackDeviceId"))
                    json.getString("fallbackDeviceId") else null,
            )
        } catch (_: Exception) {
            AnalyticsState()
        }
    }

    private fun writeState(state: AnalyticsState) {
        stateFile.parentFile?.mkdirs()
        val json = JSONObject().apply {
            put("optIn", state.optIn)
            put("lastPingedDate", state.lastPingedDate)
            if (state.fallbackDeviceId != null) put("fallbackDeviceId", state.fallbackDeviceId)
        }
        stateFile.writeText(json.toString(2))
    }

    private fun postEvent(path: String, body: JSONObject): Boolean {
        return try {
            val req = Request.Builder()
                .url(apiBase + path)
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .build()
            http.newCall(req).execute().use { it.isSuccessful }
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        fun todayUtc(): String {
            val fmt = SimpleDateFormat("yyyy-MM-dd").apply { timeZone = TimeZone.getTimeZone("UTC") }
            return fmt.format(Date())
        }
    }
}

// Default machine_id source — runs only on a real device, never in unit tests
// (tests inject machineIdReader directly). Must NOT be called from a non-Android
// JVM context — Settings.Secure requires android.content.Context, which the
// caller (SessionService) injects via a thin adapter on production.
private fun readAndroidId(): String {
    throw IllegalStateException(
        "readAndroidId must be replaced with a Context-aware reader at construction time. " +
        "See SessionService.kt where AnalyticsService is instantiated."
    )
}
```

- [ ] **Step 5: Update the AnalyticsService instantiation in `SessionService.kt`**

Find where `AnalyticsService` is constructed in `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` (grep for `AnalyticsService(`). Replace the constructor call with one that passes a real `machineIdReader`:

```kotlin
import android.provider.Settings
// ...
val analyticsService = AnalyticsService(
    apiBase = "https://wecoded-marketplace-api.destinj101.workers.dev",
    homeDir = File(System.getProperty("user.home") ?: context.filesDir.absolutePath),
    appVersion = BuildConfig.VERSION_NAME,
    machineIdReader = {
        Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: ""
    },
)
```

(Adapt `homeDir` and `appVersion` parameter values to match what's already passed at the existing call site — the changes are: drop any old args that no longer exist on the new constructor, and add the `machineIdReader` lambda.)

- [ ] **Step 6: Run tests — expect PASS**

```bash
./gradlew :app:testDebugUnitTest --tests "com.youcoded.app.analytics.AnalyticsServiceTest"
```

Expected: all 8 tests pass.

- [ ] **Step 7: Build the debug APK**

```bash
./gradlew assembleDebug
```

Expected: build succeeds.

- [ ] **Step 8: Build the parity APK (verifies R8 doesn't break anything)**

```bash
./gradlew :app:assembleReleaseTest
```

Expected: build succeeds. (The PITFALLS doc warns about R8 minification breaking reflection-based code; HMAC + JSON usage is reflection-free, so this should just be a sanity check.)

- [ ] **Step 9: Commit**

```bash
cd youcoded
git add app/src/main/kotlin/com/youcoded/app/analytics/Salt.kt
git add app/src/main/kotlin/com/youcoded/app/analytics/AnalyticsService.kt
git add app/src/test/kotlin/com/youcoded/app/analytics/AnalyticsServiceTest.kt
git add app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt
git commit -m "feat(android): hashed deviceIdHash analytics, drop install POST"
```

---

### Task 13: Cross-platform hash parity test

A parity test pins desktop and Android to produce the same hash for the same `(machine_id, platform_label)` input. Catches silent salt drift.

**Repo:** `youcoded/`
**Files:**
- Create: `youcoded/desktop/src/main/analytics-hash-parity.test.ts`
- Modify: `youcoded/app/src/test/kotlin/com/youcoded/app/analytics/AnalyticsServiceTest.kt` (add a test method)

- [ ] **Step 1: Compute the expected hash for a fixed input**

Generate the parity reference value:

```bash
cd youcoded/desktop
# Use the actual SALT value from analytics-salt.ts. Replace <SALT> below.
node -e "
const crypto = require('crypto');
const SALT = '<paste the hex string from analytics-salt.ts>';
const hash = crypto.createHmac('sha256', SALT).update('parity-fixture-id|darwin').digest('hex');
console.log(hash);
"
```

Output: a 64-char hex string. This is the parity-fixture expected output.

- [ ] **Step 2: Add the desktop parity test**

Create `youcoded/desktop/src/main/analytics-hash-parity.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { createHmac } from "node:crypto";
import { ANALYTICS_SALT } from "./analytics-salt";

// Parity contract: a fixed (machine_id, platform_label) input MUST hash to
// this exact value on both desktop and Android. If you change SALT or the
// hash construction, this test breaks intentionally — update the expected
// value AND mirror the change in app/src/main/kotlin/.../analytics/Salt.kt
// so Android stays in sync.
const FIXTURE_INPUT = "parity-fixture-id|darwin";
const EXPECTED = "<paste the hex string from step 1>";

describe("analytics hash parity", () => {
  it("hashes the parity fixture to the pinned value", () => {
    const actual = createHmac("sha256", ANALYTICS_SALT)
      .update(FIXTURE_INPUT)
      .digest("hex");
    expect(actual).toBe(EXPECTED);
  });
});
```

- [ ] **Step 3: Add the Android parity test**

Open `youcoded/app/src/test/kotlin/com/youcoded/app/analytics/AnalyticsServiceTest.kt` and add this test method to the class:

```kotlin
@Test
fun `hash parity with desktop`() {
    // Fixture: hashing "parity-fixture-id|darwin" with ANALYTICS_SALT must
    // produce the same hex string on Android as on desktop. If this breaks
    // after a salt rotation, update both desktop and Android together.
    val mac = javax.crypto.Mac.getInstance("HmacSHA256")
    mac.init(javax.crypto.spec.SecretKeySpec(ANALYTICS_SALT.toByteArray(), "HmacSHA256"))
    val digest = mac.doFinal("parity-fixture-id|darwin".toByteArray())
    val actual = digest.joinToString("") { "%02x".format(it) }
    val expected = "<paste the SAME hex string from step 1>"
    assertEquals(expected, actual)
}
```

- [ ] **Step 4: Run both parity tests**

```bash
cd youcoded/desktop && npm test -- src/main/analytics-hash-parity.test.ts
cd youcoded && ./gradlew :app:testDebugUnitTest --tests "com.youcoded.app.analytics.AnalyticsServiceTest.hash parity with desktop"
```

Expected: both pass and produce the same expected value.

- [ ] **Step 5: Commit**

```bash
cd youcoded
git add desktop/src/main/analytics-hash-parity.test.ts
git add app/src/test/kotlin/com/youcoded/app/analytics/AnalyticsServiceTest.kt
git commit -m "test(analytics): cross-platform hash parity fixture"
```

---

## Phase 4 — Skill update (youcoded-admin)

### Task 14: Update `/analytics` skill text + add /regions fetch

**Repo:** `youcoded-admin/`
**Files:**
- Modify: `youcoded-admin/skills/analytics/SKILL.md`

- [ ] **Step 1: Update the SKILL.md output template**

Open `youcoded-admin/skills/analytics/SKILL.md`. Find the "Flow 1 — Bare summary (default)" section. Replace the parallel-fetch block with:

```bash
M=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/mau)
D=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/dau?days=30)
I=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/installs?days=7)
V=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/versions)
P=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/platforms)
C=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/countries)
R=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/regions)
```

Then update the format block:

```
YouCoded analytics — <today YYYY-MM-DD>
Devices active today:        <N>
Devices active (rolling 30d): <N>
New devices (7d):            <N>
Top versions:                <v> (<pct>%)  <v> (<pct>%)  …
Platform split:              desktop <pct>%  android <pct>%
Top countries:               <CC> <pct>%  <CC> <pct>%  …  (top 5)
Top regions:                 <RC> <N>  <RC> <N>  …  (top 5)

Counted unique devices, excluding admin devices.
```

Also update the field-mapping comments throughout the doc — e.g., "DAU (today) is the last entry of the dau trend" becomes "Devices active today is the last entry of the DAU trend (devices column)." Replace every reference to "users" in the result-formatting prose with "devices."

Add a new "Flow 7 — Regions" section after Flow 6:

```markdown
## Flow 7 — Regions

Fetch `/admin/analytics/regions`. Display top 20 as a table: ISO 3166-2 region code, device count, percentage of total devices in result. ISO codes are formatted `XX-YY` (country dash subdivision) — e.g., `US-CA`, `CA-ON`, `GB-ENG`.
```

- [ ] **Step 2: Re-copy the skill into `~/.claude/skills/`**

```bash
cd youcoded-dev
cp -r youcoded-admin/skills/analytics ~/.claude/skills/
```

- [ ] **Step 3: Smoke-test by invoking the skill in a fresh Claude session**

(Manual — not a checkbox the engineer can complete via shell. Skip if running headless.)

- [ ] **Step 4: Commit**

```bash
cd youcoded-admin
git add skills/analytics/SKILL.md
git commit -m "feat(skill): /analytics — devices framing, add /regions fetch"
```

---

## Phase 5 — Cutover

### Task 15: Identify and register Destin's known device hashes

After version N ships, run it on each of Destin's known machines (laptop, dev VM, releaseTest installs) and capture the resulting hash. Add to `KNOWN_DEV_DEVICES` secret.

**Repo:** `wecoded-marketplace/`
**Files:** none (secret config only).

- [ ] **Step 1: Add a one-shot debug print to log the device hash on launch**

In `youcoded/desktop/src/main/analytics-service.ts`, at the top of `runAnalyticsOnLaunch()`, temporarily add:

```ts
const _state = readState();
console.log("YOUCODED_DEVICE_HASH:", deviceIdHash(_state));
```

Build and run version N on each known machine. Read the console line `YOUCODED_DEVICE_HASH: ...` from each.

(Or: add a `dev:get-device-hash` IPC handler if you'd rather not console.log a privacy-relevant value. Either way is fine for a one-shot collection.)

- [ ] **Step 2: Capture the hashes from each machine**

Run on:
- Destin's primary laptop (production install)
- Destin's primary laptop (dev install, if separate `~/.claude` profile)
- Any test VMs
- The releaseTest APK on Destin's phone

Save each hash to a local file like `dev-devices.txt`.

- [ ] **Step 3: Set the `KNOWN_DEV_DEVICES` secret**

```bash
cd wecoded-marketplace/worker
HASHES=$(cat /path/to/dev-devices.txt | tr '\n' ',' | sed 's/,$//')
echo "$HASHES" | npx wrangler secret put KNOWN_DEV_DEVICES
```

- [ ] **Step 4: Verify the filter works**

```bash
gh_token=$(gh auth token)
# With filter (default)
curl -s https://wecoded-marketplace-api.destinj101.workers.dev/admin/analytics/mau \
  -H "X-GitHub-PAT: $gh_token"
# Without filter
curl -s "https://wecoded-marketplace-api.destinj101.workers.dev/admin/analytics/mau?include_admins=1" \
  -H "X-GitHub-PAT: $gh_token"
```

Expected: the un-filtered MAU is higher than the filtered one (by at least 1, depending on how many of your devices are active that day).

- [ ] **Step 5: Remove the debug print from analytics-service.ts**

Revert the temporary `console.log("YOUCODED_DEVICE_HASH:", ...)` line. Commit the revert:

```bash
cd youcoded
git add desktop/src/main/analytics-service.ts
git commit -m "chore(desktop): remove one-shot device-hash debug log"
```

---

### Task 16: Set the cutover timestamp

After Step 4 of Task 15 confirms data is flowing on the new shape, freeze the cutover.

**Repo:** `wecoded-marketplace/`
**Files:**
- Modify: `wecoded-marketplace/worker/wrangler.toml`

- [ ] **Step 1: Pick the cutover timestamp**

Use the timestamp at which version N tagged the release. Approximate is fine; the goal is "everything before this is install_id-keyed and shouldn't be counted."

```bash
# E.g., the day version N tagged on master:
echo "2026-05-15T00:00:00Z"
```

- [ ] **Step 2: Update `wrangler.toml`**

Open `wecoded-marketplace/worker/wrangler.toml` and replace:

```toml
[vars]
CUTOVER_TIMESTAMP = ""
```

with:

```toml
[vars]
CUTOVER_TIMESTAMP = "2026-05-15T00:00:00Z"
```

(Use the actual timestamp from step 1.)

- [ ] **Step 3: Deploy**

```bash
cd wecoded-marketplace/worker
npx wrangler deploy
```

- [ ] **Step 4: Verify**

```bash
gh_token=$(gh auth token)
curl -s "https://wecoded-marketplace-api.destinj101.workers.dev/admin/analytics/mau" \
  -H "X-GitHub-PAT: $gh_token"
```

Expected: MAU reflects only post-cutover data. (If you have pre-cutover heartbeats from old clients, they're now excluded.)

- [ ] **Step 5: Commit**

```bash
cd wecoded-marketplace
git add worker/wrangler.toml
git commit -m "chore(worker): set CUTOVER_TIMESTAMP to <date>"
```

---

## Follow-up (NOT part of this plan)

After ~2 weeks of soaking, when telemetry shows zero pre-N-version heartbeats arriving:

1. Drop the dual-acceptance soak in `routes.ts` — `parseBody` rejects with 400 when `deviceIdHash` is missing, period.
2. Remove the legacy `installId` branch in `parseBody`.
3. Update `app-routes.test.ts` to remove the soak-window tests.

This is a single small commit; deferred until version N saturates the install base.

---

## Notes on testing strategy

- **Worker tests** run via `npm test` in `wecoded-marketplace/worker/` — vitest with `cloudflare:test` env.
- **Desktop tests** run via `npm test` in `youcoded/desktop/` — vitest with mocked `electron` + `node-machine-id`.
- **Android tests** run via `./gradlew :app:testDebugUnitTest` from `youcoded/` — JUnit + MockWebServer. They do not require a device.
- **Hash parity** is the only test that spans repos. The expected hash value is committed in both source trees and must match — a parity fixture file would be cleaner but adds cross-repo coupling. Manual sync is sufficient for one salt that we don't plan to rotate.
- **Live AE smoke** is a manual deploy-time check (Task 7 step 3). No automated test for the SQL dialect because it requires real CF credentials.
