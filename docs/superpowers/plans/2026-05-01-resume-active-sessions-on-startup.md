# Resume Active Sessions on Startup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On cold start, if YouCoded had sessions live in the strip when it last shut down (window close, crash, OS kill — anything that wasn't an explicit per-session close), present a full-screen "Welcome back" resume screen with checkboxes per session and a one-click "Resume all" path.

**Architecture:** A persisted JSON file at `~/.claude/youcoded-active-sessions.json` is updated eagerly: entries added when a session sends its first user prompt, updated on topic-file change, removed when the user closes a session via the X button. App quit/crash leaves the file as-is. On startup, the renderer reads the file, prechecks each transcript exists, fetches last user/assistant message previews, and renders the resume screen if anything survives. Reuses the existing `--resume <id>` session-create path and `loadHistory` IPC.

**Tech Stack:** TypeScript (Node + React), Vitest, Electron IPC, Kotlin (Android mirror), `fs.promises` with atomic-rename writes.

**Spec:** `docs/superpowers/specs/2026-05-01-resume-active-sessions-on-startup-design.md`

---

## File Structure

**Desktop (new):**
- `youcoded/desktop/src/main/active-sessions-store.ts` — pure-function store helpers (read/write/atomic, addSession, removeSession, updateTopic, pruneMissingTranscripts)
- `youcoded/desktop/src/main/active-sessions-store.test.ts` — unit tests for the store
- `youcoded/desktop/src/renderer/components/ResumeOnStartupScreen.tsx` — full-screen takeover UI
- `youcoded/desktop/src/renderer/components/ResumeOnStartupScreen.test.tsx` — renderer tests

**Desktop (modify):**
- `youcoded/desktop/src/shared/types.ts` — add `ActiveSession` type and `IPC.SESSION_ACTIVE_LIST_READ` constant
- `youcoded/desktop/src/main/ipc-handlers.ts` — add lifecycle wiring (transcript-watcher hook, destroy handler hook, topic update) and the read handler
- `youcoded/desktop/src/main/preload.ts` — expose `window.claude.session.activeListRead`
- `youcoded/desktop/src/renderer/remote-shim.ts` — parity entry for the same API
- `youcoded/desktop/src/renderer/App.tsx` — cold-start state, render the screen ahead of welcome, Resume / Start fresh handlers

**Android (new):**
- `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/ActiveSessionsStore.kt` — Kotlin mirror of the store
- `youcoded/app/src/test/kotlin/com/youcoded/app/runtime/ActiveSessionsStoreTest.kt` — round-trip parity test against shared fixture JSON

**Android (modify):**
- `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` — wire lifecycle to the Kotlin store and add `session:active-list-read` handler

**Workspace docs (modify):**
- `youcoded-dev/docs/PITFALLS.md` — append a section on the active-sessions-store cross-platform pattern

---

## Working Conventions

**Worktree:** This plan should be executed in a worktree off `master`. Create with:

```bash
cd C:/Users/desti/youcoded-dev/youcoded
git worktree add ../../youcoded-worktrees/resume-on-startup -b feat/resume-on-startup
cd ../../youcoded-worktrees/resume-on-startup
```

All paths in the steps below are relative to that worktree's `youcoded/` directory unless otherwise noted (or relative to `youcoded-dev/` for workspace-level docs — `PITFALLS.md`, this plan).

**Tests:** Desktop tests use Vitest. Run from `youcoded/desktop/`:
```bash
npm test -- active-sessions-store.test.ts
```

**Commits:** One commit per task. Use the existing project conventions seen in recent commits (`feat(resume-on-startup): ...`).

**Cross-platform parity:** When adding the IPC type string, it must be IDENTICAL across `preload.ts`, `ipc-handlers.ts`, `remote-shim.ts`, and `SessionService.kt`. Do not let typos sneak in. (`docs/PITFALLS.md → Cross-Platform`.)

---

### Task 1: Add types and IPC constant

**Files:**
- Modify: `desktop/src/shared/types.ts`

- [ ] **Step 1: Add the `ActiveSession` type**

