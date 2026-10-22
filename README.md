# Skillgarden

- Learners: see [`docs/install.md`](docs/install.md).
- Agents: see [`docs/agent-publishing.md`](docs/agent-publishing.md).

A Mac-native, local course platform for agent-created content.

- `skillgarden` CLI: agents publish courses from a folder and a manifest.
- Skillgarden app (SwiftUI): learners take the courses.
- Agents also read the [publication skill](docs/agent-skill/SKILL.md) at `docs/agent-skill/SKILL.md`.
- Requirements: macOS 15 or later on Apple silicon. The pinned llama.cpp runtime is arm64 only (see `docs/local-ai.md`).

## Build from source

Requirements: macOS 15 or later, Xcode 16 or later. MVP scope: `docs/mvp-requirements.md`.

```sh
./scripts/build.sh
./scripts/build.sh test
./scripts/build.sh app && open build/Skillgarden.app
swift run skillgarden --version
```

The app bundle needs the prepared llama.cpp runtime (see `docs/local-ai.md`, "Prepare the runtime").
For a signed release, see `docs/release.md`.

### UI snapshots for QA
```sh
./scripts/snapshot.sh "$TMPDIR/snapshots"
```
- The script builds the app, then writes `<out-dir>/<screen>-<light|dark>.png` for each screen (`library-empty`, `library`).
- Each image is 1280×800 pt at 2x, `en_US`, `UTC`, system accent color, with no animations.
- The store is seeded in a temporary directory from `Tests/Fixtures/sample-course`. The real data directory is not used.
- No environment variables are necessary. The script needs a logged-in macOS session (local Mac or a GitHub `macos-15` runner).
- If the build fails, the script writes the error to stderr and exits non-zero.
- To add a screen, add a case to `SnapshotScreen` and seed it in `SnapshotPlan.seedStore`.
