# WeCoded Marketplace Publisher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `wecoded-marketplace-publisher` plugin — a conversational slash-command tool that helps non-technical users publish plugins (skills, commands, hooks, MCPs, agents) to the WeCoded marketplace, offering either a self-maintained community path or an adoption-request handoff to WeCoded.

**Architecture:** One Claude Code plugin at `wecoded-marketplace/wecoded-marketplace-publisher/` containing a single slash command + a single skill (`SKILL.md` conversational flow) plus four Node.js helper scripts (`inventory.js`, `build-plugin.js`, `preflight.js`, `publish.js`). The skill orchestrates conversation and delegates deterministic work to the scripts via JSON stdin/stdout. GitHub operations go through the `gh` CLI.

**Tech Stack:** Node.js (bundled with Claude Code), `node --test` runner, `gh` CLI, Claude Code plugin format, wecoded-marketplace plugin conventions.

**Design reference:** `docs/superpowers/specs/2026-04-20-wecoded-marketplace-publisher-design.md` in the `youcoded-dev` workspace. Read before starting — this plan assumes familiarity with the spec.

---

## Prerequisites

- **Work inside `wecoded-marketplace/` repo**, not `youcoded-dev` (youcoded-dev is the workspace scaffold; code pushes go to the sub-repo).
- **Use a git worktree.** From `wecoded-marketplace/`: `git worktree add ../wecoded-marketplace-publisher-feat -b feat/marketplace-publisher`. `cd` into the worktree.
- **Node version:** whatever ships with Claude Code (currently Node 20+). No special runtime setup needed.
- **`gh` CLI** must be installed and authed for tasks 11-13 (publish-related) integration testing. Install with `winget install GitHub.cli` / `brew install gh` and run `gh auth login` if needed.
- **`jq`** helpful but not required; all JSON inspection in tests uses Node assertions.

## File structure map

```
wecoded-marketplace-publisher/
├── plugin.json                            # Task 1 — marketplace manifest
├── README.md                              # Task 1 — user-facing overview
├── package.json                           # Task 1 — for node --test + deps
├── LICENSE                                # Task 1 — copy from civic-report
├── commands/
│   └── publish-to-marketplace.md          # Task 1 — slash command entry
├── skills/
│   └── marketplace-publisher/
│       └── SKILL.md                       # Tasks 14-16 — conversation
├── scripts/
│   ├── inventory.js                       # Tasks 2-4 — disk scanner
│   ├── build-plugin.js                    # Tasks 5-8 — plugin assembler
│   ├── preflight.js                       # Tasks 9-10 — local validation
│   ├── publish.js                         # Tasks 11-13 — gh + PRs
│   └── lib/
│       ├── secret-patterns.js             # Task 7 — regex table
│       ├── schema-fetch.js                # Task 10 — fetch marketplace schema
│       └── ledger.js                      # Task 11 — published.json I/O
└── tests/
    ├── inventory.test.js                  # Tasks 2-4
    ├── build-plugin.test.js               # Tasks 5-8
    ├── preflight.test.js                  # Tasks 9-10
    ├── publish.test.js                    # Tasks 11-13
    └── fixtures/
        ├── home-with-skills/              # Task 2 — fake ~/.claude/ tree
        ├── home-with-all-types/           # Task 3 — all signal types
        ├── plugin-with-secrets/           # Task 7 — secret scanner input
        ├── valid-plugin-tree/             # Task 9 — preflight pass case
        └── schema-fixture.js              # Task 10 — fake schema for tests
```

Each file has one clear responsibility. Scripts are pure(-ish): JSON in, JSON out, side effects confined to the working dir or the user's GitHub account.

Marketplace self-entry is edited at: `wecoded-marketplace/marketplace.json` (task 18).

---

### Task 1: Plugin scaffolding & test infrastructure

**Files:**
- Create: `wecoded-marketplace-publisher/plugin.json`
- Create: `wecoded-marketplace-publisher/README.md`
- Create: `wecoded-marketplace-publisher/package.json`
- Create: `wecoded-marketplace-publisher/LICENSE` (copied from `civic-report/LICENSE`)
- Create: `wecoded-marketplace-publisher/commands/publish-to-marketplace.md`
- Create: `wecoded-marketplace-publisher/skills/marketplace-publisher/SKILL.md` (stub only — filled in tasks 14-16)
- Create: `wecoded-marketplace-publisher/scripts/.gitkeep`
- Create: `wecoded-marketplace-publisher/tests/.gitkeep`

- [ ] **Step 1: Create directory structure**

```bash
cd wecoded-marketplace
mkdir -p wecoded-marketplace-publisher/{commands,skills/marketplace-publisher,scripts/lib,tests/fixtures}
touch wecoded-marketplace-publisher/scripts/.gitkeep wecoded-marketplace-publisher/tests/.gitkeep
```

- [ ] **Step 2: Write `plugin.json`**

File: `wecoded-marketplace-publisher/plugin.json`

```json
{
  "name": "wecoded-marketplace-publisher",
  "version": "0.1.0",
  "description": "Publish your skills, commands, hooks, and MCPs to the WeCoded marketplace — conversational, non-technical-user friendly.",
  "author": {
    "name": "@destin"
  },
  "homepage": "https://github.com/itsdestin/wecoded-marketplace/tree/master/wecoded-marketplace-publisher",
  "keywords": ["publish", "marketplace", "plugin", "skill", "mcp", "submission"]
}
```

- [ ] **Step 3: Write `package.json`**

File: `wecoded-marketplace-publisher/package.json`

```json
{
  "name": "wecoded-marketplace-publisher",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=20" },
  "scripts": {
    "test": "node --test tests/*.test.js"
  }
}
```

> **Test-script note:** `node --test tests/` (directory form) is unreliable on Node 25 + Windows Git Bash. The glob form `tests/*.test.js` matches the `civic-report/` sibling convention and works everywhere.

- [ ] **Step 4: Copy LICENSE from civic-report**

```bash
cp ../civic-report/LICENSE wecoded-marketplace-publisher/LICENSE
```

- [ ] **Step 5: Write `commands/publish-to-marketplace.md`**

File: `wecoded-marketplace-publisher/commands/publish-to-marketplace.md`

```markdown
---
description: Publish a plugin you built to the WeCoded marketplace — walks you through discovery, packaging, and submission.
---

Invoke the `marketplace-publisher` skill to start the publish flow.
```

- [ ] **Step 6: Write SKILL.md stub**

File: `wecoded-marketplace-publisher/skills/marketplace-publisher/SKILL.md`

```markdown
---
name: marketplace-publisher
description: Conversational assistant that helps users publish their plugins (skills, commands, hooks, MCPs, agents) to the WeCoded marketplace. Offers a community-maintained path and an adoption-request path. Handles disk discovery, plugin rebuild, secret sanitization, and PR creation.
---

# WeCoded Marketplace Publisher

(Full skill body filled in during tasks 14-16.)
```

- [ ] **Step 7: Write user-facing README**

File: `wecoded-marketplace-publisher/README.md`

```markdown
# WeCoded Marketplace Publisher

Publish your plugins to the WeCoded marketplace — skills, commands, hooks, MCPs, agents, or any combination — without needing to know how plugins are structured.

## What it does

Run `/publish-to-marketplace`. The skill will:

1. Ask you what you made, in your own words
2. Find the pieces on your computer
3. Show you what it found and confirm with you
4. Package everything into a proper plugin
5. Detect any secrets you may have included and help you sanitize them
6. Let you review the final plugin before anything leaves your machine
7. Create a public GitHub repo under your account and open a PR to the marketplace

## Two paths

- **Community plugin** — you maintain it in your own GitHub repo; the marketplace lists it with a Community badge.
- **Request WeCoded adoption** — same community listing goes live, and WeCoded separately reviews whether to take it over. If accepted, WeCoded hosts and maintains an "Official" version; you lose control of the adopted version.

You decide after seeing the finished plugin.

## Requirements

- `gh` CLI installed and authenticated (`gh auth login`)
- A GitHub account
```

- [ ] **Step 8: Verify test runner works**

```bash
cd wecoded-marketplace-publisher
echo "import { test } from 'node:test'; test('scaffold', () => {});" > tests/smoke.test.js
npm test
```

Expected: `tests 1` / `pass 1`.

- [ ] **Step 9: Delete the smoke test and commit**

```bash
rm tests/smoke.test.js
git add wecoded-marketplace-publisher/
git commit -m "feat(publisher): scaffold plugin directory and manifest"
```

---

### Task 2: Inventory — skill scanner

**Files:**
- Create: `wecoded-marketplace-publisher/scripts/inventory.js`
- Create: `wecoded-marketplace-publisher/tests/inventory.test.js`
- Create: `wecoded-marketplace-publisher/tests/fixtures/home-with-skills/.claude/skills/summarize-emails/SKILL.md`

**Scanner responsibility:** given a fake `$HOME`, find all `SKILL.md` files under `$HOME/.claude/skills/*/` and `$HOME/.claude/plugins/**/skills/*/`, parse their YAML frontmatter, and return a list of candidate skills.

- [ ] **Step 1: Create the fixture tree**

File: `tests/fixtures/home-with-skills/.claude/skills/summarize-emails/SKILL.md`

```markdown
---
name: summarize-emails
description: Summarize the user's inbox using the Gmail MCP, grouped by sender importance.
---

# Summarize Emails

This skill uses `mcp__gmail__list_messages` and `mcp__gmail__get_message` to fetch recent mail, then clusters by sender frequency.
```

File: `tests/fixtures/home-with-skills/.claude/plugins/marketplaces/youcoded/plugins/cool-plugin/skills/cool-subskill/SKILL.md`

```markdown
---
name: cool-subskill
description: A skill that lives inside an already-installed plugin.
---
```

- [ ] **Step 2: Write the failing test**

File: `tests/inventory.test.js`

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inventorySkills } from '../scripts/inventory.js';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_HOME = path.join(__dirname, 'fixtures/home-with-skills');

test('inventorySkills finds user-level skills', async () => {
  const results = await inventorySkills({ home: FIXTURE_HOME });
  const names = results.map(r => r.name).sort();
  assert.deepEqual(names, ['cool-subskill', 'summarize-emails']);
});

test('inventorySkills captures frontmatter description', async () => {
  const results = await inventorySkills({ home: FIXTURE_HOME });
  const emailSkill = results.find(r => r.name === 'summarize-emails');
  assert.ok(emailSkill);
  assert.match(emailSkill.description, /Gmail MCP/);
});

test('inventorySkills captures path and type', async () => {
  const results = await inventorySkills({ home: FIXTURE_HOME });
  const emailSkill = results.find(r => r.name === 'summarize-emails');
  assert.equal(emailSkill.type, 'skill');
  assert.ok(emailSkill.path.endsWith('SKILL.md'));
});
```

- [ ] **Step 3: Run the test to confirm it fails**

```bash
npm test
```

Expected: FAIL — `inventorySkills is not a function` or module-not-found.

- [ ] **Step 4: Implement `inventorySkills`**

File: `wecoded-marketplace-publisher/scripts/inventory.js`

```javascript
import fs from 'node:fs/promises';
import path from 'node:path';

function parseFrontmatter(text) {
  const match = text.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return {};
  const body = match[1];
  const out = {};
  for (const line of body.split('\n')) {
    const m = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (m) out[m[1]] = m[2].trim();
  }
  return out;
}

async function readSkillMd(filePath) {
  const text = await fs.readFile(filePath, 'utf8');
  const fm = parseFrontmatter(text);
  return {
    path: filePath,
    type: 'skill',
    name: fm.name || path.basename(path.dirname(filePath)),
    description: fm.description || '',
    content: text,
  };
}

async function walkForSkillMd(root, maxDepth = 6) {
  const out = [];
  async function walk(dir, depth) {
    if (depth > maxDepth) return;
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full, depth + 1);
      } else if (entry.isFile() && entry.name === 'SKILL.md') {
        out.push(full);
      }
    }
  }
  await walk(root, 0);
  return out;
}

