# Discrete GPU Toggle (Performance settings)

**Date:** 2026-04-26
**Status:** Design — pending implementation plan
**Scope:** YouCoded app (Desktop + Android). No changes to `youcoded-core`, `wecoded-themes`, `wecoded-marketplace`, or `youcoded-admin`.

## Summary

Many users have laptops with both an integrated GPU (Intel Iris Xe, AMD Radeon iGPU, etc.) and a discrete GPU (NVIDIA GeForce, AMD Radeon discrete, etc.). Today YouCoded ships no GPU preference, which on Windows often means Chromium binds to the integrated GPU. The integrated GPU shares thermal and power budget with the CPU and carves dedicated allocations out of system RAM, so iGPU saturation cascades into CPU thermal throttling and squeezed memory — even when the discrete GPU is sitting idle.

This design adds a new **Performance** section to `SettingsPanel.tsx` exposing a single user pref, `preferPowerSaving: boolean`, that controls whether YouCoded passes Chromium's `force-high-performance-gpu` switch (default) or `force-low-power-gpu` (opt-in) at startup. The section is hidden on systems where Chromium reports only one GPU. An `(i)` info popup explains the GPU framing and lists OS-level overrides for users who want finer-grained control.

## Goals & non-goals

**Goals:**
- Default new and existing installs to discrete-GPU mode for measurable perf gains across an estimated majority of laptop users
- Provide a clear opt-out for battery-conscious users
- Frame the explanation around GPU choice as the root cause, since most performance complaints actually trace back to it
- Cross-platform parity (Desktop + Android), per the shared-React-UI invariant — Android renders nothing because detection always returns single-GPU

**Non-goals:**
- Per-window GPU choice (not supported by Chromium)
- Linux env-var-based discrete GPU binding (`__NV_PRIME_RENDER_OFFLOAD=1`, `prime-run`) — documented as a manual workaround only
- A "test my GPU" benchmarking button
- Telemetry on which mode users pick — not worth a new analytics event type
- Auto-detecting battery state and switching modes — Chromium can't switch GPU at runtime, and auto-relaunching would be terrible UX
- Bundling other perf controls (e.g. `disableHardwareAcceleration`, glassmorphism kill-switch) into this section in the same pass; the schema reserves room for them but ships only the GPU toggle

## Default behavior and migration

On startup, the main process reads `~/.claude/youcoded-performance.json`. If the file is missing OR `preferPowerSaving === false`, the main process calls `app.commandLine.appendSwitch('force-high-performance-gpu')` before `app.whenReady()`. If `preferPowerSaving === true`, it calls `app.commandLine.appendSwitch('force-low-power-gpu')` instead.

**This means existing users who never open the setting silently get the discrete-GPU upgrade on the next launch after this version ships.** No migration prompt, no first-launch banner. The change is documented in the changelog.

## User flow

### Settings entry

A new section appears in `SettingsPanel.tsx`, positioned **after Appearance and before Sync**:

```
─── Performance ────────────────────  [(i) info icon]

GPU choice affects performance.

  [○] Prefer power saving
      Use the integrated GPU instead of the discrete one.
      Saves battery, but UI animations may stutter.

  [Inline notice — only visible when saved !== draft]
  ⟳ Restart YouCoded to apply.        [ Restart now ]

  Detected GPUs: Intel Iris Xe Graphics, NVIDIA GeForce RTX 4070 Laptop GPU
```

The section is **hidden** when `multiGpuDetected === false` (single-GPU systems and detection-failure case both fall through to hidden — the failure case logs a warning so we can debug if a multi-GPU user reports a missing toggle).

The "Detected GPUs" line uses small `text-fg-muted` styling. It confirms detection worked and reassures power users which device they'll be on. Names come from `gpuList` in the IPC response.

### Toggle interaction

