# AGENTS.md — Skillgarden

## Product Overview
Skillgarden is a Mac-native, local course platform, like Udemy, for content that agents create.
- Agents publish courses with the `skillgarden` CLI: a course folder plus a manifest (YAML or JSON). Publishing is idempotent.
- Learners use the SwiftUI app to take courses: video, article, quiz and assignment lectures, transcripts, downloads, progress.
- Everything is local. No accounts, no server, no network.
- Remote Q&A is opt-in. The bundled llama.cpp model is the default. A provider profile sends lecture text only after the learner allows it for each course (#151). Provider secrets live in the Keychain only, never in SQLite, JSON, logs, URLs or manifests.
- The MVP scope is in `docs/mvp-requirements.md`. After the MVP: Q&A, certificates, ratings, analytics, sequencing locks.

## Architecture Map
| Area | Files |
|---|---|
| Package | `Package.swift` (macOS 15+, Swift 6, SwiftPM only, no .xcodeproj) |
| Core library: models, manifest, store, publish, media, search, progress | `Sources/SkillgardenCore/` |
| Agent CLI (`skillgarden publish …`) | `Sources/skillgarden/` |
| SwiftUI learner app | `Sources/SkillgardenApp/` |
| Tests (Swift Testing, `import Testing`) | `Tests/SkillgardenCoreTests/` |
| App bundle for manual runs | `scripts/bundle_app.sh` → `build/Skillgarden.app` |

## Engineering rules
- Build: `./scripts/build.sh` (app bundle: `./scripts/build.sh app`). Full suite: `./scripts/build.sh test`. Filtered: `./scripts/build.sh test --filter <name>`. Both must pass before a PR. Do not call `swift build` directly: it fails in the agent sandbox.
- Put logic in `SkillgardenCore` so tests can reach it. Keep the CLI and the app thin.
- Data lives in `~/Library/Application Support/Skillgarden` (`Skillgarden.defaultDataDirectory`). Tests use a temporary directory, never the real one.
- Use only Apple frameworks (Foundation, SwiftUI, AVKit, PDFKit, ImageIO, SQLite3) plus vendored Yams (`Vendor/Yams`, for YAML manifests). Do not add package dependencies: the agent sandbox has no network.
- Store format changes need a migration. Data saved before a change must still load.
- Internal-only course material is never shown in the learner app.
- Use `PreviewProvider`, not the `#Preview` macro (macros do not run in the agent sandbox).

## Team Roadmap Workflow (multi-agent, GitHub)

A multi-agent team works the release milestone in GitHub (`Mhinolv/Skillgarden`). GitHub Issues are the single source of truth; every change ships as a pull request into `main`. Everyone writes in ASD-STE100 Simplified Technical English with hard length budgets (see the product-team skill, `~/.claude/writing_standard.md`). Roles:

| Role | Responsibility | Output |
|---|---|---|
| Orchestrator | Supervises, prioritizes, creates issue branches, commits/pushes for the engineer, opens PRs, final approver | Merges PRs, closes issues |
| Product Research | Competitor analysis and gap finding | `research.md` |
| Product Manager | Turns gaps/requests into issues (Problem, Scope & Boundaries, Acceptance criteria) | Issues + `**PM review**` comments |
| UI/UX | `## Design notes` section of each issue | Body section + `**UX notes**` comment |
| Engineer | Implements one issue on its linked branch; regression test first for bugs | Changes + `PR BODY` / `COMMIT FILES` blocks |
| QA | Reviews the PR against the issue's acceptance criteria, design notes and owner decisions | Inline review comments + `QA RESULT: PASS/FAIL` PR comment |

Issue flow labels (exactly one at a time): `needs-pm` → `needs-ux` → `ready` → `in-progress` → `in-review` → (`needs-owner-check`) → closed. Also: `bug`/`feature`, `P0`–`P3`, `owner-request`, `redesign`, `blocked`; PR labels `qa-pass`/`qa-fail`.

Rules:
- Issue bodies use the sections `## Problem / Request`, `## Scope & Boundaries`, `## Acceptance criteria`, `## Design notes`, `## Owner decisions`. Edit one section at a time; never drop the others.
- Product-owner decisions are posted as `**Owner decision:** …` comments and mirrored in `## Owner decisions`; they override earlier wording.
- One issue = one branch (`<n>-<slug>`, created with `gh issue develop`) = one PR into `main`. Commits: `#<n>: <summary>`. Stage only the files changed for that issue. Never `git add -A`. Never commit to main.
- PRs must satisfy the PR template (Issue / What changed / How it was tested / Screenshots). `Refs #n` instead of `Closes #n` while the owner still has to check it.
- CI (build + tests) and the PR-template check must be green before merge.
- The Engineer does not commit, push, open PRs or close issues. QA does not modify source. Only the Orchestrator merges PRs and closes issues.
- For this milestone, **QA PASS + green CI + Orchestrator approval replaces the manual user-test gate** (delegated by the product owner), except issues labelled `needs-owner-check`.
- No agent may use browser/Chrome/computer-use/GUI automation tools.