export async function inventorySkills({ home }) {
  const roots = [
    path.join(home, '.claude', 'skills'),
    path.join(home, '.claude', 'plugins'),
  ];
  const found = [];
  for (const root of roots) {
    const skillFiles = await walkForSkillMd(root);
    for (const file of skillFiles) {
      found.push(await readSkillMd(file));
    }
  }
  return found;
}
```

- [ ] **Step 5: Run the test to confirm it passes**

```bash
npm test
```

Expected: `tests 3` / `pass 3`.

- [ ] **Step 6: Commit**

```bash
git add scripts/inventory.js tests/inventory.test.js tests/fixtures/
git commit -m "feat(publisher): inventory user + plugin-hosted SKILL.md files"
```

---

### Task 3: Inventory — hooks, MCP, commands, agents scanners

**Files:**
- Modify: `wecoded-marketplace-publisher/scripts/inventory.js`
- Modify: `wecoded-marketplace-publisher/tests/inventory.test.js`
- Create: `wecoded-marketplace-publisher/tests/fixtures/home-with-all-types/...` (full tree below)

- [ ] **Step 1: Create the "all types" fixture tree**

```bash
mkdir -p tests/fixtures/home-with-all-types/.claude
```

File: `tests/fixtures/home-with-all-types/.claude/settings.json`

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "~/scripts/on-start.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "~/scripts/guard.sh" }] }
    ]
  }
}
```

File: `tests/fixtures/home-with-all-types/.claude.json`

```json
{
  "mcpServers": {
    "gmail": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/gmail-mcp"],
      "env": { "GMAIL_TOKEN": "ghp_EXAMPLEONLYdoNOTuse123456789" }
    }
  }
}
```

File: `tests/fixtures/home-with-all-types/.claude/commands/my-report.md`

```markdown
---
description: Run my weekly report.
---
Assemble report X.
```

File: `tests/fixtures/home-with-all-types/.claude/agents/weekly-reviewer.md`

```markdown
---
name: weekly-reviewer
description: Reviews the week's journal entries.
---

You are a weekly reviewer agent.
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/inventory.test.js`:

```javascript
import { inventoryHooks, inventoryMcpServers, inventoryCommands, inventoryAgents } from '../scripts/inventory.js';

const ALL_TYPES_HOME = path.join(__dirname, 'fixtures/home-with-all-types');

test('inventoryHooks parses settings.json hooks block', async () => {
  const hooks = await inventoryHooks({ home: ALL_TYPES_HOME });
  assert.equal(hooks.length, 2);
  const events = hooks.map(h => h.event).sort();
  assert.deepEqual(events, ['PreToolUse', 'SessionStart']);
  const start = hooks.find(h => h.event === 'SessionStart');
  assert.equal(start.command, '~/scripts/on-start.sh');
});

test('inventoryMcpServers reads ~/.claude.json', async () => {
  const mcps = await inventoryMcpServers({ home: ALL_TYPES_HOME, cwd: ALL_TYPES_HOME });
  assert.equal(mcps.length, 1);
  assert.equal(mcps[0].name, 'gmail');
  assert.equal(mcps[0].type, 'mcp');
  assert.equal(mcps[0].config.command, 'npx');
});

test('inventoryCommands finds user-level slash commands', async () => {
  const cmds = await inventoryCommands({ home: ALL_TYPES_HOME, cwd: ALL_TYPES_HOME });
  assert.equal(cmds.length, 1);
  assert.equal(cmds[0].name, 'my-report');
  assert.equal(cmds[0].type, 'command');
});

test('inventoryAgents finds user-level agent files', async () => {
  const agents = await inventoryAgents({ home: ALL_TYPES_HOME, cwd: ALL_TYPES_HOME });
  assert.equal(agents.length, 1);
  assert.equal(agents[0].name, 'weekly-reviewer');
  assert.equal(agents[0].type, 'agent');
});
```

- [ ] **Step 3: Run tests to confirm failures**

```bash
npm test
```

Expected: 4 new failing tests (undefined exports).

- [ ] **Step 4: Implement the four scanners**

Append to `scripts/inventory.js`:

```javascript
export async function inventoryHooks({ home }) {
  const settingsPath = path.join(home, '.claude', 'settings.json');
  let settings;
  try {
    settings = JSON.parse(await fs.readFile(settingsPath, 'utf8'));
  } catch {
    return [];
  }
  const hooks = settings.hooks || {};
  const out = [];
  for (const [event, matchers] of Object.entries(hooks)) {
    for (const matcher of matchers) {
      for (const h of matcher.hooks || []) {
        if (h.type === 'command' && h.command) {
          out.push({
            type: 'hook',
            event,
            matcher: matcher.matcher || null,
            command: h.command,
            path: h.command,
          });
        }
      }
    }
  }
  return out;
}

async function readJsonOrNull(p) {
  try {
    return JSON.parse(await fs.readFile(p, 'utf8'));
  } catch {
    return null;
  }
}

export async function inventoryMcpServers({ home, cwd }) {
  const sources = [
    path.join(home, '.claude.json'),
    path.join(cwd, '.mcp.json'),
  ];
  const seen = new Map();
  for (const src of sources) {
    const data = await readJsonOrNull(src);
    if (!data) continue;
    const servers = data.mcpServers || {};
    for (const [name, config] of Object.entries(servers)) {
      if (!seen.has(name)) {
        seen.set(name, { type: 'mcp', name, config, path: src });
      }
    }
  }
  return [...seen.values()];
}

async function readMarkdownWithFrontmatter(filePath) {
  const text = await fs.readFile(filePath, 'utf8');
  const fm = parseFrontmatter(text);
  return { path: filePath, name: fm.name || path.basename(filePath, '.md'), description: fm.description || '', content: text };
}

async function listMarkdownFiles(dir) {
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    return entries.filter(e => e.isFile() && e.name.endsWith('.md')).map(e => path.join(dir, e.name));
  } catch {
    return [];
  }
}

export async function inventoryCommands({ home, cwd }) {
  const dirs = [
    path.join(home, '.claude', 'commands'),
    path.join(cwd, '.claude', 'commands'),
  ];
  const out = [];
  for (const dir of dirs) {
    for (const file of await listMarkdownFiles(dir)) {
      const base = await readMarkdownWithFrontmatter(file);
      out.push({ ...base, type: 'command' });
    }
  }
  return out;
}

export async function inventoryAgents({ home, cwd }) {
  const dirs = [
    path.join(home, '.claude', 'agents'),
    path.join(cwd, '.claude', 'agents'),
  ];
  const out = [];
  for (const dir of dirs) {
    for (const file of await listMarkdownFiles(dir)) {
      const base = await readMarkdownWithFrontmatter(file);
      out.push({ ...base, type: 'agent' });
    }
  }
  return out;
}
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
npm test
```

Expected: `tests 7` / `pass 7`.

- [ ] **Step 6: Commit**

```bash
git add scripts/inventory.js tests/inventory.test.js tests/fixtures/home-with-all-types/
git commit -m "feat(publisher): inventory hooks, MCPs, commands, agents"
```

---

### Task 4: Inventory — cross-references, scoring, CLI integration

**Files:**
- Modify: `wecoded-marketplace-publisher/scripts/inventory.js`
- Modify: `wecoded-marketplace-publisher/tests/inventory.test.js`

**Responsibility:** detect `mcp__{server}__{tool}` references inside skill/agent/command content, score candidates by token overlap with user keywords, expose a CLI entry that accepts JSON on argv and writes JSON to stdout.

- [ ] **Step 1: Write the failing tests**

Append to `tests/inventory.test.js`:

```javascript
import { detectReferences, scoreCandidate, runInventoryCli } from '../scripts/inventory.js';

test('detectReferences captures mcp__ tool names', () => {
  const refs = detectReferences('This uses mcp__gmail__list and mcp__github__search_issues.');
  const targets = refs.map(r => r.target).sort();
  assert.deepEqual(targets, ['mcp__github__search_issues', 'mcp__gmail__list']);
});

test('detectReferences resolves to MCP server name', () => {
  const refs = detectReferences('mcp__gmail__send');
  assert.equal(refs[0].resolvedTo, 'gmail');
});

test('scoreCandidate weighs keyword overlap', () => {
  const high = scoreCandidate(
    { name: 'summarize-emails', description: 'summarize user emails' },
    ['email', 'summary']
  );
  const low = scoreCandidate(
    { name: 'random-thing', description: 'unrelated' },
    ['email', 'summary']
  );
  assert.ok(high > low);
});

test('runInventoryCli produces full JSON report', async () => {
  const out = await runInventoryCli({
    signals: { hasSkill: true, hasMCP: true, hasHook: true, hasCommand: true, hasAgent: true },
    userDescription: 'summarize my emails with gmail',
    userKeywords: ['email', 'gmail', 'summary'],
    home: ALL_TYPES_HOME,
    cwd: ALL_TYPES_HOME,
  });
  assert.ok(Array.isArray(out.candidates));
  assert.ok(out.candidates.length >= 4);
  assert.ok(out.candidates[0].score >= out.candidates[out.candidates.length - 1].score);
});
```

- [ ] **Step 2: Run tests to confirm failures**

```bash
npm test
```

Expected: 4 new failing tests.

- [ ] **Step 3: Implement the three exports**

Append to `scripts/inventory.js`:

```javascript
export function detectReferences(text) {
  if (!text) return [];
  const out = [];
  const mcpPattern = /mcp__([a-zA-Z0-9_-]+)__([a-zA-Z0-9_-]+)/g;
  let m;
  while ((m = mcpPattern.exec(text)) !== null) {
    out.push({
      target: m[0],
      kind: 'mcp-tool',
      resolvedTo: m[1],
    });
  }
  return out;
}

function tokenize(str) {
  return (str || '')
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, ' ')
    .split(/\s+/)
    .filter(Boolean);
}

export function scoreCandidate(candidate, keywords) {
  const haystack = tokenize(`${candidate.name} ${candidate.description} ${candidate.content || ''}`);
  const haySet = new Set(haystack);
  const kw = keywords.map(k => k.toLowerCase());
  let score = 0;
  for (const k of kw) {
    if (haySet.has(k)) score += 10;
    else if (haystack.some(h => h.includes(k))) score += 3;
  }
  return score;
}

export async function runInventoryCli({ signals, userDescription, userKeywords, home, cwd }) {
  const candidates = [];
  if (signals.hasSkill) candidates.push(...(await inventorySkills({ home })));
  if (signals.hasHook) candidates.push(...(await inventoryHooks({ home })));
  if (signals.hasMCP) candidates.push(...(await inventoryMcpServers({ home, cwd })));
  if (signals.hasCommand) candidates.push(...(await inventoryCommands({ home, cwd })));
  if (signals.hasAgent) candidates.push(...(await inventoryAgents({ home, cwd })));

  const keywords = userKeywords && userKeywords.length ? userKeywords : tokenize(userDescription || '');

  const enriched = candidates.map(c => ({
    ...c,
    references: detectReferences(c.content || ''),
    score: scoreCandidate(c, keywords),
    matchReason: null,
  }));
  enriched.sort((a, b) => b.score - a.score);
  return { candidates: enriched };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const input = JSON.parse(process.argv[2] || '{}');
  runInventoryCli({ home: process.env.HOME || process.env.USERPROFILE, cwd: process.cwd(), ...input })
    .then(out => { process.stdout.write(JSON.stringify(out)); })
    .catch(err => { process.stderr.write(JSON.stringify({ error: err.message })); process.exit(1); });
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
npm test
```

Expected: `tests 11` / `pass 11`.

- [ ] **Step 5: Manual CLI smoke test**

```bash
node scripts/inventory.js '{"signals":{"hasSkill":true},"userDescription":"test","home":"./tests/fixtures/home-with-skills"}'
```

Expected: JSON on stdout with `candidates[]` containing `summarize-emails` and `cool-subskill`.

- [ ] **Step 6: Commit**

```bash
git add scripts/inventory.js tests/inventory.test.js
git commit -m "feat(publisher): inventory cross-ref detection, scoring, CLI"
```

---

### Task 5: Build-plugin — piece copying & plugin.json generation

**Files:**
- Create: `wecoded-marketplace-publisher/scripts/build-plugin.js`
- Create: `wecoded-marketplace-publisher/tests/build-plugin.test.js`
- Create: `wecoded-marketplace-publisher/tests/fixtures/source-skill/SKILL.md` (a source file to copy)

- [ ] **Step 1: Create source fixture**

