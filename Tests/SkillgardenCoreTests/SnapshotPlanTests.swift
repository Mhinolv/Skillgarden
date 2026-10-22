import Foundation
import Testing
@testable import SkillgardenCore

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixture = repo.appending(path: "Tests/Fixtures/sample-course")

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SnapshotTests-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func snapshotOutputsAreDeterministicForAnOutDirectory() throws {
    let out = URL(fileURLWithPath: "/tmp/snapshots")
    let outputs = SnapshotPlan.outputs(outDirectory: out)
    #expect(outputs.map(\.url.lastPathComponent) == [
        "library-empty-light.png", "library-empty-dark.png",
        "library-empty-custom-folder-light.png", "library-empty-custom-folder-dark.png", "library-light.png", "library-dark.png",
        "section-light.png", "section-dark.png",
        "lecture-light.png", "lecture-dark.png",
        "lecture-light-high-contrast.png", "lecture-dark-high-contrast.png",
        "lecture-complete-light.png", "lecture-complete-dark.png",
        "article-light.png", "article-dark.png",
        "course-landing-light.png", "course-landing-dark.png",
        "course-landing-dark-theme-light.png", "course-landing-dark-theme-dark.png",
        "course-landing-details-light.png", "course-landing-details-dark.png",
        "quiz-question-light.png", "quiz-question-dark.png",
        "quiz-wrong-answer-light.png", "quiz-wrong-answer-dark.png",
        "quiz-wrong-answer-light-high-contrast.png", "quiz-wrong-answer-dark-high-contrast.png",
        "quiz-results-light.png", "quiz-results-dark.png",
        "interactive-result-light.png", "interactive-result-dark.png",
        "video-player-light.png", "video-player-dark.png",
        "video-transcript-light.png", "video-transcript-dark.png",
        "video-quick-check-light.png", "video-quick-check-dark.png",
        "video-theater-light.png", "video-theater-dark.png",
        "section-review-light.png", "section-review-dark.png",
        "course-credits-light.png", "course-credits-dark.png",
        "assignment-light.png", "assignment-dark.png",
        "assignment-complete-light.png", "assignment-complete-dark.png",
        "lecture-downloads-light.png", "lecture-downloads-dark.png",
        "pdf-preview-light.png", "pdf-preview-dark.png",
        "transcript-search-light.png", "transcript-search-dark.png",
        "transcript-search-selected-light.png", "transcript-search-selected-dark.png",
        "transcript-search-no-results-light.png", "transcript-search-no-results-dark.png",
        "lecture-sources-light.png", "lecture-sources-dark.png",
        "video-up-next-light.png", "video-up-next-dark.png",
        "video-up-next-theater-light.png", "video-up-next-theater-dark.png",
        "outline-durations-light.png", "outline-durations-dark.png",
        "settings-light.png", "settings-dark.png",
        "settings-model-missing-light.png", "settings-model-missing-dark.png",
        "settings-ai-off-light.png", "settings-ai-off-dark.png",
        "settings-ai-error-light.png", "settings-ai-error-dark.png",
        "settings-providers-light.png", "settings-providers-dark.png",
        "provider-sheet-lm-studio-light.png", "provider-sheet-lm-studio-dark.png",
        "provider-sheet-ollama-error-light.png", "provider-sheet-ollama-error-dark.png",
        "provider-sheet-openai-light.png", "provider-sheet-openai-dark.png",
        "provider-sheet-openai-edit-light.png", "provider-sheet-openai-edit-dark.png",
        "provider-sheet-anthropic-light.png", "provider-sheet-anthropic-dark.png",
        "provider-sheet-anthropic-edit-light.png", "provider-sheet-anthropic-edit-dark.png",
        "provider-sheet-openrouter-light.png", "provider-sheet-openrouter-dark.png",
        "provider-sheet-custom-light.png", "provider-sheet-custom-dark.png",
        "chatgpt-sheet-signed-out-light.png", "chatgpt-sheet-signed-out-dark.png",
        "chatgpt-sheet-waiting-light.png", "chatgpt-sheet-waiting-dark.png",
        "chatgpt-sheet-signed-in-light.png", "chatgpt-sheet-signed-in-dark.png",
        "chatgpt-sheet-failed-light.png", "chatgpt-sheet-failed-dark.png",
        "chatgpt-sheet-models-loading-light.png", "chatgpt-sheet-models-loading-dark.png",
        "chatgpt-sheet-models-empty-light.png", "chatgpt-sheet-models-empty-dark.png",
        "chatgpt-sheet-models-failed-light.png", "chatgpt-sheet-models-failed-dark.png",
        "chatgpt-sheet-model-gone-light.png", "chatgpt-sheet-model-gone-dark.png",
        "settings-chatgpt-sign-in-again-light.png", "settings-chatgpt-sign-in-again-dark.png",
        "settings-chatgpt-choose-model-light.png", "settings-chatgpt-choose-model-dark.png",
        "qa-thread-light.png", "qa-thread-dark.png",
        "qa-thread-light-high-contrast.png", "qa-thread-dark-high-contrast.png",
        "qa-empty-light.png", "qa-empty-dark.png",
        "qa-draft-light.png", "qa-draft-dark.png",
        "qa-no-model-light.png", "qa-no-model-dark.png",
        "qa-off-light.png", "qa-off-dark.png",
        "qa-starting-light.png", "qa-starting-dark.png",
        "qa-stopping-light.png", "qa-stopping-dark.png",
        "qa-error-light.png", "qa-error-dark.png",
        "qa-no-captions-light.png", "qa-no-captions-dark.png",
        "qa-article-light.png", "qa-article-dark.png",
        "qa-theater-light.png", "qa-theater-dark.png",
        "qa-citations-light.png", "qa-citations-dark.png",
        "qa-citation-excerpt-light.png", "qa-citation-excerpt-dark.png",
        "qa-citations-stale-light.png", "qa-citations-stale-dark.png",
        "qa-off-history-light.png", "qa-off-history-dark.png",
        "qa-error-history-light.png", "qa-error-history-dark.png",
        "qa-starting-history-light.png", "qa-starting-history-dark.png",
        "qa-consent-light.png", "qa-consent-dark.png",
        "qa-consent-openrouter-light.png", "qa-consent-openrouter-dark.png",
        "qa-remote-light.png", "qa-remote-dark.png",
        "qa-external-local-light.png", "qa-external-local-dark.png",
        "qa-incomplete-light.png", "qa-incomplete-dark.png",
        "qa-auth-error-light.png", "qa-auth-error-dark.png",
        "qa-anthropic-light.png", "qa-anthropic-dark.png",
        "notes-video-light.png", "notes-video-dark.png",
        "notes-article-empty-light.png", "notes-article-empty-dark.png",
        "notes-page-light.png", "notes-page-dark.png",
        "notes-page-empty-light.png", "notes-page-empty-dark.png",
        "qa-citation-ranges-light.png", "qa-citation-ranges-dark.png",
        "qa-guard-empty-light.png", "qa-guard-empty-dark.png",
        "qa-save-failed-light.png", "qa-save-failed-dark.png",
        "qa-remove-failed-light.png", "qa-remove-failed-dark.png",
        "progress-save-failed-completion-light.png", "progress-save-failed-completion-dark.png",
        "progress-save-failed-quiz-light.png", "progress-save-failed-quiz-dark.png",
        "article-image-enlarged-light.png", "article-image-enlarged-dark.png",
        "article-image-enlarged-no-alt-light.png", "article-image-enlarged-no-alt-dark.png",
    ])
    // #182 retired the `-unthemed-dark` captures: each screen has one light and one dark default capture.
    #expect(!outputs.contains { $0.url.lastPathComponent.contains("unthemed") })
    #expect(outputs.filter { !$0.increasedContrast }.map(\.url.lastPathComponent) == SnapshotScreen.allCases.flatMap { screen in
        SnapshotAppearance.allCases.map { "\(screen.rawValue)-\($0.rawValue).png" }
    })
    #expect(SnapshotScreen.allCases.filter { $0.transcriptQuery != nil }
        == [.transcriptSearch, .transcriptSearchSelected, .transcriptSearchNoResults])
    #expect(SnapshotScreen.allCases.filter(\.selectsFirstTranscriptHit) == [.transcriptSearchSelected])
    #expect(SnapshotScreen.allCases.filter(\.showsReviewInline) == [.sectionReview])
    #expect(SnapshotScreen.allCases.filter(\.showsPDFPreviewInline) == [.pdfPreview])
    #expect(SnapshotScreen.allCases.filter(\.showsLandingDetails) == [.courseLandingDetails])
    #expect(SnapshotScreen.allCases.filter(\.opensVideoPlayer) == [.videoPlayer, .videoTranscript, .videoQuickCheck, .videoTheater,
                                                                   .videoUpNext, .videoUpNextTheater])
    #expect(SnapshotScreen.allCases.filter(\.showsUpNext) == [.videoUpNext, .videoUpNextTheater])
    #expect(SnapshotScreen.allCases.filter { $0.videoStartSeconds != nil } == [.videoTranscript])
    #expect(SnapshotScreen.allCases.filter(\.scrollsLectureToEnd) == [
        .courseLandingDetails, .videoTranscript, .videoQuickCheck, .videoTheater, .lectureDownloads, .pdfPreview, .lectureSources,
        .qaThread, .qaEmpty, .qaDraft, .qaNoModel, .qaOff, .qaStarting, .qaStopping, .qaError, .qaNoCaptions, .qaTheater,
        .qaCitations, .qaCitationsStale, .qaOffHistory, .qaErrorHistory, .qaStartingHistory, .qaConsent, .qaConsentOpenRouter,
        .qaRemote, .qaExternalLocal, .qaIncomplete, .qaAuthError, .qaAnthropic, .notesVideo, .qaCitationRanges, .qaGuardEmpty,
        .qaSaveFailed, .qaRemoveFailed,
    ])
    // #181: two screens open the Notes panel. Only the video screen opens a note in edit.
    #expect(SnapshotScreen.allCases.filter(\.showsNotes) == [.notesVideo, .notesArticleEmpty])
    #expect(SnapshotScreen.allCases.filter(\.editsNote) == [.notesVideo])
    // #238: two screens open the large image view, with and without alt text.
    #expect(SnapshotScreen.allCases.filter { $0.enlargedImage != nil } == [.articleImageEnlarged, .articleImageEnlargedNoAlt])
    #expect(SnapshotScreen.articleImageEnlarged.enlargedImage == .withAlt)
    #expect(SnapshotScreen.articleImageEnlargedNoAlt.enlargedImage == .withoutAlt)
    // #128: the Q&A screens open the panel with an injected status. Only the draft screen shows a draft.
    #expect(SnapshotScreen.allCases.filter(\.showsQA) == [.qaThread, .qaEmpty, .qaDraft, .qaNoModel, .qaOff, .qaStarting,
                                                          .qaStopping, .qaError, .qaNoCaptions, .qaArticle, .qaTheater,
                                                          .qaCitations, .qaCitationExcerpt, .qaCitationsStale,
                                                          .qaOffHistory, .qaErrorHistory, .qaStartingHistory, .qaConsent,
                                                          .qaConsentOpenRouter, .qaRemote,
                                                          .qaExternalLocal, .qaIncomplete, .qaAuthError, .qaAnthropic,
                                                          .qaCitationRanges, .qaGuardEmpty, .qaSaveFailed, .qaRemoveFailed])
    #expect(SnapshotScreen.allCases.filter { $0.qaStatus != nil } == SnapshotScreen.allCases.filter(\.showsQA))
    #expect(SnapshotScreen.allCases.compactMap(\.qaStatus).map { LectureQAState(status: $0, content: .ready) }
        == [.ready, .ready, .ready, .noModel, .off, .starting, .stopping, .error(reason: "The server stopped. Exit code 9."),
            .ready, .ready, .ready, .ready, .ready, .ready, .off, .error(reason: "The server stopped. Exit code 9."), .starting,
            .ready, .ready, .ready, .ready, .ready, .ready, .ready, .ready, .ready, .ready, .ready])
    // #151: the screens that use the fixture profiles. Only the consent screens send a question (#155: OpenRouter).
    #expect(SnapshotScreen.allCases.filter(\.usesProviderProfiles) == [.settingsProviders, .qaConsent, .qaConsentOpenRouter,
                                                                       .qaRemote, .qaExternalLocal,
                                                                       .qaIncomplete, .qaAuthError, .qaAnthropic,
                                                                       .qaCitationRanges])
    #expect(SnapshotScreen.allCases.compactMap(\.selectedProviderID)
        == ["snapshot-openai", "snapshot-openai", "snapshot-openrouter", "snapshot-openai", "snapshot-lm-studio", "snapshot-openai",
            "snapshot-openai", "snapshot-anthropic", "snapshot-anthropic"])
    #expect(SnapshotScreen.allCases.filter { $0.qaConsentQuestion != nil } == [.qaConsent, .qaConsentOpenRouter])
    #expect(SnapshotPlan.providerProfiles.map(\.kind) == [.api, .externalLocal, .api, .api])
    #expect(SnapshotPlan.providerProfiles[3].endpoint == .openRouter)
    #expect(SnapshotPlan.providerProfiles[3].routing?.upstreams == ["openai"])
    #expect(SnapshotPlan.providerProfiles.allSatisfy { $0.isValid(hasSecret: true) })
    #expect(SnapshotScreen.allCases.filter { SnapshotPlan.qaOrigin(for: $0).providerID != BundledAnswerProvider.providerID }
        == [.qaRemote, .qaExternalLocal, .qaIncomplete, .qaAuthError, .qaAnthropic, .qaCitationRanges])
    // #152: the LM Studio sheet passed its test. The Ollama sheet has the loopback error, so "Save" is off.
    #expect(SnapshotScreen.allCases.filter { $0.providerSheet != nil } == [.providerSheetLMStudio, .providerSheetOllamaError,
                                                                           .providerSheetOpenAI, .providerSheetOpenAIEdit,
                                                                           .providerSheetAnthropic, .providerSheetAnthropicEdit,
                                                                           .providerSheetOpenRouter, .providerSheetCustom])
    // #155: the new OpenRouter sheet has its defaults. The custom sheet shows the normalized request URL.
    let openRouterSheet = try #require(SnapshotScreen.providerSheetOpenRouter.providerSheet)
    #expect(openRouterSheet.profile.routing == OpenRouterRouting())
    #expect(openRouterSheet.profile.host == "openrouter.ai")
    #expect(!openRouterSheet.profile.isValid(hasSecret: false))
    let customSheet = try #require(SnapshotScreen.providerSheetCustom.providerSheet)
    #expect(customSheet.profile.requestURLCaption == "Requests go to https://example.com/v1/chat/completions")
    #expect(customSheet.profile.isValid(hasSecret: false))
    // #154: the new Anthropic sheet passed its test. The edit sheet has a saved key, so it shows "Replace Key…".
    let anthropicSheet = try #require(SnapshotScreen.providerSheetAnthropic.providerSheet)
    #expect(anthropicSheet.testResult == .connected)
    #expect(anthropicSheet.profile.apiService == .anthropic && anthropicSheet.profile.credentialReference == nil)
    #expect(anthropicSheet.profile.isValid(hasSecret: true))
    let anthropicEdit = try #require(SnapshotScreen.providerSheetAnthropicEdit.providerSheet)
    #expect(anthropicEdit.profile.apiService == .anthropic && anthropicEdit.profile.credentialReference != nil)
    #expect(anthropicEdit.profile.isValid(hasSecret: true))
    let lmStudio = try #require(SnapshotScreen.providerSheetLMStudio.providerSheet)
    #expect(lmStudio.testResult == .connected)
    #expect(lmStudio.profile.isValid(hasSecret: false))
    #expect(lmStudio.profile.externalServer == .lmStudio)
    let ollama = try #require(SnapshotScreen.providerSheetOllamaError.providerSheet)
    #expect(ollama.profile.originProblem == "Use 127.0.0.1 or [::1]. Use an API provider for other hosts.")
    #expect(!ollama.profile.isValid(hasSecret: false))
    #expect(ollama.profile.externalServer == .ollama)
    // #153: the new OpenAI sheet has a typed key and passed its test. The edit sheet has a saved key.
    let openAI = try #require(SnapshotScreen.providerSheetOpenAI.providerSheet)
    #expect(openAI.testResult == .connected && !openAI.secret.isEmpty)
    #expect(openAI.profile.apiService == .openAI && openAI.profile.credentialReference == nil)
    #expect(openAI.profile.isValid(hasSecret: true) && !openAI.profile.isValid(hasSecret: false))
    let openAIEdit = try #require(SnapshotScreen.providerSheetOpenAIEdit.providerSheet)
    #expect(openAIEdit.profile.apiService == .openAI && openAIEdit.profile.credentialReference != nil)
    #expect(openAIEdit.testResult == nil && openAIEdit.secret.isEmpty)
    #expect(SnapshotPlan.providerProfiles[1].title == "LM Studio · qwen3-8b-mlx")
    // #129: only the excerpt screen opens an excerpt. Only the stale screen saves turns of an earlier revision.
    #expect(SnapshotScreen.allCases.filter(\.opensCitationExcerpt) == [.qaCitationExcerpt])
    #expect(SnapshotScreen.allCases.filter(SnapshotPlan.qaTurnsAreStale) == [.qaCitationsStale])
    #expect(SnapshotScreen.allCases.filter { $0.qaDraft != nil } == [.qaDraft, .qaExternalLocal, .qaSaveFailed])
    // #209: one screen shows a draft that the store did not save, one a turn that the store did not remove.
    #expect(SnapshotScreen.allCases.filter(\.qaDraftSaveFailed) == [.qaSaveFailed])
    #expect(SnapshotScreen.allCases.filter(\.qaRemoveFailed) == [.qaRemoveFailed])
    // #210: the save-failure strip on a lecture with a refused completion and on quiz results with a refused result.
    #expect(SnapshotScreen.allCases.filter { !$0.progressSaveFailures.isEmpty } == [.progressSaveFailedCompletion, .progressSaveFailedQuiz])
    #expect(SnapshotScreen.progressSaveFailedCompletion.progressSaveFailures == [.completion])
    #expect(SnapshotScreen.progressSaveFailedQuiz.progressSaveFailures == [.quizResult])
    #expect(SnapshotPlan.quizActions(for: .progressSaveFailedQuiz) == SnapshotPlan.quizActions(for: .quizResults))
    #expect(SnapshotScreen.allCases.filter(\.startsTheater) == [.videoTheater, .videoUpNextTheater, .qaTheater])
    #expect(SnapshotScreen.allCases.filter(\.showsQuickChecks) == [.videoQuickCheck])
    #expect(SnapshotScreen.allCases.filter(\.checksTitlebarForVideo) == [.videoPlayer, .videoTranscript, .videoQuickCheck, .videoTheater,
                                                                         .videoUpNext, .videoUpNextTheater])
    #expect(SnapshotPlan.outputs(outDirectory: out, screens: [.videoTranscript, .library]).map(\.url.lastPathComponent) == [
        "library-light.png", "library-dark.png",
        "video-transcript-light.png", "video-transcript-dark.png",
    ])
    #expect(SnapshotPlan.outputs(outDirectory: out, screens: []).isEmpty)
    #expect(SnapshotPlan.outputs(outDirectory: out, screens: nil) == outputs)
    #expect(SnapshotScreen.allCases.filter { !$0.selectsCourse } == [.libraryEmpty, .libraryEmptyCustomFolder, .library, .settings,
                                                                    .settingsModelMissing, .settingsAIOff, .settingsAIError,
                                                                    .settingsProviders, .providerSheetLMStudio,
                                                                    .providerSheetOllamaError, .providerSheetOpenAI,
                                                                    .providerSheetOpenAIEdit, .providerSheetAnthropic,
                                                                    .providerSheetAnthropicEdit, .providerSheetOpenRouter,
                                                                    .providerSheetCustom, .chatGPTSheetSignedOut,
                                                                    .chatGPTSheetWaiting, .chatGPTSheetSignedIn, .chatGPTSheetFailed,
                                                                    .chatGPTSheetModelsLoading, .chatGPTSheetModelsEmpty, .chatGPTSheetModelsFailed, .chatGPTSheetModelGone,
                                                                    .settingsChatGPTSignInAgain, .settingsChatGPTChooseModel])
    // #156: four ChatGPT plan sheet states, and one Settings screen with a session that can't refresh.
    let signedIn = ChatGPTSignIn.State.signedIn(SnapshotPlan.chatGPTAccount)
    #expect(SnapshotScreen.allCases.compactMap(\.chatGPTSheetState)
        == [.signedOut, .waiting, signedIn, .failed(ChatGPTAuthError.unverifiedText), signedIn, signedIn, signedIn, signedIn])
    // #157: the model picker states of the Signed in sheet. The harness injects them and fetches nothing.
    let models = SnapshotPlan.chatGPTModels
    #expect(SnapshotScreen.allCases.compactMap(\.chatGPTSheetModels).map(\.models)
        == [.loaded(models), .loading, .loaded([]), .failed("ChatGPT sent an error (503)."), .loaded(models)])
    #expect(SnapshotScreen.chatGPTSheetModelGone.chatGPTSheetModels?.modelID == "gpt-4.1")
    #expect(SnapshotScreen.chatGPTSheetSignedIn.chatGPTSheetModels?.modelID == "gpt-5")
    #expect(SnapshotScreen.allCases.filter(\.usesChatGPTPlanProfile) == [.settingsChatGPTSignInAgain, .settingsChatGPTChooseModel])
    // #232: Choose Model gets a session that can refresh. The other screens get no ChatGPT secrets.
    #expect(SnapshotScreen.settingsChatGPTSignInAgain.chatGPTSecrets == SnapshotPlan.chatGPTSecrets)
    #expect(SnapshotScreen.settingsChatGPTChooseModel.chatGPTSecrets == SnapshotPlan.chatGPTRefreshableSecrets)
    #expect(SnapshotScreen.allCases.filter { !$0.chatGPTSecrets.isEmpty } == [.settingsChatGPTSignInAgain, .settingsChatGPTChooseModel])
    let fixture = try #require(SnapshotPlan.chatGPTRefreshableSecrets.values.first.flatMap(ChatGPTSession.init(keychainText:)))
    #expect(!fixture.needsRefresh(at: Date()) && fixture.canRefresh(at: Date()))
    #expect(SnapshotScreen.settingsChatGPTSignInAgain.isSettings && SnapshotScreen.chatGPTSheetFailed.isSettings)
    #expect(SnapshotScreen.allCases.filter { $0.customRootPath != nil } == [.libraryEmptyCustomFolder])
    #expect(outputs.allSatisfy { $0.url.deletingLastPathComponent().path == out.path })
    #expect(outputs == SnapshotPlan.outputs(outDirectory: out))
    let defaultCount = SnapshotScreen.allCases.count * SnapshotAppearance.allCases.count
    let contrastCount = SnapshotPlan.increasedContrastScreens.count * SnapshotAppearance.allCases.count
    #expect(Set(outputs.map(\.url)).count == defaultCount + contrastCount)
    // #219: only the high-contrast captures use the "Increase contrast" palette.
    let contrastOutputs = outputs.filter { (output: SnapshotPlan.Output) in output.increasedContrast }
    #expect(contrastOutputs.count == contrastCount)
    #expect(contrastOutputs.allSatisfy { $0.url.lastPathComponent.hasSuffix("-high-contrast.png") })
    #expect(SnapshotPlan.width == 1280 && SnapshotPlan.height == 800 && SnapshotPlan.scale == 2)
}

