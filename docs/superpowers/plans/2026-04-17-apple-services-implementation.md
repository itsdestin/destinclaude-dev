# Apple Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the `apple-services` marketplace bundle — Claude access to Apple Calendar, Reminders, Contacts, Notes, Mail, and iCloud Drive via a single `/apple-services-setup` command and a uniform skill surface.

**Architecture:** Work spans two repos. Sibling `itsdestin/apple-helper` (new) holds Swift source that compiles into a universal Mach-O; its CI builds on `apple-helper-v*` tags and opens a PR into `wecoded-marketplace` vendoring `bin/apple-helper` + `.sha256` into the plugin tree. Plugin tree `wecoded-marketplace/apple-services/` ships the binary + vendored AppleScript + single `apple-wrapper.sh` dispatching to helper/osascript/filesystem by integration + umbrella and per-op SKILL.md files + the setup command. Setup copies the binary to `~/.apple-services/bin/apple-helper` (stable, plugin-independent path) so TCC grants survive plugin updates.

**Tech Stack:** Swift 5.9+, ArgumentParser (`apple/swift-argument-parser`), EventKit, Contacts framework, AppleScript (`osascript`), bash, shellcheck, GitHub Actions.

**Prerequisites (read before starting):**
- Design spec: `docs/superpowers/specs/2026-04-17-apple-services-design.md` (revised post-Phase-0)
- Phase 0 research findings: `docs/superpowers/plans/research/2026-04-17-apple-*.md` (9 files)
- macOS 14+ host for local verification (Phases 1, 2, 4 require a Mac)
- `gh` CLI authenticated to the `itsdestin` org (can create repos + PRs)
- `swift --version` reporting 5.9+ (for local Swift helper dev)
- `shellcheck` and `jq` installed locally (`brew install shellcheck jq`)

**Phase 0 findings that reshape this plan:**
- **R1** — iMCP is MIT (not Apache-2.0); `mattt/iMCP` not `loopwork/iMCP`. License-text references below use MIT.
- **R2** — iMCP is an Xcode project, not SwiftPM. Only 9 of 23 ops are covered by its exposed methods. Our strategy is **iMCP-as-reference**: we write EventKit/Contacts calls directly in `Sources/AppleHelper/*.swift`, crediting iMCP in NOTICE.md for patterns we learned from. No `Sources/FromIMCP/` directory is created.
- **R4** — Dhravya AppleScript is embedded in TypeScript (`utils/notes.ts`, `utils/mail.ts`). Extraction = manual. Several list-returning paths return empty arrays upstream — we rewrite those using **JXA** (JavaScript for Automation) which emits real JSON.
- **R6** — CI output path is `.build/apple/Products/Release/<product>`, not `.build/release/`. Matrix + lipo not needed; single `swift build --arch arm64 --arch x86_64` produces the universal Mach-O.
- **R7** — Better Mail first-run probe: `tell application "Mail" to count every account`.
- **R8** — iCloud placeholders on Sonoma+ are APFS dataless files. Detect via `SF_DATALESS` flag (`0x40000000`) in `st_flags`, not filename.
- **R3** — TCC re-prompts on ad-hoc-signed binary hash change are likely unavoidable; documented as known friction. Automation TCC attributes to the parent process — **the YouCoded desktop Electron app must carry `NSAppleEventsUsageDescription` + usage-description keys for Calendar/Reminders/Contacts in its Info.plist**. That's a separate PR against `youcoded/desktop/`, noted in Task 30.

**Revised time budget:** Phase 1 expands by ~2 days (write 14 ops from scratch on EventKit/Contacts instead of thin wrappers over iMCP). Phase 2 Task 13/14 expands by ~1-2 days (AppleScript extraction + JXA rewrites).

**Execution pacing:**
- Phase 0 is research — 1 orchestration task dispatching 9 parallel subagents.
- Phase 1 (Swift helper) can complete and produce a testable binary before Phase 2 starts.
- Phase 4 (human DEV-VERIFICATION) is **not** a coded task — it's a human walkthrough documented inline.
- After each phase, the checkpoint task is a human review + go/no-go decision.

---

## File structure — what gets created

### `itsdestin/apple-helper/` (new repo)

| File | Responsibility |
|---|---|
| `Package.swift` | SwiftPM manifest; one executable target `apple-helper`, one test target |
| `Sources/AppleHelper/main.swift` | Entry point; delegates to `RootCommand` |
| `Sources/AppleHelper/RootCommand.swift` | ArgumentParser root with subcommands (calendar, reminders, contacts) + top-level flags |
| `Sources/AppleHelper/JSON.swift` | Pure JSON encoding helpers, date formatting, output contract |
| `Sources/AppleHelper/Errors.swift` | Error types + `TCC_DENIED:<service>` marker emission + exit codes |
| `Sources/AppleHelper/Permissions.swift` | `--request-permissions` flow (serial EventKit + Contacts prompts) |
| `Sources/AppleHelper/CalendarCommands.swift` | Calendar subcommand + 8 op cases, calls `CalendarService` |
| `Sources/AppleHelper/RemindersCommands.swift` | Reminders subcommand + 7 op cases |
| `Sources/AppleHelper/ContactsCommands.swift` | Contacts subcommand + 8 op cases |
| `Sources/FromIMCP/CalendarService.swift` | Vendored from `loopwork/iMCP`; EventKit calls; **unmodified except for adapter-layer additions noted in comments** |
| `Sources/FromIMCP/RemindersService.swift` | Vendored from `loopwork/iMCP` |
| `Sources/FromIMCP/ContactsService.swift` | Vendored from `loopwork/iMCP` |
| `Sources/FromIMCP/README.md` | Explains vendor origin + adaptation rules |
| `Resources/Info.plist` | Embedded in Mach-O for `CFBundleDisplayName`, drives TCC dialog label |
| `Tests/AppleHelperTests/JSONTests.swift` | Unit tests for JSON encoding |
| `Tests/AppleHelperTests/ErrorsTests.swift` | Unit tests for error envelope + marker format |
| `Tests/AppleHelperTests/RootCommandTests.swift` | Unit tests for arg parsing (help, version, unknown op) |
| `.github/workflows/build-and-vendor.yml` | On `apple-helper-v*` tag: build universal + sign + SHA + open PR into `wecoded-marketplace` |
| `VENDORED.md` | File-level provenance for `Sources/FromIMCP/*` |
| `NOTICE.md` | Full license texts for iMCP (Apache-2.0) |
| `README.md` | Dev setup, build commands, release process |

### `wecoded-marketplace/apple-services/` (new plugin dir)

| File | Responsibility |
|---|---|
| `plugin.json` | Marketplace metadata + `platforms: ["macos"]` + `attributions` |
| `VENDORED.md` | Plugin-side provenance: binary origin + AppleScript files |
| `NOTICE.md` | MIT license text for Dhravya/apple-mcp + Apache-2.0 for iMCP (inherited via binary) |
| `bin/apple-helper` | Universal Mach-O, placed here by `itsdestin/apple-helper` CI |
| `bin/apple-helper.sha256` | Hex SHA256 of the binary |
| `commands/apple-services-setup.md` | Slash command with 7 steps |
| `lib/apple-wrapper.sh` | Single wrapper, dispatches by integration, enforces per-op timeouts + concurrency |
| `applescript/notes/list.applescript` | Vendored from Dhravya; `list_notes` backend |
| `applescript/notes/read.applescript` | `get_note` backend |
| `applescript/notes/create.applescript` | `create_note` backend |
| `applescript/notes/update.applescript` | `update_note` backend |
| `applescript/notes/delete.applescript` | `delete_note` backend |
| `applescript/notes/search.applescript` | `search_notes` backend |
| `applescript/notes/list-folders.applescript` | `list_folders` backend |
| `applescript/mail/search.applescript` | `search` backend |
| `applescript/mail/read.applescript` | `read_message` backend |
| `applescript/mail/send.applescript` | `send` backend |
| `applescript/mail/create-draft.applescript` | `create_draft` backend |
| `applescript/mail/list-mailboxes.applescript` | `list_mailboxes` backend |
| `applescript/mail/mark-read.applescript` | `mark_read` / `mark_unread` backend |
| `setup/permissions-walkthrough.md` | Reference content shown during Step 4–5 (auto-included by setup command) |
| `skills/apple-calendar/SKILL.md` | Umbrella |
| `skills/apple-calendar-agenda/SKILL.md` | Focused: "what's on my calendar" |
| `skills/apple-calendar-create/SKILL.md` | Focused: create event |
| `skills/apple-reminders/SKILL.md` | Umbrella |
| `skills/apple-reminders-add/SKILL.md` | Focused: add a reminder |
| `skills/apple-reminders-list/SKILL.md` | Focused: list/show reminders |
| `skills/apple-contacts/SKILL.md` | Umbrella |
| `skills/apple-contacts-find/SKILL.md` | Focused: find a contact |
| `skills/apple-notes/SKILL.md` | Umbrella (with rich-content warning) |
| `skills/apple-notes-search/SKILL.md` | Focused: search notes |
| `skills/apple-notes-write/SKILL.md` | Focused: create/append to notes |
| `skills/apple-mail/SKILL.md` | Umbrella |
| `skills/apple-mail-send/SKILL.md` | Focused: send email |
| `skills/apple-mail-search/SKILL.md` | Focused: search mail |
| `skills/icloud-drive/SKILL.md` | Umbrella (filesystem) |
| `.dev/DEV-VERIFICATION.md` | Human round-trip checklist; excluded from marketplace sync |
| `.gitignore` (project-level update) | Exclude `.dev/` from install artifacts |

### Existing files modified

| File | Change |
|---|---|
| `wecoded-marketplace/marketplace.json` | Add `apple-services` entry to `plugins` array |
| `wecoded-marketplace/index.json` | Add `apple-services` entry |

---

## Phase 0: Research (unblocks Phase 1)

### Task 0: Dispatch 9 parallel research subagents

Phase 0 of the spec lists 9 research items. This task dispatches them in parallel; each writes its findings to `docs/superpowers/plans/research/2026-04-17-apple-<topic>.md`.

**Files:**
- Create: `docs/superpowers/plans/research/2026-04-17-apple-license-check.md` (R1)
- Create: `docs/superpowers/plans/research/2026-04-17-apple-imcp-audit.md` (R2)
- Create: `docs/superpowers/plans/research/2026-04-17-apple-tcc-behavior.md` (R3)
- Create: `docs/superpowers/plans/research/2026-04-17-apple-dhravya-inventory.md` (R4)
- Create: `docs/superpowers/plans/research/2026-04-17-apple-imcp-macos14.md` (R5)
- Create: `docs/superpowers/plans/research/2026-04-17-apple-swift-universal.md` (R6)
- Create: `docs/superpowers/plans/research/2026-04-17-apple-osascript-errors.md` (R7)
- Create: `docs/superpowers/plans/research/2026-04-17-apple-icloud-placeholders.md` (R8)
- Create: `docs/superpowers/plans/research/2026-04-17-apple-contacts-tcc.md` (R9)

- [ ] **Step 1: Invoke dispatching-parallel-agents skill**

Read the spec's Phase 0 section (Section 7 of `docs/superpowers/specs/2026-04-17-apple-services-design.md`) to get the full question + fallback for each R-item. Use superpowers:dispatching-parallel-agents to fire 9 subagents in one batch.

Each subagent's prompt follows this template:

```
Research item [R-number]: [title from spec Section 7]

Question: [verbatim from spec]
Resolution method: [verbatim from spec]
Fallback: [verbatim from spec]

Write findings to: docs/superpowers/plans/research/2026-04-17-apple-<topic>.md

Format:
# [R-number] [Title]

**Date:** 2026-04-17
**Blocking:** [yes/no per spec]
**Status:** RESOLVED | OPEN | BLOCKED

## Question
[restate]

## Finding
[2-4 paragraphs; include URLs, commit SHAs, file paths for evidence]

## Impact on plan
[Does this confirm the spec's assumption? If not, what changes?]

Under 600 words. Cite sources. Do not implement code — research only.
```

**R3 (TCC behavior) is empirical** — it requires macOS 14+ host access and code-signing; if the subagent can't run on macOS, it produces a `BLOCKED` findings file and the human runs it manually during Phase 4 or before Phase 1.

- [ ] **Step 2: Await completion, review each finding file**

Read each findings file. For each, answer: does the finding confirm the spec's assumption, or does it force a spec revision?

- [ ] **Step 3: Gate check — BLOCKING items**

BLOCKING items: R1, R2, R3, R5, R6. If any come back unfavorable:
- R1 copyleft finding → stop; rewrite vendored code from scratch (~2 extra days)
- R2 iMCP modules not extractable → spec revision; may need to re-implement with iMCP as reference only
- R3 TCC re-prompts unavoidably on hash change → document as friction; setup copy updated
- R5 iMCP requires macOS 15+ → bump floor or fork modules
- R6 universal build needs matrix → CI task (Task 10) uses matrix + lipo-merge approach

Non-blocking items (R4, R7, R8, R9) can land findings after Phase 1 starts.

- [ ] **Step 4: Commit findings**

```bash
cd /c/Users/desti/youcoded-dev
git add docs/superpowers/plans/research/2026-04-17-apple-*.md
git commit -m "research: Phase 0 findings for apple-services

Resolves R1-R9 from docs/superpowers/specs/2026-04-17-apple-services-design.md"
```

- [ ] **Step 5: Human go/no-go**

If no BLOCKING findings are unfavorable, proceed to Phase 1. If any are, revise the spec first (separate commit) before continuing.

---

## Phase 1: Swift helper repo (`itsdestin/apple-helper`)

### Task 1: Create repo + local workspace

**Files:**
- Create: `C:\Users\desti\apple-helper\` (local clone outside `youcoded-dev`)
- Create: `C:\Users\desti\apple-helper\.gitignore`
- Create: `C:\Users\desti\apple-helper\README.md`

- [ ] **Step 1: Create the GitHub repo**

```bash
gh repo create itsdestin/apple-helper --public --description "Swift CLI powering apple-services marketplace bundle (Calendar, Reminders, Contacts via EventKit + Contacts framework)"
```

Expected: `https://github.com/itsdestin/apple-helper` URL printed.

- [ ] **Step 2: Clone locally outside youcoded-dev**

```bash
cd /c/Users/desti
git clone https://github.com/itsdestin/apple-helper.git
cd apple-helper
```

Why outside `youcoded-dev`: this is a sibling repo, not part of the workspace, and keeping it out prevents the workspace's sync scripts from touching it.

- [ ] **Step 3: Add .gitignore**

```
# .gitignore
.build/
.swiftpm/
.DS_Store
*.xcodeproj
.vscode/
```

- [ ] **Step 4: Add README**

```markdown
# apple-helper

Swift CLI powering the `apple-services` marketplace bundle. Wraps EventKit (Calendar, Reminders) and the Contacts framework behind a uniform JSON CLI so the `apple-services` plugin's bash wrapper can call a single binary.

## Build

```bash
swift build -c release
.build/release/apple-helper --version
```

## Release

Tag `apple-helper-vX.Y.Z`. CI builds a universal (arm64+x86_64) Mach-O, ad-hoc signs it, computes SHA256, and opens a PR against `itsdestin/wecoded-marketplace` vendoring the binary into `apple-services/bin/`.

## Source layout

- `Sources/AppleHelper/` — CLI entry, arg parsing, JSON output, error envelope, EventKit/Contacts ops (all original code)

## License

MIT. Patterns inspired by `mattt/iMCP` (also MIT) are credited in `NOTICE.md` — no iMCP code is vendored byte-for-byte.
```

- [ ] **Step 5: Commit**

```bash
git add .gitignore README.md
git commit -m "init: scaffold apple-helper repo"
git push origin master
```

---

### Task 2: SwiftPM manifest + CLI skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/AppleHelper/main.swift`
- Create: `Sources/AppleHelper/RootCommand.swift`
- Create: `Resources/Info.plist`

- [ ] **Step 1: Write Package.swift**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "apple-helper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "apple-helper", targets: ["AppleHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "AppleHelper",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                // Embed Info.plist in the binary so CFBundleDisplayName
                // controls the TCC dialog label.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "AppleHelperTests",
            dependencies: ["AppleHelper"]
        ),
    ]
)
```

- [ ] **Step 2: Write main.swift**

```swift
// Sources/AppleHelper/main.swift
import ArgumentParser

RootCommand.main()
```

- [ ] **Step 3: Write RootCommand.swift skeleton**

```swift
// Sources/AppleHelper/RootCommand.swift
import ArgumentParser
import Foundation

struct RootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-helper",
        abstract: "JSON CLI over EventKit (Calendar, Reminders) and Contacts framework.",
        version: "0.1.0",
        subcommands: [
            CalendarCommand.self,
            RemindersCommand.self,
            ContactsCommand.self,
            RequestPermissionsCommand.self,
        ]
    )
}

// Placeholder subcommands so the package compiles before Task 5-7 fill them in.
struct CalendarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "calendar", abstract: "Calendar ops.")
    @Argument(help: "Operation name (e.g. list_calendars)") var op: String
    @Argument(parsing: .captureForPassthrough) var rest: [String] = []
    mutating func run() throws { throw ValidationError("Calendar ops not wired yet — see Task 5.") }
}

struct RemindersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reminders", abstract: "Reminders ops.")
    @Argument var op: String
    @Argument(parsing: .captureForPassthrough) var rest: [String] = []
    mutating func run() throws { throw ValidationError("Reminders ops not wired yet — see Task 6.") }
}

struct ContactsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "contacts", abstract: "Contacts ops.")
    @Argument var op: String
    @Argument(parsing: .captureForPassthrough) var rest: [String] = []
    mutating func run() throws { throw ValidationError("Contacts ops not wired yet — see Task 7.") }
}

struct RequestPermissionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "request-permissions", abstract: "Serially request EventKit + Contacts permissions.")
    mutating func run() throws { throw ValidationError("Permissions flow not wired yet — see Task 8.") }
}
```

- [ ] **Step 4: Write Info.plist**

```xml
<!-- Resources/Info.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.youcoded.apple-helper</string>
    <key>CFBundleName</key>
    <string>apple-helper</string>
    <key>CFBundleDisplayName</key>
    <string>apple-helper</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>NSCalendarsUsageDescription</key>
    <string>YouCoded uses Calendar to show, create, and update events.</string>
    <key>NSRemindersUsageDescription</key>
    <string>YouCoded uses Reminders to show, create, and update reminders.</string>
    <key>NSContactsUsageDescription</key>
    <string>YouCoded uses Contacts to look up and update contact details.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>YouCoded uses Calendar to show, create, and update events.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>YouCoded uses Reminders to show, create, and update reminders.</string>
</dict>
</plist>
```

- [ ] **Step 5: Verify it builds**

```bash
swift build
.build/debug/apple-helper --version
```

Expected: `0.1.0` printed.

```bash
.build/debug/apple-helper --help
```

Expected: help shows `calendar`, `reminders`, `contacts`, `request-permissions` subcommands.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/AppleHelper/ Resources/Info.plist
git commit -m "feat: SwiftPM scaffold + CLI skeleton with ArgumentParser"
```

---

### Task 3: JSON output + error envelope + tests

**Files:**
- Create: `Sources/AppleHelper/JSON.swift`
- Create: `Sources/AppleHelper/Errors.swift`
- Create: `Tests/AppleHelperTests/JSONTests.swift`
- Create: `Tests/AppleHelperTests/ErrorsTests.swift`

- [ ] **Step 1: Write the failing tests first**

```swift
// Tests/AppleHelperTests/JSONTests.swift
import XCTest
@testable import AppleHelper

final class JSONTests: XCTestCase {
    func testEncodesDateAsISO8601() {
        let date = ISO8601DateFormatter().date(from: "2026-04-17T14:00:00Z")!
        let output = JSON.encode(["start": date])
        XCTAssertTrue(output.contains("\"2026-04-17T14:00:00Z\""))
    }

    func testEncodesArrayOfDictionaries() {
        let input: [[String: Any]] = [
            ["id": "1", "title": "A"],
            ["id": "2", "title": "B"],
        ]
        let output = JSON.encode(input)
        XCTAssertTrue(output.contains("\"id\":\"1\""))
        XCTAssertTrue(output.contains("\"title\":\"B\""))
    }

    func testEncodesEmptyArray() {
        XCTAssertEqual(JSON.encode([[String: Any]]()), "[]")
    }
}
```

