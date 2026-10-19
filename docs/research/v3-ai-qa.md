# Local AI Q&A for Skillgarden

## Executive Summary

Audit date: 2026-10-18. Source revision: `070df0b`. Scope: the owner's local AI request after v2.

Recommend an app-owned `llama-server`, one selected GGUF model, and one Q&A history for each lecture. Use the published transcript or article as evidence. Keep the model resident while the app runs. Store history in SQLite after each turn. Add a supervisor that stops the server after app failure.

This design needs no account or remote service. Loopback HTTP is a narrow exception to the product's original no-server rule. The owner's explicit llama.cpp request establishes that scope. A bundled third-party runtime also needs a documented exception to the Apple-framework rule. No Swift package dependency is necessary.

The strongest product references are Udemy for course context and LM Studio for local document Q&A. The proposed combination is an inference from their documented features. No reviewed source establishes an exact competitor for this complete local course workflow.

Model quality, startup speed, and memory use on the owner's Mac remain unverified. The owner supplied macOS 15.7, but not the chip or RAM capacity.

## Current Code (where each part fits)

I read `AGENTS.md`, `README.md`, `docs/mvp-requirements.md`, and the prior v2 research document. No separate release or review document appeared in the file search. The supplied issue list supersedes the prior document's old issue inventory.

Paths use `Core/` for `Sources/SkillgardenCore/` and `App/` for `Sources/SkillgardenApp/`. New paths below are proposals.

| Area | Verified code | Proposed fit |
|---|---|---|
| Transcript | `Core/Video/Transcript.swift:4` provides ordered text, cue IDs, and start/end times. | Build source passages from these lines. |
| Captions | `Core/Video/WebVTT.swift:23` parses cues and removes tags. `LectureVideo.swift:68` loads optional captions. | Use the existing parser. Show a no-text state when captions are absent. |
| Article | `Core/Article/LectureArticle.swift:41` loads Markdown. `MarkdownDocument.swift:4` defines text blocks. | Extract headings, paragraphs, lists, code, and quotes. Do not fetch linked files. |
| Search | `Core/Search/TranscriptSearch.swift:82` searches cue text. `Core/Store/CourseStore.swift:223` returns indexed cues. | Add lecture-only passage selection. Existing search is not semantic retrieval. |
| Visibility | `Core/Store/CourseStore.swift:91` filters draft outlines. `LibraryModel.swift:605` resolves assets from manifests. | Require membership in the published outline before context access. Asset maps alone are insufficient. |
| Internal files | `Core/Publish/CoursePublisher.swift:42` separates internal files. Line 360 rejects symbolic links. | Read only approved learner assets. Never call `internalFiles` for Q&A. |
| Paths | `Core/Article/LectureArticle.swift:58` rejects internal paths. `Core/Video/LectureVideo.swift:18` uses that rule. | Recheck resolved paths before each context load. |
| Lecture layout | `App/LectureViews.swift:132` supplies a common frame. `SkillgardenApp.swift` selects the lecture view. | Add the Q&A panel through this common layout. |
| Video layout | `App/VideoViews.swift:210` shows a transcript panel. Lines 323–325 supply caption and transcript toggles. | There are no lecture tabs yet. Preserve the existing transcript preference. |
| Seek | `App/VideoViews.swift:84` seeks the player. `Core/LibraryModel.swift:462` creates a `TranscriptSeek`. | Route verified answer citations through the existing seek mechanism. |
| Persistence | `Core/Store/CourseStore.swift:6` declares schema 10. Line 395 begins ordered migrations. | Add the next available migration and Q&A methods under the existing lock. |
| Republish | `Core/Store/CourseStore.swift:65` deletes sections before outline reconstruction. | Do not reference lecture rows with a cascading foreign key for chat history. |
| Launch | `App/SkillgardenApp.swift:6` separates snapshot mode. Line 15 defines the app and its windows. | Own one runtime above all windows. Keep snapshot mode free of runtime startup. |
| Settings | `App/SkillgardenApp.swift:349` defines settings. | Add a model file selector and runtime status. |
| Bundle | `scripts/bundle_app.sh` copies the app and icon. `Package.swift` uses local Yams only. | Copy a pinned runtime and helper from prepared local artifacts. |

### Gap Analysis

The source search used `rg -n 'llama|chat|assistant|Q&A|URLSession|Process\(' Sources`. It returned no matches. The audit also inspected the complete store migration list and relevant views.