File: `tests/fixtures/source-skill/SKILL.md`

```markdown
---
name: demo-skill
description: Demo skill for build tests.
---

Body content.
```

- [ ] **Step 2: Write the failing tests**

File: `tests/build-plugin.test.js`

```javascript
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { buildPlugin } from '../scripts/build-plugin.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.join(__dirname, 'fixtures/source-skill/SKILL.md');

let tmp;
beforeEach(async () => {
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'wmp-build-'));
});

test('buildPlugin creates working dir and copies skill piece', async () => {
  const manifest = {
    pluginId: 'my-plugin',
    metadata: {
      displayName: 'My Plugin',
      description: 'Test',
      author: { name: 'tester' },
      category: 'personal',
      tags: ['test'],
    },
    pieces: [
      { type: 'skill', sourcePath: SRC, targetPath: 'skills/demo-skill/SKILL.md', meta: { name: 'demo-skill' } },
    ],
  };
  const result = await buildPlugin({ manifest, workingRoot: tmp });
  assert.equal(result.status, 'ok');

  const copied = await fs.readFile(path.join(tmp, 'my-plugin', 'skills/demo-skill/SKILL.md'), 'utf8');
  assert.match(copied, /demo-skill/);
});

test('buildPlugin generates plugin.json from metadata', async () => {
  const manifest = {
    pluginId: 'my-plugin',
    metadata: {
      displayName: 'My Plugin',
      description: 'Test description',
      author: { name: 'tester' },
      category: 'personal',
      tags: ['one', 'two'],
    },
    pieces: [],
  };
  await buildPlugin({ manifest, workingRoot: tmp });
  const pkg = JSON.parse(await fs.readFile(path.join(tmp, 'my-plugin', 'plugin.json'), 'utf8'));
  assert.equal(pkg.name, 'my-plugin');
  assert.equal(pkg.version, '0.1.0');
  assert.equal(pkg.description, 'Test description');
  assert.deepEqual(pkg.keywords, ['one', 'two']);
});
```

- [ ] **Step 3: Run tests to confirm failures**

```bash
npm test
```

Expected: 2 new failing tests.

- [ ] **Step 4: Implement `buildPlugin` (copying + plugin.json)**

File: `wecoded-marketplace-publisher/scripts/build-plugin.js`

```javascript
import fs from 'node:fs/promises';
import path from 'node:path';

async function ensureDir(dir) {
  await fs.mkdir(dir, { recursive: true });
}

async function copyFile(src, dest) {
  await ensureDir(path.dirname(dest));
  await fs.copyFile(src, dest);
}

function generatePluginJson(pluginId, metadata) {
  return {
    name: pluginId,
    version: '0.1.0',
    description: metadata.description || '',
    author: metadata.author || { name: 'unknown' },
    homepage: metadata.homepage || null,
    keywords: metadata.tags || [],
  };
}

export async function buildPlugin({ manifest, workingRoot }) {
  const { pluginId, metadata, pieces } = manifest;
  const outDir = path.join(workingRoot, pluginId);
  await ensureDir(outDir);

  for (const piece of pieces) {
    if (piece.sourcePath && piece.targetPath && piece.type !== 'mcp' && piece.type !== 'hook') {
      await copyFile(piece.sourcePath, path.join(outDir, piece.targetPath));
    }
  }

  const pluginJson = generatePluginJson(pluginId, metadata);
  await fs.writeFile(path.join(outDir, 'plugin.json'), JSON.stringify(pluginJson, null, 2));

  return { status: 'ok', outDir };
}
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
npm test
```

Expected: `tests 13` / `pass 13`.

- [ ] **Step 6: Commit**

```bash
git add scripts/build-plugin.js tests/build-plugin.test.js tests/fixtures/source-skill/
git commit -m "feat(publisher): build-plugin copies pieces and generates plugin.json"
```

---

### Task 6: Build-plugin — hooks manifest, MCP stub, README templating

**Files:**
- Modify: `wecoded-marketplace-publisher/scripts/build-plugin.js`
- Modify: `wecoded-marketplace-publisher/tests/build-plugin.test.js`

- [ ] **Step 1: Write the failing tests**

Append to `tests/build-plugin.test.js`:

```javascript
test('buildPlugin generates hooks-manifest.json from hook pieces', async () => {
  const manifest = {
    pluginId: 'hooky',
    metadata: { displayName: 'Hooky', description: 'd', author: { name: 'x' }, category: 'personal' },
    pieces: [
      { type: 'hook', event: 'SessionStart', matcher: null, command: '~/scripts/on-start.sh', sourcePath: null },
    ],
  };
  await buildPlugin({ manifest, workingRoot: tmp });
  const hm = JSON.parse(await fs.readFile(path.join(tmp, 'hooky/hooks/hooks-manifest.json'), 'utf8'));
  assert.ok(hm.hooks.SessionStart);
  assert.equal(hm.hooks.SessionStart[0].hooks[0].command, '~/scripts/on-start.sh');
});

test('buildPlugin generates .mcp.json stub for declared MCP deps', async () => {
  const manifest = {
    pluginId: 'mcpy',
    metadata: { displayName: 'Mcpy', description: 'd', author: { name: 'x' }, category: 'personal' },
    pieces: [
      { type: 'mcp', name: 'gmail', config: { command: 'npx', args: ['-y', '@mcp/gmail'] } },
    ],
  };
  await buildPlugin({ manifest, workingRoot: tmp });
  const mcp = JSON.parse(await fs.readFile(path.join(tmp, 'mcpy/.mcp.json'), 'utf8'));
  assert.ok(mcp.mcpServers.gmail);
  assert.equal(mcp.mcpServers.gmail.command, 'npx');
});

test('buildPlugin templates a README when none is provided', async () => {
  const manifest = {
    pluginId: 'readmeless',
    metadata: { displayName: 'Readme-less', description: 'A test plugin.', author: { name: 'x' }, category: 'personal' },
    pieces: [],
  };
  await buildPlugin({ manifest, workingRoot: tmp });
  const readme = await fs.readFile(path.join(tmp, 'readmeless/README.md'), 'utf8');
  assert.match(readme, /Readme-less/);
  assert.match(readme, /A test plugin/);
});
```

- [ ] **Step 2: Run tests to confirm failures**

```bash
npm test
```

Expected: 3 new failing tests.

- [ ] **Step 3: Extend `buildPlugin`**

Insert into `scripts/build-plugin.js` (above the existing `buildPlugin` export; then update `buildPlugin` to call these):

```javascript
async function writeHooksManifest(outDir, hookPieces) {
  if (hookPieces.length === 0) return;
  const manifest = { hooks: {} };
  for (const h of hookPieces) {
    manifest.hooks[h.event] ||= [];
    manifest.hooks[h.event].push({
      matcher: h.matcher || undefined,
      hooks: [{ type: 'command', command: h.command }],
    });
  }
  const p = path.join(outDir, 'hooks', 'hooks-manifest.json');
  await ensureDir(path.dirname(p));
  await fs.writeFile(p, JSON.stringify(manifest, null, 2));
}

async function writeMcpStub(outDir, mcpPieces) {
  if (mcpPieces.length === 0) return;
  const stub = { mcpServers: {} };
  for (const m of mcpPieces) {
    stub.mcpServers[m.name] = m.config;
  }
  await fs.writeFile(path.join(outDir, '.mcp.json'), JSON.stringify(stub, null, 2));
}

async function writeReadmeIfMissing(outDir, metadata) {
  const p = path.join(outDir, 'README.md');
  try {
    await fs.access(p);
    return;
  } catch {}
  const body = `# ${metadata.displayName}\n\n${metadata.description}\n\n## Installation\n\nInstall via the WeCoded marketplace or directly from this repo.\n`;
  await fs.writeFile(p, body);
}
```

Replace `buildPlugin`'s body so it calls all three:

```javascript
export async function buildPlugin({ manifest, workingRoot }) {
  const { pluginId, metadata, pieces } = manifest;
  const outDir = path.join(workingRoot, pluginId);
  await ensureDir(outDir);

  const hookPieces = [];
  const mcpPieces = [];
  for (const piece of pieces) {
    if (piece.type === 'hook') {
      hookPieces.push(piece);
      continue;
    }
    if (piece.type === 'mcp') {
      mcpPieces.push(piece);
      continue;
    }
    if (piece.sourcePath && piece.targetPath) {
      await copyFile(piece.sourcePath, path.join(outDir, piece.targetPath));
    }
  }

  const pluginJson = generatePluginJson(pluginId, metadata);
  await fs.writeFile(path.join(outDir, 'plugin.json'), JSON.stringify(pluginJson, null, 2));
  await writeHooksManifest(outDir, hookPieces);
  await writeMcpStub(outDir, mcpPieces);
  await writeReadmeIfMissing(outDir, metadata);

  return { status: 'ok', outDir };
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
npm test
```

Expected: `tests 16` / `pass 16`.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-plugin.js tests/build-plugin.test.js
git commit -m "feat(publisher): build hooks-manifest, MCP stub, README template"
```

---

### Task 7: Build-plugin — secret detection

**Files:**
- Create: `wecoded-marketplace-publisher/scripts/lib/secret-patterns.js`
- Modify: `wecoded-marketplace-publisher/scripts/build-plugin.js`
- Modify: `wecoded-marketplace-publisher/tests/build-plugin.test.js`
- Create: `wecoded-marketplace-publisher/tests/fixtures/plugin-with-secrets/*` (source file with embedded token)

- [ ] **Step 1: Create fixture with a secret**

File: `tests/fixtures/plugin-with-secrets/scripts/fetch.js`

```javascript
const apiKey = 'sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz1234567890ABCDEFGHIJKLMN';
const ghToken = 'ghp_ExampleGitHubPersonalAccessToken123456789012345';
export { apiKey, ghToken };
```

- [ ] **Step 2: Write the failing tests**

Append to `tests/build-plugin.test.js`:

```javascript
import { scanForSecrets } from '../scripts/build-plugin.js';

test('scanForSecrets finds Anthropic keys', async () => {
  const p = path.join(__dirname, 'fixtures/plugin-with-secrets/scripts/fetch.js');
  const text = await fs.readFile(p, 'utf8');
  const findings = scanForSecrets(text, p);
  const patterns = findings.map(f => f.patternName).sort();
  assert.ok(patterns.includes('anthropic-api-key'));
  assert.ok(patterns.includes('github-token'));
});

test('scanForSecrets returns file + line for each finding', async () => {
  const p = path.join(__dirname, 'fixtures/plugin-with-secrets/scripts/fetch.js');
  const text = await fs.readFile(p, 'utf8');
  const findings = scanForSecrets(text, p);
  for (const f of findings) {
    assert.equal(f.file, p);
    assert.ok(f.line > 0);
    assert.ok(f.excerpt.length > 0);
  }
});
```

- [ ] **Step 3: Run tests to confirm failures**

```bash
npm test
```

Expected: 2 new failing tests.

- [ ] **Step 4: Implement secret patterns**

File: `wecoded-marketplace-publisher/scripts/lib/secret-patterns.js`

```javascript
export const SECRET_PATTERNS = [
  { name: 'github-token', regex: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}\b/g, envHint: 'GITHUB_TOKEN' },
  { name: 'aws-access-key', regex: /\bAKIA[0-9A-Z]{16}\b/g, envHint: 'AWS_ACCESS_KEY_ID' },
  { name: 'openai-api-key', regex: /\bsk-(?!ant-)[A-Za-z0-9_-]{20,}\b/g, envHint: 'OPENAI_API_KEY' },
  { name: 'anthropic-api-key', regex: /\bsk-ant-[A-Za-z0-9_-]{20,}\b/g, envHint: 'ANTHROPIC_API_KEY' },
];
```

- [ ] **Step 5: Implement `scanForSecrets` in build-plugin.js**

Add import and function at top of `scripts/build-plugin.js`:

```javascript
import { SECRET_PATTERNS } from './lib/secret-patterns.js';

export function scanForSecrets(text, filePath) {
  const findings = [];
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    for (const pat of SECRET_PATTERNS) {
      pat.regex.lastIndex = 0;
      let m;
      while ((m = pat.regex.exec(lines[i])) !== null) {
        findings.push({
          file: filePath,
          line: i + 1,
          patternName: pat.name,
          envHint: pat.envHint,
          excerpt: m[0].slice(0, 6) + '...',
          matched: m[0],
        });
      }
    }
  }
  return findings;
}
```

- [ ] **Step 6: Run tests to confirm they pass**

```bash
npm test
```

Expected: `tests 18` / `pass 18`.

- [ ] **Step 7: Commit**

```bash
git add scripts/build-plugin.js scripts/lib/secret-patterns.js tests/build-plugin.test.js tests/fixtures/plugin-with-secrets/
git commit -m "feat(publisher): scan plugin files for secret patterns"
```

---

### Task 8: Build-plugin — secret sanitization & SETUP.md generation

**Files:**
- Modify: `wecoded-marketplace-publisher/scripts/build-plugin.js`
- Modify: `wecoded-marketplace-publisher/tests/build-plugin.test.js`

**Responsibility:** when `buildPlugin` is called with `sanitize: true` (or a similar flag) and secrets are found, rewrite the copied files so secret literals become `process.env.{ENV_HINT}` reads, then generate `SETUP.md` listing each required env var with its source. JS files get actual `process.env.X` substitution; markdown files get `<YOUR_X_HERE>` placeholder text.

- [ ] **Step 1: Write the failing tests**

Append to `tests/build-plugin.test.js`:

```javascript
test('buildPlugin with sanitize replaces JS secrets with env reads', async () => {
  const srcDir = path.join(__dirname, 'fixtures/plugin-with-secrets');
  const manifest = {
    pluginId: 'sanity',
    metadata: { displayName: 'Sanity', description: 'd', author: { name: 'x' }, category: 'personal' },
    pieces: [
      { type: 'skill', sourcePath: path.join(srcDir, 'scripts/fetch.js'), targetPath: 'scripts/fetch.js' },
    ],
  };
  const result = await buildPlugin({ manifest, workingRoot: tmp, sanitize: true });
  assert.equal(result.status, 'ok');
  assert.ok(result.sanitizedFindings.length >= 2);

  const copied = await fs.readFile(path.join(tmp, 'sanity/scripts/fetch.js'), 'utf8');
  assert.doesNotMatch(copied, /sk-ant-api03/);
  assert.doesNotMatch(copied, /ghp_Example/);
  assert.match(copied, /process\.env\.ANTHROPIC_API_KEY/);
  assert.match(copied, /process\.env\.GITHUB_TOKEN/);
});

test('buildPlugin with sanitize generates SETUP.md listing env vars', async () => {
  const srcDir = path.join(__dirname, 'fixtures/plugin-with-secrets');
  const manifest = {
    pluginId: 'setup-md',
    metadata: { displayName: 'Setup MD', description: 'd', author: { name: 'x' }, category: 'personal' },
    pieces: [
      { type: 'skill', sourcePath: path.join(srcDir, 'scripts/fetch.js'), targetPath: 'scripts/fetch.js' },
    ],
  };
  await buildPlugin({ manifest, workingRoot: tmp, sanitize: true });
  const setup = await fs.readFile(path.join(tmp, 'setup-md/SETUP.md'), 'utf8');
  assert.match(setup, /ANTHROPIC_API_KEY/);
  assert.match(setup, /GITHUB_TOKEN/);
});

test('buildPlugin without sanitize returns findings but leaves content intact', async () => {
  const srcDir = path.join(__dirname, 'fixtures/plugin-with-secrets');
  const manifest = {
    pluginId: 'raw',
    metadata: { displayName: 'Raw', description: 'd', author: { name: 'x' }, category: 'personal' },
    pieces: [
      { type: 'skill', sourcePath: path.join(srcDir, 'scripts/fetch.js'), targetPath: 'scripts/fetch.js' },
    ],
  };
  const result = await buildPlugin({ manifest, workingRoot: tmp, sanitize: false });
  assert.ok(result.unsanitizedFindings.length >= 2);
  const copied = await fs.readFile(path.join(tmp, 'raw/scripts/fetch.js'), 'utf8');
  assert.match(copied, /sk-ant-api03/);
});
```

- [ ] **Step 2: Run tests to confirm failures**

```bash
npm test
```

Expected: 3 new failing tests.

- [ ] **Step 3: Implement sanitization**

Add to `scripts/build-plugin.js`:

```javascript
function isMarkdownLike(filePath) {
  return /\.(md|markdown|txt)$/i.test(filePath);
}

function sanitizeText(text, filePath) {
  const findings = [];
  let out = text;
  for (const pat of SECRET_PATTERNS) {
    pat.regex.lastIndex = 0;
    out = out.replace(pat.regex, (match) => {
      findings.push({ patternName: pat.name, envHint: pat.envHint, excerpt: match.slice(0, 6) + '...' });
      return isMarkdownLike(filePath) ? `<YOUR_${pat.envHint}_HERE>` : `process.env.${pat.envHint}`;
    });
  }
  return { text: out, findings };
}

async function generateSetupMd(outDir, envVars) {
  if (envVars.length === 0) return;
  const lines = ['# Setup', '', 'This plugin needs the following environment variables to work:', ''];
  for (const v of envVars) {
    lines.push(`## \`${v}\``);
    lines.push('');
    lines.push(descriptionForEnv(v));
    lines.push('');
    lines.push(`Set it by running: \`export ${v}=your-value-here\` (on macOS/Linux) or \`setx ${v} your-value-here\` (on Windows).`);
    lines.push('');
  }
  lines.push('If a required value is not set, the plugin will exit with an error telling you which variable is missing.');
  await fs.writeFile(path.join(outDir, 'SETUP.md'), lines.join('\n'));
}

