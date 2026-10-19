# Agent publishing guide

This guide tells an agent how to publish a course to the Skillgarden library with the `skillgarden` CLI.
The example course is `Tests/Fixtures/sample-course`.

## 1. Quick start

1. Use the CLI that the app bundle holds. You do not need a Swift toolchain or an install step:

   ```sh
   /Applications/Skillgarden.app/Contents/Helpers/skillgarden validate <course-folder>
   ```

   A repository build has the same CLI at `build/Skillgarden.app/Contents/Helpers/skillgarden` (`./scripts/build.sh app`).
   To put a copy in your workspace, run the install script with a destination:

   ```sh
   scripts/install_cli.sh ./bin
   ./bin/skillgarden --help
   ```

   ```
   Installed skillgarden <version> to /path/to/workspace/bin/skillgarden (from /Applications/Skillgarden.app)
   ```

   The steps below write `skillgarden` for the CLI. Use the full path or the workspace copy in its place.

2. Check the course folder. This command writes nothing:

   ```sh
   skillgarden validate Tests/Fixtures/sample-course
   ```

   ```
   Valid "Local Course Basics" (sample-course, published): 2 sections, 4 lectures
   ```

3. Publish the course:

   ```sh
   skillgarden publish Tests/Fixtures/sample-course
   ```

   ```
   Published "Local Course Basics" (sample-course, published): created 7, updated 0, unchanged 0, removed 0
   Library: /Users/<name>/Library/Application Support/Skillgarden
   ```

Publish is idempotent. If you publish the same folder again, the counts show `unchanged`.

To see the changes before you publish, add `--dry-run`. The command reads the library and writes nothing:

```
Dry run "Local Course Basics" (sample-course, published): created 1, updated 1, unchanged 5, removed 1
  create  lecture  check-2
  update  lecture  read
  remove  lecture  check
Files: added 1, changed 2, unchanged 10, removed 1
Snapshot: new, 13 files, <size, such as 48 KB>
Library: /Users/<name>/Library/Application Support/Skillgarden
Nothing was written.
```

- The rows list each changed record. Unchanged records are not listed.
- `Files:` compares the course files with the installed snapshot, internal files included.
- `Snapshot: kept <snapshot-id>` means that publish keeps the installed snapshot.
- If the library uses an older store version, a `Migration:` line shows. Dry run does not migrate.
- If the library uses a newer store version, the command stops with exit code 3 and a `hint:` line.

### Install script

`scripts/install_cli.sh [--app <Skillgarden.app>] [<destination>]`

| Call | Result |
|---|---|
| No arguments | Builds the CLI from source and copies it to `~/.local/bin/skillgarden`. |
| `<destination>` is a folder | Copies the CLI to `<destination>/skillgarden`. An existing folder, a path that ends in `/`, or a new path whose name does not start with `skillgarden` is a folder. |
| `<destination>` is another path | Copies the CLI to that file path, such as `tools/skillgarden-dev`. |
| `--app <path>` | Copies `<path>/Contents/Helpers/skillgarden`. If that file is missing, the script stops with `error:` and exit code 1. |
| No `--app` | Looks for `build/Skillgarden.app`, then `/Applications/Skillgarden.app`. If neither holds the CLI, the script builds from source. |

- The script makes missing folders and replaces an earlier copy.
- The script prints `Installed skillgarden <version> to <absolute path> (from <app path>)`. A source build prints `(built from source)`.
- If the copy fails, the script prints `error: <description>` on stderr and stops with exit code 1.

### Build from source (optional)

If you have a Swift toolchain, build the release CLI from the repository root:

```sh
./scripts/install_cli.sh
```

The script builds the release CLI and copies it to `~/.local/bin/skillgarden`.
If `~/.local/bin` is missing, the script creates it.
If `~/.local/bin` is not on `PATH`, the script prints the `export PATH=...` line to add.

## 2. Data folder

The CLI and the app use the same lookup order for the library folder:

| Order | Source | Set it with |
|---|---|---|
| 1 | Environment variable `SKILLGARDEN_DATA_DIR` | `export SKILLGARDEN_DATA_DIR=/path/to/library` |
| 2 | Saved setting `DataDirectory` in the defaults domain `dev.skillgarden.app` | `defaults write dev.skillgarden.app DataDirectory /path/to/library` |
| 3 | Application Support | Nothing to set: `~/Library/Application Support/Skillgarden` |

