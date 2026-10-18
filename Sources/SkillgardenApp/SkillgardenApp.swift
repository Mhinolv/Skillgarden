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

struct SkillgardenApp: App {
    var body: some Scene {
        WindowGroup("Skillgarden") {
            ContentView(appearance: appearance, autoPlays: autoPlays)
                // The app appearance colors every window, its menus and sheets. A course theme applies only in System (#93).
                .onChange(of: appearance, initial: true) { NSApp.appearance = appearance.nsAppearance }
        }
        // The toolbar shares the row of the window buttons and shows no title. The snapshot window copies this style.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            SidebarCommands()
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
                Button(showsTranscript == true ? "Hide Transcript" : "Show Transcript", systemImage: "text.quote") {
                    showsTranscript?.toggle()
                }
                .keyboardShortcut("t", modifiers: [.option, .command])
                .disabled(showsTranscript == nil)
                // AVKit has no public API to start full screen from code, so the player button is the only full-screen control (#85).
                Button(theaterMode == true ? "Exit Theater Mode" : "Enter Theater Mode", systemImage: "tv") {
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
            SettingsView(autoPlays: Binding(get: { autoPlays }, set: { autoPlays = $0; Skillgarden.saveAutoPlay($0) }))
        }
    }

    /// The View > Appearance choice. Each change is saved at once.
    @State private var appearance = Skillgarden.savedAppearance()
    /// The Settings "Auto-play next lecture" choice (#99). Each change is saved at once.
    @State private var autoPlays = Skillgarden.savedAutoPlay()
    @FocusedValue(\.library) private var focusedLibrary
    /// Nil when no video lecture with captions shows.
    @FocusedBinding(\.showsTranscript) private var showsTranscript
    /// Nil when no video lecture with an available video shows.
    @FocusedBinding(\.theaterMode) private var theaterMode
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
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    private let reloadsOnAppear: Bool
    /// The library folder to show under "No courses yet". It is nil for the default folder.
    private let customRootPath: String?
    /// The app appearance. Dark and Light also apply in the course workspace (#93).
    private let appearance: AppAppearance
    /// The Settings "Auto-play next lecture" choice (#99).
    private let autoPlays: Bool
    /// True while the "Up next" overlay shows. Escape then cancels the countdown and does not end theater.
    @State private var upNextShows = false
    @Environment(\.showsReviewInline) private var showsReviewInline
    @Environment(\.showsPDFPreviewInline) private var showsPDFPreviewInline
    @Environment(\.snapshotIgnoresCourseTheme) private var ignoresCourseTheme
    @Environment(\.snapshotStartsTheater) private var snapshotStartsTheater

    /// Uses the data folder that `SKILLGARDEN_DATA_DIR` or the saved `DataDirectory` setting names.
    init(appearance: AppAppearance, autoPlays: Bool) {
        let library: LibraryModel
        do {
            library = LibraryModel(root: try Skillgarden.dataDirectory())
        } catch {
            library = LibraryModel(rootError: error.localizedDescription)
        }
        self.init(library: library, customRootPath: Skillgarden.customDataDirectoryPath(library.root), appearance: appearance,
                  videoText: Skillgarden.savedVideoTextChoices(), saveVideoText: Skillgarden.saveVideoTextChoices, autoPlays: autoPlays)
    }

