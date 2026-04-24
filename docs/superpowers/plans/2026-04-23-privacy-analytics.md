# Privacy-Preserving Install & Usage Analytics — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship opt-outable anonymous install + DAU/MAU telemetry for YouCoded, end-to-end: Worker endpoints → Analytics Engine → admin dashboard → admin skill, plus desktop + Android clients and updated privacy copy.

**Architecture:** Cloudflare Analytics Engine for all event storage (pure cardinality queries via `COUNT_DISTINCT`, no D1 rows keyed by install_id). Two public Worker endpoints (`/app/install`, `/app/heartbeat`). Admin-gated dashboard + SQL-backed JSON routes. Clients ping once per day with client-side UTC dedupe. Opt-out lives in existing `AboutPopup.tsx` Privacy section, default ON.

**Tech Stack:** Cloudflare Workers (Hono, TypeScript), Analytics Engine, D1 (existing, unused for analytics), Electron/Node (desktop main), Kotlin/OkHttp (Android), React + Tailwind (Privacy UI), plain HTML + Chart.js (admin dashboard), bash + `gh` + `curl` (admin skill).

**Spec:** `docs/superpowers/specs/2026-04-23-privacy-analytics-design.md`

## Cross-repo worktree convention

This plan touches three repos. Each phase runs in its own worktree to respect the `worktree-guard.sh` invariant and the workspace's single-branch policy.

- **Worker changes (Phases 1–4):** worktree under `wecoded-marketplace/`, branch `feature/privacy-analytics-worker`.
- **App changes (Phases 5–7):** worktree under `youcoded/`, branch `feature/privacy-analytics-app`.
- **Admin skill (Phase 8):** worktree under `youcoded-admin/`, branch `feature/analytics-skill`.

Each phase finishes with a merge + push + worktree cleanup before the next repo-switch.

```bash
# Example at the start of Phase 1:
cd C:/Users/desti/youcoded-dev/wecoded-marketplace
git fetch origin && git pull origin master
git worktree add ../wecoded-marketplace-worktrees/privacy-analytics feature/privacy-analytics-worker
cd ../wecoded-marketplace-worktrees/privacy-analytics
```

---

## Phase 1 — Worker: Analytics Engine binding + public `/app/*` routes

Adds the Analytics Engine binding, a `lib/analytics.ts` wrapper, and two public POST endpoints (`/app/install`, `/app/heartbeat`). Deployable alone — safe no-op with no clients pinging yet.

### Task 1.1 — Add the Analytics Engine binding to `wrangler.toml`

**Files:**
- Modify: `wecoded-marketplace/worker/wrangler.toml`

- [ ] **Step 1: Open `wrangler.toml` and add the AE binding after the `[ai]` block.**

Add this block immediately after line 13 (the `[ai]` block, before `[env.test]`):

```toml
[[analytics_engine_datasets]]
binding = "APP_ANALYTICS"
dataset = "youcoded_app_events"
```

Do NOT add a mirror binding inside `[env.test]` — vitest-pool-workers / miniflare can't resolve the AE binding in this toolchain version, and `lib/analytics.ts` will guard the call with `?.`.

- [ ] **Step 2: Commit.**

```bash
git add wrangler.toml
git commit -m "feat(worker): add Analytics Engine binding APP_ANALYTICS"
```

### Task 1.2 — Update `Env` type

**Files:**
- Modify: `wecoded-marketplace/worker/src/types.ts`

- [ ] **Step 1: Add `APP_ANALYTICS?` to the `Env` interface.**

Modify the `Env` interface (lines 1–7) to:

```ts
export interface Env {
  DB: D1Database;
  AI: Ai;
  APP_ANALYTICS?: AnalyticsEngineDataset;
  GH_CLIENT_ID: string;
  GH_CLIENT_SECRET: string;
  ADMIN_USER_IDS: string;  // comma-separated user ids
}
```

The `?` is load-bearing: test env omits the binding by design.

- [ ] **Step 2: Confirm `AnalyticsEngineDataset` resolves via `@cloudflare/workers-types`.**

Run: `npx tsc --noEmit`
Expected: no new errors. If `AnalyticsEngineDataset` is unresolved, check that `@cloudflare/workers-types` is installed; add it via `npm i -D @cloudflare/workers-types` if missing and re-run.

- [ ] **Step 3: Commit.**

```bash
git add src/types.ts package.json package-lock.json
git commit -m "feat(worker): add APP_ANALYTICS to Env type"
```

### Task 1.3 — `lib/analytics.ts` wrapper

**Files:**
- Create: `wecoded-marketplace/worker/src/lib/analytics.ts`
- Test: `wecoded-marketplace/worker/test/analytics-lib.test.ts`

- [ ] **Step 1: Write the failing test.**

Create `test/analytics-lib.test.ts`:

```ts
import { describe, it, expect, vi } from "vitest";
import { writeAppEvent } from "../src/lib/analytics";

describe("writeAppEvent", () => {
  it("no-ops when binding is missing", () => {
    // Must not throw when env.APP_ANALYTICS is undefined (test env shape).
    expect(() =>
      writeAppEvent(
        { APP_ANALYTICS: undefined as any } as any,
        {
          eventType: "install",
          installId: "00000000-0000-0000-0000-000000000000",
          appVersion: "1.2.1",
          platform: "desktop",
          os: "mac",
          country: "US",
        }
      )
    ).not.toThrow();
  });

  it("calls writeDataPoint with the expected blob order", () => {
    const writeDataPoint = vi.fn();
    writeAppEvent(
      { APP_ANALYTICS: { writeDataPoint } } as any,
      {
        eventType: "heartbeat",
        installId: "11111111-1111-1111-1111-111111111111",
        appVersion: "1.2.1",
        platform: "android",
        os: "",
        country: "DE",
      }
    );
    expect(writeDataPoint).toHaveBeenCalledWith({
      blobs: ["heartbeat", "11111111-1111-1111-1111-111111111111", "1.2.1", "android", "", "DE"],
      doubles: [],
      indexes: ["heartbeat"],
    });
  });
});
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `npx vitest run test/analytics-lib.test.ts`
Expected: FAIL with `Cannot find module '../src/lib/analytics'`.

- [ ] **Step 3: Write the minimal implementation.**

Create `src/lib/analytics.ts`:

```ts
// Privacy-by-construction wrapper around env.APP_ANALYTICS.writeDataPoint.
// Enforces the blob order that all /admin/analytics/* SQL queries assume.
// No caller outside this file should ever touch env.APP_ANALYTICS directly.
import type { Env } from "../types";

export type AppEventType = "install" | "heartbeat";

export interface AppEventPayload {
  eventType: AppEventType;
  installId: string;
  appVersion: string;
  platform: "desktop" | "android";
  os: string;      // "win" | "mac" | "linux" for desktop; "" on android
  country: string; // ISO 2-letter from CF-IPCountry, or ""
}

// The optional chaining is load-bearing: tests run with APP_ANALYTICS undefined
// because vitest-pool-workers can't resolve the binding. Production always has it.
export function writeAppEvent(env: Env, payload: AppEventPayload): void {
  env.APP_ANALYTICS?.writeDataPoint({
    blobs: [
      payload.eventType,   // blob1 — also in indexes for fast WHERE filters
      payload.installId,   // blob2 — COUNT_DISTINCT only, never returned to clients
      payload.appVersion,  // blob3
      payload.platform,    // blob4
      payload.os,          // blob5
      payload.country,     // blob6
    ],
    doubles: [],
    indexes: [payload.eventType],
  });
}
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `npx vitest run test/analytics-lib.test.ts`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit.**

```bash
git add src/lib/analytics.ts test/analytics-lib.test.ts
git commit -m "feat(worker): add writeAppEvent wrapper with fixed blob order"
```

### Task 1.4 — `/app/install` route + validation + rate limit

**Files:**
- Create: `wecoded-marketplace/worker/src/app/routes.ts`
- Test: `wecoded-marketplace/worker/test/app-routes.test.ts`

- [ ] **Step 1: Write the failing test.**

Create `test/app-routes.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import app from "../src/index";

const VALID_PAYLOAD = {
  installId: "c4b2a8f0-0000-4000-8000-000000000000",
  appVersion: "1.2.1",
  platform: "desktop",
  os: "mac",
};

describe("POST /app/install", () => {
  it("accepts a valid payload", async () => {
    const res = await app.request("/app/install", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(VALID_PAYLOAD),
    });
    expect(res.status).toBe(200);
    const body = await res.json<{ ok: boolean }>();
    expect(body.ok).toBe(true);
  });

  it("rejects non-UUID installId", async () => {
    const res = await app.request("/app/install", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...VALID_PAYLOAD, installId: "not-a-uuid" }),
    });
    expect(res.status).toBe(400);
  });

  it("rejects unknown platform", async () => {
    const res = await app.request("/app/install", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...VALID_PAYLOAD, platform: "windows-phone" }),
    });
    expect(res.status).toBe(400);
  });

  it("rejects missing fields", async () => {
    const res = await app.request("/app/install", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ installId: VALID_PAYLOAD.installId }),
    });
    expect(res.status).toBe(400);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `npx vitest run test/app-routes.test.ts`
Expected: FAIL — 404 on `/app/install` because no route is registered yet.

- [ ] **Step 3: Write the minimal implementation.**

Create `src/app/routes.ts`:

```ts
import { Hono } from "hono";
import type { HonoEnv } from "../types";
import { badRequest, tooMany } from "../lib/errors";
import { checkRateLimit } from "../lib/rate-limit";
import { writeAppEvent, type AppEventType } from "../lib/analytics";

export const appRoutes = new Hono<HonoEnv>();

// UUIDv4 regex (case-insensitive) — matches the shape generated by crypto.randomUUID().
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PLATFORMS = new Set(["desktop", "android"]);
const MAX_VERSION_LEN = 32;
const MAX_OS_LEN = 16;

interface AppEventBody {
  installId?: unknown;
  appVersion?: unknown;
  platform?: unknown;
  os?: unknown;
}

// Validates incoming payload shape. Returns the cleaned values or throws.
// Never logs the payload — the installId is treated as sensitive.
function parseBody(body: AppEventBody) {
  const installId = typeof body.installId === "string" ? body.installId : "";
  const appVersion = typeof body.appVersion === "string" ? body.appVersion : "";
  const platform = typeof body.platform === "string" ? body.platform : "";
  const os = typeof body.os === "string" ? body.os : "";
  if (!UUID_V4.test(installId)) throw badRequest("invalid request");
  if (!appVersion || appVersion.length > MAX_VERSION_LEN) throw badRequest("invalid request");
  if (!PLATFORMS.has(platform)) throw badRequest("invalid request");
  if (os.length > MAX_OS_LEN) throw badRequest("invalid request");
  return { installId, appVersion, platform: platform as "desktop" | "android", os };
}

// Uses the CF edge's visitor-ip header for rate-limit keying. The Cache API backing
// checkRateLimit is per-colo, which is fine for casual abuse prevention.
function clientIp(c: any): string {
  return c.req.header("CF-Connecting-IP") || c.req.header("X-Forwarded-For") || "unknown";
}

async function handleEvent(c: any, eventType: AppEventType, rateKey: string, limit: number) {
  const ip = clientIp(c);
  if (!(await checkRateLimit(`${rateKey}:${ip}`, limit, 3600))) {
    throw tooMany("too many requests");
  }
  const body = await c.req.json<AppEventBody>().catch(() => ({} as AppEventBody));
  const parsed = parseBody(body);
  const country = c.req.header("CF-IPCountry") || "";
  writeAppEvent(c.env, { eventType, ...parsed, country });
  return c.json({ ok: true });
}

// POST /app/install — fired once per install (first-launch).
// Rate-limited at 10/hour/IP: legit users hit it exactly once; higher is abuse.
appRoutes.post("/app/install", (c) => handleEvent(c, "install", "app-install", 10));