```swift
// Tests/AppleHelperTests/ErrorsTests.swift
import XCTest
@testable import AppleHelper

final class ErrorsTests: XCTestCase {
    func testTCCDeniedMarkerFormat() {
        let err = HelperError.tccDenied(service: "calendar", message: "Calendar access was denied.")
        XCTAssertEqual(err.marker, "TCC_DENIED:calendar")
        XCTAssertEqual(err.exitCode, 2)
    }

    func testErrorEnvelopeShape() {
        let err = HelperError.notFound(service: "reminders", message: "No reminder with ID abc.")
        let json = err.asJSON()
        XCTAssertTrue(json.contains("\"code\":\"NOT_FOUND\""))
        XCTAssertTrue(json.contains("\"service\":\"reminders\""))
        XCTAssertTrue(json.contains("\"message\":\"No reminder with ID abc.\""))
    }

    func testAllCodes() {
        let codes: [(HelperError, String)] = [
            (.tccDenied(service: "calendar", message: ""), "TCC_DENIED"),
            (.notFound(service: "calendar", message: ""), "NOT_FOUND"),
            (.invalidArg(service: "calendar", message: ""), "INVALID_ARG"),
            (.unavailable(service: "calendar", message: ""), "UNAVAILABLE"),
            (.internalError(service: "calendar", message: ""), "INTERNAL"),
        ]
        for (err, code) in codes {
            XCTAssertTrue(err.asJSON().contains("\"code\":\"\(code)\""))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test
```

Expected: FAIL with "no such module/type JSON" and "no such module/type HelperError".

- [ ] **Step 3: Write JSON.swift**

```swift
// Sources/AppleHelper/JSON.swift
import Foundation

enum JSON {
    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Encode a JSON-compatible value (dict, array, scalar) to a compact JSON string.
    /// Dates are stringified ISO-8601 before encoding.
    static func encode(_ value: Any) -> String {
        let normalized = normalize(value)
        guard let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]) else {
            return "null"
        }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private static func normalize(_ value: Any) -> Any {
        switch value {
        case let date as Date:
            return iso8601.string(from: date)
        case let dict as [String: Any]:
            return dict.mapValues { normalize($0) }
        case let arr as [Any]:
            return arr.map { normalize($0) }
        case let arrDict as [[String: Any]]:
            return arrDict.map { $0.mapValues { normalize($0) } }
        default:
            return value
        }
    }
}
```

- [ ] **Step 4: Write Errors.swift**

```swift
// Sources/AppleHelper/Errors.swift
import Foundation

enum HelperError: Error {
    case tccDenied(service: String, message: String)
    case notFound(service: String, message: String)
    case invalidArg(service: String, message: String)
    case unavailable(service: String, message: String)
    case internalError(service: String, message: String)

    var code: String {
        switch self {
        case .tccDenied:    return "TCC_DENIED"
        case .notFound:     return "NOT_FOUND"
        case .invalidArg:   return "INVALID_ARG"
        case .unavailable:  return "UNAVAILABLE"
        case .internalError: return "INTERNAL"
        }
    }

    var service: String {
        switch self {
        case .tccDenied(let s, _), .notFound(let s, _), .invalidArg(let s, _),
             .unavailable(let s, _), .internalError(let s, _):
            return s
        }
    }

    var message: String {
        switch self {
        case .tccDenied(_, let m), .notFound(_, let m), .invalidArg(_, let m),
             .unavailable(_, let m), .internalError(_, let m):
            return m
        }
    }

    var recovery: String {
        switch self {
        case .tccDenied:
            return "Run /apple-services-setup and re-grant \(service) access, or toggle it back on in System Settings → Privacy & Security."
        case .notFound:
            return "Verify the ID is current (IDs change when items are deleted and recreated)."
        case .invalidArg:
            return "Check the argument values and retry."
        case .unavailable:
            return "The service isn't ready. See the message for specifics."
        case .internalError:
            return "Please report this — unexpected internal failure."
        }
    }

    /// Marker line written to stderr for the wrapper to detect.
    var marker: String {
        switch self {
        case .tccDenied: return "TCC_DENIED:\(service)"
        default: return ""
        }
    }

    var exitCode: Int32 {
        switch self {
        case .tccDenied: return 2
        default: return 1
        }
    }

    func asJSON() -> String {
        let envelope: [String: Any] = [
            "error": [
                "code": code,
                "service": service,
                "message": message,
                "recovery": recovery,
            ]
        ]
        return JSON.encode(envelope)
    }

    /// Write the envelope + marker to stderr, then exit with the right code.
    func writeAndExit() -> Never {
        FileHandle.standardError.write(asJSON().data(using: .utf8)!)
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        if !marker.isEmpty {
            FileHandle.standardError.write(marker.data(using: .utf8)!)
            FileHandle.standardError.write("\n".data(using: .utf8)!)
        }
        exit(exitCode)
    }
}
```

- [ ] **Step 5: Run tests**

```bash
swift test
```

Expected: PASS (3 tests in JSONTests, 3 in ErrorsTests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AppleHelper/JSON.swift Sources/AppleHelper/Errors.swift Tests/AppleHelperTests/
git commit -m "feat: JSON output + error envelope with TCC_DENIED marker"
```

---

### Task 4: Clone iMCP as reference + write NOTICE/VENDORED scaffolds

**Files:**
- Create: `NOTICE.md` (repo root)
- Create: `VENDORED.md` (repo root — initially documents only the Dhravya AppleScript extracts that land later in Phase 2; iMCP is reference-only and appears in NOTICE.md only)
- Create: local reference clone at `~/reference/iMCP/` (outside repo)

**Rationale (Phase 0 R2 finding):** iMCP is an Xcode project, not SwiftPM, and its services are tightly coupled to in-repo `Tool`/`Value`/`Ontology`/`JSONSchema` types. Vendoring byte-for-byte isn't worth the decoupling work. Instead we keep iMCP locally as reading reference while we write EventKit/Contacts calls directly in Tasks 5-7.

- [ ] **Step 1: Clone iMCP locally at the SHA from R2**

```bash
mkdir -p ~/reference
cd ~/reference
git clone https://github.com/mattt/iMCP.git
cd iMCP
# SHA captured in Phase 0 R2 findings:
VENDOR_SHA="6d0df253cd31d485edaede4929dc3e92d5825cab"
git checkout "$VENDOR_SHA"
echo "Reading iMCP at $VENDOR_SHA"
```

- [ ] **Step 2: Spot-check that the expected service files are present**

```bash
ls App/Services/{Calendar,Reminders,Contacts}.swift
head -20 App/Services/Calendar.swift
```

Expected: all three files exist. If paths differ from R2, adjust when reading — the tasks below refer to these files but don't copy them.

- [ ] **Step 3: Write VENDORED.md at the apple-helper repo root**

```bash
cd /c/Users/desti/apple-helper
```

```markdown
# VENDORED.md

Provenance for code copied byte-for-byte from third-party sources.

This repo contains **no** byte-for-byte vendored code. iMCP, our primary reference, is credited in `NOTICE.md` as reference-only — we read its patterns for EventKit/Contacts usage and implement our own code in `Sources/AppleHelper/`. The marketplace plugin at `wecoded-marketplace/apple-services/` vendors AppleScript extracted from `supermemoryai/apple-mcp`; that repo's `VENDORED.md` tracks those files.

See `NOTICE.md` for third-party attribution.
```

- [ ] **Step 4: Write NOTICE.md**

```markdown
# NOTICE.md

`apple-helper` is MIT-licensed. It was built with reference to the following third-party Open Source projects. License texts are reproduced in full for attribution.

---

## iMCP (MIT)

Source: https://github.com/mattt/iMCP
Audited SHA: `6d0df253cd31d485edaede4929dc3e92d5825cab` (2026-01-30)

Our EventKit and Contacts implementations in `Sources/AppleHelper/` draw on patterns we learned reading iMCP's `App/Services/{Calendar,Reminders,Contacts}.swift` files, its `App/Extensions/EventKit+Extensions.swift`, and related types. No files are copied byte-for-byte; implementations target a different CLI shape and cover ops iMCP does not expose. iMCP is credited here because the reference meaningfully shaped our code.

iMCP's license in full:

```
MIT License

Copyright (c) 2025 Mattt (https://mat.tt)

[... paste the full MIT text from ~/reference/iMCP/LICENSE.md ...]
```
```

**Fill in the bracketed section:** open `~/reference/iMCP/LICENSE.md` and paste its full contents in place of the `[... paste ...]` line.

- [ ] **Step 5: Commit**

```bash
git add NOTICE.md VENDORED.md
git commit -m "docs: NOTICE.md (iMCP MIT reference) + VENDORED.md scaffold"
```

---

### Task 5: Wire Calendar ops directly on EventKit (8 ops)

**Files:**
- Create: `Sources/AppleHelper/CalendarCommands.swift` (replaces placeholder from Task 2)
- Modify: `Sources/AppleHelper/RootCommand.swift` — remove placeholder `CalendarCommand`

The 8 ops come from the spec's `apple-calendar` table. Per Phase 0 R2, iMCP only exposes ~3 of these (list, fetch, create) and with different shapes than we want; we call EventKit directly. `~/reference/iMCP/App/Services/Calendar.swift` and `~/reference/iMCP/App/Extensions/EventKit+Extensions.swift` are useful references for date handling + recurrence mapping — read them while implementing.

- [ ] **Step 1: Delete placeholder from RootCommand.swift**

Open `Sources/AppleHelper/RootCommand.swift` and delete the entire `struct CalendarCommand: ParsableCommand { ... }` block (keep the entry in the `subcommands:` array — the full `CalendarCommand` is defined in `CalendarCommands.swift` below).

- [ ] **Step 2: Write CalendarCommands.swift**

```swift
// Sources/AppleHelper/CalendarCommands.swift
import ArgumentParser
import EventKit
import Foundation

struct CalendarCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Calendar operations (EventKit)."
    )

    @Argument(help: "Operation name. One of: list_calendars, list_events, get_event, search_events, create_event, update_event, delete_event, free_busy.")
    var op: String

    @Option(name: .long) var from: String?
    @Option(name: .long) var to: String?
    @Option(name: .long) var calendarId: String?
    @Option(name: .long) var calendarIds: String?  // comma-separated
    @Option(name: .long) var id: String?
    @Option(name: .long) var title: String?
    @Option(name: .long) var start: String?
    @Option(name: .long) var end: String?
    @Option(name: .long) var location: String?
    @Option(name: .long) var notes: String?
    @Option(name: .long) var recurrence: String?
    @Flag(name: .long) var allDay: Bool = false
    @Option(name: .long) var query: String?

    mutating func run() throws {
        let store = EKEventStore()
        do {
            switch op {
            case "list_calendars":
                let cals = store.calendars(for: .event)
                let json = cals.map { cal in
                    [
                        "id": cal.calendarIdentifier,
                        "title": cal.title,
                        "color": cal.cgColor.map { JSON.hex(from: $0) } ?? "",
                        "writable": cal.allowsContentModifications,
                    ] as [String: Any]
                }
                print(JSON.encode(json))

            case "list_events":
                guard let fromStr = from, let toStr = to else {
                    throw HelperError.invalidArg(service: "calendar", message: "list_events requires --from and --to")
                }
                let fromDate = try parseDate(fromStr, arg: "from")
                let toDate = try parseDate(toStr, arg: "to")
                let cals = calendarId.flatMap { cid in store.calendars(for: .event).filter { $0.calendarIdentifier == cid } }
                let predicate = store.predicateForEvents(withStart: fromDate, end: toDate, calendars: cals)
                let events = store.events(matching: predicate)
                print(JSON.encode(events.map(eventToDict)))

            case "get_event":
                guard let id = id else { throw HelperError.invalidArg(service: "calendar", message: "get_event requires --id") }
                // calendarItem(withIdentifier:) works for both events and reminders.
                guard let event = store.calendarItem(withIdentifier: id) as? EKEvent else {
                    throw HelperError.notFound(service: "calendar", message: "No event with id \(id)")
                }
                print(JSON.encode(eventToDict(event)))

            case "search_events":
                guard let q = query, let fromStr = from, let toStr = to else {
                    throw HelperError.invalidArg(service: "calendar", message: "search_events requires --query --from --to")
                }
                let fromDate = try parseDate(fromStr, arg: "from")
                let toDate = try parseDate(toStr, arg: "to")
                let predicate = store.predicateForEvents(withStart: fromDate, end: toDate, calendars: nil)
                let needle = q.lowercased()
                let events = store.events(matching: predicate).filter { event in
                    (event.title ?? "").lowercased().contains(needle) ||
                    (event.notes ?? "").lowercased().contains(needle) ||
                    (event.location ?? "").lowercased().contains(needle)
                }
                print(JSON.encode(events.map(eventToDict)))

            case "create_event":
                guard let title = title, let startStr = start, let endStr = end, let calId = calendarId else {
                    throw HelperError.invalidArg(service: "calendar", message: "create_event requires --title --start --end --calendar-id")
                }
                let startDate = try parseDate(startStr, arg: "start")
                let endDate = try parseDate(endStr, arg: "end")
                guard endDate >= startDate else {
                    throw HelperError.invalidArg(service: "calendar", message: "end must be >= start")
                }
                guard let cal = store.calendars(for: .event).first(where: { $0.calendarIdentifier == calId }) else {
                    throw HelperError.notFound(service: "calendar", message: "No calendar with id \(calId)")
                }
                let event = EKEvent(eventStore: store)
                event.calendar = cal
                event.title = title
                event.startDate = startDate
                event.endDate = endDate
                event.isAllDay = allDay
                if let loc = location { event.location = loc }
                if let n = notes { event.notes = n }
                if let rule = recurrence { event.recurrenceRules = [try parseRecurrence(rule)] }
                try store.save(event, span: .thisEvent, commit: true)
                print(JSON.encode(eventToDict(event)))

            case "update_event":
                guard let id = id else { throw HelperError.invalidArg(service: "calendar", message: "update_event requires --id") }
                guard let event = store.calendarItem(withIdentifier: id) as? EKEvent else {
                    throw HelperError.notFound(service: "calendar", message: "No event with id \(id)")
                }
                if let t = title { event.title = t }
                if let s = start { event.startDate = try parseDate(s, arg: "start") }
                if let e = end { event.endDate = try parseDate(e, arg: "end") }
                if let loc = location { event.location = loc }
                if let n = notes { event.notes = n }
                if let calId = calendarId, let cal = store.calendars(for: .event).first(where: { $0.calendarIdentifier == calId }) {
                    event.calendar = cal
                }
                if let rule = recurrence { event.recurrenceRules = [try parseRecurrence(rule)] }
                try store.save(event, span: .thisEvent, commit: true)
                print(JSON.encode(eventToDict(event)))

            case "delete_event":
                guard let id = id else { throw HelperError.invalidArg(service: "calendar", message: "delete_event requires --id") }
                guard let event = store.calendarItem(withIdentifier: id) as? EKEvent else {
                    throw HelperError.notFound(service: "calendar", message: "No event with id \(id)")
                }
                try store.remove(event, span: .thisEvent, commit: true)
                print(#"{"ok":true}"#)

            case "free_busy":
                guard let fromStr = from, let toStr = to else {
                    throw HelperError.invalidArg(service: "calendar", message: "free_busy requires --from --to")
                }
                let fromDate = try parseDate(fromStr, arg: "from")
                let toDate = try parseDate(toStr, arg: "to")
                let cals = calendarIds?.split(separator: ",").compactMap { cid in
                    store.calendars(for: .event).first(where: { $0.calendarIdentifier == String(cid) })
                }
                let predicate = store.predicateForEvents(withStart: fromDate, end: toDate, calendars: cals)
                let events = store.events(matching: predicate)
                // Collapse into busy windows: each event becomes one {start, end, busy: true}.
                // Gaps are implicit (free). Consumers can merge overlaps if they care.
                let slots = events
                    .sorted { $0.startDate < $1.startDate }
                    .map { ["start": $0.startDate, "end": $0.endDate, "busy": true] as [String: Any] }
                print(JSON.encode(slots))

            default:
                throw HelperError.invalidArg(service: "calendar", message: "Unknown op: \(op)")
            }
        } catch let e as HelperError {
            e.writeAndExit()
        } catch let e as EKError where e.code == .denied {
            HelperError.tccDenied(service: "calendar", message: "Calendar access was denied.").writeAndExit()
        } catch {
            HelperError.internalError(service: "calendar", message: String(describing: error)).writeAndExit()
        }
    }

    private func parseDate(_ s: String, arg: String) throws -> Date {
        if let d = JSON.iso8601.date(from: s) { return d }
        let withTz = DateFormatter()
        withTz.dateFormat = "yyyy-MM-dd'T'HH:mm"
        withTz.timeZone = .current
        if let d = withTz.date(from: s) { return d }
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = .current
        if let d = dateOnly.date(from: s) { return d }
        throw HelperError.invalidArg(service: "calendar", message: "Invalid date for --\(arg): \(s) (expected ISO-8601 or yyyy-MM-dd)")
    }

    /// v1 recurrence support: accept a tiny DSL — one of
    ///   "daily", "weekly", "monthly", "yearly"
    /// plus optional interval suffix like "weekly:2" (every 2 weeks).
    /// Richer rules (BYDAY etc.) are out of scope for v1.
    private func parseRecurrence(_ rule: String) throws -> EKRecurrenceRule {
        let parts = rule.split(separator: ":")
        let freqStr = String(parts[0]).lowercased()
        let interval = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let freq: EKRecurrenceFrequency
        switch freqStr {
        case "daily":   freq = .daily
        case "weekly":  freq = .weekly
        case "monthly": freq = .monthly
        case "yearly":  freq = .yearly
        default:
            throw HelperError.invalidArg(service: "calendar", message: "Unknown recurrence: \(rule). Supported: daily|weekly|monthly|yearly, optional :N interval.")
        }
        return EKRecurrenceRule(recurrenceWith: freq, interval: interval, end: nil)
    }

    private func eventToDict(_ e: EKEvent) -> [String: Any] {
        return [
            "id": e.eventIdentifier ?? "",
            "title": e.title ?? "",
            "start": e.startDate,
            "end": e.endDate,
            "all_day": e.isAllDay,
            "location": e.location ?? "",
            "notes": e.notes ?? "",
            "calendar_id": e.calendar.calendarIdentifier,
            "calendar_title": e.calendar.title,
            "recurrence": e.hasRecurrenceRules ? (e.recurrenceRules?.first.map { "\($0)" } ?? "") : "",
        ]
    }
}

extension JSON {
    /// Convert CGColor to #RRGGBB hex.
    static func hex(from color: CGColor) -> String {
        guard let components = color.components, components.count >= 3 else { return "" }
        let r = Int((components[0] * 255).rounded())
        let g = Int((components[1] * 255).rounded())
        let b = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
```

- [ ] **Step 3: Verify it builds**

```bash
swift build
```

Expected: success.

- [ ] **Step 4: Smoke-test against a live calendar (macOS only)**

```bash
.build/debug/apple-helper calendar list_calendars
```

Expected first run: Calendar permission dialog. Click Allow. Then JSON array of calendars.

Expected subsequent runs: immediate JSON output, no dialog.

- [ ] **Step 5: Commit**

```bash
git add Sources/AppleHelper/CalendarCommands.swift Sources/AppleHelper/RootCommand.swift
git commit -m "feat: Calendar ops (8) on EventKit directly"
```

---

### Task 6: Wire Reminders ops directly on EventKit (7 ops)

**Files:**
- Create: `Sources/AppleHelper/RemindersCommands.swift` (replaces placeholder)
- Modify: `Sources/AppleHelper/RootCommand.swift` — remove placeholder `RemindersCommand`

Ops: `list_lists`, `list_reminders`, `get_reminder`, `create_reminder`, `update_reminder`, `complete_reminder`, `delete_reminder`. EventKit reminders API needs async `fetchReminders(matching:)` which we bridge to sync via a semaphore (EventKit has no sync query API for reminders — this is the one awkward part).

- [ ] **Step 1: Delete the placeholder in RootCommand.swift**

Remove the `struct RemindersCommand: ParsableCommand { ... }` block.

- [ ] **Step 2: Write RemindersCommands.swift**

```swift
// Sources/AppleHelper/RemindersCommands.swift
import ArgumentParser
import EventKit
import Foundation

struct RemindersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reminders",
        abstract: "Reminders operations (EventKit)."
    )