@MainActor @Test func snapshotSeedsEachScreenFromTheFixture() async throws {
    for screen in SnapshotScreen.allCases {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let courseID = try SnapshotPlan.seedStore(for: screen, root: root, fixture: fixture)
        let library = LibraryModel(root: root)
        await library.reload()
        #expect(library.errorMessage == nil)
        switch screen {
        case .libraryEmpty, .libraryEmptyCustomFolder, .settings, .settingsModelMissing, .settingsAIOff, .settingsAIError,
             .settingsProviders, .providerSheetLMStudio, .providerSheetOllamaError, .providerSheetOpenAI, .providerSheetOpenAIEdit,
             .providerSheetAnthropic, .providerSheetAnthropicEdit, .providerSheetOpenRouter, .providerSheetCustom,
             .chatGPTSheetSignedOut, .chatGPTSheetWaiting, .chatGPTSheetSignedIn, .chatGPTSheetFailed,
             .chatGPTSheetModelsLoading, .chatGPTSheetModelsEmpty, .chatGPTSheetModelsFailed, .chatGPTSheetModelGone, .settingsChatGPTSignInAgain, .settingsChatGPTChooseModel:
            #expect(courseID == nil)
            #expect(!screen.selectsCourse)
            #expect(SnapshotPlan.imageLoads(for: screen) == 0)
            #expect(library.courses.isEmpty)
        case .library:
            #expect(courseID == "sample-course")
            // The Library home: no selected course, the fixture course is in the "Continue" strip and a second course is new.
            // Three images: the strip and one tile per course.
            #expect(!screen.selectsCourse)
            #expect(SnapshotPlan.imageLoads(for: screen) == 3)
            #expect(library.courses.map(\.id) == ["garden-tools", "sample-course"])
            #expect(library.continueCourse?.id == "sample-course")
            #expect(library.courses.map { library.summary(of: $0).status } == [.new, .inProgress])
            // #182: the manifest accent stays valid and loads. The app does not show it.
            #expect(library.landings["garden-tools"]?.theme.accent == ThemeColor(hex: "#2F6FED"))
            #expect(library.libraryMeta == "2 courses · 1 in progress")
            library.selectCourse(courseID)
            library.selectDestination(nil)
            #expect(library.selectedCourse?.title == "Local Course Basics")
            #expect(library.selectedCourse?.sections.map(\.id) == ["plan"])
            #expect(library.selectedCourse?.sections.first?.lectures.map(\.id) == ["welcome", "read"])
            #expect(library.destination == nil)
            let section = try #require(library.selectedCourse?.learnerSections.first)
            #expect(library.sectionProgress(section).percent == 50)
        case .section:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.destination == .section(sectionID: "plan"))
            #expect(library.selectedSection?.objective == "Identify the course structure")
            #expect(library.headerImage(forSection: "plan")?.alt == "Two course sections")
        case .lecture:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "welcome")
            #expect(library.nextLecture == .lecture(sectionID: "plan", lectureID: "read"))
            #expect(!library.isSelectedLectureComplete)
            // The video lecture shows its poster.
            #expect(library.selectedLecture?.type == .video)
            #expect(library.video(forLecture: "welcome")?.posterAlt == "The first frame of the welcome video")
        case .lectureComplete:
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "welcome")
            #expect(library.isSelectedLectureComplete)
        case .article:
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .article)
            #expect(library.article(forLecture: "read")?.path == "content/plan.md")
        case .progressSaveFailedCompletion, .progressSaveFailedQuiz:
            // #210: the harness shows the strip for the selected lecture. The store keeps no progress for it.
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            for action in SnapshotPlan.quizActions(for: screen) { library.performQuizAction(action) }
            // The harness does not wait for the quiz write. The strip must stay after the queued writes end.
            await library.showSnapshotProgressSaveFailures(screen.progressSaveFailures)
            await library.waitForWrites()
            #expect(library.failedProgressSaves.map(\.lectureID) == [screen == .progressSaveFailedQuiz ? "check" : "read"])
            #expect(library.progressSaveFailureText == ProgressSaveKey.failureText(library.failedProgressSaves))
            #expect(!library.isSelectedLectureComplete)
            #expect((library.selectedQuizAttempt?.showsResults == true) == (screen == .progressSaveFailedQuiz))
        case .articleImageEnlarged, .articleImageEnlargedNoAlt:
            // #238: the article lecture with one image. The harness opens it after the course image and the article image load.
            #expect(courseID == "sample-course")
            #expect(SnapshotPlan.imageLoads(for: screen) == 1)
            #expect(!screen.scrollsLectureToEnd)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "read")
            let article = try #require(library.article(forLecture: "read"))
            let document = try article.load()
            #expect(document.imageSources.count == 1)
            #expect(article.image(for: try #require(document.imageSources.first))?.alt == "The two sections of the course plan")
        case .lectureSources:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "read")
            // Three cards: a full range with a URL, a start only with a URL, and no URL.
            let sources = library.selectedSources
            #expect(sources.map(\.rangeText) == ["4:10 – 9:32", "From 1:02:05", nil])
            #expect(sources.map { $0.url != nil } == [true, true, false])
        case .courseLanding, .courseLandingDarkTheme:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.destination == .overview)
            #expect(library.selectedLanding?.learningOutcomes == ["Plan a course", "Check your work"])
            let theme = try #require(library.selectedLanding?.theme)
            if screen == .courseLanding {
                #expect(theme.appearance == .light)
                #expect(theme.accent == ThemeColor(hex: "#286644"))
                #expect(library.resumeLecture?.title == "Read the plan")
            } else {
                #expect(theme.appearance == .dark)
                #expect(theme.accent == ThemeColor(hex: SnapshotPlan.darkThemeAccent))
                #expect(library.resumeLecture == nil)
            }
        case .courseLandingDetails:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.destination == .overview)
            let landing = try #require(library.selectedLanding)
            #expect(landing.summaryOutcomes == ["Plan a course", "Check your work", "Order the sections"])
            #expect(landing.detailOutcomes.count == 5)
            #expect(landing.requirements == ["A Mac"])
            #expect(landing.hasDetails)
        case .quizQuestion, .quizWrongAnswer, .quizResults:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "check")
            for action in SnapshotPlan.quizActions(for: screen) { library.performQuizAction(action) }
            let attempt = try #require(library.selectedQuizAttempt)
            switch screen {
            case .quizQuestion:
                // The sample quiz renders an image question from the fixture.
                let image = try #require(attempt.question?.image)
                #expect(image.alt == "Two course sections")
                #expect(FileManager.default.fileExists(atPath: image.url.path))
                #expect(attempt.selection == nil)
                #expect(SnapshotPlan.imageLoads(for: screen) == 2)
            case .quizWrongAnswer:
                #expect(attempt.question?.id == "outline")
                #expect(attempt.isAnswerCorrect == false)
            default:
                #expect(attempt.showsResults)
                #expect(attempt.result.weakSkills == ["Read a course outline", "Order course sections"])
                await library.waitForWrites()
            }
        case .videoPlayer, .videoTheater, .videoUpNext, .videoUpNextTheater:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .video)
            // The "Up next" overlay names the article after the welcome video (#99).
            #expect(library.nextLectureTitle == "Read the plan")
            let video = try #require(library.video(forLecture: "welcome"))
            #expect(FileManager.default.fileExists(atPath: video.url.path))
            #expect(video.captionsURL != nil)
        case .videoTranscript:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            let video = try #require(library.video(forLecture: "welcome"))
            // The start time makes the second of the two fixture lines active.
            let transcript = Transcript(captions: try #require(try video.loadCaptions()))
            #expect(transcript.lines.count == 2)
            let start = try #require(screen.videoStartSeconds)
            #expect(transcript.activeLine(at: start) == 1)
            #expect(SnapshotPlan.imageLoads(for: screen) == 1)
        case .videoQuickCheck:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            for item in SnapshotPlan.quickCheckAnswers(for: screen) { library.answerQuickCheck(item.checkID, choiceID: item.choiceID) }
            let session = try #require(library.selectedQuickChecks)
            #expect(session.checks.count == 2)
            #expect(session.isCorrect(0) == nil)
            #expect(session.isCorrect(1) == false)
            #expect(session.checks[1].explanation != nil)
        case .interactiveResult:
            #expect(courseID == "interactive-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .interactive)
            let module = try #require(library.selectedInteractive)
            #expect(module.entryExists())
            #expect(library.selectedInteractiveResult == InteractiveResult(score: 75, weakSkills: ["Order the steps of a course plan"]))
        case .assignment, .assignmentComplete:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .assignment)
            let brief = try #require(library.selectedAssignment?.brief)
            #expect(FileManager.default.fileExists(atPath: brief.url.path))
            #expect(SnapshotPlan.imageLoads(for: screen) == 2)
            for id in SnapshotPlan.rubricChecks(for: screen) { library.toggleRubricCriterion(id) }
            let checklist = try #require(library.selectedRubricChecklist)
            #expect(checklist.rubric.count == 4)
            if screen == .assignment {
                #expect(checklist.summary == "0 of 4 criteria met")
            } else {
                #expect(checklist.allMet)
            }
        case .sectionReview:
            #expect(courseID == "sample-course")
            #expect(SnapshotPlan.imageLoads(for: screen) == 2)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            for item in SnapshotPlan.reviewAnswers(for: screen) { library.answerReview(questionID: item.questionID, choiceID: item.choiceID) }
            // Two questions: the image question is unanswered, the other one is answered correctly.
            let review = try #require(library.sectionReview)
            #expect(Set(review.questions.map(\.id)) == ["check/outline", "check/order"])
            #expect(review.isCorrect("check/order") == true)
            #expect(review.isCorrect("check/outline") == nil)
            #expect(review.questions.first { $0.id == "check/outline" }?.question.image != nil)
        case .courseCredits:
            #expect(courseID == "sample-course")
            #expect(SnapshotPlan.imageLoads(for: screen) == 1)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.destination == .credits)
            // One row with a role and a URL, one row with neither.
            #expect(library.selectedCredits.map(\.name) == ["Skillgarden Team", "Garden Photo Library"])
            #expect(library.selectedCredits.map { $0.role != nil } == [true, false])
            #expect(library.selectedCredits.map { $0.url != nil } == [true, false])
        case .lectureDownloads, .pdfPreview:
            #expect(courseID == "sample-course")
            #expect(SnapshotPlan.imageLoads(for: screen) == 2)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == .article)
            // A PDF with a first page, a CSV, and a text file that the seed removed from the store.
            let downloads = library.downloads(forLecture: "read")
            #expect(downloads.map(\.title) == ["Course plan worksheet", "Section list", "Plan checklist"])
            #expect(downloads.map(\.kind) == [.pdf, .csv, .other("txt")])
            #expect(downloads.map(\.isAvailable) == [true, true, false])
            #expect(PDFPreview.firstPage(of: downloads[0].url, width: 64, height: 83) != nil)
            // The preview sheet opens the first available PDF: the worksheet, with a page count.
            #expect(downloads.first { $0.kind == .pdf && $0.isAvailable }?.title == "Course plan worksheet")
            #expect(PDFPreview.pageCount(of: downloads[0].url).map { $0 > 0 } == true)
            #expect(library.downloads(forLecture: "welcome").isEmpty)
            // The source cards of the fixture lecture stay next to the downloads.
            #expect(library.selectedSources.count == 3)
        case .transcriptSearch, .transcriptSearchSelected, .transcriptSearchNoResults:
            #expect(courseID == "sample-course")
            // The results replace the outline, so only the course page image loads.
            #expect(SnapshotPlan.imageLoads(for: screen) == 1)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            library.transcriptQuery = try #require(screen.transcriptQuery)
            library.searchTranscripts()
            await library.waitForTranscriptCues()
            let results = try #require(library.transcriptResults)
            #expect(results.hasTranscripts)
            if screen != .transcriptSearchNoResults {
                #expect(results.groups.map(\.lectureID) == ["welcome", "recap"])
                #expect(results.summary == "4 results in 2 lectures")
            } else {
                #expect(results.groups.isEmpty)
            }
        case .qaThread, .qaEmpty, .qaDraft, .qaNoModel, .qaOff, .qaStarting, .qaStopping, .qaError, .qaNoCaptions, .qaArticle,
             .qaTheater, .qaCitations, .qaCitationExcerpt, .qaCitationsStale, .qaOffHistory, .qaErrorHistory, .qaStartingHistory,
             .qaConsent, .qaConsentOpenRouter, .qaRemote, .qaExternalLocal, .qaIncomplete, .qaAuthError, .qaAnthropic,
             .qaCitationRanges, .qaGuardEmpty, .qaSaveFailed, .qaRemoveFailed:
            #expect(courseID == "sample-course")
            #expect(SnapshotPlan.imageLoads(for: screen) == 1)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.type == ([.qaArticle, .qaCitationExcerpt].contains(screen) ? .article : .video))
            let lectureID = try #require(library.selectedLecture?.id)
            let context = await library.lectureContext(forLecture: lectureID)
            if screen == .qaNoCaptions {
                #expect(library.video(forLecture: lectureID)?.captionsURL == nil)
                #expect(context == .noText)
            } else {
                guard case .ready = context else { Issue.record("\(screen) has no lecture text"); break }
            }
            try await SnapshotPlan.seedQATurns(for: screen, library: library)
            let conversation = try #require(try await library.lectureConversation(forLecture: lectureID))
            let turns = SnapshotPlan.qaTurnsAreStale(for: screen) ? conversation.earlierTurns : conversation.currentTurns
            #expect(turns.map(\.question) == SnapshotPlan.qaTurns(for: screen).map(\.question))
            switch screen {
            case .qaThread, .qaArticle, .qaTheater:
                #expect(turns.map(\.status) == [.complete, .cancelled, .failed(reason: "Local AI returned an error (500). Try again.")])
                #expect(turns.map(\.answer) == ["You plan a course step by step [t1].", "You need", ""])
            case .qaDraft, .qaCitations, .qaCitationExcerpt, .qaCitationsStale, .qaOffHistory, .qaErrorHistory, .qaStartingHistory,
                 .qaConsent, .qaConsentOpenRouter, .qaRemote, .qaExternalLocal, .qaSaveFailed, .qaRemoveFailed:
                #expect(turns.map(\.status) == [.complete])
                #expect(turns.map(\.origin) == [SnapshotPlan.qaOrigin(for: screen)])
            case .qaIncomplete:
                // #153: the partial answer stays with the output-limit status and Retry.
                #expect(turns.map(\.status) == [.incomplete])
                #expect(turns.first?.answer.isEmpty == false)
                #expect(conversation.canRetry(try #require(turns.first)))
            case .qaAuthError:
                // #153: the refused key names Settings, so the turn shows "Open Settings…" next to Retry.
                #expect(turns.map(\.status) == [.failed(reason: "OpenAI did not accept the API key. Check it in Settings.")])
                #expect(turns.allSatisfy { $0.status.opensSettings })
            case .qaAnthropic:
                #expect(turns.map(\.status) == [.incomplete, .declined,
                                                .failed(reason: "Anthropic did not accept the API key. Check it in Settings."),
                                                .failed(reason: "Anthropic is busy. Try again later.")])
                #expect(turns.map(\.answer) == ["You plan a course step by step [t1]. First you", "", "", ""])
                #expect(turns.map(\.status.opensSettings) == [false, false, true, false])
                #expect(turns.allSatisfy { conversation.canRetry($0) && $0.origin.providerID == "snapshot-anthropic" })
            case .qaCitationRanges:
                // #185: the stored answer keeps the raw range text. #203: `(t1)` merges with the cue at 0:00 in the line before.
                guard case .ready(let lecture) = context else { break }
                let turn = try #require(turns.first)
                #expect(turns.map(\.status) == [.complete] && turn.origin.providerID == "snapshot-anthropic")
                #expect(turn.answer.contains("[t0-1]"))
                let citations = AnswerCitations(answer: turn.answer, context: lecture, isStale: false)
                #expect(citations.text == "It starts with a welcome [1].\nThen you plan the course [1] with outline (v2).\n"
                    + "The guide has more help [?].")
                #expect(citations.sources.map(\.title) == ["1 · 0:00", "? · Unknown source"])
            case .qaGuardEmpty:
                // #192: the echo turn saved no text. It shows the fixed failure text with Retry.
                #expect(turns.map(\.answer) == ["You plan a course step by step [t1].", ""])
                #expect(turns.map(\.status.label) == [nil, "No answer: The model repeated its instructions. Try again."])
                #expect(conversation.canRetry(try #require(turns.last)))
            default:
                #expect(turns.isEmpty)
            }
        case .notesVideo, .notesArticleEmpty, .notesPage, .notesPageEmpty:
            #expect(courseID == "sample-course")
            #expect(SnapshotPlan.imageLoads(for: screen) == 1)
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            switch screen {
            case .notesVideo:
                #expect(library.selectedLecture?.id == "welcome")
                #expect(library.notes(forLecture: "welcome").map(\.timeLabel) == ["0:00", "0:02", "0:03"])
            case .notesArticleEmpty:
                #expect(library.selectedLecture?.id == "read")
                #expect(library.notes(forLecture: "read").isEmpty)
            case .notesPage:
                // Two sections: a video and an article in "plan", a quiz in "practice". The video notes are in time order.
                #expect(library.destination == .notes)
                #expect(library.selectedNoteGroups.map(\.sectionID) == ["plan", "plan", "practice"])
                #expect(library.selectedNoteGroups.map(\.lecture.id) == ["welcome", "read", "check"])
                #expect(library.selectedNoteGroups[0].notes.map(\.videoSeconds) == [0.5, 2])
            default:
                #expect(library.destination == .notes)
                #expect(library.selectedNoteGroups.isEmpty)
            }
        case .outlineDurations:
            #expect(courseID == "sample-course")
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: screen))
            #expect(library.selectedLecture?.id == "recap")
            #expect(library.isComplete("welcome"))
            // The open section: a done video, an article and the selected video with a long title.
            let lectures = try #require(library.selectedCourse?.learnerSections.first?.lectures)
            #expect(lectures.map(\.id) == ["welcome", "read", "recap"])
            #expect(lectures.map { LectureVideo.outlineDurationLabel(type: $0.type, video: library.video(forLecture: $0.id)) }
                == ["0:04", nil, "0:04"])
            #expect(lectures[2].title.count > 60)
        }
        if screen != .sectionReview {
            // Other screens open the first section or a section without earlier quizzes, so no review sheet shows.
            #expect(library.sectionReview == nil)
        }
    }
}

