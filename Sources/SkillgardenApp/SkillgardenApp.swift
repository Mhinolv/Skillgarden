import SwiftUI
import SkillgardenCore

@main
enum SkillgardenMain {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot") {
            exit(MainActor.assumeIsolated { SnapshotRenderer.run(arguments: Array(arguments[(index + 1)...])) })
        }
        SkillgardenApp.main()
    }
}

/// Owns the app-wide models. The snapshot harness does not start the app, so it starts no runtime (#123).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The Settings "Local AI" model (#122). The bookmark is in Application Support/Skillgarden.
    let modelSettings = ModelSettings(store: ModelBookmarkStore())
    /// The owned llama-server (#123). It starts at launch and stops at quit (⌘Q), not when the last window closes.
    let localAI = RuntimeSupervisor(isEnabled: Skillgarden.savedLocalAI(), backend: BundledRuntime(), saveEnabled: Skillgarden.saveLocalAI)
    /// The one client of the owned server for all windows (#124). It runs one request at a time.
    let answers = LlamaClient()
    /// The Settings "Q&A" profiles, the "Answer with" choice and the course consents (#151). Secrets are in the Keychain.
    /// LM Studio and Ollama answer through the OpenAI-compatible adapter (#152), OpenAI through the Responses API (#153)
    /// and Anthropic through the Messages API (#154). A ChatGPT plan signs in with Sign in with ChatGPT (#156).
    let providers = AppDelegate.makeProviders()

    private static func makeProviders() -> ProviderSettings {
        ProviderSettings(store: ProviderSettingsStore(), adapterKinds: ShippedAdapters.kinds,
                         makeProvider: { ShippedAdapters.provider(for: $0, credentials: $1) },
                         testConnection: { await ShippedAdapters.testConnection($0, secret: $1) },
                         chatGPT: ChatGPTAuthorizer())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The start runs in the background, so the window opens at once.
        Task {
            await modelSettings.load()
            localAI.setModel(modelSettings.model)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        localAI.stopForQuit()
    }
}

