# Agent publishing guide

This guide tells an agent how to publish a course to the Skillgarden library with the `skillgarden` CLI.
The example course is `Tests/Fixtures/sample-course`.

## 1. Quick start

1. Install the CLI from the repository root:

   ```sh
   ./scripts/install_cli.sh
   ```

   The script builds the release CLI and copies it to `~/.local/bin/skillgarden`.
   If `~/.local/bin` is missing, the script creates it.
   If `~/.local/bin` is not on `PATH`, the script prints the `export PATH=...` line to add.

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
   Published "Local Course Basics" (sample-course, published): created 6, updated 0, unchanged 0, removed 0
   Library: /Users/<name>/Library/Application Support/Skillgarden
   ```

Publish is idempotent. If you publish the same folder again, the counts show `unchanged`.

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

To go back to Application Support, delete the setting:

```sh
defaults delete dev.skillgarden.app DataDirectory
```

If the library is empty and the folder is not Application Support, the app shows `Library: <path>` under "No courses yet".

## 3. Course folder layout

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
| `learning_outcomes`, `requirements` | yes | Lists of text. |
| `target_audience` | yes | Text. |
| `state` | yes | `published` or `draft`. Learners do not see a draft course. |
| `theme.accent_color`, `theme.appearance` | yes | Color text such as `'#286644'`. Appearance is `light` or `dark`. |
| `course_image` | yes | `path` and `alt`. PNG, JPG or SVG. Alt text must not be empty. |
| `credits` | yes | List of `name`, with optional `role` and `url`. |
| `sections` | yes | List of sections. |
| `internal.files` | no | Team-only files. See section 6. |

**Section**

| Field | Required | Notes |
|---|---|---|
| `id`, `title`, `objective` | yes | Ids are unique in the manifest. |
| `state`, `order` | yes | `state` is `published` or `draft`. `order` is an integer. |
| `header_image` | yes | `path` and `alt`. |
| `lectures` | yes | List of lectures. |

**Lecture**

| Field | Required | Notes |
|---|---|---|
| `id`, `title`, `objective` | yes | Ids are unique in the manifest. |
| `type` | yes | `video`, `article`, `quiz`, `assignment` or `interactive`. |
| `state`, `order` | yes | Same as for a section. |
| `recommended_next` | no | The id of a lecture in the same course. |
| `video`, `article`, `quiz`, `assignment`, `interactive` | for that type | Give only the field that matches `type`. |
| `downloads` | no | Files for the learner to save, in display order. Each has `path` and `title`. `description` is optional. Any lecture type. |

## 5. Lecture types

| Type | Field | Notes |
|---|---|---|
| `video` | `video.path`, `video.duration_seconds` | An `.mp4` file. Optional: `captions.path` (`.vtt`), `poster` (`path`, `alt`), `free_preview`. |
| `article` | `article.path` | A UTF-8 Markdown file. Each Markdown image needs an entry in `article.images` with `alt`. |
| `quiz` | `quiz.questions` | Each question has `id`, `prompt`, `objective_tag`, `choices` (`id`, `text`), `correct_choice_id`, `explanation`. Optional: `image`. |
| `assignment` | `assignment.brief.path`, `assignment.rubric` | The brief is a UTF-8 Markdown file with the article rules (optional `brief.images`). The rubric has one or more rows with `id`, `criterion`, `guidance`. |
| `interactive` | `interactive.bundle_path` | A folder that holds `index.html`. See `Tests/Fixtures/interactive-course`. |

## 6. Internal files

- Put team-only files in `internal/`. List each one in `internal.files` with `path` and `title`. `description` is optional.
- Each `internal.files` path must stay inside `internal/`.
- Learner paths (images, videos, articles) must not point into `internal/`.
- Publish keeps `internal/` out of the learner snapshot. The learner app never shows these files.

List the internal files of a published course:

```sh
skillgarden internal list sample-course
```

## 7. Commands and exit codes

| Command | Output on success |
|---|---|
| `skillgarden validate <course-folder>` | `Valid "<title>" (<id>, <state>): <n> sections, <n> lectures` |
| `skillgarden publish <course-folder>` | `Published "<title>" (<id>, <state>): created <n>, updated <n>, unchanged <n>, removed <n>`, then `Library: <path>` |
| `skillgarden internal list <course-id>` | One tab-separated row for each internal file |
| `skillgarden --version` | `skillgarden <version>` |
| `skillgarden --help` | The usage text |

For a draft course, `validate` and `publish` also print `Draft: learners do not see this course.`

| Exit code | Meaning | Output |
|---|---|---|
| 0 | Success | Results on stdout |
| 1 | Manifest or file errors | One `error: <file>: <fieldPath>: <message>` line on stderr for each problem |
| 2 | Usage error or bad data folder setting | `error: ...` on stderr. A usage error also prints the usage text. |
| 3 | I/O or library error. For `validate`, also a missing course folder. | `error: <description>` on stderr |
