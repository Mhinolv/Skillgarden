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
            ContentView()
        }
        // The toolbar shares the row of the window buttons and shows no title. The snapshot window copies this style.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                Button("Reload Library", systemImage: "arrow.clockwise") {
                    Task { await focusedLibrary?.reload() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(focusedLibrary == nil || focusedLibrary?.isLoading == true)
                Button(showsTranscript == true ? "Hide Transcript" : "Show Transcript", systemImage: "text.quote") {
                    showsTranscript?.toggle()
                }
                .keyboardShortcut("t", modifiers: [.option, .command])
                .disabled(showsTranscript == nil)
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
                Button("Recommended Next") { focusedLibrary?.goToNudge() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(focusedLibrary?.nudge == nil)
                Divider()
                Button(focusedLibrary?.isSelectedLectureComplete == true ? "Mark as Incomplete" : "Mark as Complete") {
                    Task { await focusedLibrary?.toggleSelectedLectureComplete() }
                }
                .keyboardShortcut("m", modifiers: [.shift, .command])
                .disabled(focusedLibrary?.selectedLecture == nil)
            }
        }
    }

    @FocusedValue(\.library) private var focusedLibrary
    /// Nil when no video lecture with captions shows.
    @FocusedBinding(\.showsTranscript) private var showsTranscript
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
    /// The transcript choice stays for the app session and for all lectures of the window.
    @State private var showsTranscript = true
    private let reloadsOnAppear: Bool
    /// The library folder to show under "No courses yet". It is nil for the default folder.
    private let customRootPath: String?
    @Environment(\.showsReviewInline) private var showsReviewInline
    @Environment(\.showsPDFPreviewInline) private var showsPDFPreviewInline

    /// Uses the data folder that `SKILLGARDEN_DATA_DIR` or the saved `DataDirectory` setting names.
    init() {
        let library: LibraryModel
        do {
            library = LibraryModel(root: try Skillgarden.dataDirectory())
        } catch {
            library = LibraryModel(rootError: error.localizedDescription)
        }
        self.init(library: library, customRootPath: Skillgarden.customDataDirectoryPath(library.root))
    }

    /// The snapshot harness passes a loaded library and sets `reloadsOnAppear` to false.
    init(library: LibraryModel, reloadsOnAppear: Bool = true, customRootPath: String? = nil) {
        _library = State(initialValue: library)
        self.reloadsOnAppear = reloadsOnAppear
        self.customRootPath = customRootPath
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
                .disabled(library.isLoading)
            }
        }
        // The course theme colors the whole window: sidebar, toolbar and content.
        .gardenTheme(library.selectedLanding?.theme)
        .frame(minWidth: 900, minHeight: 600)
        .focusedSceneValue(\.library, library)
        .task { if reloadsOnAppear { await library.reload() } }
    }

    /// The course workspace: the outline and the selected page.
    private func workspace(_ course: Course) -> some View {
        NavigationSplitView {
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
        }
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
                    nudge: library.nudge,
                    completed: library.isComplete(lecture.id),
                    toggleComplete: { Task { await library.toggleSelectedLectureComplete() } },
                    previous: library.previousLecture == nil ? nil : { library.goToPreviousLecture() },
                    next: library.nextLecture == nil ? nil : { library.goToNextLecture() },
                    openNudge: { library.goToNudge() },
                    maxWidth: lecture.type == .interactive ? InteractiveStyle.maxWidth : CourseStyle.textWidth,
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
                                             showsTranscript: $showsTranscript,
                                             seekRequest: library.transcriptSeek.flatMap { $0.lectureID == lecture.id ? $0 : nil },
                                             completed: library.isComplete(lecture.id),
                                             toggleComplete: { Task { await library.toggleSelectedLectureComplete() } },
                                             autoCompletes: library.autoCompletes(lecture.id),
                                             autoComplete: { [library] in library.autoCompleteVideo(lectureID: lecture.id) })
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