Open `desktop/src/shared/types.ts`. Find the `PastSession` interface (it's defined near other session types). Add `ActiveSession` directly below it:

```typescript
/**
 * One entry in ~/.claude/youcoded-active-sessions.json.
 *
 * Tracks a session that was alive in the session strip and not
 * deliberately closed. On cold start, the resume screen offers these
 * back to the user. App quit / window close / crash / OS kill all
 * leave the entry in place; only an explicit per-session close
 * (the X in the strip) removes it.
 *
 * No `diedUnexpectedly` flag — sessions that ended via 'session-died'
 * are treated identically to clean exits per the design spec.
 */
export interface ActiveSession {
  /** Desktop-side session ID (the one used in the session strip). */
  desktopSessionId: string;
  /** Claude Code's internal session ID (the JSONL filename without extension). */
  claudeSessionId: string;
  /** The cwd the session was created in — used to find the project slug at read time. */
  projectPath: string;
  /** Topic snapshot at the time of writing. Updated when the topic file changes. */
  topicName: string;
  /** Epoch ms — last user-message or topic-update time. Drives ordering on the resume screen. */
  lastActivityMs: number;
}

/**
 * What the renderer receives from session:active-list-read — same shape
 * as ActiveSession plus precomputed previews so the screen can render
 * without round-trips. Entries with missing transcripts have already
 * been pruned by the time this is returned.
 */
export interface ActiveSessionForRender extends ActiveSession {
  /** Resolved project slug (the directory name under ~/.claude/projects/). */
  projectSlug: string;
  /** Last user message text (one line, untruncated — UI handles truncation). Empty string if none. */
  lastUserMessage: string;
  /** Last assistant end_turn text. Empty string if none. */
  lastAssistantMessage: string;
}
```

- [ ] **Step 2: Add the IPC constant**

In the same file, find the `IPC` object. Add (next to the other `SESSION_*` entries, e.g., near `SESSION_BROWSE`):

```typescript
  SESSION_ACTIVE_LIST_READ: 'session:active-list-read',
```

- [ ] **Step 3: Verify typecheck**

```bash
cd youcoded/desktop && npx tsc --noEmit
```

Expected: PASS (no errors).

- [ ] **Step 4: Commit**

```bash
git add desktop/src/shared/types.ts
git commit -m "feat(resume-on-startup): add ActiveSession types and IPC constant"
```

---

### Task 2: Build the active-sessions-store module (TDD)

**Files:**
- Create: `desktop/src/main/active-sessions-store.ts`
- Create: `desktop/src/main/active-sessions-store.test.ts`

The store is a small, pure module: it reads/writes the JSON file with atomic-rename semantics, and exposes idempotent helpers for the lifecycle events (add, remove, update-topic, prune-missing). All filesystem I/O goes through `fs.promises`.

- [ ] **Step 1: Write the failing tests first**

Create `desktop/src/main/active-sessions-store.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  readList,
  writeListAtomic,
  addSession,
  removeSession,
  updateTopic,
  pruneMissingTranscripts,
  ActiveSessionsListPath,
} from "./active-sessions-store";
import type { ActiveSession } from "../shared/types";

// All tests run against a temp dir to keep the real ~/.claude untouched.
let tmpHome: string;
let listPath: string;
let projectsDir: string;

beforeEach(() => {
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "active-sessions-test-"));
  listPath = path.join(tmpHome, ".claude", "youcoded-active-sessions.json");
  projectsDir = path.join(tmpHome, ".claude", "projects");
  fs.mkdirSync(path.dirname(listPath), { recursive: true });
  fs.mkdirSync(projectsDir, { recursive: true });
});

afterEach(() => {
  try { fs.rmSync(tmpHome, { recursive: true, force: true }); } catch {}
});

const sample = (overrides: Partial<ActiveSession> = {}): ActiveSession => ({
  desktopSessionId: "desk-1",
  claudeSessionId: "abc-123",
  projectPath: "C:\\Users\\dest\\proj",
  topicName: "Untitled",
  lastActivityMs: 1700000000000,
  ...overrides,
});

describe("readList", () => {
  it("returns empty array when file does not exist", async () => {
    expect(await readList(listPath)).toEqual([]);
  });

  it("returns parsed entries when file exists", async () => {
    fs.writeFileSync(listPath, JSON.stringify({ sessions: [sample()] }));
    const list = await readList(listPath);
    expect(list).toHaveLength(1);
    expect(list[0].claudeSessionId).toBe("abc-123");
  });

  it("returns empty array when file is unparseable", async () => {
    fs.writeFileSync(listPath, "not json");
    expect(await readList(listPath)).toEqual([]);
  });

  it("returns empty array when shape is wrong", async () => {
    fs.writeFileSync(listPath, JSON.stringify({ wrong: "shape" }));
    expect(await readList(listPath)).toEqual([]);
  });
});

describe("writeListAtomic", () => {
  it("writes the list to disk", async () => {
    await writeListAtomic(listPath, [sample()]);
    const raw = JSON.parse(fs.readFileSync(listPath, "utf8"));
    expect(raw.sessions).toHaveLength(1);
    expect(raw.sessions[0].claudeSessionId).toBe("abc-123");
  });

  it("does not leave a temp file behind on success", async () => {
    await writeListAtomic(listPath, [sample()]);
    const dir = path.dirname(listPath);
    const stragglers = fs.readdirSync(dir).filter((f) => f.endsWith(".tmp"));
    expect(stragglers).toEqual([]);
  });

  it("does not corrupt the existing file when the rename fails", async () => {
    // Pre-populate with a known good list
    await writeListAtomic(listPath, [sample({ claudeSessionId: "good" })]);

    // Force the rename to throw by stubbing fs.promises.rename.
    const orig = fs.promises.rename;
    (fs.promises as any).rename = vi.fn(async () => {
      throw new Error("simulated rename failure");
    });

    await expect(writeListAtomic(listPath, [sample({ claudeSessionId: "bad" })])).rejects.toThrow();

    (fs.promises as any).rename = orig;

    // Existing file content is unchanged.
    const raw = JSON.parse(fs.readFileSync(listPath, "utf8"));
    expect(raw.sessions[0].claudeSessionId).toBe("good");
  });
});

describe("addSession", () => {
  it("appends a new entry", async () => {
    await addSession(listPath, sample());
    const list = await readList(listPath);
    expect(list).toHaveLength(1);
  });

  it("is idempotent — re-adding the same desktopSessionId is a no-op", async () => {
    await addSession(listPath, sample());
    await addSession(listPath, sample({ topicName: "Different" }));
    const list = await readList(listPath);
    expect(list).toHaveLength(1);
    // Existing entry NOT overwritten.
    expect(list[0].topicName).toBe("Untitled");
  });
});

describe("removeSession", () => {
  it("removes by desktopSessionId", async () => {
    await addSession(listPath, sample({ desktopSessionId: "a" }));
    await addSession(listPath, sample({ desktopSessionId: "b" }));
    await removeSession(listPath, "a");
    const list = await readList(listPath);
    expect(list).toHaveLength(1);
    expect(list[0].desktopSessionId).toBe("b");
  });

  it("is idempotent — removing nonexistent ID is a no-op", async () => {
    await addSession(listPath, sample({ desktopSessionId: "a" }));
    await removeSession(listPath, "does-not-exist");
    const list = await readList(listPath);
    expect(list).toHaveLength(1);
  });
});

describe("updateTopic", () => {
  it("updates the topic and lastActivityMs for matching desktopSessionId", async () => {
    await addSession(listPath, sample({ desktopSessionId: "a", lastActivityMs: 1 }));
    await updateTopic(listPath, "a", "Fixing The Bug", 999);
    const list = await readList(listPath);
    expect(list[0].topicName).toBe("Fixing The Bug");
    expect(list[0].lastActivityMs).toBe(999);
  });

  it("is a no-op for unknown sessionId", async () => {
    await updateTopic(listPath, "ghost", "ignored", 999);
    const list = await readList(listPath);
    expect(list).toEqual([]);
  });
});

describe("pruneMissingTranscripts", () => {
  it("drops entries whose JSONL file does not exist anywhere under projectsDir", async () => {
    await addSession(listPath, sample({ claudeSessionId: "exists" }));
    await addSession(listPath, sample({ desktopSessionId: "ghost-d", claudeSessionId: "missing" }));

    const slug = "C--Users-dest-proj";
    fs.mkdirSync(path.join(projectsDir, slug), { recursive: true });
    fs.writeFileSync(path.join(projectsDir, slug, "exists.jsonl"), "{}");

    const survivors = await pruneMissingTranscripts(listPath, projectsDir);
    expect(survivors).toHaveLength(1);
    expect(survivors[0].claudeSessionId).toBe("exists");

    // The list on disk is also rewritten without the dropped entry.
    const persisted = await readList(listPath);
    expect(persisted).toHaveLength(1);
  });

  it("returns survivors with the resolved projectSlug attached", async () => {
    const slug = "C--Users-dest-proj";
    fs.mkdirSync(path.join(projectsDir, slug), { recursive: true });
    fs.writeFileSync(path.join(projectsDir, slug, "abc.jsonl"), "{}");
    await addSession(listPath, sample({ claudeSessionId: "abc" }));

    const survivors = await pruneMissingTranscripts(listPath, projectsDir);
    expect(survivors[0]).toMatchObject({ claudeSessionId: "abc", projectSlug: slug });
  });
});

describe("ActiveSessionsListPath", () => {
  it("resolves to ~/.claude/youcoded-active-sessions.json", () => {
    const expected = path.join(os.homedir(), ".claude", "youcoded-active-sessions.json");
    expect(ActiveSessionsListPath).toBe(expected);
  });
});
```

- [ ] **Step 2: Run the tests to confirm they all fail**

```bash
cd youcoded/desktop && npx vitest run src/main/active-sessions-store.test.ts
```

Expected: ALL fail with "Cannot find module './active-sessions-store'".

- [ ] **Step 3: Create the implementation**

Create `desktop/src/main/active-sessions-store.ts`:

```typescript
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { ActiveSession, ActiveSessionForRender } from "../shared/types";

/** Default location of the active-sessions list. */
export const ActiveSessionsListPath = path.join(
  os.homedir(),
  ".claude",
  "youcoded-active-sessions.json",
);

/** On-disk shape — wrapped in an object so we can add fields later without breaking parse. */
interface FileShape {
  sessions: ActiveSession[];
}

function isValidEntry(e: unknown): e is ActiveSession {
  if (!e || typeof e !== "object") return false;
  const o = e as Record<string, unknown>;
  return (
    typeof o.desktopSessionId === "string" &&
    typeof o.claudeSessionId === "string" &&
    typeof o.projectPath === "string" &&
    typeof o.topicName === "string" &&
    typeof o.lastActivityMs === "number"
  );
}

/**
 * Read the list. Returns [] for any failure mode (missing file, parse error,
 * wrong shape) — the file is best-effort persistence, never load-bearing.
 */
export async function readList(listPath: string): Promise<ActiveSession[]> {
  try {
    const raw = await fs.promises.readFile(listPath, "utf8");
    const parsed = JSON.parse(raw) as FileShape;
    if (!parsed || !Array.isArray(parsed.sessions)) return [];
    return parsed.sessions.filter(isValidEntry);
  } catch {
    return [];
  }
}

/**
 * Write atomically: write to a sibling temp file, then rename. If the rename
 * fails, the previous file is untouched. Caller is responsible for ensuring
 * the parent directory exists.
 */
export async function writeListAtomic(
  listPath: string,
  sessions: ActiveSession[],
): Promise<void> {
  const dir = path.dirname(listPath);
  await fs.promises.mkdir(dir, { recursive: true });
  // Use a per-call suffix so concurrent writers don't collide on the temp name.
  const tmp = `${listPath}.${process.pid}.${Date.now()}.tmp`;
  const body = JSON.stringify({ sessions } satisfies FileShape, null, 2);
  await fs.promises.writeFile(tmp, body, "utf8");
  try {
    await fs.promises.rename(tmp, listPath);
  } catch (err) {
    // Clean up temp file on rename failure so we don't accumulate cruft.
    try { await fs.promises.unlink(tmp); } catch {}
    throw err;
  }
}

/** Add an entry. Idempotent on desktopSessionId — re-adds are silently dropped. */
export async function addSession(listPath: string, entry: ActiveSession): Promise<void> {
  const list = await readList(listPath);
  if (list.some((e) => e.desktopSessionId === entry.desktopSessionId)) return;
  list.push(entry);
  await writeListAtomic(listPath, list);
}

/** Remove by desktopSessionId. Idempotent. */
export async function removeSession(listPath: string, desktopSessionId: string): Promise<void> {
  const list = await readList(listPath);
  const next = list.filter((e) => e.desktopSessionId !== desktopSessionId);
  if (next.length === list.length) return;
  await writeListAtomic(listPath, next);
}

/** Update the topic + lastActivity for a known session. No-op if not found. */
export async function updateTopic(
  listPath: string,
  desktopSessionId: string,
  topicName: string,
  lastActivityMs: number,
): Promise<void> {
  const list = await readList(listPath);
  const idx = list.findIndex((e) => e.desktopSessionId === desktopSessionId);
  if (idx === -1) return;
  list[idx] = { ...list[idx], topicName, lastActivityMs };
  await writeListAtomic(listPath, list);
}

/**
 * Drop entries whose JSONL transcript no longer exists, and return the
 * survivors with `projectSlug` attached (resolved by scanning projectsDir
 * for the matching `<claudeSessionId>.jsonl`). The on-disk list is rewritten
 * without the dropped entries.
 *
 * `lastUserMessage` and `lastAssistantMessage` are intentionally NOT populated
 * here — that's the read handler's job (it composes pruneMissingTranscripts
 * with loadHistory). This function only handles existence + slug resolution.
 */
export async function pruneMissingTranscripts(
  listPath: string,
  projectsDir: string,
): Promise<Omit<ActiveSessionForRender, "lastUserMessage" | "lastAssistantMessage">[]> {
  const list = await readList(listPath);
  if (list.length === 0) return [];

  let slugs: string[];
  try {
    const entries = await fs.promises.readdir(projectsDir);
    const stats = await Promise.all(
      entries.map(async (e) => {
        try {
          const s = await fs.promises.stat(path.join(projectsDir, e));
          return s.isDirectory() ? e : null;
        } catch { return null; }
      }),
    );
    slugs = stats.filter((s): s is string => s !== null);
  } catch {
    // Projects dir doesn't exist — no transcripts can possibly exist either.
    await writeListAtomic(listPath, []);
    return [];
  }

  const survivors: Omit<ActiveSessionForRender, "lastUserMessage" | "lastAssistantMessage">[] = [];
  const remaining: ActiveSession[] = [];

  for (const entry of list) {
    let foundSlug: string | null = null;
    for (const slug of slugs) {
      const candidate = path.join(projectsDir, slug, `${entry.claudeSessionId}.jsonl`);
      try {
        await fs.promises.access(candidate, fs.constants.R_OK);
        foundSlug = slug;
        break;
      } catch {}
    }
    if (foundSlug) {
      survivors.push({ ...entry, projectSlug: foundSlug });
      remaining.push(entry);
    }
  }

  if (remaining.length !== list.length) {
    await writeListAtomic(listPath, remaining);
  }
  return survivors;
}
```

- [ ] **Step 4: Run the tests to confirm they all pass**

```bash
cd youcoded/desktop && npx vitest run src/main/active-sessions-store.test.ts
```

Expected: ALL pass.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/active-sessions-store.ts desktop/src/main/active-sessions-store.test.ts
git commit -m "feat(resume-on-startup): active-sessions-store module with atomic write"
```

---

### Task 3: Wire lifecycle on the main side (add / remove / update-topic)

**Files:**
- Modify: `desktop/src/main/ipc-handlers.ts`

We need three lifecycle hooks:

1. **First user prompt → addSession.** Hook into the existing `transcriptWatcher.on('transcript-event', ...)`. The first `user-message` event for a given desktop session ID adds an entry. (User-interrupt and meta events are not user prompts — both are filtered upstream by the transcript watcher.)
2. **X-button close → removeSession.** Hook into `IPC.SESSION_DESTROY` handler — already an `ipcMain.handle` block in the file. After the existing destroy work, call `removeSession`.
3. **Topic file change → updateTopic.** Hook into the existing `broadcastRename(desktopId, name)` function — every rename already happens there, so adding the store update keeps it in one place.

Sessions that exit on their own (`session-exit` event) are NOT removed — per the spec, dead sessions stay in the list and are offered for resume. Only the deliberate X-button close removes.

- [ ] **Step 1: Add the import at the top of ipc-handlers.ts**

Find the imports section (top of file, after the existing `import path from 'path';` and similar). Add:

```typescript
import {
  addSession,
  removeSession,
  updateTopic,
  ActiveSessionsListPath,
} from './active-sessions-store';
```

- [ ] **Step 2: Track which sessions have already been recorded**

Inside `registerIpcHandlers()` (the function this file exports), find where `sessionIdMap` is declared (`const sessionIdMap = new Map<string, string>();`). Directly below it, add:

```typescript
  // Tracks desktop session IDs that have already been added to the
  // active-sessions list — avoids re-writing the file on every user
  // message. Cleared on session destroy.
  const recordedActiveSessions = new Set<string>();
```

- [ ] **Step 3: Hook the first user-message → addSession**

Find the existing `transcriptWatcher.on('transcript-event', ...)` block. Inside the callback, after the existing dispatch logic and BEFORE the closing `});`, add:

```typescript
    // Active-sessions list: add the entry the first time we observe a
    // real user prompt for this session. Idempotent in the store, but we
    // also gate via recordedActiveSessions to avoid hitting the file repeatedly.
    if (event.type === 'user-message') {
      const desktopId: string | undefined = event.sessionId;
      if (desktopId && !recordedActiveSessions.has(desktopId)) {
        const claudeId = sessionIdMap.get(desktopId);
        const sessionInfo = sessionManager.getSession(desktopId);
        if (claudeId && sessionInfo) {
          recordedActiveSessions.add(desktopId);
          const topic = readTopicFile(claudeId) || 'Untitled';
          addSession(ActiveSessionsListPath, {
            desktopSessionId: desktopId,
            claudeSessionId: claudeId,
            projectPath: sessionInfo.cwd,
            topicName: topic,
            lastActivityMs: Date.now(),
          }).catch((err) =>
            console.warn('[active-sessions] addSession failed:', err),
          );
        }
      }
    }