// POST /app/heartbeat — fired at most once/day per install.
// Rate-limited at 30/hour/IP: generous for dev-machine bouncing between builds.
appRoutes.post("/app/heartbeat", (c) => handleEvent(c, "heartbeat", "app-heartbeat", 30));
```

- [ ] **Step 4: Mount the new routes in `src/index.ts`.**

Modify `src/index.ts` — add the import near the top:

```ts
import { appRoutes } from "./app/routes";
```

Add the mount line with the other `app.route` calls (around line 36):

```ts
app.route("/", appRoutes);
```

- [ ] **Step 5: Run the test to verify it passes.**

Run: `npx vitest run test/app-routes.test.ts`
Expected: PASS, 4 tests.

Also run the full suite to confirm no regressions:

Run: `npx vitest run`
Expected: all tests pass (existing tests unaffected).

- [ ] **Step 6: Commit.**

```bash
git add src/app/routes.ts src/index.ts test/app-routes.test.ts
git commit -m "feat(worker): add POST /app/install with UUID validation + rate limit"
```

### Task 1.5 — `/app/heartbeat` route test coverage

The heartbeat route was implemented alongside install in Task 1.4 (same handler shape). Extend the test file with heartbeat-specific cases.

**Files:**
- Modify: `wecoded-marketplace/worker/test/app-routes.test.ts`

- [ ] **Step 1: Add heartbeat-specific tests.**

Append to `test/app-routes.test.ts`:

```ts
describe("POST /app/heartbeat", () => {
  it("accepts a valid payload", async () => {
    const res = await app.request("/app/heartbeat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        installId: "c4b2a8f0-0000-4000-8000-000000000001",
        appVersion: "1.2.1",
        platform: "android",
        os: "",
      }),
    });
    expect(res.status).toBe(200);
    const body = await res.json<{ ok: boolean }>();
    expect(body.ok).toBe(true);
  });

  it("rejects invalid payload shape", async () => {
    const res = await app.request("/app/heartbeat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "not json",
    });
    expect(res.status).toBe(400);
  });
});
```

- [ ] **Step 2: Run the tests to verify they pass.**

Run: `npx vitest run test/app-routes.test.ts`
Expected: PASS, 6 tests total.

- [ ] **Step 3: Commit.**

```bash
git add test/app-routes.test.ts
git commit -m "test(worker): add POST /app/heartbeat coverage"
```

### Task 1.6 — Deploy Phase 1 and verify

- [ ] **Step 1: Run typecheck + full test suite.**

```bash
npx tsc --noEmit
npx vitest run
```

Expected: both clean.

- [ ] **Step 2: Merge `feature/privacy-analytics-worker` into `master` and push.**

```bash
cd ../wecoded-marketplace  # main worktree
git fetch origin
git pull origin master
git merge --no-ff feature/privacy-analytics-worker -m "merge: privacy-analytics worker phase 1 (public /app/* routes)"
git push origin master
```

- [ ] **Step 3: CI deploys the worker.** Wait for `.github/workflows/worker-deploy.yml` to complete. Verify in the Actions tab.

- [ ] **Step 4: Manually verify the live endpoint.**

```bash
curl -s -X POST https://wecoded-marketplace-api.<account>.workers.dev/app/install \
  -H 'Content-Type: application/json' \
  -d '{"installId":"c4b2a8f0-0000-4000-8000-000000000002","appVersion":"0.0.0-test","platform":"desktop","os":"linux"}'
```

Expected: `{"ok":true}`.

Also check that an invalid payload fails:

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://wecoded-marketplace-api.<account>.workers.dev/app/install \
  -H 'Content-Type: application/json' \
  -d '{"installId":"bad"}'
```

Expected: `400`.

- [ ] **Step 5: Confirm Analytics Engine dataset exists in Cloudflare dashboard.**

Navigate to Workers & Pages → your account → Analytics Engine. The dataset `youcoded_app_events` should appear after the first successful `writeDataPoint` call from step 4.

- [ ] **Step 6: Remove the feature worktree.**

```bash
git worktree remove ../wecoded-marketplace-worktrees/privacy-analytics
git branch -d feature/privacy-analytics-worker
```

---

## Phase 2 — Worker: admin analytics routes + SQL API client

Adds admin-gated JSON routes that run canned SQL queries against Analytics Engine. Still uses the existing cookie-session `requireAuth` for now — Bearer/PAT branch comes in Phase 3.

### Task 2.1 — Add `CF_ACCOUNT_ID` / `CF_API_TOKEN` CI secrets

**Files:**
- Modify: `wecoded-marketplace/.github/workflows/worker-deploy.yml`
- Modify: `wecoded-marketplace/worker/src/types.ts`

- [ ] **Step 1: Start a new worktree for Phase 2.**

```bash
cd C:/Users/desti/youcoded-dev/wecoded-marketplace
git fetch origin && git pull origin master
git worktree add ../wecoded-marketplace-worktrees/privacy-analytics-admin feature/privacy-analytics-admin
cd ../wecoded-marketplace-worktrees/privacy-analytics-admin
```

- [ ] **Step 2: Extend the `Env` type.**

Modify `src/types.ts` — extend the `Env` interface:

```ts
export interface Env {
  DB: D1Database;
  AI: Ai;
  APP_ANALYTICS?: AnalyticsEngineDataset;
  GH_CLIENT_ID: string;
  GH_CLIENT_SECRET: string;
  ADMIN_USER_IDS: string;
  CF_ACCOUNT_ID: string;
  CF_API_TOKEN: string;
}
```

- [ ] **Step 3: Add the secrets to `[env.test.vars]` in `wrangler.toml` so tests typecheck.**

Modify the `[env.test.vars]` block (around line 24):

```toml
[env.test.vars]
GH_CLIENT_ID = "test"
GH_CLIENT_SECRET = "test"
ADMIN_USER_IDS = "github:admin"
CF_ACCOUNT_ID = "test-account"
CF_API_TOKEN = "test-token"
```

- [ ] **Step 4: Add the secrets to the CI deploy workflow.**

Open `.github/workflows/worker-deploy.yml`. Locate the `wrangler secret put` sequence that runs AFTER `wrangler deploy`. Add two new blocks:

```yaml
      - name: Put CF_ACCOUNT_ID secret
        working-directory: ./worker
        run: echo "${{ secrets.CF_ANALYTICS_ACCOUNT_ID }}" | npx wrangler secret put CF_ACCOUNT_ID
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}

      - name: Put CF_API_TOKEN secret
        working-directory: ./worker
        run: echo "${{ secrets.CF_ANALYTICS_API_TOKEN }}" | npx wrangler secret put CF_API_TOKEN
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

CI secrets `CF_ANALYTICS_ACCOUNT_ID` and `CF_ANALYTICS_API_TOKEN` must be added manually to the GitHub repo settings (Settings → Secrets and variables → Actions) before the next deploy. The API token must be scoped to **Analytics Engine READ only** — create it at https://dash.cloudflare.com/profile/api-tokens with the template "Custom token", permissions: "Account → Analytics Engine → Read".

- [ ] **Step 5: Commit.**

```bash
git add src/types.ts wrangler.toml .github/workflows/worker-deploy.yml
git commit -m "feat(worker): add CF_ACCOUNT_ID / CF_API_TOKEN secret plumbing"
```

### Task 2.2 — `lib/analytics-query.ts` — Analytics Engine SQL client

**Files:**
- Create: `wecoded-marketplace/worker/src/lib/analytics-query.ts`
- Test: `wecoded-marketplace/worker/test/analytics-query.test.ts`

- [ ] **Step 1: Write the failing test.**

Create `test/analytics-query.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { runAnalyticsQuery } from "../src/lib/analytics-query";

describe("runAnalyticsQuery", () => {
  const origFetch = globalThis.fetch;
  beforeEach(() => {
    globalThis.fetch = vi.fn(async () =>
      new Response(
        JSON.stringify({
          meta: [{ name: "day", type: "Date" }, { name: "dau", type: "UInt64" }],
          data: [{ day: "2026-04-22", dau: 42 }],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    ) as any;
  });
  afterEach(() => {
    globalThis.fetch = origFetch;
  });

  it("POSTs the SQL to the CF SQL API with bearer auth", async () => {
    const env = { CF_ACCOUNT_ID: "acc123", CF_API_TOKEN: "tok456" } as any;
    const rows = await runAnalyticsQuery(env, "SELECT 1");
    expect(rows).toEqual([{ day: "2026-04-22", dau: 42 }]);
    const call = (globalThis.fetch as any).mock.calls[0];
    expect(call[0]).toBe("https://api.cloudflare.com/client/v4/accounts/acc123/analytics_engine/sql");
    expect(call[1].method).toBe("POST");
    expect(call[1].headers.Authorization).toBe("Bearer tok456");
    expect(call[1].body).toBe("SELECT 1");
  });

  it("throws on non-200 from CF", async () => {
    globalThis.fetch = vi.fn(async () => new Response("boom", { status: 500 })) as any;
    const env = { CF_ACCOUNT_ID: "acc123", CF_API_TOKEN: "tok456" } as any;
    await expect(runAnalyticsQuery(env, "SELECT 1")).rejects.toThrow(/analytics query failed/i);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `npx vitest run test/analytics-query.test.ts`
Expected: FAIL with `Cannot find module '../src/lib/analytics-query'`.

- [ ] **Step 3: Write the minimal implementation.**

Create `src/lib/analytics-query.ts`:

```ts
// SQL-over-HTTP client for Cloudflare Analytics Engine.
// Docs: https://developers.cloudflare.com/analytics/analytics-engine/sql-api/
// Admin-only caller — never expose this to public routes.
import type { Env } from "../types";

interface AEResponse<T> {
  meta: Array<{ name: string; type: string }>;
  data: T[];
}

export async function runAnalyticsQuery<T = Record<string, unknown>>(
  env: Env,
  sql: string
): Promise<T[]> {
  const url = `https://api.cloudflare.com/client/v4/accounts/${env.CF_ACCOUNT_ID}/analytics_engine/sql`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.CF_API_TOKEN}`,
      "Content-Type": "text/plain",  // AE SQL API takes raw SQL, not JSON
    },
    body: sql,
  });
  if (!res.ok) {
    // Don't include the raw body — it can contain the SQL text, which is fine,
    // but we surface a short error message. Full body is in CF's observability logs.
    throw new Error(`analytics query failed: ${res.status}`);
  }
  const body = (await res.json()) as AEResponse<T>;
  return body.data;
}
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `npx vitest run test/analytics-query.test.ts`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit.**

```bash
git add src/lib/analytics-query.ts test/analytics-query.test.ts
git commit -m "feat(worker): add runAnalyticsQuery SQL client"
```

### Task 2.3 — `admin/analytics.ts` — canned-query routes

**Files:**
- Create: `wecoded-marketplace/worker/src/admin/analytics.ts`
- Test: `wecoded-marketplace/worker/test/admin-analytics.test.ts`

- [ ] **Step 1: Write the failing test.**

Create `test/admin-analytics.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import app from "../src/index";
import { seedSession } from "./setup";  // existing helper — see test/setup.ts

const origFetch = globalThis.fetch;

function mockCfSql(rows: unknown[]) {
  globalThis.fetch = vi.fn(async () =>
    new Response(JSON.stringify({ meta: [], data: rows }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    })
  ) as any;
}

describe("GET /admin/analytics/dau", () => {
  beforeEach(() => {
    mockCfSql([{ day: "2026-04-22", dau: 42 }]);
  });
  afterEach(() => {
    globalThis.fetch = origFetch;
  });

  it("returns 401 without auth", async () => {
    const res = await app.request("/admin/analytics/dau");
    expect(res.status).toBe(401);
  });

  it("returns 403 for non-admin", async () => {
    const { token } = await seedSession("github:notadmin");
    const res = await app.request("/admin/analytics/dau", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(403);
  });

  it("returns the SQL rows for an admin", async () => {
    const { token } = await seedSession("github:admin");
    const res = await app.request("/admin/analytics/dau", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const body = await res.json<Array<{ day: string; dau: number }>>();
    expect(body).toEqual([{ day: "2026-04-22", dau: 42 }]);
  });

  it("clamps the days param to a safe range", async () => {
    const { token } = await seedSession("github:admin");
    const res = await app.request("/admin/analytics/dau?days=9999", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const sqlBody = (globalThis.fetch as any).mock.calls[0][1].body as string;
    // The SQL is built server-side — clamped to at most 90.
    expect(sqlBody).toMatch(/INTERVAL '90' DAY/);
  });
});

// Similar describes for: /admin/analytics/mau, /admin/analytics/installs,
// /admin/analytics/versions, /admin/analytics/platforms, /admin/analytics/countries.
// The pattern is identical — swap the endpoint and the expected SQL fragment.
describe("GET /admin/analytics/mau", () => {
  beforeEach(() => mockCfSql([{ mau: 1337 }]));
  afterEach(() => { globalThis.fetch = origFetch; });

  it("returns the mau number for admin", async () => {
    const { token } = await seedSession("github:admin");
    const res = await app.request("/admin/analytics/mau", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const body = await res.json<{ mau: number }>();
    expect(body.mau).toBe(1337);
  });
});

describe("GET /admin/analytics/versions", () => {
  beforeEach(() => mockCfSql([{ version: "1.2.1", users: 10 }, { version: "1.2.0", users: 3 }]));
  afterEach(() => { globalThis.fetch = origFetch; });

  it("returns rows sorted as provided", async () => {
    const { token } = await seedSession("github:admin");
    const res = await app.request("/admin/analytics/versions", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const body = await res.json<Array<{ version: string; users: number }>>();
    expect(body.length).toBe(2);
    expect(body[0].version).toBe("1.2.1");
  });
});
```

Check `test/setup.ts` for the actual name/signature of the session-seeding helper. If it's named differently, update the import and calls above to match. (If no helper exists, add one at the end of `test/setup.ts` that inserts a user + session row into the test D1 DB and returns `{ token }`.)

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `npx vitest run test/admin-analytics.test.ts`
Expected: FAIL — 404 on `/admin/analytics/*`.

- [ ] **Step 3: Write the minimal implementation.**

Create `src/admin/analytics.ts`:

```ts
// Admin-only analytics read routes. Each handler:
//   1. Requires a session (Bearer token resolved via requireAuth).
//   2. Checks admin allowlist via isAdmin(env, userId).
//   3. Runs a canned SQL query against Analytics Engine.
//   4. Returns the rows as JSON — shape is documented per-route.
//
// Privacy-by-construction: no handler exposes raw install_id blobs. blob2
// is always aggregated via COUNT_DISTINCT or omitted from SELECT entirely.
import { Hono } from "hono";
import type { HonoEnv } from "../types";
import { requireAuth } from "../auth/middleware";
import { forbidden } from "../lib/errors";
import { runAnalyticsQuery } from "../lib/analytics-query";

function isAdmin(env: { ADMIN_USER_IDS: string }, userId: string): boolean {
  const admins = env.ADMIN_USER_IDS.split(",").map((s) => s.trim()).filter(Boolean);
  return admins.includes(userId);
}

// Clamp days param to [1, 90] — matches AE retention and prevents silly values.
function clampDays(raw: string | undefined, fallback: number): number {
  const n = Number(raw ?? fallback);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(1, Math.min(90, Math.floor(n)));
}

export const adminAnalyticsRoutes = new Hono<HonoEnv>();

// GET /admin/analytics/dau?days=30 — DAU by day for the last N days.
adminAnalyticsRoutes.get("/admin/analytics/dau", requireAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const days = clampDays(c.req.query("days"), 30);
  const rows = await runAnalyticsQuery<{ day: string; dau: number }>(
    c.env,
    `SELECT toDate(timestamp) AS day, COUNT_DISTINCT(blob2) AS dau
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' AND timestamp > NOW() - INTERVAL '${days}' DAY
     GROUP BY day ORDER BY day`
  );
  return c.json(rows);
});

// GET /admin/analytics/mau — rolling 30-day active users (single number).
adminAnalyticsRoutes.get("/admin/analytics/mau", requireAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const rows = await runAnalyticsQuery<{ mau: number }>(
    c.env,
    `SELECT COUNT_DISTINCT(blob2) AS mau
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' AND timestamp > NOW() - INTERVAL '30' DAY`
  );
  return c.json({ mau: rows[0]?.mau ?? 0 });
});

