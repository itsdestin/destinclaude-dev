# Marketplace App Integration Implementation Plan (Plan 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **This is Plan 2 of a 2-plan feature.** Plan 1 (`2026-04-12-marketplace-backend.md`) is **complete and deployed**. This plan wires the apps to that backend. Read Plan 1's "Known caveats" and `docs/PITFALLS.md` "Cloudflare Workers (Marketplace Backend)" section before starting.

**Goal:** Wire the desktop (Electron + React) and Android (Kotlin + WebView) apps to the already-deployed marketplace backend so users can sign in with GitHub, install counts tick up, ratings submit with install-gate, theme likes toggle, and reports queue for moderation. Ship as one coherent feature, not in slivers.

**Architecture:**
- The backend is live at `https://wecoded-marketplace-api.destinj101.workers.dev`. Auth is GitHub OAuth device-code (app opens browser, polls for token, stores bearer token locally).
- Desktop stores the token in Electron `userData` via a new `marketplace-auth-store.ts`. Android stores it in `SharedPreferences` via a new bridge message type. Same token is sent as `Authorization: Bearer <token>` on all write endpoints.
- The existing marketplace UI (`components/Marketplace.tsx`, `components/SkillCard.tsx`) gains install counts + star ratings from a new live stats fetcher that replaces the static `stats.json` read.
- New rating/like/report components are all plain React — they work on Android automatically via the shared React bundle. Only the IPC message types need Kotlin-side handlers on Android.

**Tech Stack:**
- React 18 + TypeScript (existing)
- Electron IPC (`ipcMain.handle`) + Android `LocalBridgeServer` WebSocket (existing bridge pattern)
- `electron-store` for token persistence on desktop (already a dependency per `package.json`)
- Vitest for React component tests (existing harness)

**Repo locations:**
- Desktop: `youcoded/desktop/src/` (both `main/` and `renderer/`)
- Android: `youcoded/app/src/main/java/.../runtime/SessionService.kt` (bridge message dispatcher, currently 92 types; this plan adds 4 more)

---

## Backend contract (for reference during implementation)

**Base URL:** `https://wecoded-marketplace-api.destinj101.workers.dev`

| Method | Path | Auth | Body | Response |
|---|---|---|---|---|
| POST | `/auth/github/start` | none | — | `{ device_code, user_code, auth_url, expires_in }` |
| GET | `/auth/github/start-redirect?user_code=X` | none | — | 302 to GitHub |
| POST | `/auth/github/poll` | none | `{ device_code }` | 202 `{status:"pending"}` or 200 `{status:"complete", token}` |
| POST | `/installs` | Bearer | `{ plugin_id }` | `{ ok: true }` |
| POST | `/ratings` | Bearer | `{ plugin_id, stars: 1-5, review_text?: string }` | `{ ok: true, hidden: boolean }` |
| DELETE | `/ratings/:plugin_id` | Bearer | — | `{ ok: true }` |
| POST | `/themes/:id/like` | Bearer | — | `{ liked: boolean }` |
| POST | `/reports` | Bearer | `{ rating_user_id, rating_plugin_id, reason? }` | `{ ok: true, id }` |
| GET | `/stats` | none | — | `{ generated_at, plugins: {id: {installs, review_count, rating}}, themes: {id: {likes}} }` |

**Rate limits (per user):** installs 100/hr · ratings 30/hr · reports 20/hr · 429 response on overflow.

**Errors:** 400 bad request, 401 unauthenticated, 403 forbidden (install-gate on ratings), 404 not found, 429 rate-limited. Body: `{ message: string }`.

**Install-gate rule:** `/ratings` requires that the same user already POSTed `/installs` for that plugin. The app MUST call `/installs` before any rating submission — not an inference from local state.

---

## File Structure

```
youcoded/desktop/src/
├── main/
│   ├── marketplace-auth-store.ts         # NEW: electron-store for bearer token (Task 2)
│   ├── marketplace-api-handlers.ts       # NEW: IPC bridge to Worker (Task 3)
│   ├── ipc-handlers.ts                   # MODIFY: register new handlers (Task 3)
│   ├── preload.ts                        # MODIFY: expose window.claude.marketplaceAuth + .marketplaceApi (Task 4)
│   └── skill-provider.ts                 # MODIFY: stop reading static stats.json; use live /stats (Task 6)
├── renderer/
│   ├── remote-shim.ts                    # MODIFY: Android parity shim for new APIs (Task 4)
│   ├── state/
│   │   ├── marketplace-auth-context.tsx  # NEW: signed-in state + sign-in/out actions (Task 5)
│   │   ├── marketplace-stats-context.tsx # NEW: live /stats fetch with 5-min cache (Task 6)
│   │   └── marketplace-context.tsx       # MODIFY: fire POST /installs on successful install (Task 7)
│   └── components/
│       ├── marketplace/
│       │   ├── SignInButton.tsx          # NEW: "Sign in with GitHub" / user chip (Task 8)
│       │   ├── StarRating.tsx            # NEW: star display + optional input (Task 9)
│       │   ├── RatingSubmitModal.tsx     # NEW: modal with stars + review text (Task 10)
│       │   ├── ReviewList.tsx            # NEW: list of reviews for a plugin (Task 10)
│       │   ├── ReportReviewButton.tsx    # NEW: flag a review (Task 11)
│       │   └── LikeButton.tsx            # NEW: heart toggle for themes (Task 12)
│       ├── SkillCard.tsx                 # MODIFY: render live install count + star rating (Task 9)
│       ├── ThemeCard.tsx                 # MODIFY: render like count + LikeButton (Task 12)
│       └── Marketplace.tsx               # MODIFY: mount SignInButton in header (Task 8)
└── __tests__/marketplace/                # NEW: component tests (each task)

youcoded/app/src/main/java/.../runtime/
└── SessionService.kt                     # MODIFY: add 4 new bridge message handlers (Task 13)
```