struct SkillgardenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Skillgarden") {
            ContentView(appearance: appearance, autoPlays: autoPlays, localAI: appDelegate.localAI, client: appDelegate.answers,
                        providers: appDelegate.providers)
                // The app appearance colors every window, its menus and sheets. A course theme applies only in System (#93).
                .onChange(of: appearance, initial: true) { NSApp.appearance = appearance.nsAppearance }
        }
        // The toolbar shares the row of the window buttons and shows no title. The snapshot window copies this style.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            // Skillgarden > "Install Command Line Tool…", below "Settings…" (#250).
            CommandGroup(after: .appSettings) {
                Button("Install Command Line Tool…") { CommandLineToolInstaller.start() }
            }
            // The course window has its own sidebar, not a split view, so the toolbar is one row (#246).
            CommandGroup(replacing: .sidebar) {
                Button(showsSidebar?.isOn == false ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left") {
                    showsSidebar?.toggle()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(showsSidebar == nil)
            }
            CommandGroup(after: .newItem) {
                Button("Import Course…", systemImage: "square.and.arrow.down") {
                    if let focusedLibrary { CourseImporter.start(focusedLibrary) }
                }
                .keyboardShortcut("i", modifiers: [.shift, .command])
                .disabled(focusedLibrary?.canImport != true)
            }
            CommandGroup(after: .sidebar) {
                Button("Reload Library", systemImage: "arrow.clockwise") {
                    Task { await focusedLibrary?.reload() }
                }
                .keyboardShortcut("r", modifiers: .command)
                // A reload during an import could skip the reload after the publish (#111).
                .disabled(focusedLibrary == nil || focusedLibrary?.isLoading == true || focusedLibrary?.isImporting == true)
                Button(showsTranscript?.isOn == true ? "Hide Transcript" : "Show Transcript", systemImage: "text.quote") {
                    showsTranscript?.toggle()
                }
                .keyboardShortcut("t", modifiers: [.option, .command])
                .disabled(showsTranscript == nil)
                Button(showsQA?.isOn == true ? "Hide Q&A" : "Show Q&A", systemImage: LectureQAPanel.symbol) {
                    showsQA?.toggle()
                }
                .keyboardShortcut("a", modifiers: [.option, .command])
                .disabled(showsQA == nil)
                Button(showsNotes?.isOn == true ? "Hide Notes" : "Show Notes", systemImage: LectureNotesPanel.symbol) {
                    showsNotes?.toggle()
                }
                .keyboardShortcut("n", modifiers: [.option, .command])
                .disabled(showsNotes == nil)
                // AVKit has no public API to start full screen from code, so the player button is the only full-screen control (#85).
                Button(theaterMode?.isOn == true ? "Exit Theater Mode" : "Enter Theater Mode", systemImage: "tv") {
                    theaterMode?.toggle()
                }
                .keyboardShortcut("t", modifiers: [.shift, .command])
                .disabled(theaterMode == nil)
                Divider()
                Picker("Appearance", selection: Binding(get: { appearance }, set: { appearance = $0; Skillgarden.saveAppearance($0) })) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
            }
            CommandGroup(after: .textEditing) {
                Button("Search Transcripts", systemImage: "magnifyingglass") { searchTranscripts?() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(searchTranscripts == nil)
            }
            CommandMenu("Go") {
                Button("Previous Lecture") { focusedLibrary?.goToPreviousLecture() }
                    .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                    .disabled(focusedLibrary?.previousLecture == nil)
                Button("Next Lecture") { focusedLibrary?.goToNextLecture() }
                    .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
                    .disabled(focusedLibrary?.nextLecture == nil)
                Divider()
                Button(focusedLibrary?.isSelectedLectureComplete == true ? "Mark as Incomplete" : "Mark as Complete") {
                    Task { await focusedLibrary?.toggleSelectedLectureComplete() }
                }
                .keyboardShortcut("m", modifiers: [.shift, .command])
                .disabled(focusedLibrary?.selectedLecture == nil)
            }
        }
        // Skillgarden > Settings… (⌘,).
        Settings {
            SettingsView(autoPlays: Binding(get: { autoPlays }, set: { autoPlays = $0; Skillgarden.saveAutoPlay($0) }),
                         modelSettings: appDelegate.modelSettings, localAI: appDelegate.localAI, providers: appDelegate.providers)
        }
    }

    /// The View > Appearance choice. Each change is saved at once.
    @State private var appearance = Skillgarden.savedAppearance()
    /// The Settings "Auto-play next lecture" choice (#99). Each change is saved at once.
    @State private var autoPlays = Skillgarden.savedAutoPlay()
    @FocusedValue(\.library) private var focusedLibrary
    /// Nil when no video lecture with captions shows.
    @FocusedValue(\.showsTranscript) private var showsTranscript
    /// Nil when no video or article lecture shows (#128).
    @FocusedValue(\.showsQA) private var showsQA
    /// Nil when no lecture shows its Notes pill (#181).
    @FocusedValue(\.showsNotes) private var showsNotes
    /// Nil when no video lecture with an available video shows.
    @FocusedValue(\.theaterMode) private var theaterMode
    /// Nil on the Library home. View > Show Sidebar uses it (#246).
    @FocusedValue(\.showsSidebar) private var showsSidebar
    /// Nil when no course outline shows.
    @FocusedValue(\.searchTranscripts) private var searchTranscripts
}

private struct LibraryFocusKey: FocusedValueKey {
    typealias Value = LibraryModel
}

extension FocusedValues {
    fileprivate var library: LibraryModel? {
        get { self[LibraryFocusKey.self] }
        set { self[LibraryFocusKey.self] = newValue }
    }
}

