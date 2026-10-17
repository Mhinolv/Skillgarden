import SwiftUI
import SkillgardenCore

/// The content block of an assignment lecture: the metadata row, the Markdown brief in a card, then the self-check rubric.
struct AssignmentLectureView: View {
    let assignment: LectureAssignment?
    let checklist: RubricChecklist?
    let toggle: (String) -> Void
    let reset: () -> Void
    @Environment(\.imageLoads) private var imageLoads
    @State private var brief: RenderedMarkdown?
    @State private var briefUnavailable = false

    var body: some View {
        Group {
            if let assignment, let checklist {
                VStack(alignment: .leading, spacing: 12) {
                    Label(assignment.meta, systemImage: LectureType.assignment.symbolName)
                        .gardenText(.meta)
                    GardenCard(padding: GardenSpacing.l) { briefContent }
                    RubricView(checklist: checklist, toggle: toggle, reset: reset)
                        .padding(.top, 12)
                }
            } else {
                ContentUnavailableView("Assignment unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Publish the course again to restore this assignment."))
            }
        }
        .task(id: assignment?.brief) {
            brief = nil
            briefUnavailable = false
            guard let article = assignment?.brief else { briefUnavailable = true; return }
            imageLoads?.start()
            // Read and parse the file off the main actor.
            let loaded = await Task.detached { try? RenderedMarkdown(article: article) }.value
            brief = loaded
            briefUnavailable = loaded == nil
            imageLoads?.finish(loaded: loaded != nil)
        }
    }

    @ViewBuilder private var briefContent: some View {
        if let brief {
            MarkdownBlocksView(markdown: brief)
        } else if briefUnavailable {
            ContentUnavailableView("Brief unavailable", systemImage: "exclamationmark.triangle")
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }
}

/// The self-check rubric: one checkbox per criterion with its guidance, then the summary line and Reset.
/// The checks stay for the app session only.
struct RubricView: View {
    let checklist: RubricChecklist
    let toggle: (String) -> Void
    let reset: () -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
            Label("Self-check rubric", systemImage: "checklist")
                .gardenText(.cardTitle)
            Text("Check each criterion that your work meets.")
                .font(.subheadline)
                .foregroundStyle(palette.muted)
            GardenCard {
                VStack(alignment: .leading, spacing: GardenSpacing.s) {
                    ForEach(Array(checklist.rubric.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        RubricRow(row: row, isChecked: checklist.isChecked(row.id)) { toggle(row.id) }
                    }
                }
            }
            .padding(.top, GardenSpacing.xxs)
            summary.padding(.top, GardenSpacing.xxs)
        }
    }

    private var summary: some View {
        HStack(spacing: GardenSpacing.s) {
            if checklist.allMet {
                Label {
                    Text("You met every criterion.")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                .font(.subheadline)
                .foregroundStyle(palette.ink)
            } else {
                Text(checklist.summary)
                    .font(.subheadline)
                    .foregroundStyle(palette.ink)
            }
            ProgressView(value: Double(checklist.metCount), total: Double(max(checklist.rubric.count, 1)))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(palette.accent)
                .frame(maxWidth: 160)
                .accessibilityLabel(checklist.summary)
            Spacer()
            // No confirmation: the checks are session-only.
            Button("Reset", action: reset)
                .buttonStyle(.borderless)
                .disabled(checklist.metCount == 0)
        }
    }
}

/// One rubric row. A click on the checkbox or the criterion text toggles it. Space toggles the focused checkbox.
private struct RubricRow: View {
    let row: RubricCriterion
    let isChecked: Bool
    let toggle: () -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        Toggle(isOn: Binding(get: { isChecked }, set: { if $0 != isChecked { toggle() } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.criterion)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.ink)
                Text(row.guidance)
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
        .tint(palette.accent)
        .accessibilityLabel(row.criterion)
        .accessibilityHint(row.guidance)
    }
}

struct AssignmentViews_Previews: PreviewProvider {
    static let rubric = [
        RubricCriterion(id: "goal", criterion: "The plan states one course goal",
                        guidance: "Write the goal in one sentence that names the skill."),
        RubricCriterion(id: "order", criterion: "The lectures are in a clear order",
                        guidance: "Each lecture builds on the lecture before it."),
    ]

    static var previews: some View {
        Group {
            RubricView(checklist: RubricChecklist(rubric: rubric, checked: ["goal"]), toggle: { _ in }, reset: {})
            RubricView(checklist: RubricChecklist(rubric: rubric, checked: ["goal", "order"]), toggle: { _ in }, reset: {})
        }
        .padding()
        .frame(width: 720)
    }
}