```

- [ ] **Step 4: Hook X-button close → removeSession**

Find the `ipcMain.handle(IPC.SESSION_DESTROY, ...)` handler. After the existing destroy call (whatever it currently does, leave it alone), add the removeSession call inside the same handler body. The handler currently looks roughly like:

```typescript
  ipcMain.handle(IPC.SESSION_DESTROY, async (_event, sessionId: string) => {
    try {
      sessionManager.destroy(sessionId);
      sendForSession(sessionId, IPC.SESSION_DESTROYED, sessionId, 0);
    } catch (err) {
      // ...
    }
    // ADD HERE:
    recordedActiveSessions.delete(sessionId);
    removeSession(ActiveSessionsListPath, sessionId).catch((err) =>
      console.warn('[active-sessions] removeSession failed:', err),
    );
  });
```

(If the actual handler has more logic, place the new lines AT THE END of the handler, after all existing work.)

- [ ] **Step 5: Hook topic update → updateTopic**

Find the existing `function broadcastRename(desktopId: string, name: string)` definition. At the end of its body (after the existing `windowRegistry?.emit('changed');`), add:

```typescript
    // Mirror topic changes into the active-sessions list so the resume
    // screen shows the latest auto-title. No-op if the session isn't tracked
    // (e.g., it was renamed before the first user prompt was sent).
    updateTopic(ActiveSessionsListPath, desktopId, name, Date.now()).catch((err) =>
      console.warn('[active-sessions] updateTopic failed:', err),
    );