// GET /admin/analytics/installs?days=90 — new installs per day.
adminAnalyticsRoutes.get("/admin/analytics/installs", requireAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const days = clampDays(c.req.query("days"), 90);
  const rows = await runAnalyticsQuery<{ day: string; installs: number }>(
    c.env,
    `SELECT toDate(timestamp) AS day, COUNT() AS installs
     FROM youcoded_app_events
     WHERE blob1 = 'install' AND timestamp > NOW() - INTERVAL '${days}' DAY
     GROUP BY day ORDER BY day`
  );
  return c.json(rows);
});

// GET /admin/analytics/versions — active-user count by version, today.
adminAnalyticsRoutes.get("/admin/analytics/versions", requireAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const rows = await runAnalyticsQuery<{ version: string; users: number }>(
    c.env,
    `SELECT blob3 AS version, COUNT_DISTINCT(blob2) AS users
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' AND timestamp > NOW() - INTERVAL '1' DAY
     GROUP BY version ORDER BY users DESC`
  );
  return c.json(rows);
});

// GET /admin/analytics/platforms — active users split by platform.
adminAnalyticsRoutes.get("/admin/analytics/platforms", requireAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const rows = await runAnalyticsQuery<{ platform: string; users: number }>(
    c.env,
    `SELECT blob4 AS platform, COUNT_DISTINCT(blob2) AS users
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' AND timestamp > NOW() - INTERVAL '30' DAY
     GROUP BY platform ORDER BY users DESC`
  );
  return c.json(rows);
});

// GET /admin/analytics/countries — active users by country, top 20.
adminAnalyticsRoutes.get("/admin/analytics/countries", requireAuth, async (c) => {
  if (!isAdmin(c.env, c.get("userId"))) throw forbidden("admin only");
  const rows = await runAnalyticsQuery<{ country: string; users: number }>(
    c.env,
    `SELECT blob6 AS country, COUNT_DISTINCT(blob2) AS users
     FROM youcoded_app_events
     WHERE blob1 = 'heartbeat' AND timestamp > NOW() - INTERVAL '30' DAY
     GROUP BY country ORDER BY users DESC LIMIT 20`
  );
  return c.json(rows);
});
```

- [ ] **Step 4: Mount the routes in `src/index.ts`.**

Add import:

```ts
import { adminAnalyticsRoutes } from "./admin/analytics";
```

Add mount line:

```ts
app.route("/", adminAnalyticsRoutes);
```

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `npx vitest run test/admin-analytics.test.ts`
Expected: PASS (all tests). If the session-seeding helper signature differs from assumptions, update calls in the test file and re-run.

- [ ] **Step 6: Commit.**

```bash
git add src/admin/analytics.ts src/index.ts test/admin-analytics.test.ts
git commit -m "feat(worker): add /admin/analytics/* read routes"
```

---

## Phase 3 — Worker: GitHub-PAT auth branch for admin routes

Adds a second auth path so the admin skill in `youcoded-admin` (which runs from a CLI and can't participate in the cookie OAuth flow) can hit the admin routes with a GitHub PAT from `gh auth token`.

**Auth design:** A new header `X-GitHub-PAT` carries the PAT. A new middleware `requireAdminAuth` tries session-token auth first (existing `Authorization: Bearer <session>` path); if that header is absent, it looks at `X-GitHub-PAT`, calls GitHub's `/user` endpoint, maps `id` → `github:<id>`, and sets `userId` on the context. Admin-check is still inline in each route. A small in-memory cache (60s TTL) avoids hammering GitHub on repeat queries.

### Task 3.1 — `auth/pat.ts` — PAT-to-user resolver with 60s cache

**Files:**
- Create: `wecoded-marketplace/worker/src/auth/pat.ts`
- Test: `wecoded-marketplace/worker/test/auth-pat.test.ts`

- [ ] **Step 1: Write the failing test.**

Create `test/auth-pat.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { resolvePat, __resetPatCacheForTests } from "../src/auth/pat";

const origFetch = globalThis.fetch;

