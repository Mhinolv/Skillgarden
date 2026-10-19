# Local AI runtime

`Skillgarden.app` holds one pinned llama.cpp runtime for local AI features.
The app does not use Homebrew or the network to get it.
The app runs one `llama-server` while it is open (#123). Settings shows its status and version.

## Pinned runtime

| Item | Value |
|---|---|
| Release | llama.cpp `b11669` (v0.7.0, commit `620d2225cc436ab0b001e3200e590e3b286ef9ab`) |
| Asset | `llama-b11669-bin-macos-arm64.tar.gz`, sha256 `dbed55493d72bc1ba2babc8770d669c2289b5bc4ee9fb2a4dfc158d45b7d13fd` |
| Source | https://github.com/ggml-org/llama.cpp/releases/tag/b11669 |
| Architecture | `arm64` (Apple silicon, Metal). Intel Macs are not supported. |
| Minimum macOS | 13.3 for the runtime. The app needs 15.0. |
| Manifest | `assets/llama.cpp/runtime.json` |

`runtime.json` keys:

| Key | Value |
|---|---|
| `name` | `llama.cpp` |
| `version` | The release tag, `b11669` |
| `architecture` | `arm64` |
| `minimumSystemVersion` | The `minos` of the release binaries, `13.3` |
| `sha256` | The sha256 of each copied file, by file name |

To change the pin, prepare the new release, update every value in `runtime.json`, and update this document.

## Prepare the runtime (orchestrator, outside the sandbox)

The bundle script and CI never download the runtime. The orchestrator prepares it once on the build Mac:

1. Download the release asset from the Source URL above.
2. Compare its sha256 with the Asset row above.
3. Unpack it into `~/.local/share/skillgarden/llama.cpp/b11669/`.
4. Write `SOURCE.txt` in `~/.local/share/skillgarden/llama.cpp/` with the tag, commit, asset name and sha256.

To use a different folder, set `SKILLGARDEN_LLAMA_DIR`:

```sh
SKILLGARDEN_LLAMA_DIR=/path/to/llama-b11669 ./scripts/build.sh app
```

`./scripts/build.sh app` checks the prepared files before the build:

| Condition | Output |
|---|---|
| `llama-server` is not in the folder | `error: llama.cpp runtime not found at <path>. Prepare it first (see docs/local-ai.md).` (stderr, exit 1) |
| A file in `runtime.json` is not in the folder | `error: <file>: not found in <path>` (stderr, exit 1) |
| A file does not match its sha256 | `error: <file>: checksum does not match runtime.json` (stderr, exit 1) |
| All files match | `Bundled llama.cpp b11669 (arm64) into build/Skillgarden.app` |

## Bundle layout

| Item | Path in `Skillgarden.app` |
|---|---|
| Server helper (#123) | `Contents/Helpers/SkillgardenAIHost` |
| Server binary | `Contents/Helpers/llama/llama-server` |
| Libraries that `llama-server` loads | `Contents/Helpers/llama/*.dylib` |
| Runtime manifest | `Contents/Helpers/llama/runtime.json` |
| License notices | `Contents/Resources/Licenses/llama.cpp/LICENSE` |

- The libraries are in the same folder as `llama-server`. The release rpath `@loader_path` finds them without edits.
- The script copies each library under its install name (for example `libllama.0.dylib`). It copies the file, not the release symlink.
- The script does not copy the other release tools (`llama-cli`, `llama-bench` and others).

Check the bundle with:

```sh
scripts/check_llama_runtime.sh [build/Skillgarden.app]
```

```
PASS arm64
PASS deployment target 15.0
PASS library paths
PASS checksums
```

- The script uses `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and no `DYLD_*` variables, so Homebrew cannot help it.
- `arm64`: each Mach-O file in `Contents/Helpers/llama` holds arm64 code.
- `deployment target`: no file needs a newer macOS than `LSMinimumSystemVersion` of the app.
- `library paths`: each library is in `Contents/Helpers/llama`, `/usr/lib` or `/System/Library`. Each rpath is `@loader_path`, `@executable_path` or a system folder. `llama-server --version` starts.
- `checksums`: each bundled file matches `runtime.json`, and the license notice is present.
- A failure prints `FAIL <check>: <detail>`, and the exit status is 1.

## Server lifecycle

`RuntimeSupervisor` (`Sources/SkillgardenCore/AI/`) owns one server (#123).

- The server starts at app launch when `Use local AI` is on and the model is valid. It stops at quit (⌘Q).
- Closing the last window does not stop it. Turning `Use local AI` off stops it and skips the start.
- The app starts `SkillgardenAIHost --parent-pid <app pid> -- llama-server …`. The helper runs `llama-server` as its child.
- The helper stops the server when its stdin pipe from the app closes, when the app pid exits, or on SIGTERM.
  It sends SIGTERM, then SIGKILL after 3 seconds.
- `llama-server` listens on `127.0.0.1` on a free port, with one slot (`--parallel 1`) and `--ctx-size 8192`.
  If another program takes the port first, the supervisor tries a new port, at most 3 times.
- Each start makes a new session secret. The server gets it in `LLAMA_API_KEY`, so it is not in the process list.
- The status is Ready when `GET /health` gives 200. Before callers send lecture text, they use `verifiedEndpoint()`.
  It checks that the owned server still runs and listens on the port.
- The snapshot harness injects the status and starts no runtime.

## Framework exception

The engineering rules allow only Apple frameworks and the vendored Yams package.
The llama.cpp runtime is an exception to this rule, with these limits:

- It is a separate helper program. The app and `SkillgardenCore` do not link it, and SwiftPM does not build it.
- It is one official release binary, pinned by tag and sha256. Nobody changes or rebuilds it.
- The orchestrator prepares it outside the agent sandbox. No script downloads it.
- It uses only system libraries outside its own folder (Metal, Foundation, libc++).

## Licenses

llama.cpp uses the MIT License. The release `LICENSE` file is in `Contents/Resources/Licenses/llama.cpp/LICENSE`.
If a future release adds notice files, add them to `sha256` in `runtime.json`. The bundle script copies each `LICENSE*` and `NOTICE*` file to the same folder.