@Test func snapshotLibrarySeedPublishesTheCourseImage() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let courseID = try #require(try SnapshotPlan.seedStore(for: .library, root: root, fixture: fixture))
    let course = try #require(try CourseStore(root: root).loadCourse(id: courseID, includeDrafts: false))
    let image = try #require(course.image)
    #expect(image.alt == "Local Course Basics, with a notebook and leafy branch on pale green.")
    #expect(image.mimeType == "image/svg+xml")
    #expect(FileManager.default.fileExists(atPath: root.appending(path: image.path(forPixelWidth: 128, height: 72)).path))
}

/// #42: SwiftUI `VideoPlayer` crashes on macOS 15 when the app is built with the macOS 26 SDK.
@Test func noSourceUsesSwiftUIVideoPlayer() throws {
    let sources = repo.appending(path: "Sources")
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    #expect(!files.isEmpty)
    let users = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("VideoPlayer(") }
    #expect(users.map(\.lastPathComponent) == [])
}

@Test func snapshotScriptExitsNonZeroWhenTheBuildFails() throws {
    let root = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let scripts = root.appending(path: "scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: repo.appending(path: "scripts/snapshot.sh"), to: scripts.appending(path: "snapshot.sh"))
    let stub = scripts.appending(path: "build.sh")
    try "#!/bin/sh\necho 'error: stub build failure'\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [scripts.appending(path: "snapshot.sh").path, root.appending(path: "out").path]
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus != 0)
    #expect(errorText.contains("error: stub build failure"))
    #expect(errorText.contains("snapshot: the app build failed"))
    #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "out").path))
}
