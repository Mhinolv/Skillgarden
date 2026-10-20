import AppKit
@testable import SkillgardenCore

/// The system accent in sRGB for a light or dark window, as the app draws it (#182).
/// The app uses `Color.accentColor` with no `displayAccent` change, so the snapshot tests compare with this color.
func systemAccent(for appearance: CourseAppearance) -> ThemeColor {
    var accent = ThemeColor(red: 0, green: 0x7A / 255, blue: 1)
    NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        if let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
            accent = ThemeColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
        }
    }
    return accent
}