struct ContentView: View {
    @State private var library: LibraryModel
    /// The Captions and Transcript choices for all video lectures (#97). Each change is saved at once.
    @State private var videoText: VideoTextChoices
    /// Nil saves nothing. The snapshot harness passes nil, so it never touches the real defaults domain.
    private let saveVideoText: ((VideoTextChoices) -> Void)?
    /// Theater hides the sidebar and widens the player (#85). It stays on for video lectures and ends on other pages.
    @State private var theater = TheaterMode()
    @State private var sidebarShown = true
    @State private var sidebarWidth = CourseSidebarLayout.idealWidth
    private let reloadsOnAppear: Bool
    /// The library folder to show under "No courses yet". It is nil for the default folder.
    private let customRootPath: String?
    /// The app appearance. Dark and Light also apply in the course workspace (#93).
    private let appearance: AppAppearance
    /// The snapshot override of the macOS "Increase contrast" setting (#219). Nil reads the system.
    private let increasedContrast: Bool?
    /// The Settings "Auto-play next lecture" choice (#99).
    private let autoPlays: Bool
    /// True while the "Up next" overlay shows. Escape then cancels the countdown and does not end theater.
    @State private var upNextShows = false
    /// The owned llama-server (#123). The Q&A panel shows its state (#128).
    private let localAI: RuntimeSupervisor
    /// The Q&A panel of the window (#128). A lecture change cancels its request.
    @State private var qa: LectureQA
    /// The "Answer with" choice and the course consents (#151).
    private let providers: ProviderSettings
    /// The Q&A or Notes panel that is open (#181). The window keeps it for all lectures, like theater. It is not saved.
    @State private var openPanel: LecturePanelSlot.Panel?
    /// True while a notes field has focus (#181). Escape then cancels the edit and does not end theater.
    @State private var notesFieldFocused = false
    @Environment(\.showsReviewInline) private var showsReviewInline
    @Environment(\.showsPDFPreviewInline) private var showsPDFPreviewInline
    @Environment(\.snapshotStartsTheater) private var snapshotStartsTheater
    @Environment(\.snapshotShowsQA) private var snapshotShowsQA
    @Environment(\.snapshotShowsNotes) private var snapshotShowsNotes

    /// Uses the data folder that `SKILLGARDEN_DATA_DIR` or the saved `DataDirectory` setting names.
    init(appearance: AppAppearance, autoPlays: Bool, localAI: RuntimeSupervisor, client: LlamaClient, providers: ProviderSettings) {
        let library: LibraryModel
        do {
            library = LibraryModel(root: try Skillgarden.dataDirectory())
        } catch {
            library = LibraryModel(rootError: error.localizedDescription)
        }
        self.init(library: library, customRootPath: Skillgarden.customDataDirectoryPath(library.root), appearance: appearance,
                  videoText: Skillgarden.savedVideoTextChoices(), saveVideoText: Skillgarden.saveVideoTextChoices, autoPlays: autoPlays,
                  localAI: localAI, client: client, providers: providers)
    }

    /// The snapshot harness passes a loaded library and sets `reloadsOnAppear` to false.
    /// It passes a `localAI` with an injected status and starts no runtime.
    init(library: LibraryModel, reloadsOnAppear: Bool = true, customRootPath: String? = nil, appearance: AppAppearance = .dark,
         videoText: VideoTextChoices = VideoTextChoices(), saveVideoText: ((VideoTextChoices) -> Void)? = nil, autoPlays: Bool = true,
         localAI: RuntimeSupervisor = RuntimeSupervisor(isEnabled: false, backend: nil), client: LlamaClient = LlamaClient(),
         providers: ProviderSettings = ProviderSettings(store: nil, credentials: MemoryCredentialStore()),
         increasedContrast: Bool? = nil) {
        _library = State(initialValue: library)
        self.localAI = localAI
        self.providers = providers
        let provider = BundledAnswerProvider(client: client, endpoint: { [localAI] in localAI.verifiedEndpoint() })
        _qa = State(initialValue: LectureQA(library: library, provider: provider, providers: providers,
                                            announce: { AccessibilityNotification.Announcement($0).post() }))
        _videoText = State(initialValue: videoText)
        self.saveVideoText = saveVideoText
        self.reloadsOnAppear = reloadsOnAppear
        self.customRootPath = customRootPath
        self.appearance = appearance
        self.increasedContrast = increasedContrast
        self.autoPlays = autoPlays
    }

