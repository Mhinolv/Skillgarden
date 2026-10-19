# Agent publication research — v2

## Executive Summary

Audit date: 2026-10-18. Source revision: `070df0b`. The target user is an AI agent with restricted file access.

Skillgarden already supports local validation, repeat publication, draft states, and a shared data-folder setting. The largest barriers are setup and access to the learner's library. Agents also lack structured results, a starter course, and a command to inspect the installed result.

The installed CLI passed validation and temporary publication tests. A lock test returned a generic database error. An article-only update reported seven unchanged records, although the publisher created a new snapshot.

Prioritize a portable CLI, clear path checks, structured results, and a valid starter course. Add app import for agents that cannot access the learner's library. Each proposal below fits one focused PR and needs no account or network.

The supplied issue list contains no open issues. No proposal duplicates an open issue in that list. Live GitHub state is unverified. Closed #44 already delivered the basic agent kit. Closed #64 already strengthened validation. These proposals extend that work.

## Current Agent Journey

I read `AGENTS.md`, `README.md`, `docs/mvp-requirements.md`, and `docs/agent-publishing.md`. No separate release or review document appeared in the repository file search.

Paths below are relative to the repository root. `Core/` means `Sources/SkillgardenCore/`.

| Stage | Current behavior | Agent friction | Code evidence |
|---|---|---|---|
| Install | The script builds a release executable and copies it into `~/.local/bin`. | The destination is outside this workspace. A compiler is necessary even when the app exists. | `scripts/install_cli.sh:10`, `scripts/bundle_app.sh:9` |
| Discover | Help lists three command forms. | Help omits data-folder rules, exit codes, examples, and the guide location. | `Core/Publish/SkillgardenCommand.swift:10` |
| Choose a library | Environment, saved preference, then Application Support determine the path. | A shell override does not configure an app that is already open. | `Core/Skillgarden.swift:22`, `docs/agent-publishing.md` |
| Create a manifest | YAML and JSON share a validator. The fixture supplies an example. | No starter command or exported JSON Schema exists. Agents must create many required fields and two image references. | `Core/Manifest/ManifestValidator.swift:31`, `Tests/Fixtures/sample-course/skillgarden.yaml` |
| Validate | Validation checks fields, paths, media, and interactive references without library writes. | Syntax errors lose parser detail. Diagnostics have no stable error identifier or separate fix hint. | `Core/Manifest/ManifestLoader.swift:4`, `:82` |
| Prepare media | PNG, JPEG, SVG, MP4, Markdown, and WebVTT have local checks. | Agents must supply video duration. No CLI probe exposes the existing duration reader. | `Core/Publish/CoursePublisher.swift:305`, `Core/Video/LectureVideo.swift:94` |
| Collect files | The publisher recursively copies regular files. It rejects symbolic links. | Unreferenced files and hidden folders also enter snapshots. A symlink anywhere blocks publication. | `Core/Publish/CoursePublisher.swift:354`, `:209` |
| Publish | Immutable snapshots precede a database transaction. | No plan command estimates changes or bytes. Some copy failures become generic database errors. | `Core/Publish/CoursePublisher.swift:38`, `:88` |
| Check the result | The CLI prints counts and the library path. The app has `Reload Library`. | No CLI course inspection exists. Agents cannot prove learner visibility from the receipt alone. | `Core/Publish/SkillgardenCommand.swift:18`, `Sources/SkillgardenApp/SkillgardenApp.swift:27` |
| Update | Stable course IDs select updates. Equal files avoid a new snapshot. | Counts describe manifest records, not asset changes. Changed assets can produce an all-unchanged summary. | `Core/Publish/CoursePublisher.swift:54`, `:384` |
| Retain assets | Prior snapshots remain valid for current readers. | Updates retain old media. No cleanup command exists. Large courses can consume substantial disk space. | `Core/Publish/CoursePublisher.swift:90` |
| Remove | Core has `deleteCourse(id:)`. | The CLI has no removal command. Deletion does not itself remove snapshot directories. | `Core/Store/CourseStore.swift:87`, `Core/Publish/SkillgardenCommand.swift:18` |

