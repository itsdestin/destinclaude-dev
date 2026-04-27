# Build Order & Release Flows

Release builds happen through GitHub Actions CI in the relevant sub-repo. Day-to-day iteration on desktop changes runs locally — see `docs/local-dev.md` and the **Local dev loop** section below.

## Build order dependencies

### React UI bundle is auto-rebuilt by Gradle
Located at `youcoded/scripts/build-web-ui.sh`. Runs `npm ci && npm run build` in `desktop/`, then copies `desktop/dist/renderer/` into `app/src/main/assets/web/`. The `bundleWebUi` task in `app/build.gradle.kts` invokes this script before `preBuild` whenever any input changes (`desktop/src/`, `package-lock.json`, `vite.config.ts`, etc.). Kotlin-only iterations are skipped as UP-TO-DATE.

If skipped (manual `-x bundleWebUi`, build break in `npm run build`, etc.), the Android app launches with a blank WebView — `index.html` references JS/CSS bundles that aren't in `assets/web/assets/`.

The Android release workflow (`android-release.yml`) still invokes the script as an explicit pre-step. With the Gradle task in place that's redundant on cold-cache CI runs (Gradle re-runs the work) but harmless, and acts as a safety net if anyone disables the Gradle task.

### Desktop version comes from git tag, not package.json
CI extracts version from the `vX.Y.Z` tag and patches `package.json` before building (`desktop-release.yml:40-46`). Local `package.json` version is not the source of truth.

### Android version requires manual bump
Both `versionCode` (integer, monotonically increasing for Play Store) and `versionName` (string) must be bumped in `app/build.gradle.kts` **before** tagging. CI does not derive Android versions from the tag — Play Store requires `versionCode` to always increase, so it cannot be derived.

Current: `versionCode = 17`, `versionName = "1.2.1"` (app/build.gradle.kts:23-24).

### One tag, all platforms
A single `vX.Y.Z` tag in youcoded triggers both `android-release.yml` and `desktop-release.yml`. Both upload artifacts (APK/AAB + Win/Mac/Linux installers) to the same GitHub Release.

## Release flows

### App (Desktop + Android)
1. Bump `versionCode` + `versionName` in `youcoded/app/build.gradle.kts`
2. Tag `vX.Y.Z` in youcoded on master
3. Both platform workflows trigger → single GitHub Release with all artifacts

### Toolkit (youcoded-core)
1. Bump `version` field in `youcoded-core/plugin.json` on master
2. `auto-tag.yml` compares `HEAD` vs `HEAD~1` plugin.json versions
3. If changed, creates `vX.Y.Z` tag automatically

## Local dev loop (desktop)

The supported way to iterate on desktop changes while the installed/built app stays open for real work:

```bash
bash scripts/run-dev.sh
```

- Launches a second Electron window labelled **YouCoded Dev**
- Shifts ports via `YOUCODED_PORT_OFFSET=50` (Vite 5173 → 5223, remote 9900 → 9950)
- Splits Electron `userData` via `YOUCODED_PROFILE=dev` so dev's localStorage / cookies / window bounds don't clobber the built app's
- Shares `~/.claude/` with the built app intentionally (plugins, settings, memory) so dev tests against real state — `write-guard.sh` and `.sync-lock` prevent corruption; expect occasional `WRITE BLOCKED` messages as normal friction

First time only: `cd youcoded/desktop && npm ci` to install deps. After that `scripts/run-dev.sh` is a one-shot command.

See `docs/local-dev.md` for caveats (plugin install shares state with built app, OneDrive path warning, remote-access UI is read-only in dev).

## Local verification (typecheck + CI-style build)

When you need to confirm something compiles or passes tests — not just runs:

```bash
# Desktop
cd youcoded/desktop && npm ci && npm test && npm run build

# Android
cd youcoded && ./gradlew assembleDebug && ./gradlew test

# Build Android React UI from desktop source (required before APK)
cd youcoded && ./scripts/build-web-ui.sh
```