**Design notes:**
- All new components live under `components/marketplace/` to keep the feature self-contained.
- `marketplace-auth-context.tsx` and `marketplace-stats-context.tsx` are separate contexts on purpose — auth state is write-heavy (sign-in, token refresh), stats state is read-heavy and independently cacheable.
- `marketplace-api-handlers.ts` is one file because every endpoint is a trivial `fetch` passthrough with Authorization header injection. Splitting by endpoint would be busywork.

---

## Prerequisites

- Plan 1 merged and deployed. Verify: `curl https://wecoded-marketplace-api.destinj101.workers.dev/health` returns `{"ok":true}`.
- Local checkout of `youcoded` synced to latest master.
- A new git worktree created for this plan's work. From `youcoded/`:
  ```bash
  git fetch origin && git pull origin master
  git worktree add -b marketplace-app-integration ../wecoded-marketplace-app master
  cd ../wecoded-marketplace-app
  ```
- `npm ci` inside `desktop/`.
- Optional: run `bash wecoded-marketplace/worker/scripts/smoke-test.sh https://wecoded-marketplace-api.destinj101.workers.dev` to confirm backend is live.

---

## Task 1: API client module (pure, testable)

**Files:**
- Create: `desktop/src/renderer/state/marketplace-api-client.ts`
- Test: `desktop/src/renderer/state/__tests__/marketplace-api-client.test.ts`