    /// The snapshot harness passes a loaded library and sets `reloadsOnAppear` to false.
    init(library: LibraryModel, reloadsOnAppear: Bool = true, customRootPath: String? = nil, appearance: AppAppearance = .dark,
         videoText: VideoTextChoices = VideoTextChoices(), saveVideoText: ((VideoTextChoices) -> Void)? = nil, autoPlays: Bool = true) {
        _library = State(initialValue: library)
        _videoText = State(initialValue: videoText)
        self.saveVideoText = saveVideoText
        self.reloadsOnAppear = reloadsOnAppear
        self.customRootPath = customRootPath
        self.appearance = appearance
        self.autoPlays = autoPlays
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
        .toolbar {
            if library.selectedCourse != nil {
                ToolbarItem(placement: .navigation) {
                    Button("Library", systemImage: "chevron.left") { library.selectCourse(nil) }
                        .buttonStyle(GardenToolbarButtonStyle())
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Library (⌘[)")
                }
            }
            ToolbarItem {
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
        // The course theme colors the whole window: sidebar, toolbar and content.
        .gardenTheme(ignoresCourseTheme ? nil : library.selectedLanding?.theme, appearance: appearance)
        .frame(minWidth: 900, minHeight: 600)
        .focusedSceneValue(\.library, library)
        .task { if reloadsOnAppear { await library.reload() } }
        .onChange(of: showsVideo) { _, showsVideo in showSidebar(theater.pageChanged(showsVideo: showsVideo)) }
        .onAppear { if snapshotStartsTheater { setTheater(true) } }
    }

    /// True while the page is a video lecture. Theater ends on every other page.
    private var showsVideo: Bool {
        library.selectedCourse != nil && library.selectedLecture?.type == .video && library.selectedQuizAttempt == nil
    }

    private func setTheater(_ on: Bool) {
        showSidebar(theater.set(on, sidebarHidden: columnVisibility == .detailOnly))
    }

    /// Applies a sidebar state that `TheaterMode` returns. Nil keeps the sidebar as it is.
    private func showSidebar(_ hidden: Bool?) {
        guard let hidden else { return }
        columnVisibility = hidden ? .detailOnly : .all
    }

    /// The course workspace: the outline and the selected page.
    private func workspace(_ course: Course) -> some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            CourseSidebar(course: course, library: library)
            .gardenColumn(.sidebar)
            .navigationTitle(course.title)
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            detail.gardenColumn()
                .sheet(item: Binding(get: { showsReviewInline ? nil : library.sectionReview },
                                     set: { if $0 == nil { library.closeReview() } })) { review in
                    reviewSheet(review)
                }
                .overlay {
                    if showsReviewInline, let review = library.sectionReview {
                        inlineSheet { reviewSheet(review) }
                    } else if showsPDFPreviewInline, let pdf = inlinePDF {
                        inlineSheet { PDFPreviewSheet(download: pdf) }
                    }
                }
                .background {
                    if theater.isOn && !upNextShows {
                        // Escape ends theater. The button has no visible part. While "Up next" shows, Escape cancels it only (#99).
                        Button("Exit Theater Mode") { showSidebar(theater.end()) }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                }
        }
        // View > Show Sidebar (⌃⌘S) and the toolbar button end theater.
        .onChange(of: columnVisibility) { _, visibility in theater.sidebarChanged(hidden: visibility == .detailOnly) }
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
                    showsCompleteRow: lecture.type != .video || library.selectedQuizAttempt != nil
                ) {
                    if let attempt = library.selectedQuizAttempt {
                        QuizView(attempt: attempt) { library.performQuizAction($0) }
                    } else {
                        switch lecture.type {
                        case .article: ArticleLectureView(article: library.article(forLecture: lecture.id))
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
                                             showsTranscript: videoTextBinding(\.showsTranscript),
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
                                             upNextShowsChanged: { upNextShows = $0 })
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
            } else {
                ContentUnavailableView("Select a lecture", systemImage: "list.bullet")
            }
        }
    }
}

/// The Settings window (⌘,). The app saves each change at once (#99).
struct SettingsView: View {
    @Binding var autoPlays: Bool

    var body: some View {
        Form {
            Toggle("Auto-play next lecture", isOn: $autoPlays)
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize()
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(autoPlays: .constant(true))
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

    /// The snapshot harness sets this for the `-unthemed-dark` captures (#82). The window then uses no course theme,
    /// like the Library: the system accent and the system color scheme. The app sets none.
    var snapshotIgnoresCourseTheme: Bool {
        get { self[SnapshotIgnoresCourseThemeKey.self] }
        set { self[SnapshotIgnoresCourseThemeKey.self] = newValue }
    }
}

private struct SnapshotIgnoresCourseThemeKey: EnvironmentKey {
    static let defaultValue = false
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