- The entire toggle row is the click target (existing SettingsPanel pattern).
- Toggling immediately persists to `~/.claude/youcoded-performance.json` via `performance:set-config`. The Chromium switch does NOT apply at runtime — graphics binding is set at app launch.
- The inline "Restart YouCoded to apply" notice + "Restart now" button is visible whenever `saved !== appliedAtLaunch`, where `appliedAtLaunch` is the value that was on disk when the running app started. If the user toggles back to the launch-time value before restarting, the notice and button disappear automatically.
- "Restart now" invokes `app:restart` IPC → `app.relaunch(); app.exit(0)`. No confirmation dialog (the user explicitly clicked Restart).
- "Restart now" is styled as a primary action button, not a destructive button — restart is disruptive but not destructive.

### `(i)` info popup

Follows the established `REMOTE_ACCESS_EXPLAINER` pattern: an intro paragraph followed by labeled sections.

**Intro:**

> Your laptop has more than one graphics processor (GPU). YouCoded uses the more powerful one by default for smoother chat, terminal scrolling, and theme effects. If your laptop runs hot or your battery drains faster than you'd like, you can switch to power-saving mode here — but most performance issues actually trace back to GPU choice, so try this before reaching for other settings.

**Section: Why YouCoded uses the discrete GPU.**

> Integrated GPUs share system memory and thermal budget with your CPU. When the integrated GPU works hard, your CPU slows down too — they're physically the same chip and they share the cooling system. So a slow GPU often shows up as both slow rendering AND a slow CPU.
>
> YouCoded also runs more concurrent visual work than most apps: each chat session has its own terminal, themes can include animated wallpapers and blur effects, and the chat history scrolls smoothly. On a laptop with a discrete GPU, that work belongs on the discrete card — it has its own memory and cooling and won't compete with everything else your computer is doing.

**Section: Other places to look for power savings.**

- **Themes:** Pick a theme without glassmorphism / blur, or enable Reduced Effects in Appearance — biggest GPU savings after this toggle.
- **Close unused sessions:** Each Claude session uses memory and a terminal, even when idle.
- **Windows:** Settings → System → Display → Graphics → add `YouCoded.exe` → set "High performance" or "Power saving" per app. The OS setting overrides this toggle.
- **macOS:** Apple Silicon switches automatically. On Intel Macs, System Settings → Battery → "Automatic graphics switching" controls this globally.
- **Linux (NVIDIA Optimus):** Use `prime-run` or set `__NV_PRIME_RENDER_OFFLOAD=1` when launching YouCoded. Chromium's switch alone doesn't reach the NVIDIA driver.

**Section: Why a restart is needed.**

> Graphics binding is set when YouCoded launches. Toggling at runtime would require throwing away the current GPU context and reinitializing every window, which Electron doesn't support. Restart is the clean path.

## Architecture

### Persistence

**File:** `~/.claude/youcoded-performance.json`

```json
{ "preferPowerSaving": false }
```

The schema is intentionally tiny — one key — but the file is named `youcoded-performance.json` (not `youcoded-gpu.json`) so future performance prefs (`disableHardwareAcceleration`, glassmorphism kill-switch, etc.) can land here without renaming.

Lives alongside `youcoded-remote.json`, `youcoded-favorites.json`, `youcoded-skills.json` in `~/.claude/`. Sync-included by default since `~/.claude/` is the sync root.

### Main process startup flow

In `desktop/src/main/main.ts`, **before `app.whenReady()`** (current line ~994):

1. Synchronously read `~/.claude/youcoded-performance.json`.
   - Missing file → treat as `{ preferPowerSaving: false }`.
   - Unparseable JSON → treat as `{ preferPowerSaving: false }`, log a warning.
   - Schema-validate. Unknown keys are preserved on next write (forward-compat). A non-boolean `preferPowerSaving` is coerced to `false`.
2. Apply switch:
   - `preferPowerSaving === true` → `app.commandLine.appendSwitch('force-low-power-gpu')`
   - `preferPowerSaving === false` → `app.commandLine.appendSwitch('force-high-performance-gpu')`
   - Mutually exclusive — exactly one switch is applied per startup.
