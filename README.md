# Skillgarden

A Mac-native, local course platform for agent-created content.

- `skillgarden` CLI: agents publish courses from a folder and a manifest.
- Skillgarden app (SwiftUI): learners take the courses.

## Build and run
```sh
swift build
swift test
scripts/bundle_app.sh && open build/Skillgarden.app
swift run skillgarden --version
```

Requirements: macOS 15 or later, Xcode 16 or later. MVP scope: `docs/mvp-requirements.md`.