function descriptionForEnv(name) {
  const table = {
    GITHUB_TOKEN: 'A GitHub personal access token. Create one at https://github.com/settings/tokens with the scopes this plugin needs.',
    AWS_ACCESS_KEY_ID: 'An AWS access key ID for the account this plugin operates on.',
    OPENAI_API_KEY: 'An OpenAI API key from https://platform.openai.com/api-keys.',
    ANTHROPIC_API_KEY: 'An Anthropic API key from https://console.anthropic.com/settings/keys.',
  };
  return table[name] || `A value for ${name}. See the plugin author's documentation for details.`;
}
```

Update the copy loop in `buildPlugin` to do sanitization when `sanitize === true`:

```javascript
export async function buildPlugin({ manifest, workingRoot, sanitize = false }) {
  const { pluginId, metadata, pieces } = manifest;
  const outDir = path.join(workingRoot, pluginId);
  await ensureDir(outDir);

  const hookPieces = [];
  const mcpPieces = [];
  const allFindings = [];
  const unsanitizedFindings = [];

  for (const piece of pieces) {
    if (piece.type === 'hook') { hookPieces.push(piece); continue; }
    if (piece.type === 'mcp') { mcpPieces.push(piece); continue; }
    if (!piece.sourcePath || !piece.targetPath) continue;

    const destPath = path.join(outDir, piece.targetPath);
    await ensureDir(path.dirname(destPath));
    const text = await fs.readFile(piece.sourcePath, 'utf8');

    if (sanitize) {
      const { text: cleaned, findings } = sanitizeText(text, piece.sourcePath);
      for (const f of findings) allFindings.push({ ...f, file: piece.targetPath });
      await fs.writeFile(destPath, cleaned);
    } else {
      const scan = scanForSecrets(text, piece.sourcePath);
      for (const f of scan) unsanitizedFindings.push({ ...f, file: piece.targetPath });
      await fs.writeFile(destPath, text);
    }
  }

  const pluginJson = generatePluginJson(pluginId, metadata);
  await fs.writeFile(path.join(outDir, 'plugin.json'), JSON.stringify(pluginJson, null, 2));
  await writeHooksManifest(outDir, hookPieces);
  await writeMcpStub(outDir, mcpPieces);
  await writeReadmeIfMissing(outDir, metadata);

  const envVars = [...new Set(allFindings.map(f => f.envHint))];
  await generateSetupMd(outDir, envVars);

  return { status: 'ok', outDir, sanitizedFindings: allFindings, unsanitizedFindings };
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
npm test
```

Expected: `tests 21` / `pass 21`.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-plugin.js tests/build-plugin.test.js
git commit -m "feat(publisher): sanitize secrets into process.env reads + SETUP.md"
```

---

### Task 9: Preflight — local checks (size, fields, hygiene, cross-refs)

**Files:**
- Create: `wecoded-marketplace-publisher/scripts/preflight.js`
- Create: `wecoded-marketplace-publisher/tests/preflight.test.js`
- Create: `wecoded-marketplace-publisher/tests/fixtures/valid-plugin-tree/` (a passing plugin tree)

- [ ] **Step 1: Create valid fixture**

```bash
mkdir -p tests/fixtures/valid-plugin-tree/skills/demo
```

File: `tests/fixtures/valid-plugin-tree/plugin.json`

```json
{
  "name": "valid-plugin",
  "version": "0.1.0",
  "description": "A valid test plugin.",
  "author": { "name": "tester" },
  "keywords": ["test"]
}
```

File: `tests/fixtures/valid-plugin-tree/skills/demo/SKILL.md`

```markdown
---
name: demo
description: Demo.
---
Body.
```

- [ ] **Step 2: Write the failing tests**

File: `tests/preflight.test.js`

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { preflightLocal } from '../scripts/preflight.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const VALID = path.join(__dirname, 'fixtures/valid-plugin-tree');
const SECRETS = path.join(__dirname, 'fixtures/plugin-with-secrets');

test('preflightLocal passes on a valid plugin tree', async () => {
  const result = await preflightLocal({ pluginDir: VALID, metadata: {
    displayName: 'Valid', description: 'd', author: { name: 't' }, category: 'personal', tags: ['x'],
  }});
  const fails = result.checks.filter(c => c.status === 'fail');
  assert.equal(fails.length, 0);
  assert.equal(result.pass, true);
});

test('preflightLocal fails when required metadata is missing', async () => {
  const result = await preflightLocal({ pluginDir: VALID, metadata: {
    displayName: '', description: '', author: {}, category: '', tags: [],
  }});
  assert.equal(result.pass, false);
  const names = result.checks.filter(c => c.status === 'fail').map(c => c.name);
  assert.ok(names.includes('required-fields'));
});

test('preflightLocal fails when secrets remain in source', async () => {
  const result = await preflightLocal({ pluginDir: SECRETS, metadata: {
    displayName: 'X', description: 'd', author: { name: 't' }, category: 'personal', tags: ['x'],
  }});
  assert.equal(result.pass, false);
  assert.ok(result.checks.find(c => c.name === 'secret-scan' && c.status === 'fail'));
});
```

- [ ] **Step 3: Run tests to confirm failures**

```bash
npm test
```

Expected: 3 new failing tests.

- [ ] **Step 4: Implement `preflightLocal`**

File: `wecoded-marketplace-publisher/scripts/preflight.js`

```javascript
import fs from 'node:fs/promises';
import path from 'node:path';
import { SECRET_PATTERNS } from './lib/secret-patterns.js';

const MAX_BYTES = 50 * 1024 * 1024;
const FORBIDDEN = ['.env', 'node_modules', '.git'];

async function dirSize(dir) {
  let total = 0;
  const entries = await fs.readdir(dir, { withFileTypes: true });
  for (const e of entries) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) total += await dirSize(p);
    else if (e.isFile()) {
      const stat = await fs.stat(p);
      total += stat.size;
    }
  }
  return total;
}

async function walkFiles(dir) {
  const out = [];
  async function walk(d) {
    const entries = await fs.readdir(d, { withFileTypes: true });
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) await walk(p);
      else if (e.isFile()) out.push(p);
    }
  }
  await walk(dir);
  return out;
}

async function secretScanFiles(dir) {
  const findings = [];
  const files = await walkFiles(dir);
  for (const f of files) {
    if (!/\.(js|ts|md|json|txt|sh|py)$/i.test(f)) continue;
    const text = await fs.readFile(f, 'utf8');
    for (const pat of SECRET_PATTERNS) {
      pat.regex.lastIndex = 0;
      if (pat.regex.test(text)) {
        findings.push({ file: path.relative(dir, f), pattern: pat.name });
      }
    }
  }
  return findings;
}