    @Argument(help: "Operation name. One of: list_lists, list_reminders, get_reminder, create_reminder, update_reminder, complete_reminder, delete_reminder.")
    var op: String

    @Option(name: .long) var listId: String?
    @Option(name: .long) var id: String?
    @Option(name: .long) var title: String?
    @Option(name: .long) var due: String?
    @Option(name: .long) var priority: Int?
    @Option(name: .long) var notes: String?
    @Flag(name: .long) var incompleteOnly: Bool = false

    mutating func run() throws {
        let store = EKEventStore()
        do {
            switch op {
            case "list_lists":
                let lists = store.calendars(for: .reminder)
                let json = lists.map { l in
                    [
                        "id": l.calendarIdentifier,
                        "title": l.title,
                        "color": l.cgColor.map { JSON.hex(from: $0) } ?? "",
                    ] as [String: Any]
                }
                print(JSON.encode(json))

            case "list_reminders":
                let cals = listId.flatMap { lid in store.calendars(for: .reminder).filter { $0.calendarIdentifier == lid } }
                let predicate = incompleteOnly
                    ? store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
                    : store.predicateForReminders(in: cals)
                let reminders = try fetchReminders(store: store, predicate: predicate)
                print(JSON.encode(reminders.map(reminderToDict)))

            case "get_reminder":
                guard let id = id else { throw HelperError.invalidArg(service: "reminders", message: "get_reminder requires --id") }
                guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    throw HelperError.notFound(service: "reminders", message: "No reminder with id \(id)")
                }
                print(JSON.encode(reminderToDict(r)))

            case "create_reminder":
                guard let title = title, let lid = listId else {
                    throw HelperError.invalidArg(service: "reminders", message: "create_reminder requires --title --list-id")
                }
                guard let cal = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == lid }) else {
                    throw HelperError.notFound(service: "reminders", message: "No list with id \(lid)")
                }
                let r = EKReminder(eventStore: store)
                r.calendar = cal
                r.title = title
                if let d = due {
                    r.dueDateComponents = try dateComponents(from: parseDate(d))
                }
                if let p = priority { r.priority = p }
                if let n = notes { r.notes = n }
                try store.save(r, commit: true)
                print(JSON.encode(reminderToDict(r)))

            case "update_reminder":
                guard let id = id else { throw HelperError.invalidArg(service: "reminders", message: "update_reminder requires --id") }
                guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    throw HelperError.notFound(service: "reminders", message: "No reminder with id \(id)")
                }
                if let t = title { r.title = t }
                if let d = due { r.dueDateComponents = try dateComponents(from: parseDate(d)) }
                if let p = priority { r.priority = p }
                if let n = notes { r.notes = n }
                try store.save(r, commit: true)
                print(JSON.encode(reminderToDict(r)))

            case "complete_reminder":
                guard let id = id else { throw HelperError.invalidArg(service: "reminders", message: "complete_reminder requires --id") }
                guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    throw HelperError.notFound(service: "reminders", message: "No reminder with id \(id)")
                }
                r.isCompleted = true
                try store.save(r, commit: true)
                print(#"{"ok":true}"#)

            case "delete_reminder":
                guard let id = id else { throw HelperError.invalidArg(service: "reminders", message: "delete_reminder requires --id") }
                guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
                    throw HelperError.notFound(service: "reminders", message: "No reminder with id \(id)")
                }
                try store.remove(r, commit: true)
                print(#"{"ok":true}"#)

            default:
                throw HelperError.invalidArg(service: "reminders", message: "Unknown op: \(op)")
            }
        } catch let e as HelperError {
            e.writeAndExit()
        } catch let e as EKError where e.code == .denied {
            HelperError.tccDenied(service: "reminders", message: "Reminders access was denied.").writeAndExit()
        } catch {
            HelperError.internalError(service: "reminders", message: String(describing: error)).writeAndExit()
        }
    }

    /// EventKit's reminder query is async-only. Bridge to sync via a semaphore
    /// so the CLI op model stays "one invocation = one blocking call".
    private func fetchReminders(store: EKEventStore, predicate: NSPredicate) throws -> [EKReminder] {
        let sem = DispatchSemaphore(value: 0)
        var result: [EKReminder] = []
        store.fetchReminders(matching: predicate) { reminders in
            result = reminders ?? []
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        return result
    }

    private func parseDate(_ s: String) throws -> Date {
        if let d = JSON.iso8601.date(from: s) { return d }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = .current
        if let d = f.date(from: s) { return d }
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = .current
        if let d = dateOnly.date(from: s) { return d }
        throw HelperError.invalidArg(service: "reminders", message: "Invalid date: \(s)")
    }

    private func dateComponents(from date: Date) throws -> DateComponents {
        let cal = Calendar.current
        return cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    private func reminderToDict(_ r: EKReminder) -> [String: Any] {
        var d: [String: Any] = [
            "id": r.calendarItemIdentifier,
            "title": r.title ?? "",
            "completed": r.isCompleted,
            "list_id": r.calendar.calendarIdentifier,
            "list_title": r.calendar.title,
            "notes": r.notes ?? "",
            "priority": r.priority,
        ]
        if let due = r.dueDateComponents, let date = Calendar.current.date(from: due) {
            d["due"] = date
        }
        return d
    }
}
```

- [ ] **Step 3: Build + smoke test**

```bash
swift build
.build/debug/apple-helper reminders list_lists
```

Expected: permission dialog on first run; JSON array on subsequent.

- [ ] **Step 4: Commit**

```bash
git add Sources/AppleHelper/RemindersCommands.swift Sources/AppleHelper/RootCommand.swift
git commit -m "feat: Reminders ops (7) on EventKit directly"
```

---

### Task 7: Wire Contacts ops directly on Contacts framework (8 ops)

**Files:**
- Create: `Sources/AppleHelper/ContactsCommands.swift` (replaces placeholder)
- Modify: `Sources/AppleHelper/RootCommand.swift` — remove placeholder `ContactsCommand`

Ops: `search`, `get`, `list_groups`, `list_group_members`, `create`, `update`, `add_to_group`, `remove_from_group`. Contacts framework is sync; no async bridging needed.

- [ ] **Step 1: Delete the placeholder in RootCommand.swift + write ContactsCommands.swift**

```swift
// Sources/AppleHelper/ContactsCommands.swift
import ArgumentParser
import Contacts
import Foundation

struct ContactsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contacts",
        abstract: "Contacts operations (Contacts framework)."
    )

    @Argument(help: "Operation. One of: search, get, list_groups, list_group_members, create, update, add_to_group, remove_from_group.")
    var op: String

    @Option(name: .long) var query: String?
    @Option(name: .long) var id: String?
    @Option(name: .long) var contactId: String?
    @Option(name: .long) var groupId: String?
    @Option(name: .long) var first: String?
    @Option(name: .long) var last: String?
    @Option(name: .long) var organization: String?
    @Option(name: .long) var notes: String?
    @Option(name: [.customLong("phones")], parsing: .upToNextOption) var phones: [String] = []
    @Option(name: [.customLong("emails")], parsing: .upToNextOption) var emails: [String] = []
    @Option(name: .long) var limit: Int?

    private static let keysToFetch: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactNoteKey as CNKeyDescriptor,
        CNContactImageDataAvailableKey as CNKeyDescriptor,
    ]

    mutating func run() throws {
        let store = CNContactStore()
        do {
            switch op {
            case "search":
                guard let q = query else { throw HelperError.invalidArg(service: "contacts", message: "search requires --query") }
                let predicate = CNContact.predicateForContacts(matchingName: q)
                var results: [CNContact] = []
                do {
                    results = try store.unifiedContacts(matching: predicate, keysToFetch: Self.keysToFetch)
                } catch {
                    // Name predicate isn't exhaustive — some matches live in phone/email/org.
                    // Fall back: enumerate all, filter in memory. Slow but v1-acceptable.
                    let fetchReq = CNContactFetchRequest(keysToFetch: Self.keysToFetch)
                    try store.enumerateContacts(with: fetchReq) { contact, _ in
                        let needle = q.lowercased()
                        let hay = [contact.givenName, contact.familyName, contact.organizationName,
                                   contact.phoneNumbers.map { $0.value.stringValue }.joined(separator: " "),
                                   contact.emailAddresses.map { $0.value as String }.joined(separator: " ")]
                            .joined(separator: " ").lowercased()
                        if hay.contains(needle) { results.append(contact) }
                    }
                }
                let cap = limit ?? 50
                let truncated = Array(results.prefix(cap))
                print(JSON.encode(truncated.map(contactToDict)))

            case "get":
                guard let id = id else { throw HelperError.invalidArg(service: "contacts", message: "get requires --id") }
                do {
                    let c = try store.unifiedContact(withIdentifier: id, keysToFetch: Self.keysToFetch)
                    print(JSON.encode(contactToDict(c)))
                } catch {
                    throw HelperError.notFound(service: "contacts", message: "No contact with id \(id)")
                }

            case "list_groups":
                let groups = try store.groups(matching: nil)
                print(JSON.encode(groups.map { ["id": $0.identifier, "name": $0.name] as [String: Any] }))

            case "list_group_members":
                guard let gid = groupId else { throw HelperError.invalidArg(service: "contacts", message: "list_group_members requires --group-id") }
                let predicate = CNContact.predicateForContactsInGroup(withIdentifier: gid)
                let members = try store.unifiedContacts(matching: predicate, keysToFetch: Self.keysToFetch)
                print(JSON.encode(members.map(contactToDict)))

            case "create":
                guard let first = first else { throw HelperError.invalidArg(service: "contacts", message: "create requires --first") }
                let c = CNMutableContact()
                c.givenName = first
                if let last = last { c.familyName = last }
                if let org = organization { c.organizationName = org }
                c.phoneNumbers = phones.map { CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0)) }
                c.emailAddresses = emails.map { CNLabeledValue(label: CNLabelHome, value: $0 as NSString) }
                if let n = notes { c.note = n }
                let req = CNSaveRequest()
                req.add(c, toContainerWithIdentifier: nil)
                try store.execute(req)
                // Re-fetch so identifier is stable + return shape matches `get`.
                let fetched = try store.unifiedContact(withIdentifier: c.identifier, keysToFetch: Self.keysToFetch)
                print(JSON.encode(contactToDict(fetched)))

            case "update":
                guard let id = id else { throw HelperError.invalidArg(service: "contacts", message: "update requires --id") }
                let existing = try store.unifiedContact(withIdentifier: id, keysToFetch: Self.keysToFetch)
                // unifiedContact is immutable; need mutable copy from the underlying contact.
                guard let mutable = existing.mutableCopy() as? CNMutableContact else {
                    throw HelperError.internalError(service: "contacts", message: "Couldn't obtain mutable copy of \(id)")
                }
                if let f = first { mutable.givenName = f }
                if let l = last { mutable.familyName = l }
                if let o = organization { mutable.organizationName = o }
                if !phones.isEmpty {
                    mutable.phoneNumbers = phones.map { CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: $0)) }
                }
                if !emails.isEmpty {
                    mutable.emailAddresses = emails.map { CNLabeledValue(label: CNLabelHome, value: $0 as NSString) }
                }
                if let n = notes { mutable.note = n }
                let req = CNSaveRequest()
                req.update(mutable)
                try store.execute(req)
                let refreshed = try store.unifiedContact(withIdentifier: id, keysToFetch: Self.keysToFetch)
                print(JSON.encode(contactToDict(refreshed)))

            case "add_to_group":
                guard let cid = contactId, let gid = groupId else {
                    throw HelperError.invalidArg(service: "contacts", message: "add_to_group requires --contact-id --group-id")
                }
                let contact = try store.unifiedContact(withIdentifier: cid, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
                let groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [gid]))
                guard let group = groups.first else {
                    throw HelperError.notFound(service: "contacts", message: "No group with id \(gid)")
                }
                let req = CNSaveRequest()
                req.addMember(contact, to: group)
                try store.execute(req)
                print(#"{"ok":true}"#)

            case "remove_from_group":
                guard let cid = contactId, let gid = groupId else {
                    throw HelperError.invalidArg(service: "contacts", message: "remove_from_group requires --contact-id --group-id")
                }
                let contact = try store.unifiedContact(withIdentifier: cid, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
                let groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [gid]))
                guard let group = groups.first else {
                    throw HelperError.notFound(service: "contacts", message: "No group with id \(gid)")
                }
                let req = CNSaveRequest()
                req.removeMember(contact, from: group)
                try store.execute(req)
                print(#"{"ok":true}"#)

            default:
                throw HelperError.invalidArg(service: "contacts", message: "Unknown op: \(op)")
            }
        } catch let e as HelperError {
            e.writeAndExit()
        } catch let e as CNError where e.code == .authorizationDenied {
            HelperError.tccDenied(service: "contacts", message: "Contacts access was denied.").writeAndExit()
        } catch {
            HelperError.internalError(service: "contacts", message: String(describing: error)).writeAndExit()
        }
    }

    private func contactToDict(_ c: CNContact) -> [String: Any] {
        let note: String = {
            // CNContactNoteKey is restricted since macOS 13 — requires entitlement for some apps.
            // Ad-hoc signed binaries with usage-description may not get notes; fall back to "".
            if c.isKeyAvailable(CNContactNoteKey) { return (try? c.note) ?? "" }
            return ""
        }()
        return [
            "id": c.identifier,
            "first": c.givenName,
            "last": c.familyName,
            "organization": c.organizationName,
            "phones": c.phoneNumbers.map { ["label": CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? ""), "value": $0.value.stringValue] as [String: Any] },
            "emails": c.emailAddresses.map { ["label": CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? ""), "value": $0.value as String] as [String: Any] },
            "notes": note,
            "image_data": c.imageDataAvailable,
        ]
    }
}

extension CNContact {
    func isKeyAvailable(_ key: String) -> Bool {
        return (self as NSObject).responds(to: NSSelectorFromString(key))
    }
}
```

- [ ] **Step 2: Build + smoke test**

```bash
swift build
.build/debug/apple-helper contacts list_groups
```

Expected: permission dialog on first run; JSON array on subsequent.

- [ ] **Step 3: Commit**

```bash
git add Sources/AppleHelper/ContactsCommands.swift Sources/AppleHelper/RootCommand.swift
git commit -m "feat: Contacts ops (8) on Contacts framework directly"
```

---

### Task 8: `--request-permissions` flow

**Files:**
- Create: `Sources/AppleHelper/Permissions.swift`
- Modify: `Sources/AppleHelper/RootCommand.swift` — replace placeholder `RequestPermissionsCommand`

- [ ] **Step 1: Delete the placeholder RequestPermissionsCommand from RootCommand.swift**

- [ ] **Step 2: Write Permissions.swift**

```swift
// Sources/AppleHelper/Permissions.swift
import ArgumentParser
import Contacts
import EventKit
import Foundation

struct RequestPermissionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "request-permissions",
        abstract: "Serially request Calendar, Reminders, and Contacts access."
    )

    mutating func run() throws {
        let eventStore = EKEventStore()
        let contactStore = CNContactStore()

        // Run serially so the dialogs appear in predictable order.
        let calendarGranted = awaitGrant { completion in
            eventStore.requestFullAccessToEvents { granted, _ in completion(granted) }
        }
        if !calendarGranted {
            HelperError.tccDenied(service: "calendar", message: "Calendar access was denied.").writeAndExit()
        }

        let remindersGranted = awaitGrant { completion in
            eventStore.requestFullAccessToReminders { granted, _ in completion(granted) }
        }
        if !remindersGranted {
            HelperError.tccDenied(service: "reminders", message: "Reminders access was denied.").writeAndExit()
        }

        let contactsGranted = awaitGrant { completion in
            contactStore.requestAccess(for: .contacts) { granted, _ in completion(granted) }
        }
        if !contactsGranted {
            HelperError.tccDenied(service: "contacts", message: "Contacts access was denied.").writeAndExit()
        }

        print(#"{"ok":true,"granted":["calendar","reminders","contacts"]}"#)
    }

    /// Block until the provided async closure calls its completion with the grant result.
    private func awaitGrant(_ request: (@escaping (Bool) -> Void) -> Void) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var result = false
        request { granted in
            result = granted
            sem.signal()
        }
        sem.wait()
        return result
    }
}
```

- [ ] **Step 3: Build + verify**

```bash
swift build
.build/debug/apple-helper request-permissions
```

Expected on a fresh TCC state: three dialogs appear in order (Calendar → Reminders → Contacts). On each Allow click, the next appears. After all three, prints `{"ok":true,"granted":["calendar","reminders","contacts"]}`.

If grants already exist, prints the ok line immediately with no dialogs.

- [ ] **Step 4: Commit**

```bash
git add Sources/AppleHelper/Permissions.swift Sources/AppleHelper/RootCommand.swift
git commit -m "feat: --request-permissions serial dialog flow"
```

---

### Task 9: CI workflow — build universal + vendor PR

**Files:**
- Create: `.github/workflows/build-and-vendor.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/build-and-vendor.yml
name: Build universal binary and open vendor PR

on:
  push:
    tags:
      - 'apple-helper-v*'
  workflow_dispatch:

jobs:
  build:
    runs-on: macos-14
    outputs:
      version: ${{ steps.version.outputs.version }}
      sha256: ${{ steps.sha.outputs.sha256 }}
    steps:
      - uses: actions/checkout@v4

      - name: Extract version from tag
        id: version
        run: |
          VERSION="${GITHUB_REF_NAME#apple-helper-v}"
          if [ "$GITHUB_REF_TYPE" != "tag" ]; then
            VERSION="0.0.0-dev-${GITHUB_SHA::7}"
          fi
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          echo "Version: $VERSION"

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.4.app

      - name: Build universal binary
        run: |
          # Per Phase 0 R6: single command produces a fat Mach-O at
          # .build/apple/Products/Release/<product> (NOT .build/release/).
          swift build -c release --arch arm64 --arch x86_64
          mkdir -p dist
          cp .build/apple/Products/Release/apple-helper dist/apple-helper
          lipo -info dist/apple-helper

      - name: Ad-hoc sign
        run: codesign --force --sign - dist/apple-helper

      - name: Verify signature + architectures
        run: |
          codesign -vvv dist/apple-helper
          lipo -info dist/apple-helper | grep -q 'arm64' && lipo -info dist/apple-helper | grep -q 'x86_64'

      - name: Compute SHA256
        id: sha
        run: |
          SHA=$(shasum -a 256 dist/apple-helper | cut -d' ' -f1)
          echo "$SHA" > dist/apple-helper.sha256
          echo "sha256=$SHA" >> "$GITHUB_OUTPUT"

      - uses: actions/upload-artifact@v4
        with:
          name: apple-helper-universal
          path: dist/

  vendor-pr:
    needs: build
    if: startsWith(github.ref, 'refs/tags/apple-helper-v')
    runs-on: ubuntu-latest
    steps:
      - name: Check out wecoded-marketplace
        uses: actions/checkout@v4
        with:
          repository: itsdestin/wecoded-marketplace
          token: ${{ secrets.MARKETPLACE_PAT }}
          path: marketplace

      - uses: actions/download-artifact@v4
        with:
          name: apple-helper-universal
          path: artifact

      - name: Copy binary into plugin tree
        run: |
          mkdir -p marketplace/apple-services/bin
          cp artifact/apple-helper marketplace/apple-services/bin/apple-helper
          cp artifact/apple-helper.sha256 marketplace/apple-services/bin/apple-helper.sha256
          chmod +x marketplace/apple-services/bin/apple-helper

      - name: Create branch + PR
        env:
          GH_TOKEN: ${{ secrets.MARKETPLACE_PAT }}
          VERSION: ${{ needs.build.outputs.version }}
          SHA: ${{ needs.build.outputs.sha256 }}
        run: |
          cd marketplace
          BRANCH="vendor/apple-helper-v${VERSION}"
          git config user.name "apple-helper CI"
          git config user.email "ci@youcoded.app"
          git checkout -b "$BRANCH"
          git add apple-services/bin/apple-helper apple-services/bin/apple-helper.sha256
          git commit -m "vendor(apple-services): apple-helper v${VERSION}

Upstream: itsdestin/apple-helper@${{ github.sha }}
SHA256:   ${SHA}
Size:     $(wc -c < apple-services/bin/apple-helper) bytes"
          git push -u origin "$BRANCH"
          gh pr create \
            --title "vendor(apple-services): apple-helper v${VERSION}" \
            --body "Automated vendor PR from \`itsdestin/apple-helper\` release.