    /// The Transcript choice as the video page shows it (#128). Q&A, Notes (#181) and the transcript share one slot.
    /// Q&A or Notes hides the transcript and keeps the saved choice. The Transcript pill on closes them.
    private var transcriptBinding: Binding<Bool> {
        Binding(get: { LecturePanelSlot.showsTranscript(saved: videoText.showsTranscript, open: openPanel) }, set: { on in
            let next = LecturePanelSlot.setTranscript(on, open: openPanel)
            openPanel = next.open
            videoTextBinding(\.showsTranscript).wrappedValue = next.saved
        })
    }

    /// The open state of one panel of the slot. On closes the other panel.
    private func panelBinding(_ panel: LecturePanelSlot.Panel) -> Binding<Bool> {
        Binding(get: { openPanel == panel }, set: { openPanel = LecturePanelSlot.set(panel, $0, open: openPanel) })
    }

    private var qaPanel: LectureQAPanel {
        LectureQAPanel(qa: qa, localAI: localAI, providers: providers, isOn: panelBinding(.qa))
    }

    private func notesPanel(_ lecture: Lecture) -> LectureNotesPanel {
        LectureNotesPanel(library: library, lectureID: lecture.id, isOn: panelBinding(.notes),
                          focusChanged: { notesFieldFocused = $0 })
    }

    /// A binding to one video text choice that saves the change at once.
    private func videoTextBinding(_ keyPath: WritableKeyPath<VideoTextChoices, Bool>) -> Binding<Bool> {
        Binding(get: { videoText[keyPath: keyPath] }, set: { value in
            guard videoText[keyPath: keyPath] != value else { return }
            videoText[keyPath: keyPath] = value
            saveVideoText?(videoText)
        })
    }

    var body: some View {
        Group {
            if let course = library.selectedCourse {
                workspace(course)
            } else {
                LibraryHomeView(library: library, customRootPath: customRootPath)
            }
        }
        // The toolbar is inside the theme, so its buttons get the Garden palette.
        // One group after the window buttons: sidebar, Library, Reload (#246).
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if library.selectedCourse != nil {
                    Button(sidebarShown ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                        withAnimation(.easeInOut(duration: 0.2)) { sidebarShown.toggle() }
                    }
                    .buttonStyle(GardenToolbarButtonStyle())
                    .help(sidebarShown ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
                    Button("Library", systemImage: "chevron.left") { library.selectCourse(nil) }
                        .buttonStyle(GardenToolbarButtonStyle())
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Library (⌘[)")
                }
                Button("Reload Library", systemImage: "arrow.clockwise") {
                    Task { await library.reload() }
                }
                .buttonStyle(GardenToolbarButtonStyle())
                .help("Reload Library (⌘R)")
                .disabled(library.isLoading || library.isImporting)
            }
        }
        .sheet(item: Binding(get: { library.importingTitle.map(ImportingCourse.init) }, set: { _ in })) {
            ImportProgressSheet(title: $0.title)
        }
        // The course theme sets only the light or dark look of the window. The accent is the system accent (#182).
        .gardenTheme(library.selectedLanding?.theme, appearance: appearance, increasedContrast: increasedContrast)
        .frame(minWidth: 900, minHeight: 600)
        .focusedSceneValue(\.library, library)
        .task { if reloadsOnAppear { await library.reload() } }
        .onChange(of: showsVideo) { _, showsVideo in showSidebar(theater.pageChanged(showsVideo: showsVideo)) }
        // A lecture change cancels the Q&A request, so no answer goes into the thread of another lecture (#128).
        .onChange(of: LectureQA.key(library: library), initial: true) { _, key in qa.show(key) }
        .onAppear {
            if snapshotStartsTheater { setTheater(true) }
            if snapshotShowsQA { openPanel = .qa }
            if snapshotShowsNotes { openPanel = .notes }
        }
    }

    /// True while the page is a video lecture. Theater ends on every other page.
    private var showsVideo: Bool {
        library.selectedCourse != nil && library.selectedLecture?.type == .video && library.selectedQuizAttempt == nil
    }

    private func setTheater(_ on: Bool) {
        showSidebar(theater.set(on, sidebarHidden: !sidebarShown))
    }