- If a value is empty or only spaces, the lookup skips it.
- A leading `~` expands to the home folder.
- If a value is a relative path, the command stops with `error: SKILLGARDEN_DATA_DIR must be an absolute path` (or `DataDirectory`) and exit code 2.

A sandboxed agent often cannot write to Application Support. Use a folder that the agent can write to:

```sh
export SKILLGARDEN_DATA_DIR="$HOME/skillgarden-library"
skillgarden publish path/to/course
```

The app reads the same folder only if it sees the same setting. The owner sets it once:

```sh
defaults write dev.skillgarden.app DataDirectory "$HOME/skillgarden-library"
```

Check which folder the CLI and the app use:

```sh
skillgarden doctor
```

The command prints the library path, its source, the folder state, a write access estimate, the app library and the sandbox state.
The app library ignores the environment variable. If the two paths differ, the command prints the `defaults write` line to run.
The command writes nothing. A missing folder is not an error, because publish creates it.

To go back to Application Support, delete the setting:

```sh
defaults delete dev.skillgarden.app DataDirectory
```

If the library is empty and the folder is not Application Support, the app shows `Library: <path>` under "No courses yet".

If the agent cannot write to the library, the agent builds the course folder in its workspace. The owner then uses File > `Import Course…` (⇧⌘I) in the app. The app runs the `validate` checks, asks before it replaces a course with the same ID, and publishes. Validation errors use the CLI error text, and `Copy Errors` copies them for the agent.

## 3. Course folder layout

Create a starter course folder:

```sh
skillgarden init path/to/new-course --id new-course --title "New Course"
```

- The command writes `skillgarden.yaml`, `content/welcome.md`, `media/course.svg` and `media/section.svg`. The folder passes `validate`.
- The course is a draft with one section and one article lecture. To publish it to learners, change the course `state` to `published`.
- The command creates a missing folder. It refuses a folder that holds entries other than `.DS_Store`, and writes nothing there.
- `--id` and `--title` are required. The id must not be `start` or `welcome`, because the starter section and lecture use these ids.

A course folder holds one manifest (`skillgarden.yaml` or `skillgarden.json`, not both) and the files that it names:

```
sample-course/
├── skillgarden.yaml
├── content/
│   ├── plan.md
│   ├── welcome.mp4
│   └── welcome.vtt
├── internal/
│   ├── research.md
│   └── transcript.vtt
└── media/
    ├── course.svg
    ├── poster.svg
    └── section.svg
```

- All paths in the manifest are relative to the course folder. They must stay inside it.
- Write each path in normalized form, such as `content/x.mp4`. Do not use `./`, `//`, a `.` part or a trailing `/`.
- Symbolic links are not supported.
- Keep the library folder outside the course folder.

## 4. Manifest fields

See `Tests/Fixtures/sample-course/skillgarden.yaml` for a full example.

**Course**

| Field | Required | Notes |
|---|---|---|
| `schema_version` | yes | Must be `1`. |
| `id` | yes | Stable course id. Publish updates the course with this id. |
| `title`, `subtitle`, `description` | yes | Text. Must not be empty. |
| `learning_outcomes`, `requirements` | yes | Lists of text. Each list has at least one item. |
| `target_audience` | yes | Text. |
| `state` | yes | `published` or `draft`. Learners do not see a draft course. |
| `theme.accent_color`, `theme.appearance` | yes | Color in the form `#RRGGBB`, such as `'#286644'`. Appearance is `light` or `dark`. |
| `course_image` | yes | `path` and `alt`. PNG, JPG or SVG. Alt text must not be empty. |
| `credits` | yes | List of `name`, with optional `role` and `url`. At least one item. |
| `sections` | yes | List of sections. At least one item. |
| `internal.files` | no | Team-only files. See section 6. |

**Section**

| Field | Required | Notes |
|---|---|---|
| `id`, `title`, `objective` | yes | Ids are unique in the manifest. |
| `state`, `order` | yes | `state` is `published` or `draft`. `order` is an integer. Sections have unique `order` values. |
| `header_image` | yes | `path` and `alt`. |
| `lectures` | yes | List of lectures. At least one item. |

**Lecture**