export async function preflightLocal({ pluginDir, metadata }) {
  const checks = [];

  const size = await dirSize(pluginDir);
  checks.push({
    name: 'size',
    status: size < MAX_BYTES ? 'pass' : 'fail',
    detail: `Plugin size: ${(size / 1024 / 1024).toFixed(2)} MB (limit 50 MB)`,
  });

  const requiredPresent = !!metadata.displayName && !!metadata.description && !!metadata.author?.name && !!metadata.category;
  checks.push({
    name: 'required-fields',
    status: requiredPresent ? 'pass' : 'fail',
    detail: requiredPresent ? 'All required fields present' : 'Missing one of: displayName, description, author.name, category',
  });

  const files = await walkFiles(pluginDir);
  const bad = files.filter(f => FORBIDDEN.some(x => f.includes(path.sep + x + path.sep) || f.endsWith(path.sep + x)));
  checks.push({
    name: 'hygiene',
    status: bad.length === 0 ? 'pass' : 'fail',
    detail: bad.length === 0 ? 'No forbidden files present' : `Forbidden files found: ${bad.map(b => path.relative(pluginDir, b)).join(', ')}`,
  });

  const secretFindings = await secretScanFiles(pluginDir);
  checks.push({
    name: 'secret-scan',
    status: secretFindings.length === 0 ? 'pass' : 'fail',
    detail: secretFindings.length === 0 ? 'No secrets detected' : `Detected: ${secretFindings.map(f => `${f.file} (${f.pattern})`).join('; ')}`,
  });

  const pass = checks.every(c => c.status !== 'fail');
  return { pass, checks };
}
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
npm test
```

Expected: `tests 24` / `pass 24`.

- [ ] **Step 6: Commit**

```bash
git add scripts/preflight.js tests/preflight.test.js tests/fixtures/valid-plugin-tree/
git commit -m "feat(publisher): preflight checks for size, fields, hygiene, secrets"
```

---

### Task 10: Preflight — network-dependent checks (uniqueness & enum)

**Files:**
- Create: `wecoded-marketplace-publisher/scripts/lib/schema-fetch.js`
- Modify: `wecoded-marketplace-publisher/scripts/preflight.js`
- Modify: `wecoded-marketplace-publisher/tests/preflight.test.js`

**Responsibility:** fetch the live `marketplace.json` and `scripts/schema.js` from `raw.githubusercontent.com/itsdestin/wecoded-marketplace/master/...`, validate plugin ID uniqueness, validate enum fields. Tests inject a fake fetch (via a `fetchImpl` dependency-injected parameter).

- [ ] **Step 1: Write the failing tests**

Append to `tests/preflight.test.js`:

```javascript
import { preflightNetwork } from '../scripts/preflight.js';

function fakeFetch(responses) {
  return async (url) => {
    const key = Object.keys(responses).find(k => url.includes(k));
    if (!key) throw new Error(`Unexpected fetch: ${url}`);
    return { ok: true, text: async () => responses[key] };
  };
}

test('preflightNetwork passes with unique plugin ID and valid enums', async () => {
  const fetchImpl = fakeFetch({
    'marketplace.json': JSON.stringify({ plugins: [{ name: 'other-plugin' }] }),
    'schema.js': 'export const CATEGORIES = ["personal","productivity","development"]; export const LIFE_AREAS = ["personal","work"]; export const AUDIENCES = ["general","developer"];',
  });
  const result = await preflightNetwork({
    pluginId: 'new-plugin',
    metadata: { category: 'personal', lifeArea: ['personal'], audience: 'general', tags: [] },
    fetchImpl,
  });
  assert.equal(result.pass, true);
});

test('preflightNetwork fails on duplicate plugin ID', async () => {
  const fetchImpl = fakeFetch({
    'marketplace.json': JSON.stringify({ plugins: [{ name: 'existing' }] }),
    'schema.js': 'export const CATEGORIES = ["personal"]; export const LIFE_AREAS = []; export const AUDIENCES = [];',
  });
  const result = await preflightNetwork({
    pluginId: 'existing',
    metadata: { category: 'personal', lifeArea: [], audience: '', tags: [] },
    fetchImpl,
  });
  assert.equal(result.pass, false);
  assert.ok(result.checks.find(c => c.name === 'id-uniqueness' && c.status === 'fail'));
});

test('preflightNetwork fails on invalid category enum', async () => {
  const fetchImpl = fakeFetch({
    'marketplace.json': JSON.stringify({ plugins: [] }),
    'schema.js': 'export const CATEGORIES = ["personal"]; export const LIFE_AREAS = []; export const AUDIENCES = [];',
  });
  const result = await preflightNetwork({
    pluginId: 'x',
    metadata: { category: 'madeup', lifeArea: [], audience: '', tags: [] },
    fetchImpl,
  });
  assert.equal(result.pass, false);
  assert.ok(result.checks.find(c => c.name === 'category-enum' && c.status === 'fail'));
});
```

- [ ] **Step 2: Run tests to confirm failures**

```bash
npm test
```

Expected: 3 new failing tests.

- [ ] **Step 3: Implement `schema-fetch.js`**

File: `wecoded-marketplace-publisher/scripts/lib/schema-fetch.js`

```javascript
const MARKETPLACE_URL = 'https://raw.githubusercontent.com/itsdestin/wecoded-marketplace/master/marketplace.json';
const SCHEMA_URL = 'https://raw.githubusercontent.com/itsdestin/wecoded-marketplace/master/scripts/schema.js';

export async function fetchMarketplace(fetchImpl = fetch) {
  const res = await fetchImpl(MARKETPLACE_URL);
  if (!res.ok) throw new Error(`marketplace.json fetch failed: ${res.status}`);
  return JSON.parse(await res.text());
}

export async function fetchSchemaEnums(fetchImpl = fetch) {
  const res = await fetchImpl(SCHEMA_URL);
  if (!res.ok) throw new Error(`schema.js fetch failed: ${res.status}`);
  const src = await res.text();
  return parseSchemaModule(src);
}

function extractArray(src, name) {
  const re = new RegExp(`${name}\\s*=\\s*\\[([^\\]]*)\\]`);
  const m = src.match(re);
  if (!m) return [];
  return [...m[1].matchAll(/"([^"]+)"/g)].map(x => x[1]);
}

export function parseSchemaModule(src) {
  return {
    categories: extractArray(src, 'CATEGORIES'),
    lifeAreas: extractArray(src, 'LIFE_AREAS'),
    audiences: extractArray(src, 'AUDIENCES'),
  };
}
```

- [ ] **Step 4: Implement `preflightNetwork`**

Append to `scripts/preflight.js`:

```javascript
import { fetchMarketplace, fetchSchemaEnums } from './lib/schema-fetch.js';

export async function preflightNetwork({ pluginId, metadata, fetchImpl }) {
  const checks = [];

  const marketplace = await fetchMarketplace(fetchImpl);
  const existingIds = new Set((marketplace.plugins || []).map(p => p.name));
  const unique = !existingIds.has(pluginId);
  checks.push({
    name: 'id-uniqueness',
    status: unique ? 'pass' : 'fail',
    detail: unique ? 'Plugin ID is not taken' : `Plugin ID "${pluginId}" is already used in the marketplace`,
  });

  const schema = await fetchSchemaEnums(fetchImpl);

  const catOk = schema.categories.length === 0 || schema.categories.includes(metadata.category);
  checks.push({
    name: 'category-enum',
    status: catOk ? 'pass' : 'fail',
    detail: catOk ? 'Category accepted' : `Category "${metadata.category}" not in [${schema.categories.join(', ')}]`,
  });

  const audiences = schema.audiences;
  const audOk = audiences.length === 0 || audiences.includes(metadata.audience || '');
  checks.push({
    name: 'audience-enum',
    status: audOk ? 'pass' : 'fail',
    detail: audOk ? 'Audience accepted' : `Audience "${metadata.audience}" not in [${audiences.join(', ')}]`,
  });

  const pass = checks.every(c => c.status !== 'fail');
  return { pass, checks };
}
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
npm test
```

Expected: `tests 27` / `pass 27`.

- [ ] **Step 6: Commit**

```bash
git add scripts/preflight.js scripts/lib/schema-fetch.js tests/preflight.test.js
git commit -m "feat(publisher): preflight network checks (ID uniqueness + enums)"
```

---

### Task 11: Publish — gh preflight & ledger I/O

**Files:**
- Create: `wecoded-marketplace-publisher/scripts/lib/ledger.js`
- Create: `wecoded-marketplace-publisher/scripts/publish.js`
- Create: `wecoded-marketplace-publisher/tests/publish.test.js`

- [ ] **Step 1: Write the failing tests**

File: `tests/publish.test.js`

```javascript
import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { readLedger, writeLedgerEntry } from '../scripts/lib/ledger.js';
import { verifyGhAvailable } from '../scripts/publish.js';

let tmpConfigDir;
beforeEach(async () => {
  tmpConfigDir = await fs.mkdtemp(path.join(os.tmpdir(), 'wmp-ledger-'));
});

test('readLedger returns empty when file is missing', async () => {
  const l = await readLedger({ configDir: tmpConfigDir });
  assert.deepEqual(l, { version: 1, entries: [] });
});

test('writeLedgerEntry appends then updates in place', async () => {
  await writeLedgerEntry({ configDir: tmpConfigDir, entry: {
    pluginId: 'a', repoUrl: 'https://github.com/x/a', version: '0.1.0',
    publishedAt: '2026-04-20T00:00:00Z', state: 'repo-created',
  }});
  await writeLedgerEntry({ configDir: tmpConfigDir, entry: {
    pluginId: 'a', state: 'complete', communityPR: 'https://.../pull/1',
  }});
  const l = await readLedger({ configDir: tmpConfigDir });
  assert.equal(l.entries.length, 1);
  assert.equal(l.entries[0].state, 'complete');
  assert.equal(l.entries[0].communityPR, 'https://.../pull/1');
  assert.equal(l.entries[0].repoUrl, 'https://github.com/x/a');
});

test('verifyGhAvailable with fake spawn returns ok when gh exits 0', async () => {
  const fakeSpawn = (cmd, args) => ({
    exitCode: 0,
    stdout: args.includes('--version') ? 'gh version 2.40.0' : 'Logged in to github.com',
    stderr: '',
  });
  const result = await verifyGhAvailable({ spawn: fakeSpawn });
  assert.equal(result.ok, true);
});

test('verifyGhAvailable reports unauthed when gh auth status fails', async () => {
  const fakeSpawn = (cmd, args) => args.includes('status')
    ? { exitCode: 1, stdout: '', stderr: 'not logged in' }
    : { exitCode: 0, stdout: 'gh version 2.40.0', stderr: '' };
  const result = await verifyGhAvailable({ spawn: fakeSpawn });
  assert.equal(result.ok, false);
  assert.match(result.reason, /auth/i);
});
```

- [ ] **Step 2: Run tests to confirm failures**

```bash
npm test
```

Expected: 5 new failing tests.

- [ ] **Step 3: Implement `ledger.js`**

File: `wecoded-marketplace-publisher/scripts/lib/ledger.js`

```javascript
import fs from 'node:fs/promises';
import path from 'node:path';

function ledgerPath(configDir) {
  return path.join(configDir, 'published.json');
}

export async function readLedger({ configDir }) {
  const p = ledgerPath(configDir);
  try {
    return JSON.parse(await fs.readFile(p, 'utf8'));
  } catch {
    return { version: 1, entries: [] };
  }
}

export async function writeLedgerEntry({ configDir, entry }) {
  const ledger = await readLedger({ configDir });
  const existing = ledger.entries.find(e => e.pluginId === entry.pluginId);
  if (existing) {
    Object.assign(existing, entry);
  } else {
    ledger.entries.push(entry);
  }
  await fs.mkdir(configDir, { recursive: true });
  await fs.writeFile(ledgerPath(configDir), JSON.stringify(ledger, null, 2));
  return ledger;
}
```

- [ ] **Step 4: Implement `verifyGhAvailable` in publish.js**

File: `wecoded-marketplace-publisher/scripts/publish.js`

```javascript
import { spawn as nodeSpawn } from 'node:child_process';

