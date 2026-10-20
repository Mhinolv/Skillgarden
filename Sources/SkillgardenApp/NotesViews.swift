import SwiftUI
import SkillgardenCore

/// The Notes "tab" of a lecture (#181): a pill and the panel. Video: after Q&A in the controls row, the panel in the shared slot.
/// Article: after Q&A in the meta row. Quiz, assignment and interactive: the left end of the complete row.
/// The window keeps the open state for all lectures, like Q&A. It is not saved.
@MainActor
struct LectureNotesPanel {
    let library: LibraryModel
    let lectureID: String
    let isOn: Binding<Bool>
    /// The value of `isOn` when the page made the panel, so the page draws again when the panel opens or closes.
    let isShown: Bool
    /// Gets true while a notes field has focus. The window then keeps Escape for the field.
    let windowFocusChanged: (Bool) -> Void

    init(library: LibraryModel, lectureID: String, isOn: Binding<Bool>, focusChanged: @escaping (Bool) -> Void) {
        self.library = library
        self.lectureID = lectureID
        self.isOn = isOn
        isShown = isOn.wrappedValue
        windowFocusChanged = focusChanged
    }

    static let symbol = "note.text"

    func pill(iconOnly: Bool = false) -> some View {
        Toggle(isOn: isOn) { Label("Notes", systemImage: Self.symbol) }
            .help(isShown ? "Hide Notes (⌥⌘N)" : "Show Notes (⌥⌘N)")
            .toggleStyle(GardenPillToggleStyle())
            .labelStyle(ToolbarLabelStyle(iconOnly: iconOnly))
            .environment(\.gardenLabelIconOnly, iconOnly)
    }

    /// `currentSeconds` gives the playback time of a video lecture. Nil for a lecture that is not a video, so its notes have no time.
    /// The page draws again on each caption cue and progress save. The panel skips these redraws.
    func panel(currentSeconds: (@MainActor () -> Double?)? = nil, focusChanged: @escaping (Bool) -> Void = { _ in }) -> some View {
        let windowFocusChanged = windowFocusChanged
        return LectureNotesView(library: library, lectureID: lectureID, currentSeconds: currentSeconds,
                                focusChanged: { windowFocusChanged($0); focusChanged($0) })
            .equatable()
    }
}

/// The Notes panel: the header, the notes of the lecture in panel order, then the composer.
/// "Add Note" is bordered, so "Mark as Complete" stays the only accent button of the page.
/// The panel observes the library, so a page redraw does not draw it again. The closures are not compared.
struct LectureNotesView: View, Equatable {
    let library: LibraryModel
    let lectureID: String
    let currentSeconds: (@MainActor () -> Double?)?
    var focusChanged: (Bool) -> Void = { _ in }
    @Environment(\.gardenPalette) private var palette
    @Environment(\.snapshotEditsNote) private var snapshotEditsNote
    @State private var editing: LectureNote.ID?
    @State private var editText = ""
    @State private var deletes: LectureNote?
    @State private var saveFailed = false
    @FocusState private var focus: NoteField?

    static let listHeight: CGFloat = 240

    nonisolated static func == (lhs: LectureNotesView, rhs: LectureNotesView) -> Bool {
        lhs.library === rhs.library && lhs.lectureID == rhs.lectureID && (lhs.currentSeconds == nil) == (rhs.currentSeconds == nil)
    }

