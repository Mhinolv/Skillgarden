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
        Group {
            if let course = library.selectedCourse {
                workspace(course)
            } else {
                LibraryHomeView(library: library)
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
        }
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
