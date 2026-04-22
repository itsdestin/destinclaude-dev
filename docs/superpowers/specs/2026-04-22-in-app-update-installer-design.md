# In-App Update Installer — Design

> **Status:** Design approved 2026-04-22, awaiting implementation plan.
> **Base branch:** `feat/update-panel-popup` (local worktree, unpushed — the popup ships before this feature).
> **Target worktree:** `/c/Users/desti/youcoded-worktrees/update-installer/` (to be created during implementation).

## Goal

Replace the browser-open behavior of the update-panel popup's "Update Now" button with a one-click, in-app download-and-launch flow. The user clicks once; the app downloads the correct platform-specific installer to its own cache, shows progress in place, and on completion spawns the OS installer and quits. No more "open browser → find file in Downloads → double-click."

## Non-goals

- **Silent / fully-automatic updates** ("electron-updater" style). Out of scope for v1 — requires code signing on macOS (Developer ID + notarization) and publishing `latest.yml` metadata from the release workflow. Tracked as future work.
- **Integrity verification.** No SHA-256 or GPG verification in v1 because GitHub Releases don't currently publish sidecar checksums. Future work: start publishing `<asset>.sha256` in the release workflow and verify client-side.
- **Replacing the update-panel popup itself.** That feature lands separately on `feat/update-panel-popup`. This design assumes that popup exists and wires into its "Update Now" button.
- **Auto-update on Android.** Android ships via Play Store or direct APK sideload. Zero desktop-path impact; Android handlers are stubs only.

## Context

- **Current behavior (on master):** The StatusBar version pill (`desktop/src/renderer/components/StatusBar.tsx:877`) calls `window.claude.shell.openExternal(updateStatus.download_url)` when an update is available. User's browser opens the GitHub Release asset URL, downloads the installer to `~/Downloads`, and the user double-clicks it manually.
- **In-flight work (`feat/update-panel-popup` branch):** A new L2 popup `UpdatePanel.tsx` opens from the version-pill click. When `updateStatus.update_available` is true, it shows an "Update Now" button plus filtered changelog entries. The button's `handleUpdate` function (`UpdatePanel.tsx:66`) currently still falls back to `shell.openExternal(updateStatus.download_url)`. **This design replaces the body of that function.**
- **Asset resolution (already correct):** `ipc-handlers.ts:1192-1222` resolves `download_url` per-platform and per-architecture. macOS correctly differentiates `arm64` vs `x64` DMGs (fixed in commit `5f9e4f7`). Windows is x64 .exe NSIS. Linux prefers AppImage over .deb. Our installer consumes this resolved URL as-is and does not re-do arch detection.

## Architecture

One new main-process module `update-installer.ts` owns the full download-and-launch lifecycle. It exposes five IPC channels (parity rules apply — see `docs/shared-ui-architecture.md`):

- **`update:download`** (request-response) — start download of the current `cachedUpdateStatus.download_url`. Returns `{ jobId, filePath, bytesTotal }`. Idempotent: if a job is already in flight, returns the existing jobId. Internally branches on the dev fake-update flag (see "Testing → `YOUCODED_DEV_FAKE_UPDATE` extension").
- **`update:cancel`** (request-response) — abort the download for a jobId, delete the partial file.
- **`update:launch`** (request-response) — launch the platform installer for a completed jobId. Returns `{ success: true, quitPending: true }` when the installer was spawned and `app.quit()` is scheduled, `{ success: true, quitPending: false, fallback: 'browser' }` when the platform falls back to `shell.openExternal` and the app should stay running (Linux `.deb`, missing-`APPIMAGE` case), or `{ success: false, error: '<code>' }` on spawn error (no quit, no fallback).
- **`update:progress`** (push event, main → renderer) — `{ jobId, bytesReceived, bytesTotal, percent }`. Emitted at most every 250 ms or every 5 % boundary, whichever comes first.
- **`update:get-cached-download`** (request-response) — returns `{ filePath, version } | null`. Used when the user reopens the popup and a completed download is still in cache for the current `updateStatus.latest` version.