3. After `app.whenReady()`, call `app.getGPUInfo('complete')`. Cache `{ multiGpuDetected: gpuDevices.length > 1, gpuList: [...names] }` in a module-level variable. On rejection or empty `gpuDevices`, set `multiGpuDetected = false` and log the error to `~/.claude/youcoded.log`.

This logic lives in a new `desktop/src/main/performance-config.ts` module: small, focused, easy to unit-test.

### IPC surface

Three new channels, added to all four parity sites (`preload.ts`, `remote-shim.ts`, `ipc-handlers.ts`, `SessionService.kt`):

- `performance:get-config()` → `{ preferPowerSaving: boolean, appliedAtLaunch: boolean, multiGpuDetected: boolean, gpuList: string[] }`
  - `preferPowerSaving` is the current on-disk value.
  - `appliedAtLaunch` is the value the main process read at startup and applied as a Chromium switch. Constant for the process lifetime.
- `performance:set-config({ preferPowerSaving })` → `{ ok: true }`
  Writes the JSON file. Does NOT apply at runtime — UI is responsible for the restart prompt.
- `app:restart()` → calls `app.relaunch(); app.exit(0)`. Generic name, not `performance:restart`, so future settings that need restart can reuse it.

**Android (`SessionService.kt`):** Both `performance:get-config` and `performance:set-config` are stubs. `get-config` returns `{ preferPowerSaving: false, appliedAtLaunch: false, multiGpuDetected: false, gpuList: [] }`. `set-config` returns `{ ok: true }` (no-op write — Android has no userland GPU choice). `app:restart` is a no-op for now (Android session lifecycle is different — a restart equivalent would be killing and respawning the SessionService, not in scope for this design). The renderer hides the section when `multiGpuDetected === false`, so Android users never see it — but the IPC parity test stays green.

### Renderer state

A new `usePerformanceConfig()` hook in `desktop/src/renderer/hooks/`:

- Reads on mount via `performance:get-config`.
- Holds `{ saved, appliedAtLaunch, gpuList, multiGpuDetected }`.
- The toggle calls `performance:set-config` immediately — there is no separate "draft" state. The new value updates `saved` synchronously (optimistically) and the request is in-flight in the background; if it fails, revert `saved` and surface a small error.
- `appliedAtLaunch` is the value the main process read at startup and used to set the Chromium switch. It does not change for the lifetime of the process. The "Restart to apply" notice is visible whenever `saved !== appliedAtLaunch`.
- `performance:get-config` therefore returns three independent fields beyond detection: the current on-disk `preferPowerSaving` (used as `saved`), `appliedAtLaunch`, and `multiGpuDetected`/`gpuList`.

### Detection caveats

- `app.getGPUInfo('complete')` can take ~1-2s on first call. Run it once after `app.whenReady()` and cache; do not block window creation on it.
- Until cached, `performance:get-config` returns `multiGpuDetected: false` (section hidden, pessimistic).
- Once cached, push a `performance:config-changed` event so the renderer re-renders the section if it had been hidden.
- On Windows Optimus laptops where iGPU is "hidden" by the discrete GPU's driver, Chromium may report only one device. Treat enumeration as authoritative; if a user reports the toggle is missing on a known multi-GPU laptop, the log entry helps diagnose.

## Cross-platform behavior

- **Windows:** `force-high-performance-gpu` is a hint to the OS. Per-app preference in Settings → System → Display → Graphics overrides it. NVIDIA Control Panel global/per-app profile may also override. The explainer covers this honestly so users don't blame the toggle if the OS setting wins.
- **macOS Apple Silicon:** Single GPU — section is hidden by detection. No-op.
- **macOS Intel with discrete GPU:** Switch works via Electron's internal `NSSupportsAutomaticGraphicsSwitching=NO` mechanism when `force-high-performance-gpu` is set.
- **Linux (NVIDIA Optimus):** The Chromium switch alone doesn't bind to the NVIDIA card — that requires `__NV_PRIME_RENDER_OFFLOAD=1` env vars set before launch. The toggle still flips the pref, the explainer points users to `prime-run`. **Re-execing YouCoded with discrete-GPU env vars on Linux is explicitly out of scope** — possible follow-up.
- **Linux (AMD / Intel only):** Single GPU — section is hidden.
- **Android:** Section never renders.