```

- [ ] **Step 6: Verify typecheck**

```bash
cd youcoded/desktop && npx tsc --noEmit
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add desktop/src/main/ipc-handlers.ts
git commit -m "feat(resume-on-startup): wire add/remove/update-topic lifecycle into ipc-handlers"
```

---

### Task 4: Add the `session:active-list-read` handler

**Files:**
- Modify: `desktop/src/main/ipc-handlers.ts`

This handler runs on cold start. It composes `pruneMissingTranscripts` (drops entries with no JSONL on disk + resolves slugs) with the existing `loadHistory(claudeSessionId, projectSlug, count, all)` to produce `lastUserMessage` and `lastAssistantMessage` for each survivor. The renderer gets a single shot of fully-formed render data — no follow-up round trips.

- [ ] **Step 1: Add the import**

In the imports section of `ipc-handlers.ts`, find the existing `import { listPastSessions, loadHistory } from './session-browser';`. Add `pruneMissingTranscripts` to the active-sessions-store import you added in Task 3:

```typescript
import {
  addSession,
  removeSession,
  updateTopic,
  pruneMissingTranscripts,
  ActiveSessionsListPath,
} from './active-sessions-store';
```

- [ ] **Step 2: Register the handler**

Inside `registerIpcHandlers()`, find the existing block of session-browser handlers (look for `ipcMain.handle(IPC.SESSION_BROWSE` — they're together in the file). Directly below the session-browse handler, add:

```typescript
  // Resume-on-startup: returns the persisted active-sessions list, dropping
  // entries whose transcript is gone, plus precomputed last-user / last-assistant
  // previews so the resume screen has everything it needs in one round-trip.
  ipcMain.handle(IPC.SESSION_ACTIVE_LIST_READ, async () => {
    const projectsDir = path.join(os.homedir(), '.claude', 'projects');
    const survivors = await pruneMissingTranscripts(ActiveSessionsListPath, projectsDir);

    const enriched = await Promise.all(
      survivors.map(async (entry) => {
        let lastUserMessage = '';
        let lastAssistantMessage = '';
        try {
          // Tail-read the JSONL — loadHistory already handles deduplication
          // and content normalization. Asking for ALL history is fine; the
          // file's small enough on the resume-on-startup path (typically
          // sessions less than a day old) and we only keep the last entry
          // of each role.
          const history = await loadHistory(entry.claudeSessionId, entry.projectSlug, 0, true);
          for (let i = history.length - 1; i >= 0; i--) {
            if (!lastUserMessage && history[i].role === 'user') {
              lastUserMessage = history[i].content;
            }
            if (!lastAssistantMessage && history[i].role === 'assistant') {
              lastAssistantMessage = history[i].content;
            }
            if (lastUserMessage && lastAssistantMessage) break;
          }
        } catch (err) {
          console.warn(
            `[active-sessions] loadHistory failed for ${entry.claudeSessionId}:`,
            err,
          );
        }
        return { ...entry, lastUserMessage, lastAssistantMessage };
      }),
    );

    // Sort by lastActivityMs descending so the most recent session is on top.
    enriched.sort((a, b) => b.lastActivityMs - a.lastActivityMs);
    return enriched;
  });
```

(Note: `path` and `os` are already imported at the top of `ipc-handlers.ts` per the existing code at line 1621 — no new imports needed.)

- [ ] **Step 3: Verify typecheck**

```bash
cd youcoded/desktop && npx tsc --noEmit
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/main/ipc-handlers.ts
git commit -m "feat(resume-on-startup): session:active-list-read handler with previews"
```

---

### Task 5: Expose to renderer via preload + remote-shim parity

**Files:**
- Modify: `desktop/src/main/preload.ts`
- Modify: `desktop/src/renderer/remote-shim.ts`

Per the cross-platform parity rule (`docs/PITFALLS.md → Cross-Platform`), the same shape MUST appear in both files. Renderer code calls `window.claude.session.activeListRead()` and gets the same response shape on Electron (via IPC) and Android-WebView/remote (via WebSocket).

- [ ] **Step 1: Add the IPC constant + API to preload.ts**

In `desktop/src/main/preload.ts`, find the inlined `IPC` constants object (top of file). Add to it (alongside `SESSION_BROWSE`):

```typescript
  SESSION_ACTIVE_LIST_READ: 'session:active-list-read',
```

In the same file, find the `session: { ... }` block inside `contextBridge.exposeInMainWorld('claude', { ... })`. Look for `browse:` and `loadHistory:` — add directly below them:

```typescript
    activeListRead: (): Promise<any[]> =>
      ipcRenderer.invoke(IPC.SESSION_ACTIVE_LIST_READ),
```

- [ ] **Step 2: Mirror in remote-shim.ts**

Open `desktop/src/renderer/remote-shim.ts`. Find the existing `session.browse` and `session.loadHistory` mappings (the shim's `session` object that mirrors preload). Add directly below the loadHistory entry:

```typescript
      activeListRead: (): Promise<any[]> => invoke('session:active-list-read', {}),
```

(The exact spelling depends on the surrounding shim code — match the indentation and `invoke` helper style of the adjacent entries. The string `'session:active-list-read'` MUST be a literal — typos silently break Android.)

- [ ] **Step 3: Verify the API typecheck**

```bash
cd youcoded/desktop && npx tsc --noEmit
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/main/preload.ts desktop/src/renderer/remote-shim.ts
git commit -m "feat(resume-on-startup): expose session.activeListRead in preload + remote-shim"
```

---

### Task 6: Build the ResumeOnStartupScreen component (TDD)

**Files:**
- Create: `desktop/src/renderer/components/ResumeOnStartupScreen.tsx`
- Create: `desktop/src/renderer/components/ResumeOnStartupScreen.test.tsx`

The screen takes a list of `ActiveSessionForRender` and two callbacks: `onResumeSelected(selected: ActiveSessionForRender[])` and `onStartFresh()`. It manages its own checkbox state. ESC does nothing on this screen. No animation — the parent App.tsx will swap it for the chat view on resume.

- [ ] **Step 1: Write the failing tests**

Create `desktop/src/renderer/components/ResumeOnStartupScreen.test.tsx`:

```typescript
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ResumeOnStartupScreen } from "./ResumeOnStartupScreen";
import type { ActiveSessionForRender } from "../../shared/types";

const fixture = (overrides: Partial<ActiveSessionForRender> = {}): ActiveSessionForRender => ({
  desktopSessionId: "desk-1",
  claudeSessionId: "abc-123",
  projectPath: "C:\\Users\\dest\\proj",
  projectSlug: "C--Users-dest-proj",
  topicName: "Investigating The Bug",
  lastActivityMs: Date.now() - 12 * 60 * 1000,
  lastUserMessage: "what's wrong with the spinner regex",
  lastAssistantMessage: "the regex is anchored to start of line which means…",
  ...overrides,
});