    /// Applies a sidebar state that `TheaterMode` returns. Nil keeps the sidebar as it is.
    private func showSidebar(_ hidden: Bool?) {
        guard let hidden else { return }
        sidebarShown = !hidden
    }

    /// The course workspace: the outline and the selected page.
    /// It is not a split view: a split view cuts the toolbar into a sidebar part and a page part (#246).
    private func workspace(_ course: Course) -> some View {
        HStack(spacing: 0) {
            if sidebarShown {
                CourseSidebar(course: course, library: library)
                    .gardenColumn(.sidebar)
                    .frame(width: sidebarWidth)
                    // An overlay keeps the line below the toolbar. A shape in the stack fills up into the toolbar row.
                    .overlay(alignment: .trailing) { CourseSidebarDivider(width: $sidebarWidth) }
                    .transition(.move(edge: .leading))
            }
            detail.gardenColumn()
                // One strip shows every progress write that the store refused (#210).
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let text = library.progressSaveFailureText {
                        ProgressSaveFailureStrip(text: text) { library.retryProgressSaves() }
                    }
                }
                .sheet(item: Binding(get: { showsReviewInline ? nil : library.sectionReview },
                                     set: { if $0 == nil { library.closeReview() } })) { review in
                    reviewSheet(review)
                }
                .overlay {
                    if showsReviewInline, let review = library.sectionReview {
                        inlineSheet { reviewSheet(review) }
                    } else if showsPDFPreviewInline, let pdf = inlinePDF {
                        inlineSheet { PDFPreviewSheet(download: pdf) }
                    } else if showsReviewInline, let request = qa.consentRequest {
                        // The Q&A panel shows the real consent sheet. The snapshot harness draws it here (#151).
                        inlineSheet { RemoteConsentSheet(request: request, showsText: true, allow: {}, cancel: {}) }
                    }
                }
                .background {
                    if theater.isOn && !upNextShows && !qa.isAnswering && !notesFieldFocused {
                        // Escape ends theater. The button has no visible part. While "Up next" shows, Escape cancels it only (#99).
                        // While a Q&A answer runs, Escape cancels the answer only (#128). A notes field keeps Escape (#181).
                        Button("Exit Theater Mode") { showSidebar(theater.end()) }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                }
        }
        .navigationTitle(course.title)
        .focusedSceneValue(\.showsSidebar, MenuToggle(Binding(get: { sidebarShown }, set: { shown in
            withAnimation(.easeInOut(duration: 0.2)) { sidebarShown = shown }
        })))
        // View > Show Sidebar (⌃⌘S) and the toolbar button end theater.
        .onChange(of: sidebarShown) { _, shown in theater.sidebarChanged(hidden: !shown) }
    }

    /// A sheet that the snapshot harness draws in the window. A real sheet is a separate window, so the capture misses it.
    private func inlineSheet(@ViewBuilder _ sheet: () -> some View) -> some View {
        ZStack {
            Color.black.opacity(0.25)
            sheet()
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(.garden(10))
                .overlay { RoundedRectangle.garden(10).strokeBorder(.separator, lineWidth: 1) }
        }
    }

    /// The first available PDF download of the selected lecture.
    private var inlinePDF: LectureDownload? {
        library.selectedLecture.flatMap { lecture in
            library.downloads(forLecture: lecture.id).first { $0.kind == .pdf && $0.isAvailable }
        }
    }

    private func reviewSheet(_ review: SectionReview) -> some View {
        SectionReviewSheet(review: review, answer: { library.answerReview(questionID: $0, choiceID: $1) },
                           close: { library.closeReview() })
    }

