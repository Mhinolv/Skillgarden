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
                .navigationTitle("Library")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } content: {
            if let course = library.selectedCourse {
                CourseOutlineView(course: course, selection: Binding(
                    get: { library.destination }, set: { library.selectDestination($0) }
                ))
                .navigationTitle(course.title)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
            } else {
                ContentUnavailableView("Select a course", systemImage: "books.vertical")
            }
        } detail: {
            detail
        }
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
            if let lecture = library.selectedLecture {
                CourseDetailPlaceholder(title: lecture.title, symbol: lecture.type.symbolName, titleFont: .title2)
            } else if library.destination == .overview {
                CourseDetailPlaceholder(title: course.title, symbol: "info.circle", titleFont: .largeTitle.bold())
            } else {
                ContentUnavailableView("Select a lecture", systemImage: "list.bullet")
            }
        } else {
            ContentUnavailableView("Select a course", systemImage: "books.vertical")
        }
    }
}