    var body: some View {
        let notes = library.notes(forLecture: lectureID)
        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
            Text("Notes").gardenText(.cardTitle).accessibilityAddTraits(.isHeader)
            if notes.isEmpty {
                Text("No notes yet")
                    .font(GardenFont.body)
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // A short list takes only the height that it needs. A long list scrolls in 240 pt.
                ViewThatFits(in: .vertical) {
                    rows(notes)
                    ScrollView { rows(notes) }
                }
                .frame(maxHeight: Self.listHeight, alignment: .top)
            }
            NotesComposer(library: library, lectureID: lectureID, currentSeconds: currentSeconds, saveFailed: $saveFailed,
                          focus: $focus)
            if saveFailed {
                Label("Could not save the note.", systemImage: "exclamationmark.triangle")
                    .font(GardenFont.small)
                    .foregroundStyle(palette.muted)
            }
        }
        .gardenCard(padding: GardenSpacing.s)
        .onChange(of: focus != nil) { _, focused in focusChanged(focused) }
        .onDisappear { if focus != nil { focusChanged(false) } }
        .task(id: lectureID) {
            editing = nil
            saveFailed = false
            if snapshotEditsNote, let note = library.notes(forLecture: lectureID).dropFirst().first { startEdit(note) }
        }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { deletes != nil }, set: { if !$0 { deletes = nil } }),
                            presenting: deletes) { note in
            Button("Delete", role: .destructive) { delete(note) }
        } message: { _ in
            Text("You cannot undo this.")
        }
    }

    private func rows(_ notes: [LectureNote]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(notes) { note in
                if editing == note.id {
                    editRow(note)
                } else {
                    NoteRow(note: note, seek: note.videoSeconds == nil ? nil : { library.seekNote(note) },
                            edit: { startEdit(note) }, delete: { deletes = note })
                }
            }
        }
    }

    /// The row as a field. Return saves. Escape cancels. A failed save keeps the text.
    private func editRow(_ note: LectureNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.xs) {
            if let label = note.timeLabel {
                Text(label)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.muted)
                    .frame(width: 48, alignment: .leading)
                    .accessibilityHidden(true)
            }
            TextField("Edit note", text: $editText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .edit(note.id))
                .onSubmit { saveEdit(note) }
                .onExitCommand { cancelEdit() }
            Button("Save") { saveEdit(note) }
                .buttonStyle(.garden(.plain, .small))
                .disabled(LectureNote.cleanText(editText) == nil)
            Button("Cancel") { cancelEdit() }
                .buttonStyle(.garden(.plain, .small))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    private func startEdit(_ note: LectureNote) {
        editText = note.text
        editing = note.id
        saveFailed = false
        focus = .edit(note.id)
    }

    private func cancelEdit() {
        editing = nil
        saveFailed = false
        focus = nil
    }

    private func saveEdit(_ note: LectureNote) {
        guard LectureNote.cleanText(editText) != nil else { return }
        let text = editText
        Task {
            if await library.updateNote(note, text: text) {
                if editing == note.id { cancelEdit() }
            } else {
                saveFailed = true
            }
        }
    }

    private func delete(_ note: LectureNote) {
        if editing == note.id { cancelEdit() }
        Task { saveFailed = !(await library.deleteNote(note)) }
    }
}

/// The text fields of the Notes panel: the composer, or the field of the note in edit.
enum NoteField: Hashable {
    case composer
    case edit(LectureNote.ID)
}

/// One note: the time label of a transcript line (video notes only), then the text.
/// A click on the time seeks. On hover, "Edit" and "Delete" show. The context menu has both.
private struct NoteRow: View {
    let note: LectureNote
    /// Nil for a note with no time.
    let seek: (() -> Void)?
    let edit: () -> Void
    let delete: () -> Void
    @Environment(\.gardenPalette) private var palette
    @Environment(\.locale) private var locale
    @State private var hovers = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.xs) {
            if let label = note.timeLabel, let seek {
                Button(action: seek) {
                    Text(label)
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accentInk)
                .pointerStyle(.link)
                .help("Jump to \(label)")
            }
            Text(note.text)
                .font(GardenFont.body)
                .foregroundStyle(palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                Button("Edit", systemImage: "pencil", action: edit)
                    .help("Edit")
                Button("Delete", systemImage: "trash", action: delete)
                    .help("Delete")
            }
            .buttonStyle(.garden(.plain, .small))
            .labelStyle(.iconOnly)
            .opacity(hovers ? 1 : 0)
            .allowsHitTesting(hovers)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background {
            if hovers { RoundedRectangle(cornerRadius: GardenRadius.row).fill(palette.fill) }
        }
        .contentShape(.rect)
        .onHover { hovers = $0 }
        .contextMenu {
            Button("Edit", systemImage: "pencil", action: edit)
            Button("Delete", systemImage: "trash", action: delete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note.accessibilityLabel(locale: locale))
        .accessibilityHint(seek == nil ? "" : "Jumps to this moment.")
        .accessibilityAddTraits(seek == nil ? [] : .isButton)
        .accessibilityAction { seek?() }
        .accessibilityAction(named: "Edit", edit)
        .accessibilityAction(named: "Delete", delete)
    }
}