The renderer's `UpdatePanel.tsx` owns a small local state machine (`idle → downloading → ready → launching | error`). The morphing "Update Now / Downloading X % / Launch Installer / Retry" button is driven entirely by that state.

## Components

### New files

- `desktop/src/main/update-installer.ts` — lifecycle module.
- `desktop/src/main/__tests__/update-installer.test.ts` — unit tests (download, cancel, launch, error paths).
- `desktop/src/main/__tests__/update-install-ipc.test.ts` — parity test (extends pattern from the `update:changelog` parity test already in `feat/update-panel-popup`).
- `desktop/src/shared/update-install-types.ts` — shared types (`UpdateJob`, `UpdateProgress`, `UpdateError`, error code enum). Consumed by preload, renderer, and the main module.
- `app/src/main/kotlin/com/youcoded/app/runtime/UpdateInstallerStub.kt` — Kotlin stubs for all five message types, all returning `{ success: false, error: 'not-supported' }`.

### Modified files

- `desktop/src/main/ipc-handlers.ts` — register the five new IPC handlers. Hold a per-session subscriber map for progress push events.
- `desktop/src/main/preload.ts` — expose `window.claude.update.{ download, cancel, launch, onProgress, getCachedDownload }`. `onProgress` returns an unsubscribe function (standard pattern already used elsewhere in preload).
- `desktop/src/renderer/remote-shim.ts` — same shape for parity. Remote-browser clients receive stub implementations returning `{ success: false, error: 'remote-unsupported' }` — you cannot install a desktop binary from a browser into the desktop session.
- `desktop/src/renderer/components/UpdatePanel.tsx` — rewrite `handleUpdate`, add local state machine for button morphing and progress display. Subscribe to `onProgress` in a `useEffect`.
- `desktop/src/main/main.ts` — call `cleanupStaleDownloads()` on `app.whenReady()`.
- `app/src/main/kotlin/com/youcoded/app/runtime/SessionService.kt` — wire the five `when` cases in `handleBridgeMessage()` to `UpdateInstallerStub`.

## Data flow

### Happy path

```
User clicks "Update Now"
  renderer: state = downloading(0 %), button label = "Downloading 0 %…"
  renderer → main: window.claude.update.download()
                     ↓
  main: resolve URL from cachedUpdateStatus (NOT from renderer args — see Security)
  main: validate URL (HTTPS + domain allowlist)
  main: open writable stream to userData/update-cache/<derived-filename>.partial
  main: https.get(url) → stream to disk with progress events
  main → renderer: update:progress { jobId, percent: 42, … }
                     ↓
  renderer: button label = "Downloading 42 %…"
  main: stream end → atomic rename .partial → <filename>
  main → renderer: resolve { jobId, filePath, bytesTotal }
                     ↓
  renderer: state = ready(filePath), button label = "Launch Installer"

User clicks "Launch Installer"
  renderer: state = launching, button disabled
  renderer → main: window.claude.update.launch({ jobId })
                     ↓
  main: verify filePath still exists
  main: spawn platform installer (see "Platform mechanics")
  main: 500 ms timer → app.quit()
```

### Cache-hit path (user reopens popup with completed download on disk)

```
UpdatePanel mounts
  renderer → main: window.claude.update.getCachedDownload(updateStatus.latest)
                     ↓
  main: scan userData/update-cache/ for matching filename, verify exists
  main: resolve { filePath, version } | null
                     ↓
  renderer: if hit, state = ready(filePath), skip download step entirely
```

## Platform installer mechanics

`launchInstaller(jobId)` branches on `process.platform` and `process.arch`. Each branch verifies the file exists, spawns detached, captures synchronous spawn errors, and schedules `app.quit()` 500 ms after successful spawn.