A typed wrapper around `fetch` for every endpoint. Lives in `renderer/` because both desktop and Android run the same React bundle — the client calls `fetch` directly (Workers are same-origin from the packaged app's perspective via CORS allowlist). No IPC needed for read endpoints; write endpoints go through IPC only because token handling lives in `main/`.

- [ ] **Step 1: Write failing tests**

```ts
// __tests__/marketplace-api-client.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import { createMarketplaceApiClient } from "../marketplace-api-client";

describe("MarketplaceApiClient", () => {
  const HOST = "https://api.test";
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn();
    globalThis.fetch = fetchMock as unknown as typeof fetch;
  });

  it("fetches /stats without auth", async () => {
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ plugins: {}, themes: {} })));
    const client = createMarketplaceApiClient({ host: HOST, getToken: () => null });
    const stats = await client.getStats();
    expect(fetchMock).toHaveBeenCalledWith(`${HOST}/stats`, expect.objectContaining({ method: "GET" }));
    expect(stats).toEqual({ plugins: {}, themes: {} });
  });

  it("attaches Bearer token to authenticated endpoints", async () => {
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ ok: true })));
    const client = createMarketplaceApiClient({ host: HOST, getToken: () => "TOKEN" });
    await client.postInstall("foo:bar");
    expect(fetchMock).toHaveBeenCalledWith(
      `${HOST}/installs`,
      expect.objectContaining({
        method: "POST",
        headers: expect.objectContaining({ Authorization: "Bearer TOKEN" }),
      })
    );
  });

  it("throws typed error on 401", async () => {
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ message: "invalid token" }), { status: 401 }));
    const client = createMarketplaceApiClient({ host: HOST, getToken: () => "BAD" });
    await expect(client.postInstall("foo")).rejects.toMatchObject({ status: 401 });
  });

  it("throws typed error on 403 install-gate", async () => {
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ message: "must install plugin before rating" }), { status: 403 }));
    const client = createMarketplaceApiClient({ host: HOST, getToken: () => "T" });
    await expect(client.postRating({ plugin_id: "x", stars: 5 })).rejects.toMatchObject({ status: 403 });
  });

  it("starts device-code flow unauthenticated", async () => {
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({
      device_code: "d", user_code: "U", auth_url: "http://example", expires_in: 900,
    })));
    const client = createMarketplaceApiClient({ host: HOST, getToken: () => null });
    const out = await client.authStart();
    expect(out.device_code).toBe("d");
  });

  it("polls without auth", async () => {
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ status: "pending" }), { status: 202 }));
    const client = createMarketplaceApiClient({ host: HOST, getToken: () => null });
    const out = await client.authPoll("d");
    expect(out.status).toBe("pending");
  });
});
```

- [ ] **Step 2: Run — expect fail**

```bash
cd desktop && npx vitest run marketplace-api-client
```

- [ ] **Step 3: Implement `marketplace-api-client.ts`**

```ts
export const MARKETPLACE_API_HOST = "https://wecoded-marketplace-api.destinj101.workers.dev";

export class MarketplaceApiError extends Error {
  constructor(public readonly status: number, message: string) {
    super(message);
  }
}

export interface AuthStartResponse {
  device_code: string;
  user_code: string;
  auth_url: string;
  expires_in: number;
}

export type AuthPollResponse =
  | { status: "pending" }
  | { status: "complete"; token: string };

export interface StatsResponse {
  generated_at: number;
  plugins: Record<string, { installs: number; review_count: number; rating: number }>;
  themes: Record<string, { likes: number }>;
}

export interface PostRatingInput {
  plugin_id: string;
  stars: 1 | 2 | 3 | 4 | 5;
  review_text?: string;
}

export interface MarketplaceApiClient {
  getStats(): Promise<StatsResponse>;
  authStart(): Promise<AuthStartResponse>;
  authPoll(deviceCode: string): Promise<AuthPollResponse>;
  postInstall(pluginId: string): Promise<void>;
  postRating(input: PostRatingInput): Promise<{ hidden: boolean }>;
  deleteRating(pluginId: string): Promise<void>;
  toggleThemeLike(themeId: string): Promise<{ liked: boolean }>;
  postReport(input: { rating_user_id: string; rating_plugin_id: string; reason?: string }): Promise<void>;
}

export function createMarketplaceApiClient(opts: {
  host: string;
  getToken: () => string | null;
}): MarketplaceApiClient {
  const { host, getToken } = opts;

  async function request<T>(path: string, init: RequestInit & { auth?: boolean } = {}): Promise<T> {
    const headers: Record<string, string> = { "Content-Type": "application/json", ...(init.headers as any) };
    if (init.auth) {
      const token = getToken();
      if (!token) throw new MarketplaceApiError(401, "not signed in");
      headers.Authorization = `Bearer ${token}`;
    }
    const res = await fetch(`${host}${path}`, { ...init, headers });
    const body = res.status === 202 ? { status: "pending" as const } : await res.json().catch(() => ({}));
    if (!res.ok && res.status !== 202) {
      throw new MarketplaceApiError(res.status, (body as any)?.message ?? res.statusText);
    }
    return body as T;
  }

  return {
    getStats: () => request<StatsResponse>("/stats", { method: "GET" }),
    authStart: () => request<AuthStartResponse>("/auth/github/start", { method: "POST" }),
    authPoll: (device_code) =>
      request<AuthPollResponse>("/auth/github/poll", {
        method: "POST",
        body: JSON.stringify({ device_code }),
      }),
    postInstall: async (plugin_id) => {
      await request("/installs", { method: "POST", body: JSON.stringify({ plugin_id }), auth: true });
    },
    postRating: (input) =>
      request<{ hidden: boolean }>("/ratings", {
        method: "POST",
        body: JSON.stringify(input),
        auth: true,
      }),
    deleteRating: async (plugin_id) => {
      await request(`/ratings/${encodeURIComponent(plugin_id)}`, { method: "DELETE", auth: true });
    },
    toggleThemeLike: (theme_id) =>
      request<{ liked: boolean }>(`/themes/${encodeURIComponent(theme_id)}/like`, {
        method: "POST",
        auth: true,
      }),
    postReport: async (input) => {
      await request("/reports", { method: "POST", body: JSON.stringify(input), auth: true });
    },
  };
}
```

- [ ] **Step 4: Run — expect pass**

6/6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/state/marketplace-api-client.ts desktop/src/renderer/state/__tests__/marketplace-api-client.test.ts
git commit -m "feat(marketplace): typed API client for Worker backend"
```

---

## Task 2: Token storage in main process

**Files:**
- Create: `desktop/src/main/marketplace-auth-store.ts`
- Test: `desktop/src/main/__tests__/marketplace-auth-store.test.ts`

`electron-store` backed. Token lives in `userData/marketplace-auth.json`. Never logged, never written to stderr.

- [ ] **Step 1: Write failing test**

```ts
// __tests__/marketplace-auth-store.test.ts
import { describe, it, expect, beforeEach } from "vitest";
import { MarketplaceAuthStore } from "../marketplace-auth-store";

describe("MarketplaceAuthStore", () => {
  let store: MarketplaceAuthStore;

  beforeEach(() => {
    // In-memory backing for tests.
    const backing = new Map<string, unknown>();
    store = new MarketplaceAuthStore({
      get: (k) => backing.get(k),
      set: (k, v) => backing.set(k, v),
      delete: (k) => backing.delete(k),
    });
  });

  it("returns null when no token is stored", () => {
    expect(store.getToken()).toBeNull();
  });

  it("stores and retrieves a token", () => {
    store.setToken("abc123");
    expect(store.getToken()).toBe("abc123");
  });

  it("clears the token on signOut", () => {
    store.setToken("abc");
    store.signOut();
    expect(store.getToken()).toBeNull();
  });

  it("persists the user profile alongside the token", () => {
    store.setSession("tok", { id: "github:1", login: "u", avatar_url: "http://a" });
    expect(store.getUser()).toEqual({ id: "github:1", login: "u", avatar_url: "http://a" });
  });
});
```

- [ ] **Step 2: Run — expect fail**

- [ ] **Step 3: Implement**

```ts
// marketplace-auth-store.ts
export interface MarketplaceUser {
  id: string;         // github:<id>
  login: string;
  avatar_url: string;
}

interface Backing {
  get<T>(key: string): T | undefined;
  set<T>(key: string, value: T): void;
  delete(key: string): void;
}

export class MarketplaceAuthStore {
  constructor(private readonly backing: Backing) {}

  getToken(): string | null {
    return this.backing.get<string>("marketplace.token") ?? null;
  }

  getUser(): MarketplaceUser | null {
    return this.backing.get<MarketplaceUser>("marketplace.user") ?? null;
  }

  setToken(token: string): void {
    this.backing.set("marketplace.token", token);
  }

  setSession(token: string, user: MarketplaceUser): void {
    this.backing.set("marketplace.token", token);
    this.backing.set("marketplace.user", user);
  }

  signOut(): void {
    this.backing.delete("marketplace.token");
    this.backing.delete("marketplace.user");
  }
}

// Factory used by main.ts. Electron-store is dynamically imported so tests
// don't need electron installed.
export async function createElectronAuthStore(): Promise<MarketplaceAuthStore> {
  const { default: Store } = await import("electron-store");
  const store = new Store({ name: "marketplace-auth" });
  return new MarketplaceAuthStore({
    get: (k) => store.get(k) as any,
    set: (k, v) => store.set(k, v as any),
    delete: (k) => store.delete(k as any),
  });
}
```

- [ ] **Step 4: Run — expect 4/4 pass**

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/marketplace-auth-store.ts desktop/src/main/__tests__/marketplace-auth-store.test.ts
git commit -m "feat(marketplace): main-process auth store for bearer token + user profile"
```

---

## Task 3: IPC handlers (desktop main process)

**Files:**
- Create: `desktop/src/main/marketplace-api-handlers.ts`
- Modify: `desktop/src/main/ipc-handlers.ts`
- Modify: `desktop/src/main/main.ts` (instantiate auth store at startup)

Handlers expose the 8 write endpoints + auth flow via IPC. Read endpoints (`getStats`) go directly from renderer — no need to proxy.

- [ ] **Step 1: Write `marketplace-api-handlers.ts`**

```ts
import { ipcMain, shell } from "electron";
import type { MarketplaceAuthStore } from "./marketplace-auth-store";
import { createMarketplaceApiClient, MARKETPLACE_API_HOST } from "../renderer/state/marketplace-api-client";

export function registerMarketplaceApiHandlers(store: MarketplaceAuthStore): void {
  const client = createMarketplaceApiClient({
    host: MARKETPLACE_API_HOST,
    getToken: () => store.getToken(),
  });

  // Auth: device-code flow. Renderer calls authStart, gets an auth_url; we
  // open it in the user's default browser, then the renderer calls authPoll
  // until the Worker returns the bearer token.
  ipcMain.handle("marketplace:auth:start", async () => {
    const out = await client.authStart();
    await shell.openExternal(out.auth_url);
    return out;
  });

  ipcMain.handle("marketplace:auth:poll", async (_e, deviceCode: string) => {
    const res = await client.authPoll(deviceCode);
    if (res.status === "complete") {
      store.setToken(res.token);
      // TODO(Task 5): fetch /user from GitHub once we add that endpoint, or
      // decode from the token. For now we store only the token; user info
      // can be populated lazily.
    }
    return res;
  });

  ipcMain.handle("marketplace:auth:signed-in", () => !!store.getToken());
  ipcMain.handle("marketplace:auth:user", () => store.getUser());
  ipcMain.handle("marketplace:auth:sign-out", () => store.signOut());

  // Write endpoints — each is a thin pass-through. We keep them in main/
  // because the token must never reach the renderer bundle.
  ipcMain.handle("marketplace:install", (_e, pluginId: string) => client.postInstall(pluginId));
  ipcMain.handle("marketplace:rate", (_e, input) => client.postRating(input));
  ipcMain.handle("marketplace:rate:delete", (_e, pluginId: string) => client.deleteRating(pluginId));
  ipcMain.handle("marketplace:theme:like", (_e, themeId: string) => client.toggleThemeLike(themeId));
  ipcMain.handle("marketplace:report", (_e, input) => client.postReport(input));
}
```

- [ ] **Step 2: Wire into `ipc-handlers.ts`**

Find the existing handler registration block and call `registerMarketplaceApiHandlers(authStore)` from there. The `authStore` instance must be created once at app startup in `main.ts`:

```ts
// main.ts — near other startup initialization
import { createElectronAuthStore } from "./marketplace-auth-store";
import { registerMarketplaceApiHandlers } from "./marketplace-api-handlers";

// ...
const marketplaceAuthStore = await createElectronAuthStore();
registerMarketplaceApiHandlers(marketplaceAuthStore);
```

- [ ] **Step 3: Typecheck**

```bash
cd desktop && npm run typecheck
```

- [ ] **Step 4: Commit**

```bash
git add desktop/src/main/marketplace-api-handlers.ts desktop/src/main/ipc-handlers.ts desktop/src/main/main.ts
git commit -m "feat(marketplace): IPC handlers for auth + write endpoints"
```

---

## Task 4: Preload + remote-shim parity

**Files:**
- Modify: `desktop/src/main/preload.ts`
- Modify: `desktop/src/renderer/remote-shim.ts`

Expose `window.claude.marketplaceAuth.*` and `window.claude.marketplaceApi.*` on both platforms. **Both preload.ts AND remote-shim.ts MUST expose the same shape** — see `docs/PITFALLS.md` under "Cross-Platform".

- [ ] **Step 1: Update `preload.ts`**

Add to the `window.claude` exposure:

```ts
marketplaceAuth: {
  start: () => ipcRenderer.invoke("marketplace:auth:start") as Promise<AuthStartResponse>,
  poll: (deviceCode: string) => ipcRenderer.invoke("marketplace:auth:poll", deviceCode) as Promise<AuthPollResponse>,
  signedIn: () => ipcRenderer.invoke("marketplace:auth:signed-in") as Promise<boolean>,
  user: () => ipcRenderer.invoke("marketplace:auth:user") as Promise<MarketplaceUser | null>,
  signOut: () => ipcRenderer.invoke("marketplace:auth:sign-out") as Promise<void>,
},
marketplaceApi: {
  install: (pluginId: string) => ipcRenderer.invoke("marketplace:install", pluginId) as Promise<void>,
  rate: (input: PostRatingInput) => ipcRenderer.invoke("marketplace:rate", input) as Promise<{ hidden: boolean }>,
  deleteRating: (pluginId: string) => ipcRenderer.invoke("marketplace:rate:delete", pluginId) as Promise<void>,
  likeTheme: (themeId: string) => ipcRenderer.invoke("marketplace:theme:like", themeId) as Promise<{ liked: boolean }>,
  report: (input: {rating_user_id:string;rating_plugin_id:string;reason?:string}) => ipcRenderer.invoke("marketplace:report", input) as Promise<void>,
},
```

Import the shared types from `renderer/state/marketplace-api-client`.

- [ ] **Step 2: Update `remote-shim.ts`**

Same API surface, but routed through the WebSocket `invoke` helper for Android. Copy the invoke-call pattern used by other existing methods in the shim (e.g., `skills.install`, `dialog.openFolder`). The message type strings MUST match exactly:
- `marketplace:auth:start` / `marketplace:auth:poll` / `marketplace:auth:signed-in` / `marketplace:auth:user` / `marketplace:auth:sign-out`
- `marketplace:install` / `marketplace:rate` / `marketplace:rate:delete` / `marketplace:theme:like` / `marketplace:report`

Since the type string is shared, a typo on one side silently breaks the other platform. Keep the strings as constants if that helps discipline.

- [ ] **Step 3: Typecheck both**

```bash
cd desktop && npm run typecheck
```

- [ ] **Step 4: Commit**

```bash
git add desktop/src/main/preload.ts desktop/src/renderer/remote-shim.ts
git commit -m "feat(marketplace): expose marketplaceAuth + marketplaceApi on window.claude (desktop + android parity)"
```

---

## Task 5: Marketplace auth React context

**Files:**
- Create: `desktop/src/renderer/state/marketplace-auth-context.tsx`
- Test: `desktop/src/renderer/state/__tests__/marketplace-auth-context.test.tsx`

Global "am I signed in" state with actions. Uses `window.claude.marketplaceAuth`. Starts the device-code flow, polls every 2 seconds until complete or 15 min timeout, then stores token + user.

- [ ] **Step 1: Write test** (uses `@testing-library/react` — already in deps)

```tsx
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, act, waitFor } from "@testing-library/react";
import { MarketplaceAuthProvider, useMarketplaceAuth } from "../marketplace-auth-context";

function Probe() {
  const { signedIn, startSignIn, user } = useMarketplaceAuth();
  return (
    <div>
      <span data-testid="state">{signedIn ? "in" : "out"}</span>
      <span data-testid="user">{user?.login ?? ""}</span>
      <button data-testid="go" onClick={() => startSignIn()}>go</button>
    </div>
  );
}

describe("MarketplaceAuthProvider", () => {
  beforeEach(() => {
    (globalThis as any).window.claude = {
      marketplaceAuth: {
        start: vi.fn().mockResolvedValue({ device_code: "d", user_code: "U", auth_url: "http://a", expires_in: 900 }),
        poll: vi.fn()
          .mockResolvedValueOnce({ status: "pending" })
          .mockResolvedValueOnce({ status: "complete", token: "TOK" }),
        signedIn: vi.fn().mockResolvedValue(false),
        user: vi.fn().mockResolvedValue(null),
        signOut: vi.fn(),
      },
    };
  });

  it("starts as signed-out", async () => {
    const { getByTestId } = render(<MarketplaceAuthProvider><Probe /></MarketplaceAuthProvider>);
    await waitFor(() => expect(getByTestId("state").textContent).toBe("out"));
  });

  it("transitions to signed-in after sign-in flow completes", async () => {
    const { getByTestId } = render(<MarketplaceAuthProvider><Probe /></MarketplaceAuthProvider>);
    await act(async () => { getByTestId("go").click(); });
    // Poll runs; second call returns complete.
    await waitFor(() => expect(getByTestId("state").textContent).toBe("in"), { timeout: 5000 });
  });
});
```

- [ ] **Step 2: Run — expect fail**

- [ ] **Step 3: Implement context**

```tsx
// marketplace-auth-context.tsx
import React, { createContext, useContext, useEffect, useState } from "react";
import type { MarketplaceUser } from "../../main/marketplace-auth-store";

interface Ctx {
  signedIn: boolean;
  user: MarketplaceUser | null;
  signInPending: boolean;
  startSignIn(): Promise<void>;
  signOut(): Promise<void>;
}

const MarketplaceAuthContext = createContext<Ctx | null>(null);

const POLL_INTERVAL_MS = 2000;
const POLL_TIMEOUT_MS = 15 * 60 * 1000;

export function MarketplaceAuthProvider({ children }: { children: React.ReactNode }) {
  const [signedIn, setSignedIn] = useState(false);
  const [user, setUser] = useState<MarketplaceUser | null>(null);
  const [signInPending, setSignInPending] = useState(false);

  async function refresh() {
    setSignedIn(await window.claude.marketplaceAuth.signedIn());
    setUser(await window.claude.marketplaceAuth.user());
  }

  useEffect(() => { void refresh(); }, []);

  async function startSignIn() {
    if (signInPending) return;
    setSignInPending(true);
    try {
      const { device_code } = await window.claude.marketplaceAuth.start();
      const deadline = Date.now() + POLL_TIMEOUT_MS;
      // Loop until complete or timeout.
      // eslint-disable-next-line no-constant-condition
      while (true) {
        if (Date.now() > deadline) throw new Error("sign-in timed out");
        const res = await window.claude.marketplaceAuth.poll(device_code);
        if (res.status === "complete") {
          await refresh();
          return;
        }
        await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
      }
    } finally {
      setSignInPending(false);
    }
  }

  async function signOut() {
    await window.claude.marketplaceAuth.signOut();
    setSignedIn(false);
    setUser(null);
  }

  return (
    <MarketplaceAuthContext.Provider value={{ signedIn, user, signInPending, startSignIn, signOut }}>
      {children}
    </MarketplaceAuthContext.Provider>
  );
}

export function useMarketplaceAuth(): Ctx {
  const ctx = useContext(MarketplaceAuthContext);
  if (!ctx) throw new Error("useMarketplaceAuth outside MarketplaceAuthProvider");
  return ctx;
}
```

- [ ] **Step 4: Wrap the app with the provider**

In the renderer's root render (likely `main.tsx` or `App.tsx`), wrap the existing tree with `<MarketplaceAuthProvider>`. Place it outside `<MarketplaceProvider>` so marketplace-context can read auth state later if needed.

- [ ] **Step 5: Run tests**

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(marketplace): auth React context with device-code polling"
```

---

## Task 6: Live stats fetcher

**Files:**
- Create: `desktop/src/renderer/state/marketplace-stats-context.tsx`
- Modify: `desktop/src/main/skill-provider.ts` (remove reads of static stats.json)
- Test: `desktop/src/renderer/state/__tests__/marketplace-stats-context.test.tsx`

Replaces the static `stats.json` fetch. Pulls from `GET /stats` on Marketplace open. Caches in-memory for 5 min. Exposes `useMarketplaceStats()` returning `{ loading, plugins, themes, refresh }`.

**Implementation notes:**
- Call `createMarketplaceApiClient` from the renderer (no auth needed for `/stats`).
- On first mount, fetch. On re-mount within 5 min, use cached value.
- Expose `refresh()` for pull-to-refresh or explicit user action.
- Handle fetch failure gracefully: return empty aggregates, log once, don't block the UI.

- [ ] **Step 1: Write tests** covering: loading state, populated state after fetch, 5-min cache hit, refresh() bypasses cache, graceful error handling.

- [ ] **Step 2: Implement** (pattern similar to `theme-context.tsx` which already exists — mirror its shape).

- [ ] **Step 3: Wrap app** with `<MarketplaceStatsProvider>`.

- [ ] **Step 4: Remove static stats.json references**

Search for `stats.json` in `desktop/src/` and remove reads — the file is now unused (Plan 1 didn't delete it from the marketplace repo to avoid breaking old app versions; it's just ignored now).

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(marketplace): live /stats fetcher replacing static stats.json"
```

---

## Task 7: Fire POST /installs on plugin install

**Files:**
- Modify: `desktop/src/renderer/state/marketplace-context.tsx`

Whenever an install completes successfully in the existing `install(pluginId)` action, fire `window.claude.marketplaceApi.install(pluginId)` in a `.catch(() => {})` so failures don't block the local install. Only fire if the user is signed in — otherwise skip silently (anonymous install = no telemetry).

Do NOT fire for uninstalls; the backend intentionally doesn't decrement.

- [ ] **Step 1: Find the install action** in `marketplace-context.tsx` — look for the IPC call that runs the local install (`skills:install` or similar).

- [ ] **Step 2: Add post-install hook** after successful install:

```ts
// Inside the install action, after local install succeeds:
const signedIn = await window.claude.marketplaceAuth.signedIn();
if (signedIn) {
  window.claude.marketplaceApi.install(pluginId).catch((e) => {
    console.warn("marketplace install telemetry failed:", e);
  });
}
```

- [ ] **Step 3: Test** that a local install still succeeds when the Worker POST fails (mock fetch to reject).

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(marketplace): telemeter install count to Worker on successful local install"
```

---

## Task 8: Sign-in button + user chip

**Files:**
- Create: `desktop/src/renderer/components/marketplace/SignInButton.tsx`
- Modify: `desktop/src/renderer/components/Marketplace.tsx`

A single component that shows either:
- "Sign in with GitHub" button when signed out (clicking calls `startSignIn()`; during `signInPending`, shows "Check your browser… (code: AB12-CD34)")
- User avatar + login + caret dropdown when signed in (dropdown has "Sign out")

Mount it in the Marketplace modal header, right-aligned.

- [ ] **Step 1: Build the component** using the existing `<OverlayPanel>` primitive for the dropdown per overlay rules in `docs/shared-ui-architecture.md`.

- [ ] **Step 2: Snapshot test** for both states (signed in, signed out, pending).

- [ ] **Step 3: Manual test on desktop** — run `bash scripts/run-dev.sh` from the youcoded root, open Marketplace, click sign in, complete the browser flow, verify the user chip shows up.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(marketplace): SignInButton + user chip in marketplace header"
```

---

## Task 9: Star rating display on SkillCard

**Files:**
- Create: `desktop/src/renderer/components/marketplace/StarRating.tsx`
- Modify: `desktop/src/renderer/components/SkillCard.tsx`

`<StarRating value={4.3} count={27} size="sm" />` — renders 5 stars (fractional fill OK) + "(27)" if count ≥ 1. No display if count = 0 (card just shows install count alone). Size variants: `sm` (on cards), `lg` (on plugin detail page).

Pulls values from `useMarketplaceStats()` rather than from the marketplace registry entry — stats are live.

- [ ] **Step 1: Build `StarRating`** as pure presentational (no hooks, no context). Use SVG stars with `clip-path` for fractional fill.

- [ ] **Step 2: Wire into SkillCard** — render install count (already wired from stats context) + StarRating when `review_count ≥ 1`.

- [ ] **Step 3: Visual regression:** update any existing snapshot tests for SkillCard to accommodate new rendered elements.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(marketplace): StarRating + render live ratings on SkillCard"
```

---

## Task 10: Rating submission modal + review list

**Files:**
- Create: `desktop/src/renderer/components/marketplace/RatingSubmitModal.tsx`
- Create: `desktop/src/renderer/components/marketplace/ReviewList.tsx`
- Modify: the skill detail view (find it — probably in `Marketplace.tsx` or a sub-component) to wire in a "Rate this plugin" button and the review list

Critical gotcha: **ratings require a prior install**. Call `window.claude.marketplaceApi.install(pluginId)` BEFORE `rate(...)` if the user hasn't explicitly installed — OR show an inline hint "Install the plugin to rate it" that's a one-click install-then-rate flow.

**Backend doesn't currently expose GET /ratings/:plugin_id** to list reviews — we'd need to add it. Until then, reviews are not retrievable; rating submission still works but the review list is empty.

- [ ] **Step 0: Add backend endpoint** to list visible reviews for a plugin.

This task has a cross-plan dependency. Either:
- (A) Add `GET /ratings/:plugin_id` to the Worker as a prerequisite. This is ~30 LOC — one new route, one test. Do it in a tiny follow-up PR on wecoded-marketplace before completing Task 10.
- (B) Ship rating submission only in this task; defer the review list to a follow-up.

Plan doc authors chose (A). Walk through with the user before committing to (B) if you get here.

- [ ] **Step 1–N: Standard UI work.** Modal with stars, 500-char textarea, submit button. Handle 403 (show "install this plugin first"), 429 (show "you've rated too many plugins in the last hour"), 500 (generic retry message).

- [ ] **Commit at end**

```bash
git commit -m "feat(marketplace): rating submission modal + review list"
```

---

## Task 11: Report review button

**Files:**
- Create: `desktop/src/renderer/components/marketplace/ReportReviewButton.tsx`
- Modify: `ReviewList.tsx` to render the button on each review

Small flag icon on each review. Clicking opens a confirmation dialog with an optional reason textarea. Submits to `/reports` via `marketplaceApi.report({ rating_user_id, rating_plugin_id, reason })`. Show a toast "Report submitted" on success; silently swallow failures (they're non-blocking).

- [ ] **Commit**: `feat(marketplace): report-review button`

---

## Task 12: Theme like button

**Files:**
- Create: `desktop/src/renderer/components/marketplace/LikeButton.tsx`
- Modify: `desktop/src/renderer/components/ThemeCard.tsx`

Heart icon toggle. Fills when liked, outline when not. Count shown next to it (from stats context). Optimistic: flip state immediately on click, reconcile with server response, revert + toast on error.

- [ ] **Commit**: `feat(marketplace): theme like toggle`

---

## Task 13: Android IPC parity

**Files:**
- Modify: `app/src/main/java/com/itsdestin/youcoded-core/runtime/SessionService.kt`

Add 10 new `when` cases in `handleBridgeMessage()` for the message types added in Task 4. Each case is a simple pass-through to the shared marketplace API client (Kotlin equivalent — or just use HttpClient + the same URL constant).

- [ ] **Step 1: Add a Kotlin `MarketplaceAuthStore`** backed by `SharedPreferences` for token persistence. Same shape as the TS version: `getToken()`, `getUser()`, `setToken()`, `setSession()`, `signOut()`.

- [ ] **Step 2: Add a Kotlin `MarketplaceApiClient`** using the existing `OkHttpClient` pattern from elsewhere in the runtime. Reuses the URL constant.

- [ ] **Step 3: Wire the 10 message types** in `SessionService.handleBridgeMessage()`. Each respond via `bridgeServer.respond(ws, msg.type, msg.id, payload)`.

- [ ] **Step 4: Open-URL message** — `marketplace:auth:start` needs to open a browser on Android. Use an Intent with `ACTION_VIEW`. The Activity (not the SessionService) must handle it via a new callback pattern like the existing file picker (see `docs/android-runtime.md` "Native UI Bridge Pattern").

- [ ] **Step 5: Build web UI + APK**:

```bash
cd youcoded && bash scripts/build-web-ui.sh && ./gradlew assembleDebug
```

- [ ] **Step 6: Manual test on Android** — install the debug APK, open Marketplace, sign in, verify a browser opens and the flow completes.

- [ ] **Commit**: `feat(marketplace): Android IPC handlers + auth store`

---

## Task 14: Offline + error UX polish

**Files:**
- Modify: various components

Every marketplace write must gracefully degrade when the Worker is unreachable:
- Installs still succeed locally; telemetry is silently dropped.
- Ratings show "Offline — try again" toast; user can retry.
- Reports queue locally and flush on next successful request (use a bounded array in-memory; don't persist — reports are low-stakes).

Add a small indicator in the Marketplace header when the Worker has been unreachable for >30 seconds (red dot + tooltip "Marketplace backend unreachable").

- [ ] **Commit**: `feat(marketplace): offline-tolerant UX`

---

## Task 15: End-to-end verification

Manual steps performed by the controller after all tasks land:

- [ ] Build desktop: `cd desktop && npm run build`
- [ ] Run dev app: `bash scripts/run-dev.sh` from youcoded root
- [ ] Sign in with GitHub → user chip appears
- [ ] Open any plugin → install it → `/stats` shows +1 install within 5 min
- [ ] Rate the same plugin 4 stars with a short review → card shows a star rating
- [ ] Try to rate a plugin you haven't installed → install-gate rejection
- [ ] Like a theme → heart fills; count increments on `/stats`
- [ ] Report your own review → report appears in `wrangler d1 execute marketplace --remote --command "SELECT * FROM reports"`
- [ ] Sign out → user chip disappears; sign-in button returns
- [ ] Android APK (if Task 13 completed) — same flow
- [ ] Open a PR to youcoded

---

## Self-Review Checklist (plan author)

- **Spec coverage:** sign-in, install counts, ratings (submit/update/delete), theme likes, reports, offline handling, cross-platform — all present.
- **Placeholder scan:** Tasks 10 and 13 have some "find the file" and "copy the pattern" instructions rather than verbatim code. Acceptable because those tasks involve integrating with existing code the implementer must read. Task 10 also has a cross-plan dependency (GET /ratings/:plugin_id endpoint) explicitly flagged.
- **Type consistency:** `MarketplaceUser`, `AuthStartResponse`, `AuthPollResponse`, `StatsResponse`, `PostRatingInput` defined once in `marketplace-api-client.ts` and imported everywhere.

## Known soft spots flagged for future controllers

1. **Backend gap: no `GET /ratings/:plugin_id` endpoint exists** to list reviews for a plugin. Task 10 flags this. Likely a 30-LOC follow-up to Plan 1 (new Hono route + test) before Task 10 can ship fully.
2. **Review text rendering.** Plain text, React auto-escapes — no XSS. If Markdown is ever added, audit the sanitizer.
3. **Token refresh / invalidation.** If a GitHub OAuth App secret rotation happens, all existing tokens become invalid and users get 401 silently. UX should detect 401 on writes and prompt re-sign-in. That logic is handled in the api-client (throws `MarketplaceApiError`), but the UI needs to catch it and show a re-sign-in toast. Task 14 covers this broadly.
4. **Rate-limit UX.** 429 responses should show human-readable messages ("You've rated too many plugins this hour — try again in X minutes"). The Worker doesn't currently return a `Retry-After` header; adding that would be a Plan 1 follow-up.
5. **Android browser-open pattern** (Task 13 Step 4) is non-trivial — it's the same deferred-callback pattern as the file picker. Worth dedicating a separate subagent task if it gets complicated.

---

**Plan complete and saved. Two execution options:**

**1. Subagent-Driven (recommended)** — controller dispatches a fresh subagent per task, two-stage review between tasks.

**2. Inline Execution** — controller executes tasks in-session using superpowers:executing-plans.

**For the next session:** start by running `bash /c/Users/desti/youcoded-dev/wecoded-marketplace/worker/scripts/smoke-test.sh https://wecoded-marketplace-api.destinj101.workers.dev` to confirm Plan 1 is still live before committing to Plan 2 work. Then set up the worktree and begin Task 1.