- Upstream tag: \`apple-helper-v${VERSION}\`
- Upstream SHA: \`${{ github.sha }}\`
- Binary SHA256: \`${SHA}\`

Merge to ship the updated binary to users." \
            --base master \
            --head "$BRANCH"
```

**Setup note:** this workflow requires a `MARKETPLACE_PAT` secret — a fine-grained PAT scoped to `itsdestin/wecoded-marketplace` with `Contents: Read/Write` + `Pull requests: Read/Write`. Create at https://github.com/settings/tokens?type=beta and add via `gh secret set MARKETPLACE_PAT --repo itsdestin/apple-helper`.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/build-and-vendor.yml
git commit -m "ci: build universal mach-o + open vendor PR on tag"
git push origin master
```

- [ ] **Step 3: Manual smoke build locally before tagging**

```bash
swift build -c release --arch arm64 --arch x86_64
lipo -info .build/apple/Products/Release/apple-helper
```

Expected: `Architectures in the fat file: ... are: x86_64 arm64` (order may vary).

If `lipo -info` reports only one arch, you're probably on an older SwiftPM. Falling back to a per-arch build + manual `lipo -create` works but needs Xcode-selected: `sudo xcode-select -s /Applications/Xcode_15.4.app`. The CI workflow uses a pinned Xcode to avoid this.

---

### Task 10: First release — tag v0.1.0

**Files:**
- None modified; tag only.

- [ ] **Step 1: Verify all prior tasks committed**

```bash
cd /c/Users/desti/apple-helper
git status
git log --oneline
```

Expected: clean working tree, 9-ish commits matching Tasks 1-9.

- [ ] **Step 2: Create + push the tag**

```bash
git tag -a apple-helper-v0.1.0 -m "apple-helper v0.1.0

Initial release. Covers Calendar (8 ops), Reminders (7 ops), Contacts (8 ops)
via EventKit + Contacts framework. Universal Mach-O, ad-hoc signed, macOS 14+."
git push origin apple-helper-v0.1.0
```

- [ ] **Step 3: Watch the CI build**

```bash
gh run watch
```

Expected: `build` job passes in ~5-8 min; `vendor-pr` job opens a PR against `itsdestin/wecoded-marketplace`.

- [ ] **Step 4: Locate the vendor PR but DO NOT merge yet**

```bash
gh pr list --repo itsdestin/wecoded-marketplace --head "vendor/apple-helper-v0.1.0"
```

Note the PR number. Merging this PR happens at Task 29 (after the plugin tree is ready to accept the binary).

**Checkpoint:** Phase 1 complete. Binary exists, is tested locally, and is ready to vendor. Move to Phase 2.

---

## Phase 2: Plugin tree (`wecoded-marketplace/apple-services/`)

### Task 11: Worktree + scaffold plugin directory

**Files:**
- Create: `wecoded-marketplace` worktree at `.worktrees/apple-services`
- Create: `wecoded-marketplace/apple-services/` (on feature branch)
- Create: `wecoded-marketplace/apple-services/.gitignore`

- [ ] **Step 1: Sync marketplace, create worktree**

```bash
cd /c/Users/desti/youcoded-dev/wecoded-marketplace
git fetch origin
git checkout master
git pull origin master
git worktree add -b feature/apple-services ../../.worktrees/apple-services master
cd ../../.worktrees/apple-services
```

- [ ] **Step 2: Create plugin dir + .gitignore**

```bash
mkdir -p apple-services/{commands,lib,bin,applescript/notes,applescript/mail,setup,skills,.dev}
cat > apple-services/.gitignore <<'EOF'
# Human-only dev docs, not shipped to users
.dev/
EOF
```

- [ ] **Step 3: Commit scaffold**

```bash
git add apple-services/.gitignore
git commit -m "feat(apple-services): scaffold plugin directory"
```

---

### Task 12: Write `plugin.json`

**Files:**
- Create: `apple-services/plugin.json`

- [ ] **Step 1: Write plugin.json**

```json
{
  "name": "apple-services",
  "description": "Calendar, Reminders, Contacts, Notes, Mail, and iCloud Drive in one setup. macOS only.",
  "version": "0.1.0",
  "author": { "name": "YouCoded" },
  "license": "MIT",
  "homepage": "https://github.com/itsdestin/wecoded-marketplace/tree/master/apple-services",
  "platforms": ["macos"],
  "attributions": [
    {
      "name": "iMCP",
      "url": "https://github.com/loopwork/iMCP",
      "license": "Apache-2.0",
      "scope": "Swift service modules (Calendar, Reminders, Contacts) compiled into bin/apple-helper"
    },
    {
      "name": "apple-mcp",
      "url": "https://github.com/Dhravya/apple-mcp",
      "license": "MIT",
      "scope": "AppleScript snippets for Notes and Mail"
    }
  ]
}
```

- [ ] **Step 2: Validate as JSON**

```bash
cat apple-services/plugin.json | python3 -m json.tool > /dev/null && echo "valid"
```

Expected: `valid`.

- [ ] **Step 3: Commit**

```bash
git add apple-services/plugin.json
git commit -m "feat(apple-services): plugin.json with platforms + attributions"
```

---

### Task 13: Write Notes AppleScript/JXA (7 files)

**Files:** (filenames match spec op names — snake_case — so the wrapper can do `$op.$ext` lookup)
- Create: `apple-services/applescript/notes/list_folders.applescript`
- Create: `apple-services/applescript/notes/list_notes.jxa`
- Create: `apple-services/applescript/notes/get_note.applescript`
- Create: `apple-services/applescript/notes/search_notes.jxa`
- Create: `apple-services/applescript/notes/create_note.applescript`
- Create: `apple-services/applescript/notes/update_note.applescript`
- Create: `apple-services/applescript/notes/delete_note.applescript`

**Phase 0 R4 finding:** upstream (`supermemoryai/apple-mcp`, formerly `Dhravya/apple-mcp`) embeds scripts in TypeScript (`utils/notes.ts`), and **every list-returning script returns `[]` because the author gave up on parsing AppleScript record lists via run-applescript**. Approach: extract the create/read/delete script bodies (those work) and rewrite all list-returning ops as **JXA** (JavaScript for Automation) which emits real JSON via `JSON.stringify`.

The wrapper (Task 15) dispatches either `.applescript` or `.jxa` based on file extension.

- [ ] **Step 1: Clone upstream for reference**

```bash
mkdir -p ~/reference
cd ~/reference
rm -rf apple-mcp
git clone https://github.com/supermemoryai/apple-mcp.git
cd apple-mcp
# SHA from R4:
VENDOR_SHA="08e2c53"
git checkout "$VENDOR_SHA"
```

Open `utils/notes.ts` in an editor — that's where all the Notes scripts live as backtick template strings inside methods like `createNote`, `findNote`, `getAllNotes`, `getNotesFromFolder`.

- [ ] **Step 2: Write list-folders.applescript (simple, count-returning only — no record lists)**

```bash
cd /c/Users/desti/youcoded-dev/.worktrees/apple-services
```

Create `apple-services/applescript/notes/list_folders.applescript`:

```applescript
on run argv
    tell application "Notes"
        set folderList to folders
        set output to "["
        set first_ to true
        repeat with f in folderList
            if not first_ then set output to output & ","
            set first_ to false
            set fName to name of f
            set fCount to count of notes of f
            set output to output & "{\"name\":" & my jsonStr(fName) & ",\"note_count\":" & fCount & "}"
        end repeat
        set output to output & "]"
        return output
    end tell
end run

on jsonStr(s)
    set escaped to ""
    repeat with ch in (characters of s)
        set c to ch as string
        if c is "\"" then
            set escaped to escaped & "\\\""
        else if c is "\\" then
            set escaped to escaped & "\\\\"
        else if c is return or c is linefeed then
            set escaped to escaped & "\\n"
        else if c is tab then
            set escaped to escaped & "\\t"
        else
            set escaped to escaped & c
        end if
    end repeat
    return "\"" & escaped & "\""
end jsonStr
```

- [ ] **Step 3: Write list_notes.jxa (uses JXA for clean JSON)**

Create `apple-services/applescript/notes/list_notes.jxa`:

```javascript
// Run with: osascript -l JavaScript list_notes.jxa [folderName]
function run(argv) {
    const Notes = Application('Notes');
    Notes.includeStandardAdditions = true;
    const folderFilter = argv[0] || '';

    let notesToShow;
    if (folderFilter) {
        const folder = Notes.folders.whose({name: folderFilter})[0];
        if (!folder) {
            return JSON.stringify({error: {code: 'NOT_FOUND', service: 'notes', message: `Folder not found: ${folderFilter}`, recovery: 'Check folder name.'}});
        }
        notesToShow = folder.notes();
    } else {
        notesToShow = Notes.notes();
    }

    const result = notesToShow.map(n => ({
        id: n.id(),
        name: n.name(),
        modified: n.modificationDate().toISOString(),
    }));
    return JSON.stringify(result);
}
```

- [ ] **Step 4: Write get_note.applescript**

Create `apple-services/applescript/notes/get_note.applescript`:

```applescript
on run argv
    if (count of argv) < 1 then error "get_note.applescript requires: <note-id>"
    set noteId to item 1 of argv
    tell application "Notes"
        set target_ to note id noteId
        set nName to name of target_
        set nBody to body of target_
        set nMod to modification date of target_
    end tell
    -- Return raw (not JSON) — wrapper will wrap.
    -- Format: id\tname\tISO-modified\tHTML-body
    return noteId & tab & nName & tab & (my iso(nMod)) & tab & nBody
end run

on iso(d)
    set {year_, month_, day_, hour_, min_, sec_} to {year of d, month of d as integer, day of d, hour of d, minutes of d, seconds of d}
    return (year_ as string) & "-" & my pad(month_) & "-" & my pad(day_) & "T" & my pad(hour_) & ":" & my pad(min_) & ":" & my pad(sec_)
end iso

on pad(n)
    if n < 10 then return "0" & n
    return n as string
end pad
```

Note: the wrapper (Task 15) parses this TSV output and runs HTML→markdown conversion before returning JSON to the skill. Keeping the AppleScript simple avoids JSON-escaping body HTML.

- [ ] **Step 5: Write search_notes.jxa**

Create `apple-services/applescript/notes/search_notes.jxa`:

```javascript
// Run with: osascript -l JavaScript search_notes.jxa <query> [folderName]
function run(argv) {
    const query = (argv[0] || '').toLowerCase();
    const folderFilter = argv[1] || '';
    if (!query) return JSON.stringify({error: {code: 'INVALID_ARG', service: 'notes', message: 'search requires a query', recovery: 'Pass the query as the first argument.'}});

    const Notes = Application('Notes');
    const source = folderFilter
        ? (Notes.folders.whose({name: folderFilter})[0] || {}).notes
        : Notes.notes;
    if (!source) return JSON.stringify([]);

    const results = [];
    for (const n of source()) {
        const name = n.name();
        const body = n.plaintext();  // plaintext strips HTML — good for snippet
        const hay = (name + ' ' + body).toLowerCase();
        if (hay.includes(query)) {
            const idx = hay.indexOf(query);
            const snippet = body.substring(Math.max(0, idx - 40), idx + query.length + 40);
            results.push({id: n.id(), name: name, snippet: snippet});
        }
        if (results.length >= 20) break;
    }
    return JSON.stringify(results);
}
```

- [ ] **Step 6: Write create_note.applescript (extracted + adapted from upstream)**

Create `apple-services/applescript/notes/create_note.applescript`. Reference: `utils/notes.ts` `createNote` method around lines 340-400 of upstream.

```applescript
on run argv
    if (count of argv) < 2 then error "create_note.applescript requires: <name> <body> [folder]"
    set noteName to item 1 of argv
    set noteBody to item 2 of argv
    set folderName to ""
    if (count of argv) >= 3 then set folderName to item 3 of argv

    tell application "Notes"
        if folderName is "" then
            set newNote to make new note with properties {name:noteName, body:noteBody}
        else
            try
                set targetFolder to first folder whose name is folderName
                set newNote to make new note at targetFolder with properties {name:noteName, body:noteBody}
            on error
                error "Folder not found: " & folderName
            end try
        end if
        set noteId to id of newNote
    end tell
    return "{\"id\":\"" & noteId & "\",\"name\":\"" & noteName & "\"}"
end run
```

- [ ] **Step 7: Write update_note.applescript**

Create `apple-services/applescript/notes/update_note.applescript`:

```applescript
on run argv
    if (count of argv) < 2 then error "update_note.applescript requires: <id> <body> [mode=replace|append|prepend]"
    set noteId to item 1 of argv
    set newBody to item 2 of argv
    set mode to "replace"
    if (count of argv) >= 3 then set mode to item 3 of argv

    tell application "Notes"
        set target_ to note id noteId
        if mode is "replace" then
            set body of target_ to newBody
        else if mode is "append" then
            set body of target_ to (body of target_) & "<br>" & newBody
        else if mode is "prepend" then
            set body of target_ to newBody & "<br>" & (body of target_)
        else
            error "Unknown mode: " & mode
        end if
        set nName to name of target_
    end tell
    return "{\"id\":\"" & noteId & "\",\"name\":\"" & nName & "\"}"
end run
```

- [ ] **Step 8: Write delete_note.applescript**

Create `apple-services/applescript/notes/delete_note.applescript`:

```applescript
on run argv
    if (count of argv) < 1 then error "delete_note.applescript requires: <id>"
    set noteId to item 1 of argv
    tell application "Notes"
        delete note id noteId
    end tell
    return "{\"ok\":true}"
end run
```

- [ ] **Step 9: Syntax-check each script**

```bash
for f in apple-services/applescript/notes/*.applescript; do
  echo "== $f"
  osascript -s o "$f" 2>&1 | head -3
done
for f in apple-services/applescript/notes/*.jxa; do
  echo "== $f"
  osascript -l JavaScript -s o "$f" 2>&1 | head -3
done
```

Expected: each file parses without syntax error. Missing-args errors are fine (scripts require argv).

- [ ] **Step 10: Commit**

```bash
git add apple-services/applescript/notes/
git commit -m "feat(apple-services): Notes AppleScript/JXA backends

AppleScript for create/update/read/delete (adapted from supermemoryai/apple-mcp
@ $VENDOR_SHA where upstream had working scripts). JXA for list/search because
upstream's AppleScript list-returning paths return [] due to run-applescript
record-parsing limitations — JXA's JSON.stringify gives us reliable output.

list-folders uses hand-rolled JSON escaping since it only returns simple
{name, note_count} records."
```

---

### Task 14: Write Mail AppleScript/JXA (6 files)

**Files:** (snake_case filenames match spec op names)
- Create: `apple-services/applescript/mail/list_mailboxes.jxa`
- Create: `apple-services/applescript/mail/search.jxa`
- Create: `apple-services/applescript/mail/read_message.applescript`
- Create: `apple-services/applescript/mail/send.applescript`
- Create: `apple-services/applescript/mail/create_draft.applescript`
- Create: `apple-services/applescript/mail/mark_read.applescript`
- Create: `apple-services/applescript/mail/mark_unread.applescript` (thin wrapper — same script with unread=1)

**Phase 0 R4 finding:** upstream has only `sendMail` (without attachments) + `getMailboxesForAccount` in a directly-usable shape. All list/search paths return `[]`. We write list-mailboxes + search as JXA (reliable JSON); use AppleScript for read/send/create-draft/mark-read where upstream works or the op is simple.

- [ ] **Step 1: Write list_mailboxes.jxa**

```javascript
// osascript -l JavaScript list_mailboxes.jxa [accountName]
function run(argv) {
    const Mail = Application('Mail');
    const filterAccount = argv[0] || '';
    const result = [];
    const accounts = filterAccount
        ? Mail.accounts.whose({name: filterAccount})()
        : Mail.accounts();
    for (const acct of accounts) {
        for (const box of acct.mailboxes()) {
            result.push({
                name: box.name(),
                account: acct.name(),
                unread_count: box.unreadCount(),
            });
        }
    }
    return JSON.stringify(result);
}
```

- [ ] **Step 2: Write search.jxa**

```javascript
// osascript -l JavaScript search.jxa <query> [mailbox] [from] [to] [since ISO] [limit]
function run(argv) {
    const query = (argv[0] || '').toLowerCase();
    const mailbox = argv[1] || '';
    const from = (argv[2] || '').toLowerCase();
    const to = (argv[3] || '').toLowerCase();
    const sinceStr = argv[4] || '';
    const limit = parseInt(argv[5] || '50', 10);
    const sinceDate = sinceStr ? new Date(sinceStr) : null;

    const Mail = Application('Mail');
    const results = [];

    for (const acct of Mail.accounts()) {
        for (const box of acct.mailboxes()) {
            if (mailbox && box.name() !== mailbox) continue;
            for (const msg of box.messages()) {
                try {
                    const subj = (msg.subject() || '').toLowerCase();
                    const sender = (msg.sender() || '').toLowerCase();
                    const recips = (msg.toRecipients.address() || []).join(' ').toLowerCase();
                    const preview = (msg.content() || '').substring(0, 200).toLowerCase();
                    if (query && !(subj + ' ' + preview).includes(query)) continue;
                    if (from && !sender.includes(from)) continue;
                    if (to && !recips.includes(to)) continue;
                    if (sinceDate) {
                        const d = new Date(msg.dateSent());
                        if (d < sinceDate) continue;
                    }
                    results.push({
                        id: msg.id(),
                        from: msg.sender(),
                        subject: msg.subject(),
                        date: new Date(msg.dateSent()).toISOString(),
                        preview: (msg.content() || '').substring(0, 200),
                    });
                    if (results.length >= limit) return JSON.stringify(results);
                } catch (e) { /* skip problematic messages */ }
            }
        }
    }
    return JSON.stringify(results);
}
```

- [ ] **Step 3: Write read_message.applescript**

```applescript
on run argv
    if (count of argv) < 1 then error "read_message.applescript requires: <message-id>"
    set msgId to item 1 of argv
    tell application "Mail"
        -- Mail message IDs are scoped to their mailbox; search across all.
        set foundMsg to missing value
        repeat with acct in accounts
            repeat with box in mailboxes of acct
                try
                    set foundMsg to (first message of box whose id is msgId)
                    exit repeat
                end try
            end repeat
            if foundMsg is not missing value then exit repeat
        end repeat
        if foundMsg is missing value then error "Message not found: " & msgId
        set msgFrom to sender of foundMsg
        set msgSubject to subject of foundMsg
        set msgDate to date sent of foundMsg
        set msgBody to content of foundMsg
    end tell
    -- TSV: id\tfrom\tsubject\tISO-date\tbody. Wrapper converts to JSON.
    return msgId & tab & msgFrom & tab & msgSubject & tab & (my iso(msgDate)) & tab & msgBody
end run

on iso(d)
    set {year_, month_, day_, hour_, min_, sec_} to {year of d, month of d as integer, day of d, hour of d, minutes of d, seconds of d}
    return (year_ as string) & "-" & my pad(month_) & "-" & my pad(day_) & "T" & my pad(hour_) & ":" & my pad(min_) & ":" & my pad(sec_)
end iso

on pad(n)
    if n < 10 then return "0" & n
    return n as string
end pad
```

- [ ] **Step 4: Write send.applescript** (reference: upstream `sendMail` in `utils/mail.ts`)

```applescript
on run argv
    if (count of argv) < 3 then error "send.applescript requires: <to-csv> <subject> <body> [cc-csv] [bcc-csv] [attach-paths-csv]"
    set recipientList to item 1 of argv
    set msgSubject to item 2 of argv
    set msgBody to item 3 of argv
    set ccList to ""
    set bccList to ""
    set attachList to ""
    if (count of argv) >= 4 then set ccList to item 4 of argv
    if (count of argv) >= 5 then set bccList to item 5 of argv
    if (count of argv) >= 6 then set attachList to item 6 of argv

    tell application "Mail"
        set newMsg to make new outgoing message with properties {subject:msgSubject, content:msgBody, visible:false}
        tell newMsg
            repeat with r in (my splitCSV(recipientList))
                if r is not "" then
                    make new to recipient at end of to recipients with properties {address:r}
                end if
            end repeat
            repeat with r in (my splitCSV(ccList))
                if r is not "" then
                    make new cc recipient at end of cc recipients with properties {address:r}
                end if
            end repeat
            repeat with r in (my splitCSV(bccList))
                if r is not "" then
                    make new bcc recipient at end of bcc recipients with properties {address:r}
                end if
            end repeat
            repeat with p in (my splitCSV(attachList))
                if p is not "" then
                    try
                        make new attachment with properties {file name:(POSIX file p)} at after the last paragraph
                    end try
                end if
            end repeat
            send
        end tell
    end tell
    return "{\"ok\":true}"