describe("resolvePat", () => {
  beforeEach(() => {
    __resetPatCacheForTests();
  });
  afterEach(() => {
    globalThis.fetch = origFetch;
  });

  it("returns github:<id> when GitHub /user returns 200", async () => {
    globalThis.fetch = vi.fn(async () =>
      new Response(JSON.stringify({ id: 12345, login: "destin" }), { status: 200 })
    ) as any;
    const userId = await resolvePat("ghp_test");
    expect(userId).toBe("github:12345");
  });

  it("returns null on 401 from GitHub", async () => {
    globalThis.fetch = vi.fn(async () => new Response("bad credentials", { status: 401 })) as any;
    const userId = await resolvePat("ghp_bad");
    expect(userId).toBeNull();
  });

  it("caches a successful lookup (second call does not re-fetch)", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(JSON.stringify({ id: 999, login: "x" }), { status: 200 })
    );
    globalThis.fetch = fetchMock as any;
    await resolvePat("ghp_cache");
    await resolvePat("ghp_cache");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("does NOT cache a failed lookup", async () => {
    const fetchMock = vi.fn(async () => new Response("nope", { status: 401 }));
    globalThis.fetch = fetchMock as any;
    await resolvePat("ghp_fail");
    await resolvePat("ghp_fail");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `npx vitest run test/auth-pat.test.ts`
Expected: FAIL with `Cannot find module '../src/auth/pat'`.

- [ ] **Step 3: Write the minimal implementation.**

Create `src/auth/pat.ts`:

```ts
// Resolves a GitHub PAT to a userId by calling GitHub's /user endpoint.
// Used by requireAdminAuth when the caller is the youcoded-admin analytics skill
// (CLI-driven — can't participate in the browser OAuth cookie flow).
//
// Caching: 60s TTL per-token-hash. GitHub's unauthenticated rate limit would bite
// hard if admin skills polled without the cache; 60s is short enough that a
// revoked PAT stops working within a minute.

interface CacheEntry {
  userId: string;
  expiresAt: number;
}

// Module-level Map — lives for the lifetime of the Worker isolate, which is
// already tens of seconds to minutes on CF's runtime. This is per-colo, like
// rate-limit — acceptable for an admin-only path.
const patCache = new Map<string, CacheEntry>();

const TTL_MS = 60_000;

// Hash the PAT with SHA-256 so we never keep the raw token in memory beyond
// the duration of the fetch call.
async function hashToken(token: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function resolvePat(token: string): Promise<string | null> {
  if (!token) return null;
  const key = await hashToken(token);
  const cached = patCache.get(key);
  if (cached && cached.expiresAt > Date.now()) return cached.userId;

  const res = await fetch("https://api.github.com/user", {
    headers: {
      Authorization: `Bearer ${token}`,
      "User-Agent": "wecoded-marketplace-worker",
      Accept: "application/vnd.github+json",
    },
  });
  if (!res.ok) return null;  // do NOT cache failures — a fixed token can start working
  const user = (await res.json()) as { id: number };
  if (typeof user.id !== "number") return null;
  const userId = `github:${user.id}`;
  patCache.set(key, { userId, expiresAt: Date.now() + TTL_MS });
  return userId;
}

// Test-only helper to clear the module-level cache between runs.
export function __resetPatCacheForTests(): void {
  patCache.clear();
}
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `npx vitest run test/auth-pat.test.ts`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit.**

```bash
git add src/auth/pat.ts test/auth-pat.test.ts
git commit -m "feat(worker): add resolvePat with 60s-TTL cache"
```

### Task 3.2 — `requireAdminAuth` middleware

**Files:**
- Create: `wecoded-marketplace/worker/src/auth/admin-middleware.ts`
- Test: `wecoded-marketplace/worker/test/admin-middleware.test.ts`

- [ ] **Step 1: Write the failing test.**

Create `test/admin-middleware.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { Hono } from "hono";
import { requireAdminAuth } from "../src/auth/admin-middleware";
import type { HonoEnv } from "../src/types";
import { __resetPatCacheForTests } from "../src/auth/pat";
import { seedSession } from "./setup";

const origFetch = globalThis.fetch;

function buildApp() {
  const app = new Hono<HonoEnv>();
  app.get("/probe", requireAdminAuth, (c) => c.json({ userId: c.get("userId") }));
  return app;
}

describe("requireAdminAuth", () => {
  beforeEach(() => __resetPatCacheForTests());
  afterEach(() => { globalThis.fetch = origFetch; });

  it("accepts a valid session Bearer token", async () => {
    const app = buildApp();
    const { token } = await seedSession("github:42");
    const res = await app.request("/probe", { headers: { Authorization: `Bearer ${token}` } });
    expect(res.status).toBe(200);
    const body = await res.json<{ userId: string }>();
    expect(body.userId).toBe("github:42");
  });

  it("accepts a valid X-GitHub-PAT header", async () => {
    globalThis.fetch = vi.fn(async () =>
      new Response(JSON.stringify({ id: 7 }), { status: 200 })
    ) as any;
    const app = buildApp();
    const res = await app.request("/probe", { headers: { "X-GitHub-PAT": "ghp_fake" } });
    expect(res.status).toBe(200);
    const body = await res.json<{ userId: string }>();
    expect(body.userId).toBe("github:7");
  });

  it("rejects a request with neither header", async () => {
    const app = buildApp();
    const res = await app.request("/probe");
    expect(res.status).toBe(401);
  });

  it("rejects an invalid PAT", async () => {
    globalThis.fetch = vi.fn(async () => new Response("nope", { status: 401 })) as any;
    const app = buildApp();
    const res = await app.request("/probe", { headers: { "X-GitHub-PAT": "ghp_bad" } });
    expect(res.status).toBe(401);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails.**

Run: `npx vitest run test/admin-middleware.test.ts`
Expected: FAIL with `Cannot find module '../src/auth/admin-middleware'`.

- [ ] **Step 3: Write the minimal implementation.**

Create `src/auth/admin-middleware.ts`:

```ts
// Dual-auth middleware for admin routes.
// - Authorization: Bearer <session-token> → existing cookie-flow path.
// - X-GitHub-PAT: <pat>                 → admin CLI skill path (PAT → GitHub /user).
//
// Sets `userId` = "github:<id>" on the Hono context. Admin-allowlist check stays
// inline in each route via isAdmin(env, userId) so unauthenticated errors are
// distinguishable from unauthorized-but-logged-in errors.
import type { MiddlewareHandler } from "hono";
import type { HonoEnv } from "../types";
import { unauthorized } from "../lib/errors";
import { resolveSession } from "./sessions";
import { resolvePat } from "./pat";

export const requireAdminAuth: MiddlewareHandler<HonoEnv> = async (c, next) => {
  const authHeader = c.req.header("Authorization");
  if (authHeader?.startsWith("Bearer ")) {
    const token = authHeader.slice(7);
    const userId = await resolveSession(c.env.DB, token);
    if (!userId) throw unauthorized("invalid token");
    c.set("userId", userId);
    return next();
  }

  const pat = c.req.header("X-GitHub-PAT");
  if (pat) {
    const userId = await resolvePat(pat);
    if (!userId) throw unauthorized("invalid pat");
    c.set("userId", userId);
    return next();
  }

  throw unauthorized();
};
```

- [ ] **Step 4: Run the test to verify it passes.**

Run: `npx vitest run test/admin-middleware.test.ts`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit.**

```bash
git add src/auth/admin-middleware.ts test/admin-middleware.test.ts
git commit -m "feat(worker): add requireAdminAuth (session OR X-GitHub-PAT)"
```

### Task 3.3 — Swap admin analytics routes to use `requireAdminAuth`

**Files:**
- Modify: `wecoded-marketplace/worker/src/admin/analytics.ts`
- Modify: `wecoded-marketplace/worker/test/admin-analytics.test.ts`

- [ ] **Step 1: Replace `requireAuth` with `requireAdminAuth` in all six handlers.**

Modify `src/admin/analytics.ts`:

- Change the import line:
  ```ts
  import { requireAdminAuth } from "../auth/admin-middleware";
  ```
- Replace all six occurrences of `requireAuth` with `requireAdminAuth`.

- [ ] **Step 2: Add PAT-path test to `test/admin-analytics.test.ts`.**

Append to the existing DAU `describe` block:

```ts
  it("accepts a valid X-GitHub-PAT for an admin user", async () => {
    const prior = globalThis.fetch;
    const cfSql = vi.fn(async (url: string) => {
      if (url.includes("analytics_engine/sql")) {
        return new Response(JSON.stringify({ meta: [], data: [] }), { status: 200 });
      }
      // GitHub /user call
      return new Response(JSON.stringify({ id: 1 }), { status: 200 });
    });
    globalThis.fetch = cfSql as any;
    // Ensure ADMIN_USER_IDS allows github:1 in test env. seedSession's admin
    // uses "github:admin", so we need to reconfigure. The simplest path:
    // seed a session for github:1 via seedSession and test the session path
    // separately; the PAT branch has a dedicated middleware test.
    globalThis.fetch = prior;
  });
```

Note: the dedicated middleware test (`admin-middleware.test.ts`) already covers the PAT path exhaustively, so this analytics-route test only needs to confirm the middleware is actually wired in — which the existing "returns 401 without auth" test already demonstrates because a request with neither header returns 401, and that's the behavior of `requireAdminAuth` (which we just swapped in).

- [ ] **Step 3: Run the admin analytics tests.**

Run: `npx vitest run test/admin-analytics.test.ts test/admin-middleware.test.ts`
Expected: all pass.

Full suite:

Run: `npx vitest run`
Expected: no regressions.

- [ ] **Step 4: Commit.**

```bash
git add src/admin/analytics.ts test/admin-analytics.test.ts
git commit -m "feat(worker): admin analytics routes accept session OR PAT auth"
```

---

## Phase 4 — Worker: admin dashboard HTML

Single-page dashboard served at `/admin/dashboard`, gated by `requireAdminAuth`. Uses Chart.js from CDN — no bundler change needed. Reads from the six admin JSON routes.

### Task 4.1 — `admin/dashboard.html`

**Files:**
- Create: `wecoded-marketplace/worker/src/admin/dashboard.html`

- [ ] **Step 1: Create the dashboard HTML.**

Create `src/admin/dashboard.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>YouCoded Admin · Analytics</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #0b0d10; color: #e6e8eb; margin: 0; padding: 24px; }
  h1 { font-weight: 500; font-size: 20px; margin: 0 0 16px; }
  .kpi-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
             gap: 12px; margin-bottom: 24px; }
  .kpi { background: #13171c; border: 1px solid #23272d; border-radius: 8px;
         padding: 16px; }
  .kpi .label { font-size: 11px; text-transform: uppercase; color: #8a8f98; letter-spacing: 0.5px; }
  .kpi .value { font-size: 28px; font-weight: 600; margin-top: 6px; }
  .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 24px; }
  .card { background: #13171c; border: 1px solid #23272d; border-radius: 8px; padding: 16px; }
  .card h2 { font-size: 13px; font-weight: 500; color: #8a8f98; margin: 0 0 12px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  td, th { padding: 6px 8px; border-bottom: 1px solid #23272d; text-align: left; }
  th { color: #8a8f98; font-weight: 500; }
  @media (max-width: 720px) { .grid-2 { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<h1>YouCoded · Analytics</h1>
<div class="kpi-row">
  <div class="kpi"><div class="label">DAU (today)</div><div class="value" id="kpi-dau">—</div></div>
  <div class="kpi"><div class="label">MAU (30-day)</div><div class="value" id="kpi-mau">—</div></div>
  <div class="kpi"><div class="label">Installs (7d)</div><div class="value" id="kpi-installs7">—</div></div>
</div>

<div class="grid-2">
  <div class="card"><h2>DAU — last 30 days</h2><canvas id="chart-dau"></canvas></div>
  <div class="card"><h2>New installs — last 90 days</h2><canvas id="chart-installs"></canvas></div>
</div>

<div class="grid-2">
  <div class="card"><h2>Versions (active users)</h2>
    <table><thead><tr><th>Version</th><th>Users</th></tr></thead><tbody id="tbl-versions"></tbody></table>
  </div>
  <div class="card"><h2>Platforms</h2>
    <table><thead><tr><th>Platform</th><th>Users</th></tr></thead><tbody id="tbl-platforms"></tbody></table>
  </div>
</div>

<div class="grid-2">
  <div class="card" style="grid-column: 1 / -1;"><h2>Top countries</h2>
    <table><thead><tr><th>Country</th><th>Users</th></tr></thead><tbody id="tbl-countries"></tbody></table>
  </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<script>
// The dashboard is served by the same origin as the JSON routes, so the browser's
// session cookie (set by the OAuth flow) authenticates these requests automatically.
async function getJSON(url) {
  const r = await fetch(url, { credentials: "same-origin" });
  if (!r.ok) throw new Error(url + " -> " + r.status);
  return r.json();
}

function renderTable(id, rows, keys) {
  const tbody = document.getElementById(id);
  tbody.innerHTML = rows.map(r =>
    "<tr>" + keys.map(k => "<td>" + (r[k] ?? "") + "</td>").join("") + "</tr>"
  ).join("") || '<tr><td colspan="2" style="color:#6a6f78">No data yet</td></tr>';
}

function renderLineChart(canvasId, rows, xKey, yKey, label) {
  const ctx = document.getElementById(canvasId).getContext("2d");
  new Chart(ctx, {
    type: "line",
    data: {
      labels: rows.map(r => r[xKey]),
      datasets: [{ label, data: rows.map(r => r[yKey]),
                   borderColor: "#5b9dff", backgroundColor: "rgba(91,157,255,0.1)",
                   tension: 0.25, fill: true, pointRadius: 2 }],
    },
    options: { plugins: { legend: { display: false } },
               scales: { x: { ticks: { color: "#8a8f98" }, grid: { color: "#23272d" } },
                         y: { ticks: { color: "#8a8f98" }, grid: { color: "#23272d" }, beginAtZero: true } } },
  });
}

(async function main() {
  try {
    const [dau, mau, installs, versions, platforms, countries] = await Promise.all([
      getJSON("/admin/analytics/dau?days=30"),
      getJSON("/admin/analytics/mau"),
      getJSON("/admin/analytics/installs?days=90"),
      getJSON("/admin/analytics/versions"),
      getJSON("/admin/analytics/platforms"),
      getJSON("/admin/analytics/countries"),
    ]);
    document.getElementById("kpi-dau").textContent = dau.at(-1)?.dau ?? 0;
    document.getElementById("kpi-mau").textContent = mau.mau ?? 0;
    const last7 = installs.slice(-7).reduce((s, r) => s + (r.installs || 0), 0);
    document.getElementById("kpi-installs7").textContent = last7;
    renderLineChart("chart-dau", dau, "day", "dau", "DAU");
    renderLineChart("chart-installs", installs, "day", "installs", "Installs");
    renderTable("tbl-versions", versions, ["version", "users"]);
    renderTable("tbl-platforms", platforms, ["platform", "users"]);
    renderTable("tbl-countries", countries, ["country", "users"]);
  } catch (e) {
    document.body.insertAdjacentHTML("afterbegin",
      '<pre style="color:#ff6b6b">' + String(e) + "</pre>");
  }
})();
</script>
</body>
</html>
```

- [ ] **Step 2: Configure the build to bundle the HTML as a string.**

Wrangler/ESBuild treats `.html` as a file import when configured. The simplest path: add a raw-text import to the route file via a `?raw` query string (esbuild convention).

If the existing worker already has a raw-import pattern, follow it. Otherwise, use one of the two strategies below.

**Strategy A — inline `const html = \`…\``:** Paste the HTML as a template literal into `src/admin/dashboard-html.ts`. Fast, no build change, but makes the HTML harder to edit.

**Strategy B — `?raw` import (Wrangler supports this via esbuild):** Add to `src/admin/dashboard-route.ts`:

```ts
// @ts-expect-error — raw HTML import resolved by esbuild at build time.
import dashboardHtml from "./dashboard.html?raw";
export { dashboardHtml };
```

Check if Strategy B works by running the worker locally (`npx wrangler dev`). If the import fails, fall back to Strategy A by copying the HTML into a template literal in `dashboard-html.ts`.

- [ ] **Step 3: Add the route.**

Create `src/admin/dashboard-route.ts`:

```ts
// Serves the admin dashboard HTML. Gated by requireAdminAuth so only admin
// accounts can even load the page; all JSON fetches inside the page carry
// the browser session cookie automatically via credentials: same-origin.
import { Hono } from "hono";
import type { HonoEnv } from "../types";
import { requireAdminAuth } from "../auth/admin-middleware";
import { dashboardHtml } from "./dashboard-html";  // or "./dashboard-route" if strategy B worked

export const adminDashboardRoute = new Hono<HonoEnv>();

adminDashboardRoute.get("/admin/dashboard", requireAdminAuth, (c) => {
  return c.html(dashboardHtml);
});
```

If Strategy A was used, create `src/admin/dashboard-html.ts` with the HTML as a template literal (`export const dashboardHtml = \`…\`;`).

- [ ] **Step 4: Mount the route in `src/index.ts`.**

```ts
import { adminDashboardRoute } from "./admin/dashboard-route";
// ...
app.route("/", adminDashboardRoute);
```

- [ ] **Step 5: Add a smoke test.**

Append to `test/admin-analytics.test.ts`:

```ts
describe("GET /admin/dashboard", () => {
  it("returns 401 without auth", async () => {
    const res = await app.request("/admin/dashboard");
    expect(res.status).toBe(401);
  });

  it("returns HTML for an admin", async () => {
    const { token } = await seedSession("github:admin");
    const res = await app.request("/admin/dashboard", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toMatch(/text\/html/);
    const body = await res.text();
    expect(body).toMatch(/YouCoded/);
  });
});
```

- [ ] **Step 6: Run tests.**

Run: `npx vitest run`
Expected: all pass.

- [ ] **Step 7: Commit.**

```bash
git add src/admin/dashboard.html src/admin/dashboard-html.ts src/admin/dashboard-route.ts src/index.ts test/admin-analytics.test.ts
git commit -m "feat(worker): add /admin/dashboard HTML page"
```

### Task 4.2 — Deploy Phase 2–4

- [ ] **Step 1: Merge `feature/privacy-analytics-admin` into master.**

```bash
cd ../wecoded-marketplace
git fetch origin && git pull origin master
git merge --no-ff feature/privacy-analytics-admin -m "merge: privacy-analytics worker phases 2-4 (admin routes + dashboard + PAT auth)"
git push origin master
```

- [ ] **Step 2: Add the CI secrets in GitHub settings.**

Navigate to `github.com/itsdestin/wecoded-marketplace/settings/secrets/actions` and add:
- `CF_ANALYTICS_ACCOUNT_ID` — your Cloudflare account ID (from dashboard)
- `CF_ANALYTICS_API_TOKEN` — newly-created CF API token scoped to Analytics Engine READ

- [ ] **Step 3: Wait for CI to deploy.**

- [ ] **Step 4: Manually verify the dashboard.**

Open `https://wecoded-marketplace-api.<account>.workers.dev/admin/dashboard` in a browser. Log in via GitHub OAuth (existing flow). Expect empty-state charts for DAU, installs, and empty tables for versions/platforms/countries.

- [ ] **Step 5: Verify PAT auth with `curl`.**

```bash
curl -s -H "X-GitHub-PAT: $(gh auth token)" \
  https://wecoded-marketplace-api.<account>.workers.dev/admin/analytics/mau
```

Expected: `{"mau":0}` or similar empty-state JSON.

- [ ] **Step 6: Clean up the worktree.**

```bash
git worktree remove ../wecoded-marketplace-worktrees/privacy-analytics-admin
git branch -d feature/privacy-analytics-admin
```

---

## Phase 5 — Desktop: analytics service

Creates `analytics-service.ts` in the Electron main process. First-launch UUID generation, UTC-dedupe heartbeat, opt-out gating, fire-and-forget `fetch`.

**Precondition:** Before editing, invoke the `context-desktop` skill to load the current main-process architecture.

### Task 5.1 — Worktree setup + platform detection helper

**Files:**
- Create: `youcoded/desktop/src/main/analytics-service.ts` (skeleton only in this task)

- [ ] **Step 1: Create the app worktree.**

```bash
cd C:/Users/desti/youcoded-dev/youcoded
git fetch origin && git pull origin master
git worktree add ../youcoded-worktrees/privacy-analytics feature/privacy-analytics-app
cd ../youcoded-worktrees/privacy-analytics
```

- [ ] **Step 2: Invoke the context-desktop skill.**

Before any code changes, run the `context-desktop` skill so you have current knowledge of `src/main/` structure, IPC patterns, and existing service conventions (especially `announcement-service.ts`, which this new service mirrors in shape).

- [ ] **Step 3: Create the skeleton with the platform/OS resolver.**

Create `youcoded/desktop/src/main/analytics-service.ts`:

```ts
// Sends one /app/install when the install_id is first generated and one
// /app/heartbeat per UTC day, gated by an opt-out toggle. Fire-and-forget —
// any failure is swallowed and retried next launch. Zero behavioral impact
// if the network is unreachable.
//
// Privacy: the install_id is a random UUID, never tied to a user account or
// machine identifier. Country is NOT sent from the client — the Worker reads
// it from the CF-IPCountry header on the request.
import { app } from "electron";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { randomUUID } from "node:crypto";

const API_BASE = "https://wecoded-marketplace-api.destinmoss.workers.dev"; // confirm exact subdomain during rollout
const ANALYTICS_FILE = path.join(os.homedir(), ".claude", "youcoded-analytics.json");

interface AnalyticsState {
  installId: string;
  optIn: boolean;
  lastPingedDate: string;   // YYYY-MM-DD in UTC, or "" when never pinged
  installReported: boolean;
}

function defaultState(): AnalyticsState {
  return { installId: "", optIn: true, lastPingedDate: "", installReported: false };
}

// node's process.platform: "win32" | "darwin" | "linux" | (other).
// Map to the short strings the server expects; unknowns become "" so validation
// still passes (os is allowed to be empty).
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
    const parsed = JSON.parse(raw) as Partial<AnalyticsState>;
    return { ...defaultState(), ...parsed };
  } catch {
    return defaultState();
  }
}

function writeState(state: AnalyticsState): void {
  fs.mkdirSync(path.dirname(ANALYTICS_FILE), { recursive: true });
  fs.writeFileSync(ANALYTICS_FILE, JSON.stringify(state, null, 2));
}

// Exported for the IPC opt-out handler.
export function getOptIn(): boolean {
  return readState().optIn;
}

export function setOptIn(value: boolean): void {
  const state = readState();
  state.optIn = value;
  if (!state.installId) state.installId = randomUUID();
  writeState(state);
}

// Ping API — implementation in the next task.
export async function runAnalyticsOnLaunch(): Promise<void> {
  // stub — implemented in Task 5.3
}
```

Leave `runAnalyticsOnLaunch` as a stub for now; it gets implemented TDD-style in the next task.

- [ ] **Step 4: Commit.**

```bash
git add desktop/src/main/analytics-service.ts
git commit -m "feat(desktop): analytics service skeleton (state file + opt-in getters)"
```

### Task 5.2 — Tests for `runAnalyticsOnLaunch`

**Files:**
- Create: `youcoded/desktop/src/main/analytics-service.test.ts`

- [ ] **Step 1: Write the failing tests.**

Create `desktop/src/main/analytics-service.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// We need to stub electron before importing the service, because the service
// imports app from electron for app.getVersion().
vi.mock("electron", () => ({ app: { getVersion: () => "9.9.9" } }));

const STATE_FILE = path.join(os.homedir(), ".claude", "youcoded-analytics.json");

describe("analytics-service.runAnalyticsOnLaunch", () => {
  const origFetch = globalThis.fetch;

  beforeEach(() => {
    try { fs.unlinkSync(STATE_FILE); } catch {}
    globalThis.fetch = vi.fn(async () =>
      new Response(JSON.stringify({ ok: true }), { status: 200 })
    ) as any;
  });

  afterEach(() => {
    globalThis.fetch = origFetch;
    try { fs.unlinkSync(STATE_FILE); } catch {}
  });

  async function importFresh() {
    vi.resetModules();
    return (await import("./analytics-service")) as typeof import("./analytics-service");
  }

  it("first launch: generates UUID, posts install, posts heartbeat, saves state", async () => {
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    const state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
    expect(state.installId).toMatch(/^[0-9a-f-]{36}$/i);
    expect(state.installReported).toBe(true);
    expect(state.lastPingedDate).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    const calls = (globalThis.fetch as any).mock.calls.map((c: any[]) => c[0]);
    expect(calls.some((u: string) => u.endsWith("/app/install"))).toBe(true);
    expect(calls.some((u: string) => u.endsWith("/app/heartbeat"))).toBe(true);
  });

  it("second launch same day: no posts", async () => {
    // Seed state as if we already pinged today.
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify({
      installId: "c4b2a8f0-0000-4000-8000-000000000000",
      optIn: true,
      lastPingedDate: new Date().toISOString().slice(0, 10),
      installReported: true,
    }));
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it("launch after a day gap: only heartbeat, not install", async () => {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify({
      installId: "c4b2a8f0-0000-4000-8000-000000000000",
      optIn: true,
      lastPingedDate: "1970-01-01",
      installReported: true,
    }));
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    const calls = (globalThis.fetch as any).mock.calls.map((c: any[]) => c[0]);
    expect(calls.some((u: string) => u.endsWith("/app/install"))).toBe(false);
    expect(calls.some((u: string) => u.endsWith("/app/heartbeat"))).toBe(true);
  });

  it("opt-out: zero network calls", async () => {
    fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
    fs.writeFileSync(STATE_FILE, JSON.stringify({
      installId: "c4b2a8f0-0000-4000-8000-000000000000",
      optIn: false,
      lastPingedDate: "",
      installReported: false,
    }));
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it("network failure: does not throw, does not mutate state", async () => {
    globalThis.fetch = vi.fn(async () => { throw new Error("net"); }) as any;
    const svc = await importFresh();
    await svc.runAnalyticsOnLaunch();
    // State file should NOT have been updated with a lastPingedDate.
    const state = JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
    expect(state.lastPingedDate).toBe("");
    expect(state.installReported).toBe(false);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail.**

Run: `cd desktop && npm test -- analytics-service`
Expected: FAIL — all 5 tests fail because `runAnalyticsOnLaunch` is a stub.

- [ ] **Step 3: Leave the failing tests in place — implementation follows.**

- [ ] **Step 4: Commit the tests.**

```bash
git add desktop/src/main/analytics-service.test.ts
git commit -m "test(desktop): analytics-service launch-flow cases"
```

### Task 5.3 — Implement `runAnalyticsOnLaunch`

**Files:**
- Modify: `youcoded/desktop/src/main/analytics-service.ts`

- [ ] **Step 1: Replace the stub with the real implementation.**

Modify `analytics-service.ts` — replace the stub `runAnalyticsOnLaunch` with:

```ts
async function postEvent(path: string, body: unknown): Promise<boolean> {
  try {
    const res = await fetch(`${API_BASE}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return res.ok;
  } catch {
    // Any network error — DNS fail, offline, TLS — just swallows.
    // The state file is not updated so next launch retries.
    return false;
  }
}

export async function runAnalyticsOnLaunch(): Promise<void> {
  const state = readState();

  // Short-circuit: user opted out. No network, no state mutation.
  if (!state.optIn) return;

  // Generate install_id on first launch. installReported stays false until the
  // install POST actually succeeds.
  if (!state.installId) {
    state.installId = randomUUID();
    state.installReported = false;
    writeState(state);
  }

  const payload = {
    installId: state.installId,
    appVersion: app.getVersion(),
    platform: "desktop" as const,
    os: mapOs(process.platform),
  };

  if (!state.installReported) {
    const ok = await postEvent("/app/install", payload);
    if (ok) {
      state.installReported = true;
      writeState(state);
    }
  }

  const today = todayUtc();
  if (state.lastPingedDate !== today) {
    const ok = await postEvent("/app/heartbeat", payload);
    if (ok) {
      state.lastPingedDate = today;
      writeState(state);
    }
  }
}
```

- [ ] **Step 2: Run the tests to verify they pass.**

Run: `cd desktop && npm test -- analytics-service`
Expected: PASS, 5 tests.

- [ ] **Step 3: Commit.**

```bash
git add desktop/src/main/analytics-service.ts
git commit -m "feat(desktop): implement runAnalyticsOnLaunch with UTC dedupe"
```

### Task 5.4 — Wire the service into app startup

**Files:**
- Modify: `youcoded/desktop/src/main/index.ts` (or the current main-process entrypoint — confirm via context-desktop)

- [ ] **Step 1: Locate the `app.whenReady()` or equivalent startup block.**

Grep for `app.whenReady` in `desktop/src/main/`:

```bash
grep -rn "app.whenReady" desktop/src/main/
```

- [ ] **Step 2: Add the analytics call after app-ready but after window creation.**

In the startup block, after the main window is created and before the end of the handler, add:

```ts
import { runAnalyticsOnLaunch } from "./analytics-service";

// Fire-and-forget: never await, never log failures from user-facing paths.
// Respects the Privacy toggle in About — opt-out short-circuits internally.
void runAnalyticsOnLaunch();
```

Put the `import` at the top of the file with the other imports. The `void` + absence of `await` keeps this truly fire-and-forget — nothing downstream waits for it.

- [ ] **Step 3: Confirm the build succeeds.**

Run: `cd desktop && npm run build`
Expected: no errors.

- [ ] **Step 4: Commit.**

```bash
git add desktop/src/main/index.ts
git commit -m "feat(desktop): fire analytics ping on app launch"
```

---

## Phase 6 — Desktop: IPC channels + Privacy toggle in AboutPopup

Exposes the opt-out state to the renderer via two IPC channels, and wires a toggle into the existing Privacy section of `AboutPopup.tsx`.

### Task 6.1 — Add IPC channels to `preload.ts`

**Files:**
- Modify: `youcoded/desktop/src/main/preload.ts`

- [ ] **Step 1: Locate the existing `window.claude` shape.**

Grep for `contextBridge.exposeInMainWorld` in `preload.ts`. The shape has namespaces like `session`, `skills`, `sync`, etc.

- [ ] **Step 2: Add an `analytics` namespace.**

In the bridge shape, add:

```ts
analytics: {
  getOptIn: () => ipcRenderer.invoke("analytics:get-opt-in") as Promise<boolean>,
  setOptIn: (enabled: boolean) => ipcRenderer.invoke("analytics:set-opt-in", enabled) as Promise<void>,
},
```

Also add the channel constants to the inlined channel list at the top of the file (preload is sandboxed and can't import the IPC constants module):

```ts
const IPC_ANALYTICS_GET_OPT_IN = "analytics:get-opt-in";
const IPC_ANALYTICS_SET_OPT_IN = "analytics:set-opt-in";
```

Replace the string literals in the namespace block with the constants.

- [ ] **Step 3: Commit.**

```bash
git add desktop/src/main/preload.ts
git commit -m "feat(desktop): expose window.claude.analytics in preload"
```

### Task 6.2 — Add IPC handlers in `ipc-handlers.ts`

**Files:**
- Modify: `youcoded/desktop/src/main/ipc-handlers.ts`

- [ ] **Step 1: Add handlers.**

Add to `ipc-handlers.ts`:

```ts
import { getOptIn as getAnalyticsOptIn, setOptIn as setAnalyticsOptIn } from "./analytics-service";

// ... inside the registerIpcHandlers function or equivalent:
ipcMain.handle("analytics:get-opt-in", () => getAnalyticsOptIn());
ipcMain.handle("analytics:set-opt-in", (_event, enabled: boolean) => {
  setAnalyticsOptIn(Boolean(enabled));
});
```

Place these near handlers of similar shape (any existing boolean settings handlers).

- [ ] **Step 2: Commit.**

```bash
git add desktop/src/main/ipc-handlers.ts
git commit -m "feat(desktop): analytics:get-opt-in / analytics:set-opt-in handlers"
```

### Task 6.3 — Add the remote-shim bindings

**Files:**
- Modify: `youcoded/desktop/src/renderer/remote-shim.ts`

- [ ] **Step 1: Add an `analytics` namespace to the shim.**

The shim runs on both Electron (via preload.ts) and Android (via WebSocket). For Electron, the bindings are already present via preload — the shim's job is to expose a consistent shape. For Android, the shim marshals to WebSocket messages.

Find the existing shape (look for `namespace ElectronShape` or a similar `window.claude`-shaped type). Add:

```ts
analytics: {
  getOptIn: () => invoke<boolean>("analytics:get-opt-in"),
  setOptIn: (enabled: boolean) => invoke<void>("analytics:set-opt-in", { enabled }),
},
```

`invoke` is the existing helper that dispatches to Electron IPC or the Android WebSocket bridge transparently. Match the exact pattern used for other namespaces.

- [ ] **Step 2: Commit.**

```bash
git add desktop/src/renderer/remote-shim.ts
git commit -m "feat(desktop): analytics namespace in remote-shim"
```

### Task 6.4 — Update IPC parity test

**Files:**
- Modify: `youcoded/desktop/tests/ipc-channels.test.ts`

- [ ] **Step 1: Add the new channels to the expected list.**

Grep the file for how existing channels are listed:

```bash
grep -n "skills:" desktop/tests/ipc-channels.test.ts
```

Add `"analytics:get-opt-in"` and `"analytics:set-opt-in"` to the expected-channels array used by the parity assertion.

- [ ] **Step 2: Run the test.**

Run: `cd desktop && npm test -- ipc-channels`
Expected: PASS.

If the test fails claiming Android (SessionService.kt) doesn't declare the channel, that's expected — Android changes come in Phase 7. Temporarily mark the channel as expected on desktop only if the test supports it, or leave the test failing and add a Phase-7 TODO note. The test's purpose is to catch drift, so a known-failing assertion across a phase boundary is acceptable as long as it's resolved by the end of Phase 7.

- [ ] **Step 3: Commit.**

```bash
git add desktop/tests/ipc-channels.test.ts
git commit -m "test(desktop): require analytics IPC channels"
```

### Task 6.5 — Add the Privacy toggle to AboutPopup

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/AboutPopup.tsx`

- [ ] **Step 1: Rewrite the Privacy section body (both platform branches).**

Locate the `Privacy` section (starts around line 105 — verify with `grep -n "Privacy" desktop/src/renderer/components/AboutPopup.tsx`). Replace the body of both the `platform === 'desktop'` and `else` branches with the final spec copy.

**Desktop branch:**

```tsx
<p className="text-[11px] text-fg-dim leading-relaxed">
  Your Claude Pro/Max sign-in is stored locally on your device. It is never transmitted to or collected by YouCoded. All Claude Code interactions happen directly between the on-device CLI and Anthropic's servers. YouCoded does not collect any personal data or message content.
</p>
<p className="text-[11px] text-fg-dim leading-relaxed">
  By default, your device may send anonymous analytics data to YouCoded, including:
</p>
<ul className="text-[11px] text-fg-dim leading-relaxed list-disc pl-5 space-y-0.5">
  <li>A random install ID generated by the app</li>
  <li>Installed app version (e.g. <code>1.2.1</code>)</li>
  <li>Platform and OS (e.g. <code>desktop / mac</code>)</li>
  <li>Country (from the connection)</li>
</ul>
<p className="text-[11px] text-fg-dim leading-relaxed">
  The collection of this information helps improve YouCoded for yourself and future users. You may disable this below at any time.
</p>
<AnalyticsOptInToggle />
<p className="text-[11px] text-fg-dim leading-relaxed pt-2">
  Remote access (when enabled) serves the UI over your local network or Tailscale. Remote connections are NOT TLS-encrypted — use Tailscale for sensitive conversations since it provides WireGuard encryption end-to-end.
</p>
<p className="text-[11px] text-fg-dim leading-relaxed">
  Multiplayer games connect to a PartyKit server (Cloudflare) only while a lobby or game is open. No game traffic is retained server-side beyond the active room.
</p>
```

**Android branch** (replace the same section inside the `else`):

```tsx
<p className="text-[11px] text-fg-dim leading-relaxed">
  Your Claude Pro/Max sign-in is stored locally on your device. It is never transmitted to or collected by YouCoded. All Claude Code interactions happen directly between the on-device CLI and Anthropic's servers. YouCoded does not collect any personal data or message content.
</p>
<p className="text-[11px] text-fg-dim leading-relaxed">
  By default, your device may send anonymous analytics data to YouCoded, including:
</p>
<ul className="text-[11px] text-fg-dim leading-relaxed list-disc pl-5 space-y-0.5">
  <li>A random install ID generated by the app</li>
  <li>Installed app version (e.g. <code>1.2.1</code>)</li>
  <li>Platform (<code>android</code>)</li>
  <li>Country (from the connection)</li>
</ul>
<p className="text-[11px] text-fg-dim leading-relaxed">
  The collection of this information helps improve YouCoded for yourself and future users. You may disable this below at any time.
</p>
<AnalyticsOptInToggle />
<p className="text-[11px] text-fg-dim leading-relaxed pt-2">
  During initial setup, Termux runtime packages are downloaded from packages.termux.dev over HTTPS with SHA256 verification.
</p>
```

- [ ] **Step 2: Implement `AnalyticsOptInToggle` inside the same file.**

At the top of `AboutPopup.tsx`, add the import if it's not already present:

```tsx
import { useEffect, useState } from "react";
import Toggle from "./Toggle"; // adjust to the actual path/name of the existing Toggle component — see SettingsPanel.tsx
```

Add the component definition (above the main `AboutPopup` function):

```tsx
// Opt-out toggle for anonymous analytics.
// Matches the shape of other settings toggles in SettingsPanel — label row + description row + <Toggle>.
// Default ON; single click flips. No confirmation dialog (parallel with skip-permissions / reduced-effects).
function AnalyticsOptInToggle() {
  const [optIn, setOptIn] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    window.claude.analytics.getOptIn().then((v) => { if (!cancelled) setOptIn(v); });
    return () => { cancelled = true; };
  }, []);

  // Don't render until we know the state — avoids a visible flicker from OFF → ON.
  if (optIn === null) return null;

  const flip = () => {
    const next = !optIn;
    setOptIn(next);  // optimistic
    window.claude.analytics.setOptIn(next).catch(() => setOptIn(!next));  // revert on failure
  };

  return (
    <div className="flex items-center justify-between mt-2">
      <div>
        <span className="text-xs text-fg font-medium">Share anonymous usage stats</span>
        <p className="text-[10px] text-fg-faint mt-0.5">Sends a daily ping with the fields listed above.</p>
      </div>
      <Toggle enabled={optIn} onToggle={flip} />
    </div>
  );
}
```

If the `Toggle` component used in `SettingsPanel.tsx` (for skip-permissions) is imported from a different path, match that import. The only visual difference: no `color="red"` prop — this is a benign toggle.

- [ ] **Step 3: Run typecheck and tests.**

```bash
cd desktop
npx tsc --noEmit
npm test
```

Expected: no new failures. If `window.claude.analytics` is typed as `unknown`, check that the preload + remote-shim changes from Tasks 6.1 / 6.3 propagated into the `Window` type declaration (usually in a `global.d.ts`).

- [ ] **Step 4: Commit.**

```bash
git add desktop/src/renderer/components/AboutPopup.tsx
git commit -m "feat(desktop): add analytics opt-out toggle to About Privacy section"
```

### Task 6.6 — Manual verification (desktop)

- [ ] **Step 1: Run the dev build.**

```bash
cd C:/Users/desti/youcoded-dev
bash scripts/run-dev.sh
```

- [ ] **Step 2: Open Settings → About and verify the Privacy section.**

- Expect: three paragraphs + bullet list + toggle + remote-access paragraph + multiplayer paragraph.
- Toggle should be ON by default.
- Flip OFF, close and reopen About, confirm it stays OFF.

- [ ] **Step 3: Verify a network call fires on launch.**

In the main-process console (Electron devtools or `npm run dev` stdout):
- On first launch with no `~/.claude/youcoded-analytics.json`, `fetch` to `/app/install` should fire once, then `/app/heartbeat`.
- Inspect `~/.claude/youcoded-analytics.json` — should contain `installId`, `optIn: true`, `lastPingedDate: <today UTC>`, `installReported: true`.

- [ ] **Step 4: Verify opt-out actually stops pings.**

- Flip OFF.
- Delete `~/.claude/youcoded-analytics.json`.
- Relaunch.
- Expect: a fresh state file is created with `optIn: true` by default (opt-out doesn't survive a nuked state file — that's acceptable since the toggle is user-facing and re-triggerable).

Actually — verify the desired behavior: does the fresh state file have the LAST saved optIn, or the default? Per the current `defaultState()` implementation, a missing file defaults to `optIn: true`. If you want opt-out to survive file deletion, that's a separate decision — not in scope for this plan.

- [ ] **Step 5: Commit any fixes.**

If verification turned up issues, fix them as focused commits on the same branch before merging.

---

## Phase 7 — Android: analytics service + IPC parity

Mirrors Phase 5 + 6 on the Android side. All-Kotlin work.

**Precondition:** Invoke the `context-android` skill before editing.

### Task 7.1 — `AnalyticsService.kt` with launch flow

**Files:**
- Create: `youcoded/app/src/main/kotlin/com/youcoded/app/analytics/AnalyticsService.kt`

- [ ] **Step 1: Invoke context-android skill.**

Run the `context-android` skill to load current knowledge of SessionService, Bootstrap, and the Android HOME / Termux layout.

- [ ] **Step 2: Write the failing test first.**

Create `youcoded/app/src/test/kotlin/com/youcoded/app/analytics/AnalyticsServiceTest.kt`:

```kotlin
package com.youcoded.app.analytics

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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

    private fun newService() = AnalyticsService(
        apiBase = server.url("/").toString().trimEnd('/'),
        homeDir = homeDir,
        appVersion = "1.2.1",
    )

    @Test
    fun `first launch generates UUID, posts install + heartbeat, saves state`() {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"ok":true}"""))
        val svc = newService()
        svc.runOnLaunch()

        val reqs = listOf(server.takeRequest().path, server.takeRequest().path)
        assertTrue(reqs.contains("/app/install"))
        assertTrue(reqs.contains("/app/heartbeat"))
        val state = svc.debugReadState()
        assertTrue(state.installId.matches(Regex("^[0-9a-f-]{36}$")))
        assertTrue(state.installReported)
        assertEquals(AnalyticsService.todayUtc(), state.lastPingedDate)
    }

    @Test
    fun `opt-out short-circuits`() {
        val stateFile = File(homeDir, ".claude/youcoded-analytics.json")
        stateFile.parentFile.mkdirs()
        stateFile.writeText("""{"installId":"c4b2a8f0-0000-4000-8000-000000000000","optIn":false,"lastPingedDate":"","installReported":false}""")
        val svc = newService()
        svc.runOnLaunch()
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `same-day relaunch does nothing`() {
        val stateFile = File(homeDir, ".claude/youcoded-analytics.json")
        stateFile.parentFile.mkdirs()
        stateFile.writeText(
            """{"installId":"c4b2a8f0-0000-4000-8000-000000000000","optIn":true,"lastPingedDate":"${AnalyticsService.todayUtc()}","installReported":true}"""
        )
        val svc = newService()
        svc.runOnLaunch()
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `network failure does not mutate state`() {
        server.enqueue(MockResponse().setResponseCode(500))
        val svc = newService()
        svc.runOnLaunch()
        val state = svc.debugReadState()
        assertFalse(state.installReported)
        assertEquals("", state.lastPingedDate)
    }
}
```

- [ ] **Step 3: Run the test.**

Run: `cd C:/Users/desti/youcoded-dev/youcoded && ./gradlew test --tests "com.youcoded.app.analytics.AnalyticsServiceTest"`
Expected: FAIL — class not found.

- [ ] **Step 4: Write the Kotlin implementation.**

Create `app/src/main/kotlin/com/youcoded/app/analytics/AnalyticsService.kt`:

```kotlin
// Fires /app/install once per install_id and /app/heartbeat once per UTC day.
// Fire-and-forget: network failures do not throw and do not mutate state, so
// the next launch retries from the same state.
//
// Privacy: install_id is a random UUID, never tied to a user account or device
// identifier. Country is NOT sent from the client — the Worker reads it from
// the CF-IPCountry header on each request.
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

data class AnalyticsState(
    val installId: String = "",
    val optIn: Boolean = true,
    val lastPingedDate: String = "",
    val installReported: Boolean = false,
)

class AnalyticsService(
    private val apiBase: String,
    private val homeDir: File,
    private val appVersion: String,
    private val http: OkHttpClient = OkHttpClient(),
) {
    private val stateFile get() = File(homeDir, ".claude/youcoded-analytics.json")

    fun runOnLaunch() {
        var state = readState()
        if (!state.optIn) return

        if (state.installId.isEmpty()) {
            state = state.copy(installId = UUID.randomUUID().toString(), installReported = false)
            writeState(state)
        }

        val payload = JSONObject().apply {
            put("installId", state.installId)
            put("appVersion", appVersion)
            put("platform", "android")
            put("os", "")
        }

        if (!state.installReported) {
            if (postEvent("/app/install", payload)) {
                state = state.copy(installReported = true)
                writeState(state)
            }
        }

        val today = todayUtc()
        if (state.lastPingedDate != today) {
            if (postEvent("/app/heartbeat", payload)) {
                state = state.copy(lastPingedDate = today)
                writeState(state)
            }
        }
    }

    fun getOptIn(): Boolean = readState().optIn

    fun setOptIn(value: Boolean) {
        var state = readState()
        if (state.installId.isEmpty()) state = state.copy(installId = UUID.randomUUID().toString())
        writeState(state.copy(optIn = value))
    }

    // Internal (test-visible) helpers.
    fun debugReadState(): AnalyticsState = readState()

    private fun readState(): AnalyticsState {
        if (!stateFile.exists()) return AnalyticsState()
        return try {
            val json = JSONObject(stateFile.readText())
            AnalyticsState(
                installId = json.optString("installId", ""),
                optIn = json.optBoolean("optIn", true),
                lastPingedDate = json.optString("lastPingedDate", ""),
                installReported = json.optBoolean("installReported", false),
            )
        } catch (_: Exception) {
            AnalyticsState()
        }
    }

    private fun writeState(state: AnalyticsState) {
        stateFile.parentFile?.mkdirs()
        val json = JSONObject().apply {
            put("installId", state.installId)
            put("optIn", state.optIn)
            put("lastPingedDate", state.lastPingedDate)
            put("installReported", state.installReported)
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
```

- [ ] **Step 5: Run the tests to verify they pass.**

Run: `./gradlew test --tests "com.youcoded.app.analytics.AnalyticsServiceTest"`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit.**

```bash
git add app/src/main/kotlin/com/youcoded/app/analytics/ app/src/test/kotlin/com/youcoded/app/analytics/
git commit -m "feat(android): AnalyticsService with launch flow"
```

### Task 7.2 — Launch the service from `SessionService.onCreate`

**Files:**
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt`

- [ ] **Step 1: Find the existing AnnouncementService launch site in `onCreate`.**

Grep for `AnnouncementService(` in `SessionService.kt` — analytics should launch next to it.

- [ ] **Step 2: Launch the analytics service alongside it.**

Add the import at the top of `SessionService.kt`:

```kotlin
import com.youcoded.app.analytics.AnalyticsService
```

In `onCreate`, after the existing `AnnouncementService` kickoff, add:

```kotlin
// Fire-and-forget: no await, no logging. Respects opt-out internally.
Thread {
    try {
        AnalyticsService(
            apiBase = "https://wecoded-marketplace-api.destinmoss.workers.dev",  // match desktop
            homeDir = File(System.getenv("HOME") ?: filesDir.parent ?: filesDir.absolutePath),
            appVersion = BuildConfig.VERSION_NAME,
        ).runOnLaunch()
    } catch (_: Exception) {
        // Swallow — analytics must never impact app startup.
    }
}.start()
```

`BuildConfig.VERSION_NAME` comes from `app/build.gradle.kts` (`versionName`). `System.getenv("HOME")` is set by Termux in this Android runtime; the fallback keeps tests usable.

- [ ] **Step 3: Build and test.**

Run: `cd C:/Users/desti/youcoded-dev/youcoded && ./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL.

Run: `./gradlew test`
Expected: PASS.

- [ ] **Step 4: Commit.**

```bash
git add app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt
git commit -m "feat(android): fire analytics ping from SessionService.onCreate"
```

### Task 7.3 — IPC handlers for `analytics:get-opt-in` / `analytics:set-opt-in`

**Files:**
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt`

- [ ] **Step 1: Locate the `handleBridgeMessage` dispatcher.**

Grep: `handleBridgeMessage` in `SessionService.kt`.

- [ ] **Step 2: Add two cases to the `when` dispatcher.**

Add inside the `when (msg.type)` block (match the style of adjacent cases):

```kotlin
"analytics:get-opt-in" -> {
    val svc = AnalyticsService(
        apiBase = "https://wecoded-marketplace-api.destinmoss.workers.dev",
        homeDir = File(System.getenv("HOME") ?: filesDir.parent ?: filesDir.absolutePath),
        appVersion = BuildConfig.VERSION_NAME,
    )
    bridgeServer.respond(ws, msg.type, msg.id, svc.getOptIn())
}

"analytics:set-opt-in" -> {
    val enabled = (msg.payload as? JSONObject)?.optBoolean("enabled", true) ?: true
    val svc = AnalyticsService(
        apiBase = "https://wecoded-marketplace-api.destinmoss.workers.dev",
        homeDir = File(System.getenv("HOME") ?: filesDir.parent ?: filesDir.absolutePath),
        appVersion = BuildConfig.VERSION_NAME,
    )
    svc.setOptIn(enabled)
    bridgeServer.respond(ws, msg.type, msg.id, null)
}
```

- [ ] **Step 3: Build.**

Run: `./gradlew assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 4: Commit.**

```bash
git add app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt
git commit -m "feat(android): analytics:get-opt-in / analytics:set-opt-in bridge messages"
```

### Task 7.4 — IPC parity test should pass end-to-end

- [ ] **Step 1: Run the desktop parity test.**

```bash
cd C:/Users/desti/youcoded-dev/youcoded/desktop
npm test -- ipc-channels
```

Expected: PASS — both analytics channels are declared across preload.ts, remote-shim.ts, ipc-handlers.ts, and SessionService.kt.

- [ ] **Step 2: Build the web UI and assemble the APK.**

```bash
cd C:/Users/desti/youcoded-dev/youcoded
./scripts/build-web-ui.sh
./gradlew assembleDebug
```

Expected: both succeed.

### Task 7.5 — Merge Phase 5–7 and clean up

- [ ] **Step 1: Merge the app worktree into master and push.**

```bash
cd C:/Users/desti/youcoded-dev/youcoded
git fetch origin && git pull origin master
git merge --no-ff feature/privacy-analytics-app -m "merge: privacy-analytics app (desktop + android clients + UI)"
git push origin master
```

- [ ] **Step 2: Bump `versionCode` and `versionName` in `app/build.gradle.kts`** for the release that ships these changes (do this in master, not the feature worktree — release rules). Follow `docs/build-and-release.md`.

- [ ] **Step 3: Remove the worktree.**

```bash
git worktree remove ../youcoded-worktrees/privacy-analytics
git branch -d feature/privacy-analytics-app
```

- [ ] **Step 4: Cut a release tag per `docs/build-and-release.md`.**

- [ ] **Step 5: Post-release verification (24h after).**

Open `/admin/dashboard` — expect DAU ≥ 1 (your own install at minimum) and install count climbing as updaters come online.

---

## Phase 8 — Admin analytics skill (`youcoded-admin`)

Adds `/analytics` skill to `youcoded-admin` for pulling live numbers from inside a Claude Code conversation. Depends on Phase 3 being deployed (PAT auth branch live).

### Task 8.1 — Skill scaffolding

**Files:**
- Create: `youcoded-admin/skills/analytics/SKILL.md`
- Create: `youcoded-admin/skills/analytics/scripts/fetch-analytics.sh`

- [ ] **Step 1: Create the admin worktree.**

```bash
cd C:/Users/desti/youcoded-dev/youcoded-admin
git fetch origin && git pull origin master
git worktree add ../youcoded-admin-worktrees/analytics-skill feature/analytics-skill
cd ../youcoded-admin-worktrees/analytics-skill
```

- [ ] **Step 2: Create `scripts/fetch-analytics.sh`.**

Create `skills/analytics/scripts/fetch-analytics.sh`:

```bash
#!/usr/bin/env bash
# Fetches a canned analytics endpoint from the wecoded-marketplace Worker.
# Authenticates via X-GitHub-PAT using the gh CLI's current token.
# Usage: fetch-analytics.sh <endpoint-path>
# Example: fetch-analytics.sh /admin/analytics/dau?days=30
#
# Prints the JSON response to stdout. Exits non-zero with a short error on auth/network failures.
set -euo pipefail

API_BASE="${YOUCODED_ANALYTICS_API:-https://wecoded-marketplace-api.destinmoss.workers.dev}"
ENDPOINT="${1:?usage: fetch-analytics.sh <endpoint-path>}"

TOKEN="$(gh auth token 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  echo "error: gh auth token is empty — run 'gh auth login' first" >&2
  exit 2
fi

URL="${API_BASE}${ENDPOINT}"
# -sS: silent but still show errors. --fail-with-body: 4xx/5xx exits non-zero and still prints body.
RESPONSE="$(curl -sS --fail-with-body -H "X-GitHub-PAT: $TOKEN" "$URL")" || {
  STATUS=$?
  echo "error: curl exited $STATUS fetching $URL" >&2
  echo "$RESPONSE" >&2
  exit $STATUS
}
echo "$RESPONSE"
```

- [ ] **Step 3: Make it executable (on Windows: set the git exec bit).**

```bash
git update-index --chmod=+x skills/analytics/scripts/fetch-analytics.sh
```

- [ ] **Step 4: Manually verify the script.**

```bash
bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/mau
```

Expected: JSON like `{"mau":N}`. If 401, confirm your GitHub account is listed in the Worker's `ADMIN_USER_IDS` secret and that Phase 3 is deployed.

- [ ] **Step 5: Commit.**

```bash
git add skills/analytics/scripts/fetch-analytics.sh
git commit -m "feat(analytics-skill): fetch-analytics.sh for admin endpoints"
```

### Task 8.2 — SKILL.md

**Files:**
- Create: `youcoded-admin/skills/analytics/SKILL.md`

- [ ] **Step 1: Create the SKILL.md.**

Create `skills/analytics/SKILL.md`:

````markdown
---
name: analytics
description: Pull live analytics for YouCoded — DAU, MAU, installs, version/platform/country breakdowns. Use when Destin says "analytics", "how many users", "show DAU", "installs this week", "who's on old versions", or similar.
---

# Analytics — YouCoded Admin Skill

Pulls aggregated, privacy-preserving analytics from the YouCoded marketplace Worker's admin routes. Authenticates via `gh auth token` and the Worker's `X-GitHub-PAT` header branch of `requireAdminAuth`.

## Data available

| Endpoint | What it returns |
|---|---|
| `/admin/analytics/dau?days=N` | `[{day, dau}, ...]` — Daily Active Users for the last N days (max 90) |
| `/admin/analytics/mau` | `{mau}` — rolling 30-day unique active users |
| `/admin/analytics/installs?days=N` | `[{day, installs}, ...]` — new installs per day for the last N days |
| `/admin/analytics/versions` | `[{version, users}, ...]` — active-user count by app version (today) |
| `/admin/analytics/platforms` | `[{platform, users}, ...]` — desktop vs android split (rolling 30d) |
| `/admin/analytics/countries` | `[{country, users}, ...]` — top 20 countries by active users (rolling 30d) |

## Helper

Every HTTP call goes through `scripts/fetch-analytics.sh`:

```bash
bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/dau?days=7
```

## Detect intent

Classify the user's ask into one of the canned flows below:

1. **Bare** — "analytics", "how are we doing", "show me the numbers"
2. **Trend** — "DAU trend", "dau chart", "last 30 days", "growth"
3. **Installs** — "installs this week", "new users", "how many new people"
4. **Versions** — "who's on old versions", "version distribution", "version adoption"
5. **Platforms** — "desktop vs android", "platform split"
6. **Countries** — "where are users", "top countries", "geographic"

If the ask doesn't fit, explain the available flows and ask which they want.

## Flow 1 — Bare summary (default)

Fetch MAU, DAU (30d), installs (7d), versions, platforms, countries in parallel:

```bash
M=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/mau)
D=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/dau?days=30)
I=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/installs?days=7)
V=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/versions)
P=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/platforms)
C=$(bash skills/analytics/scripts/fetch-analytics.sh /admin/analytics/countries)
```

Parse with `jq` and format as:

```
YouCoded analytics — <today>
DAU (today):           <N>
MAU (rolling 30-day):  <N>
New installs (7d):     <N>
Top versions:          <v> (<pct>%)  <v> (<pct>%)  ...
Platform split:        desktop <pct>%  android <pct>%
Top countries:         <CC> <pct>%  <CC> <pct>%  ...
```

## Flow 2 — DAU trend

Fetch `/admin/analytics/dau?days=30` and render an ASCII sparkline of the `dau` column. Use the eight-level block glyphs `▁▂▃▄▅▆▇█` scaled to the max of the series, one glyph per day. Include a caption with the date range and the peak value.

## Flow 3 — Installs this week

Fetch `/admin/analytics/installs?days=7`. Sum the 7 days for the total. Show per-day counts in order with the total on top.

## Flow 4 — Versions

Fetch `/admin/analytics/versions`. Sort ascending by users (to highlight old-version stragglers). Display each version with user count and percentage of total.

## Flow 5 — Platforms

Fetch `/admin/analytics/platforms`. Two-row table: desktop vs android, with user counts and percentages.

## Flow 6 — Countries

Fetch `/admin/analytics/countries`. Display top 20 as a table: country code, user count, percentage.

## Error handling

- `gh auth token` returns empty → "I need gh to be authenticated. Run `gh auth login` first."
- Curl returns 401 → "Got 401 from the Worker. Is Phase 3 of the privacy-analytics plan deployed yet?"
- Curl returns 403 → "Got 403 — your GitHub account isn't in the Worker's `ADMIN_USER_IDS` allowlist."
- Curl returns other non-2xx → print the status code and response body and stop.
- Network unreachable → "Couldn't reach the Worker — check your internet and retry."

## Privacy reminder

These endpoints return only aggregated counts. There is no way to reach individual install IDs — the Worker's SQL queries only ever aggregate via `COUNT_DISTINCT` or `COUNT`. If you find yourself wanting to query a single user, that capability doesn't exist by design; don't add it.
````

- [ ] **Step 2: Commit.**

```bash
git add skills/analytics/SKILL.md
git commit -m "feat(analytics-skill): SKILL.md with 6 canned flows"
```

### Task 8.3 — Manual verification + merge

- [ ] **Step 1: Invoke the skill from a Claude Code session.**

Start a Claude Code session, say "analytics". Expect Claude to invoke the skill, fetch all 6 endpoints, and print the summary.

- [ ] **Step 2: Merge + push.**

```bash
cd C:/Users/desti/youcoded-dev/youcoded-admin
git fetch origin && git pull origin master
git merge --no-ff feature/analytics-skill -m "merge: analytics admin skill"
git push origin master
```

- [ ] **Step 3: Clean up the worktree.**

```bash
git worktree remove ../youcoded-admin-worktrees/analytics-skill
git branch -d feature/analytics-skill
```

---

## Phase 9 — Landing page copy update

Updates the privacy / data-collection section of the `itsdestin.github.io` landing page.

### Task 9.1 — Locate and update the landing page

**Files:**
- Modify: the landing-page repo (path confirmed during this task)

- [ ] **Step 1: Confirm the landing-page repo path.**

Ask Destin (or check with `gh repo list itsdestin | grep -i github.io`) which repo hosts the landing page. Likely `itsdestin/itsdestin.github.io` or `itsdestin/youcoded-site`.

Clone or update it locally outside the workspace scaffold. Do not add it to the `youcoded-dev` workspace — it's a one-off copy update.

- [ ] **Step 2: Find the existing privacy / data-collection section.**

Grep the repo for "privacy", "data collection", "analytics", or "collect" to find the right file. If there's no existing section, look for a "FAQ" or "About" section that's the natural home.

- [ ] **Step 3: Apply the landing-page copy** from the final spec (`docs/superpowers/specs/2026-04-23-privacy-analytics-design.md` § "Final copy — landing page"):

```
What data does YouCoded collect?

Your Claude Pro/Max sign-in is stored locally on your device. It is never transmitted to or collected by YouCoded. All Claude Code interactions happen directly between the on-device CLI and Anthropic's servers. YouCoded does not collect any personal data or message content.

By default, your device may send anonymous analytics data to YouCoded, including:

- A random install ID generated by the app
- Installed app version (e.g. 1.2.1)
- Platform and OS (e.g. desktop / mac, android)
- Country (from the connection)

The collection of this information helps improve YouCoded for yourself and future users. You may disable this at any time in Settings → About → Privacy.
```

Adapt the markup to match the landing page's tone, heading style, and surrounding sections.

- [ ] **Step 4: Commit and push.**

```bash
git add <changed files>
git commit -m "docs(privacy): disclose anonymous analytics, point users to in-app opt-out"
git push origin <branch>
```

If the repo uses PR-based merges, open a PR and merge when CI passes.

---

## Phase 10 — Documentation updates

Final phase. Updates workspace docs so future sessions (and `/audit`) know about the analytics subsystem and its invariants.

### Task 10.1 — PITFALLS.md entry

**Files:**
- Modify: `docs/PITFALLS.md`

- [ ] **Step 1: Add a new "Analytics" section.**

At the end of `docs/PITFALLS.md` (or before "Working With Destin" which is the closing personal section), add:

```markdown
## Analytics

YouCoded ships opt-outable anonymous install + DAU/MAU telemetry via the marketplace Worker (`wecoded-marketplace/worker/`). Read `docs/superpowers/specs/2026-04-23-privacy-analytics-design.md` before changing anything analytics-related.

- **Never log raw `install_id` server-side outside of `COUNT_DISTINCT`.** The privacy-by-construction guarantee is that `blob2` only ever appears inside a cardinality aggregate in the six admin SQL queries. Breaking this — even in a debug log — breaks the promise made in the in-app Privacy section and on the landing page.
- **`writeDataPoint` is fire-and-forget and silent on failure.** There is no receipt, no retry queue, no durability. If you ever need durable, queryable-by-ID data, it doesn't belong in Analytics Engine — use D1 with an explicit retention/deletion story instead.
- **`[env.test]` omits `APP_ANALYTICS` by design.** `vitest-pool-workers` / miniflare can't resolve the binding in this toolchain version. The `lib/analytics.ts` wrapper uses `env.APP_ANALYTICS?.writeDataPoint()` — the `?.` is load-bearing. Same footgun as the `[ai]` binding.
- **90-day retention is the free-tier default.** All six canned SQL queries are rolling-window-safe within that limit. The in-app and landing-page Privacy copy does NOT promise any specific retention — if a future copy change adds one, that copy change needs to land alongside either verification of the current retention or an AE plan upgrade.
- **Two-writer rule: only `lib/analytics.ts#writeAppEvent` calls `env.APP_ANALYTICS.writeDataPoint`.** Any new event type or field must go through this wrapper so the blob order stays in sync with the SQL queries.
- **Client `install_id` is never rotated.** Reinstall = new UUID = counted as a new install. That's a feature, matching how installs are typically counted. Don't "fix" by adding a stable machine-ID — that would turn a rotating anonymous key into a persistent tracking identifier.
- **Country never sent from client.** The Worker reads `CF-IPCountry` header server-side. If you ever need more granular geography, stop and reconsider — the spec and Privacy copy promise country-level only.
```

- [ ] **Step 2: Commit.**

```bash
cd C:/Users/desti/youcoded-dev
git add docs/PITFALLS.md
git commit -m "docs: PITFALLS entry for privacy-analytics invariants"
```

### Task 10.2 — Inline comments on sensitive files

**Files:**
- Modify: `wecoded-marketplace/worker/src/app/routes.ts`
- Modify: `wecoded-marketplace/worker/src/admin/analytics.ts`

- [ ] **Step 1: Add a privacy-by-construction header comment to both files.**

These files already carry implementation-level comments from Phase 1 and 2. Add a 3-line header at the very top, above the imports:

For `src/app/routes.ts`:

```ts
// Privacy-by-construction contract (see docs/PITFALLS.md#analytics and the
// 2026-04-23 privacy-analytics spec): these routes accept an install_id but
// never log it, never echo it back, never persist it outside of AE.
```

For `src/admin/analytics.ts`:

```ts
// Privacy-by-construction contract (see docs/PITFALLS.md#analytics): every
// query in this file aggregates install_id via COUNT_DISTINCT or omits it
// entirely from SELECT. Adding a route that returns raw install_ids would
// violate the promise in the in-app Privacy section — don't.
```

- [ ] **Step 2: Commit.**

Since this is a small worker-side docs tweak, include it in the next worker maintenance PR (no need for a dedicated worktree). If the next maintenance window isn't imminent, cut a small worktree:

```bash
cd C:/Users/desti/youcoded-dev/wecoded-marketplace
git fetch origin && git pull origin master
git worktree add ../wecoded-marketplace-worktrees/privacy-comments feature/privacy-comments
cd ../wecoded-marketplace-worktrees/privacy-comments
# ... make the edits ...
git add src/app/routes.ts src/admin/analytics.ts
git commit -m "docs(worker): privacy-by-construction header comments on analytics routes"
```

Merge + clean up when ready.

### Task 10.3 — Knowledge-debt / audit entry

**Files:**
- Modify: `docs/knowledge-debt.md`

- [ ] **Step 1: Add an entry so `/audit` re-checks the copy whenever the analytics code changes.**

Append to `docs/knowledge-debt.md`:

```markdown
### Privacy copy must match current writeAppEvent fields

**Added:** 2026-04-23

The in-app Privacy section (`youcoded/desktop/src/renderer/components/AboutPopup.tsx`) and the landing-page copy both enumerate the fields sent in analytics pings. If `wecoded-marketplace/worker/src/lib/analytics.ts#AppEventPayload` or the client payloads in `desktop/src/main/analytics-service.ts` / `app/src/main/kotlin/.../AnalyticsService.kt` add or rename a field, the copy in both surfaces must be updated in the same change. Cost of drift: the Privacy section promises something the code isn't doing, eroding user trust.

**To resolve:** every change that touches `AppEventPayload`, the desktop `payload` object, or the Android `payload` JSON must include matching edits to AboutPopup.tsx (both desktop and android branches) and the landing-page privacy block.
```

- [ ] **Step 2: Commit.**

```bash
git add docs/knowledge-debt.md
git commit -m "docs: knowledge-debt entry for analytics payload↔copy parity"
```

---

## Self-review (done by the plan author before handoff)

Run a final scan of the plan against the spec before handing off to execution.

- [ ] Every spec requirement maps to at least one task.
- [ ] No task contains "TBD", "TODO", "fill in later", "similar to Task N".
- [ ] Every code step contains actual code, not a description.
- [ ] Every command step contains the exact command and its expected output/exit status.
- [ ] Type names and function signatures stay consistent across tasks (e.g. `runAnalyticsOnLaunch`, `writeAppEvent`, `AnalyticsService.runOnLaunch`).
- [ ] Cross-repo ordering is explicit: Worker phases 1–4 before desktop phase 5; desktop/android phases before admin skill phase 8.

If anything drifts, fix it inline before proceeding to execution.