| Field | Required | Notes |
|---|---|---|
| `id`, `title`, `objective` | yes | Ids are unique in the manifest. |
| `type` | yes | `video`, `article`, `quiz`, `assignment` or `interactive`. |
| `state`, `order` | yes | Same as for a section. The lectures of a section have unique `order` values. |
| `recommended_next` | no | The id of a lecture in the same course. The app does not use it now (#87). |
| `video`, `article`, `quiz`, `assignment`, `interactive` | for that type | Give only the field that matches `type`. |
| `downloads` | no | Files for the learner to save, in display order. Each has `path` and `title`. `description` is optional. Any lecture type. |
| `sources` | no | "Sources and further watching" cards. Each card has `title` and `channel`. Optional: `url` (http or https), `timestamp_start`, `timestamp_end` (integer seconds, end after start). |

## 5. Lecture types

| Type | Field | Notes |
|---|---|---|
| `video` | `video.path`, `video.duration_seconds` | An `.mp4` file. `duration_seconds` is the video length in seconds. Validate accepts a value within 2 seconds of the real length. Run `skillgarden media inspect <file>` to get the value. Optional: `captions.path` (`.vtt`), `poster` (`path`, `alt`), `free_preview` (accepted, and the app ignores it). |
| `article` | `article.path` | A UTF-8 Markdown file. Each Markdown image needs an entry in `article.images` with `alt`. |
| `quiz` | `quiz.questions` | Each question has `id`, `prompt`, `objective_tag`, `choices` (`id`, `text`), `correct_choice_id`, `explanation`. Optional: `image`. |
| `assignment` | `assignment.brief.path`, `assignment.rubric` | The brief is a UTF-8 Markdown file with the article rules (optional `brief.images`). The rubric has one or more rows with `id`, `criterion`, `guidance`. |
| `interactive` | `interactive.bundle_path` | A folder that holds `index.html`. See `Tests/Fixtures/interactive-course`. The `.html`, `.css` and `.js` files must not refer to URLs that the app blocks: `http:`, `https:`, `//host`, `mailto:`, `javascript:` and paths out of the bundle. In-bundle files, `#fragment`, `data:`, `blob:` and `about:blank` are allowed. |

## 6. Internal files

- Put team-only files in `internal/`. List each one in `internal.files` with `path` and `title`. `description` is optional.
- Each `internal.files` path must stay inside `internal/`.
- The folder name `internal` matches in any case.
- Learner paths (images, videos, articles) must not point into `internal/`.
- Publish keeps `internal/` out of the learner snapshot. The learner app never shows these files.

List the internal files of a published course:

```sh
skillgarden internal list sample-course
```

## 6a. Inspect an installed course

Show the state of an installed course, and whether learners see it. The command opens the library read-only:

```sh
skillgarden inspect sample-course
```

```
Course "Local Course Basics" (sample-course, published)
Learners: can see this course. 2 of 4 lectures in 1 of 2 sections are visible (2 draft).
Snapshot: 3F2A9C1E-...
Snapshot path: /path/to/library/courses/3F2A9C1E-...
Internal files: 2
Library: /path/to/library
```

- The visible counts use the learner rules of the app. A lecture in a draft section is not visible.
- For a draft course, the `Learners:` line tells you why learners cannot see the course and how to fix it.
- For an unknown course id, `inspect` exits 1 and prints `error: course "<id>" not found`, a hint and `Library: <path>` on stderr.

## 6b. Remove a course

Delete a course from the library database. The command needs `--yes`, before or after the id. It never asks a question:

```sh
skillgarden remove sample-course --yes
```

```
Removed "Local Course Basics" (sample-course) from the library.
Learner progress stays. If you publish this course id again, the progress comes back.
Files stay on disk: /path/to/library/courses/3F2A9C1E-...
Files stay on disk: /path/to/library/derivatives/3F2A9C1E-...
Files stay on disk: /path/to/library/internal/3F2A9C1E-...
Library: /path/to/library
```

- Learner progress, the resume lecture and quiz results stay in the library. If you publish the same course id again, the progress comes back.
- The snapshot folders stay on disk. The command prints one `Files stay on disk:` line for each folder that exists. A later release adds a cleanup.
- Without `--yes`, `remove` exits 2 and does not open the library. It prints `error: remove deletes course "<id>" from the library. Run it again with --yes to confirm.` and `Library: <path>` on stderr.
- For an unknown course id, `remove` exits 1 and prints `error: course "<id>" not found` and `Library: <path>` on stderr.
- If the app is open, the course goes away after Reload Library (Command-R).

## 7. Commands and exit codes

The app bundle holds the CLI at `Skillgarden.app/Contents/Helpers/skillgarden`. The commands are the same for each copy.

| Command | Output on success |
|---|---|
| `skillgarden validate <course-folder>` | `Valid "<title>" (<id>, <state>): <n> sections, <n> lectures` |
| `skillgarden publish <course-folder>` | `Published "<title>" (<id>, <state>): created <n>, updated <n>, unchanged <n>, removed <n>`, then `Files: added <n>, changed <n>, unchanged <n>, removed <n>`, `Snapshot: new <id>, <n> files, <size>` (or `Snapshot: kept <id>` when no file changed) and `Library: <path>` |
| `skillgarden publish --dry-run <course-folder>` | `Dry run "<title>" (<id>, <state>): ...` with the same counts, one row for each change, `Files:`, `Snapshot:`, `Library: <path>`, `Nothing was written.` |
| `skillgarden internal list <course-id>` | One tab-separated row for each internal file |
| `skillgarden inspect <course-id>` | `Course "<title>" (<id>, <state>)`, `Learners:`, `Snapshot:`, `Snapshot path:`, `Internal files:`, `Library: <path>`. See section 6a. |
| `skillgarden remove <course-id> --yes` | `Removed "<title>" (<id>) from the library.`, the progress line, one `Files stay on disk: <path>` line for each folder, `Library: <path>`. See section 6b. |
| `skillgarden init <folder> --id <id> --title <title>` | `Created "<title>" (<id>, draft): 4 files in <path>`, then the draft line and the next step |
| `skillgarden media inspect <file>` | `File: <path>`, `Format: MP4`, `Duration: <m:ss> (<n> seconds)`, `Manifest: duration_seconds: <n>`, `Validate accepts: <min> to <max>`. It does not open the library. |
| `skillgarden doctor` | Labelled lines: version, CLI, library, source, folder, write access, app library, match, sandbox |
| `skillgarden schema [--output <file>]` | The manifest JSON Schema. With `--output`: `Wrote manifest schema 1 to <path>`. See section 8. |
| `skillgarden --version` | `skillgarden <version>` |
| `skillgarden --help` | The usage text |

For a draft course, `validate` and `publish` also print `Draft: learners do not see this course.`

| Exit code | Meaning | Output |
|---|---|---|
| 0 | Success | Results on stdout |
| 1 | Manifest or file errors. For `inspect` and `remove`, an unknown course id. For `init`, a folder that is not empty or a path that is not a folder. For `media inspect`, a file that is not MP4 or has no readable length. | One `error: <file>: <fieldPath>: <message>` line on stderr for each problem. List indexes in `<fieldPath>` start at 0: `sections[0]` is the first section. |
| 2 | Usage error or bad data folder setting. For `remove`, a run without `--yes`. | `error: ...` on stderr. A usage error also prints the usage text. |
| 3 | I/O or library error. For `validate`, also a missing course folder. For `media inspect`, a file that does not exist or a folder. For `doctor`, a library path that is not a folder. For `schema`, a file that cannot be written. A busy or locked library. | `error: <description>` on stderr. A busy or locked library also prints a `hint:` line and `Library: <path>`. |

`doctor` prints its report on stdout also for exit codes 2 and 3.

### JSON output

Add `--json` anywhere after the command name, for example `skillgarden validate <course-folder> --json`. Then each run writes one JSON document to stdout, for every exit code. Stderr stays empty. The exit codes do not change. `skillgarden schema --json` writes the schema itself, not the object below.

| Key | Value |
|---|---|
| `format_version` | `1`. Later versions add keys only. |
| `command` | `validate`, `publish`, `internal list`, `inspect`, `remove`, `media inspect`, `init`, `doctor`, `schema`, or `null` for an unknown command |
| `ok` | `true` when `exit_code` is 0 |
| `exit_code` | The process exit code |
| `result` | `null` on failure. `validate`: `title`, `id`, `state`, `draft`, `sections`, `lectures`. `publish`: `title`, `id`, `state`, `draft`, `created`, `updated`, `unchanged`, `removed`, `library_path`, `files` (`added`, `changed`, `unchanged`, `removed`), `snapshot` (`state` `new` or `kept`, `id`, `files`, integer `bytes`). `publish --dry-run` adds `dry_run` (`true`), `changes` (each with `action`, `kind`, `id`) and `migration` (`from`, `to`, or `null`). Its `snapshot.id` is `null` for a new snapshot. `internal list`: `files`, each with `title`, `path`, `description`. `inspect`: `title`, `id`, `state`, `draft`, `visible`, `sections`, `visible_sections`, `lectures`, `visible_lectures`, `snapshot` (`id`, `path`), `internal_files`, `library_path`. `remove`: `title`, `id`, `progress_kept` (`true`), `folders_kept` (the paths of the `Files stay on disk:` lines), `library_path`. `media inspect`: `path`, `format` (`mp4`), `duration_seconds`, `accepted_min`, `accepted_max`. `init`: `title`, `id`, `state`, `draft`, `path`, `files`. `schema --output`: `path`, `schema_version`. `doctor` (also on failure): `version`, `cli_path`, `library_path`, `source`, `folder`, `write_access`, `app_library_path`, `app_source`, `match`, `sandbox`. |
| `diagnostics` | One object for each problem: `code`, `severity` (`error`), `message`, `file`, `field_path`, `hint`, `library_path`. `file`, `field_path`, `hint` and `library_path` are `null` when unknown. `library_path` is set for `library.busy` and `library.locked`. |

The `code` values are stable. New versions add codes, but never rename a code.

| Code | Problem |
|---|---|
| `usage` | The arguments are wrong, or `remove` has no `--yes` |
| `data_dir.relative` | The data folder setting is not an absolute path |
| `data_dir.not_folder` | `doctor` finds a file, not a folder, at the library path |
| `course_folder.missing` | The course folder does not exist |
| `course_folder.not_empty`, `course_folder.not_folder` | `init` finds entries in the folder, or a file at the path |
| `file_not_found`, `not_mp4`, `no_video_length` | `media inspect` finds no file, a file that is not MP4, or an MP4 file with no readable length |
| `manifest.missing`, `manifest.duplicate`, `manifest.syntax` | No manifest, two manifests, or a manifest that cannot be parsed |
| `field.required`, `field.type`, `field.choice`, `field.not_allowed` | A field is missing or empty, has the wrong type, has an unknown value, or is not allowed for the lecture type |
| `field.value` | A value breaks a rule, such as a range, a URL or a hex color |
| `id.duplicate`, `order.duplicate`, `reference.unknown` | A duplicate id, a duplicate order, or an id that does not exist |
| `path.outside`, `path.missing`, `path.not_normalized` | A path leaves its folder, names no file, or is not normalized |
| `media.invalid` | An image, video, captions, Markdown or bundle file is not valid |
| `course.not_found` | `internal list`, `inspect` or `remove` cannot find the course |
| `library.busy` | Another process held a write lock on the library for more than 5 seconds. Run the command again when it stops. |
| `library.locked` | Another operation in the same process locked the library database. Run the command again. |
| `io` | All other errors |

## 8. Manifest schema

`skillgarden schema` prints the JSON Schema (draft 2020-12) of manifest version 1. The repository has a copy in `docs/skillgarden-manifest.schema.json`.

```sh
skillgarden schema --output skillgarden-manifest.schema.json
```

- The schema `$id` is `urn:skillgarden:manifest:1`. It changes when `schema_version` changes.
- The schema lists the required fields, the types, the `state`, `appearance` and lecture `type` values, and the type field that each lecture type needs.
- The schema accepts unknown keys, the same as `validate`.
- A manifest that matches the schema can still fail `validate`. Run `skillgarden validate <course-folder>` before you publish.

Only `validate` does these checks:

| Check | Example error |
|---|---|
| Files exist | `file does not exist` |
| Paths stay inside the course folder, and learner paths stay out of `internal/` | `path must stay inside the course folder` |
| Paths are normalized | `path must be normalized: use "media/intro.mp4"` |
| Media formats: `.mp4`, `.vtt`, images, UTF-8 Markdown, interactive bundles, video length | `must be an .mp4 file` |
| Ids and `order` values are unique | `duplicate id "intro" (first used at ...)` |
| `correct_choice_id` and `recommended_next` refer to a choice or lecture that exists | `must refer to a lecture id in this course` |
| Alt text of each Markdown image | `alt text is required` |
| Hex colors | `must be a hex color such as "#286644"` |
| Text that is only spaces, source URLs and the order of timestamps | `must be an http or https URL` |
