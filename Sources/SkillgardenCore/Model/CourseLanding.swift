import Foundation

/// An sRGB color with components from 0 to 1.
public struct ThemeColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Reads `#RRGGBB`. Returns nil for any other form.
    public init?(hex: String) {
        let digits = hex.dropFirst()
        guard hex.first == "#", digits.count == 6, digits.allSatisfy(\.isHexDigit),
              let value = Int(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// WCAG 2 relative luminance.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio, from 1 to 21.
    public func contrastRatio(with other: ThemeColor) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public static let white = ThemeColor(red: 1, green: 1, blue: 1)
    /// The Garden ink `#211F1A`.
    public static let ink = ThemeColor(red: 0x21 / 255, green: 0x1F / 255, blue: 0x1A / 255)

    /// The text color on a fill of this color: white if it has 3:1 contrast or more, else ink.
    public var onAccent: ThemeColor {
        contrastRatio(with: .white) >= CourseTheme.minimumAccentContrast ? .white : .ink
    }
}

public enum CourseAppearance: String, Equatable, Sendable {
    case light, dark

    /// The Garden page base for this appearance, before the accent tint. The accent contrast check uses it.
    public var background: ThemeColor {
        switch self {
        case .light: ThemeColor(red: 0xFB / 255, green: 0xFA / 255, blue: 0xF7 / 255)
        case .dark: ThemeColor(red: 0x0F / 255, green: 0x0D / 255, blue: 0x16 / 255)
        }
    }
}

/// The resolved look of a course. A nil accent means the system accent.
public struct CourseTheme: Equatable, Sendable {
    public static let minimumAccentContrast = 3.0

    public let appearance: CourseAppearance
    public let accent: ThemeColor?

    /// Uses the system accent if `accentColor` is not `#RRGGBB` or has less than 3:1 contrast on the background.
    public init(accentColor: String, appearance: CourseAppearance) {
        self.appearance = appearance
        let color = ThemeColor(hex: accentColor)
        accent = color.flatMap { $0.contrastRatio(with: appearance.background) >= Self.minimumAccentContrast ? $0 : nil }
    }
}

/// The course page fields of an installed manifest.
public struct CourseLanding: Equatable, Sendable {
    public let description: String
    public let learningOutcomes: [String]
    public let requirements: [String]
    public let targetAudience: String
    public let theme: CourseTheme

    public init(manifest: CourseManifest) {
        func clean(_ items: [String]) -> [String] {
            items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        description = manifest.description.trimmingCharacters(in: .whitespacesAndNewlines)
        learningOutcomes = clean(manifest.learningOutcomes)
        requirements = clean(manifest.requirements)
        targetAudience = manifest.targetAudience.trimmingCharacters(in: .whitespacesAndNewlines)
        theme = CourseTheme(accentColor: manifest.theme.accentColor,
                            appearance: manifest.theme.appearance == .dark ? .dark : .light)
    }
}

extension Course {
    /// The first learner lecture, which "Start Course" opens. Nil if the course has no learner lecture.
    public var firstLecture: CourseDestination? {
        learnerLectures.first.map { .lecture(sectionID: $0.sectionID, lectureID: $0.lecture.id) }
    }
}
