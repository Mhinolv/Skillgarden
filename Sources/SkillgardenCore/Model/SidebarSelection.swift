import Foundation

extension CourseAppearance {
    /// The sidebar color: the page color of the Library home, white or `#1E1E20` in dark mode (#246).
    public var sidebarBase: ThemeColor {
        switch self {
        case .light: ThemeColor(red: 1, green: 1, blue: 1)
        case .dark: ThemeColor(red: 0x1E / 255, green: 0x1E / 255, blue: 0x20 / 255)
        }
    }
}

/// The quiet fill behind the selected outline row (#89): a soft tint of the accent, not the system selection blue.
/// The row keeps its ink text, so the fill must stay light in light mode and dark in dark mode.
public enum SidebarSelection {
    /// The part of the accent in the fill: 14%, or 24% in dark mode.
    public static func fraction(for appearance: CourseAppearance) -> Double {
        appearance == .dark ? 0.24 : 0.14
    }

    /// The fill: the shown accent at `fraction(for:)` on the sidebar base.
    public static func color(accent: ThemeColor, appearance: CourseAppearance) -> ThemeColor {
        appearance.sidebarBase.mixed(with: accent.displayAccent(for: appearance), by: fraction(for: appearance))
    }

    /// The Quiet Garden text color on the sidebar: `#1D1D1F`, or `#F2F2F7` in dark mode.
    public static func ink(for appearance: CourseAppearance) -> ThemeColor {
        appearance == .dark ? ThemeColor(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF7 / 255) : .ink
    }
}
