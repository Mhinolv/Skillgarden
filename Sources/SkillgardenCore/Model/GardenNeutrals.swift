import Foundation

/// The neutral tokens of the Quiet Garden palette: hairline, progress track, neutral fill and the two secondary text colors.
/// The macOS "Increase contrast" setting selects stronger values (#219). The accent, ink, page, tint and wrong colors stay.
public struct GardenNeutrals: Equatable, Sendable {
    /// The opacity of black (white in dark mode) for the 1 pt hairline.
    public let lineOpacity: Double
    /// The opacity of black (white in dark mode) for the empty part of a progress stone.
    public let trackOpacity: Double
    /// The opacity of black (white in dark mode) for the neutral fill.
    public let fillOpacity: Double
    /// The secondary text color as `0xRRGGBB`.
    public let muted: Int
    /// The tertiary text color as `0xRRGGBB`.
    public let faint: Int

    /// Default contrast gives the values from before #219, bit for bit.
    public init(appearance: CourseAppearance, increasedContrast: Bool) {
        switch (appearance, increasedContrast) {
        case (.light, false):
            (lineOpacity, trackOpacity, fillOpacity, muted, faint) = (0.08, 0.09, 0.045, 0x6E6E73, 0xAEAEB2)
        case (.light, true):
            (lineOpacity, trackOpacity, fillOpacity, muted, faint) = (0.30, 0.22, 0.08, 0x48484D, 0x6E6E73)
        case (.dark, false):
            (lineOpacity, trackOpacity, fillOpacity, muted, faint) = (0.08, 0.16, 0.06, 0x98989D, 0x5E5E63)
        case (.dark, true):
            (lineOpacity, trackOpacity, fillOpacity, muted, faint) = (0.32, 0.32, 0.12, 0xC7C7CC, 0x98989D)
        }
    }
}
