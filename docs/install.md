# Install and first use

This guide is for learners. It tells you how to install Skillgarden and take your first course.
You do not need developer tools.
Agents that publish courses read [the agent publishing guide](agent-publishing.md).

## 1. Requirements

| Item | Requirement |
|---|---|
| macOS | 15 or later |
| Mac | Apple silicon (arm64). The pinned llama.cpp runtime for local Q&A is built only for Apple silicon. |
| Network | Not necessary. Skillgarden runs on your Mac only. |

## 2. Install

1. Get the signed `Skillgarden.app` zip from the owner.
2. Double-click the zip to unzip it.
3. Move `Skillgarden.app` to the Applications folder.
4. Open `Skillgarden.app` from Applications.

The app is signed and notarized for direct distribution (see `docs/release.md`).
The app holds the `skillgarden` CLI at `Skillgarden.app/Contents/Helpers/skillgarden`.

### Install the command line tool

Agents publish courses with the `skillgarden` command. To run it by name in Terminal:

1. Make sure that `Skillgarden.app` is in the Applications folder.
2. Choose Skillgarden > "Install Command Line Tool…".
3. If the app asks to replace the existing skillgarden command, click "Replace".
4. In the alert, click "Copy PATH Line".
5. Paste the line at the end of `~/.zshrc`, then open a new Terminal window.
6. Run `skillgarden --help`.

The PATH line is:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

- The app makes `~/.local/bin/skillgarden` a symlink to the CLI in the app. You do not need an administrator password.
- When you update the app, the `skillgarden` command runs the new version.
- If the app is not in the Applications folder, the install stops. Move the app, then try again.

### Install the agent skill

The agent skill tells an agent how to publish a course with the CLI.
Install it into the skills folder of your agent:

```sh
skillgarden skill install ~/.claude/skills
```

```
Installed skill skillgarden-publish to /Users/<name>/.claude/skills/skillgarden-publish
```

- The command writes `SKILL.md` and the publishing guide `agent-publishing.md` into `skillgarden-publish`.
- A second install replaces the old files. Run it again after an app update.

## 3. Your data

Skillgarden keeps your library in this folder:

```
~/Library/Application Support/Skillgarden
```

- The library holds the courses, your progress, notes and the Q&A history.
- Nothing leaves your Mac by default. Skillgarden has no account and no server.
- To use a different folder, see section 2 of [the agent publishing guide](agent-publishing.md#2-data-folder).

## 4. Add a course

If the library is empty, the app shows "No courses yet".

To import a course folder:

1. Choose File > "Import Course…" (⇧⌘I), or click "Import Course…" under "No courses yet".
2. Select the course folder.
3. If the app shows errors, click "Copy Errors" and give the text to the agent that made the course.
4. If a course with the same ID is installed, the app asks before it replaces it.

An agent can also publish a course with `skillgarden publish`.
See [the agent publishing guide](agent-publishing.md).
If the course does not show, choose View > "Reload Library" (⌘R).

## 5. Take a course

1. Click a course in the library.
2. Click "Start Course", or "Resume" to go back to your last lecture.
3. When you finish a lecture, click "Mark as Complete" (⇧⌘M).
4. To go to the next lecture, choose Go > "Next Lecture" (⌥⌘→).

To find words in the video transcripts:

1. Open a course.
2. Choose Edit > "Search Transcripts" (⌘F).
3. Type a word in the "Search transcripts" field.
4. Click a result to go to that point in the video.

To show the transcript of a video, choose View > "Show Transcript" (⌥⌘T).

## 6. Q&A with the bundled model

Skillgarden answers questions about a lecture with a local model. The default "Answer with" choice is "Bundled model".
Skillgarden does not download a model. Get a GGUF model file first, such as Qwen3 4B Q4_K_M (about 2.5 GB).

1. Choose Skillgarden > "Settings…" (⌘,).
2. Turn on "Use local AI".
3. Click "Choose Model…" and select the GGUF file.
4. Wait until "Status" shows `Ready · llama.cpp b11669`.
5. Open a lecture and choose View > "Show Q&A" (⌥⌘A).
6. Type in the "Ask about this lecture" field, then click "Send".

The bundled runtime runs only on Apple silicon. See [Local AI runtime](local-ai.md) for model and runtime details.

## 7. Remote providers (optional)

A remote provider is optional. Examples are LM Studio, Ollama, the OpenAI API and the Anthropic API.

1. In Settings, click "Add Provider" in the "Q&A" section.
2. Enter the provider details and the key.
3. Set "Answer with" to the provider.
4. Ask a question in a lecture.
5. Read the consent sheet. It shows the provider, the host, the model and the exact text to send.
6. Click "Allow and Send" to send the question. Click "Cancel" to keep the question on your Mac.

- Skillgarden asks once for each course. Lecture text leaves this Mac only after you allow it for each course.
- Keys and tokens stay in the macOS Keychain on this Mac. They do not sync.
- Internal-only course material never goes to a provider.
- To remove a provider, click "Disconnect" in its row. Skillgarden deletes the key and the course permissions.

See [Local AI runtime](local-ai.md#remote-qa-and-provider-profiles-151) for each provider.

## 8. Uninstall

1. If you added remote providers, click "Disconnect" for each in Settings. This deletes their keys from the Keychain.
2. Quit Skillgarden.
3. Move `Skillgarden.app` from Applications to the Trash.
4. If you want to delete your courses and progress, move `~/Library/Application Support/Skillgarden` to the Trash.
