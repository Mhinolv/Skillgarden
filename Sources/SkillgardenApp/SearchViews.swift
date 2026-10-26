import SwiftUI
import SkillgardenCore

/// The outline column with the transcript search field (#18).
/// A query of 2 or more characters replaces the outline with the results. Escape clears the query.
struct CourseSidebar: View {
    let course: Course
    @Bindable var library: LibraryModel
    @FocusState private var searchFocused: Bool
    @Environment(\.snapshotSelectsFirstTranscriptHit) private var selectsFirstHit

    var body: some View {
        VStack(spacing: 0) {
            TranscriptSearchField(query: $library.transcriptQuery, focused: $searchFocused)
                .padding(.horizontal, GardenSpacing.s)
                .padding(.top, GardenSpacing.xs)
                .padding(.bottom, GardenSpacing.xxs)
            outline
        }
        .focusedSceneValue(\.searchTranscripts) { searchFocused = true }
        .task(id: library.transcriptQuery) {
            // A short query shows the outline at once. A longer query waits for the learner to stop typing.
            if TranscriptSearch.normalizedQuery(library.transcriptQuery) != nil {
                try? await Task.sleep(for: TranscriptSearch.debounce)
                guard !Task.isCancelled else { return }
            }
            library.searchTranscripts()
        }
        .onChange(of: library.transcriptResults?.summary) { _, summary in
            if let summary { AccessibilityNotification.Announcement(summary).post() }
        }
    }

    @ViewBuilder private var outline: some View {
        Group {
            if let results = library.transcriptResults {
                TranscriptResultsView(results: results, initialSelection: selectsFirstHit ? results.hits.first?.id : nil,
                                      open: { library.openTranscriptHit($0) }, clear: { library.clearTranscriptSearch() })
            } else {
                CourseOutlineView(course: course, library: library, selection: Binding(
                    get: { library.destination }, set: { library.selectDestination($0) }
                ))
            }
        }
        .listStyle(.sidebar)
    }
}

/// The transcript search field at the top of the sidebar. Escape clears the query (#18).
/// The course window has no split view, so `searchable(placement: .sidebar)` cannot place the field (#246).
private struct TranscriptSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.muted)
                .accessibilityHidden(true)
            TextField("Search transcripts", text: $query)
                .textFieldStyle(.plain)
                .focused(focused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.muted)
            }
        }
        .font(GardenFont.body)
        .padding(.horizontal, GardenSpacing.xs)
        .frame(height: 28)
        .background(palette.fill, in: .garden(GardenRadius.button))
        .overlay { RoundedRectangle.garden(GardenRadius.button).strokeBorder(palette.line, lineWidth: 1) }
    }
}

/// The widths of the course sidebar: the learner drags the divider between `minWidth` and `maxWidth`.
enum CourseSidebarLayout {
    static let minWidth: CGFloat = 260
    static let idealWidth: CGFloat = 300
    static let maxWidth: CGFloat = 360
}

/// The 1 pt line between the sidebar and the page. A drag on it changes the sidebar width.
/// It starts below the toolbar, so the toolbar row stays one surface (#246).
struct CourseSidebarDivider: View {
    @Binding var width: CGFloat
    @State private var dragStart: CGFloat?
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.line)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(.rect)
                    .pointerStyle(.columnResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            let start = dragStart ?? width
                            dragStart = start
                            width = min(max(start + drag.translation.width, CourseSidebarLayout.minWidth), CourseSidebarLayout.maxWidth)
                        }
                        .onEnded { _ in dragStart = nil })
            }
            .accessibilityHidden(true)
    }
}

private struct ShowsSidebarFocusKey: FocusedValueKey {
    typealias Value = MenuToggle
}

extension FocusedValues {
    /// Set while a course shows. View > Show Sidebar (⌃⌘S) uses it (#246).
    var showsSidebar: MenuToggle? {
        get { self[ShowsSidebarFocusKey.self] }
        set { self[ShowsSidebarFocusKey.self] = newValue }
    }
}

/// The results of a transcript search, grouped by lecture in course order.
/// A click, or the arrow keys, select a result. Return selects the result again.
/// The selected result has the quiet outline fill, not the system blue (#90).
struct TranscriptResultsView: View {
    let results: TranscriptSearchResults
    let open: (TranscriptHit) -> Void
    let clear: () -> Void
    @State private var selection: String?
    @Environment(\.gardenPalette) private var palette

    /// `initialSelection` selects a result and does not open it. Only the snapshot harness sets it (#90).
    init(results: TranscriptSearchResults, initialSelection: String? = nil,
         open: @escaping (TranscriptHit) -> Void, clear: @escaping () -> Void) {
        self.results = results
        self.open = open
        self.clear = clear
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        // The empty states draw over an empty list. The sidebar search field shows only above a list.
        Group {
            if !results.hasTranscripts {
                List {}.overlay {
                    ContentUnavailableView("No transcripts", systemImage: "text.quote",
                                           description: Text("This course has no video transcripts to search."))
                }
            } else if results.groups.isEmpty {
                List {}.overlay { ContentUnavailableView.search(text: results.query) }
            } else {
                list
            }
        }
        .onExitCommand(perform: clear)
    }

    private var list: some View {
        List(selection: $selection) {
            Text(results.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .selectionDisabled()
                .background(SystemSelectionHighlightOff())
            ForEach(results.groups) { group in
                Section {
                    ForEach(group.hits) { hit in
                        TranscriptHitRow(hit: hit)
                            .outlineSelection(selection == hit.id)
                            .tag(hit.id)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.lectureTitle).font(.headline).foregroundStyle(palette.ink).lineLimit(2)
                        Text(group.sectionTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .onChange(of: selection) { _, id in openHit(id) }
        // A new query starts with no selected result, so a click on any row opens it.
        .onChange(of: results.query) { selection = nil }
        .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { ids in openHit(ids.first) })
    }

    private func openHit(_ id: String?) {
        guard let id, let hit = results.hits.first(where: { $0.id == id }) else { return }
        open(hit)
    }
}

/// One result: the cue start and the snippet with the matched text in bold and the accent color.
private struct TranscriptHitRow: View {
    let hit: TranscriptHit
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.xs) {
            Text(hit.timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            Text(snippet)
                .font(.subheadline)
                .foregroundStyle(palette.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hit.accessibilityLabel)
        .accessibilityHint("Opens the lecture at this moment.")
    }

    private var snippet: AttributedString {
        var text = AttributedString(hit.snippet)
        for match in hit.matches {
            guard let range = Range(match, in: text) else { continue }
            text[range].inlinePresentationIntent = .stronglyEmphasized
            text[range].foregroundColor = palette.accent
        }
        return text
    }
}

private struct SearchTranscriptsFocusKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    /// Set while the course outline shows. Edit > Search Transcripts (⌘F) uses it to focus the search field.
    var searchTranscripts: (() -> Void)? {
        get { self[SearchTranscriptsFocusKey.self] }
        set { self[SearchTranscriptsFocusKey.self] = newValue }
    }
}

private struct SnapshotSelectsFirstTranscriptHitKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The snapshot harness sets this for the `transcript-search-selected` screen (#90). The app sets none.
    var snapshotSelectsFirstTranscriptHit: Bool {
        get { self[SnapshotSelectsFirstTranscriptHitKey.self] }
        set { self[SnapshotSelectsFirstTranscriptHitKey.self] = newValue }
    }
}
