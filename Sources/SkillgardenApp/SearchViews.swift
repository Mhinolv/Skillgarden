import SwiftUI
import SkillgardenCore

/// The outline column with the transcript search field (#18).
/// A query of 2 or more characters replaces the outline with the results. Escape clears the query.
struct CourseSidebar: View {
    let course: Course
    @Bindable var library: LibraryModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let results = library.transcriptResults {
                TranscriptResultsView(results: results, open: { library.openTranscriptHit($0) },
                                      clear: { library.clearTranscriptSearch() })
            } else {
                CourseOutlineView(course: course, library: library, selection: Binding(
                    get: { library.destination }, set: { library.selectDestination($0) }
                ))
            }
        }
        .searchable(text: $library.transcriptQuery, placement: .sidebar, prompt: "Search transcripts")
        .searchFocused($searchFocused)
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
}

/// The results of a transcript search, grouped by lecture in course order.
/// A click, or the arrow keys, select a result. Return selects the result again.
struct TranscriptResultsView: View {
    let results: TranscriptSearchResults
    let open: (TranscriptHit) -> Void
    let clear: () -> Void
    @State private var selection: String?
    @Environment(\.gardenPalette) private var palette

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
            ForEach(results.groups) { group in
                Section {
                    ForEach(group.hits) { hit in
                        TranscriptHitRow(hit: hit).tag(hit.id)
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
