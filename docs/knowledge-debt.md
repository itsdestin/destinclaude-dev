# Knowledge Debt

Running list of documentation/rule drift that's been noticed but not yet fixed. Each entry has concrete fix instructions so they persist across sessions.

**How to use this file:**
- Claude appends entries when it notices drift mid-session (outdated claim, renamed file, etc.)
- `/audit` appends entries for any drift detected but not fixed in-session
- User reviews periodically, applies fixes, removes entries
- Each entry stays until resolved — empty file = no known debt

## Entry format

```markdown
## <Title> (noticed YYYY-MM-DD)
- **Claim**: <what docs/rules say>
- **Actual**: <what code does>
- **Fix**: <concrete steps — file, section, change, verify>
- **Priority**: low / medium / high
```

---

Last audit: 2026-04-23 (full sweep — see `docs/AUDIT.md` for complete findings). Prior baseline 2026-04-11.

## Onboarding.tsx screen deferred (noticed 2026-04-12)
- **Claim**: Decomposition v3 §7.12 / §9.10 specify a React Onboarding screen that collects name/comfort/output-style, installs curated packages on first launch, and replaces the conversational setup-wizard as the primary first-run path.
- **Actual**: All backend helpers exist and are bridged to desktop, remote, and Android (skills:install-many, skills:apply-output-style, skills:get-curated-defaults, skills:get-integration-info). The React screen itself has not been built — App.tsx still shows only `FirstRunView` (CLI prereqs) and no toolkit-preferences step. Net effect: after decomposition lands, first-launch users reach an empty app with no curated packages installed and no output style set.
- **Fix**: Build `desktop/src/renderer/components/Onboarding.tsx` — form with name input, comfort radio (beginner/intermediate/power), output-style picker (casual/conversational/academic/professional), and a "install curated defaults" confirm step that calls `window.claude.skills.installMany(curatedIds)` and `window.claude.skills.applyOutputStyle(styleId)`. Gate it in App.tsx after `FirstRunView` completes, keyed on absence of `~/.claude/toolkit-state/config.json` (add a tiny IPC `toolkit:hasConfig` if needed). Must have a skip button so a bug can't brick first launch. Needs live dev-server iteration — don't ship blind.
- **Priority**: high (blocks decomposition merge to master)