The fixture contains four lecture types. The interactive example lives separately in `Tests/Fixtures/interactive-course`. Existing tests cover data-folder precedence, validation without writes, and app visibility through the same custom root. See `Tests/SkillgardenCoreTests/AgentPublishingTests.swift:39`, `:69`, and `:112`.

## Sandbox Findings

### Commands and observed results

The executable was `/Users/markhinojosa/.local/bin/skillgarden`, version `0.1.0`. I did not rebuild it. Its exact source revision is unverified. Command behavior matched the inspected code.

All publication commands used a new temporary library through `SKILLGARDEN_DATA_DIR`. No command wrote to the normal Skillgarden library.

| Command or test | Exit | Observed result |
|---|---|---|
| `skillgarden --help` | 0 | Three usage lines. |
| `skillgarden validate Tests/Fixtures/sample-course` | 0 | Valid course, two sections, four lectures. |
| The same validation with a relative data-folder override | 0 | Validation correctly ignores the library setting. |
| `skillgarden publish Tests/Fixtures/sample-course` | 0 | Seven created records. |
| Repeat publication to the same temporary library | 0 | Seven unchanged records. |
| `skillgarden internal list sample-course` | 0 | Two internal file rows. |
| `skillgarden validate --json Tests/Fixtures/sample-course` | 2 | Usage error. |
| Publication with `SKILLGARDEN_DATA_DIR=relative` | 2 | Explicit absolute-path error. |
| Validation of malformed YAML in a temporary folder | 1 | `cannot read or parse manifest`, without a line number. |
| Publication while another SQLite connection held `BEGIN IMMEDIATE` | 3 | Generic database error after 5.32 seconds. |
| Publication after an article edit in a temporary course copy | 0 | Seven unchanged records, but two snapshot directories existed. |
| Validation with `PATH=/usr/bin:/bin`, through the absolute executable path | 0 | No Homebrew executable was necessary. |

Temporary test root: `/var/folders/0n/chksxwms2fn5qzx0grsk5nw40000gn/T/skillgarden-research-wm1z07nt`.

### Constraint assessment