describe("ResumeOnStartupScreen", () => {
  it("renders the welcome-back header", () => {
    render(
      <ResumeOnStartupScreen
        sessions={[fixture()]}
        onResumeSelected={vi.fn()}
        onStartFresh={vi.fn()}
      />,
    );
    expect(screen.getByText(/Welcome back/i)).toBeTruthy();
  });

  it("renders one card per session", () => {
    render(
      <ResumeOnStartupScreen
        sessions={[fixture({ desktopSessionId: "a", topicName: "First" }), fixture({ desktopSessionId: "b", topicName: "Second" })]}
        onResumeSelected={vi.fn()}
        onStartFresh={vi.fn()}
      />,
    );
    expect(screen.getByText("First")).toBeTruthy();
    expect(screen.getByText("Second")).toBeTruthy();
  });

  it("checks all boxes by default and labels the button 'Resume all (N)'", () => {
    render(
      <ResumeOnStartupScreen
        sessions={[fixture({ desktopSessionId: "a" }), fixture({ desktopSessionId: "b" })]}
        onResumeSelected={vi.fn()}
        onStartFresh={vi.fn()}
      />,
    );
    const button = screen.getByRole("button", { name: /Resume all \(2\)/i });
    expect(button).toBeTruthy();
    expect(button.hasAttribute("disabled")).toBe(false);
  });

  it("renders a single 'Resume' button (no count, no plural) when exactly one session", () => {
    render(
      <ResumeOnStartupScreen
        sessions={[fixture()]}
        onResumeSelected={vi.fn()}
        onStartFresh={vi.fn()}
      />,
    );
    const button = screen.getByRole("button", { name: /^Resume$/i });
    expect(button).toBeTruthy();
  });

  it("toggles a card's checkbox on row click and updates the button to 'Resume selected (M)'", () => {
    render(
      <ResumeOnStartupScreen
        sessions={[fixture({ desktopSessionId: "a", topicName: "AAA" }), fixture({ desktopSessionId: "b" })]}
        onResumeSelected={vi.fn()}
        onStartFresh={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByText("AAA").closest("[data-resume-card]")!);
    expect(screen.getByRole("button", { name: /Resume selected \(1\)/i })).toBeTruthy();
  });

  it("disables the resume button when zero are checked", () => {
    render(
      <ResumeOnStartupScreen
        sessions={[fixture()]}
        onResumeSelected={vi.fn()}
        onStartFresh={vi.fn()}
      />,
    );
    fireEvent.click(screen.getByText(fixture().topicName).closest("[data-resume-card]")!);
    const button = screen.getByRole("button", { name: /Resume/i });
    expect(button.hasAttribute("disabled")).toBe(true);
  });

  it("calls onResumeSelected with only the checked sessions", () => {
    const onResume = vi.fn();
    render(
      <ResumeOnStartupScreen
        sessions={[fixture({ desktopSessionId: "a" }), fixture({ desktopSessionId: "b" })]}
        onResumeSelected={onResume}
        onStartFresh={vi.fn()}
      />,
    );
    // Uncheck "a"
    fireEvent.click(screen.getAllByRole("button", { name: /Investigating/i })[0]);
    fireEvent.click(screen.getByRole("button", { name: /Resume selected/i }));
    expect(onResume).toHaveBeenCalledTimes(1);
    const arg: ActiveSessionForRender[] = onResume.mock.calls[0][0];
    expect(arg).toHaveLength(1);
    expect(arg[0].desktopSessionId).toBe("b");
  });

  it("calls onStartFresh when the 'Start fresh' link is clicked", () => {
    const onStartFresh = vi.fn();
    render(
      <ResumeOnStartupScreen
        sessions={[fixture()]}
        onResumeSelected={vi.fn()}
        onStartFresh={onStartFresh}
      />,
    );
    fireEvent.click(screen.getByRole("button", { name: /Start fresh/i }));
    expect(onStartFresh).toHaveBeenCalledTimes(1);
  });

  it("renders 'Untitled' topic without crashing", () => {
    render(
      <ResumeOnStartupScreen
        sessions={[fixture({ topicName: "Untitled" })]}
        onResumeSelected={vi.fn()}
        onStartFresh={vi.fn()}
      />,
    );
    expect(screen.getByText("Untitled")).toBeTruthy();
  });

  it("handles empty preview text gracefully", () => {
    render(
      <ResumeOnStartupScreen
        sessions={[fixture({ lastUserMessage: "", lastAssistantMessage: "" })]}
        onResumeSelected={vi.fn()}
        onStartFresh={vi.fn()}
      />,
    );
    // Should still render the card without a preview row
    expect(screen.getByText(fixture().topicName)).toBeTruthy();
  });
});
```

- [ ] **Step 2: Run the tests to confirm they all fail**

```bash
cd youcoded/desktop && npx vitest run src/renderer/components/ResumeOnStartupScreen.test.tsx
```

Expected: ALL fail with "Cannot find module './ResumeOnStartupScreen'".

- [ ] **Step 3: Create the component**

Create `desktop/src/renderer/components/ResumeOnStartupScreen.tsx`:

```typescript
import React, { useState, useMemo } from 'react';
import type { ActiveSessionForRender } from '../../shared/types';

interface Props {
  sessions: ActiveSessionForRender[];
  onResumeSelected: (selected: ActiveSessionForRender[]) => void;
  onStartFresh: () => void;
}

function formatRelativeTime(epochMs: number): string {
  const diff = Date.now() - epochMs;
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d ago`;
  return new Date(epochMs).toLocaleDateString();
}

// Pull the rightmost path segment for the project label so a long
// projectPath like 'C:\Users\dest\src\youcoded-dev' still fits one line.
function shortProjectName(projectPath: string): string {
  const norm = projectPath.replace(/[\\/]+$/, '');
  const parts = norm.split(/[\\/]/);
  return parts[parts.length - 1] || projectPath;
}

export function ResumeOnStartupScreen({ sessions, onResumeSelected, onStartFresh }: Props) {
  // Default: all checked. Map keyed by desktopSessionId.
  const [checked, setChecked] = useState<Set<string>>(
    () => new Set(sessions.map((s) => s.desktopSessionId)),
  );

  const toggle = (id: string) => {
    setChecked((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const checkedCount = checked.size;
  const totalCount = sessions.length;
  const allChecked = checkedCount === totalCount;

  const buttonLabel = useMemo(() => {
    if (totalCount === 1) return 'Resume';
    if (allChecked) return `Resume all (${totalCount})`;
    return `Resume selected (${checkedCount})`;
  }, [allChecked, checkedCount, totalCount]);

  const handleResume = () => {
    if (checkedCount === 0) return;
    const selected = sessions.filter((s) => checked.has(s.desktopSessionId));
    onResumeSelected(selected);
  };

  return (
    <div className="flex-1 flex flex-col items-center justify-center gap-6 px-6 py-8 max-h-screen overflow-y-auto">
      <div className="text-center max-w-xl">
        <h1 className="text-2xl font-medium text-fg">Welcome back.</h1>
        <p className="text-sm text-fg-muted mt-2">
          YouCoded closed with active sessions. Pick which ones to bring back.
        </p>
      </div>

      <div className="flex flex-col gap-2 w-full max-w-2xl">
        {sessions.map((s) => {
          const isChecked = checked.has(s.desktopSessionId);
          return (
            <button
              key={s.desktopSessionId}
              type="button"
              data-resume-card
              onClick={() => toggle(s.desktopSessionId)}
              aria-pressed={isChecked}
              className={`layer-surface w-full text-left p-4 flex gap-3 transition-colors ${
                isChecked
                  ? 'border border-accent'
                  : 'border border-edge-dim hover:border-edge'
              }`}
            >
              <div className="flex-shrink-0 mt-0.5">
                <input
                  type="checkbox"
                  checked={isChecked}
                  readOnly
                  tabIndex={-1}
                  aria-hidden
                  className="pointer-events-none"
                />
              </div>
              <div className="flex-1 min-w-0">
                <div className="text-base font-medium text-fg truncate">{s.topicName}</div>
                <div className="text-xs text-fg-muted mt-0.5">
                  {shortProjectName(s.projectPath)} · {formatRelativeTime(s.lastActivityMs)}
                </div>
                {s.lastUserMessage ? (
                  <div className="text-sm text-fg-dim italic mt-2 truncate">
                    "{s.lastUserMessage}"
                  </div>
                ) : null}
                {s.lastAssistantMessage ? (
                  <div className="text-sm text-fg-muted mt-1 truncate">
                    {s.lastAssistantMessage}
                  </div>
                ) : null}
              </div>
            </button>
          );
        })}
      </div>

      <div className="flex flex-col items-center gap-2 mt-2">
        <button
          type="button"
          onClick={handleResume}
          disabled={checkedCount === 0}
          className="px-6 py-2 rounded-md bg-accent text-on-accent font-medium disabled:opacity-50 disabled:cursor-not-allowed"
        >
          {buttonLabel}
        </button>
        <button
          type="button"
          onClick={onStartFresh}
          className="text-sm text-fg-muted hover:text-fg-dim transition-colors"
        >
          Start fresh
        </button>
      </div>
    </div>
  );
}
```

- [ ] **Step 4: Run the tests to confirm they all pass**

```bash
cd youcoded/desktop && npx vitest run src/renderer/components/ResumeOnStartupScreen.test.tsx
```

Expected: ALL pass.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/renderer/components/ResumeOnStartupScreen.tsx desktop/src/renderer/components/ResumeOnStartupScreen.test.tsx
git commit -m "feat(resume-on-startup): ResumeOnStartupScreen component"
```

---

### Task 7: Wire the screen into App.tsx (cold-start gate + handlers)

**Files:**
- Modify: `desktop/src/renderer/App.tsx`

The screen should render BEFORE the welcome screen, only on cold start, only if `activeListRead` returns a non-empty list. After the user picks Resume or Start fresh, the screen unmounts and the normal app flow continues.

The Resume path reuses the existing `handleResumeSession` callback (already in App.tsx at line ~1579) — call it once per selected session. The first selected session is created with focus; subsequent ones are created in the background.

- [ ] **Step 1: Add the import**

At the top of `App.tsx`, alongside other component imports, add:

```typescript
import { ResumeOnStartupScreen } from './components/ResumeOnStartupScreen';
import type { ActiveSessionForRender } from '../shared/types';
```

- [ ] **Step 2: Add cold-start state**

Inside `AppInner` (the main app component), find the existing welcome-related state (`welcomeFormOpen`, `welcomeCwd`, etc., around line 281). Directly below those, add:

```typescript
  // Cold-start resume flow:
  //  - null  = haven't read the list yet (initial state on mount)
  //  - []    = list was empty or all entries failed precheck (skip the screen)
  //  - [...] = show the resume screen with these survivors
  //  - 'dismissed' = user picked Start fresh OR completed Resume — skip the screen
  const [activeListAtBoot, setActiveListAtBoot] = useState<
    ActiveSessionForRender[] | 'loading' | 'dismissed'
  >('loading');
```

- [ ] **Step 3: Read the list on mount**

Find the existing `useEffect` blocks near the top of `AppInner` that run on mount (look for `useEffect(() => {`, an empty deps array `[]`). Add a new `useEffect`:

```typescript
  useEffect(() => {
    let cancelled = false;
    const read = (window as any).claude?.session?.activeListRead;
    if (typeof read !== 'function') {
      setActiveListAtBoot([]);
      return;
    }
    read()
      .then((list: ActiveSessionForRender[]) => {
        if (cancelled) return;
        setActiveListAtBoot(Array.isArray(list) && list.length > 0 ? list : []);
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        console.warn('[resume-on-startup] activeListRead failed:', err);
        setActiveListAtBoot([]);
      });
    return () => { cancelled = true; };
  }, []);
```

- [ ] **Step 4: Add the resume-all handler**

Inside `AppInner`, near the existing `handleResumeSession` (line ~1579), add:

```typescript
  const handleResumeAll = useCallback(
    async (selected: ActiveSessionForRender[]) => {
      // Sort by lastActivityMs descending — the first one resumed gets focus,
      // and we want that to be the most recent. The list arrives sorted
      // from the read handler, but defending against caller mutation is cheap.
      const ordered = [...selected].sort((a, b) => b.lastActivityMs - a.lastActivityMs);

      // Hide the resume screen optimistically — the chat view will show
      // the resuming tabs as they spawn.
      setActiveListAtBoot('dismissed');

      // Spawn each session sequentially. handleResumeSession already calls
      // session.create with --resume <id> + dispatches HISTORY_LOADED, so
      // there's nothing left for us to do per-session.
      for (const entry of ordered) {
        try {
          await handleResumeSession(
            entry.claudeSessionId,
            entry.projectSlug,
            entry.projectPath,
          );
        } catch (err) {
          console.error('[resume-on-startup] resume failed for', entry.desktopSessionId, err);
        }
      }
    },
    [handleResumeSession],
  );

  const handleStartFresh = useCallback(() => {
    setActiveListAtBoot('dismissed');
    // Clear the persisted list so a subsequent quit/crash doesn't re-offer
    // the same sessions. The IPC handler doesn't expose a clear, but
    // calling activeListRead after pruning is fine — we just need the
    // file to not have stale entries. Easiest: write an empty list via
    // a new helper. For v1 we can simply call session.destroy on each
    // entry's desktopSessionId — but those sessions don't exist this
    // run, so destroy is a no-op. Instead use a dedicated clear-all:
    (window as any).claude?.session?.activeListClear?.();
  }, []);
```

(Note: `activeListClear` is not yet defined — Task 8 below adds it. For this task, the call is a forward reference; it'll resolve in the next commit.)

- [ ] **Step 5: Render the screen ahead of welcome**

Find the existing welcome-screen render block (around line 2129, the `<div className="flex-1 flex flex-col items-center justify-center gap-3">` for "No Active Session"). The structure is:

```tsx
{sessionId ? (
  // ... chat view ...
) : (
  // ... welcome screen ...
)}
```

Wrap the welcome side in a resume-screen check. Replace the welcome JSX expression with:

```tsx
{activeListAtBoot === 'loading' ? (
  // Brief blank state while we read the file. Avoids a flash of the
  // welcome screen if the user has sessions to resume.
  <div className="flex-1" />
) : Array.isArray(activeListAtBoot) && activeListAtBoot.length > 0 ? (
  <ResumeOnStartupScreen
    sessions={activeListAtBoot}
    onResumeSelected={handleResumeAll}
    onStartFresh={handleStartFresh}
  />
) : (
  // ... existing welcome screen JSX (unchanged) ...
)}
```

Keep the existing welcome JSX intact in the third branch — don't restructure it.

- [ ] **Step 6: Verify typecheck and tests still pass**

```bash
cd youcoded/desktop && npx tsc --noEmit && npx vitest run
```

Expected: PASS on both.

- [ ] **Step 7: Commit**

```bash
git add desktop/src/renderer/App.tsx
git commit -m "feat(resume-on-startup): render screen on cold start, wire Resume/Start-fresh"
```

---

### Task 8: Add the `session:active-list-clear` handler + plumbing

**Files:**
- Modify: `desktop/src/shared/types.ts`
- Modify: `desktop/src/main/active-sessions-store.ts`
- Modify: `desktop/src/main/active-sessions-store.test.ts`
- Modify: `desktop/src/main/ipc-handlers.ts`
- Modify: `desktop/src/main/preload.ts`
- Modify: `desktop/src/renderer/remote-shim.ts`

The Start-fresh button needs to wipe the list. Add a `clearList` helper to the store, an IPC handler, and parity entries.

- [ ] **Step 1: Add the IPC constant in types.ts**

Next to `SESSION_ACTIVE_LIST_READ`:

```typescript
  SESSION_ACTIVE_LIST_CLEAR: 'session:active-list-clear',
```

- [ ] **Step 2: Add a clearList test**

In `desktop/src/main/active-sessions-store.test.ts`, after the `pruneMissingTranscripts` describe block, append:

```typescript
import { clearList } from "./active-sessions-store";

describe("clearList", () => {
  it("removes all entries", async () => {
    await addSession(listPath, sample({ desktopSessionId: "a" }));
    await addSession(listPath, sample({ desktopSessionId: "b" }));
    await clearList(listPath);
    expect(await readList(listPath)).toEqual([]);
  });

  it("is a no-op when the file does not exist", async () => {
    await clearList(listPath);
    expect(fs.existsSync(listPath)).toBe(true);
    expect(await readList(listPath)).toEqual([]);
  });
});
```

(Move the `clearList` import up to the existing import-from-store block. Listed separately above for clarity.)

- [ ] **Step 3: Run the test to confirm it fails**

```bash
cd youcoded/desktop && npx vitest run src/main/active-sessions-store.test.ts
```

Expected: the new tests fail with "clearList is not a function" (or similar).

- [ ] **Step 4: Add the clearList implementation**

In `desktop/src/main/active-sessions-store.ts`, append at the bottom:

```typescript
/** Wipe the list. Idempotent — empty file after, regardless of prior state. */
export async function clearList(listPath: string): Promise<void> {
  await writeListAtomic(listPath, []);
}
```

- [ ] **Step 5: Confirm tests pass**

```bash
cd youcoded/desktop && npx vitest run src/main/active-sessions-store.test.ts
```

Expected: ALL pass.

- [ ] **Step 6: Register the IPC handler**

In `desktop/src/main/ipc-handlers.ts`, update the active-sessions-store import to include `clearList`:

```typescript
import {
  addSession,
  removeSession,
  updateTopic,
  pruneMissingTranscripts,
  clearList,
  ActiveSessionsListPath,
} from './active-sessions-store';
```

Below the `IPC.SESSION_ACTIVE_LIST_READ` handler, add:

```typescript
  ipcMain.handle(IPC.SESSION_ACTIVE_LIST_CLEAR, async () => {
    await clearList(ActiveSessionsListPath);
    return { ok: true };
  });
```

- [ ] **Step 7: Expose to preload + remote-shim**

In `desktop/src/main/preload.ts`:

```typescript
  // In the IPC constants object:
  SESSION_ACTIVE_LIST_CLEAR: 'session:active-list-clear',
```

```typescript
    // In the session: { ... } block, next to activeListRead:
    activeListClear: (): Promise<{ ok: boolean }> =>
      ipcRenderer.invoke(IPC.SESSION_ACTIVE_LIST_CLEAR),
```

In `desktop/src/renderer/remote-shim.ts`, in the `session` object next to `activeListRead`:

```typescript
      activeListClear: (): Promise<{ ok: boolean }> =>
        invoke('session:active-list-clear', {}),
```

- [ ] **Step 8: Verify typecheck and tests**

```bash
cd youcoded/desktop && npx tsc --noEmit && npx vitest run
```

Expected: ALL pass.

- [ ] **Step 9: Commit**

```bash
git add desktop/src/shared/types.ts desktop/src/main/active-sessions-store.ts desktop/src/main/active-sessions-store.test.ts desktop/src/main/ipc-handlers.ts desktop/src/main/preload.ts desktop/src/renderer/remote-shim.ts
git commit -m "feat(resume-on-startup): activeListClear API for the Start-fresh path"
```

---

### Task 9: Android Kotlin mirror — store + lifecycle wiring

**Files:**
- Create: `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/ActiveSessionsStore.kt`
- Modify: `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt`

The Kotlin store is a strict subset of the desktop one — it reads/writes the same JSON shape into Android's own `~/.claude/youcoded-active-sessions.json` (which lives inside the Termux env, separate from desktop's). Same atomic-rename pattern.

- [ ] **Step 1: Create the Kotlin store**

Create `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/ActiveSessionsStore.kt`:

```kotlin
package com.youcoded.app.runtime

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Active-sessions list mirror for Android.
 *
 * Same JSON shape as desktop's active-sessions-store.ts. Each platform owns
 * its own copy of the file (Android's ~/.claude lives inside the Termux env,
 * separate from desktop's). See:
 *   docs/superpowers/specs/2026-05-01-resume-active-sessions-on-startup-design.md
 *   desktop/src/main/active-sessions-store.ts
 *
 * On-disk shape:
 *   { "sessions": [ { desktopSessionId, claudeSessionId, projectPath, topicName, lastActivityMs } ] }
 */
class ActiveSessionsStore(private val homeDir: File) {

    private val listFile: File
        get() = File(File(homeDir, ".claude"), "youcoded-active-sessions.json")

    data class Entry(
        val desktopSessionId: String,
        val claudeSessionId: String,
        val projectPath: String,
        val topicName: String,
        val lastActivityMs: Long,
    )

    @Synchronized
    fun read(): List<Entry> {
        return try {
            if (!listFile.exists()) return emptyList()
            val obj = JSONObject(listFile.readText())
            val arr = obj.optJSONArray("sessions") ?: return emptyList()
            (0 until arr.length()).mapNotNull { i ->
                val e = arr.optJSONObject(i) ?: return@mapNotNull null
                runCatching {
                    Entry(
                        desktopSessionId = e.getString("desktopSessionId"),
                        claudeSessionId = e.getString("claudeSessionId"),
                        projectPath = e.getString("projectPath"),
                        topicName = e.getString("topicName"),
                        lastActivityMs = e.getLong("lastActivityMs"),
                    )
                }.getOrNull()
            }
        } catch (t: Throwable) {
            emptyList()
        }
    }

    @Synchronized
    fun write(entries: List<Entry>) {
        listFile.parentFile?.mkdirs()
        val arr = JSONArray()
        for (e in entries) {
            arr.put(
                JSONObject().apply {
                    put("desktopSessionId", e.desktopSessionId)
                    put("claudeSessionId", e.claudeSessionId)
                    put("projectPath", e.projectPath)
                    put("topicName", e.topicName)
                    put("lastActivityMs", e.lastActivityMs)
                },
            )
        }
        val body = JSONObject().apply { put("sessions", arr) }.toString(2)
        // Atomic rename: write temp, then move.
        val tmp = File(listFile.parentFile, "${listFile.name}.${System.nanoTime()}.tmp")
        tmp.writeText(body)
        if (!tmp.renameTo(listFile)) {
            tmp.delete()
            throw java.io.IOException("rename ${tmp.path} -> ${listFile.path} failed")
        }
    }

    @Synchronized
    fun add(entry: Entry) {
        val current = read()
        if (current.any { it.desktopSessionId == entry.desktopSessionId }) return
        write(current + entry)
    }

    @Synchronized
    fun remove(desktopSessionId: String) {
        val current = read()
        val next = current.filter { it.desktopSessionId != desktopSessionId }
        if (next.size == current.size) return
        write(next)
    }

    @Synchronized
    fun updateTopic(desktopSessionId: String, topicName: String, lastActivityMs: Long) {
        val current = read()
        val idx = current.indexOfFirst { it.desktopSessionId == desktopSessionId }
        if (idx == -1) return
        val updated = current.toMutableList()
        updated[idx] = updated[idx].copy(topicName = topicName, lastActivityMs = lastActivityMs)
        write(updated)
    }

    @Synchronized
    fun clear() {
        write(emptyList())
    }

    /**
     * Drop entries whose JSONL file no longer exists, returning survivors with
     * resolved projectSlug. Mirrors pruneMissingTranscripts from desktop.
     *
     * `projectsDir` is `~/.claude/projects` inside Android's Termux env.
     */
    @Synchronized
    fun pruneMissingTranscripts(projectsDir: File): List<Pair<Entry, String>> {
        val current = read()
        if (current.isEmpty()) return emptyList()
        val slugs = projectsDir.listFiles { f -> f.isDirectory }?.map { it.name } ?: emptyList()
        val survivors = mutableListOf<Pair<Entry, String>>()
        val remaining = mutableListOf<Entry>()
        for (entry in current) {
            val slug = slugs.firstOrNull { slug ->
                File(File(projectsDir, slug), "${entry.claudeSessionId}.jsonl").exists()
            }
            if (slug != null) {
                survivors.add(entry to slug)
                remaining.add(entry)
            }
        }
        if (remaining.size != current.size) write(remaining)
        return survivors
    }
}
```

- [ ] **Step 2: Wire SessionService — instantiate the store**

In `youcoded/app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt`, find where other long-lived state is initialized in the class (the `Bootstrap`, `SessionRegistry`, etc.). Add:

```kotlin
private val activeSessionsStore: ActiveSessionsStore by lazy {
    // Android's ~/.claude lives inside the Termux env. The bootstrap helper
    // exposes the resolved $HOME — use that, not Environment.getDataDirectory().
    ActiveSessionsStore(File(bootstrap.homeDir))
}
private val recordedActiveSessions = mutableSetOf<String>()
```

(Match the surrounding style — if `bootstrap.homeDir` doesn't exist exactly under that name, use whichever existing field exposes the Termux `$HOME` path. `AnnouncementService.kt` is a reference for the same pattern — copy how it resolves home.)

- [ ] **Step 3: Wire SessionService — add on first user message**

Find the transcript-event-emit path in `SessionService` (search for `user-message` or wherever transcript events are dispatched to the WebSocket). Add a side-effect when the type is `user-message`:

```kotlin
if (event.type == "user-message") {
    val desktopId = event.sessionId
    if (desktopId != null && desktopId !in recordedActiveSessions) {
        val claudeId = sessionIdMap[desktopId]
        val sessionInfo = sessionRegistry.get(desktopId)
        if (claudeId != null && sessionInfo != null) {
            recordedActiveSessions.add(desktopId)
            val topic = readTopicFile(claudeId) ?: "Untitled"
            try {
                activeSessionsStore.add(
                    ActiveSessionsStore.Entry(
                        desktopSessionId = desktopId,
                        claudeSessionId = claudeId,
                        projectPath = sessionInfo.cwd,
                        topicName = topic,
                        lastActivityMs = System.currentTimeMillis(),
                    ),
                )
            } catch (t: Throwable) {
                Log.w("ActiveSessions", "add failed", t)
            }
        }
    }
}
```

(`sessionIdMap`, `sessionRegistry`, `readTopicFile` may have different names in `SessionService.kt` — match the existing field names. Don't introduce new private fields beyond `recordedActiveSessions`.)

- [ ] **Step 4: Wire SessionService — remove on session destroy**

Find the existing `session:destroy` handler in `SessionService.handleBridgeMessage()`. After the existing destroy work:

```kotlin
recordedActiveSessions.remove(desktopId)
try { activeSessionsStore.remove(desktopId) } catch (t: Throwable) {
    Log.w("ActiveSessions", "remove failed", t)
}
```

- [ ] **Step 5: Wire SessionService — update on topic change**

Find the existing topic-watch / rename broadcast path (search for `session:renamed`). After the broadcast, add:

```kotlin
try {
    activeSessionsStore.updateTopic(desktopId, name, System.currentTimeMillis())
} catch (t: Throwable) {
    Log.w("ActiveSessions", "updateTopic failed", t)
}
```

- [ ] **Step 6: Add the `session:active-list-read` and `clear` handlers**

In `SessionService.handleBridgeMessage()`, add two new `when` cases:

```kotlin
"session:active-list-read" -> {
    val projectsDir = File(File(bootstrap.homeDir), ".claude/projects")
    val survivors = activeSessionsStore.pruneMissingTranscripts(projectsDir)
    val arr = JSONArray()
    for ((entry, slug) in survivors) {
        // For now, lastUserMessage / lastAssistantMessage are returned as
        // empty strings on Android. Adding the JSONL tail-read here is a
        // follow-up — the screen renders fine without previews, just less
        // informatively. Tracked in the spec's "future work" section if any.
        arr.put(
            JSONObject().apply {
                put("desktopSessionId", entry.desktopSessionId)
                put("claudeSessionId", entry.claudeSessionId)
                put("projectPath", entry.projectPath)
                put("topicName", entry.topicName)
                put("lastActivityMs", entry.lastActivityMs)
                put("projectSlug", slug)
                put("lastUserMessage", "")
                put("lastAssistantMessage", "")
            },
        )
    }
    bridgeServer.respond(ws, msg.type, msg.id, arr)
}

"session:active-list-clear" -> {
    try { activeSessionsStore.clear() } catch (_: Throwable) {}
    bridgeServer.respond(ws, msg.type, msg.id, JSONObject().put("ok", true))
}
```

(The Android-side previews are deliberately omitted in v1 — Android already has a JSONL parser via the Node-CLI transcript watcher path, but tail-reading from Kotlin would mean re-implementing the loadHistory dedup logic. v1 ships without previews on Android; the screen still works and the desktop's main use case is fully covered.)

- [ ] **Step 7: Verify Android builds**

From the workspace root:

```bash
cd youcoded && ./gradlew :app:assembleDebug
```

Expected: BUILD SUCCESSFUL.

- [ ] **Step 8: Commit**

```bash
git add app/src/main/kotlin/com/youcoded/app/runtime/ActiveSessionsStore.kt app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt
git commit -m "feat(resume-on-startup): Android Kotlin mirror — store + lifecycle wiring"
```

---

### Task 10: Update PITFALLS with the cross-platform pattern

**Files:**
- Modify: `youcoded-dev/docs/PITFALLS.md`

This adds an entry so future maintainers don't get tripped up by the "same shape, separate file" architecture.

- [ ] **Step 1: Append a new section**

Open `youcoded-dev/docs/PITFALLS.md`. Find the existing "Sync Warnings" section (it's a multi-platform-state section that's a good template). Add a new section directly above or below it (alphabetical wins; "Active Sessions Persistence" goes near the top):

```markdown
## Active Sessions Persistence (Resume-on-Startup)

The active-sessions list at `~/.claude/youcoded-active-sessions.json` powers the cold-start "Welcome back" resume screen. A few invariants to preserve.

- **Same JSON shape, separate per-platform file.** Desktop writes from `desktop/src/main/active-sessions-store.ts`; Android writes from `app/.../runtime/ActiveSessionsStore.kt`. Each platform's `~/.claude` is a separate filesystem location (Android's lives inside the Termux env). The file shape is locked: `{ sessions: [{ desktopSessionId, claudeSessionId, projectPath, topicName, lastActivityMs }] }`. Adding a field requires touching both writers — a fixture parity test in `active-sessions-store.test.ts` round-trips the canonical sample.
- **Lifecycle is eager, not on-quit.** Add on first user message, remove on X-button close, update on topic file change. App quit / window close / crash / OS kill leave the file as-is — the resume screen relies on that. Do NOT add a "clear list on quit" path; it would defeat the entire feature.
- **Sessions ending via `session-died` stay in the list.** No `diedUnexpectedly` flag, no badge — they're treated identically to clean exits per the design spec. If a future change wants to differentiate, it goes in a new field, not by overloading `lastActivityMs`.
- **Read-time precheck is mandatory.** The list can outlive the JSONL transcripts (user wipes `~/.claude/projects/`, etc.). `pruneMissingTranscripts` resolves the slug for each entry by scanning project dirs and silently drops entries whose JSONL is gone, rewriting the file as a side effect. Don't trust the list at read time without it.
- **Atomic rename, always.** `writeListAtomic` writes to a temp sibling and renames. Don't `fs.writeFile` directly — a yanked power cord mid-write leaves the user with an empty/partial file and the next startup loses everything.
- **`recordedActiveSessions` is a runtime-only set.** It exists to skip redundant file writes on every user message — the store's `addSession` is already idempotent on `desktopSessionId`, so the cache is purely a perf optimization. Don't persist it; don't share it across processes.
- **The IPC type strings (`session:active-list-read`, `session:active-list-clear`) are exact.** Per the cross-platform parity rule, a typo silently breaks one platform. Verified by `tests/ipc-channels.test.ts` (if you add a third channel here, add it to the test).
```

- [ ] **Step 2: Commit (in the workspace repo, not the youcoded sub-repo)**

```bash
cd C:/Users/desti/youcoded-dev
git add docs/PITFALLS.md
git commit -m "docs(pitfalls): document active-sessions persistence invariants"
```

(This commit lands on the workspace `master` directly — workspace docs aren't gated by a sub-repo PR. Push to origin when ready.)

---

## Final verification

After all tasks complete, before merging the worktree to master:

- [ ] **Run the full desktop test suite from the worktree's `youcoded/desktop/`:**
  ```bash
  npm test
  ```
  Expected: all green.

- [ ] **Build desktop to confirm the renderer compiles:**
  ```bash
  npm run build
  ```
  Expected: BUILD SUCCESSFUL.

- [ ] **Build Android debug from the worktree's `youcoded/`:**
  ```bash
  ./gradlew :app:assembleDebug
  ```
  Expected: BUILD SUCCESSFUL.

- [ ] **Manual smoke test on desktop:**
  1. `bash scripts/run-dev.sh` from the workspace root.
  2. Open YouCoded Dev. Create 2 sessions. Send a prompt in each.
  3. Verify `~/.claude/youcoded-active-sessions.json` exists and has 2 entries.
  4. Force-quit the dev Electron (Activity Monitor / Task Manager — NOT the X button on a session).
  5. Re-launch via `bash scripts/run-dev.sh`. Verify the resume screen appears with both sessions, both checked, last-message previews populated.
  6. Click "Resume all (2)". Verify both sessions reappear in the strip and chat history loads.
  7. Quit again. Re-launch. Close one session via the X button. Quit. Re-launch — only the remaining session is offered.
  8. Click "Start fresh". Verify the welcome screen appears and the file on disk is now `{"sessions":[]}`.

- [ ] **Manual smoke test on Android:**
  1. Install the debug APK (`adb install -r app/build/outputs/apk/debug/app-debug.apk`).
  2. Open YouCoded. Create 2 sessions. Send a prompt in each.
  3. Force-stop the app from system Settings.
  4. Re-launch. Verify the resume screen appears (without previews — Android is preview-less in v1, that's expected).
  5. Resume all. Verify both sessions reload.

- [ ] **Run `/audit` from the workspace** to confirm no doc drift introduced by the new module.

---

## Notes for the executing engineer

- **The existing `handleResumeSession` callback in App.tsx is the resume mechanic.** Don't rebuild it. The new code only orchestrates calling it once per selected session.
- **Don't add a `clear-on-app-quit` path.** The whole feature depends on the file surviving an unclean quit. The Start-fresh button is the user-explicit clear path; nothing else clears.
- **`recordedActiveSessions` is in-process only.** Each Electron process / Android `SessionService` instance has its own set. After a crash, the next process starts with an empty set — first user-message after recovery re-adds the entry to the list (idempotent in the store). That's correct behavior.
- **Don't try to merge the desktop and Android list files.** The architecture is "same shape, two files." Sync across devices is an entirely separate concern (handled by `youcoded-active-sessions.json` riding the existing `~/.claude` backup pipeline if at all).
- **The Android v1 ships without previews** by design — the screen renders correctly with empty strings (the component already handles that case in its tests). Adding Kotlin-side tail-read is a follow-up if anyone misses the previews on mobile.