| Verified gap | Existing capability that must stay | Evidence | Recommendation |
|---|---|---|---|
| No AI executable or model setup | Existing app bundle and settings | Bundle script, settings, search above | Features 1–2 |
| No owned server lifecycle | App launch and snapshot branch | `App/SkillgardenApp.swift:6` | Feature 3 |
| No AI transport | No URLSession client in Sources | Search above | Feature 4 |
| No prompt builder or token budget | Parsed transcript and article text | Transcript and article files above | Feature 5 |
| No long-text Q&A retrieval | Existing transcript text search | `Core/Search/TranscriptSearch.swift:82` | Feature 6 |
| No saved Q&A history | Progress, quiz, and transcript tables | `Core/Store/CourseStore.swift:395` | Feature 7 |
| No Q&A tab, incremental answer, or cancel action | Transcript toggles and video controls | `App/VideoViews.swift:200–235` | Feature 8 |
| No answer citations | Existing transcript seek | `Core/LibraryModel.swift:462` | Feature 9 |
| No local AI acceptance procedure | Existing Swift Testing suite | `Tests/SkillgardenCoreTests/` | Feature 10 |

The supplied open issues are excluded: #107 portable CLI, #108 doctor, #109 JSON output, #110 scaffold, #111 import, and #112 schema. Also excluded: #113 agent guide, #114 dry-run, #115 receipt, #116 media probe, #117 SQLite errors, and #118 removal.

The proposed runtime is not the portable publication CLI in #107. Feature 1 must extend that issue's final bundle script after v2. Feature 7 must respect course deletion from #118. Live GitHub state was not checked.

## Integration Options

### Comparison and recommendation

| Choice | Benefits | Costs and constraints | Decision |
|---|---|---|---|
| Child `llama-server` | HTTP boundary, separate failure domain, simple stub tests, no Swift binding | Port, process supervision, binary distribution | Recommend. |
| In-process libllama | No port or orphan server. App exit releases runtime memory. | C API bridge, native build artifacts, shared crash domain, custom token loop | Defer. |
| MLX | Apple Silicon support and Swift model APIs | Different runtime/model path and extra package dependencies | Alternative only. |
| Apple Foundation Models | System-managed local model and Swift API | Requires macOS 26 and compatible hardware | Later option, unavailable on the owner's macOS 15.7. |