end run

on splitCSV(s)
    if s is "" then return {}
    set AppleScript's text item delimiters to ","
    set parts to text items of s
    set AppleScript's text item delimiters to ""
    return parts
end splitCSV
```

- [ ] **Step 5: Write create_draft.applescript**

Same args as `send`, but saves instead of sending:

```applescript
on run argv
    if (count of argv) < 3 then error "create_draft.applescript requires: <to-csv> <subject> <body> [cc-csv] [bcc-csv]"
    set recipientList to item 1 of argv
    set msgSubject to item 2 of argv
    set msgBody to item 3 of argv
    set ccList to ""
    set bccList to ""
    if (count of argv) >= 4 then set ccList to item 4 of argv
    if (count of argv) >= 5 then set bccList to item 5 of argv

    tell application "Mail"
        set newMsg to make new outgoing message with properties {subject:msgSubject, content:msgBody, visible:true}
        tell newMsg
            repeat with r in (my splitCSV(recipientList))
                if r is not "" then
                    make new to recipient at end of to recipients with properties {address:r}
                end if
            end repeat
            repeat with r in (my splitCSV(ccList))
                if r is not "" then
                    make new cc recipient at end of cc recipients with properties {address:r}
                end if
            end repeat
            repeat with r in (my splitCSV(bccList))
                if r is not "" then
                    make new bcc recipient at end of bcc recipients with properties {address:r}
                end if
            end repeat
            save
            set draftId to id of it
        end tell
    end tell
    return "{\"id\":\"" & draftId & "\"}"
end run

on splitCSV(s)
    if s is "" then return {}
    set AppleScript's text item delimiters to ","
    set parts to text items of s
    set AppleScript's text item delimiters to ""
    return parts
end splitCSV
```

- [ ] **Step 6: Write mark_read.applescript and mark_unread.applescript**

Both scripts share the same logic; `mark_unread` just sets the read-status bit differently. Write them as two thin files so the wrapper's filename-based dispatch works without arg translation.

`apple-services/applescript/mail/mark_read.applescript`:

```applescript
on run argv
    if (count of argv) < 1 then error "mark_read.applescript requires: <message-id>"
    set msgId to item 1 of argv
    tell application "Mail"
        set foundMsg to missing value
        repeat with acct in accounts
            repeat with box in mailboxes of acct
                try
                    set foundMsg to (first message of box whose id is msgId)
                    exit repeat
                end try
            end repeat
            if foundMsg is not missing value then exit repeat
        end repeat
        if foundMsg is missing value then error "Message not found: " & msgId
        set read status of foundMsg to true
    end tell
    return "{\"ok\":true}"
end run
```

`apple-services/applescript/mail/mark_unread.applescript`:

```applescript
on run argv
    if (count of argv) < 1 then error "mark_unread.applescript requires: <message-id>"
    set msgId to item 1 of argv
    tell application "Mail"
        set foundMsg to missing value
        repeat with acct in accounts
            repeat with box in mailboxes of acct
                try
                    set foundMsg to (first message of box whose id is msgId)
                    exit repeat
                end try
            end repeat
            if foundMsg is not missing value then exit repeat
        end repeat
        if foundMsg is missing value then error "Message not found: " & msgId
        set read status of foundMsg to false
    end tell
    return "{\"ok\":true}"