| Constraint | Finding | Evidence level |
|---|---|---|
| Workspace-only writes | The default library and install destination are outside permitted write roots. | Session policy and code inspection. Forbidden writes were not attempted. |
| Data-folder override | A temporary root works. The guide's `$HOME/skillgarden-library` example is also outside this workspace. | Runtime test and guide inspection. |
| No compiler | An existing executable works. The current install script always invokes Swift. | Runtime test and script inspection. |
| Restricted Swift caches | `scripts/build.sh` redirects caches and disables the nested SwiftPM sandbox. | Script inspection. Build success was not retested. |
| No network | These CLI tests needed no network. Yams is vendored. | Runtime tests and repository inspection. |
| No ffmpeg | Validation works without Homebrew on PATH. The MP4 reader uses file headers directly. | Runtime test and `Core/Video/LectureVideo.swift:94`. |
| Large media | The duration reader skips media payloads. Copies and byte comparisons still cost I/O. Old snapshots remain. | Code inspection. Large-file time and disk cost are unverified. |
| App holds database open | An open connection alone is not proof of a lock conflict. A held write transaction reproduced failure. | Controlled temporary test. Actual app contention was not tested. |
| Read-only `.git` | CLI publication does not need Git writes. | Entry point and publisher inspection. |
| Claude Code | File and network restrictions depend on sandbox configuration. | Official [sandbox documentation](https://code.claude.com/docs/en/sandboxing). No runtime test. |
| Cursor | Run modes and sandbox settings control file and network access. | Official [run-mode documentation](https://cursor.com/docs/agent/security/run-modes). No runtime test. |

The SQLite wrapper already waits five seconds. It converts SQLite failures into one generic error. A busy-specific result would help agents choose whether to retry. See `Core/Store/SQLiteDatabase.swift:31` and `:59`.

## Prior Art

### Competitors and adjacent tools

These products are relevant examples, not a market-share ranking. Prices are USD and reflect the pages checked on the audit date.

| Product | Relationship, platform, and target user | Price | Useful behavior | Limitation for our target agent |
|---|---|---|---|---|
| Kolibri | Direct offline education alternative. Local server and client devices serve schools and communities. | Free. | Offline content transfer through peer devices or USB. | Its Studio channel workflow uses an online tool. It differs from a native Mac folder-to-course workflow. [About Kolibri](https://learningequality.org/kolibri/about-kolibri/) |
| Udemy | Direct course platform. Web author tools serve instructors. | No course creation or hosting fee. Revenue share applies to sales. | Bulk file upload, file status, and a media library. | Publication needs its online service and account. [Bulk uploader](https://support.udemy.com/hc/en-us/articles/231537528-How-to-Use-the-Bulk-Uploader), [fees](https://support.udemy.com/hc/en-us/articles/229605008-Instructor-revenue-share) |
| Teachable | Direct course platform. Web author tools serve course businesses. | Starter: $39/month, or $29/month billed annually, plus a 7.5% transaction fee. Other fees can apply. | Bulk upload and unpublished lessons. | Its hosted workflow needs an account and network. [Lesson content](https://support.teachable.com/en/articles/11682455-add-lesson-content), [price](https://www.teachable.com/pricing) |
| Quarto | Adjacent document tool. A CLI on macOS, Windows, and Linux serves technical authors. | Free, open source. | Project creation, Markdown, local output, and preview. | Its documented output centers on documents and websites. Skillgarden course progress integration is unverified. [Overview](https://quarto.org/), [platforms](https://quarto.org/docs/get-started/), [project creation](https://quarto.org/docs/websites/) |
| GitHub CLI | Adjacent CLI design example for developers. | Open-source CLI. Service costs vary. | Structured JSON fields and output filters. | Its GitHub operations need a remote service. Adopt its output contract, not its service dependency. [Output format](https://cli.github.com/manual/gh_help_formatting) |

### Feature Matrix

“Unverified” means the cited evidence does not establish that capability. “Partial” identifies a narrower workflow.

| Product | Offline local input | Starter structure | Validation or status | Structured CLI results | Update or import | Learner result |
|---|---|---|---|---|---|---|
| Skillgarden | Yes | Fixture only | Local validation | No | Repeat folder publication | Native course app |
| Kolibri | Offline transfer | Studio channel workflow | Unverified CLI checks | Unverified | USB or peer import | Offline course platform |
| Udemy | No local publication | Web curriculum | Upload status | Unverified | Bulk media upload | Hosted course |
| Teachable | No local publication | Web lesson editor | Draft lesson visibility | Unverified | Bulk media upload | Hosted course |
| Quarto | Yes, with local dependencies | CLI project creation | Local preview | Unverified | Rebuild documents | Documents and websites |
| GitHub CLI | Partial, local command execution | Not a course tool | Command results | Yes | Remote resource commands | Not a course tool |

### Patterns that fit

| Pattern | Verified prior art | Decision for Skillgarden |
|---|---|---|
| JSON, exit codes, hints, dry run | CLI guidelines discuss script output, errors, and safe command behavior. | Keep existing exit codes 0–3. Add structured details and a publication plan. [CLI Guidelines](https://clig.dev/) |
| Starter command | Quarto creates a project from a command. | Create a complete local draft with text and SVG assets. [Quarto](https://quarto.org/docs/websites/) |
| JSON Schema | The standard describes document structure and constraints. | Ship a local schema. Keep file and media checks in Core. [JSON Schema](https://json-schema.org/docs) |
| `llms.txt` | The proposal exposes concise content for language models. | Optional index only. Local help and documents must work without web retrieval. [Proposal](https://llmstxt.org/) |
| Agent instructions | `AGENTS.md` provides project context. Claude skills use `SKILL.md`. | Ship a small local publication skill with explicit paths and examples. [AGENTS.md](https://agents.md/), [Claude skills](https://code.claude.com/docs/en/skills) |
| MCP over stdio | The client starts a subprocess and exchanges protocol messages through standard streams. | Technically local. Defer until the CLI contract is stable. It cannot grant access outside the sandbox. [Transport specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports) |
| Drop folder or inbox | Hazel applies rules to files in selected folders. | Start with explicit app folder import. A later inbox needs complete-file detection and durable receipts. [Hazel folders](https://www.noodlesoft.com/manual/hazel/hazel-basics/about-folders-rules/) |
| SCORM | SCORM includes content packaging and a runtime contract. | Defer full support. An archive reader alone does not provide a compliant runtime. [ADL guide](https://www.adlnet.gov/assets/uploads/cmi5%20Best%20Practices%20Guide%20-%20From%20Conception%20to%20Conformance.pdf) |
| cmi5 | cmi5 defines launch and session rules with xAPI. | Defer. Its runtime and record-store work exceed this focused milestone. [ADL guide](https://www.adlnet.gov/assets/uploads/cmi5%20Best%20Practices%20Guide%20-%20From%20Conception%20to%20Conformance.pdf) |
| Common Cartridge | The standard supports educational resource exchange. | Consider a later import of local resources. External links and assessments need explicit conversion rules. [1EdTech](https://www.1edtech.org/standards/cc) |
| Bulk course media | Udemy and Teachable accept many content files. | Use local file discovery for a later author assistant. Avoid remote upload services. |

## Gap Analysis

The gaps below refer to the inspected checkout. Searches covered `Sources/`, `scripts/`, `docs/`, and fixture files.

| Gap | Verified boundary | Recommendation |
|---|---|---|
| Portable setup | The install destination is fixed. The app bundle contains only the app executable. | 1 |
| Path diagnosis | Path resolution exists. No command reports its source or sandbox limits. | 2 |
| Machine contract | `CommandResult` has text streams and exit status. No JSON option exists. | 3 |
| Starter course | The command router has no `init` branch. | 4 |
| Sandbox-to-app transfer | No app folder import appeared in source searches. Reload already exists. | 5 |
| Local schema | Rules exist in Swift. No exported schema appeared in the file search. | 6 |
| Self-contained guidance | The guide exists. Help does not expose it, and no repository publication skill appeared. | 7 |
| Change plan | Validation does not compare against the installed publication. | 8 |
| Result inspection | Core can load courses. The CLI exposes only internal file inspection. Asset-only changes lack separate counts. | 9 |
| Media probe | Core reads MP4 duration. The CLI does not expose that result. | 10 |
| Lock recovery | A busy timeout exists. SQLite error details do not reach agents. | 11 |
| Course removal | Core deletion exists. CLI removal does not. | 12 |

Deferred gaps: asset exclusions, snapshot cleanup, and automatic inbox import. These need clear retention and file-selection rules before implementation. Full standard-format imports and an MCP server add less immediate value than a reliable CLI.

## Recommended Features

Rank reflects expected agent effort removed, not measured usage. S means a small interface or document change. M means one focused behavior across a few files. All proposals avoid new dependencies, services, and accounts.

1. **Portable CLI inside the app — P1, M, CLI.**
   Problem: A restricted agent cannot install into the home folder or compile without Xcode.
   Behavior: Bundle the CLI with the app. Let the install script copy an existing binary into an explicit destination.
   Scope: Support direct execution and workspace copies. Keep source builds as an explicit option.
   Prior art: Quarto distributes platform executables. This is a packaging analogy, not a claim about identical install flags.
   Likely files: `scripts/bundle_app.sh`, `scripts/install_cli.sh`, `docs/agent-publishing.md`.
   Check: Run help and validation from the bundled binary without Swift on PATH.

2. **Library path diagnosis — P1, M, CLI/Core.**
   Problem: Agents cannot tell which library the CLI selects or whether the app uses it.
   Behavior: Add `doctor` with the resolved path, setting source, executable version, and relevant restrictions.
   Scope: Read-only checks. Report write access as an estimate. Do not change preferences or claim the app shares shell variables.
   Prior art: CLI Guidelines support clear environment errors and corrective advice.
   Likely files: `Core/Skillgarden.swift`, `Core/Publish/SkillgardenCommand.swift`, `Tests/SkillgardenCoreTests/AgentPublishingTests.swift`.
   Check: Cover environment precedence, missing folders, and relative paths.

3. **Structured command results — P1, M, CLI/Core.**
   Problem: Agents must parse prose and cannot classify individual failures reliably.
   Behavior: Add `--json` with a format version, result fields, diagnostics, stable codes, and fix hints.
   Scope: Cover existing commands and common errors. Preserve exit codes 0–3 and default text output.
   Prior art: GitHub CLI JSON output and CLI Guidelines.
   Likely files: `Core/Publish/SkillgardenCommand.swift`, `Core/Manifest/ManifestLoader.swift`, `Core/Manifest/ManifestValidator.swift`, command tests.
   Check: Parse both success and failure output as JSON. Keep stdout free of extra text.

4. **Valid starter course — P1, M, CLI/Core.**
   Problem: Agents copy a complex fixture and repair fields before they can publish useful text.
   Behavior: Add `init <folder> --id <id> --title <title>` with one draft article and local SVG assets.
   Scope: Create every required field. Refuse to overwrite a nonempty folder. Do not generate video.
   Prior art: Quarto project creation.
   Likely files: `Core/Publish/SkillgardenCommand.swift`, new `Core/Publish/CourseScaffold.swift`, scaffold tests.
   Check: The output passes validation with no network and no additional assets.

5. **Import a course folder in the app — P1, M, app/Core.**
   Problem: The agent can create a course but cannot write to the learner's library.
   Behavior: Add an app command that lets the owner select the completed course folder and import it.
   Scope: Reuse `CoursePublisher`, show validation failures, and reload after success. Confirm replacement of an existing course ID.
   Prior art: Kolibri offline import and Udemy local file selection.
   Likely files: `Sources/SkillgardenApp/SkillgardenApp.swift`, `Core/LibraryModel.swift`, import tests.
   Check: Import from a separate source folder into a temporary app library. This requires one owner action, not sandbox escalation.

6. **Offline manifest schema — P2, M, CLI/docs.**
   Problem: Agents must infer the full contract from Swift or a large example.
   Behavior: Ship a versioned JSON Schema and expose it through `skillgarden schema`.
   Scope: Include required fields, enums, and lecture variants. Document semantic checks that still require `validate`.
   Prior art: JSON Schema.
   Likely files: new schema resource, `Package.swift`, `Core/Publish/SkillgardenCommand.swift`, manifest tests.
   Check: Compare schema fields and enums with the existing manifest contract to detect drift.

7. **Local agent quick start — P2, S, docs/CLI.**
   Problem: The guide assumes a home-folder install and suggests a library path outside this sandbox.
   Behavior: Expand help and add a local skill with a workspace example, result checks, and app import instructions.
   Scope: Document only shipped commands. Link the guide from README and help. Keep the full reference separate.
   Prior art: `AGENTS.md`, Claude skills, and the `llms.txt` index concept.
   Likely files: `README.md`, `docs/agent-publishing.md`, new publication `SKILL.md`, `Core/Publish/SkillgardenCommand.swift`.
   Check: Follow the documented path from a workspace without home-folder writes.

8. **Publication plan without writes — P2, M, CLI/Core.**
   Problem: Validation cannot reveal replacements, removed lectures, or the size of a new snapshot.
   Behavior: Add `publish --dry-run` with record differences, file totals, and the selected destination.
   Scope: Use a true read-only store path. Do not create a database or run migrations. Flag unsupported store versions.
   Prior art: CLI Guidelines for dry runs.
   Likely files: `Core/Publish/CoursePublisher.swift`, `Core/Store/SQLiteDatabase.swift`, `Core/Store/CourseStore.swift`, command tests.
   Check: Compare the library tree before and after the plan. Confirm that no file changes.

9. **Publication receipt and course inspection — P2, M, CLI/Core.**
   Problem: Asset edits can produce an unchanged summary. Agents cannot inspect the installed course through the CLI.
   Behavior: Add `inspect <course-id>` and include the snapshot identifier in publication results.
   Scope: Show course state, visible lecture count, root, and snapshot path. Distinguish asset changes from manifest record changes.
   Prior art: Udemy file status and GitHub CLI structured inspection.
   Likely files: `Core/Publish/CoursePublisher.swift`, `Core/Publish/SkillgardenCommand.swift`, `Core/Store/CourseStore.swift`, publication tests.
   Check: An article-only edit changes the receipt. Draft inspection explains why learners cannot see the course.

10. **MP4 duration probe — P2, S, CLI/Core.**
    Problem: Agents guess duration or seek ffmpeg before they can create a valid video manifest.
    Behavior: Add `media inspect <file>` with the detected MP4 duration and the manifest value to use.
    Scope: Reuse the existing parser. Do not transcode or promise codec compatibility.
    Prior art: Udemy exposes media type and status. The duration probe is a local extension of that idea.
    Likely files: `Core/Video/LectureVideo.swift`, `Core/Publish/SkillgardenCommand.swift`, media tests.
    Check: Match the current duration validator with no external executable.

11. **Actionable database lock errors — P2, S, Core/CLI.**
    Problem: A temporary lock looks like an unspecified store failure.
    Behavior: Preserve busy and locked SQLite results. Report a stable code, retry advice, and the library path.
    Scope: Keep the existing bounded timeout. Do not change journal mode or add an indefinite retry loop.
    Prior art: CLI Guidelines for actionable errors. The audit reproduced the local need.
    Likely files: `Core/Store/SQLiteDatabase.swift`, `Core/Publish/SkillgardenCommand.swift`, store tests.
    Check: Hold a temporary write lock and verify the diagnostic. Retry successfully after release.

12. **Explicit course removal — P3, S, CLI/Core.**
    Problem: Agents can create temporary or mistaken courses but cannot remove them through the CLI.
    Behavior: Add `remove <course-id> --yes` with the affected library path in the result.
    Scope: Reuse Core deletion. State the effect on learner progress. Retain asset snapshots until a separate cleanup design exists.
    Prior art: [Teachable course deletion](https://support.teachable.com/en/articles/11682451-create-and-set-up-your-course) and Udemy media deletion.
    Likely files: `Core/Publish/SkillgardenCommand.swift`, `Core/Store/CourseStore.swift`, command tests, `docs/agent-publishing.md`.
    Check: Remove one temporary course without changes to another course. Reject the command without explicit confirmation.

Implementation order can follow the rank. Features 8 and 9 need a shared read-only store interface. Feature 7 must track commands as they ship.

## Sources

Local evidence: the code paths and tests cited above, `AGENTS.md`, `README.md`, and the supplied issue list. Runtime results came from temporary libraries only.

Web sources were checked with built-in search and page retrieval. No desktop or browser automation was used.

- [Kolibri overview and offline transfer](https://learningequality.org/kolibri/about-kolibri/)
- [Udemy bulk uploader](https://support.udemy.com/hc/en-us/articles/231537528-How-to-Use-the-Bulk-Uploader)
- [Udemy fees and revenue share](https://support.udemy.com/hc/en-us/articles/229605008-Instructor-revenue-share)
- [Teachable lesson content](https://support.teachable.com/en/articles/11682455-add-lesson-content)
- [Teachable course setup and deletion](https://support.teachable.com/en/articles/11682451-create-and-set-up-your-course)
- [Teachable prices](https://www.teachable.com/pricing)
- [Quarto overview](https://quarto.org/)
- [Quarto platform downloads](https://quarto.org/docs/get-started/)
- [Quarto project creation](https://quarto.org/docs/websites/)
- [GitHub CLI JSON output](https://cli.github.com/manual/gh_help_formatting)
- [CLI Guidelines](https://clig.dev/)
- [JSON Schema](https://json-schema.org/docs)
- [llms.txt proposal](https://llmstxt.org/)
- [AGENTS.md format](https://agents.md/)
- [Claude Code skills](https://code.claude.com/docs/en/skills)
- [Claude Code sandbox](https://code.claude.com/docs/en/sandboxing)
- [Cursor run modes](https://cursor.com/docs/agent/security/run-modes)
- [MCP stdio transport](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
- [Hazel folder rules](https://www.noodlesoft.com/manual/hazel/hazel-basics/about-folders-rules/)
- [ADL cmi5 guide and SCORM context](https://www.adlnet.gov/assets/uploads/cmi5%20Best%20Practices%20Guide%20-%20From%20Conception%20to%20Conformance.pdf)
- [Common Cartridge](https://www.1edtech.org/standards/cc)

## Owner decisions (2026-10-18)

- File all 12 recommended features as v2 issues. Work the P1 features first.
- A sandboxed agent gets its course into the app through the app import command (feature 5). The agent builds the course folder in its workspace. The owner imports it once. Do not build a watched inbox folder in v2.
