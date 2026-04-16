# Research — gws Slides Command Coverage (Docs-Only)

**Date:** 2026-04-16
**Pinned gws version assumed:** v0.22.5 (current stable, published 2026-03-31)

## Sources consulted

- https://github.com/googleworkspace/cli — repo root; README describes dynamic Discovery-driven command surface
- https://raw.githubusercontent.com/googleworkspace/cli/main/README.md — confirms `gws` reads Google's Discovery Service at runtime and builds the entire command tree dynamically
- https://raw.githubusercontent.com/googleworkspace/cli/main/skills/gws-slides/SKILL.md — authoritative list of top-level resources and methods for the Slides surface at v0.22.5 (frontmatter pins this version)
- https://raw.githubusercontent.com/googleworkspace/cli/main/CHANGELOG.md — single Slides-specific entry: "Fix Slides presentations.get failure caused by flatPath placeholder mismatch" (bug fix, not scope change)
- https://api.github.com/repos/googleworkspace/cli/releases — scanned release notes back through v0.22.x series; no release scoped/descoped Slides
- https://api.github.com/search/issues?q=slides+repo:googleworkspace/cli — two Slides-adjacent items, both parity-oriented, none report missing write capability
- https://developers.google.com/slides/api/reference/rest — background confirmation of what the three underlying API methods can do

## Supported subcommands

The `gws-slides` SKILL.md lists exactly three methods and one sub-resource under `presentations`:

| Subcommand | Supported? | Notes |
|-----------|-----------|-------|
| `gws slides presentations get <id>` | Yes | "Gets the latest version of the specified presentation." |
| `gws slides presentations create` | Yes | "Creates a blank presentation using the title given in the request." Body-only: content is ignored at creation. |
| `gws slides presentations batchUpdate` | Yes | One-size-fits-all mutation entrypoint. Covers adding slides, inserting text, replacing content, changing layouts/shapes, theming, speaker notes, thumbnails, and every other Slides write op. |
| `gws slides presentations pages <method>` | Yes (sub-resource) | "Operations on the 'pages' resource" — includes page `get` and `getThumbnail`. |
| `gws slides export` | No (not in Slides) | Slides API itself has no export method. Exporting to PDF is done via `gws drive files export --params '{"fileId":"...","mimeType":"application/pdf"}'`. |
| `gws slides list` | No | Listing belongs to Drive: `gws drive files list --params '{"q":"mimeType=\x27application/vnd.google-apps.presentation\x27"}'`. |

Architectural note: the command surface is not hand-coded. README's Architecture section describes two-phase parsing — `gws` reads the Slides Discovery document, then builds the `clap::Command` tree from its resources and methods. So whatever the Slides Discovery doc exposes, `gws slides` exposes. That Discovery doc has included `presentations.create`, `presentations.get`, `presentations.batchUpdate`, `presentations.pages.get`, and `presentations.pages.getThumbnail` since Slides API v1 launched in 2016 — nothing has been gated out.

## Release history

- v0.22.5 (2026-03-31) — current stable; SKILL.md frontmatter pins this version.
- CHANGELOG only Slides entry is the flatPath `presentations.get` bugfix. There is no "added Slides write support" entry because write support was never added separately — it came free with Discovery-driven dispatch the moment `slides` was recognized as a service.
- No releases have removed or feature-flagged Slides write methods.

## Verdict

**GREEN — Full write support.** `gws slides presentations batchUpdate` is the exact same entrypoint the official Google Slides API exposes for every mutation (add/delete/duplicate slides, replace text, insert shapes/tables/images, change layouts, update speaker notes, apply themes, etc.). `create` handles new decks, `get` handles reads, `pages.getThumbnail` handles previews. The one thing that sounds like a gap — PDF export — isn't a Slides API method in Google's own surface; it's a Drive `files.export` call with `mimeType: application/pdf`, which `gws drive` already supports.

## Recommendation

The Slides skill's SKILL.md should document this layout:

- **Create a deck:** `gws slides presentations create --json '{"title":"..."}'`
- **Read a deck:** `gws slides presentations get --params '{"presentationId":"..."}'`
- **Add slides / insert text / update content / change layout:** one or more requests inside a single `gws slides presentations batchUpdate` call. Point the skill at Google's `batchUpdate` request reference (`createSlide`, `insertText`, `replaceAllText`, `updatePageElementTransform`, `createShape`, `createImage`, `createTable`, `updateTextStyle`, `updateShapeProperties`, etc.). Recommend the skill include 2–3 recipe examples, because `batchUpdate` is powerful but verbose and agents tend to under-batch.
- **Export to PDF:** call `gws drive files export --params '{"fileId":"<presentationId>","mimeType":"application/pdf"}' --output deck.pdf`. Document this as a cross-service hop; the skill should mention the `gws-drive` skill as a dependency for export/list operations.
- **List decks:** `gws drive files list` with a mimeType filter. Same cross-service hop.

No "read-only" or "view/export only" disclaimer is needed. The v1 bundle can confidently offer full "create a slide deck about X" functionality to users.
