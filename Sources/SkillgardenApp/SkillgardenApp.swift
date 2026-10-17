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
    private let reloadsOnAppear: Bool

    init(root: URL = Skillgarden.defaultDataDirectory) {
        self.init(library: LibraryModel(root: root))
    }

    /// The snapshot harness passes a loaded library and sets `reloadsOnAppear` to false.
    init(library: LibraryModel, reloadsOnAppear: Bool = true) {
        _library = State(initialValue: library)
        self.reloadsOnAppear = reloadsOnAppear
    }

    var body: some View {
        NavigationSplitView {
            libraryList
                .gardenColumn()
                .navigationTitle("Library")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } content: {
            if let course = library.selectedCourse {
                CourseOutlineView(course: course, library: library, selection: Binding(
                    get: { library.destination }, set: { library.selectDestination($0) }
                ))
                .gardenColumn()
                .navigationTitle(course.title)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
            } else {
                ContentUnavailableView("Select a course", systemImage: "books.vertical")
            }
        } detail: {
            detail.gardenColumn()
        }
        // The course theme colors the whole window: sidebar, toolbar and content.
        .gardenTheme(library.selectedLanding?.theme)
        .frame(minWidth: 900, minHeight: 600)
        .focusedSceneValue(\.library, library)
        .task { if reloadsOnAppear { await library.reload() } }
        .toolbar {
            ToolbarItem {
                Button("Reload Library", systemImage: "arrow.clockwise") {
                    Task { await library.reload() }
                }
                .help("Reload Library (⌘R)")
                .disabled(library.isLoading)
            }
        }
    }

    @ViewBuilder private var libraryList: some View {
        if let error = library.errorMessage {
            ContentUnavailableView {
                Label("Can't open the library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await library.reload() } }
                    .disabled(library.isLoading)
            }
        } else if library.isLoading && library.courses.isEmpty {
            ProgressView("Load Library")
        } else if library.courses.isEmpty {
            ContentUnavailableView("No courses yet", systemImage: "books.vertical",
                                   description: Text("Publish a course with the skillgarden CLI."))
        } else {
            List(selection: Binding(get: { library.selectedCourseID }, set: { library.selectCourse($0) })) {
                ForEach(library.courses) { course in
                    LibraryRow(course: course, root: library.root).tag(course.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder private var detail: some View {
        if let course = library.selectedCourse {
            if let lecture = library.selectedLecture, let section = library.selectedSection {
                LectureFrameView(
                    sectionTitle: section.title, number: course.lectureNumber(of: lecture.id) ?? 1, lecture: lecture,
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
                                             saveResumePosition: { [library] in library.saveResumePosition($0, lectureID: lecture.id) })
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
                                isComplete: { library.isComplete($0) },
                                isFreePreview: { library.isFreePreview($0) }) { lecture in
                    library.selectDestination(.lecture(sectionID: section.id, lectureID: lecture.id))
                }
                .id(section.id)
            } else if library.destination == .overview {
                CourseLandingView(course: course, landing: library.selectedLanding, root: library.root,
                                  resumeLecture: library.resumeLecture, resume: { library.resume() },
                                  start: course.firstLecture.map { first in { library.selectDestination(first) } })
            } else {
                ContentUnavailableView("Select a lecture", systemImage: "list.bullet")
            }
        } else {
            ContentUnavailableView("Select a course", systemImage: "books.vertical")
        }
    }
}