### Windows (`.exe` NSIS)

```ts
const child = spawn(filePath, [], {
  detached: true,
  stdio: 'ignore',
  windowsHide: false, // installer needs its own window
});
child.unref();
```

- NSIS handles its own UAC elevation prompt.
- Child process is not linked to our job object, so `app.quit()` does not kill it.
- NSIS installer displays a "Launch YouCoded" checkbox at the end — relies on electron-builder's default `oneClick: false, allowToChangeInstallationDirectory: false` config. **Implementation task: verify this in the electron-builder config (either `electron-builder.yml` or the `build` field inside `desktop/package.json`) and document if anything needs tweaking.**
- **No code signing today.** SmartScreen may nag on unsigned `.exe` — same as today's browser flow. When a code-signing cert is added later, zero changes needed on the installer side (build-time concern only).

### macOS (`.dmg`)

```ts
const child = spawn('open', ['-W', filePath], {
  detached: true,
  stdio: 'ignore',
});
child.unref();

// Listen for spawn error or quick non-zero exit (malformed DMG etc.)
// for up to 2 s before firing app.quit().
```

- `-W` = wait for the opened app/DMG to exit before `open` itself exits. Enables error detection: `open` returns exit code ≠ 0 quickly if the DMG is corrupt or the path is wrong.
- After the user drags the .app to Applications and ejects the DMG, they double-click the new YouCoded. Same as today's browser flow.
- **Gatekeeper:** The DMG downloaded by Node's `https.get` is not quarantined (`https.get` is not a Gatekeeper-aware download client — same behavior as electron-updater's default). The new .app extracted from it inherits no quarantine xattr. First-launch Gatekeeper warning is **at worst** the same as today.
- **Do NOT** manually strip or add `com.apple.quarantine` (`xattr -d` etc.). Behave as a well-mannered citizen.
- **Do NOT** unpack the DMG, mount via `hdiutil` directly, or copy the .app to `/Applications` programmatically. That is the "full-automatic" path which risks Gatekeeper / LaunchServices issues without signing.
- **Arch:** URL arrives already arch-matched from `ipc-handlers.ts:1206-1216`. Installer does NOT re-do arch detection. If the user is running Intel-on-Rosetta on Apple Silicon, they continue to get Intel DMGs — same behavior as the browser flow and correct (DMG matches the binary they're running).

### Linux AppImage

```ts
const appImagePath = process.env.APPIMAGE; // path of running AppImage
if (!appImagePath || !fs.existsSync(appImagePath)) {
  // Graceful fallback — not an error. App stays running, user installs manually.
  shell.openExternal(cachedUpdateStatus.download_url);
  return { success: true, quitPending: false, fallback: 'browser' };
}
fs.chmodSync(downloadedPath, 0o755);
try {
  fs.renameSync(downloadedPath, appImagePath); // must be same filesystem
} catch (e) {
  if (e.code === 'EXDEV') {
    // Cross-filesystem — copy + unlink instead
    fs.copyFileSync(downloadedPath, appImagePath);
    fs.unlinkSync(downloadedPath);
  } else if (e.code === 'EACCES' || e.code === 'EPERM') {
    throw new InstallError('appimage-not-writable');
  } else {
    throw e;
  }
}
app.relaunch();
app.quit();
```

- Linux kernel allows replacing an open file; the running process keeps its old inode until exit.
- `fs.renameSync` is atomic within the same filesystem. `EXDEV` (cross-filesystem) handled by copy + unlink.
- `EACCES` / `EPERM` (AppImage lives in a root-owned location, e.g. `/opt`) surfaces as `appimage-not-writable` — the error state shows the usual Retry + browser fallback. Same net UX as today's browser flow, which also requires the user to manually replace the binary.
- No elevation required for the happy path (user-owned AppImage).

### Linux .deb fallback

```ts
shell.openExternal(cachedUpdateStatus.download_url);
return { success: true, quitPending: false, fallback: 'browser' };
// Popup copy: "Debian package — install manually with `sudo dpkg -i <file>`."
```

- Same as current behavior. Popup closes; the app stays running while the user installs the .deb from their browser's download UI. Flagged in popup copy so the user understands why this specific path differs.

### Error → fallback chain (all platforms)

```
launchInstaller error
  → renderer state: error(code)
  → button: "Launch failed — Retry"
  → secondary link: "Open in browser instead"
      → window.claude.shell.openExternal(updateStatus.download_url)
      → onClose()
```

(The renderer has `updateStatus.download_url` directly in its props — no extra round-trip to main.)

Error codes (enumerated in `update-install-types.ts`):

- `spawn-failed` — `spawn()` threw or child exited non-zero within 2 s
- `file-missing` — the download file does not exist on disk
- `appimage-not-writable` — `EACCES` / `EPERM` replacing a root-owned AppImage
- `dmg-corrupt` — `open -W` exited with non-zero (macOS)
- `unsupported-platform` — platform/arch combination we don't handle
- `remote-unsupported` — attempted from a remote-browser session
- `network-failed` — download failed mid-stream
- `disk-full` — `ENOSPC` during write
- `url-rejected` — failed HTTPS / domain allowlist check (security)

(Note: `appimage-not-detected` and `.deb` are **not** errors — they short-circuit to `fallback: 'browser'` with `shell.openExternal` and a transient popup close. The app keeps running. See platform mechanics above.)

## Security

- **HTTPS-only.** `update:download` refuses any URL not starting with `https://`. Coverage: `https.get` auto-upgrades behavior is off; we never follow a redirect to an `http://` target.
- **Domain allowlist.** URL host must be `github.com` or `objects.githubusercontent.com` (GitHub's release-asset CDN). Blocks a malicious metadata response from redirecting us to a third-party binary.
- **Safe filename derivation.** Filename comes from the URL path's basename, sanitized: no `..`, no path separators, extension whitelisted to `.exe | .dmg | .AppImage | .deb` per platform. Prevents path traversal into the userData dir.
- **Redirect cap.** Reuse the redirect-capping approach already in `changelog-service.ts`. Max 5 redirects; every redirect target re-validated against HTTPS + domain allowlist.
- **URL is resolved main-side.** The renderer's `update:download` call takes **no URL argument**. The main handler reads `cachedUpdateStatus.download_url` (populated by the trusted GitHub API fetch in `ipc-handlers.ts:1192+`) and uses it directly. Renderer cannot spoof the download target.
- **No xattr manipulation on macOS.** See "Platform mechanics → macOS".
- **No integrity verification in v1.** Explicit non-goal; tracked as future work.

## Cleanup

`cleanupStaleDownloads()` runs on `app.whenReady()`:

1. Create `userData/update-cache/` if missing.
2. Delete any `*.partial` file (assumed abandoned).
3. Delete any non-partial file whose `mtime` is older than 24 hours (assumed installed already).

Also: closing the update popup mid-download triggers `update:cancel` on the active job — the user's implicit signal they don't want to update right now. No partial-recovery / resume logic. If they reopen later, they start fresh.

## Edge cases

1. **Popup closed mid-download** → cancel the download, unlink `.partial`.
2. **Popup dismissed after download completes, before launch** → installer stays in cache for 24 h. Reopening the popup (same `updateStatus.latest`) detects the file via `getCachedDownload` and skips straight to `ready` state. If a newer release came out in the interim, old file is swept by startup cleanup and new download starts.
3. **Corrupted download (file exists but not runnable)** → caught at `launchInstaller` spawn error. Error state with Retry + browser fallback.
4. **Disk full** → `ENOSPC` → `disk-full` error with copy: *"Not enough space to download update (need ~150 MB)."* Plus browser fallback link.
5. **Running from `npm run dev` (unpackaged)** → Update Now button hidden entirely. Gated on `!app.isPackaged` in the popup.
6. **Multiple YouCoded instances** (e.g., `run-dev.sh` side-by-side with prod) → each has its own `userData`, no cache collision. No special handling.
7. **Second click on "Update Now" while `ready`** → treat as "Launch Installer" click, go straight to launch.
8. **User's network blocks GitHub** → download fails with `network-failed` → browser fallback also fails; user is no worse off than the current flow.

## Testing

### Automated (Vitest, main-process)

**`update-installer.test.ts`** covers:

- Rejects non-HTTPS URLs with `url-rejected`.
- Rejects URLs outside the GitHub domain allowlist with `url-rejected`.
- Rejects unsafe filenames (`..`, slashes, wrong extension).
- Filename derivation picks the right extension per platform.
- Progress events throttle correctly (emit on 250 ms or 5 % threshold; not per chunk).
- `cancelDownload` unlinks `.partial`, aborts the stream cleanly.
- Simultaneous `startDownload` calls return the same jobId (single-job invariant).
- On spawn error, `launchInstaller` surfaces the error instead of quitting.
- `cleanupStaleDownloads` deletes `.partial` files and files older than 24 h; leaves fresh files.

**`update-install-ipc.test.ts`** — parity check (extends the `update:changelog` parity test already on `feat/update-panel-popup`). Asserts all five new message types (`update:download`, `update:cancel`, `update:launch`, `update:progress`, `update:get-cached-download`) appear in `preload.ts`, `remote-shim.ts`, `ipc-handlers.ts`, and the Android stub.

Mock the network with `undici`'s `MockAgent` or a local HTTPS server. Tests do not hit real GitHub.

### Manual test matrix

| Platform | Scenario | Expected |
|---|---|---|
| Windows | Fake-update flag → Update Now → Launch | NSIS installer launches, app quits, installer completes, new version runs |
| macOS arm64 | Fake-update → Update Now → Launch | DMG mounts in Finder, user drags to Applications, new version runs |
| macOS x64 (or Rosetta) | Fake-update → Update Now → Launch | x64 DMG used, mounts, installs correctly |
| Linux AppImage | Fake-update → Update Now → Launch | AppImage replaced in place, app relaunches on new version |
| Linux .deb (if tested) | Click Update Now | Browser opens .deb download page (fallback path) |
| Any | Network drop mid-download | Error state shows retry + "Open in browser" link |
| Any | Cancel while downloading | `.partial` removed, button returns to "Update Now" |
| Any | Reopen popup after completed download | Button reads "Launch Installer" immediately; no re-download |

### `YOUCODED_DEV_FAKE_UPDATE` extension

The `feat/update-panel-popup` branch already gates a dev-only fake-update flag on `!app.isPackaged`. Extend it:

- When set, `update:download` serves a bundled ~1 MB dummy installer from `desktop/dev-assets/fake-installer.<ext>` instead of fetching from GitHub.
- On "Launch" in dev mode, invoke `shell.showItemInFolder(filePath)` on the dummy instead of spawning it. Prevents accidentally launching real installers during development.

## Future work (out of scope for v1)

- **SHA-256 checksum verification.** Publish `<asset>.sha256` sidecars in the release workflow; fetch alongside the main asset; verify before `launchInstaller`. Requires changes to `.github/workflows/desktop-release.yml` in the youcoded repo.
- **Silent install on Windows.** Add `[/S]` flag spawn path; verify NSIS config supports it; consider an optional "Restart automatically when update completes" user preference.
- **`electron-updater` / silent updates.** Requires Mac code signing + notarization, `latest.yml` publishing, and probably Windows code signing too. Substantial infrastructure work; revisit once signing is in place for other reasons.
- **Progressive rollout.** If in-app update proves unstable, consider a kill-switch that falls back to browser flow based on a server-side flag.