/// The note field and "Add Note". It alone reads the text, so a key press draws only this view.
/// On a video, the first key press records the playback time and shows it left of the field. Playback continues.
private struct NotesComposer: View {
    let library: LibraryModel
    let lectureID: String
    let currentSeconds: (@MainActor () -> Double?)?
    @Binding var saveFailed: Bool
    var focus: FocusState<NoteField?>.Binding
    @State private var text = ""
    /// The playback time of the first key press. Nil before it and for a lecture that is not a video.
    @State private var seconds: Double?
    @State private var saving = false
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        let canAdd = !saving && LectureNote.cleanText(text) != nil
        HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.xs) {
            if let seconds {
                Text(LectureVideo.durationLabel(seconds: Int(seconds)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.muted)
                    .accessibilityLabel("Note time \(LectureVideo.spokenDuration(seconds: Int(seconds)))")
            }
            TextField("Add a note", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .composer)
                .onSubmit { if canAdd { add() } }
            Button("Add Note", action: add)
                .buttonStyle(.garden(.bordered))
                .disabled(!canAdd)
        }
        .onChange(of: text) { _, new in
            if new.isEmpty {
                seconds = nil
            } else if seconds == nil, let currentSeconds {
                seconds = currentSeconds()
            }
        }
        .onChange(of: lectureID) {
            text = ""
            seconds = nil
        }
    }

    private func add() {
        guard !saving, LectureNote.cleanText(text) != nil else { return }
        let note = text
        let time = currentSeconds == nil ? nil : seconds ?? currentSeconds?()
        saving = true
        Task {
            let saved = await library.addNote(note, videoSeconds: time, lectureID: lectureID)
            saving = false
            saveFailed = !saved
            // A failed save keeps the text, so the learner can try again.
            if saved && text == note {
                text = ""
                seconds = nil
            }
        }
    }
}

/// The course Notes page (#181): the notes under "Section · Lecture" headers in course order.
/// A row click opens the lecture. A click on the time also seeks the video to the note.
struct CourseNotesView: View {
    let groups: [LectureNoteGroup]
    let open: (LectureNote, _ seeks: Bool) -> Void
    @Environment(\.gardenPalette) private var palette
    @Environment(\.locale) private var locale

    var body: some View {
        if groups.isEmpty {
            ContentUnavailableView("No notes yet", systemImage: LectureNotesPanel.symbol)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Notes")
                        .gardenText(.title)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your notes on each lecture, in course order.")
                        .gardenText(.meta)
                        .padding(.top, GardenSpacing.xxs)
                        .padding(.bottom, GardenSpacing.s)
                    ForEach(groups) { group in
                        Text(group.title)
                            .gardenText(.cardTitle)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.top, GardenSpacing.m)
                            .padding(.bottom, GardenSpacing.xxs)
                        ForEach(Array(group.notes.enumerated()), id: \.element.id) { index, note in
                            if index > 0 { Divider() }
                            row(note)
                        }
                    }
                }
                .frame(maxWidth: CourseStyle.textWidth, alignment: .leading)
                .padding(CourseStyle.detailPadding)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func row(_ note: LectureNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.xs) {
            if let label = note.timeLabel {
                Button { open(note, true) } label: {
                    Text(label)
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accentInk)
                .pointerStyle(.link)
                .help("Jump to \(label)")
                .accessibilityLabel(note.accessibilityLabel(locale: locale))
                .accessibilityHint("Jumps to this moment.")
            }
            Button { open(note, false) } label: {
                Text(note.text)
                    .font(GardenFont.body)
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the lecture")
            .accessibilityLabel(note.timeLabel == nil ? note.accessibilityLabel(locale: locale) : note.text)
            .accessibilityHint("Opens the lecture.")
        }
        .padding(.vertical, 10)
    }
}

private struct ShowsNotesFocusKey: FocusedValueKey {
    typealias Value = MenuToggle
}

extension FocusedValues {
    /// Set while a lecture shows its Notes pill. View > Show Notes uses it (#181).
    var showsNotes: MenuToggle? {
        get { self[ShowsNotesFocusKey.self] }
        set { self[ShowsNotesFocusKey.self] = newValue }
    }
}

private struct TextEntryFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SnapshotShowsNotesKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SnapshotEditsNoteKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while a notes field of the page has focus (#181). Quiz number keys and Return then type text.
    var textEntryFocused: Bool {
        get { self[TextEntryFocusedKey.self] }
        set { self[TextEntryFocusedKey.self] = newValue }
    }

    /// The snapshot harness sets this, so the window opens with the Notes panel open (#181). The app sets none.
    var snapshotShowsNotes: Bool {
        get { self[SnapshotShowsNotesKey.self] }
        set { self[SnapshotShowsNotesKey.self] = newValue }
    }

    /// The snapshot harness sets this, so the second note of the panel opens in edit (#181). The app sets none.
    var snapshotEditsNote: Bool {
        get { self[SnapshotEditsNoteKey.self] }
        set { self[SnapshotEditsNoteKey.self] = newValue }
    }
}

struct CourseNotesView_Previews: PreviewProvider {
    static var previews: some View {
        let lecture = Lecture(id: "welcome", title: "Welcome", type: .video, order: 0, state: .published)
        CourseNotesView(groups: [
            LectureNoteGroup(sectionID: "plan", sectionTitle: "Plan the course", lecture: lecture, notes: [
                LectureNote(id: 1, lectureID: "welcome", text: "The outline lists the sections first.", videoSeconds: 221,
                            createdAt: Date()),
            ]),
        ], open: { _, _ in })
        .frame(width: 720, height: 400)
    }
}
