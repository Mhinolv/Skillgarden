# Model providers for lecture Q&A

## Executive Summary

Research date: 2026-10-19. Code revision: `5356367`. The supplied GitHub issue list defines the release state.

Start with LM Studio and Ollama through their local HTTP APIs. This gives the owner access to existing MLX models without another bundled runtime. Add direct OpenAI and Anthropic APIs after explicit consent controls. Add OpenRouter through the compatible endpoint adapter.

An official ChatGPT subscription path now exists for eligible local apps. Use Sign in with ChatGPT and the Responses API. Confirm Skillgarden's eligibility before implementation. Claude and Gemini subscription credentials are not interchangeable with API keys. Their CLI paths need separate treatment. [OpenAI overview](https://developers.openai.com/siwc/token-sharing-open-source), [Claude rules](https://code.claude.com/docs/en/legal-and-compliance), [Gemini rules](https://geminicli.com/docs/resources/tos-privacy/).

Keep llama.cpp as the default. Keep context selection, citations, history, and cancellation in Core. Do not add a Skillgarden account or backend.

This document replaces the general competitor survey requested earlier. It does not create GitHub issues. No source code changed.

## Owner decisions needed

| Decision | Recommendation |
|---|---|
| Permit remote Q&A under the local-only product rule? | Permit direct provider requests only after explicit opt-in. Keep courses and history local. |
| Permit external local servers? | Permit user-managed LM Studio and Ollama. Skillgarden does not start or stop them. |
| Permit additional Apple frameworks? | Approve Security for Keychain. Approve AuthenticationServices and necessary OAuth support before subscription work. |
| Is Skillgarden eligible for Sign in with ChatGPT? | Confirm its distribution, license, and commercial status. Keep this feature free to use. |
| Permit prior answers to leave the Mac? | Ask before each course uses a new provider. Include eligible history in the notice. |
| Keep the bundled model resident when another provider is selected? | Preserve the current lifecycle rule from #123 until the owner changes it. |
| Support Gemini at launch? | Defer until its consumer-use and age restrictions are resolved for Skillgarden. |
| Support Claude or Gemini subscription wrappers? | Defer the Q&A wrappers until the vendors confirm this exact use. |
| Require macOS 26 for Apple models? | Keep macOS 15 support. Consider an optional adapter after an SDK and device check. |

The owner can change product policy. The owner cannot waive provider terms. ChatGPT eligibility and the current SDK on this Mac remain unverified.

## Findings

### 1. API models

These interfaces support text requests without a vendor SDK. Foundation `URLSession` can send the requests from Core. SSE means server-sent events.

| Provider | Authentication | Request and response | First-release decision |
|---|---|---|---|
| OpenAI | API key as Bearer token | `/v1/responses`: `model`, `instructions`, `input`, `stream`. Typed SSE text events. | First direct remote API. Reuse its decoder for the subscription path. |
| Anthropic | Bearer API key, or supported `x-api-key`. Required `anthropic-version`. | `/v1/messages`: `model`, top-level `system`, `messages`, `max_tokens`, `stream`. Typed SSE blocks. | Second direct remote API. Use a separate encoder and decoder. |
| Gemini | Native `x-goog-api-key`. Compatible API uses Bearer key. | Native `streamGenerateContent?alt=sse`: `contents`, `systemInstruction`, `generationConfig`. Compatible chat API also exists. | Defer the preset until the terms question is resolved. |
| OpenRouter | Bearer API key | `/api/v1/chat/completions`: `model`, `messages`, `stream`. OpenAI-style SSE, comments, and possible error events. | Next API provider. Require an explicit upstream policy. |
| LM Studio | Optional server token as Bearer | Local `/v1/chat/completions` and `/v1/models`. OpenAI-compatible text response. | First external local provider. Default port: 1234. |
| Ollama | No authentication for its local API | Local `/v1/chat/completions` and `/v1/models`. OpenAI-compatible subset. | Same local adapter. Default port: 11434. |
| Custom endpoint | Optional Bearer key, scoped to its origin | Explicit base URL, model ID, and Chat Completions text subset | Support that tested subset. Do not promise every OpenAI feature. |

