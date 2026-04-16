# ADR 005: Single vX.Y.Z Tag Triggers Both Platform Releases

**Status:** Accepted
**Date:** 2026-Q1 (unified-release-tags branch)

## Context

YouCoded ships both a desktop app (Windows/Mac/Linux via Electron) and an Android app. Originally, desktop used `desktop-v*` tags and Android used `android-v*` tags. This created confusion: users would see "v2.3.1 desktop" and "v2.3.0 Android" and ask which to install.

## Decision

Unify on `vX.Y.Z` tags. A single tag in youcoded triggers both `android-release.yml` and `desktop-release.yml`, and both workflows upload artifacts to the same GitHub Release.

- **Desktop**: CI extracts version from the tag (`v2.3.2` → `2.3.2`) and patches `desktop/package.json` before build
- **Android**: `versionName` matches the tag; `versionCode` (integer) must be manually bumped in `app/build.gradle.kts` BEFORE tagging

## Alternatives Considered

- **Keep separate tag conventions** — user confusion was too high
- **Derive versionCode from tag (e.g., hash → int)** — Play Store requires monotonically increasing integers; hash wouldn't guarantee this
- **Calendar-based versionCode** (yyyymmdd) — works, but breaks if you release twice in one day

## Consequences

**Good:**
- Users see one release per version with all platform artifacts
- Desktop version is automatically correct — no manual `package.json` bumps needed
- Tight coupling is enforced — desktop v2.3.2 and Android v2.3.2 always ship together

**Bad:**
- Android `versionCode` must still be bumped manually (can't be derived from tag due to Play Store monotonic requirement)
- Forgetting the `versionCode` bump causes Play Store to silently reject the upload — known pitfall, documented in PITFALLS.md
- Platform-specific bugs require coordination: can't ship a desktop-only hotfix without also producing an Android build
- Lessons from v2.3.0 release showed the `auto-tag` mechanism was fragile with this pattern — see memory entry `project_release_lessons_2_3_0`
