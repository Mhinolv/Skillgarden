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
            CourseOutlineView(course: course, library: library, selection: Binding(
                get: { library.destination }, set: { library.selectDestination($0) }
            ))
            .gardenColumn()
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
                        ZStack {
                            Color.black.opacity(0.25)
                            reviewSheet(review)
                                .clipShape(.garden(GardenRadius.card))
                                .shadow(radius: 12)
                        }
                    }
                }
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
                    maxWidth: lecture.type == .interactive ? InteractiveStyle.maxWidth : CourseStyle.textWidth
                ) {
                    if let attempt = library.selectedQuizAttempt {
                        QuizView(attempt: attempt) { library.performQuizAction($0) }
                    } else {
                        switch lecture.type {
                        case .article: ArticleLectureView(article: library.article(forLecture: lecture.id))
                        case .video:
                            VideoLectureView(video: library.video(forLecture: lecture.id),
                                             startSeconds: { [library] in
                                                 let duration = library.video(forLecture: lecture.id).map { Double($0.durationSeconds) }
                                                 return library.startSeconds(forLecture: lecture.id, duration: duration)
                                             },
                                             saveResumePosition: { [library] in library.saveResumePosition($0, lectureID: lecture.id) },
                                             showsTranscript: $showsTranscript)
                        case .interactive:
                            InteractiveLectureView(lecture: lecture, module: library.selectedInteractive,
                                                   result: library.selectedInteractiveResult) {
                                library.receiveInteractiveMessage($0, lectureID: lecture.id)
                            }
                        case .quiz, .assignment: LectureContentPlaceholder(lecture: lecture)
                        }
                    }
                }
                .id(lecture.id)
            } else if let section = library.selectedSection {
                SectionPageView(section: section, number: course.sectionNumber(of: section.id) ?? 1,
                                headerImage: library.headerImage(forSection: section.id),
                                progress: library.sectionProgress(section),
                                stones: library.steppingStones(in: section),
                                isComplete: { library.isComplete($0) },
                                isFreePreview: { library.isFreePreview($0) }) { lecture in
                    library.selectDestination(.lecture(sectionID: section.id, lectureID: lecture.id))
                }
                .id(section.id)
            } else if library.destination == .overview {
                CourseLandingView(course: course, landing: library.selectedLanding, root: library.root,
                                  path: library.coursePath, percent: library.summary(of: course).percent,
                                  resumeLecture: library.resumeLecture, resume: { library.resume() },
                                  start: course.firstLecture.map { first in { library.selectDestination(first) } },
                                  openLecture: { section, lecture in
                                      library.selectDestination(.lecture(sectionID: section.id, lectureID: lecture.id))
                                  },
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

/// A 40 pt round toolbar button: card fill and a `line` stroke. It shows only the symbol of its label.
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
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(palette.ink)
            .frame(width: 40, height: 40)
            .background(palette.card, in: Circle())
            .overlay { Circle().strokeBorder(palette.line, lineWidth: 1) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Circle())
            .contentShape(.focusEffect, Circle())
    }
}