## Edge cases

1. **GPU enumeration fails or returns empty.** `app.getGPUInfo('complete')` either rejects or returns `gpuDevices: []`. Fallback: `multiGpuDetected = false`, hide the section. Log a warning to `~/.claude/youcoded.log` with the raw error so it's diagnosable later. Better to hide a useful toggle than show a broken one.
2. **GPU enumeration is slow.** See "Detection caveats" above — cached after first successful call, optional re-render via `performance:config-changed`.
3. **User edits the JSON file directly.** Schema-validate on read. Unknown keys are preserved on next write. A non-boolean `preferPowerSaving` is coerced to `false`.
4. **Sync conflicts across devices.** The file syncs across devices via `~/.claude/`. Different machines may have different GPU layouts — that's fine, the *value* syncs but *whether the toggle is shown* depends on local detection. A device with no discrete GPU silently uses the synced value (which has no effect there) and does not display the section. Correct behavior.
5. **`force-high-performance-gpu` and `force-low-power-gpu` set together.** Mutually exclusive — the apply step picks exactly one.
6. **Dev mode (`run-dev.sh`).** Same logic applies. The dev instance's `userData` is split (`youcoded-dev` profile) but `~/.claude/youcoded-performance.json` is shared with the built app. Acceptable — dev iteration shouldn't need its own GPU pref.
7. **First launch with no preference file.** Switch defaults to `force-high-performance-gpu`. No prompt, no banner.

## Testing strategy

- **Unit:** `performance-config.test.ts` for the JSON read/parse/validate logic. Cases: missing file, empty file, malformed JSON, valid `true`, valid `false`, non-boolean coerced, unknown keys preserved on write.
- **IPC parity:** Add `performance:get-config`, `performance:set-config`, `app:restart` to `desktop/tests/ipc-channels.test.ts` — must appear in `preload.ts`, `remote-shim.ts`, `ipc-handlers.ts`, and `app/.../runtime/SessionService.kt`.
- **Detection:** Manual on the dev box (multi-GPU laptop) — verify `gpuList` contains both Iris Xe and RTX 4070, section renders, "Detected GPUs" line populates. Mock single-GPU detection in a unit test by stubbing `getGPUInfo`.
- **Switch application:** Smoke test that imports the startup module and asserts `app.commandLine.hasSwitch('force-high-performance-gpu')` for default, `force-low-power-gpu` after writing `{ preferPowerSaving: true }` to the test config path.
- **No automated test for actual GPU binding** — that's an OS/driver concern. Manual verification on the dev box: open Task Manager → GPU tab → confirm `YouCoded.exe` shows on the RTX 4070 with default config, on Iris Xe after toggling power saving + restart.
- **Restart UX:** Manual smoke test — toggle, see notice, click Restart, confirm relaunch and that the new switch applied (verifiable via `app.commandLine.hasSwitch` exposed for the test, or via Task Manager GPU tab).

## Open questions

None — all clarifying questions have been resolved during brainstorming. Implementation plan can proceed.

## Risks

- **Default-on may surprise some users.** Mitigation: explainer clearly documents what's happening; toggle is one click away. Trust the changelog and the in-app discoverability.
- **Chromium GPU enumeration on edge-case Windows Optimus drivers may misreport single GPU.** Mitigation: log enumeration result; if a user reports the toggle missing, the log entry diagnoses the case. Workaround for the user: Windows OS-level Graphics setting still works.
- **Linux NVIDIA users may toggle and see no effect** because the env-var-based path isn't implemented. Mitigation: explainer specifically calls this out and points to `prime-run`. Future work captures the actual fix.
