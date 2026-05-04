# Multi-Model Harness MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add chat-only "Local" sessions to YouCoded backed by Ollama (and any OpenAI-compatible endpoint). Local sessions render in the existing chat view via the same `transcript:event` shape Claude sessions use, so the chat reducer/UI works unchanged.

**Architecture:** A new `LocalSessionHarness` lives in `src/main/` next to `SessionManager`. It uses the [Vercel AI SDK](https://sdk.vercel.ai) to stream from Ollama over HTTP, persists conversation JSON to `~/.claude/youcoded-local/sessions/`, and emits `transcript-event` on the same EventEmitter pipe the watcher uses today. `SessionManager.createSession()` delegates `provider: 'local'` to the harness instead of spawning a PTY worker.

**Tech Stack:** TypeScript, Node 20+, Electron, Vercel AI SDK (`ai` + `ollama-ai-provider`), Vitest, React 18.

**Spec:** `docs/superpowers/specs/2026-05-04-multi-model-harness-design.md`

---

## File Structure

| Path | Purpose | Action |
|------|---------|--------|
| `youcoded/desktop/src/shared/types.ts` | Add `'local'` to `SessionProvider` union; add `endpoint?: string` to `SessionInfo`; add `LOCAL_*` IPC channel constants | Modify |
| `youcoded/desktop/src/main/local-session-store.ts` | Pure persistence layer for `~/.claude/youcoded-local/sessions/<id>.json` (load/save/list/atomic-write) | Create |
| `youcoded/desktop/src/main/ollama-detector.ts` | Detect Ollama binary, query installed models, install Ollama, pull model | Create |
| `youcoded/desktop/src/main/local-session-harness.ts` | Per-session chat loop using Vercel AI SDK; emits `transcript-event` | Create |
| `youcoded/desktop/src/main/session-manager.ts` | Branch on `provider === 'local'` → delegate to harness | Modify |
| `youcoded/desktop/src/main/main.ts` | Wire harness's `transcript-event` into the same IPC channel the watcher feeds | Modify |
| `youcoded/desktop/src/main/preload.ts` | Expose `window.claude.local.*` (listModels, isOllamaInstalled, installOllama, pullModel) | Modify |
| `youcoded/desktop/src/main/ipc-handlers.ts` | Wire IPC handlers for `local:*` channels | Modify |
| `youcoded/desktop/src/renderer/remote-shim.ts` | Stub `window.claude.local.*` on remote/Android (returns "not supported") so renderer code doesn't crash | Modify |
| `youcoded/desktop/src/renderer/components/SessionStrip.tsx` | Replace `isGemini` boolean with three-way Runtime selector; Local model dropdown; inline "Install Qwen 3 8B" CTA | Modify |
| `youcoded/desktop/src/renderer/components/HeaderBar.tsx` | Hide chat/terminal toggle and permission-mode badge for `provider === 'local'` | Modify |
| `youcoded/desktop/src/renderer/components/ModelPickerPopup.tsx` | Runtime-scoped model list (Local sessions show installed Ollama models) | Modify |
| `youcoded/desktop/src/renderer/components/SettingsPanel.tsx` | New "Local Models" settings section | Modify |
| `youcoded/desktop/src/renderer/App.tsx` | Pass `provider: 'local'`; gate transcript-watcher attach on `provider === 'claude'`; route Stop button to local harness for local sessions | Modify |
| `youcoded/desktop/src/main/prerequisite-installer.ts` | Add Ollama install path (Windows/macOS/Linux) | Modify |
| `youcoded/desktop/src/renderer/components/restore/ResumeBrowser.tsx` | Local sessions filter/tab | Modify |
| `youcoded/desktop/tests/local-session-store.test.ts` | Unit tests for the store | Create |
| `youcoded/desktop/tests/ollama-detector.test.ts` | Unit tests with mocked HTTP | Create |
| `youcoded/desktop/tests/local-session-harness.test.ts` | Unit tests with mocked AI SDK | Create |
| `youcoded/desktop/package.json` | Add `ai`, `ollama-ai-provider` deps | Modify |

The three new `src/main/` files are intentionally split: `local-session-store.ts` is pure file I/O (no network), `ollama-detector.ts` is pure HTTP/process probing (no state), `local-session-harness.ts` composes them and owns the streaming loop. This keeps each file small and unit-testable in isolation.

---

## Setup (one-time)

- [ ] **Setup Step 1: Sync the workspace**

```bash
cd /c/Users/desti/youcoded-dev/youcoded
git fetch origin
git pull origin master
```

Expected: clean pull, no merge conflicts.

- [ ] **Setup Step 2: Create the implementation worktree**

```bash
cd /c/Users/desti/youcoded-dev/youcoded
git worktree add ../youcoded.wt/local-harness-mvp -b feat/local-harness-mvp origin/master
```

Expected: worktree at `C:\Users\desti\youcoded-dev\youcoded.wt\local-harness-mvp` on a fresh branch off the latest `origin/master`.

- [ ] **Setup Step 3: Junction `node_modules` from the main checkout**

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/local-harness-mvp/desktop
cmd //c "mklink /J node_modules ..\\..\\..\\youcoded\\desktop\\node_modules"
ls node_modules | head -3
```

Expected: a few package directory names print. **Critical:** when you eventually remove this worktree, `cmd //c "rmdir node_modules"` FIRST — `git worktree remove` follows junctions on Windows and would wipe the main checkout's `node_modules`. (See `docs/PITFALLS.md → Working With Destin → "git worktree remove follows junctions on Windows"`.)

- [ ] **Setup Step 4: Install new npm dependencies**

```bash
cd /c/Users/desti/youcoded-dev/youcoded/desktop
npm install ai@^4 ollama-ai-provider@^1
```

Run from the main checkout, not the worktree, since `node_modules` is junctioned. Expected: deps land in `package.json` and `node_modules`.

- [ ] **Setup Step 5: Commit the dep additions on the feature branch**

The `npm install` modifies `package.json` and `package-lock.json` in the main checkout. Move them to the worktree:

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/local-harness-mvp/desktop
git checkout HEAD -- package.json package-lock.json  # discard if any auto-changed in worktree
git -C ../../../youcoded/desktop diff package.json package-lock.json | git apply -p1 --directory=desktop
git status
git add desktop/package.json desktop/package-lock.json
git commit -m "feat(local-harness): add ai sdk + ollama-ai-provider deps"
```

Expected: one commit, two files staged. (If the diff/apply dance is awkward, alternative: edit `package.json` in the worktree to add the two deps, then run `npm install` from the main checkout to regenerate the lock — both checkouts end up with the same shared `node_modules`.)

---

## Task 1: Provider Type Extension

**Files:**
- Modify: `youcoded/desktop/src/shared/types.ts`

- [ ] **Step 1: Extend `SessionProvider` and `SessionInfo`**

Open `src/shared/types.ts`. Locate the `SessionProvider` definition (around line 28–29). Replace the union and add the optional endpoint:

```ts
// Which CLI/runtime backend powers a session — defaults to 'claude' for backwards compat
export type SessionProvider = 'claude' | 'gemini' | 'local';

export interface SessionInfo {
  // ... existing fields unchanged
  provider: SessionProvider;
  /** Model alias the session was started with (e.g. 'claude-sonnet-4-6' or 'qwen3:8b') */
  model?: string;
  /** For provider === 'local': OpenAI-compat HTTP endpoint. Defaults to http://localhost:11434/v1 (Ollama). */
  endpoint?: string;
  // ... existing fields unchanged
}
```

(The `endpoint` field is `?` so existing `SessionInfo` consumers don't break.)

- [ ] **Step 2: Add IPC channel constants**

Locate the existing `IPC` constant in the same file. Add new entries inside the object:

```ts
export const IPC = {
  // ... existing channels
  LOCAL_LIST_MODELS: 'local:list-models',
  LOCAL_IS_OLLAMA_INSTALLED: 'local:is-ollama-installed',
  LOCAL_INSTALL_OLLAMA: 'local:install-ollama',
  LOCAL_INSTALL_OLLAMA_PROGRESS: 'local:install-ollama:progress',
  LOCAL_PULL_MODEL: 'local:pull-model',
  LOCAL_PULL_MODEL_PROGRESS: 'local:pull-model:progress',
};
```

- [ ] **Step 3: Verify TypeScript still compiles**

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/local-harness-mvp/desktop
npx tsc --noEmit
```

Expected: no errors. If `SessionProvider` is referenced in test files with exhaustive switch statements, the test compile may complain; if so, add a `case 'local':` branch returning a placeholder where needed. Most consumers use the union loosely and won't break.

- [ ] **Step 4: Commit**

```bash
git add desktop/src/shared/types.ts
git commit -m "types(local-harness): extend SessionProvider with 'local'; add endpoint field; reserve IPC channels"
```

---

## Task 2: LocalSessionStore (TDD)

**Files:**
- Create: `youcoded/desktop/src/main/local-session-store.ts`
- Test: `youcoded/desktop/tests/local-session-store.test.ts`

- [ ] **Step 1: Write the failing tests**

Create `youcoded/desktop/tests/local-session-store.test.ts`:

```ts
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as os from 'os';
import * as path from 'path';
import * as fs from 'fs/promises';
import {
  LocalSessionStore,
  type LocalSessionRecord,
  type LocalChatMessage,
} from '../src/main/local-session-store';

describe('LocalSessionStore', () => {
  let tmpRoot: string;
  let store: LocalSessionStore;

  beforeEach(async () => {
    tmpRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'lss-'));
    store = new LocalSessionStore(tmpRoot);
  });

  afterEach(async () => {
    await fs.rm(tmpRoot, { recursive: true, force: true });
  });

  function makeRecord(overrides: Partial<LocalSessionRecord> = {}): LocalSessionRecord {
    return {
      id: 'sess-1',
      provider: 'local',
      model: 'qwen3:8b',
      endpoint: 'http://localhost:11434/v1',
      systemPrompt: 'You are a helpful assistant.',
      createdAt: 1714857600000,
      updatedAt: 1714857600000,
      title: 'Untitled',
      messages: [],
      ...overrides,
    };
  }

  it('save() then load() round-trips a record', async () => {
    const rec = makeRecord({ title: 'A new chat' });
    await store.save(rec);
    const loaded = await store.load('sess-1');
    expect(loaded).toEqual(rec);
  });

  it('load() returns null when the file does not exist', async () => {
    expect(await store.load('does-not-exist')).toBeNull();
  });

  it('listAll() returns sessions sorted by updatedAt desc', async () => {
    await store.save(makeRecord({ id: 'a', updatedAt: 1000 }));
    await store.save(makeRecord({ id: 'b', updatedAt: 3000 }));
    await store.save(makeRecord({ id: 'c', updatedAt: 2000 }));
    const list = await store.listAll();
    expect(list.map(r => r.id)).toEqual(['b', 'c', 'a']);
  });

  it('listAll() returns [] when the directory does not exist yet', async () => {
    const freshRoot = path.join(tmpRoot, 'nope');
    const freshStore = new LocalSessionStore(freshRoot);
    expect(await freshStore.listAll()).toEqual([]);
  });

  it('delete() removes the file', async () => {
    await store.save(makeRecord());
    await store.delete('sess-1');
    expect(await store.load('sess-1')).toBeNull();
  });

  it('save() writes atomically (no .tmp file left behind on success)', async () => {
    await store.save(makeRecord());
    const files = await fs.readdir(path.join(tmpRoot, 'sessions'));
    expect(files.filter(f => f.endsWith('.tmp'))).toEqual([]);
    expect(files).toContain('sess-1.json');
  });

  it('save() bumps updatedAt to now if not provided by caller', async () => {
    const before = Date.now();
    const rec = makeRecord();
    rec.updatedAt = 0; // sentinel: caller did not set
    const saved = await store.save(rec);
    expect(saved.updatedAt).toBeGreaterThanOrEqual(before);
  });

  it('appendMessage() appends to messages and bumps updatedAt', async () => {
    await store.save(makeRecord());
    const msg: LocalChatMessage = {
      role: 'user',
      content: 'hello',
      timestamp: 1714857700000,
    };
    const updated = await store.appendMessage('sess-1', msg);
    expect(updated.messages).toEqual([msg]);
    expect(updated.updatedAt).toBeGreaterThanOrEqual(1714857700000);
  });

  it('appendMessage() throws when the session does not exist', async () => {
    await expect(
      store.appendMessage('nope', { role: 'user', content: 'x', timestamp: 0 })
    ).rejects.toThrow();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/local-harness-mvp/desktop
npx vitest run tests/local-session-store.test.ts 2>&1 | tail -15
```

Expected: every test fails with `Cannot find module '../src/main/local-session-store'`.

- [ ] **Step 3: Implement `LocalSessionStore`**

Create `youcoded/desktop/src/main/local-session-store.ts`:

```ts
import * as fs from 'fs/promises';
import * as path from 'path';
import type { SessionProvider } from '../shared/types';

export interface LocalChatMessage {
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: number;
}

export interface LocalSessionRecord {
  id: string;
  provider: SessionProvider;            // always 'local' in MVP
  model: string;
  endpoint: string;
  systemPrompt: string;
  createdAt: number;
  updatedAt: number;
  title: string;
  messages: LocalChatMessage[];
}

/**
 * Persists local-session conversation JSON files under <root>/sessions/<id>.json.
 * Pure file I/O; no network, no event emitter. Atomic write via .tmp + rename
 * so a crash mid-write doesn't corrupt the file.
 */
export class LocalSessionStore {
  private readonly sessionsDir: string;

  constructor(private readonly root: string) {
    this.sessionsDir = path.join(root, 'sessions');
  }

  private filePath(id: string): string {
    return path.join(this.sessionsDir, `${id}.json`);
  }

  async save(record: LocalSessionRecord): Promise<LocalSessionRecord> {
    await fs.mkdir(this.sessionsDir, { recursive: true });
    const stamped: LocalSessionRecord = {
      ...record,
      updatedAt: record.updatedAt && record.updatedAt > 0 ? record.updatedAt : Date.now(),
    };
    const finalPath = this.filePath(stamped.id);
    const tmpPath = `${finalPath}.tmp`;
    await fs.writeFile(tmpPath, JSON.stringify(stamped, null, 2), 'utf8');
    await fs.rename(tmpPath, finalPath);
    return stamped;
  }

  async load(id: string): Promise<LocalSessionRecord | null> {
    try {
      const text = await fs.readFile(this.filePath(id), 'utf8');
      return JSON.parse(text) as LocalSessionRecord;
    } catch (e: any) {
      if (e?.code === 'ENOENT') return null;
      throw e;
    }
  }

  async delete(id: string): Promise<void> {
    try {
      await fs.unlink(this.filePath(id));
    } catch (e: any) {
      if (e?.code !== 'ENOENT') throw e;
    }
  }

  async listAll(): Promise<LocalSessionRecord[]> {
    let entries: string[];
    try {
      entries = await fs.readdir(this.sessionsDir);
    } catch (e: any) {
      if (e?.code === 'ENOENT') return [];
      throw e;
    }
    const records: LocalSessionRecord[] = [];
    for (const f of entries) {
      if (!f.endsWith('.json') || f.endsWith('.tmp')) continue;
      try {
        const text = await fs.readFile(path.join(this.sessionsDir, f), 'utf8');
        records.push(JSON.parse(text) as LocalSessionRecord);
      } catch {
        // Skip unreadable / malformed files rather than fail the whole list.
        continue;
      }
    }
    records.sort((a, b) => b.updatedAt - a.updatedAt);
    return records;
  }

  async appendMessage(id: string, msg: LocalChatMessage): Promise<LocalSessionRecord> {
    const rec = await this.load(id);
    if (!rec) throw new Error(`local session ${id} not found`);
    rec.messages.push(msg);
    rec.updatedAt = Date.now();
    return this.save(rec);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npx vitest run tests/local-session-store.test.ts 2>&1 | tail -10
```

Expected: all 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/local-session-store.ts desktop/tests/local-session-store.test.ts
git commit -m "feat(local-harness): LocalSessionStore — atomic file persistence for local conversations"
```

---

## Task 3: OllamaDetector (TDD)

**Files:**
- Create: `youcoded/desktop/src/main/ollama-detector.ts`
- Test: `youcoded/desktop/tests/ollama-detector.test.ts`

The detector talks to Ollama's HTTP API at `http://localhost:11434`. It does **not** install Ollama itself — that's `prerequisite-installer.ts`'s job in Task 11. The detector only probes (is it up? what models are installed?) and triggers model pulls via the API.

- [ ] **Step 1: Write the failing tests**

Create `youcoded/desktop/tests/ollama-detector.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { OllamaDetector } from '../src/main/ollama-detector';

describe('OllamaDetector', () => {
  let fetchMock: ReturnType<typeof vi.fn>;
  let detector: OllamaDetector;

  beforeEach(() => {
    fetchMock = vi.fn();
    // Inject our mock — detector accepts an injected fetch for testability
    detector = new OllamaDetector('http://localhost:11434', fetchMock as any);
  });

  it('isReachable() returns true when /api/version 200s', async () => {
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({ version: '0.5.0' }),
    });
    expect(await detector.isReachable()).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      'http://localhost:11434/api/version',
      expect.objectContaining({ method: 'GET' }),
    );
  });

  it('isReachable() returns false on network error', async () => {
    fetchMock.mockRejectedValueOnce(new Error('ECONNREFUSED'));
    expect(await detector.isReachable()).toBe(false);
  });

  it('isReachable() returns false on non-2xx', async () => {
    fetchMock.mockResolvedValueOnce({ ok: false, status: 500, json: async () => ({}) });
    expect(await detector.isReachable()).toBe(false);
  });

  it('listModels() returns model names from /api/tags', async () => {
    fetchMock.mockResolvedValueOnce({
      ok: true,
      status: 200,
      json: async () => ({
        models: [
          { name: 'qwen3:8b', size: 4_900_000_000, modified_at: '2026-05-01T00:00:00Z' },
          { name: 'llama3.2:3b', size: 2_000_000_000, modified_at: '2026-04-15T00:00:00Z' },
        ],
      }),
    });
    const models = await detector.listModels();
    expect(models).toEqual([
      { name: 'qwen3:8b', sizeBytes: 4_900_000_000, modifiedAt: '2026-05-01T00:00:00Z' },
      { name: 'llama3.2:3b', sizeBytes: 2_000_000_000, modifiedAt: '2026-04-15T00:00:00Z' },
    ]);
  });

  it('listModels() returns [] when Ollama is unreachable', async () => {
    fetchMock.mockRejectedValueOnce(new Error('ECONNREFUSED'));
    expect(await detector.listModels()).toEqual([]);
  });

  it('pullModel() streams progress events as the response body emits NDJSON', async () => {
    // Build a fake ReadableStream emitting NDJSON chunks
    const chunks = [
      '{"status":"pulling manifest"}\n',
      '{"status":"downloading","completed":1024,"total":4096}\n',
      '{"status":"downloading","completed":4096,"total":4096}\n',
      '{"status":"success"}\n',
    ];
    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      start(controller) {
        for (const c of chunks) controller.enqueue(encoder.encode(c));
        controller.close();
      },
    });
    fetchMock.mockResolvedValueOnce({ ok: true, status: 200, body: stream });

    const events: any[] = [];
    await detector.pullModel('qwen3:8b', (ev) => events.push(ev));

    expect(events).toEqual([
      { kind: 'status', status: 'pulling manifest' },
      { kind: 'progress', status: 'downloading', completedBytes: 1024, totalBytes: 4096 },
      { kind: 'progress', status: 'downloading', completedBytes: 4096, totalBytes: 4096 },
      { kind: 'done' },
    ]);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
npx vitest run tests/ollama-detector.test.ts 2>&1 | tail -15
```

Expected: every test fails with `Cannot find module '../src/main/ollama-detector'`.

- [ ] **Step 3: Implement `OllamaDetector`**

Create `youcoded/desktop/src/main/ollama-detector.ts`:

```ts
export interface OllamaModelInfo {
  name: string;
  sizeBytes: number;
  modifiedAt: string;
}

export type PullEvent =
  | { kind: 'status'; status: string }
  | { kind: 'progress'; status: string; completedBytes: number; totalBytes: number }
  | { kind: 'done' }
  | { kind: 'error'; message: string };

/**
 * Probes a running Ollama server (default localhost:11434) and triggers model pulls.
 * Does NOT install Ollama itself — see prerequisite-installer.ts for that.
 *
 * fetch is injected so tests can mock it without touching globals.
 */
export class OllamaDetector {
  constructor(
    private readonly baseUrl: string = 'http://localhost:11434',
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async isReachable(): Promise<boolean> {
    try {
      const res = await this.fetchImpl(`${this.baseUrl}/api/version`, { method: 'GET' });
      return res.ok;
    } catch {
      return false;
    }
  }

  async listModels(): Promise<OllamaModelInfo[]> {
    try {
      const res = await this.fetchImpl(`${this.baseUrl}/api/tags`, { method: 'GET' });
      if (!res.ok) return [];
      const json = await res.json() as { models?: Array<{ name: string; size: number; modified_at: string }> };
      return (json.models ?? []).map(m => ({
        name: m.name,
        sizeBytes: m.size,
        modifiedAt: m.modified_at,
      }));
    } catch {
      return [];
    }
  }

  async pullModel(name: string, onEvent: (ev: PullEvent) => void): Promise<void> {
    let res: Response;
    try {
      res = await this.fetchImpl(`${this.baseUrl}/api/pull`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name, stream: true }),
      });
    } catch (e: any) {
      onEvent({ kind: 'error', message: String(e?.message ?? e) });
      return;
    }
    if (!res.ok || !res.body) {
      onEvent({ kind: 'error', message: `pull failed: HTTP ${res.status}` });
      return;
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let nl: number;
      while ((nl = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        try {
          const parsed = JSON.parse(line) as {
            status?: string;
            completed?: number;
            total?: number;
            error?: string;
          };
          if (parsed.error) {
            onEvent({ kind: 'error', message: parsed.error });
            return;
          }
          if (parsed.status === 'success') {
            onEvent({ kind: 'done' });
            return;
          }
          if (typeof parsed.completed === 'number' && typeof parsed.total === 'number') {
            onEvent({
              kind: 'progress',
              status: parsed.status ?? 'downloading',
              completedBytes: parsed.completed,
              totalBytes: parsed.total,
            });
          } else if (parsed.status) {
            onEvent({ kind: 'status', status: parsed.status });
          }
        } catch {
          // Skip unparseable lines; Ollama occasionally emits extra whitespace.
        }
      }
    }
    onEvent({ kind: 'done' });
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npx vitest run tests/ollama-detector.test.ts 2>&1 | tail -10
```

Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/ollama-detector.ts desktop/tests/ollama-detector.test.ts
git commit -m "feat(local-harness): OllamaDetector — probe Ollama HTTP API + model pulls"
```

---

## Task 4: LocalSessionHarness (TDD)

**Files:**
- Create: `youcoded/desktop/src/main/local-session-harness.ts`
- Test: `youcoded/desktop/tests/local-session-harness.test.ts`

The harness is the heart of the feature. It owns one or more in-flight local sessions, calls the Vercel AI SDK to stream responses, persists conversation state, and emits `transcript-event` so existing pipelines pick it up.

- [ ] **Step 1: Write the failing tests**

Create `youcoded/desktop/tests/local-session-harness.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as os from 'os';
import * as path from 'path';
import * as fs from 'fs/promises';
import { LocalSessionHarness } from '../src/main/local-session-harness';
import { LocalSessionStore } from '../src/main/local-session-store';

// Mock the AI SDK — the real one would call a network endpoint.
const mockStreamText = vi.fn();
vi.mock('ai', () => ({
  streamText: (...args: any[]) => mockStreamText(...args),
}));
vi.mock('ollama-ai-provider', () => ({
  createOllama: () => (modelName: string) => ({ __mockModel: modelName }),
}));

function streamFromChunks(chunks: string[]) {
  // Mimic the SDK's textStream async iterable
  return {
    textStream: (async function* () {
      for (const c of chunks) yield c;
    })(),
    finishReason: Promise.resolve('stop'),
    usage: Promise.resolve({ promptTokens: 10, completionTokens: 20, totalTokens: 30 }),
  };
}

describe('LocalSessionHarness', () => {
  let tmpRoot: string;
  let store: LocalSessionStore;
  let harness: LocalSessionHarness;
  let events: Array<{ type: string; sessionId: string; data: any }>;

  beforeEach(async () => {
    tmpRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'lsh-'));
    store = new LocalSessionStore(tmpRoot);
    harness = new LocalSessionHarness(store);
    events = [];
    harness.on('transcript-event', (ev) => events.push(ev));
    mockStreamText.mockReset();
  });

  afterEach(async () => {
    harness.destroyAll();
    await fs.rm(tmpRoot, { recursive: true, force: true });
  });

  it('startSession() returns SessionInfo with provider="local" and persists an empty record', async () => {
    const info = await harness.startSession({
      id: 'sess-x',
      name: 'Chat',
      cwd: '/tmp',
      model: 'qwen3:8b',
      endpoint: 'http://localhost:11434/v1',
      systemPrompt: 'You are helpful.',
    });
    expect(info.provider).toBe('local');
    expect(info.id).toBe('sess-x');
    expect(info.model).toBe('qwen3:8b');
    expect(info.endpoint).toBe('http://localhost:11434/v1');
    const loaded = await store.load('sess-x');
    expect(loaded?.messages).toEqual([]);
  });

  it('send() emits user-message → assistant-text(s) → turn-complete in order', async () => {
    await harness.startSession({
      id: 'sess-x', name: 'Chat', cwd: '/tmp',
      model: 'qwen3:8b', endpoint: 'http://localhost:11434/v1', systemPrompt: 'sys',
    });
    mockStreamText.mockReturnValueOnce(streamFromChunks(['Hello', ', world', '!']));
    await harness.send('sess-x', 'hi');

    const types = events.map(e => e.type);
    expect(types).toEqual([
      'user-message',
      'assistant-text', 'assistant-text', 'assistant-text',
      'turn-complete',
    ]);
    expect(events[0].data.text).toBe('hi');
    expect(events.slice(1, 4).map(e => e.data.text)).toEqual(['Hello', ', world', '!']);
  });

  it('send() persists the user message and the concatenated assistant reply', async () => {
    await harness.startSession({
      id: 'sess-x', name: 'Chat', cwd: '/tmp',
      model: 'qwen3:8b', endpoint: 'http://localhost:11434/v1', systemPrompt: 'sys',
    });
    mockStreamText.mockReturnValueOnce(streamFromChunks(['part one ', 'part two']));
    await harness.send('sess-x', 'hello');

    const loaded = await store.load('sess-x');
    expect(loaded?.messages.map(m => ({ role: m.role, content: m.content }))).toEqual([
      { role: 'user',      content: 'hello' },
      { role: 'assistant', content: 'part one part two' },
    ]);
  });

  it('send() auto-titles the session from the first user message', async () => {
    await harness.startSession({
      id: 'sess-x', name: 'Chat', cwd: '/tmp',
      model: 'qwen3:8b', endpoint: 'http://localhost:11434/v1', systemPrompt: 'sys',
    });
    mockStreamText.mockReturnValueOnce(streamFromChunks(['ok']));
    await harness.send('sess-x', 'how do I install python on windows please');
    const loaded = await store.load('sess-x');
    expect(loaded?.title).toBe('how do I install python on');
  });

  it('cancel() aborts the in-flight stream and emits turn-complete with stopReason="interrupted"', async () => {
    await harness.startSession({
      id: 'sess-x', name: 'Chat', cwd: '/tmp',
      model: 'qwen3:8b', endpoint: 'http://localhost:11434/v1', systemPrompt: 'sys',
    });
    // A stream that yields one chunk then awaits forever (until aborted)
    mockStreamText.mockReturnValueOnce({
      textStream: (async function* () {
        yield 'partial';
        await new Promise<never>(() => { /* hang */ });
      })(),
      finishReason: Promise.resolve('stop'),
      usage: Promise.resolve({ promptTokens: 0, completionTokens: 0, totalTokens: 0 }),
    });

    const sendP = harness.send('sess-x', 'go');
    // Wait a tick so the first chunk emits
    await new Promise(r => setTimeout(r, 10));
    await harness.cancel('sess-x');
    await sendP;

    const stopEvent = events.find(e => e.type === 'turn-complete');
    expect(stopEvent?.data.stopReason).toBe('interrupted');
    const loaded = await store.load('sess-x');
    // Partial reply should be persisted
    expect(loaded?.messages.at(-1)?.content).toBe('partial');
  });

  it('resumeSession() re-loads message history and emits the existing transcript', async () => {
    // Pre-seed a session record on disk
    await store.save({
      id: 'sess-x', provider: 'local', model: 'qwen3:8b',
      endpoint: 'http://localhost:11434/v1', systemPrompt: 'sys',
      createdAt: 1, updatedAt: 2, title: 'Old chat',
      messages: [
        { role: 'user', content: 'prior q', timestamp: 1 },
        { role: 'assistant', content: 'prior a', timestamp: 2 },
      ],
    });
    const info = await harness.resumeSession('sess-x');
    expect(info.id).toBe('sess-x');
    // Resuming does NOT re-emit (the chat reducer hydrates from persisted state separately).
    // It just makes the session live again so subsequent send() works.
    expect(events).toEqual([]);

    // Subsequent send should include the prior history in the SDK call
    mockStreamText.mockReturnValueOnce(streamFromChunks(['ok']));
    await harness.send('sess-x', 'new q');
    const callArgs = mockStreamText.mock.calls[0][0];
    expect(callArgs.messages).toEqual([
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'prior q' },
      { role: 'assistant', content: 'prior a' },
      { role: 'user', content: 'new q' },
    ]);
  });

  it('destroySession() removes the in-memory session and stops emitting', async () => {
    await harness.startSession({
      id: 'sess-x', name: 'Chat', cwd: '/tmp',
      model: 'qwen3:8b', endpoint: 'http://localhost:11434/v1', systemPrompt: 'sys',
    });
    harness.destroySession('sess-x');
    await expect(harness.send('sess-x', 'hi')).rejects.toThrow();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
npx vitest run tests/local-session-harness.test.ts 2>&1 | tail -15
```

Expected: every test fails with `Cannot find module '../src/main/local-session-harness'`.

- [ ] **Step 3: Implement `LocalSessionHarness`**

Create `youcoded/desktop/src/main/local-session-harness.ts`:

```ts
import { EventEmitter } from 'events';
import { streamText } from 'ai';
import { createOllama } from 'ollama-ai-provider';
import type { SessionInfo } from '../shared/types';
import { LocalSessionStore, type LocalChatMessage } from './local-session-store';

export interface StartLocalSessionOpts {
  id: string;
  name: string;
  cwd: string;
  model: string;
  endpoint: string;          // e.g. http://localhost:11434/v1
  systemPrompt: string;
}

interface LiveSession {
  info: SessionInfo;
  systemPrompt: string;
  abortController: AbortController | null;   // non-null while a stream is in flight
}

const DEFAULT_TITLE = 'Untitled';

/**
 * Owns local-mode chat sessions. Streams completions via Vercel AI SDK and
 * emits 'transcript-event' messages shaped like the TranscriptWatcher's,
 * so the chat reducer & UI work without modification.
 *
 * Event shape (see TranscriptWatcher for the cross-reference):
 *   { type: 'user-message',    sessionId, data: { text, timestamp, uuid } }
 *   { type: 'assistant-text',  sessionId, data: { text, timestamp, uuid } }
 *   { type: 'turn-complete',   sessionId, data: { stopReason, model, usage } }
 */
export class LocalSessionHarness extends EventEmitter {
  private readonly sessions = new Map<string, LiveSession>();

  constructor(private readonly store: LocalSessionStore) {
    super();
  }

  async startSession(opts: StartLocalSessionOpts): Promise<SessionInfo> {
    const info: SessionInfo = {
      id: opts.id,
      name: opts.name,
      cwd: opts.cwd,
      provider: 'local',
      model: opts.model,
      endpoint: opts.endpoint,
      permissionMode: 'normal',
      skipPermissions: false,
      status: 'active',
      createdAt: Date.now(),
    };
    // Persist an empty record so resume works even if the user never sends
    // a message in this session.
    await this.store.save({
      id: opts.id,
      provider: 'local',
      model: opts.model,
      endpoint: opts.endpoint,
      systemPrompt: opts.systemPrompt,
      createdAt: info.createdAt,
      updatedAt: info.createdAt,
      title: DEFAULT_TITLE,
      messages: [],
    });
    this.sessions.set(opts.id, {
      info,
      systemPrompt: opts.systemPrompt,
      abortController: null,
    });
    return info;
  }

  /** Re-mount a previously persisted session as live. Does NOT re-emit prior events. */
  async resumeSession(id: string): Promise<SessionInfo> {
    const rec = await this.store.load(id);
    if (!rec) throw new Error(`local session ${id} not found on disk`);
    const info: SessionInfo = {
      id: rec.id,
      name: rec.title || DEFAULT_TITLE,
      cwd: '',                          // not currently persisted; caller can set
      provider: 'local',
      model: rec.model,
      endpoint: rec.endpoint,
      permissionMode: 'normal',
      skipPermissions: false,
      status: 'active',
      createdAt: rec.createdAt,
    };
    this.sessions.set(id, { info, systemPrompt: rec.systemPrompt, abortController: null });
    return info;
  }

  async send(sessionId: string, userText: string): Promise<void> {
    const live = this.sessions.get(sessionId);
    if (!live) throw new Error(`local session ${sessionId} is not live`);
    const userTimestamp = Date.now();
    const userUuid = `local-u-${userTimestamp}-${Math.random().toString(36).slice(2, 8)}`;

    // Persist + emit the user message first (matches the order TranscriptWatcher uses)
    await this.store.appendMessage(sessionId, {
      role: 'user',
      content: userText,
      timestamp: userTimestamp,
    });
    this.emit('transcript-event', {
      type: 'user-message',
      sessionId,
      data: { text: userText, timestamp: userTimestamp, uuid: userUuid },
    });

    // Auto-title from first user message
    const recAfterUser = await this.store.load(sessionId);
    if (recAfterUser && recAfterUser.title === DEFAULT_TITLE) {
      const words = userText.trim().split(/\s+/).slice(0, 6);
      const title = words.join(' ').slice(0, 60);
      if (title) {
        recAfterUser.title = title;
        await this.store.save(recAfterUser);
      }
    }

    // Build messages array for the SDK
    const rec = await this.store.load(sessionId);
    if (!rec) throw new Error(`local session ${sessionId} disappeared`);
    const sdkMessages = [
      { role: 'system' as const, content: live.systemPrompt },
      ...rec.messages.map(m => ({ role: m.role, content: m.content })),
    ];

    // Spin up the abort controller for this turn
    const abortController = new AbortController();
    live.abortController = abortController;

    // Build the model client. createOllama() returns a factory; calling it
    // with the model name returns the actual model handle the SDK uses.
    const ollama = createOllama({ baseURL: live.info.endpoint });
    const modelHandle = ollama(live.info.model);

    let assistantText = '';
    let stopReason: 'stop' | 'interrupted' | 'error' = 'stop';
    let usage: { promptTokens: number; completionTokens: number; totalTokens: number } | null = null;

    try {
      const result = streamText({
        model: modelHandle,
        messages: sdkMessages,
        abortSignal: abortController.signal,
      } as any);

      for await (const chunk of result.textStream) {
        if (abortController.signal.aborted) {
          stopReason = 'interrupted';
          break;
        }
        assistantText += chunk;
        const chunkTs = Date.now();
        this.emit('transcript-event', {
          type: 'assistant-text',
          sessionId,
          data: {
            text: chunk,
            timestamp: chunkTs,
            uuid: `local-a-${chunkTs}-${Math.random().toString(36).slice(2, 8)}`,
          },
        });
      }

      // Pull final metadata if the stream reached its natural end
      if (stopReason !== 'interrupted') {
        try { usage = await result.usage; } catch { /* model didn't report usage */ }
      }
    } catch (e: any) {
      if (abortController.signal.aborted) {
        stopReason = 'interrupted';
      } else {
        stopReason = 'error';
        // eslint-disable-next-line no-console
        console.error('[LocalSessionHarness] streamText error:', e);
      }
    } finally {
      live.abortController = null;
    }

    // Persist whatever assistant text we accumulated, even on interrupt/error
    if (assistantText) {
      await this.store.appendMessage(sessionId, {
        role: 'assistant',
        content: assistantText,
        timestamp: Date.now(),
      });
    }

    this.emit('transcript-event', {
      type: 'turn-complete',
      sessionId,
      data: { stopReason, model: live.info.model, usage },
    });
  }

  async cancel(sessionId: string): Promise<void> {
    const live = this.sessions.get(sessionId);
    if (live?.abortController) live.abortController.abort();
  }

  destroySession(sessionId: string): boolean {
    const live = this.sessions.get(sessionId);
    if (!live) return false;
    if (live.abortController) live.abortController.abort();
    this.sessions.delete(sessionId);
    return true;
  }

  destroyAll(): void {
    for (const id of this.sessions.keys()) this.destroySession(id);
  }

  isLive(sessionId: string): boolean {
    return this.sessions.has(sessionId);
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npx vitest run tests/local-session-harness.test.ts 2>&1 | tail -15
```

Expected: all 7 tests pass. If the cancel-test hangs longer than ~3 seconds, the abort signal isn't being respected — re-check that `result.textStream`'s `for await` exits when `abortController.signal.aborted` is true. On flaky systems, slightly increase the `setTimeout(r, 10)` delay so the first chunk has time to emit before cancel fires.

- [ ] **Step 5: Commit**

```bash
git add desktop/src/main/local-session-harness.ts desktop/tests/local-session-harness.test.ts
git commit -m "feat(local-harness): LocalSessionHarness — streaming chat via Vercel AI SDK + persistence + cancel"
```

---

## Task 5: SessionManager Delegation

**Files:**
- Modify: `youcoded/desktop/src/main/session-manager.ts`

The existing `SessionManager.createSession()` always spawns a PTY worker. We need it to delegate to `LocalSessionHarness` when `provider === 'local'`, while keeping the Claude/Gemini paths untouched.

- [ ] **Step 1: Wire the harness into `SessionManager`**

Open `src/main/session-manager.ts`. Add the import and a constructor parameter for the harness:

```ts
import { LocalSessionHarness } from './local-session-harness';
```

Replace the class definition to accept a harness in the constructor. Find the `export class SessionManager extends EventEmitter {` line and add:

```ts
export class SessionManager extends EventEmitter {
  private sessions = new Map<string, ManagedSession>();
  private pipeName: string = '';
  private localHarness: LocalSessionHarness | null = null;

  setLocalHarness(harness: LocalSessionHarness) {
    this.localHarness = harness;
    // Re-emit harness session lifecycle so consumers don't have to subscribe twice
    harness.on('transcript-event', (event) => this.emit('transcript-event', event));
  }

  setPipeName(name: string) {
    this.pipeName = name;
  }
  // ... rest unchanged
```

(`setLocalHarness` is wired separately rather than passed in the constructor so that the existing call sites that construct `SessionManager` don't have to change in lockstep — main.ts wires it up after both objects exist.)

- [ ] **Step 2: Branch `createSession` on `provider === 'local'`**

Locate the `createSession(opts: CreateSessionOpts): SessionInfo {` method (line ~44). Add an early branch at the top of the method, immediately after the `const id = randomUUID();` line:

```ts
createSession(opts: CreateSessionOpts): SessionInfo {
  const id = randomUUID();
  const provider: SessionProvider = opts.provider || 'claude';
  const resolvedCwd = (opts.cwd && fs.existsSync(opts.cwd)) ? opts.cwd : os.homedir();

  // --- LOCAL provider branch ---
  if (provider === 'local') {
    if (!this.localHarness) throw new Error('Local harness not wired');
    const endpoint = opts.endpoint || 'http://localhost:11434/v1';
    const systemPrompt = opts.systemPrompt || 'You are a helpful assistant. The user is using YouCoded, a desktop coding-assistant app.';
    const model = opts.model || 'qwen3:8b';
    // Fire-and-forget the async startSession; the SessionInfo we return
    // mirrors what the harness will use. We immediately register a dummy
    // ManagedSession so destroy/list operations still work uniformly.
    const info: SessionInfo = {
      id, name: opts.name, cwd: resolvedCwd,
      permissionMode: 'normal', skipPermissions: false,
      status: 'active', createdAt: Date.now(),
      provider: 'local', model, endpoint,
      ...(opts.initialInput !== undefined ? { initialInput: opts.initialInput } : {}),
    };
    this.sessions.set(id, { info, worker: null as any });   // worker unused for local
    this.emit('session-created', info);
    this.localHarness.startSession({
      id, name: opts.name, cwd: resolvedCwd, model, endpoint, systemPrompt,
    }).catch((err) => {
      log('ERROR', 'SessionManager', 'Local harness startSession failed', { sessionId: id, error: String(err) });
      this.emit('session-exit', id, 1);
      this.sessions.delete(id);
    });
    return info;
  }
  // --- end LOCAL branch ---

  // Existing PTY path continues unchanged below this point.
  const args: string[] = [];
  // ... existing code
```

- [ ] **Step 3: Update `CreateSessionOpts` to accept the new fields**

In the same file, find the `interface CreateSessionOpts` (line ~15). Add:

```ts
export interface CreateSessionOpts {
  name: string;
  cwd: string;
  skipPermissions: boolean;
  cols?: number;
  rows?: number;
  resumeSessionId?: string;
  model?: string;
  provider?: SessionProvider;
  initialInput?: string;
  /** Local-only: OpenAI-compat endpoint URL */
  endpoint?: string;
  /** Local-only: system prompt override */
  systemPrompt?: string;
}
```

- [ ] **Step 4: Update `sendInput` and `destroySession` to handle local sessions**

`sendInput` should route local-session inputs to the harness. Find the method (line ~186) and replace:

```ts
sendInput(id: string, text: string): boolean {
  const session = this.sessions.get(id);
  if (!session) return false;
  if (session.info.provider === 'local') {
    if (!this.localHarness) return false;
    // Strip trailing CR — chat input arrives with \r appended for the PTY path.
    const userText = text.endsWith('\r') ? text.slice(0, -1) : text;
    // Single-byte ESC = cancel for local sessions
    if (userText === '\x1b') {
      this.localHarness.cancel(id).catch(() => { /* swallow */ });
      return true;
    }
    if (!userText) return true;
    this.localHarness.send(id, userText).catch((err) => {
      log('ERROR', 'SessionManager', 'Local harness send failed', { sessionId: id, error: String(err) });
    });
    return true;
  }
  try { session.worker.send({ type: 'input', data: text }); } catch { return false; }
  return true;
}
```

Find `destroySession` (line ~171) and add a local branch:

```ts
destroySession(id: string): boolean {
  const session = this.sessions.get(id);
  if (!session) return false;
  session.info.status = 'destroyed';
  this.sessions.delete(id);
  this.emit('session-exit', id, 0);
  if (session.info.provider === 'local') {
    this.localHarness?.destroySession(id);
    return true;
  }
  try {
    session.worker.send({ type: 'kill' });
    session.worker.disconnect();
  } catch {
    // Worker IPC already closed
  }
  return true;
}
```

- [ ] **Step 5: Wire the harness in `main.ts`**

Open `src/main/main.ts`. Find where `SessionManager` is instantiated. After construction, wire the harness:

```ts
import { LocalSessionHarness } from './local-session-harness';
import { LocalSessionStore } from './local-session-store';
import * as os from 'os';
import * as path from 'path';

const localStore = new LocalSessionStore(path.join(os.homedir(), '.claude', 'youcoded-local'));
const localHarness = new LocalSessionHarness(localStore);
sessionManager.setLocalHarness(localHarness);
```

Also locate the existing wiring of `transcriptWatcher.on('transcript-event', ...)` to the renderer IPC. The harness's `transcript-event` is now also re-emitted by `SessionManager` via `setLocalHarness`, so any code already subscribed to `sessionManager.on('transcript-event', ...)` works for free. If the existing wire goes through `transcriptWatcher` directly (search for `transcriptWatcher.on('transcript-event'`), add the parallel `sessionManager.on('transcript-event', ...)` subscription with the same handler.

- [ ] **Step 6: Type-check and commit**

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/local-harness-mvp/desktop
npx tsc --noEmit 2>&1 | tail -10
```

Expected: no errors. (If the `ManagedSession.worker` field tightens types and refuses `null as any`, change its type to `worker: ChildProcess | null`.)

```bash
git add desktop/src/main/session-manager.ts desktop/src/main/main.ts
git commit -m "feat(local-harness): SessionManager delegates 'local' provider to LocalSessionHarness"
```

---

## Task 6: IPC Wiring (preload + ipc-handlers + remote-shim)

**Files:**
- Modify: `youcoded/desktop/src/main/preload.ts`
- Modify: `youcoded/desktop/src/main/ipc-handlers.ts`
- Modify: `youcoded/desktop/src/renderer/remote-shim.ts`

Expose `window.claude.local.*` so the renderer's new-session form can list models, trigger Ollama install, and pull a model.

- [ ] **Step 1: Add the channels and exposed methods to `preload.ts`**

Locate the `IPC` object in `preload.ts` (it's a duplicate of the one in shared/types.ts because preload can't import). Add:

```ts
const IPC = {
  // ... existing
  LOCAL_LIST_MODELS: 'local:list-models',
  LOCAL_IS_OLLAMA_INSTALLED: 'local:is-ollama-installed',
  LOCAL_INSTALL_OLLAMA: 'local:install-ollama',
  LOCAL_INSTALL_OLLAMA_PROGRESS: 'local:install-ollama:progress',
  LOCAL_PULL_MODEL: 'local:pull-model',
  LOCAL_PULL_MODEL_PROGRESS: 'local:pull-model:progress',
};
```

Then in the `contextBridge.exposeInMainWorld('claude', { ... })` block, add the `local` namespace:

```ts
local: {
  listModels: () => ipcRenderer.invoke(IPC.LOCAL_LIST_MODELS),
  isOllamaInstalled: () => ipcRenderer.invoke(IPC.LOCAL_IS_OLLAMA_INSTALLED),
  installOllama: () => ipcRenderer.invoke(IPC.LOCAL_INSTALL_OLLAMA),
  onInstallOllamaProgress: (cb: (ev: { phase: string; pct?: number; message?: string }) => void) => {
    const handler = (_e: any, ev: any) => cb(ev);
    ipcRenderer.on(IPC.LOCAL_INSTALL_OLLAMA_PROGRESS, handler);
    return () => ipcRenderer.removeListener(IPC.LOCAL_INSTALL_OLLAMA_PROGRESS, handler);
  },
  pullModel: (name: string) => ipcRenderer.invoke(IPC.LOCAL_PULL_MODEL, name),
  onPullModelProgress: (cb: (ev: { name: string; phase: string; pct?: number; message?: string }) => void) => {
    const handler = (_e: any, ev: any) => cb(ev);
    ipcRenderer.on(IPC.LOCAL_PULL_MODEL_PROGRESS, handler);
    return () => ipcRenderer.removeListener(IPC.LOCAL_PULL_MODEL_PROGRESS, handler);
  },
},
```

- [ ] **Step 2: Implement the IPC handlers in `ipc-handlers.ts`**

Open `src/main/ipc-handlers.ts`. Import the detector and constants:

```ts
import { OllamaDetector } from './ollama-detector';
import { IPC } from '../shared/types';

const ollama = new OllamaDetector();
```

Add the four handlers at the bottom of the file:

```ts
ipcMain.handle(IPC.LOCAL_IS_OLLAMA_INSTALLED, async () => {
  return await ollama.isReachable();
});

ipcMain.handle(IPC.LOCAL_LIST_MODELS, async () => {
  return await ollama.listModels();
});

ipcMain.handle(IPC.LOCAL_INSTALL_OLLAMA, async (event) => {
  // Defer to prerequisite-installer (wired in Task 11). Stub for now:
  event.sender.send(IPC.LOCAL_INSTALL_OLLAMA_PROGRESS, {
    phase: 'error',
    message: 'Ollama installer not yet wired (Task 11)',
  });
  return { ok: false, error: 'install path not yet wired' };
});

ipcMain.handle(IPC.LOCAL_PULL_MODEL, async (event, name: string) => {
  if (typeof name !== 'string' || !name) return { ok: false, error: 'name required' };
  await ollama.pullModel(name, (ev) => {
    if (ev.kind === 'progress') {
      event.sender.send(IPC.LOCAL_PULL_MODEL_PROGRESS, {
        name, phase: ev.status,
        pct: ev.totalBytes > 0 ? Math.round((ev.completedBytes / ev.totalBytes) * 100) : undefined,
      });
    } else if (ev.kind === 'status') {
      event.sender.send(IPC.LOCAL_PULL_MODEL_PROGRESS, { name, phase: ev.status });
    } else if (ev.kind === 'done') {
      event.sender.send(IPC.LOCAL_PULL_MODEL_PROGRESS, { name, phase: 'done', pct: 100 });
    } else {
      event.sender.send(IPC.LOCAL_PULL_MODEL_PROGRESS, { name, phase: 'error', message: ev.message });
    }
  });
  return { ok: true };
});
```

- [ ] **Step 3: Add no-op shims to `remote-shim.ts`**

Open `src/renderer/remote-shim.ts`. Find the `window.claude` assembly. Add a `local` namespace whose methods all reject with "not supported on this platform" (matches the existing pattern for desktop-only APIs):

```ts
local: {
  listModels: async () => [],
  isOllamaInstalled: async () => false,
  installOllama: async () => ({ ok: false, error: 'local mode not supported on this platform' }),
  onInstallOllamaProgress: () => () => {},
  pullModel: async () => ({ ok: false, error: 'local mode not supported on this platform' }),
  onPullModelProgress: () => () => {},
},
```

- [ ] **Step 4: Verify IPC channel parity test still passes**

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/local-harness-mvp/desktop
npx vitest run tests/ipc-channels.test.ts 2>&1 | tail -10
```

Expected: pass (or only logs `console.warn` about drift). If it hard-fails, check that the IPC keys you added to `shared/types.ts` (Task 1, Step 2) match the keys you added to `preload.ts` here.

- [ ] **Step 5: Type-check and commit**

```bash
npx tsc --noEmit 2>&1 | tail -10
```

Expected: no errors.

```bash
git add desktop/src/main/preload.ts desktop/src/main/ipc-handlers.ts desktop/src/renderer/remote-shim.ts
git commit -m "feat(local-harness): wire window.claude.local.* IPC + remote-shim no-ops"
```

---

## Task 7: SessionStrip Runtime Selector

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/SessionStrip.tsx`

Replace the existing `isGemini: boolean` toggle with a three-way **Runtime** selector at the top of the new-session form. When Local is selected, the Model dropdown switches to live-listing installed Ollama models, with an inline "Install Qwen 3 8B →" CTA when none are present.

- [ ] **Step 1: Add `runtime` state and replace the Gemini toggle**

Find the local state at the top of the new-session form (`const [isGemini, setIsGemini] = useState(false);`, around line 166). Replace with:

```tsx
type Runtime = 'claude' | 'local' | 'gemini';
const [runtime, setRuntime] = useState<Runtime>('claude');
const [localModels, setLocalModels] = useState<Array<{ name: string; sizeBytes: number }>>([]);
const [localModelsLoaded, setLocalModelsLoaded] = useState(false);

useEffect(() => {
  if (runtime !== 'local') return;
  let cancelled = false;
  (window.claude as any).local.listModels().then((models: any[]) => {
    if (cancelled) return;
    setLocalModels(models);
    setLocalModelsLoaded(true);
  });
  return () => { cancelled = true; };
}, [runtime]);
```

(The `as any` cast is temporary — once `window.claude.local` is added to the type declarations in `shared/types.ts` or a `globals.d.ts`, replace with the typed accessor.)

- [ ] **Step 2: Add the Runtime segmented control above the form fields**

Inside the expanded new-session form JSX, just before the existing folder picker `<div>`, insert:

```tsx
{/* Runtime picker — Local is ungated; Gemini gated by sessionDefaults.geminiEnabled */}
<div className="mb-3">
  <label className="text-[10px] uppercase tracking-wider text-fg-muted mb-1 block">Runtime</label>
  <div className="inline-flex rounded border border-edge overflow-hidden">
    {(['claude', 'local', ...(geminiEnabled ? ['gemini' as Runtime] : [])] as Runtime[]).map(r => (
      <button
        key={r}
        type="button"
        onClick={() => setRuntime(r)}
        className={`px-3 py-1 text-xs ${runtime === r ? 'bg-accent text-on-accent' : 'bg-panel text-fg hover:bg-inset'}`}
      >
        {r === 'claude' ? 'Claude' : r === 'local' ? 'Local' : 'Gemini'}
      </button>
    ))}
  </div>
</div>
```

- [ ] **Step 3: Replace the model selector body to be runtime-aware**

Find the existing Model selector block (search for `{/* Model selector — grayed out when Gemini is selected */}` around line 949). Replace the entire block with:

```tsx
{/* Model selector — content depends on runtime */}
<div style={{
  opacity: runtime === 'gemini' ? 0.4 : 1,
  pointerEvents: runtime === 'gemini' ? 'none' : 'auto',
  transition: 'opacity 200ms',
}}>
  <label className="text-[10px] uppercase tracking-wider text-fg-muted mb-1 block">Model</label>
  {runtime === 'claude' && (
    <div className="flex gap-1">
      {/* ...existing Claude variant buttons (Sonnet/Opus/Haiku) — leave the JSX
          for these in place, just confine them inside this conditional. */}
    </div>
  )}
  {runtime === 'local' && (
    <>
      {!localModelsLoaded && <div className="text-xs text-fg-muted">Checking installed models…</div>}
      {localModelsLoaded && localModels.length === 0 && (
        <button
          type="button"
          className="text-xs px-2 py-1 rounded bg-accent text-on-accent"
          onClick={() => {
            setShowNewForm(false);
            // Triggers first-run flow — wired in Task 11
            window.dispatchEvent(new CustomEvent('youcoded:open-local-setup'));
          }}
        >
          Install Qwen 3 8B →
        </button>
      )}
      {localModelsLoaded && localModels.length > 0 && (
        <select
          className="bg-panel border border-edge rounded text-fg text-xs px-2 py-1"
          value={newModel}
          onChange={(e) => setNewModel(e.target.value)}
        >
          {localModels.map(m => (
            <option key={m.name} value={m.name}>
              {m.name} ({(m.sizeBytes / 1e9).toFixed(1)} GB)
            </option>
          ))}
        </select>
      )}
    </>
  )}
  {runtime === 'gemini' && <div className="text-xs text-fg-muted">Gemini chooses its own model.</div>}
</div>
```

- [ ] **Step 4: Update the create handler to pass the selected provider**

Find `handleCreate` (around line 336). Replace:

```tsx
const handleCreate = useCallback(() => {
  onCreateSession(newCwd, dangerous, newModel, runtime, launchInNewWindow);
  setMenuOpen(false);
  setShowNewForm(false);
  setDangerous(defaultSkipPermissions || false);
  setNewModel(defaultModel || 'sonnet');
  setRuntime('claude');
  setLaunchInNewWindow(false);
}, [newCwd, dangerous, newModel, runtime, launchInNewWindow, onCreateSession, defaultSkipPermissions, defaultModel]);
```

- [ ] **Step 5: Update the `onCreateSession` prop type**

Find the `Props` interface at the top of the file. Change `provider?: 'claude' | 'gemini'` to `provider?: 'claude' | 'gemini' | 'local'` everywhere it appears (likely 1–2 occurrences in this file).

- [ ] **Step 6: Update HeaderBar's `onCreateSession` prop type**

Open `src/renderer/components/HeaderBar.tsx`. Find the `Props` interface (around line 153). Change `provider?: 'claude' | 'gemini'` to `provider?: 'claude' | 'gemini' | 'local'`.

- [ ] **Step 7: Update App.tsx's `createSession` callback**

Open `src/renderer/App.tsx`. Find the `createSession` useCallback (around line 1562). Change the signature:

```tsx
const createSession = useCallback(async (
  cwd: string,
  dangerous: boolean,
  sessionModel?: string,
  provider?: 'claude' | 'gemini' | 'local',
  launchInNewWindow?: boolean,
) => {
  const m = sessionModel || currentModel;
  const info = await (window.claude.session.create as any)({
    name: provider === 'gemini' ? 'Gemini Session'
        : provider === 'local'  ? 'Local Session'
        : 'New Session',
    cwd,
    skipPermissions: dangerous,
    model: m,
    provider,
    // ... rest unchanged
  });
  // ...
```

- [ ] **Step 8: Type-check and dev-smoke**

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/local-harness-mvp/desktop
npx tsc --noEmit 2>&1 | tail -10
```

Expected: no errors.

Now visual smoke (no commit yet):

```bash
cd /c/Users/desti/youcoded-dev
YOUCODED_WT=youcoded.wt/local-harness-mvp bash scripts/run-dev.sh
```

(If `run-dev.sh` doesn't accept that variable, run `cd youcoded.wt/local-harness-mvp/desktop && npx vite & npx electron .` from the worktree.)

In the dev window: click the "+" in the session strip. Verify the **Runtime** selector shows Claude / Local. Click Local — verify the model dropdown appears (will say "Checking installed models…" and either show models or the install CTA depending on whether Ollama is running locally). The "+" doesn't actually create a Local session yet at this point because the create flow is wired but the harness isn't smoke-tested end-to-end until Task 13 — that's expected.

Close the dev window when done.

- [ ] **Step 9: Commit**

```bash
git add desktop/src/renderer/components/SessionStrip.tsx desktop/src/renderer/components/HeaderBar.tsx desktop/src/renderer/App.tsx
git commit -m "feat(local-harness): three-way Runtime selector in new-session form"
```

---

## Task 8: HeaderBar + ModelPickerPopup — runtime-aware UI

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/HeaderBar.tsx`
- Modify: `youcoded/desktop/src/renderer/components/ModelPickerPopup.tsx`

Local sessions don't have a terminal pane and don't have permission modes, so those UI elements should hide. The mid-session model picker should scope its list to the current session's runtime.

- [ ] **Step 1: Hide chat/terminal toggle for local sessions**

Open `src/renderer/components/HeaderBar.tsx`. Find the chat/terminal toggle block (search for `viewMode === 'terminal'` or `onToggleView`). Wrap it in a conditional that checks the current session's provider. The simplest form, assuming `currentSession?: SessionInfo` is in props:

```tsx
{currentSession?.provider !== 'local' && (
  <ChatTerminalToggle viewMode={viewMode} onToggleView={onToggleView} />
)}
```

(If `HeaderBar` doesn't already receive the active session, plumb it: add `currentSession?: SessionInfo` to `Props`, pass `sessions.find(s => s.id === activeSessionId)` from `App.tsx`.)

- [ ] **Step 2: Hide permission-mode badge for local sessions**

Same file, find the permission-mode badge (search for `permissionMode` in the JSX). Wrap analogously:

```tsx
{currentSession?.provider !== 'local' && (
  <PermissionModeBadge ... />
)}
```

- [ ] **Step 3: Update `ModelPickerPopup` to scope the list by runtime**

Open `src/renderer/components/ModelPickerPopup.tsx`. The popup currently lists Claude variants. Add a `provider` prop and conditionally render either the Claude list or the local-models list:

```tsx
interface ModelPickerPopupProps {
  // ... existing
  provider?: SessionProvider;            // active session's runtime
  endpoint?: string;                     // active session's endpoint (for local)
}

// Inside the component:
const [localModels, setLocalModels] = useState<Array<{ name: string; sizeBytes: number }>>([]);

useEffect(() => {
  if (provider !== 'local') return;
  let cancelled = false;
  (window.claude as any).local.listModels().then((models: any[]) => {
    if (!cancelled) setLocalModels(models);
  });
  return () => { cancelled = true; };
}, [provider]);

// In the render body, branch:
if (provider === 'local') {
  return (
    <div className="...">
      <div className="text-[10px] uppercase tracking-wider text-fg-muted mb-1 px-2 pt-2">
        Local Models
      </div>
      {localModels.map(m => (
        <button
          key={m.name}
          onClick={() => onSelect(m.name)}
          className="w-full text-left px-2 py-1 hover:bg-inset"
        >
          {m.name} <span className="text-fg-muted text-xs">({(m.sizeBytes / 1e9).toFixed(1)} GB)</span>
        </button>
      ))}
      {localModels.length === 0 && (
        <div className="px-2 py-1 text-xs text-fg-muted">No local models installed.</div>
      )}
    </div>
  );
}

// ... existing Claude-variant render below
```

- [ ] **Step 4: Wire `provider` into `ModelPickerPopup` from its parent**

In `App.tsx` (or wherever `ModelPickerPopup` is rendered), pass the active session's `provider`:

```tsx
<ModelPickerPopup
  // ... existing
  provider={activeSession?.provider}
  endpoint={activeSession?.endpoint}
/>
```

- [ ] **Step 5: Type-check and commit**

```bash
npx tsc --noEmit 2>&1 | tail -10
```

Expected: no errors.

```bash
git add desktop/src/renderer/components/HeaderBar.tsx desktop/src/renderer/components/ModelPickerPopup.tsx desktop/src/renderer/App.tsx
git commit -m "feat(local-harness): hide terminal toggle + permission badge for local sessions; runtime-scoped ModelPicker"
```

---

## Task 9: Stop Button + ESC Routing for Local Sessions

**Files:**
- Modify: `youcoded/desktop/src/renderer/App.tsx`

The existing chat-passthrough listener in `App.tsx` writes `\x1b` to the PTY when ESC is pressed in chat mode. For local sessions, the `\x1b` reaches `SessionManager.sendInput`, which (per Task 5, Step 4) interprets a single ESC byte as `cancel()`. So the wiring for ESC actually works without changes. **Verify** rather than re-wire.

The Stop button in `InputBar` likewise dispatches an interrupt-like input. Audit and ensure the cancel path works end-to-end.

- [ ] **Step 1: Audit ESC routing**

Search for the chat-passthrough ESC listener:

```bash
cd /c/Users/desti/youcoded-dev/youcoded.wt/local-harness-mvp/desktop
grep -n "x1b\|escape" src/renderer/App.tsx | head -20
```

Identify the line that calls `window.claude.session.sendInput(activeSessionId, '\x1b')` (or equivalent). Verify it does NOT additionally short-circuit on `viewMode === 'terminal'` for local sessions in a way that suppresses the cancel. Local sessions have no terminal mode, so the chat-passthrough check `viewMode === 'chat'` should always be true and ESC routes through.

- [ ] **Step 2: Audit Stop button**

Open `src/renderer/components/InputBar.tsx` (or wherever the Stop button lives). Find what it dispatches when clicked. If it sends `'\x1b'` via `sendInput`, no change needed. If it sends a different sentinel for Claude (e.g. a custom `interrupt` IPC), add a parallel branch for local sessions:

```tsx
const handleStop = () => {
  if (currentSession?.provider === 'local') {
    window.claude.session.sendInput(currentSession.id, '\x1b');
  } else {
    // existing path
  }
};
```

- [ ] **Step 3: Manual smoke (no automated test)**

(Defer the actual end-to-end test to Task 13. This task is an audit + minor fix only.)

- [ ] **Step 4: Type-check and commit**

```bash
npx tsc --noEmit 2>&1 | tail -10
```

Expected: no errors.

```bash
git add desktop/src/renderer/App.tsx desktop/src/renderer/components/InputBar.tsx
git commit -m "feat(local-harness): route ESC + Stop button through cancel for local sessions"
```

---

## Task 10: Settings Panel — Local Models Section

**Files:**
- Modify: `youcoded/desktop/src/renderer/components/SettingsPanel.tsx`

Add a "Local Models" settings section: endpoint URL field, default model dropdown (sourced from installed Ollama models), system prompt override textarea.

- [ ] **Step 1: Locate where existing settings sections are defined**

Open `src/renderer/components/SettingsPanel.tsx`. Find the section structure — likely a list of `<SettingsSection title="...">` blocks or similar. Add a new section after the most-related existing one (e.g. after "Defaults" or near the Gemini-toggle area).

- [ ] **Step 2: Add the section**

Define the new section, persisting changes via the existing `sessionDefaults` mechanism (extend the shape):

```tsx
<SettingsSection title="Local Models">
  <div className="space-y-3">
    <div>
      <label className="text-xs text-fg-muted">Endpoint URL</label>
      <input
        type="text"
        className="w-full bg-panel border border-edge rounded px-2 py-1 text-sm"
        value={defaults.localEndpoint || 'http://localhost:11434/v1'}
        onChange={(e) => onDefaultsChange({ localEndpoint: e.target.value })}
      />
      <div className="text-[10px] text-fg-muted mt-1">
        Defaults to Ollama on localhost. Point at LM Studio (typically <code>http://localhost:1234/v1</code>) or any other OpenAI-compatible endpoint.
      </div>
    </div>
    <div>
      <label className="text-xs text-fg-muted">Default Model</label>
      <select
        className="w-full bg-panel border border-edge rounded px-2 py-1 text-sm"
        value={defaults.localDefaultModel || ''}
        onChange={(e) => onDefaultsChange({ localDefaultModel: e.target.value })}
      >
        <option value="">(use first installed)</option>
        {localModelsForSettings.map(m => (
          <option key={m.name} value={m.name}>{m.name}</option>
        ))}
      </select>
    </div>
    <div>
      <label className="text-xs text-fg-muted">System Prompt</label>
      <textarea
        rows={4}
        className="w-full bg-panel border border-edge rounded px-2 py-1 text-sm font-mono"
        value={defaults.localSystemPrompt || ''}
        placeholder="You are a helpful assistant. The user is using YouCoded..."
        onChange={(e) => onDefaultsChange({ localSystemPrompt: e.target.value })}
      />
    </div>
  </div>
</SettingsSection>
```

Add the `localModelsForSettings` state with a `useEffect` that calls `window.claude.local.listModels()` when the panel mounts.

- [ ] **Step 3: Extend the `defaults` interface**

Find the `DefaultsButtonProps` and `sessionDefaults` shape (in this file and `App.tsx`). Add the three optional fields:

```tsx
defaults: {
  // ... existing
  localEndpoint?: string;
  localDefaultModel?: string;
  localSystemPrompt?: string;
};
```

Persist via the same store the existing defaults use (likely `~/.claude/youcoded-settings.json` or equivalent).

- [ ] **Step 4: Plumb defaults into createSession for local provider**

In `App.tsx`, when `createSession` runs with `provider === 'local'`, pass the configured defaults:

```tsx
if (provider === 'local') {
  // Augment the create call with local defaults
  const info = await (window.claude.session.create as any)({
    // ... existing
    endpoint: sessionDefaults.localEndpoint || 'http://localhost:11434/v1',
    systemPrompt: sessionDefaults.localSystemPrompt || undefined,
    model: sessionModel || sessionDefaults.localDefaultModel || 'qwen3:8b',
  });
}
```

- [ ] **Step 5: Type-check and commit**

```bash
npx tsc --noEmit 2>&1 | tail -10
```

Expected: no errors.

```bash
git add desktop/src/renderer/components/SettingsPanel.tsx desktop/src/renderer/App.tsx
git commit -m "feat(local-harness): Local Models settings section (endpoint, default model, system prompt)"
```

---

## Task 11: Ollama Install via prerequisite-installer + First-Run Flow

**Files:**
- Modify: `youcoded/desktop/src/main/prerequisite-installer.ts`
- Modify: `youcoded/desktop/src/main/ipc-handlers.ts`

Replace the stub `LOCAL_INSTALL_OLLAMA` handler from Task 6 with a real installer that uses Anthropic-installer-style native bootstrap scripts (per platform).

- [ ] **Step 1: Add `installOllama` to `prerequisite-installer.ts`**

Open `src/main/prerequisite-installer.ts`. Look at the existing `installClaude` implementation as a reference (it follows the same shape — download a script, run it). Add:

```ts
export async function installOllama(
  onProgress: (ev: { phase: string; message?: string; pct?: number }) => void,
): Promise<{ ok: boolean; error?: string }> {
  onProgress({ phase: 'starting', message: 'Downloading Ollama installer…' });
  const platform = process.platform;
  try {
    if (platform === 'win32') {
      // Ollama ships an MSI; download + silent install
      // URL is stable per Ollama docs but coupled — see cc-dependencies-style entry below
      const installerPath = path.join(os.tmpdir(), 'OllamaSetup.exe');
      await downloadFile('https://ollama.com/download/OllamaSetup.exe', installerPath, (pct) => {
        onProgress({ phase: 'downloading', pct, message: 'Downloading Ollama (~300 MB)' });
      });
      onProgress({ phase: 'installing', message: 'Running Ollama installer…' });
      // Silent install if available; otherwise the user gets the wizard
      await runCommand(installerPath, ['/S'], { shell: false });
    } else if (platform === 'darwin') {
      // macOS: download and unzip Ollama.app, move to /Applications. For MVP,
      // open the download URL and instruct the user — full silent install is non-trivial on macOS.
      shell.openExternal('https://ollama.com/download/Ollama-darwin.zip');
      return { ok: false, error: 'macOS silent install not yet supported — Ollama install opened in browser.' };
    } else if (platform === 'linux') {
      // Linux: official one-liner
      await runCommand('sh', ['-c', 'curl -fsSL https://ollama.com/install.sh | sh'], { shell: false });
    } else {
      return { ok: false, error: `unsupported platform: ${platform}` };
    }
    onProgress({ phase: 'verifying', message: 'Checking Ollama is running…' });
    // Give the daemon a moment to come up
    for (let i = 0; i < 10; i++) {
      await new Promise(r => setTimeout(r, 1000));
      if (await new (require('./ollama-detector').OllamaDetector)().isReachable()) {
        onProgress({ phase: 'done', pct: 100 });
        return { ok: true };
      }
    }
    return { ok: false, error: 'Ollama installed but daemon did not start within 10 s' };
  } catch (e: any) {
    return { ok: false, error: String(e?.message ?? e) };
  }
}

async function downloadFile(url: string, dest: string, onPct: (pct: number) => void): Promise<void> {
  const res = await fetch(url);
  if (!res.ok || !res.body) throw new Error(`download failed: HTTP ${res.status}`);
  const total = Number(res.headers.get('content-length') ?? 0);
  let received = 0;
  const out = fs.createWriteStream(dest);
  const reader = res.body.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    out.write(value);
    received += value.byteLength;
    if (total > 0) onPct(Math.round((received / total) * 100));
  }
  out.end();
  await new Promise<void>((resolve, reject) => {
    out.on('finish', () => resolve());
    out.on('error', reject);
  });
}
```

(`runCommand` should already exist in this file — see existing usage. If not, add a small `child_process.spawn`-based wrapper.)

- [ ] **Step 2: Update the IPC handler to call the real installer**

In `src/main/ipc-handlers.ts`, replace the stub `LOCAL_INSTALL_OLLAMA` handler from Task 6:

```ts
ipcMain.handle(IPC.LOCAL_INSTALL_OLLAMA, async (event) => {
  const { installOllama } = await import('./prerequisite-installer');
  return await installOllama((ev) => {
    event.sender.send(IPC.LOCAL_INSTALL_OLLAMA_PROGRESS, ev);
  });
});
```

- [ ] **Step 3: Add a CC-dependencies-style entry**

Open `youcoded/docs/cc-dependencies.md`. Add a new entry:

```markdown
## Native installer bootstrap script (Local — Ollama)

**Touchpoint:** `src/main/prerequisite-installer.ts → installOllama`
**CC version touched:** N/A — this is for Ollama, not Claude Code.
**Coupling:** Depends on Ollama publishing installer binaries at `https://ollama.com/download/OllamaSetup.exe` (Windows) and the Linux install script at `https://ollama.com/install.sh`. If Ollama moves these URLs or changes the silent-install flag (`/S`), `installOllama` breaks.
**Mitigation:** First-run failure surfaces a clear error; user can install Ollama manually from ollama.com.
```

- [ ] **Step 4: Wire the renderer's first-run trigger**

In Task 7, Step 3 we dispatched `youcoded:open-local-setup` when the user clicks "Install Qwen 3 8B →". Add a listener in `App.tsx` that opens a small modal with two phases:

1. Install Ollama (if not reachable)
2. Pull Qwen 3 8B (if no models installed)

For brevity, the simplest implementation is a small inline component. Add to `App.tsx`:

```tsx
const [localSetupOpen, setLocalSetupOpen] = useState(false);
useEffect(() => {
  const handler = () => setLocalSetupOpen(true);
  window.addEventListener('youcoded:open-local-setup', handler);
  return () => window.removeEventListener('youcoded:open-local-setup', handler);
}, []);

// Render the modal when localSetupOpen is true:
{localSetupOpen && (
  <LocalSetupModal onClose={() => setLocalSetupOpen(false)} />
)}
```

Create `src/renderer/components/LocalSetupModal.tsx`:

```tsx
import { useEffect, useState } from 'react';

export function LocalSetupModal({ onClose }: { onClose: () => void }) {
  const [phase, setPhase] = useState<'check' | 'install-ollama' | 'pull-model' | 'done' | 'error'>('check');
  const [progress, setProgress] = useState<{ pct?: number; message?: string }>({});
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const ollamaUp = await (window.claude as any).local.isOllamaInstalled();
      if (!ollamaUp) {
        setPhase('install-ollama');
        const off = (window.claude as any).local.onInstallOllamaProgress((ev: any) => setProgress(ev));
        const result = await (window.claude as any).local.installOllama();
        off();
        if (!result.ok) { setError(result.error || 'install failed'); setPhase('error'); return; }
      }
      const models = await (window.claude as any).local.listModels();
      if (models.length === 0) {
        setPhase('pull-model');
        const off = (window.claude as any).local.onPullModelProgress((ev: any) => setProgress(ev));
        const result = await (window.claude as any).local.pullModel('qwen3:8b');
        off();
        if (!result.ok) { setError(result.error || 'pull failed'); setPhase('error'); return; }
      }
      setPhase('done');
    })();
  }, []);

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-panel rounded-lg p-6 w-[28rem] max-w-[90vw]">
        <h2 className="text-lg font-semibold mb-3">Local Mode Setup</h2>
        {phase === 'check'          && <div>Checking Ollama…</div>}
        {phase === 'install-ollama' && <div>Installing Ollama: {progress.message ?? ''} {progress.pct != null && `(${progress.pct}%)`}</div>}
        {phase === 'pull-model'     && <div>Downloading Qwen 3 8B: {progress.message ?? ''} {progress.pct != null && `(${progress.pct}%)`}</div>}
        {phase === 'done'           && <div>Ready! You can now create Local sessions.</div>}
        {phase === 'error'          && <div className="text-red-500">Error: {error}</div>}
        <button onClick={onClose} className="mt-4 px-3 py-1 bg-accent text-on-accent rounded">
          {phase === 'done' || phase === 'error' ? 'Close' : 'Cancel'}
        </button>
      </div>
    </div>
  );
}
```

- [ ] **Step 5: Type-check and commit**

```bash
npx tsc --noEmit 2>&1 | tail -10
```

Expected: no errors.

```bash
git add desktop/src/main/prerequisite-installer.ts desktop/src/main/ipc-handlers.ts desktop/src/renderer/components/LocalSetupModal.tsx desktop/src/renderer/App.tsx youcoded/docs/cc-dependencies.md
git commit -m "feat(local-harness): Ollama install path + first-run setup modal"
```

---

## Task 12: ResumeBrowser Support for Local Sessions

**Files:**
- Modify: `youcoded/desktop/src/main/ipc-handlers.ts` (add list IPC)
- Modify: `youcoded/desktop/src/main/preload.ts` (expose list IPC)
- Modify: `youcoded/desktop/src/renderer/components/restore/ResumeBrowser.tsx`

The `ResumeBrowser` lists past Claude sessions today; gain a "Local" tab/filter that lists past local sessions from `LocalSessionStore.listAll()`.

- [ ] **Step 1: Add a `LOCAL_LIST_SESSIONS` IPC channel**

In `shared/types.ts` `IPC` object, add:

```ts
LOCAL_LIST_SESSIONS: 'local:list-sessions',
```

In `preload.ts`, expose under `local`:

```ts
listSessions: () => ipcRenderer.invoke(IPC.LOCAL_LIST_SESSIONS),
```

In `remote-shim.ts`, no-op:

```ts
listSessions: async () => [],
```

In `ipc-handlers.ts`, wire to the store. Pass the store in via main.ts (or read directly):

```ts
import { LocalSessionStore } from './local-session-store';
const localStoreForIpc = new LocalSessionStore(path.join(os.homedir(), '.claude', 'youcoded-local'));

ipcMain.handle(IPC.LOCAL_LIST_SESSIONS, async () => {
  return await localStoreForIpc.listAll();
});
```

(For consistency it's cleaner to share one `LocalSessionStore` instance across `main.ts` and `ipc-handlers.ts`. Refactor as a singleton if natural, otherwise two readers of the same dir is benign — they both read; only `LocalSessionHarness` writes.)

- [ ] **Step 2: Add a "Local" tab to `ResumeBrowser`**

Open `src/renderer/components/restore/ResumeBrowser.tsx`. Find where the existing session list is rendered (likely a list grouped by project). Add a tab/filter at the top:

```tsx
const [tab, setTab] = useState<'claude' | 'local'>('claude');
const [localSessions, setLocalSessions] = useState<any[]>([]);

useEffect(() => {
  if (tab !== 'local') return;
  (window.claude as any).local.listSessions().then(setLocalSessions);
}, [tab]);

return (
  <div>
    <div className="flex gap-2 border-b border-edge mb-3">
      <button
        className={`px-3 py-1 ${tab === 'claude' ? 'border-b-2 border-accent' : ''}`}
        onClick={() => setTab('claude')}
      >
        Claude
      </button>
      <button
        className={`px-3 py-1 ${tab === 'local' ? 'border-b-2 border-accent' : ''}`}
        onClick={() => setTab('local')}
      >
        Local
      </button>
    </div>
    {tab === 'claude' && (
      // existing JSX
    )}
    {tab === 'local' && (
      <div className="space-y-1">
        {localSessions.length === 0 && <div className="text-fg-muted text-sm">No local sessions yet.</div>}
        {localSessions.map(s => (
          <button
            key={s.id}
            className="w-full text-left px-2 py-2 rounded hover:bg-inset"
            onClick={() => onResumeLocal(s.id)}
          >
            <div className="font-medium">{s.title}</div>
            <div className="text-xs text-fg-muted">
              {s.model} · {new Date(s.updatedAt).toLocaleString()}
            </div>
          </button>
        ))}
      </div>
    )}
  </div>
);
```

- [ ] **Step 3: Implement `onResumeLocal` in the parent**

In `App.tsx` (or wherever `ResumeBrowser` is rendered), add:

```tsx
const onResumeLocal = useCallback(async (sessionId: string) => {
  const info = await (window.claude.session.create as any)({
    name: 'Local Session',
    cwd: '',
    skipPermissions: false,
    provider: 'local',
    resumeSessionId: sessionId,    // signal to SessionManager to resume rather than start fresh
  });
  // ... existing post-create wiring
}, []);
```

In `SessionManager.createSession` (Task 5), add a check at the top of the `local` branch:

```ts
if (opts.resumeSessionId) {
  // Resume an existing local session instead of creating a new one
  this.localHarness!.resumeSession(opts.resumeSessionId).then((info) => {
    this.sessions.set(info.id, { info, worker: null as any });
    this.emit('session-created', info);
  });
  return /* placeholder SessionInfo with the resume id */;
}
```

(The placeholder-then-replace pattern matches how Claude session resume works today; mirror its existing shape.)

- [ ] **Step 4: Type-check and commit**

```bash
npx tsc --noEmit 2>&1 | tail -10
```

Expected: no errors.

```bash
git add desktop/src/shared/types.ts desktop/src/main/preload.ts desktop/src/main/ipc-handlers.ts desktop/src/renderer/remote-shim.ts desktop/src/renderer/components/restore/ResumeBrowser.tsx desktop/src/renderer/App.tsx desktop/src/main/session-manager.ts
git commit -m "feat(local-harness): ResumeBrowser shows local sessions; resume path via LocalSessionHarness"
```

---

## Task 13: End-to-End Smoke Test

**Files:** None modified — manual verification in dev mode.

Validates the full flow: Ollama runs, model is installed, user creates a Local session, sends a message, sees streamed response, persistence works across restart, cancel works, resume works.

- [ ] **Step 1: Confirm Ollama is running locally**

```bash
curl -s http://localhost:11434/api/version
```

Expected: `{"version":"0.x.x"}`. If Ollama isn't installed, install it through the dev app's first-run flow as part of this test, OR install manually first to keep the test focused on the harness.

- [ ] **Step 2: Confirm Qwen 3 8B is pulled**

```bash
curl -s http://localhost:11434/api/tags | grep qwen3
```

If empty, pull it: `ollama pull qwen3:8b` (takes ~5 min depending on connection). Or test the in-app pull flow.

- [ ] **Step 3: Launch dev mode against the worktree**

```bash
cd /c/Users/desti/youcoded-dev
YOUCODED_WT=youcoded.wt/local-harness-mvp bash scripts/run-dev.sh
```

A "YouCoded Dev" window opens.

- [ ] **Step 4: Create a Local session**

Click "+" → choose **Local** runtime → select `qwen3:8b` from the model dropdown → leave folder as default → click Create.

Verify:
- A new session appears in the strip with `qwen3:8b` shown in the model pill
- The chat view (not terminal view) is shown — view-mode toggle is hidden in the header
- Permission-mode badge is hidden in the header

- [ ] **Step 5: Send a message and verify streaming**

Type "Hello, what is 2+2?" in the input bar and press Enter.

Verify:
- User bubble appears immediately
- Assistant reply streams in chunk-by-chunk (visible flicker as text grows)
- Markdown renders correctly (try a follow-up like "Show me a fenced code block of Python")
- Stop button is visible while streaming

- [ ] **Step 6: Test cancel mid-stream**

Send a long-form message: "Write a 500-word essay about cats." During the streaming, click the Stop button.

Verify:
- Stream halts within ~1 second
- The partial assistant message is preserved (not cleared)
- A new message can be sent immediately after

- [ ] **Step 7: Test persistence across restart**

Close the dev window. Re-launch with `bash scripts/run-dev.sh`. Open the resume browser → click the "Local" tab.

Verify:
- The session you created appears with the correct title (auto-derived from the first message)
- Click it; the full conversation re-loads in chat view
- Send another message; the model responds with context (the prior conversation is in its prompt)

- [ ] **Step 8: Verify Claude sessions still work**

Open the same dev window, click "+" → choose **Claude** runtime → create. Send a message. Verify the existing Claude session experience is unchanged (terminal toggle visible, permission badge visible, etc.).

- [ ] **Step 9: Shut down dev mode**

Close the dev window. Verify (Task Manager / `ps`) that no orphaned `electron` or `vite` processes remain.

- [ ] **Step 10: Commit a final marker (no code change)**

```bash
git commit --allow-empty -m "chore(local-harness): MVP smoke test passed"
```

---

## After Completion

The MVP is now mergeable. To finish:

```bash
# Push the feature branch
cd /c/Users/desti/youcoded-dev/youcoded.wt/local-harness-mvp
git push -u origin feat/local-harness-mvp

# Open a PR (use the gh CLI per CLAUDE.md instructions)
gh pr create --title "feat: multi-model harness MVP — chat-only Local sessions via Ollama" --body "$(cat <<'EOF'
## Summary
- Adds 'local' SessionProvider; LocalSessionHarness in main process emits the existing transcript:event shape so chat reducer/UI work unchanged.
- New-session form has a three-way Runtime selector (Claude / Local / Gemini).
- Ollama auto-install + Qwen 3 8B pull via prerequisite-installer pattern.
- Local sessions persisted to ~/.claude/youcoded-local/sessions/<id>.json; resume supported.

Spec: docs/superpowers/specs/2026-05-04-multi-model-harness-design.md
Plan: docs/superpowers/plans/2026-05-04-multi-model-harness-mvp.md

## Test plan
- [x] Unit tests pass (LocalSessionStore, OllamaDetector, LocalSessionHarness)
- [x] tsc clean
- [x] End-to-end smoke (Task 13) verified manually
- [ ] Existing Claude session creation unchanged (verified in smoke step 8)
EOF
)"
```

After the PR merges to `master`:

```bash
# Clean up the worktree per CLAUDE.md ("Clean up worktrees after merging to master")
cd /c/Users/desti/youcoded-dev/youcoded.wt/local-harness-mvp/desktop
cmd //c "rmdir node_modules"   # FIRST — git worktree remove follows junctions on Windows
cd /c/Users/desti/youcoded-dev/youcoded
git worktree remove ../youcoded.wt/local-harness-mvp
git branch -D feat/local-harness-mvp
```

---

## Out of MVP Scope (defer to follow-up specs)

The roadmap section of the spec covers Stages B–D. The next plan should be Stage B: tools (Read/Write/Edit/Bash/Glob), permission flow reusing the existing `PERMISSION_REQUEST` shape, agent loop via Vercel AI SDK's `streamText({ tools, stopWhen: stepCountIs(N) })`. Spec it with the brainstorming skill before writing the next plan.