Sources: [OpenAI chat reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create), [Responses contract](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [Anthropic headers](https://platform.claude.com/docs/en/api/overview), [Anthropic Messages](https://platform.claude.com/docs/en/api/messages/create), [Anthropic SSE](https://platform.claude.com/docs/en/build-with-claude/streaming), [Gemini native API](https://ai.google.dev/api/generate-content), [Gemini compatibility](https://ai.google.dev/gemini-api/docs/openai), [OpenRouter authentication](https://openrouter.ai/docs/api/reference/authentication), [OpenRouter SSE](https://openrouter.ai/docs/api/reference/streaming), [LM Studio API](https://lmstudio.ai/docs/developer/openai-compat), [LM Studio authentication](https://lmstudio.ai/docs/developer/core/authentication), [Ollama compatibility](https://docs.ollama.com/api/openai-compatibility).

The common internal request needs these fields:

- A provider profile and model ID.
- System instructions with selected passage IDs and text.
- Eligible prior user and assistant messages.
- The current question.
- A context budget and an optional output limit.
- A request ID for cancellation.

There is no universal JSON body. For compatible Chat Completions endpoints, start with `model`, `messages`, and `stream: true`. Map the output limit per provider. OpenAI Chat Completions uses `max_completion_tokens` for relevant models. Anthropic requires `max_tokens`. Gemini uses `generationConfig.maxOutputTokens` in its native API. Omit temperature, tools, files, web search, and model-specific options from the initial common contract.

For OpenAI Responses, place system text in `instructions` and conversation messages in `input`. Use `store: false`. For API keys, use `max_output_tokens` to bound output. Treat `response.completed` as success. Handle failures and incomplete responses separately. Subscription requests have additional restrictions, described below. [Responses reference](https://developers.openai.com/api/reference/python/resources/responses/methods/create).

Use a small tested model list plus manual model IDs. A model catalogue does not prove account access. Do not rank models by quality without lecture tests. Exact cost, speed, and citation accuracy on these lectures are unverified.

API use can incur provider charges. A consumer subscription does not create a general API credit balance. The official ChatGPT plan path is a distinct authorization mode.

Gemini's current terms restrict API use to professional or business purposes. They also restrict apps likely to serve people under 18. Unpaid-service terms permit Google to use submitted content for product improvement and human review. Paid-service terms provide different data treatment. These constraints need resolution before a consumer course app exposes a Gemini preset. A compatible API does not remove them. [Gemini API terms](https://ai.google.dev/gemini-api/terms).

### 2. Subscription models

| Path | Verified status | Product decision |
|---|---|---|
| ChatGPT Plus/Pro through official Sign in with ChatGPT | Supported for eligible apps and accounts. | Recommend after eligibility confirmation. |
| ChatGPT cookies or private website endpoints | Outside the supported flow. SIWC prohibits password or session-cookie collection. | Exclude. |
| Codex app-server subprocess | Official documentation supports app-server with an app-authorized ChatGPT token. | Valid alternative, but adds a CLI dependency. |
| Claude Pro/Max through app-owned OAuth or copied tokens | Anthropic prohibits third-party Claude.ai login and credential intermediation. | Exclude. |
| User signs in to unmodified Claude Code | Anthropic permits this under its documented product-host conditions. | Do not equate this with permission for a hidden Q&A proxy. |
| Claude Code as Skillgarden's subscription Q&A engine | The exact wrapper use is unverified. | Seek vendor confirmation before implementation. |
| Gemini subscription through reused CLI OAuth | Google explicitly identifies this access as a terms violation. | Exclude. |
| Unmodified Gemini CLI as a Q&A subprocess | Headless execution exists. Permission for this product wrapper is unverified. | Defer. |
| Apple on-device Foundation Models | Official framework access. No consumer model subscription required. | Local option, not a Claude, ChatGPT, or Gemini entitlement. |

#### ChatGPT: use the documented local-app route

OpenAI documents local sign-in with PKCE, dynamic registration, a persistent host ID, and a loopback callback. No partner API key or client secret is required for that flow. Validate state, nonce, identity, and granted scopes. Store credentials in the Keychain. [Registration](https://developers.openai.com/siwc/token-sharing-open-source/sign-in).

The SIWC terms require the app's real identity, user-authorized requests, and local credential storage under user control. The feature cannot require payment to Skillgarden. Account sharing, token pooling, and quota bypass are prohibited. Paid or remotely hosted app access needs separate eligibility review. [SIWC terms](https://openai.com/policies/sign-in-with-chatgpt-terms/), [eligibility](https://developers.openai.com/siwc/token-sharing-open-source).

Use the public `/v1/responses` endpoint with the authorized token. Fetch account-specific models. Do not use ChatGPT's private backend endpoints. The preview requires `store: false`, `stream: true`, and explicit history in `input`. It rejects `max_output_tokens`, `temperature`, and several other fields. Put instructions outside explicit system-message items. Thus, output limits must be optional in the abstraction. Client cancellation cannot guarantee a provider-side cost ceiling. [Inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [preview limits](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).

Codex app-server can accept the app's token through its child environment. It uses newline-delimited RPC messages and incremental answer events. Token refresh requires process renewal in the documented setup. Direct HTTP avoids that process lifecycle and keeps Q&A free of agent tools. Do not read another app's token store. [App-server integration](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server).

#### Claude: distinguish a native CLI from credential reuse

Anthropic permits products to host the unmodified Claude Code binary under stated commercial conditions. Users must authenticate themselves. Products cannot remove authentication methods or intermediate usage charges. The same document prohibits third-party Claude.ai login and token collection. [Claude Code rules](https://code.claude.com/docs/en/legal-and-compliance).

Claude Code supports `-p` and structured incremental output. This establishes technical feasibility, not blanket permission for subscription-backed lecture Q&A. A wrapper also needs to prevent file access, tools, hooks, and unrelated context. Use the direct API first. [Programmatic execution](https://code.claude.com/docs/en/headless).

Anthropic's current account guidance allows some third-party use at its discretion through paid usage credits. It does not promise access to included subscription limits. Skillgarden has no verified special agreement. [Account guidance](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account), [consumer terms](https://www.anthropic.com/legal/consumer-terms).

#### Gemini: a CLI subscription is not an API credential

Google AI Pro and Ultra increase limits for Gemini CLI and Code Assist. Google prohibits third-party direct access through CLI OAuth. The CLI's Apache license does not grant service access rights. Headless JSONL output exists, but this research did not verify permission for a general course-app wrapper. [Plan FAQ](https://geminicli.com/docs/faq/), [terms](https://geminicli.com/docs/resources/tos-privacy/), [headless reference](https://geminicli.com/docs/cli/headless/).

### 3. Local alternatives

Cost estimates below describe engineering scope, not measured delivery time.

| Option | Cost to Skillgarden | Learner requirements | Recommendation |
|---|---|---|---|
| LM Studio with MLX | M: compatible client, model ID, connection state, optional token | Existing LM Studio, supported MLX model, active server | Use the owner's existing models through HTTP. |
| Ollama local models | S after the compatible client | Installed Ollama and local model | Add a preset and local-only setup guidance. |
| Bundled MLX Swift runtime | L: dependencies, model formats, packaging, memory, lifecycle, tests | Compatible Apple Silicon model | Defer. Conflicts with the no-new-package rule. |
| User-managed MLX server | S after the compatible client, if its API conforms | User installs and maintains that server | Treat as a custom endpoint. Exact server compatibility is unverified. |
| Apple on-device Foundation Models | M adapter plus SDK and device validation | macOS 26+, supported Apple Intelligence hardware, model availability | Defer for the owner's recorded macOS 15.7. |

LM Studio documents its MLX engine and OpenAI-compatible API. Skillgarden does not need the MLX weights or tokenizer. The learner selects the served model ID. Exact installed models and server state on this Mac are unverified. [MLX engine](https://lmstudio.ai/blog/unified-mlx-engine), [local API](https://lmstudio.ai/docs/developer/openai-compat).

Ollama can route local API requests to cloud models. Loopback does not prove that inference stays on the Mac. Require local models and explain `OLLAMA_NO_CLOUD=1` or `disable_ollama_cloud`. Skillgarden cannot verify arbitrary proxy behavior from a URL alone. Use the label “External local server” instead of an absolute privacy promise. [Ollama FAQ](https://docs.ollama.com/faq).

MLX Swift LM introduces package dependencies and another model execution path. It provides no immediate advantage over the owner's existing server for this milestone. [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm).

Apple provides on-device inference without a per-request charge. Its documented model has a 4,096-token context window. Check runtime availability and the model's context size. Use a new session per answer with bounded history. Test refusals, unsupported languages, and cumulative output updates. Select the on-device model explicitly. New framework support for cloud models must not create an automatic fallback. [Apple announcement](https://www.apple.com/newsroom/2025/06/apple-supercharges-its-tools-and-technologies-for-developers/), [framework](https://developer.apple.com/foundation-models-framework/), [context limits](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window), [updates](https://developer.apple.com/documentation/updates/foundationmodels).

### 4. Architecture and verified code gaps

I read `AGENTS.md`, `README.md`, `docs/local-ai.md`, the v3 research document, and the MVP requirements. The file search found no separate release or review document. The supplied issue list supersedes the older research inventory.

Paths below abbreviate `Sources/SkillgardenCore` as `Core` and `Sources/SkillgardenApp` as `App`.

| Verified code | Existing contract or gap |
|---|---|
| `Core/AI/LlamaClient.swift:57` | Public requests require `LocalAIEndpoint`. No general provider interface exists. |
| `Core/AI/LlamaClient.swift:163` | Requests contain messages and stream only. The owned server supplies the model. |
| `Core/AI/LlamaClient.swift:183` | URL validation permits literal loopback addresses only. It also requires a 64-character session secret. |
| `Core/AI/LlamaClient.swift:197` | Ephemeral transport already rejects redirects and avoids cookies and caches. |
| `Core/AI/AnswerStream.swift:45` | Each update contains the accumulated answer. Cancellation and terminal outcomes already exist. |
| `Core/AI/LectureContext.swift:19` | The default budget is 8,192 tokens, with 1,024 reserved for the answer. |
| `Core/AI/LectureContext.swift:142` | Context requires a published lecture. Resolved-path checks exclude internal assets and escaped paths. |
| `Core/AI/LectureConversation.swift:120` | History selection already excludes old source versions and incomplete answers. |
| `Core/AI/LectureQA.swift:119` | The controller depends on `LlamaClient` and an owned endpoint closure. |
| `Core/Store/CourseStore.swift:608` | Q&A tables preserve history. They have no provider or model fields. |
| `App/AISettingsView.swift:7` | Settings offers the local toggle and GGUF file choice only. |
| `App/LectureQAView.swift:69` | Q&A state and explanatory text assume local inference. |
| `App/SkillgardenApp.swift:189` | App composition injects the owned runtime into Q&A. |

The search covered `Sources` and `Tests` for provider names, `Keychain`, `SecItem`, `FoundationModels`, `MLX`, and `AnswerCitation`. It found no provider adapters or credential store. The current branch has passage IDs but no completed citation implementation. Issue #129 already covers that work. Do not create a duplicate.

Proposed flow:

`LectureQA → safe context + history → consent check → AnswerProvider → transport → accumulated answer → existing store and citation validator`

- Introduce `AnswerProvider` in Core with `ask` and cancellation by request ID.
- Keep `AnswerRequest`, accumulated `AnswerUpdate`, and exactly one terminal event.
- Add typed authentication, quota, refusal, and output-limit failures without raw provider payloads in learner text.
- Preserve the owned runtime's endpoint verification inside its adapter.
- Give external local and remote adapters separate endpoint policies.
- Store profile ID, model ID, protocol, origin, and budget outside secrets.
- Keep every network call in Core. Views call state controllers only.
- Keep `LectureContextBuilder`, local retrieval, and passage IDs outside provider adapters.
- Validate citations against the passages sent for that request after #129 merges.
- Reject unknown IDs, stale revisions, and model-written seek targets.
- Freeze the profile and model for each request. Cancel before a provider change.
- Retain one visible lecture history. Record provider and model per new turn through a store migration.
- Label legacy turns as the bundled local provider with an unknown model.
- Require consent before old eligible messages enter a new remote provider's prompt.

Store API keys and OAuth tokens as non-synchronizing Keychain items. Use profile-specific service and account identifiers. Keep only references in preferences. Handle denied access and replacement errors explicitly. Remove credentials on Disconnect. Never put secrets in manifests, SQLite, logs, URLs, or command arguments. Security is an Apple framework, but its addition needs the documented framework exception. [Keychain services](https://developer.apple.com/documentation/security/keychain-services).

For remote requests, require HTTPS and a fixed approved origin. Reject redirects and embedded URL credentials. Permit HTTP only for literal loopback addresses. Normalize the base path once to avoid `/v1/v1`. Do not reuse the owned server's session secret for external endpoints.

Keep tests offline through injected transports, credential stores, and OAuth callbacks. `Tests/SkillgardenCoreTests/LlamaClientTests.swift:26` already provides a scripted transport. Reuse synthetic lecture fixtures and temporary stores.

Required adapter checks cover split UTF-8, comments, unknown events, empty responses, error events, abrupt EOF, cancellation, and late events. Add tests for 401, 403, 429, output limits, redacted errors, and rejected redirects. Test that internal sentinel text never enters a request. Test provider changes, consent revocation, migration, and citation identity. CI must never require a key, model download, or vendor connection.

Live synthetic smoke checks remain necessary before release. Stub tests cannot prove provider access, quality, remote cancellation, or model compatibility. Keep #130's offline acceptance work separate from these adapter checks.

### 5. Product rules

Proposed replacement policy, subject to owner approval:

> Courses, progress, and Q&A history stay on the Mac. Local AI is the default. Remote Q&A requires explicit consent and the learner's provider credentials.

The remote notice must name the provider, destination host, and model. It must identify selected transcript or article passages, course and lecture titles, the question, and eligible prior messages. Offer a preview of the exact text. Explain that provider charges and data policies apply.

Confirm consent for each course and destination. Invalidate consent when the destination changes. Keep “Local”, “External local server”, “API”, and “Subscription” distinct in the selector. Subscription inference is remote even when a CLI runs locally.

Do not send videos, audio, downloads, internal assets, unpublished lectures, or unrelated history. Preserve the existing publication and path checks. Do not let remote tools read local files. Do not perform remote embeddings or token-count requests before consent.

A learner can paste private text into a question. Path controls cannot detect every secret in free text. The notice must cover the question and history too. The enforceable guarantee concerns app-selected internal material, not arbitrary learner input.

Use a synthetic message for an explicit connection test. Do not probe remote providers at launch. Do not retry partial requests automatically. Do not switch to a paid or remote model after failure. Cancellation stops the local request but cannot recall text already sent.

OpenRouter can choose upstream providers and fall back by default. Set an explicit upstream allowlist, disable fallback, and require a suitable data policy. Show that OpenRouter and the selected upstream receive the request. A privacy filter is not a universal retention guarantee. [Provider controls](https://github.com/OpenRouterTeam/docs/blob/main/guides/routing/provider-selection.mdx).

### 6. Prior art

These are documented behaviors, not results from desktop tests. The product lessons are recommendations.

| App | Verified behavior | Lesson for Skillgarden |
|---|---|---|
| Raycast | Separate API-key, custom-provider, and subscription paths. Subscription models carry distinct labels. | Show the source and payment mode beside the model. |
| BoltAI | Setup asks for a provider and that provider's API key. | Use provider-specific setup fields. Avoid a single ambiguous token field. |
| Msty | Original app setup separates local AI, remote providers, and existing Ollama models. | Offer separate local and remote setup choices. Current Studio details remain unverified. |
| Jan | Custom endpoints support compatible APIs and explicit provider configuration. | Expose a base URL and manual model ID for advanced users. |
| Obsidian Copilot | Provider setup validates required fields and offers key removal through its Keychain integration. | Disable Save until setup is valid. Provide Disconnect. |
| Zed | Provider access runs locally. Saved keys use the system Keychain. | Keep credentials on the Mac and transport in the local app. |

Sources: [Raycast keys](https://manual.raycast.com/ai/bring-your-own-key), [Raycast subscriptions](https://manual.raycast.com/ai/bring-your-own-subscription), [BoltAI setup](https://docs.boltai.com/docs/start/setup), [Msty setup](https://docs.msty.app/getting-started/onboarding), [Jan endpoints](https://docs.jan.ai/desktop/remote-models/custom-endpoint), [Copilot settings](https://docs.obsidiancopilot.com/settings/), [Zed API access](https://zed.dev/docs/ai/use-api-access).

Raycast documents Claude Code and Codex subprocesses with user-managed sign-in. It also avoids automatic credit fallback after subscription limits. This is useful product evidence. It does not establish that Skillgarden has the same vendor permissions. [Raycast subscriptions](https://manual.raycast.com/ai/bring-your-own-subscription).

## Recommended issues

These eight proposals are single-PR units in priority order. S means a narrow change. M means one subsystem. L means a larger subsystem with security review.

Existing work is excluded: #111 import, #122 model selection, #123 runtime lifecycle, #128 Q&A UI, #129 citations, and #130 offline acceptance. Use their final contracts. Do not recreate them.

### 1. Separate Q&A from the local runtime — P1, M

- Problem: Q&A cannot use another provider without changes to its controller.
- Behavior: add `AnswerProvider` and wrap `LlamaClient`. Preserve cancellation, history, and passage identity. Add provider/model provenance with a backward-compatible migration.
- Boundary: only the bundled provider remains selectable.
- Likely files: `Core/AI/AnswerProvider.swift` (new), `LectureQA.swift`, `LectureConversation.swift`, `LibraryModel.swift`, `Store/CourseStore.swift`, `App/SkillgardenApp.swift`.
- Dependencies: final #128 and #129 contracts.
- Check: old stores load. Cancellation and citation tests pass through the adapter.

### 2. Add provider profiles, Keychain storage, and consent — P1, M

- Problem: learners need a safe destination and credential choice.
- Behavior: add provider-aware Settings and Q&A state. Store secrets in Keychain. Add destination consent and exact prompt preview.
- Boundary: profiles cannot send until their adapter exists. Keep the bundled provider as default.
- Likely files: new `Core/AI/ProviderConfiguration.swift`, `ProviderCredentials.swift`, `RemoteConsent.swift`, `App/AISettingsView.swift`, `LectureQAView.swift`, `AGENTS.md`, `docs/local-ai.md`.
- Dependencies: proposal 1 and owner approval for remote access and Security.
- Check: no remote request occurs without consent. Secrets never enter persisted profiles or diagnostic text.

### 3. Connect LM Studio and Ollama local servers — P1, M

- Problem: the owner cannot use existing MLX models in Q&A.
- Behavior: add the Chat Completions adapter, local presets, optional token, model ID, and an explicit connection test.
- Boundary: literal loopback only. No install, model download, process ownership, or cloud models.
- Likely files: new `Core/AI/CompatibleProvider.swift`, `CompatibleStream.swift`, `ProviderConfiguration.swift`, `App/AISettingsView.swift`, adapter tests.
- Dependencies: proposals 1–2.
- Check: LM Studio and Ollama fixtures preserve citations and cancellation. Document the external-server privacy limit.

### 4. Connect the OpenAI Responses API — P1, M

- Problem: learners with API access cannot use OpenAI models for lecture questions.
- Behavior: add direct HTTPS requests, a Responses event decoder, model ID, output limit, and provider errors.
- Boundary: API key only. No tools or remote conversation store.
- Likely files: new `Core/AI/OpenAIProvider.swift`, `ResponsesStream.swift`, provider configuration, Settings, adapter tests.
- Dependencies: proposals 1–2 and remote policy approval.
- Check: completed, incomplete, failed, refused, and cancelled responses map to distinct outcomes.

### 5. Connect the Anthropic Messages API — P1, M

- Problem: learners need Claude without prohibited subscription credential reuse.
- Behavior: add native Messages requests, text-block events, required headers, and output limits.
- Boundary: single-workspace API keys first. No Claude.ai login or Claude Code wrapper.
- Likely files: new `Core/AI/AnthropicProvider.swift`, `AnthropicStream.swift`, provider configuration, Settings, adapter tests.
- Dependencies: proposals 1–2 and remote policy approval.
- Check: ping, text, error, refusal, and terminal events preserve the common Q&A contract.

### 6. Connect OpenRouter and compatible HTTPS endpoints — P2, M

- Problem: learners need a gateway or another compatible provider.
- Behavior: extend the compatible adapter with HTTPS profiles. Add an OpenRouter preset with explicit upstream and privacy controls.
- Boundary: text Chat Completions only. No automatic provider fallback or model downloads.
- Likely files: `Core/AI/CompatibleProvider.swift`, `ProviderConfiguration.swift`, new endpoint-policy tests, `App/AISettingsView.swift`.
- Dependencies: proposals 2–3 and remote policy approval.
- Check: keys stay bound to the approved origin. Upstream changes invalidate consent.

### 7. Authorize a ChatGPT subscription — P2, L

- Problem: eligible subscribers need an official account connection without an API key.
- Behavior: implement one-account PKCE registration, callback validation, token refresh, Keychain storage, and Disconnect.
- Boundary: authentication only. Keep the provider unavailable for Q&A until proposal 8.
- Likely files: new `Core/AI/ChatGPTAuthorization.swift`, `ChatGPTSession.swift`, `ProviderCredentials.swift`, `App/AISettingsView.swift`, auth tests.
- Dependencies: proposal 2, confirmed SIWC eligibility, required Apple frameworks, and owner acceptance of SIWC terms.
- Check: reject wrong state, nonce, issuer, audience, scopes, expired tokens, and callback replay through offline fixtures.

### 8. Answer through the authorized ChatGPT plan — P2, M

- Problem: a connected subscription still cannot answer lecture questions.
- Behavior: add account-specific model selection and the SIWC request profile to the Responses adapter.
- Boundary: explicit history, no tools, no unsupported output-limit field, and no automatic API-key fallback.
- Likely files: `Core/AI/OpenAIProvider.swift`, new `ChatGPTProvider.swift`, provider configuration, Settings, Q&A view, adapter tests.
- Dependencies: proposals 4 and 7.
- Check: quota and revoked-access states remain actionable. Cancel and citation identity match the API-key path.

Defer native MLX, Apple models, Gemini presets, and Claude/Gemini subscription wrappers. Their reasons appear in Findings. No proposed issue duplicates #130's local acceptance procedure.

## Sources

All web sources were checked through built-in web tools on 2026-10-19. No browser, GUI automation, account login, or live inference was used.

| Source group | URLs |
|---|---|
| OpenAI API | [Responses](https://developers.openai.com/api/reference/python/resources/responses/methods/create), [Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create) |
| OpenAI subscription eligibility | [Quickstart](https://developers.openai.com/siwc/quickstart), [local-app overview](https://developers.openai.com/siwc/token-sharing-open-source) |
| OpenAI subscription contract | [Sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [limits](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations), [app-server](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server) |
| OpenAI terms | [SIWC terms](https://openai.com/policies/sign-in-with-chatgpt-terms/) |
| Anthropic API | [Headers](https://platform.claude.com/docs/en/api/overview), [Messages](https://platform.claude.com/docs/en/api/messages/create), [SSE](https://platform.claude.com/docs/en/build-with-claude/streaming) |
| Anthropic subscription rules | [Claude Code rules](https://code.claude.com/docs/en/legal-and-compliance), [account guidance](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account), [consumer terms](https://www.anthropic.com/legal/consumer-terms), [headless mode](https://code.claude.com/docs/en/headless) |
| Gemini API | [Native](https://ai.google.dev/api/generate-content), [compatible](https://ai.google.dev/gemini-api/docs/openai), [terms](https://ai.google.dev/gemini-api/terms) |
| Gemini subscription rules | [CLI terms](https://geminicli.com/docs/resources/tos-privacy/), [FAQ](https://geminicli.com/docs/faq/), [headless mode](https://geminicli.com/docs/cli/headless/) |
| OpenRouter | [Authentication](https://openrouter.ai/docs/api/reference/authentication), [SSE](https://openrouter.ai/docs/api/reference/streaming), [upstream controls](https://github.com/OpenRouterTeam/docs/blob/main/guides/routing/provider-selection.mdx) |
| Local servers | [LM Studio API](https://lmstudio.ai/docs/developer/openai-compat), [authentication](https://lmstudio.ai/docs/developer/core/authentication), [MLX](https://lmstudio.ai/blog/unified-mlx-engine), [Ollama API](https://docs.ollama.com/api/openai-compatibility), [FAQ](https://docs.ollama.com/faq) |
| Apple and MLX | [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm), [Foundation Models](https://developer.apple.com/foundation-models-framework/), [context](https://developer.apple.com/documentation/foundationmodels/managing-the-context-window), [updates](https://developer.apple.com/documentation/updates/foundationmodels), [cost announcement](https://www.apple.com/newsroom/2025/06/apple-supercharges-its-tools-and-technologies-for-developers/), [Keychain](https://developer.apple.com/documentation/security/keychain-services) |
| Prior art | [Raycast keys](https://manual.raycast.com/ai/bring-your-own-key), [subscriptions](https://manual.raycast.com/ai/bring-your-own-subscription), [BoltAI](https://docs.boltai.com/docs/start/setup), [Msty](https://docs.msty.app/getting-started/onboarding), [Jan](https://docs.jan.ai/desktop/remote-models/custom-endpoint), [Copilot](https://docs.obsidiancopilot.com/settings/), [Zed](https://zed.dev/docs/ai/use-api-access) |

Unverified items: live GitHub state, installed provider versions, installed MLX model compatibility, Skillgarden's SIWC eligibility, and vendor approval for subscription Q&A wrappers. Model quality, performance, and actual provider charges were not measured. Source claims describe documented behavior, not a completed integration test.