    @ViewBuilder private var detail: some View {
        if let course = library.selectedCourse {
            if let lecture = library.selectedLecture, let section = library.selectedSection {
                LectureFrameView(
                    sectionTitle: section.title, number: course.lectureNumber(of: lecture.id) ?? 1, lecture: lecture,
                    stones: library.steppingStones(in: section),
                    completed: library.isComplete(lecture.id),
                    toggleComplete: { Task { await library.toggleSelectedLectureComplete() } },
                    previous: library.previousLecture == nil ? nil : { library.goToPreviousLecture() },
                    next: library.nextLecture == nil ? nil : { library.goToNextLecture() },
                    maxWidth: lecture.type == .interactive ? InteractiveStyle.maxWidth
                        : lecture.type == .video && theater.isOn ? .infinity : CourseStyle.textWidth,
                    downloads: library.downloads(forLecture: lecture.id),
                    sources: library.selectedSources,
                    // A quiz has its own primary action, so each screen keeps one accent button.
                    completeIsPrimary: lecture.type != .quiz,
                    // A video has the complete control in its controls row, under the player.
                    showsCompleteRow: lecture.type != .video || library.selectedQuizAttempt != nil,
                    // Video and article pages show the Notes pill next to Q&A. The other types show it in the complete row (#181).
                    notesPanel: [.video, .article].contains(lecture.type) ? nil : notesPanel(lecture)
                ) {
                    if let attempt = library.selectedQuizAttempt {
                        QuizView(attempt: attempt) { library.performQuizAction($0) }
                    } else {
                        switch lecture.type {
                        case .article:
                            ArticleLectureView(article: library.article(forLecture: lecture.id), qaPanel: qaPanel,
                                               notesPanel: notesPanel(lecture))
                        case .video:
                            VideoLectureView(video: library.video(forLecture: lecture.id),
                                             quickChecks: library.selectedQuickChecks,
                                             answerQuickCheck: { library.answerQuickCheck($0, choiceID: $1) },
                                             retryQuickCheck: { library.retryQuickCheck($0) },
                                             startSeconds: { [library] in
                                                 let duration = library.video(forLecture: lecture.id).map { Double($0.durationSeconds) }
                                                 return library.startSeconds(forLecture: lecture.id, duration: duration)
                                             },
                                             saveResumePosition: { [library] in library.saveResumePosition($0, lectureID: lecture.id) },
                                             showsCaptions: videoTextBinding(\.showsCaptions),
                                             showsTranscript: transcriptBinding,
                                             theater: Binding(get: { theater.isOn }, set: { setTheater($0) }),
                                             playerMaxWidth: theater.playerMaxWidth,
                                             seekRequest: library.transcriptSeek.flatMap { $0.lectureID == lecture.id ? $0 : nil },
                                             completed: library.isComplete(lecture.id),
                                             toggleComplete: { Task { await library.toggleSelectedLectureComplete() } },
                                             autoCompletes: library.autoCompletes(lecture.id),
                                             autoComplete: { [library] in library.autoCompleteVideo(lectureID: lecture.id) },
                                             upNextTitle: autoPlays ? library.nextLectureTitle : nil,
                                             playNext: { library.playNextLecture() },
                                             startsPlaying: { [library] in library.takeAutoPlay(lectureID: lecture.id) },
                                             upNextShowsChanged: { upNextShows = $0 },
                                             qaPanel: qaPanel,
                                             notesPanel: notesPanel(lecture))
                        case .interactive:
                            InteractiveLectureView(lecture: lecture, module: library.selectedInteractive,
                                                   result: library.selectedInteractiveResult) {
                                library.receiveInteractiveMessage($0, lectureID: lecture.id)
                            }
                        case .assignment:
                            AssignmentLectureView(assignment: library.selectedAssignment,
                                                  checklist: library.selectedRubricChecklist,
                                                  toggle: { library.toggleRubricCriterion($0) },
                                                  reset: { library.resetRubric() })
                        case .quiz: LectureContentPlaceholder(lecture: lecture)
                        }
                    }
                }
                .id(lecture.id)
            } else if let section = library.selectedSection {
                SectionPageView(section: section, number: course.sectionNumber(of: section.id) ?? 1,
                                headerImage: library.headerImage(forSection: section.id),
                                progress: library.sectionProgress(section),
                                stones: library.steppingStones(in: section),
                                isComplete: { library.isComplete($0) }) { lecture in
                    library.selectDestination(.lecture(sectionID: section.id, lectureID: lecture.id))
                }
                .id(section.id)
            } else if library.destination == .overview {
                CourseLandingView(course: course, landing: library.selectedLanding, root: library.root,
                                  percent: library.summary(of: course).percent,
                                  resumeLecture: library.resumeLecture, resume: { library.resume() },
                                  start: course.firstLecture.map { first in { library.selectDestination(first) } },
                                  openCredits: library.selectedCredits.isEmpty ? nil : { library.selectDestination(.credits) })
            } else if library.destination == .credits {
                CourseCreditsView(credits: library.selectedCredits)
            } else if library.destination == .notes {
                CourseNotesView(groups: library.selectedNoteGroups) { library.openNote($0, seeks: $1) }
            } else {
                ContentUnavailableView("Select a lecture", systemImage: "list.bullet")
            }
        }
    }
}