async function runCmd(spawnImpl, cmd, args) {
  if (typeof spawnImpl === 'function' && spawnImpl.length <= 2) {
    const r = await spawnImpl(cmd, args);
    return r;
  }
  return new Promise((resolve) => {
    const child = nodeSpawn(cmd, args);
    let out = '', err = '';
    child.stdout.on('data', d => out += d.toString());
    child.stderr.on('data', d => err += d.toString());
    child.on('close', code => resolve({ exitCode: code, stdout: out, stderr: err }));
  });
}

export async function verifyGhAvailable({ spawn = runCmd.bind(null, nodeSpawn) } = {}) {
  const version = await (typeof spawn === 'function' ? spawn('gh', ['--version']) : runCmd(nodeSpawn, 'gh', ['--version']));
  if (version.exitCode !== 0) {
    return { ok: false, reason: 'gh CLI is not installed or not on PATH' };
  }
  const status = await (typeof spawn === 'function' ? spawn('gh', ['auth', 'status']) : runCmd(nodeSpawn, 'gh', ['auth', 'status']));
  if (status.exitCode !== 0) {
    return { ok: false, reason: 'gh is installed but not authenticated. Run: gh auth login' };
  }
  return { ok: true, version: version.stdout.trim() };
}
```

- [ ] **Step 5: Run tests to confirm they pass**

```bash
npm test
```

Expected: `tests 32` / `pass 32`.

- [ ] **Step 6: Commit**

```bash
git add scripts/publish.js scripts/lib/ledger.js tests/publish.test.js
git commit -m "feat(publisher): ledger read/write + gh availability check"
```

---

### Task 12: Publish — repo create, push, community PR

**Files:**
- Modify: `wecoded-marketplace-publisher/scripts/publish.js`
- Modify: `wecoded-marketplace-publisher/tests/publish.test.js`

**Responsibility:** create the user's public repo under their `gh` account, push the working dir, then open a community-listing PR against `wecoded-marketplace` that adds an entry to `marketplace.json`. All `gh`/`git` invocations go through a dependency-injected `spawn`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/publish.test.js`:

```javascript
import { publishCommunity } from '../scripts/publish.js';

function recordingSpawn(responses) {
  const calls = [];
  const impl = async (cmd, args) => {
    calls.push([cmd, ...args].join(' '));
    const key = Object.keys(responses).find(k => calls[calls.length - 1].includes(k));
    return responses[key] || { exitCode: 0, stdout: '', stderr: '' };
  };
  impl.calls = calls;
  return impl;
}

test('publishCommunity runs gh repo create, push, and opens PR', async () => {
  const spawn = recordingSpawn({
    'repo create': { exitCode: 0, stdout: 'https://github.com/alice/demo', stderr: '' },
    'pr create': { exitCode: 0, stdout: 'https://github.com/itsdestin/wecoded-marketplace/pull/100', stderr: '' },
  });
  const result = await publishCommunity({
    workingDir: '/tmp/does-not-matter',
    pluginId: 'demo',
    ghUser: 'alice',
    metadata: { displayName: 'Demo', description: 'd', author: { name: 'alice' }, category: 'personal' },
    spawn,
  });
  assert.ok(spawn.calls.some(c => c.startsWith('gh repo create')));
  assert.ok(spawn.calls.some(c => c.startsWith('git push')) || spawn.calls.some(c => c.includes('--push')));
  assert.ok(spawn.calls.some(c => c.startsWith('gh pr create')));
  assert.equal(result.repoUrl, 'https://github.com/alice/demo');
  assert.equal(result.communityPR, 'https://github.com/itsdestin/wecoded-marketplace/pull/100');
});

test('publishCommunity fails gracefully when repo create fails', async () => {
  const spawn = async (cmd, args) => args.includes('repo') && args.includes('create')
    ? { exitCode: 1, stdout: '', stderr: 'name already taken' }
    : { exitCode: 0, stdout: '', stderr: '' };
  await assert.rejects(async () => {
    await publishCommunity({
      workingDir: '/tmp/does-not-matter',
      pluginId: 'demo',
      ghUser: 'alice',
      metadata: { displayName: 'Demo', description: 'd', author: { name: 'alice' }, category: 'personal' },
      spawn,
    });
  }, /already taken/);
});
```

- [ ] **Step 2: Run tests to confirm failures**

```bash
npm test
```

Expected: 2 new failing tests.

- [ ] **Step 3: Implement `publishCommunity`**

Append to `scripts/publish.js`:

```javascript
async function run(spawn, cmd, args) {
  const r = await spawn(cmd, args);
  if (r.exitCode !== 0) {
    const msg = r.stderr || r.stdout || `${cmd} exited ${r.exitCode}`;
    throw new Error(msg);
  }
  return r;
}

function marketplaceEntryFor(pluginId, metadata, repoUrl) {
  return {
    name: pluginId,
    displayName: metadata.displayName,
    description: metadata.description,
    author: metadata.author,
    category: metadata.category,
    source: { source: 'url', url: `${repoUrl}.git` },
    homepage: repoUrl,
    sourceMarketplace: 'community',
  };
}

export async function publishCommunity({ workingDir, pluginId, ghUser, metadata, spawn }) {
  const repoCreate = await run(spawn, 'gh', [
    'repo', 'create', `${ghUser}/${pluginId}`,
    '--public',
    '--source', workingDir,
    '--push',
  ]);
  const repoUrl = (repoCreate.stdout || '').trim() || `https://github.com/${ghUser}/${pluginId}`;

  const entry = marketplaceEntryFor(pluginId, metadata, repoUrl);
  const branch = `add-plugin/${pluginId}`;
  const body = [
    `Adds \`${pluginId}\` as a community plugin.`,
    '',
    `- **Author:** ${metadata.author?.name || 'unknown'}`,
    `- **Source:** ${repoUrl}`,
    `- **Description:** ${metadata.description}`,
    '',
    'Published via `wecoded-marketplace-publisher`.',
  ].join('\n');

  const prCreate = await run(spawn, 'gh', [
    'pr', 'create',
    '--repo', 'itsdestin/wecoded-marketplace',
    '--head', branch,
    '--title', `Add ${metadata.displayName} (community)`,
    '--body', body,
  ]);

  return {
    repoUrl,
    communityPR: (prCreate.stdout || '').trim(),
    marketplaceEntry: entry,
  };
}
```

> **Note for implementer:** The marketplace entry above assumes community plugins hosted in user repos use `source: { source: 'url', url: '...' }` — this matches the existing convention for `youcoded-core` in `marketplace.json`. If `wecoded-marketplace` CI validates a different shape for community entries (check `validate-plugin-pr.yml` and `scripts/schema.js` before shipping), update `marketplaceEntryFor` and this task's tests. Do not invent schema values the CI won't accept.
>
> The `gh pr create` call above requires that the change to `marketplace.json` be committed on the `add-plugin/{pluginId}` branch of the marketplace repo before the PR is opened. The minimal reliable flow: clone `wecoded-marketplace` into a temp dir, create branch, write the entry, commit, push, then `gh pr create --head add-plugin/{pluginId}`. Add these steps as additional `gh/git` calls before `gh pr create`. The test above asserts on the presence of repo-create and pr-create but does not mandate a specific git workflow — implementer has latitude here.

- [ ] **Step 4: Run tests to confirm they pass**

```bash
npm test
```

Expected: `tests 34` / `pass 34`.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish.js tests/publish.test.js
git commit -m "feat(publisher): publishCommunity opens user repo + community PR"
```

---

### Task 13: Publish — adoption PR + idempotent recovery

**Files:**
- Modify: `wecoded-marketplace-publisher/scripts/publish.js`
- Modify: `wecoded-marketplace-publisher/tests/publish.test.js`

**Responsibility:** open the adoption-request PR that drops a templated file at `adoption-requests/{pluginId}.md` in `wecoded-marketplace`. Also add a `publish()` top-level orchestrator that reads the ledger to resume interrupted runs.

- [ ] **Step 1: Write the failing tests**

Append to `tests/publish.test.js`:

```javascript
import { publishAdoptionRequest, publish } from '../scripts/publish.js';

test('publishAdoptionRequest opens a PR with request file contents', async () => {
  const spawn = recordingSpawn({
    'pr create': { exitCode: 0, stdout: 'https://github.com/itsdestin/wecoded-marketplace/pull/101', stderr: '' },
  });
  const result = await publishAdoptionRequest({
    pluginId: 'demo',
    ghUser: 'alice',
    metadata: { displayName: 'Demo', description: 'd', author: { name: 'alice' }, category: 'personal' },
    communityPR: 'https://github.com/itsdestin/wecoded-marketplace/pull/100',
    reason: 'I do not have time to maintain this long-term.',
    repoUrl: 'https://github.com/alice/demo',
    spawn,
  });
  assert.equal(result.adoptionPR, 'https://github.com/itsdestin/wecoded-marketplace/pull/101');
  const prCreateCall = spawn.calls.find(c => c.startsWith('gh pr create'));
  assert.match(prCreateCall, /adoption-request/);
});

test('publish resumes from "repo-created" state in ledger', async () => {
  const configDir = await fs.mkdtemp(path.join(os.tmpdir(), 'wmp-resume-'));
  await writeLedgerEntry({ configDir, entry: {
    pluginId: 'resumer',
    repoUrl: 'https://github.com/alice/resumer',
    version: '0.1.0',
    publishedAt: new Date().toISOString(),
    state: 'repo-created',
  }});

  const spawn = recordingSpawn({
    'pr create': { exitCode: 0, stdout: 'https://.../pull/5', stderr: '' },
  });

  const result = await publish({
    workingDir: '/tmp/xx',
    pluginId: 'resumer',
    ghUser: 'alice',
    metadata: { displayName: 'R', description: 'd', author: { name: 'alice' }, category: 'personal' },
    pathChoice: 'community',
    configDir,
    spawn,
  });
  assert.ok(!spawn.calls.some(c => c.startsWith('gh repo create')));
  assert.ok(spawn.calls.some(c => c.startsWith('gh pr create')));
  assert.equal(result.communityPR, 'https://.../pull/5');
});
```

- [ ] **Step 2: Run tests to confirm failures**

```bash
npm test
```

Expected: 2 new failing tests.

- [ ] **Step 3: Implement `publishAdoptionRequest` and `publish`**

Append to `scripts/publish.js`:

```javascript
import { readLedger, writeLedgerEntry } from './lib/ledger.js';

function adoptionRequestBody({ pluginId, metadata, communityPR, reason, repoUrl, ghUser }) {
  return [
    `# Adoption Request: ${metadata.displayName}`,
    '',
    `**Plugin ID:** \`${pluginId}\``,
    `**Submitter:** @${ghUser}`,
    `**Source repo:** ${repoUrl}`,
    `**Community listing PR:** ${communityPR}`,
    `**Category:** ${metadata.category}`,
    '',
    '## Description',
    '',
    metadata.description || '',
    '',
    '## Why adoption?',
    '',
    reason,
    '',
    '## Acknowledgments',
    '',
    'I understand that if WeCoded accepts this adoption request:',
    '- WeCoded will host and maintain the adopted version of this plugin.',
    '- The community listing from my repo will be delisted in favor of the adopted copy.',
    '- I will no longer control updates, bug fixes, or the plugin itself.',
    '- I keep ownership of my source repo, but it will no longer be what the marketplace lists.',
    '',
    'If WeCoded declines this request, nothing changes — my community listing remains.',
  ].join('\n');
}

export async function publishAdoptionRequest({ pluginId, ghUser, metadata, communityPR, reason, repoUrl, spawn }) {
  const body = adoptionRequestBody({ pluginId, metadata, communityPR, reason, repoUrl, ghUser });
  const branch = `adoption-request/${pluginId}`;
  const prCreate = await run(spawn, 'gh', [
    'pr', 'create',
    '--repo', 'itsdestin/wecoded-marketplace',
    '--head', branch,
    '--title', `[Adoption Request] ${metadata.displayName}`,
    '--body', body,
    '--label', 'adoption-request',
  ]);
  return { adoptionPR: (prCreate.stdout || '').trim() };
}

