import SwiftUI
import SkillgardenCore

/// Shared values for the course pages and lecture views.
enum CourseStyle {
    static let spacing: CGFloat = 8
    static let detailPadding: CGFloat = 24
    static let textWidth: CGFloat = 720
    static let cornerRadius: CGFloat = 8
}

extension LectureType {
    var symbolName: String {
        switch self {
        case .video: "play.rectangle"
        case .article: "doc.text"
        case .quiz: "checklist"
        case .assignment: "pencil.and.list.clipboard"
        }
    }
}

struct LibraryRow: View {
    let course: Course

    var body: some View {
        HStack(spacing: CourseStyle.spacing) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 36)
                .background(.quaternary, in: .rect(cornerRadius: CourseStyle.cornerRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: CourseStyle.spacing) {
                Text(course.title).font(.headline).lineLimit(1)
                Text(course.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CourseOutlineView: View {
    let course: Course
    @Binding var selection: CourseDestination?

    private var sections: [CourseSection] { course.learnerSections }

    var body: some View {
        List(selection: $selection) {
            Label("Course Overview", systemImage: "info.circle")
                .tag(CourseDestination.overview)
            ForEach(sections) { section in
                Section {
                    // The section header is a row, so a click selects it and opens the section page.
                    Text(section.title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .tag(CourseDestination.section(sectionID: section.id))
                    ForEach(section.lectures) { lecture in
                        LectureRow(lecture: lecture)
                            .tag(CourseDestination.lecture(sectionID: section.id, lectureID: lecture.id))
                    }
                }
            }
            if sections.allSatisfy({ $0.lectures.isEmpty }) {
                ContentUnavailableView("No lectures yet", systemImage: "list.bullet")
            }
        }
    }
}

struct LectureRow: View {
    let lecture: Lecture

    var body: some View {
        HStack(spacing: CourseStyle.spacing) {
            Image(systemName: lecture.type.symbolName)
                .foregroundStyle(.secondary)
            Text(lecture.title).font(.body).lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lecture.title), \(lecture.type.rawValue)")
    }
}

struct CourseDetailPlaceholder: View {
    let title: String
    let symbol: String
    let titleFont: Font

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CourseStyle.spacing) {
                Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(title).font(titleFont).accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: CourseStyle.textWidth, alignment: .leading)
            .padding(CourseStyle.detailPadding)
            .frame(maxWidth: .infinity)
        }
    }
}