llama.cpp documents an OpenAI-compatible chat endpoint, incremental responses, tokenization, model context controls, and API keys. Its health endpoint returns 503 during model load and 200 when ready. The default listener is `127.0.0.1:8080`. These facts support the HTTP choice. [Server reference](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

The project also documents an XCFramework route for native integration. That route does not remove the need for app-specific inference control. [XCFramework reference](https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md)

MLX Swift LM supplies Swift model libraries, but conflicts with the current no-new-package rule. Foundation Models first became available with macOS 26. [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm), [Apple release announcement](https://www.apple.com/newsroom/2025/09/apples-foundation-models-framework-unlocks-new-intelligent-app-experiences/)

### Proposed process contract

These are design proposals, not verified runtime measurements.

1. At app launch, read the saved model and runtime configuration.
2. If configuration is valid, start one supervisor and one server asynchronously.
3. Keep the library usable while the model loads.
4. Bind only to numeric loopback, with a new secret for each app session.
5. Allow one inference request at a time across all app windows.
6. On quit, cancel the request and stop the owned process.
7. After a short grace period, kill only the owned child if it does not stop.

Use a small Swift helper that owns the server. The app holds a private pipe to that helper. Pipe EOF signals app death, including force quit. The server must not inherit the pipe's write end. The helper then terminates and reaps its child.

Add a process-exit watcher as a second signal. Apple exposes process event sources through Dispatch. This supports the proposal, but does not prove race-free cleanup. [DispatchSourceProcess](https://developer.apple.com/documentation/dispatch/dispatchsourceprocess)

Register the watcher before server launch. Recheck the parent after registration. Test app death before, during, and after child creation. A normal termination callback alone cannot handle force quit.

If the helper also fails, a server can remain. On the next launch, inspect an owner record with executable identity and process start identity. Never kill a process from a stale PID alone. Cleanup after simultaneous helper and app failure remains a release risk until tested.

Select a random high port and retry a bounded number of bind failures. A free-port probe has a race, so it cannot prove ownership. Confirm that the owned process remains alive. Verify an authenticated endpoint before any lecture text leaves the app. Do not attach to an unknown listener.

Use an ephemeral URLSession without cookies, disk cache, redirects, or proxy routing. Restrict requests to the selected loopback endpoint. Drain server output continuously into a bounded diagnostic buffer. Exclude prompts, answers, and credentials from logs.

Expose `No model`, `Starting`, `Ready`, `Error`, and `Stopping` as service states. Use a generous configurable startup deadline. Offer Retry after failure without a restart loop. A sleep/wake cycle requires a new health check.

Process spawn, model load, and first-answer delay are separate measurements. Context evaluation can dominate the first answer after readiness. Start with one 8K context slot. Measure cold load, warm load, first token, peak memory, and concurrent video playback on the owner's Mac.

## Model and Binary Delivery

### Binary options

| Method | Offline fit | Version control | Recommendation |
|---|---|---|---|
| Bundle a prepared Metal build | Works after app delivery | Pin release, checksum, architecture, and notices | Default release route. |
| Homebrew `llama.cpp` | Installation and updates normally need external access | User upgrades can change flags and API behavior | Developer fallback only. |
| User-chosen executable | Works if the user already has it | Require an explicit supported-version check | Optional advanced fallback. |

Homebrew provides `brew install llama.cpp`. llama.cpp provides Apple hardware support and release artifacts. Actual artifact compatibility with macOS 15.7 must be tested. [Homebrew formula](https://formulae.brew.sh/formula/llama.cpp), [llama.cpp project](https://github.com/ggml-org/llama.cpp)

Prepare the binary outside the restricted agent sandbox. The bundle script must consume local files without a download. Include required dynamic libraries and Metal resources. Check architecture, deployment target, and library paths. Avoid dependencies on the builder's Homebrew directory.

Pin one supported runtime version before implementation. Verify its flags, chat template behavior, and response format. Keep runtime notices with the app. llama.cpp uses MIT terms. Each model has separate terms. [llama.cpp license](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE)

For public distribution, test nested executable signatures and notarization separately. Those checks are not established by the current debug bundle script.

### Model shortlist

These are baseline candidates, not a claim about the best model available. Q&A quality on Skillgarden courses is unverified.

RAM figures are planning estimates for one 8K context, plus headroom for macOS and video. They are not vendor minimums. Quantized weights alone do not describe total memory use.

| Candidate | Format and rough weight size | Suggested Mac RAM | Proposed role and quality risk | License/source |
|---|---|---|---|---|
| Qwen2.5 1.5B Instruct | Q4/Q5 GGUF, about 1–1.5 GB | 8 GB, subject to pressure tests | Small fallback. Complex explanations need close review. | Apache 2.0, [model card](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF) |
| Qwen3 4B | Q4/Q5 GGUF, about 2.5–3 GB | 16 GB preferred | First candidate for the default. Disable its reasoning mode through the supported template. | Apache 2.0, [model card](https://huggingface.co/Qwen/Qwen3-4B-GGUF) |
| Qwen2.5 7B Instruct | Q4/Q5 GGUF, about 4.5–5.5 GB | 16 GB minimum trial, 24 GB preferred | Larger comparison candidate. Better lecture answers remain a hypothesis. | Apache 2.0, [model card](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF) |
| Qwen2.5 3B Instruct | Q4/Q5 GGUF, about 2–2.5 GB | 8–16 GB | Technically suitable size. Do not select it as the distribution default. | Qwen Research, [model card](https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF) |

Qwen3 4B supports both reasoning and non-reasoning modes. The latter better fits a short lecture answer. The 3B Qwen2.5 license differs from its 1.5B and 7B siblings. Do not infer a model's terms from the family name.

Start with Q4_K_M. Compare Q5_K_M only if available RAM permits it. Keep model size, context length, and output length separate in diagnostics. Do not assume every GGUF model includes a suitable instruction template.

### Offline model path

The user obtains the model outside Skillgarden, or copies it from removable media. Skillgarden never downloads a model. A file selector chooses a local GGUF file and saves a bookmark. The app uses the file in place, without a hidden multi-gigabyte copy.

Suggest `~/Library/Application Support/Skillgarden/Models` as an optional folder. Do not require that folder. Show the selected file, size, and model identity in Settings. If the file moves or becomes unreadable, show Choose Model. Reject unsupported split files with a clear message in the first release.

## Q&A Design

All behavior in this section is proposed.

### Lecture context and long text

- Load the selected published lecture's transcript or article off the main thread.
- Preserve cue IDs and timestamps for video passages.
- Preserve block IDs and headings for article passages.
- Cache prepared passages by course ID, lecture ID, and source revision.
- Never scan the course directory for additional material.
- Exclude downloads, quiz answers, assignments, external links, draft lectures, and internal files from the first release.

Captions are optional in the current model. A video can have no transcript despite the owner's intended workflow. Show `This lecture has no text for AI Q&A.` Do not transcribe audio or invent context.

For short lectures, include all source text. Reserve space for instructions, the current question, recent complete turns, and a bounded answer. Count the rendered prompt with the selected model's tokenizer. Word counts alone cannot guarantee a fit.

For long lectures, create overlapping passages at cue or paragraph boundaries. Start with a target near 350 tokens and a small overlap. Rank passages with local lexical relevance to the question. Include nearby passages when they fit. Use a stable tie order and retain original source IDs.

A follow-up question can use the preceding user question for retrieval terms. Previous AI text is conversation history, never source evidence. If selection finds no useful evidence, return an explicit no-evidence response. Show that the answer used selected excerpts.

The initial retrieval method needs no embedding model, vector database, or new dependency. It can miss synonyms and broad questions. Reject whole-lecture summaries when only excerpts fit. Add semantic retrieval only after measured failures justify another model.

### Answers, citations, and boundaries

Use a fixed instruction that limits answers to supplied lecture passages. Treat all course text as untrusted evidence. Delimit evidence separately from instructions. Permit no tools, file access, commands, or external requests.

Ask for source markers such as `[L12]`. Resolve each marker against passages supplied for that request. Generate timestamp buttons from stored cue times, never from model-written time strings. Unknown markers remain non-clickable. A valid marker proves its target, not the truth of the associated claim.

A video citation seeks through `TranscriptSeek` and leaves playback paused. Article citations show the relevant excerpt first. Article scroll-to-block behavior can follow later. Retain the player while the Q&A panel is visible. Replacing the video view currently triggers `onDisappear` and stops playback.

A prompt cannot guarantee obedience. Adversarial course text can cause unsupported answers even with strict instructions. Keep a visible answer limitation and source excerpts. Do not promise perfect grounding.

Internal material must never enter the context, retrieval index, history replay, logs, or answer sources. Resolve paths within the learner snapshot after symbolic-link resolution. Revalidate visibility before each request and before history display.

Use fixture secrets to prove exclusion from requests and responses under the stub. Real-model tests must also check internal-secret leakage. No model can guarantee that arbitrary output never coincides with unseen text. The enforceable boundary is no access to internal material and no display of previously disallowed history.

### Incremental answers and cancel

Decode server-sent events through Foundation URLSession. Buffer incomplete UTF-8 and event frames. Handle errors, terminal markers, disconnects, and empty results. Show received answer text in a draft bubble. Throttle view updates and accessibility announcements.

Cancel closes the task and response stream. The pinned runtime must demonstrate that disconnect stops generation. Keep partial text as `Cancelled`, outside later prompt history. If the runtime does not stop promptly, restart the owned server. Never retry a question automatically after partial output.

Bind each request to its original lecture and revision. On lecture change, cancel the active request. Late events cannot enter another lecture's history. One active request across windows keeps memory and response order predictable.

### SQLite history

Add `qa_threads` and `qa_messages` through the next available migration. Schema 11 is available in this checkout, but v2 can consume it.

| Record | Proposed fields |
|---|---|
| Thread | ID, course ID, lecture ID, source revision, creation date |
| Message | ID, thread ID, sequence, role, text, status, model identity, source references, creation date |
| Index | Unique thread sequence and course/lecture lookup |

Use a course foreign key with cascade deletion. Do not use a cascading lecture foreign key because republish replaces lecture rows. Keep stable lecture IDs across republish. Hide history for lectures that leave the published outline.

Save the question and a pending answer record before inference. Commit the answer when it completes, fails, or is cancelled. After app restart, mark pending records as interrupted. Do not write SQLite once per token.

Retain old history after source changes, but label it as an earlier lecture version. Exclude that history from new prompts. Disable stale citation actions. Clear History deletes the lecture's threads in one transaction and cancels its active request first.

The database preserves conversation text after restart. The server's context cache is temporary and is not the history store. History retention does not imply unlimited prompt memory.

## Prior Art

### Competitors

Prices describe the relevant local or learner offer on the audit date. Unknown prices and platform details remain explicitly unverified.

| Product | Platform and target user | Price | Standout capability | Limitation relative to Skillgarden's goal |
|---|---|---|---|---|
| Coursera Coach | Web course learners. Its page excludes the mobile app. | Included with Plus and selected certificate subscriptions. Exact price unverified. | Course-based explanations, summaries, practice | Account and hosted course workflow, not local learner files. [Source](https://www.coursera.org/explore/coach/) |
| Udemy AI Assistant | Course player for individual and enterprise learners. Mobile parity unverified. | Course/subscription access. Separate assistant fee unverified. | Course Q&A, suggested questions, lecture summaries, lab help | Account and eligible course content, not an offline local library. [Source](https://blog.udemy.com/accelerate-your-career-growth-with-udemy-ai-assistant/) |
| Khanmigo | Web tutor for learners, parents, and teachers | Learners/parents: $4/month. Teacher tools: free. | Guided help that encourages the learner to solve problems | Hosted tutor and eligibility limits. No verified local lecture import. [Source](https://www.khanmigo.ai/pricing) |
| LM Studio | macOS, Windows, Linux. Local AI users and developers | Desktop local use: free for home/work. Separate Bionic offers exist. | Offline document Q&A, model choice, local API | No documented course progress or automatic lecture context. [Offline](https://lmstudio.ai/docs/app/offline), [Desktop](https://lmstudio.ai/developers), [Offers](https://lmstudio.ai/pricing) |
| Ollama | macOS, Windows, Linux. Local model users and developers | Local software/free tier: free. Cloud offers separate. | Model management, local API, load/unload controls | Independent service lifecycle. No documented lecture Q&A interface. [FAQ](https://docs.ollama.com/faq), [Price](https://www.ollama.com/pricing) |
| Jan | Desktop local AI users. macOS supported, with documented Intel restrictions | Local use: free | GGUF import, llama.cpp engine, local API | Generic chat and model controls. No documented lecture/player link. [Engine](https://docs.jan.ai/desktop/local-engine/llama-cpp), [Mac](https://docs.jan.ai/desktop/install/mac) |
| llamafile | Local executable for macOS, Linux, Windows users | Free open-source tool. Model terms separate. | Runtime and model distribution in one file | Technical setup. No documented course UI or progress. [Project](https://github.com/mozilla-ai/llamafile) |

The limitation column compares documented workflows. Absence from these documents does not prove that a competitor lacks every possible extension.

### Feature Matrix

`Yes` means verified in the cited documents. `U` means unverified. `—` means outside the documented product workflow. Local use assumes prepared model files.

| Product | Course UI/progress | Course-based AI | Local offline AI | User model choice | Document context | Local API | AI citation seeks video |
|---|---|---|---|---|---|---|---|
| Skillgarden now | Yes | No | No | No | No AI context | No | No, transcript seek exists |
| Coursera Coach | Yes | Yes | U | U | Course content | U | U |
| Udemy AI Assistant | Yes | Yes | U | U | Course content | U | U |
| Khanmigo | Tutor platform | Yes, curriculum | U | U | U | U | U |
| LM Studio | — | Manual context | Yes | Yes | Yes | Yes | U |
| Ollama | — | Caller supplies it | Yes | Yes | Caller supplies it | Yes | — |
| Jan | — | Manual context | Yes | Yes | U | Yes | U |
| llamafile | — | Manual context | Yes | Yes | U | Yes | — |
| Proposed Skillgarden | Existing | Lecture only | Yes | Local GGUF | Transcript/article | Private loopback | Verified cue IDs |

### Process and model lessons

LM Studio supports a background service independent of its visible app. That is useful prior art, but differs from the owner's quit requirement. Its offline document flow also requires model files first. [Headless service](https://lmstudio.ai/docs/developer/core/headless), [Offline operation](https://lmstudio.ai/docs/app/offline)

Ollama retains models for five minutes by default and exposes `keep_alive`. Its macOS install can register a login item. Do not use that lifecycle for Skillgarden's owned runtime. Current Ollama internals are not assumed to be a drop-in `llama-server`. [Ollama FAQ](https://docs.ollama.com/faq)

Jan exposes llama.cpp and local model import through its interface. Its exact child cleanup after force quit is unverified. llamafile simplifies binary/model delivery, but does not establish app-owned shutdown. [Jan models](https://docs.jan.ai/desktop/manage-models), [llamafile](https://www.mozilla.ai/open-tools/llamafile)

## Risks

| Risk | Required control or evidence |
|---|---|
| App exit leaves a server | Supervisor pipe, parent watcher, crash tests, safe stale-process recovery |
| Unknown listener receives text | Owned process identity and authenticated probe before context transfer |
| Runtime or model reads remote resources | Local paths only, controlled arguments, disabled tools, offline release test |
| Model exhausts RAM during video | One slot, bounded context, model size guidance, owner-Mac measurement |
| Course text changes instructions | Evidence boundary, no tools, adversarial fixtures, visible answer limitations |
| Internal material enters a prompt | Published-outline gate, resolved path checks, no directory scan, fixture secrets |
| Republish erases or misuses history | Stable IDs, no lecture cascade, source revision checks |
| Long text loses evidence | Explicit excerpt mode, budget tests, retrieval evaluation |
| Broken stream corrupts history | Request identity, terminal states, restart repair, cancel tests |
| Runtime update breaks the app | Pinned binary and protocol contract tests |
| Model terms block distribution | Exact model and quantization provenance before any model bundle |

### Tests without a real model

Use Swift Testing and temporary folders only. Inject process, clock, transport, and token-count interfaces into Core. Keep the app and CLI thin. Use the normal build scripts for implementation PRs.

A stub server must implement health, authenticated requests, token counts, and incremental response events. A tiny Swift fixture can listen on loopback through Apple system APIs. URLProtocol fixtures can cover most transport errors without a socket.

Test split event frames, malformed JSON, Unicode boundaries, slow load, wrong credentials, occupied ports, early exit, and cancel. Test supervisor cleanup with a harmless child executable and a simulated parent. Never use the real model or normal library in these tests.

Test migration from schema 10, restart recovery, republish, course deletion, stale citations, and Clear History. Test path traversal, internal folder case variants, draft access, and late events after navigation. Test long input with deterministic token counts.

Stub tests establish protocol and state behavior. They cannot establish answer quality, actual memory use, Metal compatibility, or runtime cancellation. A later release check must use prepared local artifacts on macOS 15.7. No browser or GUI automation is necessary.

## Recommended Features

Order follows dependencies. P1 defines the usable milestone. P2 completes citation navigation and release qualification. S means a narrow change. M means one focused subsystem with tests. No proposal requires a new remote service or account.

### 1. Bundle a pinned local AI runtime — P1, M, script

- Problem: learners cannot rely on Homebrew or network access.
- Prior art: Jan's local engine and llamafile's portable delivery.
- Behavior: copy a prepared Metal runtime, libraries, notices, and version metadata into the app bundle.
- Boundary: no model download, package dependency, or runtime updater.
- Dependencies: v2 #107 merge, then its final bundle layout.
- Likely files: `scripts/bundle_app.sh`, new runtime artifact manifest, `docs/local-ai.md`.
- Check: bundle paths and architecture pass checks without Homebrew on PATH.

### 2. Select and validate a local model — P1, M, Core + app

- Problem: learners need a clear setup state before Q&A can work.
- Prior art: Jan model import and LM Studio model choice.
- Behavior: select one GGUF, save its bookmark, and show file or compatibility errors.
- Boundary: one model, in-place access, no catalogue or automatic copy.
- Dependencies: feature 1's runtime contract.
- Likely files: new `Core/AI/ModelConfiguration.swift`, `App/AISettingsView.swift`, `App/SkillgardenApp.swift`.
- Check: missing, moved, unreadable, and unsupported model files produce actionable states.

### 3. Own the server lifecycle — P1, M, Core + app + script

- Problem: the server must follow app launch and quit, including app failure.
- Prior art: LM Studio and Ollama service controls. Exact app-death behavior comes from the owner request.
- Behavior: start one supervised child, verify readiness, resolve port conflicts, and stop it on parent death.
- Boundary: one runtime and one model. No login service or external server attachment.
- Dependencies: features 1–2.
- Likely files: new `Core/AI/RuntimeSupervisor.swift`, `Sources/SkillgardenAIHost/main.swift`, `Package.swift`, app launch and bundle script.
- Check: a harmless child stops after normal quit and simulated parent death.

### 4. Add incremental answers and cancellation to Core — P1, M, Core

- Problem: a slow answer needs visible progress and a reliable stop action.
- Prior art: llama-server's incremental chat API.
- Behavior: decode incremental events, enforce loopback transport, and cancel a request by identity.
- Boundary: no tool calls, remote provider support, or automatic retries after partial output.
- Dependencies: feature 3's endpoint and session credentials.
- Likely files: new `Core/AI/LlamaClient.swift`, `Core/AI/AnswerStream.swift`, test stub server.
- Check: fragmented events, server errors, cancellation, and late events pass deterministic tests.

### 5. Build safe lecture context — P1, M, Core

- Problem: generic chat does not know the current lecture or its visibility rules.
- Prior art: Udemy and Coursera course context.
- Behavior: extract published transcript/article passages, assign source IDs, and enforce a model-specific token budget.
- Boundary: short lectures first. Refuse oversized context until feature 6 exists.
- Dependencies: feature 4's tokenizer contract.
- Likely files: new `Core/AI/LectureContext.swift`, `Core/LibraryModel.swift`, existing transcript and article types.
- Check: internal secrets, draft text, linked files, and oversized requests never enter a prompt.

### 6. Select evidence from long lectures — P1, M, Core

- Problem: a transcript can exceed the model's safe context window.
- Prior art: LM Studio document retrieval.
- Behavior: create bounded passages, rank local lexical matches, and include neighboring evidence within budget.
- Boundary: no embedding model or vector database. No full-summary claim from selected excerpts.
- Dependencies: feature 5.
- Likely files: new `Core/AI/LectureRetrieval.swift`, context builder, retrieval fixtures.
- Check: relevant distant cues survive selection and all prompts fit the configured budget.

### 7. Preserve Q&A history for each lecture — P1, M, Core

- Problem: learners lose their earlier questions after navigation or restart.
- Prior art: Khanmigo exposes chat history. Exact lecture retention behavior is the owner's requirement.
- Behavior: migrate SQLite, retain ordered turns, track source revisions, repair interrupted turns, and clear lecture history.
- Boundary: no cross-lecture memory or generated history summaries.
- Dependencies: feature 5's source identity. Coordinate with v2 #118 deletion behavior.
- Likely files: `Core/Store/CourseStore.swift`, new `Core/AI/LectureConversation.swift`, store tests.
- Check: republish preserves history, changed sources exclude old prompt turns, and deletion removes owned history.

### 8. Add the lecture Q&A tab — P1, M, app

- Problem: learners need answers without a separate chat app.
- Prior art: Udemy's assistant beside course content.
- Behavior: connect the prepared service, context, and history to a tab with Send, Cancel, Retry, and Clear History.
- Boundary: video and article lectures only. Preserve the video view while the panel changes.
- Dependencies: features 2–7.
- Likely files: new `App/LectureQAView.swift`, `App/LectureViews.swift`, `App/VideoViews.swift`, `App/SkillgardenApp.swift`.
- Check: every service state has a usable view. Navigation cannot mix lecture answers.

### 9. Seek verified answer citations — P2, M, Core + app

- Problem: learners need to check an answer against the original lesson.
- Prior art: document evidence in LM Studio. Equivalent video seek behavior remains unverified elsewhere.
- Behavior: validate source markers, show excerpts, and route video citations to existing seek requests.
- Boundary: no arbitrary links or model-written time targets. Article excerpts have no scroll automation.
- Dependencies: features 5, 7, and 8.
- Likely files: new `Core/AI/AnswerCitation.swift`, `Core/LibraryModel.swift`, `App/LectureQAView.swift`.
- Check: unknown, stale, and wrong-lecture markers cannot seek the player.

### 10. Define the offline release acceptance procedure — P2, S, docs + script

- Problem: stub success does not establish model quality or performance on the owner's Mac.
- Prior art: model/runtime controls in LM Studio and Ollama.
- Behavior: add a repeatable local procedure with fixed questions, expected evidence, and performance measurements.
- Boundary: prepared artifacts only. No network, GUI automation, telemetry, or automatic model acquisition.
- Dependencies: features 1–9.
- Likely files: `docs/local-ai.md`, new `scripts/check_local_ai.sh`, synthetic lecture fixtures.
- Check: record cold load, first token, memory, cancel behavior, refusal accuracy, and citation accuracy on macOS 15.7.

## Open Questions for the Owner

The research is complete without these decisions. Implementation needs answers before model and UI defaults become fixed.

| Decision | Recommended default |
|---|---|
| What chip and RAM does the owner's Mac have? | Measure before selection of the default model. |
| Should setup copy the model or use it in place? | Use it in place through a saved bookmark. |
| Does the milestone include Intel Macs? | Start with Apple Silicon after confirmation of the owner's hardware. |
| Must the server stay resident when AI is unused? | Yes after valid setup, as requested. Expose an explicit disable setting. |
| What does “app closes” mean? | Actual app quit, not closure of the last window. |
| Should old questions survive a lecture update? | Preserve them with an old-version label. Exclude them from new prompts. |
| Which lecture types need the first Q&A tab? | Video and article. Other types show no tab. |

### Questions for UI/UX

| State or decision | Proposed direction for UX review |
|---|---|
| Tab place | Place AI Q&A below the persistent video. Define its relation to the current transcript toggle. |
| Article layout | Use the same tab name and conversation controls. Keep context identity visible. |
| Empty history | Show one short explanation and two fixed example questions. |
| No model | Show Choose Model and a local setup explanation. |
| No lecture text | Explain that a published transcript or article is required. |
| Model startup | Show a status with no false percentage. Keep the lesson usable. |
| Server error | Show the specific cause and Retry or Choose Model. |
| Incremental answer | Show a draft answer, Cancel, and controlled auto-scroll. |
| Citation | Show source time and excerpt. Seek paused on activation. |
| Clear History | Confirm deletion for this lecture. Preserve keyboard focus afterward. |
| Old source version | Label old turns and disable stale source actions. |
| Accessibility | Define focus order, status announcements, and update frequency for VoiceOver. |

## Sources

Sources were checked through built-in web search on 2026-10-18. No browser or GUI automation was used. Vendor statements describe capabilities, not independently measured quality.

- [llama.cpp project](https://github.com/ggml-org/llama.cpp)
- [llama-server API and flags](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [llama.cpp MIT license](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE)
- [llama.cpp XCFramework](https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md)
- [Homebrew llama.cpp](https://formulae.brew.sh/formula/llama.cpp)
- [Apple process event source](https://developer.apple.com/documentation/dispatch/dispatchsourceprocess)
- [Apple Foundation Models availability](https://www.apple.com/newsroom/2025/09/apples-foundation-models-framework-unlocks-new-intelligent-app-experiences/)
- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)
- [Qwen2.5 1.5B GGUF](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF)
- [Qwen2.5 3B GGUF](https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF)
- [Qwen2.5 7B GGUF](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF)
- [Qwen3 4B GGUF](https://huggingface.co/Qwen/Qwen3-4B-GGUF)
- [Coursera Coach](https://www.coursera.org/explore/coach/)
- [Udemy assistant features and access](https://blog.udemy.com/accelerate-your-career-growth-with-udemy-ai-assistant/)
- [Khanmigo price and access](https://www.khanmigo.ai/pricing)
- [LM Studio desktop offer](https://lmstudio.ai/developers)
- [LM Studio offline operation](https://lmstudio.ai/docs/app/offline)
- [LM Studio background service](https://lmstudio.ai/docs/developer/core/headless)
- [LM Studio Bionic offers](https://lmstudio.ai/pricing)
- [Ollama lifecycle and models](https://docs.ollama.com/faq)
- [Ollama offers](https://www.ollama.com/pricing)
- [Jan local engine](https://docs.jan.ai/desktop/local-engine/llama-cpp)
- [Jan local API](https://docs.jan.ai/desktop/api-server)
- [Jan model import](https://docs.jan.ai/desktop/manage-models)
- [Jan Mac support](https://docs.jan.ai/desktop/install/mac)
- [llamafile project](https://github.com/mozilla-ai/llamafile)
- [llamafile delivery description](https://www.mozilla.ai/open-tools/llamafile)

Local evidence: `AGENTS.md`, `README.md`, `docs/mvp-requirements.md`, `docs/research/v2-agent-publishing.md`, and the source paths above. No real model, binary artifact, or app interaction was tested. No source code changed.

## Owner decisions (2026-10-18)

- File all 10 recommended features in milestone v3. Engineer work starts only after v2 is done.
- Bundle one pinned official llama.cpp macOS arm64 release in the app. The orchestrator gets it outside the sandbox. No Homebrew at run time.
- The server starts at app launch and stops at app quit. A Settings toggle turns AI off. "Close" means quit, not the last window.
- The owner's Mac: Apple M4 Max, 48 GB RAM, macOS 15.7. Apple Silicon only. No GGUF model is on the Mac yet. The app uses a user-chosen GGUF file in place.
- Orchestrator default (not an owner decision, the PM must list it as an open question): old questions stay with an old-version label and stay out of new prompts. Video and article lectures get the tab.