export async function publish({ workingDir, pluginId, ghUser, metadata, pathChoice, reason, configDir, spawn }) {
  const ledger = await readLedger({ configDir });
  const prior = ledger.entries.find(e => e.pluginId === pluginId);

  let repoUrl = prior?.repoUrl;
  let communityPR = prior?.communityPR;
  let adoptionPR = prior?.adoptionPR;

  if (!prior || prior.state === undefined) {
    const community = await publishCommunity({ workingDir, pluginId, ghUser, metadata, spawn });
    repoUrl = community.repoUrl;
    await writeLedgerEntry({ configDir, entry: {
      pluginId, repoUrl, version: '0.1.0', publishedAt: new Date().toISOString(), state: 'repo-created',
    }});
    communityPR = community.communityPR;
    await writeLedgerEntry({ configDir, entry: { pluginId, communityPR, state: 'community-pr-open' } });
  } else if (prior.state === 'repo-created') {
    const community = await publishCommunity({ workingDir, pluginId, ghUser, metadata, spawn });
    communityPR = community.communityPR;
    await writeLedgerEntry({ configDir, entry: { pluginId, communityPR, state: 'community-pr-open' } });
  }

  if (pathChoice === 'adoption' && !adoptionPR) {
    const adoption = await publishAdoptionRequest({
      pluginId, ghUser, metadata, communityPR, reason, repoUrl, spawn,
    });
    adoptionPR = adoption.adoptionPR;
    await writeLedgerEntry({ configDir, entry: { pluginId, adoptionPR, state: 'complete-with-adoption' } });
  } else {
    await writeLedgerEntry({ configDir, entry: { pluginId, state: 'complete' } });
  }

  return { repoUrl, communityPR, adoptionPR };
}
```

> **Note for implementer:** `publishCommunity` above is re-invoked when resuming from `repo-created`, but the test expects only `gh pr create` to be called (no `gh repo create`). Split `publishCommunity` into a "create repo" phase and a "create PR" phase so the resume path can skip the first. Matching the test requires: `publishCommunity` returns both `repoUrl` and `communityPR`, but the PR phase must be callable standalone given a repo URL. Refactor inline if needed.

- [ ] **Step 4: Run tests to confirm they pass** (with the split mentioned above)

```bash
npm test
```

Expected: `tests 36` / `pass 36`.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish.js tests/publish.test.js
git commit -m "feat(publisher): adoption PR + idempotent publish orchestrator"
```

---

### Task 14: SKILL.md — intake through discovery

**Files:**
- Modify: `wecoded-marketplace-publisher/skills/marketplace-publisher/SKILL.md`

**Responsibility:** write the top half of the conversational flow — preflight of `gh`, open-ended intake, structured triage, call to `inventory.js`, findings review. No test — SKILL.md behavior is verified manually and via dry-run (task 17).

- [ ] **Step 1: Write the SKILL.md content (steps 1-5 of the journey)**

Replace the stub in `skills/marketplace-publisher/SKILL.md` with:

````markdown
---
name: marketplace-publisher
description: Conversational assistant that helps users publish their plugins (skills, commands, hooks, MCPs, agents) to the WeCoded marketplace. Offers a community-maintained path and an adoption-request path. Handles disk discovery, plugin rebuild, secret sanitization, and PR creation.
---

# WeCoded Marketplace Publisher

You are helping the user publish something they've built to the WeCoded marketplace. The user is a non-technical user who built their plugin via conversation with Claude; they may not know what components it has or where its files live. Your job is to guide them warmly and clearly, never dead-ending, and always explaining what will happen before doing it.

## Step 1 — Preflight (gh CLI check)

Run:

```bash
node ${CLAUDE_PLUGIN_ROOT}/scripts/publish.js preflight-gh
```

If the output JSON has `ok: false`:
- Politely tell the user the GitHub CLI (`gh`) isn't ready. Show them the `reason` from the script output, and include:
  - How to install: `winget install GitHub.cli` (Windows), `brew install gh` (macOS), `sudo apt install gh` (Ubuntu/Debian)
  - How to sign in: `gh auth login`
- Stop the flow. Tell them to run `/publish-to-marketplace` again once `gh` is ready.

If `ok: true`, continue.

## Step 2 — Open-ended intake

Ask: *"Great, let's get your plugin published. First — tell me about what you made. In your own words, what does it do, and how do you use it?"*

Listen carefully. From their answer, extract (mentally, or in scratchpad notes):
- A one-sentence **description** (this will seed the marketplace listing description)
- A casual **name** they use for it (this seeds the `displayName`)
- Keywords that suggest what TYPE of components are involved

## Step 3 — Structured triage

Ask these one at a time, not all at once. Each answer informs which locations to scan. Convert answers to a `signals` object.

1. *"Do you trigger it with a slash command (something you type starting with `/`)?"* → `hasCommand`
2. *"Does it talk to any external services — email, GitHub, Slack, Notion, anything like that?"* → `hasMCP` (services usually mean MCPs)
3. *"Does it run automatically — like when you start a Claude session, or when you save a file?"* → `hasHook`
4. *"Does it include its own reusable instructions — something you built that you could imagine sharing with a friend?"* → `hasSkill`
5. *"Does it include a custom sub-agent — a separate Claude personality you hand off work to?"* → `hasAgent`

Default to `true` for `hasSkill` if the user isn't sure — most plugins have a skill.

## Step 4 — Detective work

Call the inventory script:

```bash
node ${CLAUDE_PLUGIN_ROOT}/scripts/inventory.js '{
  "signals": { "hasSkill": ..., "hasCommand": ..., "hasHook": ..., "hasMCP": ..., "hasAgent": ... },
  "userDescription": "...",
  "userKeywords": ["..."]
}'
```

Parse the JSON output. The `candidates[]` array is sorted by score (most relevant first).

## Step 5 — Findings & confirmation

Present the top candidates in plain language. Example framing:

> *"I looked around and found a few things that might be what you mean. Let me describe them:*
>
> *1. A skill called `summarize-emails` (in `~/.claude/skills/`). It says it summarizes your inbox using Gmail. It also mentions the Gmail tool (`mcp__gmail__list`), which means it needs the Gmail MCP to work.*
>
> *Is `summarize-emails` what you made? If yes — should I include the Gmail tool as a required dependency so other people's installs work?"*

For each candidate's `references[]` that resolves to an MCP server the inventory also found, call it out specifically — this is the hidden-dependency detection. Ask the user one thing at a time: confirm each piece, ask about each dependency.

Build a "confirmed manifest" in your head (or as a JSON blob in your scratchpad) like:

```json
{
  "pluginId": "summarize-emails",
  "pieces": [
    { "type": "skill", "sourcePath": "/home/.../SKILL.md", "targetPath": "skills/summarize-emails/SKILL.md" },
    { "type": "mcp", "name": "gmail", "config": { ... } }
  ]
}
```

Then proceed to the rebuild step (filled in by Task 15).
````

- [ ] **Step 2: Commit**

```bash
git add skills/marketplace-publisher/SKILL.md
git commit -m "feat(publisher): SKILL.md intake, triage, and discovery flow"
```

---

### Task 15: SKILL.md — rebuild, secret review, metadata

**Files:**
- Modify: `wecoded-marketplace-publisher/skills/marketplace-publisher/SKILL.md`

- [ ] **Step 1: Append the middle section of the skill**

Append to `skills/marketplace-publisher/SKILL.md`:

````markdown
## Step 6 — Rebuild

Call the build-plugin script with the confirmed manifest:

```bash
node ${CLAUDE_PLUGIN_ROOT}/scripts/build-plugin.js '{
  "manifest": { "pluginId": "...", "metadata": { ... }, "pieces": [ ... ] },
  "workingRoot": "~/.claude/wecoded-marketplace-publisher/working",
  "sanitize": false
}'
```

Set `sanitize: false` for this call — you want to see unsanitized findings first so you can show them to the user.

Parse the JSON output. If `unsanitizedFindings` is non-empty, go to Step 7. Otherwise skip to Step 8.

## Step 7 — Secret review & sanitization

If the build returned secret findings, present them to the user clearly:

> *"Before we go further, I scanned your plugin and found **N** things that look like secrets. I want to show you before we do anything else."*

List each finding with:
- The file and line
- What kind of secret (GitHub token, Anthropic key, etc.)
- An excerpt (`ghp_...`) — never the full value

Then offer the recommended action:

> *"**Recommended**: I'll sanitize the published version — take these secrets out of the code and replace them with environment variable reads. I'll add a **SETUP.md** doc telling anyone who installs this plugin exactly what values they need and where to get them. Your local copy stays exactly as it is — only the published copy is sanitized.*
>
> *Or: if these are deliberately-shared demo values (rotated, revoked, etc.) I can keep them in — but I have to warn you that anyone who installs this plugin will be able to see and use them. Not recommended.*
>
> *Which would you like — sanitize (recommended), keep as-is, or cancel?"*

If sanitize: re-run build-plugin.js with `sanitize: true`. After it completes, show the user a before/after summary for each file:

> *"In `scripts/fetch.js`, I replaced the Anthropic key with `process.env.ANTHROPIC_API_KEY` and added `ANTHROPIC_API_KEY` to SETUP.md."*