## Icon override system is dead code (noticed 2026-04-12)
- **Claim**: `theme.icons` manifest entries (slots: send, new-chat, settings, theme-cycle, close, menu per `youcoded/desktop/src/renderer/themes/theme-types.ts:75`) override the app's built-in icons. `theme-builder` SKILL.md documents generating and shipping `icon-<slot>.svg` assets. Exemplar theme `golden-sunbreak/manifest.json` ships a `send` override.
- **Actual**: Manifest loading and asset resolution work end-to-end (`theme-asset-resolver.ts:52-58`), but **zero React components consume `theme.icons[slot]`**. Every UI icon — send button (`InputBar.tsx:493-495`), settings gear + view toggle + gamepad (`HeaderBar.tsx`), new session (`SessionStrip.tsx`) — is hardcoded inline SVG that ignores the override map. `golden-sunbreak`'s `send` override has been dead data since shipped.
- **Fix**: Either (a) wire each icon-rendering component to check `theme.icons[slot]` before falling back to its hardcoded SVG, and expand slots to cover terminal/chat-view/game/session-add, OR (b) remove the `icons` field from `theme-types.ts` + manifest schema + SKILL.md and stop pretending it works. Also update `theme-builder/scripts/mockup-render.js` if (a) — mockup's chrome SVGs are also hardcoded. Tracked in youcoded issue.
- **Priority**: medium (affects every theme's claimed override capability; blocks theme-builder icon pack work)

## Sign + size-cap announcement payload (noticed 2026-04-21, surfaced by /release v1.2.0 review)
- **Claim**: AnnouncementService (desktop `desktop/src/main/announcement-service.ts`, Android `app/src/main/kotlin/com/youcoded/app/runtime/AnnouncementService.kt`) fetches the public `announcements.txt` from `raw.githubusercontent.com/itsdestin/youcoded/master/announcements.txt` over HTTPS and writes the result to the local cache.
- **Actual**: Fetch is unauthenticated and unsigned. Any future compromise of the youcoded repo (or the single file) lets an attacker push arbitrary banner text into the status bar of every installed client. Length is also unbounded — a multi-megabyte payload would bloat the cache and the StatusBar render path.
- **Fix**: (1) Sign `announcements.txt` with a static public key committed to the app, verify the signature in both fetchers before writing to cache, fail-closed on signature mismatch. (2) Cap the parsed announcement length server-side in the parser (e.g. 512 chars) before persisting. (3) Document the trust model in the announcements README so contributors know not to bypass the signing step.
- **Priority**: low (no current incident; defense-in-depth hardening)

## CC-drift: Verify tool-card display after Glob/Grep merge into Bash tool on native builds (surfaced 2026-04-21, from CC v2.1.117)
CC v2.1.117 merged the Glob and Grep tools into the Bash tool on native macOS/Linux builds (Windows desktop and Android npm builds are unchanged). YouCoded's transcript-watcher dispatches TRANSCRIPT_TOOL_USE with tool names; ToolCards render per-tool UI. If Glob/Grep calls now surface as `tool_name='Bash'` in transcript JSONL on native builds, any tool-name-specific rendering (icons, labels) drops through to the Bash fallback. Affects desktop macOS/Linux only (CC 2.1.113+ native builds). Touchpoint: 'Transcript JSONL shape'. Verify by running a Grep via native CC and checking the tool card.

CHANGELOG entry: "v2.1.117: Native builds on macOS and Linux: the `Glob` and `Grep` tools are replaced by embedded `bfs` and `ugrep` available through the Bash tool — faster searches without a separate tool round-trip (Windows and npm-installed builds unchanged)"

## CC-drift: Consider surfacing CLAUDE_CODE_FORK_SUBAGENT toggle in settings (surfaced 2026-04-21, from CC v2.1.117)
CC v2.1.117 added `CLAUDE_CODE_FORK_SUBAGENT=1` to enable forked subagents on external builds. YouCoded doesn't expose this today. Could become a developer-mode toggle in the settings panel; low priority, small effort. No coupling today.

CHANGELOG entry: "v2.1.117: Forked subagents can now be enabled on external builds by setting `CLAUDE_CODE_FORK_SUBAGENT=1`"

## CC-drift: Audit sync service against CC's expanded cleanupPeriodDays coverage (surfaced 2026-04-21, from CC v2.1.117)
CC v2.1.117 expanded the `cleanupPeriodDays` retention sweep to also cover `~/.claude/tasks/`, `~/.claude/shell-snapshots/`, and `~/.claude/backups/`. YouCoded's sync-service.ts writes/reads files under `~/.claude/` — if any YouCoded artifacts live under those three newly-swept paths, they could be deleted by CC's retention sweep. Quick audit of sync-service.ts paths worthwhile. No formal touchpoint for these paths today.

CHANGELOG entry: "v2.1.117: The `cleanupPeriodDays` retention sweep now also covers `~/.claude/tasks/`, `~/.claude/shell-snapshots/`, and `~/.claude/backups/`"

## Document Go-binary exec trap in Android runtime docs (noticed 2026-04-23)
- **Claim**: `docs/android-runtime.md` and `docs/PITFALLS.md` document the SELinux W^X bypass via three exec layers — LD_PRELOAD (C/Rust), claude-wrapper.js (Node), and `linker64-env.sh` bash wrappers for Go binaries (gh, fzf, micro). The implication is that running Go binaries through the wrappers is sufficient.
- **Actual**: The wrappers cover bash-invoked Go binaries, but they do not protect against a Go binary's own calls to `fork/exec` on scripts in the app's home dir. Go's raw `SYS_execve` syscall bypasses termux-exec's LD_PRELOAD intercept, so scripts under `~/.claude-mobile/*` (e.g. `xdg-open`, `open`, any shim placed on PATH) fail with `EACCES` when execed by any Go child. Hit in the wild by rclone's Google Drive OAuth auto-browser-open on Android — fix shipped in youcoded 6469e058 (`authGdriveWithBrowserIntent` streams stderr and opens the URL via `PlatformBridge.openUrl` / `Intent.ACTION_VIEW`). Same trap will fire for any future Go binary that tries to shell out to a `~/.claude-mobile/` shim (e.g. a Go tool that opens URLs via `xdg-open`, or spawns a helper script there).
- **Fix**: Add a subsection to `docs/android-runtime.md` under "System Fundamentals" (or `docs/PITFALLS.md` under "Android Runtime") titled something like "Go binaries can't exec scripts in `~/.claude-mobile/`." Explain: (1) why (LD_PRELOAD shim only intercepts libc execve, Go uses raw syscall), (2) the symptom (`EACCES` at fork/exec), (3) the two safe paths (spawn the Go process from bash with the linker64 wrappers so only the Go binary itself runs, then route any URL-open / native UI through `PlatformBridge` or a `CompletableDeferred` native-UI bridge), (4) cross-link to the rclone fix in SyncService.kt as the reference implementation. Also mention in the "# Known Pitfalls" list of CLAUDE.md that this is now a documented class of bug.
- **Priority**: medium (next Go-binary integration will re-hit this silently; the fix pattern is non-obvious without docs)

> **D1–D8 resolved on 2026-04-23.** Full details and applied fixes in `docs/AUDIT.md`. One follow-up: the D4 edit to `youcoded/.claude/rules/android-runtime.md` still needs to be committed + pushed in the youcoded repo.

## Android Library doesn't show locally-built themes (noticed 2026-04-25)
- **Claim**: After Phase 1 of `docs/superpowers/plans/2026-04-24-local-themes-in-library.md` shipped (youcoded master commit `b79d9885`), locally-built user themes (those at `~/.claude/wecoded-themes/<slug>/manifest.json`) appear in the Library Themes tab.
- **Actual**: Desktop only. Phase 1 modified `desktop/src/main/theme-marketplace-provider.ts::listThemes()` to synthesize entries via `local-theme-synthesizer.ts`. The Android equivalent — `app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt::themeMarketplaceList()` (around line 2948) — was NOT updated. Android users still only see external-registry themes in the Library, with locally-built themes invisible until they publish.
- **Fix**: Port the synthesizer logic to Kotlin. Either (a) add a `LocalThemeSynthesizer.kt` mirror with a unit test that exercises the same fixtures as `local-theme-synthesizer.test.ts`, then call it from `themeMarketplaceList()`, OR (b) move synthesis upstream by having the desktop main-process expose a `theme-marketplace:list-with-locals` IPC and have Android call into desktop via the WebSocket bridge (only works when desktop is the host — not appropriate for native Android app sessions). (a) is the right approach. Also port the `Local` badge + tooltip + delete-confirmation copy to the React renderer's WebView path — those should already work since the renderer code is shared, but verify that `theme.onReload` fires on Android (the IPC bridge dispatches it per `remote-shim.ts:211`).
- **Priority**: low (Destin primarily uses desktop; Phase 1 doesn't regress Android behavior — local themes were invisible there before too)

## Android integrations install/connect/uninstall not implemented (noticed 2026-04-28)
- **Claim**: The "Connect your stuff" rail now renders on Android (mp-mobile branch wired `integrations:list` to the marketplace registry catalog), so users on phones can browse Gmail, Drive, Spotify, etc. as if they're available.
- **Actual**: Only `integrations:list` is wired. Tapping **Install** / **Connect** / **Uninstall** on any integration sends `integrations:install` / `:connect` / `:uninstall` IPC, hits the unchanged stub at `app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` (around the `"integrations:status", "integrations:install", "integrations:uninstall", "integrations:connect", "integrations:configure"` block) and gets back `{ error: "not-implemented: integrations available on Android in a follow-up" }`. The renderer surfaces the error in the card status pill / detail-overlay error banner.
- **Fix**: Three pieces, in this order:
  1. **Install (plugin-wrapped)** — port `desktop/src/main/integration-installer.ts::install()` to a Kotlin counterpart (e.g. `IntegrationInstaller.kt` in `app/.../skills/`). For `setup.type === "plugin"` entries it should look up the plugin entry via `LocalSkillProvider`/`MarketplaceFetcher`, route through the existing `PluginInstaller` (clone + register in all four CC registries — that already works on Android for skills), then mirror `setup.postInstallCommand` back to the renderer. Write a test that installs the `google-services` integration on a fresh emulator and confirms the plugin appears in `~/.claude/plugins/marketplaces/youcoded/plugins/google-services/`.
  2. **Connect (OAuth)** — Android has no Electron `safeStorage` equivalent. Reuse the `EncryptedSharedPreferences` already wired for `marketplace:auth` (see `MasterKeys` usage near the top of `SessionService.kt`) for token-at-rest. The OAuth client config (client ID, scopes) is per-provider — start with one provider (Google Workspace) and copy the desktop flow's redirect-uri / device-code handling.
  3. **Uninstall + Status** — uninstall is the inverse of install + clear the encrypted token. Status reads the integrations manifest (`~/.claude/integrations.json` on desktop; either mirror to the same path or merge into `youcoded-skills.json`).
- **Tracking**: https://github.com/itsdestin/youcoded/issues/78
- **Priority**: medium (browse works; install fails loudly with a clear error message; users on phones get to see what's coming without silent breakage). Lift to high before promoting integrations from "Coming soon to Android" copy on any landing page.

## Analytics payload ↔ privacy copy must stay in sync (noticed 2026-04-24)
- **Claim**: Three surfaces each enumerate exactly what the analytics ping contains — the in-app Privacy section in `AboutPopup.tsx` (desktop + android branches), the landing-page FAQ in `youcoded/docs/index.html` ("Is my data private?"), and the spec at `docs/superpowers/specs/2026-04-23-privacy-analytics-design.md`. All three currently list: random install ID, app version, platform (+ OS on desktop), country.
- **Actual**: The authoritative list of fields is `AppEventPayload` in `wecoded-marketplace/worker/src/lib/analytics.ts`, with the client payloads constructed in `youcoded/desktop/src/main/analytics-service.ts` and `youcoded/app/src/main/kotlin/com/youcoded/app/analytics/AnalyticsService.kt`. If someone adds or renames a field in any of those three code sites without updating the three copy surfaces, the Privacy promise drifts from the code and user trust erodes silently.
- **Fix**: Every change that touches `AppEventPayload` shape, the desktop `payload` object, or the Android `payload` JSON must include matching edits to (a) `AboutPopup.tsx` (both platform branches), (b) the FAQ answer for "Is my data private?" in `youcoded/docs/index.html`, and (c) the three "Final copy" sections in the privacy-analytics spec. Run `/audit analytics` before shipping any change in this area.
- **Priority**: medium (silent drift risk; the worst outcome is claiming we don't collect something we do)

## CC-drift: Adopt PostToolUse updatedToolOutput for tool-output rewriting (surfaced 2026-04-29, from CC v2.1.123)

CC v2.1.121 expanded PostToolUse's hookSpecificOutput.updatedToolOutput so it works for ALL tools, not just MCP. YouCoded could use this from the bundled hooks (write-guard, hook-relay) to redact secrets, normalize paths, or annotate output before it reaches the LLM. Small-medium effort to wire into hooks-manifest.json and the hook-relay handlers; primary value is secret/PII redaction at the tool-output boundary. Currently no parallel facility.

CHANGELOG entry: CC v2.1.121 — PostToolUse hooks can now replace tool output for all tools via hookSpecificOutput.updatedToolOutput (previously MCP-only)

## CC-drift: Wrap claude ultrareview CLI in YouCoded admin skill (surfaced 2026-04-29, from CC v2.1.123)

CC v2.1.120 added `claude ultrareview [target]` as a non-interactive subcommand that prints findings to stdout (--json for raw) and exits 0/1 on completion/failure. YouCoded's existing /ultrareview admin skill is interactive only. Wrapping the new CLI lets the admin skill run review headlessly — useful for the release pipeline (auto-run before tag), nightly CI, or PR comment bots. Small effort to thread the subcommand into youcoded-admin/skills/release if desired.

CHANGELOG entry: CC v2.1.120 — Added claude ultrareview [target] subcommand to run /ultrareview non-interactively from CI or scripts — prints findings to stdout (--json for raw output) and exits 0 on completion or 1 on failure

## CC-verification: scrollback duplication, orphan-spinner, MCP-spawn, TaskList ordering (surfaced 2026-04-29, from CC v2.1.123)

Five CC v2.1.119–v2.1.121 fixes touch behaviors YouCoded code paths interact with. Static review at release time confirmed no code change is required, but post-release runtime verification was deferred:

- **TerminalView.tsx (xterm scrollback duplication)** — CC v2.1.120 + v2.1.121 fixed scrollback duplication on tmux/GNOME Terminal/Windows Terminal/Konsole resize/redraw. PITFALLS.md "Vendored Termux terminal-emulator" still documents "xterm scrollback can show duplicated TUI chrome" as a known issue. Verify on a long Android session and a long desktop session that previously exhibited the duplication. If gone, drop the bullet.
- **attention-classifier.ts (orphaned subagent spinner)** — CC v2.1.119 fixed spinner staying on when a subagent task notification was orphaned. YouCoded's classifier would have correctly tagged this as `thinking-stalled` after 10s. Post-fix the spinner should stop on its own; re-run `desktop/test-conpty/test-attention-states.mjs` against CC v2.1.123 and confirm `desktop/tests/attention-classifier-parity.test.ts` still passes.
- **claude-code-registry.ts (MCP plugin spawn on Windows)** — CC v2.1.119 fixed MCP servers from plugins not spawning on Windows when the plugin cache was incomplete. On a Windows test machine, install spotify-services via the marketplace UI and verify `/mcp` shows it Connected. If the workaround note in PITFALLS.md "MCP Plugin Authoring" no longer applies, drop it.
- **task-state.ts (TaskList ordering)** — CC v2.1.119 fixed TaskList returning tasks in arbitrary filesystem order instead of sorted by ID. Open the Open Tasks popup in a session with several tasks at mixed statuses; verify ordering is by ID ascending and that the chip count matches.

## CC-verification: install-prereq POSIX bash/curl probing + reg.exe absolute path (surfaced 2026-04-29, from review-platform)

`desktop/src/main/prerequisite-installer.ts` `installClaude` POSIX branch silently assumes `/bin/bash` exists and `curl` is on PATH; on stripped Linux distros (Alpine, certain container images) this can fail with raw stderr instead of clear "install bash + curl" guidance. Optional follow-up: probe with `runCommand('bash', ['--version'])` and `runCommand('curl', ['--version'])` first.

`refreshPath()` at line 152 invokes `reg query` without resolving `reg.exe` via `which` / PATHEXT. C:\Windows\System32 is reliably on PATH so this works in practice, but inherits Electron's snapshot of PATH at app launch — same vulnerability the rest of the file works around with `resolveCommand()`. Real fix would be to invoke C:\Windows\System32\reg.exe by absolute path.

