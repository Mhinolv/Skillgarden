---
name: skillgarden-publish
description: Publish a course folder to a Skillgarden library in the workspace with the skillgarden CLI, check the result, and hand it off to the owner.
---

# Publish a Skillgarden course

Use this skill to publish a course with the `skillgarden` CLI from a sandboxed workspace.
Do every step in the workspace. Do not write to `~` or to `~/Library/Application Support`.

- The CLI is in the app bundle: `/Applications/Skillgarden.app/Contents/Helpers/skillgarden`.
  The examples write `skillgarden` for it. Use the full path, or copy the CLI with `scripts/install_cli.sh ./bin`.
- The examples use the course folder `./my-course`. To start a new course, run `skillgarden init ./my-course --id my-course --title "My Course"`.
- Manifest fields, lecture types and all commands: `docs/agent-publishing.md`.

## 1. Set the library in the workspace

Put the library in the workspace, next to the course folder. Do not put it inside the course folder.

```sh
export SKILLGARDEN_DATA_DIR="$PWD/.skillgarden-library"
skillgarden doctor
```

```
...
Library:        /path/to/workspace/.skillgarden-library
Source:         SKILLGARDEN_DATA_DIR (environment)
...
```

`doctor` writes nothing. Its report also shows the app library, which ignores the environment variable.

- The value must be an absolute path. `$PWD` makes it absolute.
- If the value is a relative path, each library command stops with `error: SKILLGARDEN_DATA_DIR must be an absolute path` and exit code 2.
- Publish creates the library folder if it is missing.
- If a shell does not keep the `export`, put the variable in front of each command, as in the examples below.

## 2. Validate

Check the course folder. This command does not open the library and writes nothing.

```sh
skillgarden validate ./my-course
```

```
Valid "Local Course Basics" (sample-course, published): 2 sections, 4 lectures
```

- If the exit code is 1, the command prints one `error: <file>: <fieldPath>: <message>` line on stderr for each problem.
- Fix each problem, then run `validate` again.
- For a video lecture, run `skillgarden media inspect <file>` to get the `duration_seconds` value.

## 3. Publish

```sh
SKILLGARDEN_DATA_DIR="$PWD/.skillgarden-library" skillgarden publish ./my-course
```

```
Published "Local Course Basics" (sample-course, published): created 7, updated 0, unchanged 0, removed 0
Files: added 13, changed 0, unchanged 0, removed 0
Snapshot: new <snapshot-id>, 13 files, <size>
Library: /path/to/workspace/.skillgarden-library
```

- Publish is idempotent. A second publish of the same folder prints `unchanged 7` and `Snapshot: kept <snapshot-id>`.
- To see the changes first, add `--dry-run`. The dry run writes nothing.
- A draft course also prints `Draft: learners do not see this course.` To publish it to learners, set the course `state` to `published`.

## 4. Check the result

1. Check the exit code first. Only exit code 0 is a success.

   | Exit code | Meaning | Do this |
   |---|---|---|
   | 0 | Success | Read the output. |
   | 1 | Manifest or file errors | Fix the `error:` lines, then publish again. |
   | 2 | Usage error or bad library folder setting | Check the command and `SKILLGARDEN_DATA_DIR`. |
   | 3 | I/O or library error | Read the `error:` and `hint:` lines. If the library is busy, run the command again. |

2. Read the summary line (`Published "<title>" (<id>, <state>): ...`). Check the course id and the state.
3. Read the `Library:` line. It must show the workspace library, not Application Support.

For a structured result, add `--json`. Stdout then holds one JSON document for each exit code:

```sh
SKILLGARDEN_DATA_DIR="$PWD/.skillgarden-library" skillgarden publish ./my-course --json
```

```
{
  "command" : "publish",
  "diagnostics" : [

  ],
  "exit_code" : 0,
  "format_version" : 1,
  "ok" : true,
  "result" : {
    ...
    "id" : "sample-course",
    "library_path" : "/path/to/workspace/.skillgarden-library",
    ...
    "state" : "published",
    ...
  }
}
```

- Check `ok` and `exit_code`, then `result.id`, `result.state` and `result.library_path`.
- On failure, `result` is `null`. Each item of `diagnostics` has a stable `code`, a `message` and a `hint`.

To check what learners see, run `inspect`. It opens the library read-only:

```sh
SKILLGARDEN_DATA_DIR="$PWD/.skillgarden-library" skillgarden inspect sample-course
```

```
Course "Local Course Basics" (sample-course, published)
Learners: can see this course. 2 of 4 lectures in 1 of 2 sections are visible (2 draft).
Snapshot: <snapshot-id>
Snapshot path: /path/to/workspace/.skillgarden-library/courses/<snapshot-id>
Internal files: 2
Library: /path/to/workspace/.skillgarden-library
```

## 5. Hand off to the owner

The app does not read `SKILLGARDEN_DATA_DIR`. Give the owner the course folder path and one of these two options. Do not run them yourself.

**Option A: import the course folder (recommended).** The owner does these steps in the app:

1. Choose File > `Import Course…` (⇧⌘I).
2. Choose the course folder, such as `/path/to/workspace/my-course`.
3. If the app asks to replace a course with the same ID, choose to replace it.

The app runs the `validate` checks and publishes the course into the app library. If the check fails, `Copy Errors` copies the errors for the agent.

**Option B: open the workspace library.** The owner runs this line once:

```sh
defaults write dev.skillgarden.app DataDirectory "/path/to/workspace/.skillgarden-library"
```

- Give the absolute path from the `Library:` line.
- The app reads the setting when it starts. If the app is open, the owner quits it and opens it again.
- After a later publish to the same library, Reload Library (⌘R) shows the change.
- To go back to Application Support, the owner runs `defaults delete dev.skillgarden.app DataDirectory`.