If keep: proceed without sanitization. (You'll have already written unsanitized files. The preflight in Step 9 will catch this and fail, so the user gets a second chance to reconsider.)

If cancel: exit, leave the working dir in place for the user to inspect manually.

## Step 8 — Metadata

The build generated a `plugin.json` from initial metadata, but the marketplace entry needs more: `displayName`, `description`, `category`, `tags`, `lifeArea`, `audience`.

Propose values based on:
- `displayName`: the casual name from Step 2, cleaned up (Title Case, no weird characters)
- `description`: the one-sentence description from Step 2, polished
- `category`: pick from the marketplace's valid set (fetch once via schema; common: `personal`, `productivity`, `development`, `work`, `fun`)
- `tags`: 3-5 keywords from the user's intake + detected component types (`skill`, `mcp-integration`, etc.)
- `lifeArea`: infer from category (`personal` → `["personal"]`, `work` → `["work"]`, etc.)
- `audience`: `"general"` unless the user indicates it's developer-focused

Show the user the proposed values. Ask: *"Any of these you want to change?"* For each field they want to edit, collect the new value. Keep the loop tight — don't interrogate field by field unless they want to.
````

- [ ] **Step 2: Commit**

```bash
git add skills/marketplace-publisher/SKILL.md
git commit -m "feat(publisher): SKILL.md rebuild, secret review, metadata flow"
```

---

### Task 16: SKILL.md — preflight, path choice, publish, confirmation

**Files:**
- Modify: `wecoded-marketplace-publisher/skills/marketplace-publisher/SKILL.md`

- [ ] **Step 1: Append the final section**

Append to `skills/marketplace-publisher/SKILL.md`:

````markdown
## Step 9 — Preflight

Run the full preflight:

```bash
node ${CLAUDE_PLUGIN_ROOT}/scripts/preflight.js '{
  "pluginDir": "~/.claude/wecoded-marketplace-publisher/working/<pluginId>",
  "pluginId": "<pluginId>",
  "metadata": { ... }
}'
```

Parse the JSON output. For each `check` with `status: "fail"`, show the user the `detail` message in plain language and jump back to the appropriate step:
- `secret-scan` fail → loop back to Step 7
- `required-fields` fail → loop back to Step 8
- `id-uniqueness` fail → suggest alternatives based on `displayName` and ask user to pick one (updates the manifest's `pluginId` and requires re-running build-plugin)
- `size` / `hygiene` → show offenders, offer to exclude, re-run build-plugin

For `status: "warn"`, describe the concern and ask the user if they want to proceed anyway.

Only proceed when `pass: true`.

## Step 10 — Show finished plugin

Summarize for the user:

> *"Here's what's ready to publish:*
>
> *- **Name:** Summarize Emails*
> *- **Description:** Summarize the user's inbox...*
> *- **Category:** personal*
> *- **Tags:** email, summary, productivity*
> *- **Contains:** 1 skill (`summarize-emails`), 1 MCP dependency (Gmail)*
> *- **Installers will need to configure:** `GMAIL_TOKEN` (see SETUP.md)*
>
> *Ready to publish?"*

## Step 11 — Path choice

Present the two options. Use this exact framing (the user needs the consequences of adoption to be unmistakable):

```
Two options for publishing:

Option A: Community plugin (you maintain it)
  • Your plugin lives in your own GitHub repo
  • You can edit, update, or remove it any time
  • If people report bugs, you fix them
  • Marketplace shows a "Community" badge

Option B: Request WeCoded adoption (they may take over)
  • Your plugin still gets published to your GitHub repo and listed
    as Community — no matter what, you end up with a working listing
  • Separately, WeCoded reviews and decides whether to adopt it

  If WeCoded accepts:
    • WeCoded copies your plugin into their own repo
    • Marketplace shows an "Official WeCoded" badge
    • Your community version is delisted (adopted copy replaces it)
    • You no longer control updates, bug fixes, or the plugin itself
    • You still have YOUR repo — it's just no longer what the
      marketplace lists

  If WeCoded declines:
    • Nothing changes — your community version stays listed
    • WeCoded gives you a reason

  Response usually takes 1-2 weeks.
```

Ask for A or B.

If B, follow up: *"In a sentence or two, why would you like WeCoded to take this over?"* Capture the answer as `reason`.

## Step 12 — Publish

Run the publish orchestrator:

```bash
node ${CLAUDE_PLUGIN_ROOT}/scripts/publish.js publish '{
  "workingDir": "~/.claude/wecoded-marketplace-publisher/working/<pluginId>",
  "pluginId": "<pluginId>",
  "ghUser": "<from gh auth>",
  "metadata": { ... },
  "pathChoice": "community" | "adoption",
  "reason": "..." (if adoption),
  "configDir": "~/.claude/wecoded-marketplace-publisher"
}'
```

If any step throws, catch the error and tell the user in plain language:
- `gh repo create` failure with "name already taken" → suggest the user pick a different plugin ID; rerun with the new name
- PR creation failure → tell the user the repo was created but the PR step failed; the ledger is now in `repo-created` state; they can re-run `/publish-to-marketplace` to resume

## Step 13 — Confirmation

On success, show:

> *"**Done.** Here's what happened:*
>
> *- **Your repo:** https://github.com/{user}/{pluginId}*
> *- **Community listing PR:** https://github.com/itsdestin/wecoded-marketplace/pull/NNN*
> *- **Adoption request PR:** https://github.com/itsdestin/wecoded-marketplace/pull/MMM  (if applicable)*
>
> *What happens next:*
>
> *- The WeCoded team reviews community PRs typically within a few days. You'll get a GitHub notification when they respond.*
> *- If you chose adoption: the adoption review usually takes 1-2 weeks. Either way, your community listing is already live as soon as the community PR is merged.*
> *- If you need to make changes before the PR is merged, push commits to your repo; the PR will update automatically.*
>
> *You can always find these URLs in `~/.claude/wecoded-marketplace-publisher/published.json`."*

End the session. Do not poll PR status.
````

- [ ] **Step 2: Commit**

```bash
git add skills/marketplace-publisher/SKILL.md
git commit -m "feat(publisher): SKILL.md preflight, path choice, publish, confirmation"
```

---

### Task 17: Dry-run mode

**Files:**
- Modify: `wecoded-marketplace-publisher/scripts/publish.js`
- Modify: `wecoded-marketplace-publisher/tests/publish.test.js`

**Responsibility:** add `--dry-run` (or `dryRun: true` flag) support to `publish()` so the full flow runs through preflight and stops before `gh repo create`. Prints "would create / push / open" plan.

- [ ] **Step 1: Write the failing test**

Append to `tests/publish.test.js`:

```javascript
test('publish with dryRun does not call gh repo create', async () => {
  const configDir = await fs.mkdtemp(path.join(os.tmpdir(), 'wmp-dry-'));
  const spawn = recordingSpawn({});
  const result = await publish({
    workingDir: '/tmp/xx',
    pluginId: 'dryplugin',
    ghUser: 'alice',
    metadata: { displayName: 'D', description: 'd', author: { name: 'alice' }, category: 'personal' },
    pathChoice: 'community',
    configDir,
    spawn,
    dryRun: true,
  });
  assert.equal(spawn.calls.length, 0);
  assert.equal(result.dryRun, true);
  assert.ok(result.plan);
  assert.match(result.plan, /would create/i);
});
```

- [ ] **Step 2: Run test to confirm failure**

```bash
npm test
```

Expected: 1 new failing test.

- [ ] **Step 3: Implement dry-run in `publish()`**

At the top of `publish()` in `scripts/publish.js`, before reading the ledger:

```javascript
  if (dryRun) {
    const planLines = [
      `Would create GitHub repo: ${ghUser}/${pluginId}`,
      `Would push working dir: ${workingDir}`,
      `Would open community PR at: itsdestin/wecoded-marketplace (branch: add-plugin/${pluginId})`,
    ];
    if (pathChoice === 'adoption') {
      planLines.push(`Would open adoption-request PR at: itsdestin/wecoded-marketplace (branch: adoption-request/${pluginId})`);
    }
    return { dryRun: true, plan: planLines.join('\n') };
  }
```

Change the function signature to accept `dryRun = false`:

```javascript
export async function publish({ workingDir, pluginId, ghUser, metadata, pathChoice, reason, configDir, spawn, dryRun = false }) {
```

- [ ] **Step 4: Run test to confirm pass**

```bash
npm test
```

Expected: `tests 37` / `pass 37`.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish.js tests/publish.test.js
git commit -m "feat(publisher): dry-run mode for end-to-end validation"
```

---

### Task 18: Marketplace self-entry

**Files:**
- Modify: `wecoded-marketplace/marketplace.json` (add an entry for the publisher plugin itself)

- [ ] **Step 1: Inspect existing entries**

```bash
node -e "console.log(JSON.stringify(JSON.parse(require('fs').readFileSync('marketplace.json','utf8')).plugins.find(p => p.name === 'civic-report'), null, 2))"
```

- [ ] **Step 2: Add the publisher entry**

Edit `wecoded-marketplace/marketplace.json`. In the `plugins` array, insert a new entry following the same shape as `civic-report`:

```json
{
  "name": "wecoded-marketplace-publisher",
  "displayName": "WeCoded Marketplace Publisher",
  "description": "Publish your plugins to the WeCoded marketplace — conversational, non-technical-user friendly.",
  "author": {
    "name": "@destin",
    "github": "itsdestin"
  },
  "category": "productivity",
  "source": {
    "source": "local",
    "path": "wecoded-marketplace-publisher"
  },
  "prompt": "/publish-to-marketplace"
}
```

- [ ] **Step 3: Regenerate index (if the repo's sync script is available)**

```bash
cd wecoded-marketplace
node scripts/sync.js --local
```

If this command errors or doesn't exist at the expected path, skip this step. The CI workflow will regenerate `index.json` on merge.

- [ ] **Step 4: Commit**

```bash
git add wecoded-marketplace/marketplace.json wecoded-marketplace/index.json
git commit -m "feat(marketplace): register wecoded-marketplace-publisher plugin"
```

---

### Task 19: Manual integration test

**Files:** none (this is a verification task, not a code task)

**Responsibility:** verify the end-to-end flow in dry-run mode against real fixtures, then optionally a real sandbox publish.

- [ ] **Step 1: Run the test suite one last time**

```bash
cd wecoded-marketplace-publisher
npm test
```

Expected: all 37 tests pass.

- [ ] **Step 2: Dry-run the flow manually**

Create a temp working dir with a simple fake plugin:

```bash
TMP=$(mktemp -d)
mkdir -p "$TMP/mytest/skills/demo-skill"
cat > "$TMP/mytest/skills/demo-skill/SKILL.md" <<'EOF'
---
name: demo-skill
description: Demo.
---
Body.
EOF
cat > "$TMP/mytest/plugin.json" <<'EOF'
{
  "name": "mytest",
  "version": "0.1.0",
  "description": "Test",
  "author": { "name": "tester" },
  "keywords": []
}
EOF
```

Then run:

```bash
node scripts/publish.js publish '{
  "workingDir": "'"$TMP"'",
  "pluginId": "mytest",
  "ghUser": "sandbox-user",
  "metadata": { "displayName": "MyTest", "description": "Test", "author": { "name": "tester" }, "category": "personal" },
  "pathChoice": "community",
  "configDir": "'"$TMP"'/config",
  "dryRun": true
}'
```

Expected stdout: `{ "dryRun": true, "plan": "Would create GitHub repo: sandbox-user/mytest\n..." }`.

- [ ] **Step 3: Sandbox integration test (optional — requires sandbox GitHub account)**

Only run if you have a sandbox account authenticated with `gh`.

```bash
# Fork wecoded-marketplace under the sandbox account first, then:
node scripts/publish.js publish '{ ... same as above but dryRun: false, targeting a FORK of wecoded-marketplace ... }'
```

Verify on GitHub:
- A new public repo `{sandbox-user}/mytest` exists with the plugin contents
- A PR is open at `{sandbox-user}/wecoded-marketplace` (the fork) adding the community entry to `marketplace.json`

After verification, delete the test repo and close the PR.

- [ ] **Step 4: Document the integration-test outcome in the PR description**

When opening the PR that ships this plugin, include in the PR body:

- Whether the sandbox integration test was run (yes/no)
- Any manual observations from the dry-run

- [ ] **Step 5: Open the PR against wecoded-marketplace**

```bash
gh pr create --base master --head feat/marketplace-publisher \
  --title "feat: WeCoded Marketplace Publisher plugin" \
  --body-file <<'EOF'
Adds `wecoded-marketplace-publisher`, a Claude Code plugin that helps non-technical users publish their own plugins to this marketplace.

## What's new

- Plugin at `wecoded-marketplace-publisher/` with `plugin.json`, `README.md`, commands, skills, scripts, and tests.
- Entry in `marketplace.json` registering the publisher itself as a WeCoded plugin.
- 37 passing unit tests covering inventory, build, preflight, and publish.

## Design and plan

- Spec: `youcoded-dev/docs/superpowers/specs/2026-04-20-wecoded-marketplace-publisher-design.md`
- Plan: `youcoded-dev/docs/superpowers/plans/2026-04-20-wecoded-marketplace-publisher.md`

## Sandbox test

(fill in based on step 3)

## Checklist

- [ ] `npm test` passes
- [ ] Dry-run produces expected plan text
- [ ] marketplace.json valid JSON
- [ ] SKILL.md reviewed for tone (plain language, no jargon)
EOF
```

---

## Self-review

After writing the plan, I checked it against the spec:

**Spec coverage:**
- ✓ Plugin scaffolding (Task 1)
- ✓ Disk discovery via inventory.js (Tasks 2-4)
- ✓ Plugin rebuild via build-plugin.js (Tasks 5-6)
- ✓ Secret detection (Task 7)
- ✓ Secret sanitization + SETUP.md (Task 8)
- ✓ Local preflight (Task 9)
- ✓ Network preflight — ID uniqueness + enum (Task 10)
- ✓ gh availability check + ledger (Task 11)
- ✓ Community repo + PR (Task 12)
- ✓ Adoption PR + idempotent resume (Task 13)
- ✓ SKILL.md conversational flow (Tasks 14-16)
- ✓ Dry-run mode (Task 17)
- ✓ Marketplace self-entry (Task 18)
- ✓ Manual integration test (Task 19)

**Placeholder scan:** no "TBD" / "TODO" / "implement later" markers. Each task has concrete code.

**Type consistency:** spot-checked — `buildPlugin` signature is consistent across tasks 5/6/7/8; `publish`/`publishCommunity`/`publishAdoptionRequest` names match between tests and implementations.

**Known implementer notes / soft spots:**
- Task 12 inline note: the exact `source` shape for community plugins must match what `wecoded-marketplace` CI validates. The plan uses `{ source: 'url', url: '...' }` matching the `youcoded-core` entry convention; implementer should verify against `validate-plugin-pr.yml` and `scripts/schema.js` before merging.
- Task 12 inline note: `gh pr create` against `wecoded-marketplace` requires cloning the marketplace repo, committing the new entry to a branch, and pushing before the PR opens. The plan treats the git mechanics as implementer latitude — if the straight `gh pr create` call fails (GitHub requires the branch to exist with the diff), add the clone/commit/push steps before the PR call.
- Task 13 inline note: splitting `publishCommunity` into repo-create and PR-create phases is necessary for the resume test. Refactor when implementing.