end run
```

- [ ] **Step 7: Syntax-check + commit**

```bash
for f in apple-services/applescript/mail/*.applescript; do
  echo "== $f"
  osascript -s o "$f" 2>&1 | head -3
done
for f in apple-services/applescript/mail/*.jxa; do
  echo "== $f"
  osascript -l JavaScript -s o "$f" 2>&1 | head -3
done

git add apple-services/applescript/mail/
git commit -m "feat(apple-services): Mail AppleScript/JXA backends

JXA for list-mailboxes + search (reliable JSON); AppleScript for
read/send/create-draft/mark-read. read.applescript emits TSV for
wrapper JSON-wrapping. Scripts reference supermemoryai/apple-mcp
@ $VENDOR_SHA where upstream had working create/send paths; rewrote
list-returning paths using JXA."
```

---

### Task 15: Write `lib/apple-wrapper.sh`

**Files:**
- Create: `apple-services/lib/apple-wrapper.sh`

This is the single entry point for all skills. Dispatches by `$1` (integration) and `$2` (op) to helper binary / osascript / bash.

- [ ] **Step 1: Write the wrapper**

```bash
#!/usr/bin/env bash
# apple-wrapper.sh — single entry point dispatching apple-services ops to
# the Swift helper binary, AppleScript, or pure bash (iCloud).
#
# WHY single wrapper: keeps error envelope + TCC_DENIED handling in one place
# instead of duplicated across helper/osascript wrappers.
#
# Usage:   apple-wrapper.sh <integration> <op> [--arg value ...]
# Example: apple-wrapper.sh calendar list_events --from 2026-04-17 --to 2026-04-24

set -u

PLUGIN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER_BIN="${APPLE_HELPER_BIN:-$HOME/.apple-services/bin/apple-helper}"
ICLOUD_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
LOCK_DIR="${TMPDIR:-/tmp}"

# ─── Error envelope + exit helpers (defined first so input checks can use) ──

err_out() {
  # err_out <code> <service> <message> <recovery>
  local code="$1" service="$2" msg="$3" recovery="$4"
  jq -cn \
    --arg c "$code" --arg s "$service" --arg m "$msg" --arg r "$recovery" \
    '{error: {code: $c, service: $s, message: $m, recovery: $r}}' >&2
  [ "$code" = "TCC_DENIED" ] && { echo "TCC_DENIED:$service" >&2; exit 2; }
  exit 1
}

# ─── Dependency check ───────────────────────────────────────────────────────

command -v jq >/dev/null 2>&1 || {
  echo '{"error":{"code":"UNAVAILABLE","service":"wrapper","message":"jq is not installed. Apple Services needs jq to format output.","recovery":"Install jq (brew install jq), then retry."}}' >&2
  exit 1
}

# ─── Args ───────────────────────────────────────────────────────────────────

integration="${1:-}"
op="${2:-}"
shift 2 2>/dev/null || true

if [ -z "$integration" ] || [ -z "$op" ]; then
  err_out INVALID_ARG wrapper "Usage: apple-wrapper.sh <integration> <op> [args]" "See skills/<integration>/SKILL.md"
fi

# ─── Per-op timeout selection ───────────────────────────────────────────────

op_timeout() {
  case "$op" in
    search|search_*) echo 60 ;;
    list_*|get_*|list) echo 15 ;;
    create_*|update_*|delete_*|send|mark_*|add_to_*|remove_from_*|complete_*) echo 20 ;;
    *) echo 15 ;;
  esac
}

# ─── Helper-binary routing (calendar, reminders, contacts) ──────────────────

route_helper() {
  [ -x "$HELPER_BIN" ] || err_out UNAVAILABLE "$integration" \
    "The Apple Services helper isn't installed at $HELPER_BIN." \
    "Run /apple-services-setup."

  local timeout; timeout=$(op_timeout)
  local stderr_file; stderr_file="$(mktemp)"

  if timeout "$timeout" "$HELPER_BIN" "$integration" "$op" "$@" 2> "$stderr_file"; then
    rm -f "$stderr_file"
    return 0
  fi

  local exit_code=$?
  if grep -q "^TCC_DENIED:" "$stderr_file"; then
    cat "$stderr_file" >&2
    rm -f "$stderr_file"
    exit 2
  fi

  if [ "$exit_code" = 124 ]; then
    err_out UNAVAILABLE "$integration" "Helper call timed out after ${timeout}s." "Retry; if persistent, re-run /apple-services-setup."
  fi

  cat "$stderr_file" >&2
  rm -f "$stderr_file"
  exit "$exit_code"
}

# ─── AppleScript routing (notes, mail) ──────────────────────────────────────

route_applescript() {
  # Dispatch by file extension: .jxa for JavaScript (for list-returning ops
  # where AppleScript record-list parsing is broken upstream — see Phase 0
  # R4), .applescript for everything else.
  local script osascript_lang
  if [ -f "$PLUGIN_DIR/applescript/$integration/$op.jxa" ]; then
    script="$PLUGIN_DIR/applescript/$integration/$op.jxa"
    osascript_lang=(-l JavaScript)
  elif [ -f "$PLUGIN_DIR/applescript/$integration/$op.applescript" ]; then
    script="$PLUGIN_DIR/applescript/$integration/$op.applescript"
    osascript_lang=()
  else
    err_out INVALID_ARG "$integration" "Unknown op: $op" "See skills/$integration/SKILL.md for op list."
  fi

  # Serialize concurrent calls to the same target app — AppleScript talks to
  # the live app process and two parallel osascripts fighting over Mail.app
  # will occasionally error out.
  local lock="$LOCK_DIR/apple-services.$integration.lock"
  exec 9> "$lock" || err_out INTERNAL "$integration" "Couldn't acquire lock $lock" "Free disk space in TMPDIR."
  flock -w 30 9 || err_out UNAVAILABLE "$integration" "$integration lock busy for 30s." "Retry; another skill call may be running."

  local timeout; timeout=$(op_timeout)
  local stderr_file; stderr_file="$(mktemp)"
  local stdout_file; stdout_file="$(mktemp)"

  if timeout "$timeout" osascript "${osascript_lang[@]}" "$script" "$@" > "$stdout_file" 2> "$stderr_file"; then
    # Post-process TSV-emitting AppleScript ops (notes/get_note, mail/read_message)
    # into JSON. These scripts return tab-separated fields because JSON-escaping
    # HTML bodies from AppleScript is painful.
    post_process_applescript_output < "$stdout_file"
    rm -f "$stderr_file" "$stdout_file"
    return 0
  fi

  local exit_code=$?
  # AppleScript Automation denial surfaces as error -1743
  if grep -qE '\(-1743\)' "$stderr_file"; then
    err_out TCC_DENIED "$integration" "Automation access to $integration was denied." "Open System Settings → Privacy & Security → Automation, find your Claude host app, turn on $integration. Then re-run."
  fi

  # Application isn't running / not installed
  if grep -qE "Application isn.t running|not allowed to send Apple events|Can.t get application" "$stderr_file"; then
    err_out UNAVAILABLE "$integration" "$integration isn't ready." "Open $integration.app, finish any first-run setup, then retry."
  fi

  if [ "$exit_code" = 124 ]; then
    err_out UNAVAILABLE "$integration" "$integration op timed out after ${timeout}s." "The app may be stuck; quit it and retry."
  fi

  local msg; msg=$(head -c 500 < "$stderr_file" | tr '\n' ' ')
  rm -f "$stderr_file" "$stdout_file"
  err_out INTERNAL "$integration" "$msg" "Check Console.app logs for $integration.app errors."
}

# Convert TSV-shaped AppleScript output for specific ops into JSON.
# Ops that return TSV (from Tasks 13/14): notes/get_note, mail/read_message.
# All other ops return JSON already and pass through unchanged.
post_process_applescript_output() {
  local raw; raw=$(cat)
  case "$integration/$op" in
    notes/get_note)
      # Format: id\tname\tISO-modified\tHTML-body
      jq -cn --arg raw "$raw" '
        ($raw | split("\t")) as $parts
        | {id: $parts[0], name: $parts[1], modified: $parts[2], body_markdown: (($parts[3:] | join("\t")) | html_to_md_placeholder)}
      ' 2>/dev/null \
      || jq -cn --arg raw "$raw" '
        ($raw | split("\t")) as $parts
        | {id: $parts[0], name: $parts[1], modified: $parts[2], body_markdown: ($parts[3:] | join("\t"))}
      '
      # Note: real HTML→markdown conversion would need pandoc or similar.
      # v1 returns the raw HTML as body_markdown; skill's SKILL.md documents this.
      ;;
    mail/read_message)
      # Format: id\tfrom\tsubject\tISO-date\tbody
      jq -cn --arg raw "$raw" '
        ($raw | split("\t")) as $parts
        | {id: $parts[0], from: $parts[1], subject: $parts[2], date: $parts[3], body_text: ($parts[4:] | join("\t")), to: [], cc: [], attachments: []}
      '
      ;;
    *)
      printf '%s' "$raw"
      ;;
  esac
}

# ─── iCloud filesystem routing ──────────────────────────────────────────────

route_icloud() {
  # All iCloud ops take --path relative to ICLOUD_ROOT.
  local path="" content="" src="" dst=""
  local recursive=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --path) path="$2"; shift 2 ;;
      --content) content="$2"; shift 2 ;;
      --src) src="$2"; shift 2 ;;
      --dst) dst="$2"; shift 2 ;;
      --recursive) recursive=1; shift ;;
      *) shift ;;
    esac
  done

  resolve() {
    # Reject paths escaping ICLOUD_ROOT
    local rel="$1"
    local abs; abs="$(cd "$ICLOUD_ROOT" 2>/dev/null && cd "$(dirname "./$rel")" 2>/dev/null && pwd)/$(basename "./$rel")" || true
    case "$abs" in
      "$ICLOUD_ROOT"/*|"$ICLOUD_ROOT") echo "$abs" ;;
      *) err_out INVALID_ARG icloud "Path escapes iCloud Drive root: $rel" "Pass paths relative to iCloud Drive root." ;;
    esac
  }

  case "$op" in
    list)
      local full; full=$(resolve "$path")
      [ -d "$full" ] || err_out NOT_FOUND icloud "Not a directory: $path" "Check the path."
      local find_args=(-mindepth 1)
      [ "$recursive" = 0 ] && find_args+=(-maxdepth 1)
      find "$full" "${find_args[@]}" -print0 2>/dev/null | while IFS= read -r -d '' entry; do
        local base; base="$(basename "$entry")"
        # Two iCloud placeholder representations (Phase 0 R8):
        # 1. Legacy dot-prefixed .icloud stubs (pre-Sonoma filesystems):
        if [[ "$base" == .*.icloud ]]; then
          local real_name="${base#.}"; real_name="${real_name%.icloud}"
          jq -cn --arg n "$real_name" --arg t "placeholder" '{name: $n, type: $t, size: 0, modified: null}'
          continue
        fi
        # 2. APFS dataless files (Sonoma+ default): SF_DATALESS flag (0x40000000)
        #    set in st_flags. stat -f%Xf gives flags in hex.
        if [ -f "$entry" ]; then
          local flags; flags=$(stat -f%Xf "$entry" 2>/dev/null || echo 0)
          # Bash doesn't do hex bitwise AND easily; use printf + shell arithmetic.
          local flags_dec; flags_dec=$(printf '%d' "0x$flags" 2>/dev/null || echo 0)
          if (( (flags_dec & 0x40000000) != 0 )); then
            local size; size=$(stat -f%z "$entry")
            local modified; modified=$(date -u -r "$(stat -f%m "$entry")" +%Y-%m-%dT%H:%M:%SZ)
            jq -cn --arg n "$base" --arg t "placeholder" --argjson s "$size" --arg m "$modified" '{name: $n, type: $t, size: $s, modified: $m}'
            continue
          fi
        fi
        # Normal entry
        local type size modified
        if [ -d "$entry" ]; then type=dir; size=0;
        else type=file; size=$(stat -f%z "$entry"); fi
        modified=$(date -u -r "$(stat -f%m "$entry")" +%Y-%m-%dT%H:%M:%SZ)
        jq -cn --arg n "$base" --arg t "$type" --argjson s "$size" --arg m "$modified" '{name: $n, type: $t, size: $s, modified: $m}'
      done | jq -cs .
      ;;
    read)
      local full; full=$(resolve "$path")
      local base; base="$(basename "$full")"
      # Reject legacy .icloud stub (file wouldn't even exist at the cleaned name)
      if [ -e "$(dirname "$full")/.${base}.icloud" ]; then
        err_out UNAVAILABLE icloud "This file is in iCloud but not downloaded." "Open Finder, right-click the file, Download Now, then retry."
      fi
      [ -f "$full" ] || err_out NOT_FOUND icloud "Not a file: $path" "Check the path."
      # Reject SF_DATALESS dataless file — reading it would trigger a sync
      # download that can stall for many seconds on slow networks.
      local flags; flags=$(stat -f%Xf "$full" 2>/dev/null || echo 0)
      local flags_dec; flags_dec=$(printf '%d' "0x$flags" 2>/dev/null || echo 0)
      if (( (flags_dec & 0x40000000) != 0 )); then
        err_out UNAVAILABLE icloud "This file is in iCloud but not downloaded locally yet." "Open Finder, right-click the file, Download Now, then retry."
      fi
      if file --mime-encoding "$full" | grep -q 'binary'; then
        local size; size=$(stat -f%z "$full")
        local type; type=$(file --mime-type -b "$full")
        jq -cn --argjson b true --arg t "$type" --argjson s "$size" '{binary: $b, type: $t, size: $s}'
      else
        jq -Rs . < "$full"
      fi
      ;;
    write)
      local full; full=$(resolve "$path")
      mkdir -p "$(dirname "$full")"
      printf '%s' "$content" > "$full"
      echo '{"ok":true}'
      ;;
    delete)
      local full; full=$(resolve "$path")
      [ -e "$full" ] || err_out NOT_FOUND icloud "Not found: $path" "Check the path."
      rm -rf -- "$full"
      echo '{"ok":true}'
      ;;
    move)
      local srcFull; srcFull=$(resolve "$src")
      local dstFull; dstFull=$(resolve "$dst")
      mkdir -p "$(dirname "$dstFull")"
      mv "$srcFull" "$dstFull"
      echo '{"ok":true}'
      ;;
    create_folder)
      local full; full=$(resolve "$path")
      mkdir -p "$full"
      echo '{"ok":true}'
      ;;
    stat)
      local full; full=$(resolve "$path")
      [ -e "$full" ] || err_out NOT_FOUND icloud "Not found: $path" "Check the path."
      local name type size modified
      name=$(basename "$full")
      if [ -d "$full" ]; then type=dir; size=0; else type=file; size=$(stat -f%z "$full"); fi
      modified=$(date -u -r "$(stat -f%m "$full")" +%Y-%m-%dT%H:%M:%SZ)
      jq -cn --arg n "$name" --arg t "$type" --argjson s "$size" --arg m "$modified" '{name: $n, type: $t, size: $s, modified: $m}'
      ;;
    *)
      err_out INVALID_ARG icloud "Unknown op: $op" "See skills/icloud-drive/SKILL.md."
      ;;
  esac
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

case "$integration" in
  calendar|reminders|contacts) route_helper "$@" ;;
  notes|mail) route_applescript "$@" ;;
  icloud) route_icloud "$@" ;;
  *) err_out INVALID_ARG wrapper "Unknown integration: $integration" "One of: calendar, reminders, contacts, notes, mail, icloud" ;;
esac
```

- [ ] **Step 2: Mark executable + set Git executable bit**

```bash
chmod +x apple-services/lib/apple-wrapper.sh
git update-index --chmod=+x apple-services/lib/apple-wrapper.sh
```

- [ ] **Step 3: Run shellcheck**

```bash
shellcheck apple-services/lib/apple-wrapper.sh
```

Expected: no errors (warnings about `$@` inside functions are OK).

- [ ] **Step 4: Smoke-test (requires apple-helper binary installed)**

Skip if Phase 1 binary isn't installed yet. Otherwise:

```bash
APPLE_HELPER_BIN=/c/Users/desti/apple-helper/.build/release/apple-helper \
  apple-services/lib/apple-wrapper.sh calendar list_calendars
```

Expected: JSON array of calendars.

```bash
apple-services/lib/apple-wrapper.sh icloud list --path ""
```

Expected: JSON array of iCloud Drive root entries.

- [ ] **Step 5: Commit**

```bash
git add apple-services/lib/apple-wrapper.sh
git commit -m "feat(apple-services): unified apple-wrapper.sh with helper+osascript+fs routing"
```

---

### Task 16: `/apple-services-setup` — Steps 1–3 (platform, binary install, iCloud check)

**Files:**
- Create: `apple-services/commands/apple-services-setup.md`

The setup command is a slash command — a markdown file where each top-level section is a step Claude executes. Modeled on `google-services/commands/google-services-setup.md`.

- [ ] **Step 1: Write the command file header + Steps 1-3**

```markdown
---
description: "Set up Apple Services (Calendar, Reminders, Contacts, Notes, Mail, iCloud Drive) with one command. Installs helper, grants macOS permissions, and verifies each service."
---

Run the Apple Services setup. Follow the steps below in order.

## How to talk to the user

Behind the scenes, this setup runs small helpers that do technical work. The user should never see that work — only what's happening in plain, everyday words.

**When things are going well:** one short, human sentence, or nothing at all. "Apple apps are connected." "You're all set."

**When something doesn't work:** give the user a brief, plain-language sense of what kind of problem it was, then offer a choice using `AskUserQuestion` — you look into it, or they retry later.

Pick the line that best matches where things fell apart:

- macOS version too old: "Apple Services needs a newer version of macOS."
- iCloud Drive off: "iCloud Drive isn't turned on."
- Helper not installed: "The setup helper didn't install properly."
- Permissions denied: "Apple apps access wasn't granted."
- Smoke test failure: "One or more Apple apps didn't respond."

Then ask:

- **question:** "Want me to look into it, or try again later?"
- **header:** "Setup hit a snag"
- **options:**
  - label: "Look into it" — description: "I'll investigate and try to fix it."
  - label: "Try again later" — description: "Run /apple-services-setup again whenever you're ready."

### Words to never say to the user

Any helper's name, CLI, API, framework, TCC, AppleScript, osascript, xattr, codesign, terminal, shell, binary, Mach-O, file, folder, directory, path, exit code, SHA, JSON, Press Enter.

### Words that are fine

Calendar, Reminders, Contacts, Notes, Mail, iCloud Drive, "Apple apps," "your Mac," "permission," "allow," "all set," "let's try that again."

### Gates between steps

Every gate between steps uses `AskUserQuestion`. YouCoded is a chat — the user can't press Enter at a terminal. If a step tells you to "run this script" or "show the dialog," just do it — no extra "Ready?" confirmation.

---

## Step 0 — Acknowledge start

Send in chat:

> Getting Apple apps ready for YouCoded...

Silently set up the session:

```bash
export PLUGIN_DIR="$HOME/.claude/plugins/marketplaces/youcoded/plugins/apple-services"
# Dev fallback: if not installed via marketplace, fall back to the sibling checkout
if [ ! -d "$PLUGIN_DIR" ]; then
  for candidate in "$HOME/youcoded-dev/wecoded-marketplace/apple-services" "$HOME/youcoded-dev/.worktrees/apple-services/apple-services"; do
    [ -d "$candidate" ] && { export PLUGIN_DIR="$candidate"; break; }
  done
fi
```

## Step 1 — Platform + version + dependency check

Run:

```bash
if [ "$(uname)" != "Darwin" ]; then
  echo "PLATFORM_NOT_MAC"; exit 1
fi
macos_major=$(sw_vers -productVersion | cut -d. -f1)
if [ "$macos_major" -lt 14 ]; then
  echo "MACOS_TOO_OLD $(sw_vers -productVersion)"; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "JQ_MISSING"; exit 1
fi
echo "OK"
```

Handle the output:
- `OK` → continue to Step 2.
- `PLATFORM_NOT_MAC` → send "Apple Services only runs on a Mac — you can install it when you're on one." and stop.
- `MACOS_TOO_OLD X.Y` → send "Apple Services needs macOS 14 (Sonoma) or newer — you're on X.Y. Update macOS from System Settings → General → Software Update, then run this again." and stop.
- `JQ_MISSING` → send "Apple Services needs a small tool called **jq** to format results. Open Terminal and run: `brew install jq` — then come back and run `/apple-services-setup` again. If you don't have Homebrew, install it from https://brew.sh first." and stop.

## Step 2 — Install the helper to a stable path

Run:

```bash
install_dir="$HOME/.apple-services/bin"
mkdir -p "$install_dir"

if [ ! -f "$PLUGIN_DIR/bin/apple-helper" ]; then
  echo "HELPER_MISSING"; exit 1
fi

expected_sha=$(cat "$PLUGIN_DIR/bin/apple-helper.sha256")

# Idempotent: if installed binary matches, skip the copy (preserves TCC grants).
if [ -f "$install_dir/apple-helper" ]; then
  actual_sha=$(shasum -a 256 "$install_dir/apple-helper" | cut -d' ' -f1)
  if [ "$actual_sha" = "$expected_sha" ]; then
    echo "OK_ALREADY"
    exit 0
  fi
fi

cp "$PLUGIN_DIR/bin/apple-helper" "$install_dir/apple-helper"
xattr -d com.apple.quarantine "$install_dir/apple-helper" 2>/dev/null || true
chmod +x "$install_dir/apple-helper"

actual_sha=$(shasum -a 256 "$install_dir/apple-helper" | cut -d' ' -f1)
[ "$expected_sha" = "$actual_sha" ] || { echo "SHA_MISMATCH $expected_sha $actual_sha"; exit 1; }

echo "OK_INSTALLED"
```

Handle:
- `OK_ALREADY` or `OK_INSTALLED` → continue.
- `HELPER_MISSING` → send "The setup helper isn't in your plugin install — try reinstalling Apple Services from the marketplace." and stop.
- `SHA_MISMATCH ...` → send "The setup helper didn't match its expected fingerprint — your plugin install may be damaged. Reinstall Apple Services from the marketplace." and stop.

Before continuing, if `OK_INSTALLED`, send: "Setting up a small tool that lets Claude talk to your Apple apps. One-time, happens locally on your Mac."

## Step 3 — iCloud Drive availability check

Run:

```bash
if [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]; then
  echo "OK"
else
  echo "MISSING"
fi
```

Handle:
- `OK` → continue.
- `MISSING` → send "iCloud Drive isn't turned on. Open System Settings → your name at the top → iCloud → iCloud Drive, turn it on, then run this again." and stop.
```

- [ ] **Step 2: Commit partial**

```bash
git add apple-services/commands/apple-services-setup.md
git commit -m "feat(apple-services): setup command steps 1-3 (platform + binary + iCloud)"
```

---

### Task 17: `/apple-services-setup` — Steps 4–5 (permissions)

**Files:**
- Modify: `apple-services/commands/apple-services-setup.md` — append Steps 4–5

- [ ] **Step 1: Append Steps 4-5**

Open `apple-services/commands/apple-services-setup.md` and append (after Step 3):

```markdown
## Step 4 — Calendar, Reminders, Contacts permissions

Before running the helper, detect which app macOS will attribute Automation prompts to:

```bash
# Walk up from our PID; take the first ancestor that isn't bash/zsh/sh.
host_pid=$PPID
while true; do
  comm=$(ps -o comm= -p "$host_pid" 2>/dev/null | xargs basename 2>/dev/null || echo "")
  case "$comm" in
    bash|zsh|sh|-bash|-zsh) host_pid=$(ps -o ppid= -p "$host_pid" | xargs); [ "$host_pid" = 1 ] && break ;;
    *) break ;;
  esac
done
host_app=$(ps -o comm= -p "$host_pid" 2>/dev/null | xargs basename 2>/dev/null || echo "Terminal")
# Friendly name
case "$host_app" in
  YouCoded|youcoded) host_friendly="YouCoded" ;;
  iTerm2|iTerm) host_friendly="iTerm" ;;
  Terminal) host_friendly="Terminal" ;;
  *) host_friendly="$host_app" ;;
esac
echo "$host_friendly"
```

Remember `host_friendly` — you'll reuse it in Step 5.

Send this pre-frame (substituting — don't show the variable to the user):

> macOS is about to show three permission dialogs, in this order: Calendar, then Reminders, then Contacts. Each will ask whether a tool called **apple-helper** can access that data. Click **Allow** on all three.

Then run:

```bash
~/.apple-services/bin/apple-helper request-permissions 2>&1
```

Handle the output:
- Contains `{"ok":true,"granted":["calendar","reminders","contacts"]}` → send "Calendar, Reminders, and Contacts are connected." and continue to Step 5.
- Contains `TCC_DENIED:calendar` → send "Calendar access was denied. Open System Settings → Privacy & Security → Calendars, find **apple-helper** in the list, turn it on. Then run `/apple-services-setup` again." and stop.
- Same for `TCC_DENIED:reminders` and `TCC_DENIED:contacts` (substitute the right app pane).

## Step 5 — Notes and Mail automation permissions

Send:

> macOS is about to ask if **{{host_friendly}}** can control Notes, then the same for Mail. Click **OK** on both prompts.

Run (with 10s timeout as belt-and-suspenders for indexing edge cases):

```bash
timeout 10 osascript -e 'tell application "Notes" to count notes' 2>&1
notes_exit=$?

# Per Phase 0 R7: use 'count every account' as the Mail pre-flight. Returns 0
# instantly when Mail has no accounts configured, avoiding the hanging
# inbox-construction path that 'count messages of inbox' hits.
mail_acct_out=$(timeout 10 osascript -e 'tell application "Mail" to count every account' 2>&1)
mail_acct_exit=$?
if [ "$mail_acct_exit" = 0 ] && [ "$mail_acct_out" = "0" ]; then
  mail_result=NO_ACCOUNTS
elif [ "$mail_acct_exit" != 0 ]; then
  mail_result="FAIL:$mail_acct_out"
else
  # Mail has accounts — confirm mailboxes are queryable.
  timeout 10 osascript -e 'tell application "Mail" to count messages of inbox' 2>&1
  mail_msgs_exit=$?
  if [ "$mail_msgs_exit" = 0 ]; then
    mail_result=OK
  elif [ "$mail_msgs_exit" = 124 ]; then
    mail_result=MAIL_SLOW
  else
    mail_result=FAIL
  fi
fi
echo "notes=$notes_exit mail=$mail_result"
```

Handle:
- `notes=0` and `mail=OK` → send "Notes and Mail are connected." and continue to Step 6.
- `notes != 0` with `(-1743)` in stderr → send "Notes access was denied. Open System Settings → Privacy & Security → Automation, find **{{host_friendly}}**, turn on Notes underneath it. Then run `/apple-services-setup` again." and stop.
- `mail=NO_ACCOUNTS` → send "Mail isn't set up yet — it has no accounts configured. Open Mail.app, add at least one account, then run `/apple-services-setup` again." and stop.
- `mail=MAIL_SLOW` → send "Mail is still indexing — give it a few minutes, then run `/apple-services-setup` again." and stop.
- `mail=FAIL:...` with `(-1743)` in the message → Automation was denied; emit the automation-recovery message substituting `{{host_friendly}}`.
- `mail=FAIL` → send the generic "Mail didn't respond" error and stop.
```

- [ ] **Step 2: Commit**

```bash
git add apple-services/commands/apple-services-setup.md
git commit -m "feat(apple-services): setup command steps 4-5 (permissions)"
```

---

### Task 18: `/apple-services-setup` — Steps 6–7 (smoke + summary)

**Files:**
- Modify: `apple-services/commands/apple-services-setup.md` — append Steps 6–7

- [ ] **Step 1: Append the final steps**

```markdown
## Step 6 — Smoke test each integration

Run all six probes. Each either succeeds (counts something ≥0) or fails independently:

```bash
WRAPPER="$PLUGIN_DIR/lib/apple-wrapper.sh"

probe() {
  local label="$1"; shift
  local result
  if result=$("$WRAPPER" "$@" 2>&1); then
    local count; count=$(echo "$result" | jq 'length' 2>/dev/null || echo 0)
    printf '%s\tPASS\t%s\n' "$label" "$count"
  else
    printf '%s\tFAIL\t%s\n' "$label" "$(echo "$result" | head -c 200)"
  fi
}

probe calendar     calendar     list_calendars
probe reminders    reminders    list_lists
probe contacts     contacts     list_groups
probe notes        notes        list_folders
probe mail         mail         list_mailboxes
probe icloud       icloud       list        --path ""
```

(All op names are snake_case, matching the AppleScript/JXA file basenames and the spec ops tables.)

Parse the output. If all six report `PASS`, continue to Step 7.

If any report `FAIL`, still run Step 7 but flag that integration in the summary with a "couldn't verify" note pointing the user to run `/apple-services-setup` again.

## Step 7 — Success summary

Build a summary like this (substituting the PASS counts from Step 6):

```
All set — Apple apps are connected.

  Calendar      {{count}} calendars
  Reminders     {{count}} lists
  Contacts      ready
  Notes         {{count}} folders
  Mail          {{count}} mailboxes
  iCloud Drive  {{count}} items at the top level

Try asking me:
  • "What's on my calendar this week?"
  • "Remind me at 5pm to call mom"
  • "Find Jenny's phone number"
  • "What's in my Notes folder 'Tahoe'?"
  • "Search my email for the lease renewal"
  • "Save this to my iCloud Drive in Claude/drops"
```

If any integration failed in Step 6, substitute "couldn't verify — try `/apple-services-setup` again" for that row and note it above the "Try asking me" block.

## Idempotency contract

Re-running `/apple-services-setup` is always safe:
- Step 1: pure check.
- Step 2: skipped if binary hash matches.
- Step 3: pure check.
- Step 4: no prompt if already granted.
- Step 5: no prompt if already granted.
- Steps 6-7: always run.
```

- [ ] **Step 2: Commit**

```bash
git add apple-services/commands/apple-services-setup.md
git commit -m "feat(apple-services): setup command steps 6-7 (smoke + summary)"
```

---

### Task 19: Umbrella SKILL.md files (6)

**Files:**
- Create: `apple-services/skills/apple-calendar/SKILL.md`
- Create: `apple-services/skills/apple-reminders/SKILL.md`
- Create: `apple-services/skills/apple-contacts/SKILL.md`
- Create: `apple-services/skills/apple-notes/SKILL.md`
- Create: `apple-services/skills/apple-mail/SKILL.md`
- Create: `apple-services/skills/icloud-drive/SKILL.md`

Each umbrella SKILL documents the full op surface. Per-op SKILLs (Tasks 20-21) are separate files for high-traffic ops.

- [ ] **Step 1: Write apple-calendar/SKILL.md**

```markdown
---
name: apple-calendar
description: "Apple Calendar: list, search, and manage events across all your calendars via EventKit. Use when the user asks about events, meetings, or wants to schedule something on their Mac's Calendar."
metadata:
  category: "productivity"
  requires:
    bins:
      - bash
---

# apple-calendar

> **Prereq:** Run `/apple-services-setup` once to grant Calendar access. All commands here will return `TCC_DENIED:calendar` if the grant hasn't been made yet.

Skills call `apple-wrapper.sh calendar <op> [args]`. The wrapper is at `$PLUGIN_DIR/lib/apple-wrapper.sh`; in a typical install, this resolves to `~/.claude/plugins/marketplaces/youcoded/plugins/apple-services/lib/apple-wrapper.sh`.

## Operations

| Op | Args | Returns |
|---|---|---|
| `list_calendars` | — | `[{id, title, color, writable}]` |
| `list_events` | `--from <iso> --to <iso> [--calendar-id <id>]` | `[event]` |
| `get_event` | `--id <id>` | `event` |
| `search_events` | `--query <q> --from <iso> --to <iso>` | `[event]` |
| `create_event` | `--title <t> --start <iso> --end <iso> --calendar-id <id> [--location <l>] [--notes <n>] [--all-day] [--recurrence <rule>]` | `event` |
| `update_event` | `--id <id>` + any field above | `event` |
| `delete_event` | `--id <id>` | `{ok: true}` |
| `free_busy` | `--from <iso> --to <iso> [--calendar-ids <id,id,...>]` | `[{start, end, busy}]` |

## Examples

```bash
# What's this week?
apple-wrapper.sh calendar list_events --from 2026-04-13 --to 2026-04-20

# Create a meeting
apple-wrapper.sh calendar create_event \
  --title "Team sync" \
  --start 2026-04-17T14:00 --end 2026-04-17T15:00 \
  --calendar-id "<id-from-list_calendars>"

# Busy windows across two calendars
apple-wrapper.sh calendar free_busy --from 2026-04-17 --to 2026-04-18 \
  --calendar-ids "<id1>,<id2>"
```

## Handling permission denial

If a call fails with `TCC_DENIED:calendar`, tell the user:

> macOS says I don't have access to your Calendar. Run `/apple-services-setup` and re-grant permission, or open System Settings → Privacy & Security → Calendars and turn on **apple-helper**. Let me know when that's done and I'll retry.

Do not retry automatically.
```

- [ ] **Step 2: Write apple-reminders/SKILL.md**

```markdown
---
name: apple-reminders
description: "Apple Reminders: create, list, complete, and delete reminders across your lists. Use when the user asks to be reminded of something, or wants to see their to-do list."
metadata:
  category: "productivity"
  requires:
    bins:
      - bash
---

# apple-reminders

> **Prereq:** Run `/apple-services-setup` once to grant Reminders access.

Skills call `apple-wrapper.sh reminders <op> [args]`.

## Operations

| Op | Args | Returns |
|---|---|---|
| `list_lists` | — | `[{id, title, color}]` |
| `list_reminders` | `[--list-id <id>] [--incomplete-only]` | `[reminder]` |
| `get_reminder` | `--id <id>` | `reminder` |
| `create_reminder` | `--title <t> --list-id <id> [--due <iso>] [--priority <0-9>] [--notes <n>]` | `reminder` |
| `update_reminder` | `--id <id>` + any field | `reminder` |
| `complete_reminder` | `--id <id>` | `{ok: true}` |
| `delete_reminder` | `--id <id>` | `{ok: true}` |

## Examples

```bash
apple-wrapper.sh reminders list_reminders --incomplete-only
apple-wrapper.sh reminders create_reminder --title "Call mom" --list-id "<id>" --due 2026-04-17T17:00
apple-wrapper.sh reminders complete_reminder --id "<reminder-id>"
```

## Handling permission denial

`TCC_DENIED:reminders` → tell the user to re-grant via `/apple-services-setup` or System Settings → Privacy & Security → Reminders → turn on **apple-helper**.

## Related: youcoded-inbox

> For inbox-style watched-list reading with same-day re-presentation guards, see the `youcoded-inbox` bundle's `apple-reminders` provider. This skill is general-purpose and does not track "already shown today" state.
```

- [ ] **Step 3: Write apple-contacts/SKILL.md**

```markdown
---
name: apple-contacts
description: "Apple Contacts: fuzzy-search, retrieve, create, and update contacts and groups. Use when the user asks for someone's phone/email, or wants to add a new contact."
metadata:
  category: "productivity"
  requires:
    bins:
      - bash
---

# apple-contacts

> **Prereq:** Run `/apple-services-setup` once to grant Contacts access.

Skills call `apple-wrapper.sh contacts <op> [args]`.

## Operations

| Op | Args | Returns |
|---|---|---|
| `search` | `--query <q> [--limit <n>]` | `[contact]` — fuzzy across name, phone, email, org |
| `get` | `--id <id>` | `contact` |
| `list_groups` | — | `[{id, name}]` |
| `list_group_members` | `--group-id <id>` | `[contact]` |
| `create` | `--first <f> [--last <l>] [--phones <p1> <p2>...] [--emails <e1> <e2>...] [--organization <o>] [--notes <n>]` | `contact` |
| `update` | `--id <id>` + any field | `contact` |
| `add_to_group` | `--contact-id <cid> --group-id <gid>` | `{ok: true}` |
| `remove_from_group` | `--contact-id <cid> --group-id <gid>` | `{ok: true}` |

## Examples

```bash
apple-wrapper.sh contacts search --query "jenny"
apple-wrapper.sh contacts create --first "Alex" --last "Smith" --emails alex@example.com
```

## Handling permission denial

`TCC_DENIED:contacts` → re-grant via `/apple-services-setup` or System Settings → Privacy & Security → Contacts → **apple-helper**.
```

- [ ] **Step 4: Write apple-notes/SKILL.md**

```markdown
---
name: apple-notes
description: "Apple Notes: search, read, create, and update notes in any folder. Use when the user asks about their notes, wants to save a note, or search across note content."
metadata:
  category: "productivity"
  requires:
    bins:
      - bash
---

# apple-notes

> **Prereq:** Run `/apple-services-setup` once to grant Automation access to Notes.

Skills call `apple-wrapper.sh notes <op> [args]`. Operations route to AppleScript (no EventKit equivalent exists).

## Operations

| Op | Args | Returns |
|---|---|---|
| `list-folders` | — | `[{name, note_count}]` |
| `list` | `[--folder <name>]` | `[{id, name, modified}]` |
| `read` | `--id <id>` | `{id, name, body_markdown, modified}` |
| `search` | `--query <q> [--folder <name>]` | `[{id, name, snippet}]` |
| `create` | `--name <n> --body <md> [--folder <name>]` | `note` |
| `update` | `--id <id> --body <md> [--mode replace\|append\|prepend]` | `note` |
| `delete` | `--id <id>` | `{ok: true}` |

## ⚠️ Rich content warning

Apple Notes stores rich HTML (images, drawings, tables, attachments). Markdown round-trips lose non-text content.

**`update` with `--mode replace` will destroy images, drawings, tables, and attachments in the target note.** Unless you're confident the note contains only text — or the user explicitly said to replace everything — use `--mode append` or `--mode prepend`. When in doubt, ask.

## Handling permission denial

`TCC_DENIED:notes` → Automation access was revoked. Tell the user: open System Settings → Privacy & Security → Automation, find the app that's hosting Claude, turn on **Notes** underneath it. Then re-run `/apple-services-setup`.

## Related: youcoded-inbox

> For inbox-style watched-folder reading with same-day re-presentation guards, see the `youcoded-inbox` bundle's `apple-notes` provider. This skill is general-purpose and does not track "already shown today" state.
```

- [ ] **Step 5: Write apple-mail/SKILL.md**

```markdown
---
name: apple-mail
description: "Apple Mail: search, read, send, draft, and manage mail. Use when the user asks to check mail, find a message, send or reply to an email, or triage their inbox."
metadata:
  category: "productivity"
  requires:
    bins:
      - bash
---

# apple-mail

> **Prereq:** Run `/apple-services-setup` once to grant Automation access to Mail.

Skills call `apple-wrapper.sh mail <op> [args]`. Routes via AppleScript.

## Operations

| Op | Args | Returns |
|---|---|---|
| `list-mailboxes` | `[--account <name>]` | `[{name, account, unread_count}]` |
| `search` | `--query <q> [--mailbox <name>] [--from <email>] [--to <email>] [--since <iso>] [--limit <n>]` | `[{id, from, subject, date, preview}]` |
| `read` | `--id <id>` | `{id, from, to[], cc[], subject, date, body_text, body_html?, attachments[]}` |
| `send` | `--to <e1,e2,...> --subject <s> --body <b> [--cc <...>] [--bcc <...>] [--attachments <p1,p2,...>]` | `{ok: true}` |
| `create-draft` | same as `send` | `{id}` |
| `mark-read` | `--id <id>` | `{ok: true}` |

## Performance note

Mail searches against large mailboxes can take 30-60 seconds; the wrapper allows up to 60s for search ops. List/read ops cap at 15s.

## Handling permission denial

`TCC_DENIED:mail` → same pattern as Notes: re-grant via Automation settings + `/apple-services-setup`.
```

- [ ] **Step 6: Write icloud-drive/SKILL.md**

```markdown
---
name: icloud-drive
description: "iCloud Drive: list, read, write, move, and delete files in iCloud Drive. Use when the user wants to save something to iCloud, find a file, or organize their iCloud folders."
metadata:
  category: "productivity"
  requires:
    bins:
      - bash
---

# icloud-drive

> **Prereq:** iCloud Drive must be turned on in System Settings. `/apple-services-setup` verifies this.

Skills call `apple-wrapper.sh icloud <op> [args]`. No TCC grant required — operations are plain filesystem reads/writes against the iCloud Drive mount point.

## Operations

| Op | Args | Returns |
|---|---|---|
| `list` | `--path <rel> [--recursive]` | `[{name, type, size, modified}]` |
| `read` | `--path <rel>` | text content, or `{binary: true, type, size}` |
| `write` | `--path <rel> --content <str>` | `{ok: true}` |
| `delete` | `--path <rel>` | `{ok: true}` |
| `move` | `--src <rel> --dst <rel>` | `{ok: true}` |
| `create_folder` | `--path <rel>` | `{ok: true}` |
| `stat` | `--path <rel>` | `{name, type, size, modified}` |

All paths are relative to iCloud Drive root. Use `--path ""` for root.

## ⚠️ Placeholder files

Files not yet downloaded from iCloud appear with `type: "placeholder"` in `list` output. `read` on such a file returns `UNAVAILABLE` — tell the user to open Finder, right-click the file, Download Now, then retry.

## Offline behavior

If iCloud sync is paused or offline, reads return what's on disk. Writes succeed locally and sync on next connection — no special handling needed.

## Related: youcoded-inbox

> For inbox-style watched-folder reading with same-day re-presentation guards, see the `youcoded-inbox` bundle's `icloud-drive` provider. This skill is general-purpose and does not track "already shown today" state.
```

- [ ] **Step 7: Commit**

```bash
git add apple-services/skills/apple-calendar/ apple-services/skills/apple-reminders/ \
        apple-services/skills/apple-contacts/ apple-services/skills/apple-notes/ \
        apple-services/skills/apple-mail/ apple-services/skills/icloud-drive/
git commit -m "feat(apple-services): 6 umbrella SKILL.md files"
```

---

### Task 20: Per-op SKILL.md files — Calendar, Reminders, Contacts

**Files:**
- Create: `apple-services/skills/apple-calendar-agenda/SKILL.md`
- Create: `apple-services/skills/apple-calendar-create/SKILL.md`
- Create: `apple-services/skills/apple-reminders-add/SKILL.md`
- Create: `apple-services/skills/apple-reminders-list/SKILL.md`
- Create: `apple-services/skills/apple-contacts-find/SKILL.md`

Focused skills for the highest-traffic ops. Each has a very specific `description` so the Skill matcher routes narrow intents here first.

- [ ] **Step 1: apple-calendar-agenda/SKILL.md**

```markdown
---
name: apple-calendar-agenda
description: "Show what's on the user's Apple Calendar for today, this week, or a specific date range. Use when they ask 'what's on my calendar', 'what do I have today', 'show my agenda', or similar."
---

# apple-calendar-agenda

Show calendar events for a time range.

## Usage

```bash
# Today
apple-wrapper.sh calendar list_events --from "$(date -u +%Y-%m-%dT00:00:00Z)" --to "$(date -u -v+1d +%Y-%m-%dT00:00:00Z)"

# This week (Monday-Sunday)
apple-wrapper.sh calendar list_events --from "$(date -u -v-Mon +%Y-%m-%dT00:00:00Z)" --to "$(date -u -v+Sun +%Y-%m-%dT23:59:59Z)"

# Specific range
apple-wrapper.sh calendar list_events --from 2026-04-17 --to 2026-04-24
```

Output is a JSON array of events; format for display as a human-readable list (don't print raw JSON).

## Rendering

When showing the agenda, group by day and format times in the user's local timezone. Prefer a compact list over a table for ≤10 events. For an empty result, say "Nothing on your calendar in that range."
```

- [ ] **Step 2: apple-calendar-create/SKILL.md**

```markdown
---
name: apple-calendar-create
description: "Create a new Apple Calendar event. Use when the user says 'add an event', 'put this on my calendar', 'schedule X', 'book a meeting', or similar."
---

# apple-calendar-create

Create a calendar event.

## Flow

1. If you don't know which calendar to add to, call `list_calendars` first and ask the user (unless only one is writable).
2. Parse the user's natural-language time into ISO-8601 start/end.
3. Call `create_event`.
4. Confirm by reading back the title, time, and calendar.

## Usage

```bash
apple-wrapper.sh calendar list_calendars   # if needed
apple-wrapper.sh calendar create_event \
  --title "Coffee with Alex" \
  --start 2026-04-18T15:00 \
  --end 2026-04-18T16:00 \
  --calendar-id "<id>"
```

## Duration defaults

If the user doesn't specify an end time:
- "Meeting" / "call" → default 30 minutes
- "Coffee" / "lunch" / "dinner" → default 60 minutes
- "Appointment" → default 60 minutes
- Anything else → ask.
```

- [ ] **Step 3: apple-reminders-add/SKILL.md**

```markdown
---
name: apple-reminders-add
description: "Add a new Apple Reminder. Use when the user says 'remind me to X', 'add a reminder', 'put X on my to-do list', or similar."
---

# apple-reminders-add

Add a reminder, optionally with a due time.

## Flow

1. Default to the user's primary reminders list unless they name a specific one.
2. Parse any time phrase ("at 5pm", "tomorrow morning", "next Monday") into ISO-8601 due.
3. Call `create_reminder`.
4. Confirm with the reminder title + due time in human format.

## Usage

```bash
apple-wrapper.sh reminders list_lists   # if the user named a list
apple-wrapper.sh reminders create_reminder \
  --title "Call mom" \
  --list-id "<primary-id>" \
  --due 2026-04-17T17:00
```

## Default list

If `list_lists` returns multiple and the user didn't name one, prefer a list called "Reminders" or the first list in the array. Don't ask — the cost of a wrong list is low (user can move it).
```

- [ ] **Step 4: apple-reminders-list/SKILL.md**

```markdown
---
name: apple-reminders-list
description: "List or show the user's Apple Reminders. Use when they ask 'what's on my to-do', 'show my reminders', 'what do I have to do'."
---

# apple-reminders-list

Show reminders, defaulting to incomplete only.

## Usage

```bash
# All incomplete across all lists
apple-wrapper.sh reminders list_reminders --incomplete-only

# From one list only
apple-wrapper.sh reminders list_reminders --list-id "<id>" --incomplete-only
```

Group by list in the output. Show due date if present, otherwise just the title.
```

- [ ] **Step 5: apple-contacts-find/SKILL.md**

```markdown
---
name: apple-contacts-find
description: "Find a contact in Apple Contacts by name, phone, email, or organization. Use when the user asks 'what's X's number', 'find X', 'email for Y'."
---

# apple-contacts-find

Fuzzy-search Contacts.

## Usage

```bash
apple-wrapper.sh contacts search --query "jenny" --limit 5
```

## Presenting results

- **1 match:** show name + the requested field (phone/email/etc.) directly.
- **2-5 matches:** list them briefly, each with a disambiguator (org, second name).
- **>5 matches:** ask the user to narrow the query.

Don't dump all fields of every match — answer the question they asked.
```

- [ ] **Step 6: Commit**

```bash
git add apple-services/skills/apple-calendar-agenda/ apple-services/skills/apple-calendar-create/ \
        apple-services/skills/apple-reminders-add/ apple-services/skills/apple-reminders-list/ \
        apple-services/skills/apple-contacts-find/
git commit -m "feat(apple-services): per-op SKILLs for calendar/reminders/contacts"
```

---

### Task 21: Per-op SKILL.md files — Notes, Mail

**Files:**
- Create: `apple-services/skills/apple-notes-search/SKILL.md`
- Create: `apple-services/skills/apple-notes-write/SKILL.md`
- Create: `apple-services/skills/apple-mail-send/SKILL.md`
- Create: `apple-services/skills/apple-mail-search/SKILL.md`

- [ ] **Step 1: apple-notes-search/SKILL.md**

```markdown
---
name: apple-notes-search
description: "Search across Apple Notes content. Use when the user asks 'find my note about X', 'search my notes for Y', or wants to locate a specific note."
---

# apple-notes-search

Search note bodies and titles.

## Usage

```bash
apple-wrapper.sh notes search --query "tahoe cabin"
# Restrict to one folder:
apple-wrapper.sh notes search --query "receipts" --folder "Work"
```

Returns `[{id, name, snippet}]`. For 0 results, say "No notes found matching that." For many, show the top 5 and offer to narrow.

Use `read --id <id>` to pull the full note body when the user picks one.
```

- [ ] **Step 2: apple-notes-write/SKILL.md**

```markdown
---
name: apple-notes-write
description: "Create a new Apple Note or add to an existing one. Use when the user says 'save this as a note', 'add this to my notes', 'write a note about X'."
---

# apple-notes-write

Create a note or append to an existing one.

## Default: create new

```bash
apple-wrapper.sh notes create \
  --name "Meeting notes 2026-04-17" \
  --body "## Attendees\n- Alex\n- Jamie\n\n## Notes\n..." \
  --folder "Work"
```

## Adding to an existing note

Ask the user whether to append or replace. **Default to append** — replace destroys rich content (images, tables, drawings) in notes Claude didn't create.

```bash
# Safe: append
apple-wrapper.sh notes update --id "<id>" --body "New content" --mode append

# Only if user explicitly confirms, and note is plain text:
apple-wrapper.sh notes update --id "<id>" --body "..." --mode replace
```

If unsure whether a note is plain text, read it first with `read --id <id>` and look for image/table markers in the body.
```

- [ ] **Step 3: apple-mail-send/SKILL.md**

```markdown
---
name: apple-mail-send
description: "Send an email via Apple Mail. Use when the user says 'email X', 'send a message to Y', 'reply to Z'."
---

# apple-mail-send

Compose and send email.

## Usage

```bash
apple-wrapper.sh mail send \
  --to "alice@example.com" \
  --subject "Tuesday call" \
  --body "Hi Alice, ..."
```

## Before sending

- **Always show the draft to the user and get confirmation** unless they've explicitly said to send without review.
- For replies, ask for the recipient email or use `mail search` + `mail read` to find the thread and quote.
- Attachments are passed as a comma-separated list of absolute paths.

## Draft instead of send

If the user says "draft X" instead of "send X", use `create-draft` — it writes to the Drafts mailbox and the user finishes sending from Mail.app.
```

- [ ] **Step 4: apple-mail-search/SKILL.md**

```markdown
---
name: apple-mail-search
description: "Search Apple Mail messages. Use when the user asks 'find the email from X', 'search my mail for Y', 'where's that message about Z'."
---

# apple-mail-search

Search the user's mail.

## Usage

```bash
# Keyword
apple-wrapper.sh mail search --query "lease renewal" --limit 10

# Narrow with filters
apple-wrapper.sh mail search --query "invoice" --from "billing@example.com" --since 2026-01-01
```

## Performance

Mail search can take 30-60 seconds on large mailboxes — the wrapper allows up to 60s. Tell the user "Searching your mail — this can take up to a minute" before calling.

Returns `[{id, from, subject, date, preview}]`. Use `read --id <id>` for full body + attachments of a specific hit.
```

- [ ] **Step 5: Commit**

```bash
git add apple-services/skills/apple-notes-search/ apple-services/skills/apple-notes-write/ \
        apple-services/skills/apple-mail-send/ apple-services/skills/apple-mail-search/
git commit -m "feat(apple-services): per-op SKILLs for notes/mail"
```

---

### Task 22: VENDORED.md, NOTICE.md, permissions-walkthrough.md

**Files:**
- Create: `apple-services/VENDORED.md`
- Create: `apple-services/NOTICE.md`
- Create: `apple-services/setup/permissions-walkthrough.md`

- [ ] **Step 1: Write apple-services/VENDORED.md**

```markdown
# VENDORED.md

Provenance for files pulled from third-party sources. Updated on every vendor refresh.

Per Phase 0 findings, most of this plugin is original code. The only meaningfully-vendored files are AppleScript extracts from `supermemoryai/apple-mcp` (MIT). The `bin/apple-helper` binary is original code in the sibling `itsdestin/apple-helper` repo — see that repo's `NOTICE.md` for references. iMCP informed the Swift helper but is not vendored byte-for-byte, so it doesn't appear below.

| File | Source | Upstream reference | SHA | License | Last pulled |
|---|---|---|---|---|---|
| `applescript/notes/create_note.applescript` | supermemoryai/apple-mcp | `utils/notes.ts` (createNote block) | 08e2c53 | MIT | 2026-04-17 |
| `applescript/notes/*` (all others) | mostly original; reference patterns | `utils/notes.ts` | 08e2c53 | MIT | 2026-04-17 |
| `applescript/mail/send.applescript` | supermemoryai/apple-mcp | `utils/mail.ts` (sendMail block) | 08e2c53 | MIT | 2026-04-17 |
| `applescript/mail/list_mailboxes.jxa` | supermemoryai/apple-mcp | `utils/mail.ts` (getMailboxesForAccount pattern) | 08e2c53 | MIT | 2026-04-17 |
| `applescript/mail/*` (all others) | mostly original; reference patterns | `utils/mail.ts` | 08e2c53 | MIT | 2026-04-17 |

**Re-pull procedure:** when updating from upstream, change the SHA column + `Last pulled` date. No automated drift-check yet (see Spec B). For now, review upstream manually when refreshing.
```

- [ ] **Step 2: Write apple-services/NOTICE.md**

```markdown
# NOTICE.md

`apple-services` is MIT-licensed. It incorporates code from the following third-party Open Source projects. License texts are reproduced in full.

---

## supermemoryai/apple-mcp (MIT)

Source: https://github.com/supermemoryai/apple-mcp (repo moved from `Dhravya/apple-mcp`)

Extracts from upstream TypeScript files (`utils/notes.ts`, `utils/mail.ts`) inform the scripts in `applescript/notes/` and `applescript/mail/`. Specifically the `createNote`, `findNote`, `sendMail`, and `getMailboxesForAccount` patterns were adapted. List-returning paths were rewritten in JXA because upstream's AppleScript record-parsing returns `[]`.

Full MIT license:

```
[paste full MIT license from ~/reference/apple-mcp/LICENSE]
```

---

## mattt/iMCP (MIT, reference only for `bin/apple-helper`)

Source: https://github.com/mattt/iMCP (repo moved from `loopwork/iMCP`)

The compiled binary `bin/apple-helper` is built from original Swift in the sibling `itsdestin/apple-helper` repo. No iMCP code is vendored byte-for-byte, but its EventKit + Contacts service patterns (`App/Services/{Calendar,Reminders,Contacts}.swift`) informed our implementations and deserve credit.

Full MIT license:

```
[paste full MIT license from ~/reference/iMCP/LICENSE.md]
```
```

- [ ] **Step 3: Write apple-services/setup/permissions-walkthrough.md**

```markdown
# Permissions walkthrough (reference)

This file documents the TCC grants Apple Services needs, what each one enables, and how to re-grant if revoked. `/apple-services-setup` pulls short excerpts from here into its user-facing copy.

## EventKit — Calendar

- **Granted to:** `apple-helper` binary
- **Enables:** read + write events across all calendars
- **First request:** macOS system dialog triggered by `requestFullAccessToEvents`
- **To re-grant:** System Settings → Privacy & Security → Calendars → toggle **apple-helper** on
- **macOS version:** requires 14.0+

## EventKit — Reminders

- **Granted to:** `apple-helper`
- **Enables:** read + write reminders across all lists
- **To re-grant:** System Settings → Privacy & Security → Reminders → toggle **apple-helper** on

## Contacts framework

- **Granted to:** `apple-helper`
- **Enables:** read + write contacts and groups
- **To re-grant:** System Settings → Privacy & Security → Contacts → toggle **apple-helper** on

## Automation — Notes

- **Granted to:** the *invoking* process (YouCoded.app, Terminal, iTerm — whichever is running Claude)
- **Enables:** AppleScript control of Notes.app
- **First request:** triggered by the first `tell application "Notes"` at setup
- **To re-grant:** System Settings → Privacy & Security → Automation → find your Claude host app → toggle **Notes** on

## Automation — Mail

- **Granted to:** the invoking process (same as Notes)
- **Enables:** AppleScript control of Mail.app
- **To re-grant:** System Settings → Privacy & Security → Automation → find your Claude host app → toggle **Mail** on

## iCloud Drive

- **Granted to:** no TCC needed
- **Requires:** iCloud Drive enabled in System Settings → your name → iCloud → iCloud Drive
```

- [ ] **Step 4: Commit**

```bash
git add apple-services/VENDORED.md apple-services/NOTICE.md apple-services/setup/permissions-walkthrough.md
git commit -m "docs(apple-services): VENDORED + NOTICE + permissions walkthrough"
```

---

### Task 23: `.dev/DEV-VERIFICATION.md` (human checklist)

**Files:**
- Create: `apple-services/.dev/DEV-VERIFICATION.md`

- [ ] **Step 1: Write the checklist**

```markdown
# DEV-VERIFICATION.md

Human round-trip checklist. Run before tagging each release. NOT shipped to users — this directory is gitignored.

Estimated time: 2-3 hours concentrated on a real Mac (14+) with real Apple accounts populated.

## Section A — Fresh install

- [ ] `tccutil reset All` to wipe TCC state
- [ ] Remove `~/.apple-services/bin/` to force re-copy
- [ ] Start the app where Claude runs (Terminal, iTerm, YouCoded desktop)
- [ ] Run `/apple-services-setup`
- [ ] Verify Step 1 passes platform + version checks
- [ ] Verify Step 2 copies binary, reports `OK_INSTALLED`
- [ ] Verify Step 3 finds iCloud Drive
- [ ] Verify Step 4 pops 3 dialogs in order (Calendar → Reminders → Contacts); click Allow on each
- [ ] Verify Step 5 pops 2 dialogs (Notes → Mail); click OK on each
- [ ] Verify Step 6 prints PASS for all 6 probes
- [ ] Verify Step 7 summary is coherent + example prompts make sense
- [ ] **Idempotency:** re-run `/apple-services-setup`. Expect zero dialogs, all PASS.

## Section B — Per-integration CRUD round-trip

For each of the six integrations, confirm CRUD via chat and verify in the respective Apple app:

- [ ] **Calendar:** ask "create a calendar event tomorrow at 2pm called 'Test'" → verify in Calendar.app → ask to delete → verify gone
- [ ] **Reminders:** ask "remind me in 1 hour to test reminders" → verify in Reminders.app → complete via chat → verify checked
- [ ] **Contacts:** ask "create a contact named Test Person with email test@example.com" → verify in Contacts.app → ask to delete → verify gone
- [ ] **Notes:** ask "create a note titled Test with body 'hello'" → verify in Notes.app → ask to append 'world' → verify body is "hello\nworld" → delete → verify gone
- [ ] **Mail:** ask "draft an email to myself with subject Test" → verify in Mail Drafts → send → verify received → delete
- [ ] **iCloud Drive:** ask "save 'hi' to a file called test.txt at iCloud root" → verify in Finder → ask to delete → verify gone

## Section C — Permission denial recovery

For each TCC grant:

- [ ] Revoke in System Settings
- [ ] Make a chat request that hits that integration
- [ ] Verify error surfaces with correct `TCC_DENIED:<service>` code
- [ ] Verify Claude's recovery copy matches what this plan specifies
- [ ] Re-grant via `/apple-services-setup` or directly in System Settings
- [ ] Verify operation resumes

## Section D — Binary-update behavior (addresses R3)

- [ ] Install v1 helper, grant all 5 TCC permissions
- [ ] Replace `~/.apple-services/bin/apple-helper` with a v0.1.0+1 build (same ad-hoc signing)
- [ ] Run any calendar op
- [ ] Record: did macOS re-prompt? If yes, this becomes documented friction in release notes.

## Section E — Edge cases

- [ ] iCloud `.icloud` placeholder: force-eject a file from a Mac (Finder → right-click → Remove Download), list the dir, verify `type: "placeholder"` appears
- [ ] Mail.app first-run: quit Mail, deactivate all accounts, re-run `/apple-services-setup` — verify helpful "Mail isn't fully set up yet" message
- [ ] Unicode names: create a contact "François" and search for "fran"
- [ ] Empty iCloud root: temporarily rename everything out of iCloud root, list, verify empty array returns cleanly
- [ ] Locked TCC: wrapper should surface `TCC_DENIED` clearly when a user has disabled a grant

## Section F — Coexistence with youcoded-inbox

- [ ] Install both youcoded-inbox and apple-services
- [ ] Run the inbox's daily check — verify it still works with its apple-notes/apple-reminders providers
- [ ] Use apple-services skills — verify they work independently
- [ ] Confirm neither corrupts the other's state

## Sign-off

- [ ] All sections passed, OR deviations documented in the release PR description
- [ ] `docs/knowledge-debt.md` updated with any drift found
- [ ] Ready to tag
```

- [ ] **Step 2: Commit**

```bash
git add apple-services/.dev/DEV-VERIFICATION.md
git commit -m "docs(apple-services): human DEV-VERIFICATION checklist"
```

---

### Task 24: Marketplace registry entries

**Files:**
- Modify: `wecoded-marketplace/marketplace.json` — add entry
- Modify: `wecoded-marketplace/index.json` — add entry

- [ ] **Step 1: Read current marketplace.json to find the right spot**

```bash
cat marketplace.json | jq '.plugins[].name' | head -20
```

Identify where alphabetically (or by convention — currently appears chronologically) `apple-services` should be inserted.

- [ ] **Step 2: Add entry to marketplace.json**

Insert as an additional element in the `plugins` array. Using `jq` for atomicity:

```bash
jq '.plugins += [{
  "name": "apple-services",
  "displayName": "Apple Services",
  "description": "Calendar, Reminders, Contacts, Notes, Mail, and iCloud Drive in one setup. macOS only.",
  "author": { "name": "@destin", "github": "itsdestin" },
  "category": "productivity",
  "source": { "source": "local", "path": "apple-services" },
  "platforms": ["macos"]
}]' marketplace.json > marketplace.json.tmp && mv marketplace.json.tmp marketplace.json
```

- [ ] **Step 3: Add entry to index.json**

Inspect its shape first:

```bash
cat index.json | jq '.plugins[0]' 2>/dev/null || cat index.json | head -40
```

Append a matching entry. The index shape typically has `sourceMarketplace: "youcoded"` and additional fields — copy the pattern from an existing YouCoded plugin entry (e.g. `google-services`).

- [ ] **Step 4: Validate JSON**

```bash
python3 -m json.tool < marketplace.json > /dev/null && echo "marketplace.json: valid"
python3 -m json.tool < index.json > /dev/null && echo "index.json: valid"
```

Expected: both print `valid`.

- [ ] **Step 5: Commit**

```bash
git add marketplace.json index.json
git commit -m "feat(apple-services): register in marketplace.json + index.json"
```

---

### Task 25: Marketplace CI validation updates

**Files:**
- Modify: `wecoded-marketplace/.github/workflows/validate-plugin-pr.yml`

The existing validate-plugin-pr workflow checks `plugins/**` but actual plugins live at the top level of the repo. Add apple-services-specific validation without breaking existing behavior.

- [ ] **Step 1: Inspect existing workflow**

```bash
cat .github/workflows/validate-plugin-pr.yml | head -80
```

Note: trigger is `paths: plugins/**` which never matches the actual layout. Leaving that fix to a separate PR; scope this task to apple-services additions only.

- [ ] **Step 2: Add an apple-services validation job**

Append to `.github/workflows/validate-plugin-pr.yml`:

```yaml

  validate-apple-services:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Skip if apple-services not touched
        id: touched
        run: |
          if git diff --name-only origin/master...HEAD | grep -q '^apple-services/'; then
            echo "touched=yes" >> "$GITHUB_OUTPUT"
          else
            echo "touched=no" >> "$GITHUB_OUTPUT"
          fi

      - name: Install tools
        if: steps.touched.outputs.touched == 'yes'
        run: |
          sudo apt-get update
          sudo apt-get install -y shellcheck jq

      - name: Shellcheck wrapper
        if: steps.touched.outputs.touched == 'yes'
        run: shellcheck apple-services/lib/apple-wrapper.sh

      - name: Validate plugin.json
        if: steps.touched.outputs.touched == 'yes'
        run: |
          jq -e '.name == "apple-services"' apple-services/plugin.json
          jq -e '.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' apple-services/plugin.json
          jq -e '.platforms == ["macos"]' apple-services/plugin.json

      - name: Check binary SHA matches
        if: steps.touched.outputs.touched == 'yes'
        run: |
          if [ -f apple-services/bin/apple-helper ]; then
            EXPECTED=$(cat apple-services/bin/apple-helper.sha256)
            ACTUAL=$(sha256sum apple-services/bin/apple-helper | cut -d' ' -f1)
            [ "$EXPECTED" = "$ACTUAL" ] || { echo "::error::apple-helper SHA mismatch ($EXPECTED vs $ACTUAL)"; exit 1; }
          fi

      - name: AppleScript syntax check (osascript unavailable on Ubuntu, skip)
        if: steps.touched.outputs.touched == 'yes'
        run: echo "AppleScript syntax check runs on macOS jobs only — deferred"

  validate-apple-services-macos:
    if: github.event_name == 'pull_request'
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Skip if apple-services not touched
        id: touched
        run: |
          if git diff --name-only origin/master...HEAD | grep -q '^apple-services/'; then
            echo "touched=yes" >> "$GITHUB_OUTPUT"
          else
            echo "touched=no" >> "$GITHUB_OUTPUT"
          fi

      - name: AppleScript + JXA syntax check
        if: steps.touched.outputs.touched == 'yes'
        run: |
          fail=0
          for f in apple-services/applescript/*/*.applescript; do
            if ! osascript -s o "$f" < /dev/null 2>&1; then
              echo "::error::$f failed AppleScript syntax check"
              fail=1
            fi
          done
          for f in apple-services/applescript/*/*.jxa; do
            if ! osascript -l JavaScript -s o "$f" < /dev/null 2>&1; then
              echo "::error::$f failed JXA syntax check"
              fail=1
            fi
          done
          exit $fail

      - name: Universal binary sanity
        if: steps.touched.outputs.touched == 'yes'
        run: |
          if [ -f apple-services/bin/apple-helper ]; then
            lipo -info apple-services/bin/apple-helper
            lipo -info apple-services/bin/apple-helper | grep -q 'arm64' || { echo "::error::missing arm64 slice"; exit 1; }
            lipo -info apple-services/bin/apple-helper | grep -q 'x86_64' || { echo "::error::missing x86_64 slice"; exit 1; }
          fi
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/validate-plugin-pr.yml
git commit -m "ci(apple-services): shellcheck, plugin.json, SHA, osascript, lipo validation"
```

---

### Task 25b: Cross-reference youcoded-inbox providers

**Files:**
- Modify: `wecoded-marketplace/youcoded-inbox/skills/claudes-inbox/providers/apple-notes.md` — append note
- Modify: `wecoded-marketplace/youcoded-inbox/skills/claudes-inbox/providers/apple-reminders.md` — append note
- Modify: `wecoded-marketplace/youcoded-inbox/skills/claudes-inbox/providers/icloud-drive.md` — append note

Per spec Section 5 ("Migration from youcoded-inbox → Cross-references added"), these three provider files need a pointer to the apple-services bundle. Working on the same `feature/apple-services` branch keeps these changes inside the same PR.

- [ ] **Step 1: Append to youcoded-inbox/skills/claudes-inbox/providers/apple-notes.md**

Add this block at the end of the file:

```markdown

---

## Related: apple-services bundle

> For general-purpose Notes operations (search, CRUD across folders), see the `apple-services` marketplace bundle's `apple-notes` skill. This provider is inbox-specific and includes re-presentation logic the general-purpose skill does not.
```

- [ ] **Step 2: Append to youcoded-inbox/skills/claudes-inbox/providers/apple-reminders.md**

Add the same pattern, substituting the skill name:

```markdown

---

## Related: apple-services bundle

> For general-purpose Reminders operations (create, list, complete, update across lists), see the `apple-services` marketplace bundle's `apple-reminders` skill. This provider is inbox-specific and includes re-presentation logic the general-purpose skill does not.
```

- [ ] **Step 3: Append to youcoded-inbox/skills/claudes-inbox/providers/icloud-drive.md**

```markdown

---

## Related: apple-services bundle

> For general-purpose iCloud Drive operations (list, read, write, move, delete across folders), see the `apple-services` marketplace bundle's `icloud-drive` skill. This provider is inbox-specific and includes re-presentation logic the general-purpose skill does not.
```

- [ ] **Step 4: Commit**

```bash
git add wecoded-marketplace/youcoded-inbox/skills/claudes-inbox/providers/{apple-notes,apple-reminders,icloud-drive}.md
git commit -m "docs(youcoded-inbox): cross-reference apple-services bundle

Points users from inbox-specific providers to the general-purpose skills
in the new apple-services bundle."
```

---

### Task 26: Push feature branch

**Files:**
- None modified; push only.

- [ ] **Step 1: Push the feature branch**

```bash
cd /c/Users/desti/youcoded-dev/.worktrees/apple-services
git push -u origin feature/apple-services
```

- [ ] **Step 2: Do NOT open PR yet**

The binary is still missing from `apple-services/bin/apple-helper`. Task 29 merges the Phase 1 vendor PR first, which adds the binary; then Task 30 opens the feature PR off a freshly-pulled feature branch.

---

## Phase 3: Release

### Task 27: Merge the Phase 1 vendor PR

**Files:**
- Merges a PR in `itsdestin/wecoded-marketplace`.

- [ ] **Step 1: Locate the PR**

```bash
gh pr list --repo itsdestin/wecoded-marketplace --head "vendor/apple-helper-v0.1.0"
```

- [ ] **Step 2: Review diff**

```bash
gh pr diff <PR-number> --repo itsdestin/wecoded-marketplace
```

Expected changes: 2 files added — `apple-services/bin/apple-helper` (binary) + `apple-services/bin/apple-helper.sha256` (text). No other files.

**Gotcha:** at this point `apple-services/` directory exists on the feature branch but not on master. The vendor PR is creating the bin/ subdir on master while the rest of the plugin is on `feature/apple-services`. That's intentional — merging the vendor PR first means when feature/apple-services gets rebased, the binary is already there.

- [ ] **Step 3: Merge**

```bash
gh pr merge <PR-number> --repo itsdestin/wecoded-marketplace --squash
```

- [ ] **Step 4: Pull the merge into the feature worktree**

```bash
cd /c/Users/desti/youcoded-dev/.worktrees/apple-services
git fetch origin
git rebase origin/master
```

Expected: the binary + sha256 files now appear in the worktree's `apple-services/bin/` directory.

- [ ] **Step 5: Push the rebased feature branch**

```bash
git push --force-with-lease origin feature/apple-services
```

---

### Task 28: Human DEV-VERIFICATION pass

**Not a code task.** Execute `apple-services/.dev/DEV-VERIFICATION.md` end-to-end on a macOS 14+ host. Estimated 2-3 hours.

- [ ] **Step 1: Execute Sections A–F**

Work through the checklist in `apple-services/.dev/DEV-VERIFICATION.md`. Check each box as you complete it.

- [ ] **Step 2: Record issues**

For any item that fails, decide: is it a blocking bug (fix before tag) or acceptable friction (document in release notes)?

- [ ] **Step 3: Gate**

Only continue to Task 29 if all blocking items pass.

---

### Task 28b: Cross-repo — add TCC usage-description keys to YouCoded desktop

**Not in this plan's repos** — a separate PR against `youcoded/desktop/`. Included here because Apple Services' Automation permissions (Step 5 of the setup) won't attach correctly to YouCoded.app without these keys.

Phase 0 R3 finding: Automation TCC attributes grants to the **responsible (parent) process**. When Claude runs inside the YouCoded Electron app, the parent is YouCoded.app — so YouCoded.app's `Info.plist` must carry usage-description strings or macOS will deny the grant (or show an empty description dialog that users reflexively decline).

- [ ] **Step 1: Open a PR against `youcoded/desktop/`**

In a separate session or manually. Changes needed:

- For **electron-builder** configurations (`electron-builder.yml`, `package.json` `build.mac.extendInfo`, or similar): add these keys to the macOS Info.plist.
- For **custom Info.plist patchers**: same keys.

```xml
<key>NSAppleEventsUsageDescription</key>
<string>YouCoded uses AppleScript automation so Claude can help you with Notes and Mail.</string>
<key>NSCalendarsUsageDescription</key>
<string>YouCoded reads and writes your Calendar so Claude can show, create, and update events on your behalf.</string>
<key>NSRemindersUsageDescription</key>
<string>YouCoded reads and writes your Reminders so Claude can show, create, and update reminders on your behalf.</string>
<key>NSContactsUsageDescription</key>
<string>YouCoded reads and writes your Contacts so Claude can look up and update contact details on your behalf.</string>
```

- [ ] **Step 2: Note the PR URL in Task 29's release notes**

This cross-repo PR should ship **before or alongside** the apple-services v0.1.0 tag. If it ships after, early users will see empty/denied Automation prompts until they upgrade YouCoded desktop.

---

### Task 29: Tag apple-services v0.1.0 and open the plugin PR

**Files:**
- None modified; tag + PR only.

- [ ] **Step 1: Open the plugin PR**

```bash
cd /c/Users/desti/youcoded-dev/.worktrees/apple-services

gh pr create \
  --repo itsdestin/wecoded-marketplace \
  --base master \
  --head feature/apple-services \
  --title "feat(apple-services): Calendar + Reminders + Contacts + Notes + Mail + iCloud Drive" \
  --body "$(cat <<'EOF'
## Summary

- New marketplace plugin \`apple-services\`, macOS-only (\`platforms: [\"macos\"]\`).
- Swift helper (\`bin/apple-helper\`) built by the sibling \`itsdestin/apple-helper\` repo, vendored here via the CI auto-PR flow (merged separately).
- Six umbrella SKILLs + nine focused per-op SKILLs.
- Single \`lib/apple-wrapper.sh\` dispatches to helper / osascript / filesystem.
- \`/apple-services-setup\` walks through macOS TCC grants and verifies each integration.

## Test plan

- [x] DEV-VERIFICATION Section A (fresh install) passed on macOS 14.4
- [x] Section B (per-integration CRUD round-trip) passed for all 6
- [x] Section C (permission denial recovery) passed
- [x] Section D (binary-update re-prompt) — [document finding from R3]
- [x] Section E (edge cases) passed
- [x] Section F (inbox coexistence) passed

Design spec: \`docs/superpowers/specs/2026-04-17-apple-services-design.md\` (youcoded-dev)
Implementation plan: \`docs/superpowers/plans/2026-04-17-apple-services-implementation.md\`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Wait for CI to pass**

```bash
gh pr checks <PR-number> --repo itsdestin/wecoded-marketplace
```

Expected: `validate-apple-services` and `validate-apple-services-macos` jobs pass.

- [ ] **Step 3: Merge**

```bash
gh pr merge <PR-number> --repo itsdestin/wecoded-marketplace --squash
```

- [ ] **Step 4: Tag in the marketplace repo (for version tracking)**

```bash
cd /c/Users/desti/youcoded-dev/wecoded-marketplace
git fetch origin
git checkout master && git pull origin master
git tag -a apple-services-v0.1.0 -m "apple-services v0.1.0 — first release"
git push origin apple-services-v0.1.0
```

- [ ] **Step 5: Clean up worktree**

```bash
cd /c/Users/desti/youcoded-dev
git worktree remove .worktrees/apple-services
cd wecoded-marketplace
git branch -D feature/apple-services
```

- [ ] **Step 6: Announce**

Drop a release note in the relevant channel referencing the tag and the DEV-VERIFICATION outcomes.

---

## Phase 4 (reference): Ongoing maintenance

Not tasks in this plan — reference for future work.

- **Binary updates:** Tag `apple-helper-vX.Y.Z` in `itsdestin/apple-helper`. CI opens a vendor PR. Review + merge. Tag the marketplace plugin `apple-services-vA.B.C` if the helper change is user-visible.
- **AppleScript refreshes:** Update `applescript/` files directly in a feature branch. Re-run `osascript -s o` (and `osascript -l JavaScript -s o` for `.jxa`) syntax checks. Bump `apple-services` version.
- **Spec drift:** Re-read `docs/superpowers/specs/2026-04-17-apple-services-design.md` before non-trivial changes; update spec first if the change invalidates a stated invariant.
- **macos-14 runner deprecation (Phase 0 R6 finding):** GitHub Actions' `macos-14` image begins deprecation **2026-07-06** and is fully unsupported **2026-11-02**. Before that, migrate `itsdestin/apple-helper`'s `build-and-vendor.yml` to `macos-15` (or `macos-latest` with a pinned Xcode). Minor one-line change; treat as a scheduled maintenance ticket.
- **R3 empirical follow-up:** TCC behavior findings (display string, re-prompt on hash change, Automation attribution) are desk-research only. During DEV-VERIFICATION section D, capture empirical behavior and update the spec + this plan's release-notes language if reality differs from the desk-researched predictions.

---

## Summary of deliverables

1. **New repo** `itsdestin/apple-helper` with Swift CLI covering Calendar (8 ops), Reminders (7), Contacts (8) — tag `apple-helper-v0.1.0`
2. **New plugin** `wecoded-marketplace/apple-services/` with binary + wrapper + 15 SKILLs + setup command — tag `apple-services-v0.1.0`
3. **Research** — 9 findings files under `docs/superpowers/plans/research/2026-04-17-apple-*.md`
4. **DEV-VERIFICATION** human pass, documented outcomes