/// The Settings window (⌘,). The app saves each change at once (#99).
struct SettingsView: View {
    @Binding var autoPlays: Bool
    /// The "Local AI" model choice (#122).
    let modelSettings: ModelSettings
    /// The owned llama-server (#123).
    let localAI: RuntimeSupervisor
    /// The "Q&A" provider profiles (#151).
    let providers: ProviderSettings

    var body: some View {
        Form {
            Toggle("Auto-play next lecture", isOn: $autoPlays)
            QAProvidersSection(providers: providers)
            LocalAISection(settings: modelSettings, localAI: localAI)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        // Each open checks the saved model again, so a moved or deleted file shows at once.
        .task {
            providers.checkCredentials()
            await modelSettings.load()
            // A ChatGPT plan session near its end refreshes, so a session that can't refresh shows "Sign in again." (#156).
            await providers.refreshChatGPTSessions()
        }
        // A new model restarts the server: Stopping, Starting, Ready.
        .onChange(of: modelSettings.model) { _, model in localAI.setModel(model) }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(autoPlays: .constant(true), modelSettings: ModelSettings(store: nil),
                     localAI: RuntimeSupervisor(isEnabled: true, backend: nil, status: .ready(version: "b11669")),
                     providers: ProviderSettings(store: nil, credentials: MemoryCredentialStore(), profiles: SnapshotPlan.providerProfiles,
                                                 selectedID: SnapshotPlan.providerProfiles[0].id))
    }
}

extension AppAppearance {
    /// The app-wide AppKit appearance, or nil for System.
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }
}

private struct ShowsReviewInlineKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The snapshot harness sets this, so the review sheet draws in the window and the capture shows it. The app sets none.
    var showsReviewInline: Bool {
        get { self[ShowsReviewInlineKey.self] }
        set { self[ShowsReviewInlineKey.self] = newValue }
    }

}

private struct SnapshotStartsTheaterKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The snapshot harness sets this for the `video-theater` screen, so the window opens in theater mode (#85). The app sets none.
    var snapshotStartsTheater: Bool {
        get { self[SnapshotStartsTheaterKey.self] }
        set { self[SnapshotStartsTheaterKey.self] = newValue }
    }
}

/// The save-failure strip at the top of the detail column (#210). It uses the red box of the quiz feedback.
/// "Try Again" writes the latest values once. VoiceOver hears the text when it shows or changes.
struct ProgressSaveFailureStrip: View {
    let text: String
    let retry: () -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.wrong)
                .accessibilityHidden(true)
            Text(text)
                .font(GardenFont.body)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again", action: retry)
                .buttonStyle(.garden(.bordered))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, GardenSpacing.s)
        .background(palette.wrongFill, in: .garden(GardenRadius.button))
        .padding(.horizontal, GardenSpacing.s)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .onChange(of: text, initial: true) { _, text in AccessibilityNotification.Announcement(text).post() }
    }
}

/// A 28 pt toolbar button: a muted symbol, radius 6, no border. It shows only the symbol of its label.
struct GardenToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GardenToolbarButton(configuration: configuration)
    }
}

private struct GardenToolbarButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(palette.muted)
            .frame(width: 28, height: 28)
            .background(configuration.isPressed ? palette.fill : .clear, in: .garden(GardenRadius.button))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.garden(GardenRadius.button))
            .contentShape(.focusEffect, .garden(GardenRadius.button))
    }
}
