# Direct distribution release

`scripts/release_app.sh` makes a signed and notarized `Skillgarden.app` for direct distribution (#212).
The owner runs it on the build Mac. CI does not run it. App Store submission is out of scope.

## Prerequisites

| Item | Requirement |
|---|---|
| Mac | Apple silicon, macOS 15 or later, with the Swift toolchain and the Xcode command-line tools |
| Runtime | The prepared llama.cpp runtime (see `docs/local-ai.md`, "Prepare the runtime") |
| Apple Developer Program | A paid membership of the team that signs the app |
| Certificate | A "Developer ID Application" certificate and its private key in the login Keychain |
| Network | The notarization step sends the zip to Apple. The other steps use no network. |

Check the certificate:

```sh
security find-identity -v -p codesigning
```

The output must show a line with `"Developer ID Application: <Name> (<TEAMID>)"`.
If the line is missing, the script prints `error: no valid signing identity "<name>" in the Keychain` and exits 2.

## One-time setup

1. Make an app-specific password for your Apple ID at https://account.apple.com.
2. Store the notarization credentials in the Keychain. The command asks for the password. Do not put it in a file.

```sh
xcrun notarytool store-credentials skillgarden-notary --apple-id <Apple ID> --team-id <TEAMID>
```

3. Add the two values to your shell profile (`~/.zprofile`), not to the repository:

```sh
export SKILLGARDEN_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export SKILLGARDEN_NOTARY_PROFILE=skillgarden-notary
```

- The script reads only these two environment variables. It takes no credential from an argument or a file.
- `SKILLGARDEN_NOTARY_PROFILE` is the name of the Keychain profile, not a password.
- If a value is missing, the script prints its name and its setup line, and exits 2 before the build.

## Run

Check the commands first. A dry run prints each command and runs nothing. It needs no certificate and no profile:

```sh
SKILLGARDEN_SIGN_IDENTITY="Developer ID Application: Test (TEAMID)" SKILLGARDEN_NOTARY_PROFILE=test scripts/release_app.sh --dry-run
```

Then make the release:

```sh
scripts/release_app.sh
```

| Step | Commands |
|---|---|
| `[1/6] Build release bundle` | `./scripts/build.sh app release` (#211), then `scripts/check_llama_runtime.sh` with the upstream hash check |
| `[2/6] Sign nested code` | `codesign --options runtime --timestamp` for the llama.cpp libraries, `llama-server`, `SkillgardenAIHost` and `skillgarden`, inner first |
| `[3/6] Sign app (hardened runtime)` | `codesign --options runtime --timestamp` for `build/Skillgarden.app` |
| `[4/6] Notarize` | `ditto` makes a zip, then `xcrun notarytool submit --keychain-profile … --wait` |
| `[5/6] Staple` | `xcrun stapler staple` attaches the ticket to the app |
| `[6/6] Verify` | See "Verify". Then `ditto` makes the artifact zip. |

- The script prints each command with `+` before it runs it.
- The script ends with the artifact path, its SHA-256 and the version:

```
Artifact: build/release/Skillgarden-0.1.0.zip
SHA-256: <64 hex characters>
Version: 0.1.0
```

- The version is `CFBundleShortVersionString` of the app (#214). If the app has none, it is the version of the bundled `skillgarden`.
- Publish the SHA-256 with the artifact.

## Verify

Step 6 uses the Apple command-line tools on the stapled app:

| Command | Result |
|---|---|
| `codesign --verify --deep --strict --verbose=2 build/Skillgarden.app` | `valid on disk` and `satisfies its Designated Requirement` |
| `spctl -a -vv build/Skillgarden.app` | `accepted`, `source=Notarized Developer ID` |
| `xcrun stapler validate build/Skillgarden.app` | `The validate action worked!` |
| `scripts/check_llama_runtime.sh --signed build/Skillgarden.app` | Five `PASS` lines (see below) |

The runtime check has two checks for the files:

| Check | Before signing (step 1) | With `--signed` (step 6) |
|---|---|---|
| `upstream hash` | Each file matches its sha256 in `runtime.json` | Only files that are not code. Signing changes the binaries. |
| `signature` | Each binary has a valid signature (ad hoc is accepted) | Each binary has a valid Developer ID signature of one team, the hardened runtime and a secure timestamp |

To check a downloaded artifact on another Mac, unzip it and run the three Apple commands above.

## Troubleshoot

| Output | Action |
|---|---|
| `error: SKILLGARDEN_… is not set` (exit 2) | Do "One-time setup", step 3. Open a new terminal. |
| `error: no valid signing identity …` (exit 2) | Install the Developer ID certificate with its private key. Copy the name from `security find-identity`. |
| `error: [n/6] … failed: <tool> exited with status <code>` | Read the tool error above the line. Correct the cause and run the script again. It starts from step 1. |
| `error: [4/6] Notarize failed: status Invalid` | Run the printed `xcrun notarytool log <id> --keychain-profile …` command. The log names each file that failed. |
| `notarytool` cannot find the profile | Run `xcrun notarytool store-credentials` again with the same profile name. |
| `FAIL upstream hash` in step 1 | The prepared runtime is not the pinned release. Prepare it again (see `docs/local-ai.md`). |
| `FAIL signature` in step 6 | A nested binary has no Developer ID signature. Check the step 2 output. |
| `spctl` shows `rejected` | The ticket is missing or the signature is not Developer ID. Run the script again. |

The script never prints a password or a token. `notarytool` reads them from the Keychain profile.
