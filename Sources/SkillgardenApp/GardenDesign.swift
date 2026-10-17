import AppKit
import SwiftUI
import SkillgardenCore

// The Garden design system (`docs/design/garden.html`). Screens use only these tokens and components.

/// Garden type. `gardenTheme(_:)` applies `.fontDesign(.rounded)`, so these fonts draw rounded.
/// Code stays `.monospaced()`. Numbers use `.monospacedDigit()`.
enum GardenFont {
    static let display = Font.system(size: 44, weight: .heavy)
    static let title = Font.system(size: 34, weight: .heavy)
    static let heading = Font.system(size: 26, weight: .heavy)
    static let cardTitle = Font.system(size: 18, weight: .heavy)
    static let body = Font.system(size: 15, weight: .regular)
    static let bodyLineSpacing: CGFloat = 6
    static let label = Font.system(size: 12.5, weight: .heavy)
    static let meta = Font.system(size: 13, weight: .semibold)
}

enum GardenSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 14
    static let m: CGFloat = 20
    static let l: CGFloat = 28
    static let xl: CGFloat = 40
}

/// Corner radii. Use them with `style: .continuous`.
enum GardenRadius {
    static let card: CGFloat = 28
    static let hero: CGFloat = 32
    static let innerBox: CGFloat = 22
    static let image: CGFloat = 18
    static let row: CGFloat = 14
}

extension Shape where Self == RoundedRectangle {
    /// A continuous rounded rectangle with a Garden radius.
    static func garden(_ radius: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

extension ThemeColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    init(hexValue value: Int) {
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// The system accent in sRGB. Core uses it to pick the text color on the accent.
    static var systemAccent: ThemeColor {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return ThemeColor(red: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent)
    }
}

extension CourseAppearance {
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

/// The Garden colors for one accent and color scheme. `gardenTheme(_:)` puts it in the environment.
struct GardenPalette: Equatable, Sendable {
    let colorScheme: ColorScheme
    /// True while a course theme colors the window.
    let isCourseThemed: Bool
    let accent: Color
    /// The text color on an accent fill: white, or ink for light accents.
    let onAccent: Color
    /// The 3D base below primary buttons.
    let accentBase: Color
    let page: Color
    let card: Color
    let soft: Color
    let line: Color
    let ink: Color
    let muted: Color
    /// Only for wrong answers.
    let wrong: Color
    let wrongFill: Color

    /// A nil accent uses the system accent.
    init(accent theme: ThemeColor?, colorScheme: ColorScheme, isCourseThemed: Bool = false) {
        let accent = theme?.color ?? .accentColor
        func tint(_ base: Int, _ fraction: Double) -> Color {
            ThemeColor(hexValue: base).color.mix(with: accent, by: fraction, in: .device)
        }
        self.colorScheme = colorScheme
        self.isCourseThemed = isCourseThemed
        self.accent = accent
        onAccent = (theme ?? .systemAccent).onAccent.color
        accentBase = accent.mix(with: .black, by: 0.4, in: .device)
        wrong = ThemeColor(hexValue: 0xC2412C).color
        if colorScheme == .dark {
            page = tint(0x0F0D16, 0.12)
            card = tint(0x1A1724, 0.10)
            soft = tint(0x1A1724, 0.22)
            line = tint(0x2A2638, 0.22)
            ink = ThemeColor(hexValue: 0xF3F0FA).color
            muted = ThemeColor(hexValue: 0xA9A3BC).color
            wrongFill = card.mix(with: wrong, by: 0.2, in: .device)
        } else {
            page = tint(0xFBFAF7, 0.07)
            card = .white
            soft = tint(0xFFFFFF, 0.12)
            line = tint(0xEEEAE2, 0.18)
            ink = ThemeColor.ink.color
            muted = ThemeColor(hexValue: 0x77716A).color
            wrongFill = ThemeColor(hexValue: 0xFCEDEA).color
        }
    }
}

private struct GardenPaletteKey: EnvironmentKey {
    static var defaultValue: GardenPalette { GardenPalette(accent: nil, colorScheme: .light) }
}

extension EnvironmentValues {
    var gardenPalette: GardenPalette {
        get { self[GardenPaletteKey.self] }
        set { self[GardenPaletteKey.self] = newValue }
    }
}

extension View {
    /// Apply at the window root. A course theme sets the accent and the light or dark look of the whole window.
    /// Without a theme (Library) the window uses the system accent and color scheme.
    func gardenTheme(_ theme: CourseTheme?) -> some View {
        modifier(GardenTheme(theme: theme))
    }

    /// Fills a split view column with the page color while a course theme colors the window.
    func gardenColumn() -> some View {
        modifier(GardenColumn())
    }

    /// A Garden text style: font, line spacing and color.
    func gardenText(_ style: GardenTextStyle) -> some View {
        modifier(GardenText(style: style))
    }

    /// The Garden card surface: card fill, radius 28 and padding.
    func gardenCard(padding: CGFloat = GardenSpacing.m) -> some View {
        modifier(GardenCardSurface(padding: padding))
    }
}

private struct GardenTheme: ViewModifier {
    let theme: CourseTheme?
    @Environment(\.colorScheme) private var systemColorScheme

    func body(content: Content) -> some View {
        let colorScheme = theme?.appearance.colorScheme ?? systemColorScheme
        let palette = GardenPalette(accent: theme?.accent, colorScheme: colorScheme, isCourseThemed: theme != nil)
        content
            .fontDesign(.rounded)
            .tint(palette.accent)
            .environment(\.gardenPalette, palette)
            .environment(\.colorScheme, colorScheme)
            .preferredColorScheme(theme?.appearance.colorScheme)
            // Hide the toolbar material, so the column page colors show below the toolbar.
            .toolbarBackground(theme == nil ? .automatic : .hidden, for: .windowToolbar)
            .background(TransparentTitlebar(isTransparent: theme != nil))
    }
}

/// Makes the window titlebar transparent while a course theme colors the window.
/// The columns fill below the toolbar, so the toolbar shows the page color.
private struct TransparentTitlebar: NSViewRepresentable {
    let isTransparent: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The view gets its window after SwiftUI adds it to the hierarchy.
        DispatchQueue.main.async { [isTransparent] in
            view.window?.titlebarAppearsTransparent = isTransparent
        }
    }
}

private struct GardenColumn: ViewModifier {
    @Environment(\.gardenPalette) private var palette

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(palette.isCourseThemed ? .hidden : .automatic)
            .background {
                if palette.isCourseThemed { SolidFill(color: NSColor(palette.page)).ignoresSafeArea() }
            }
    }
}

/// An opaque AppKit fill. The sidebar material does not blend it, so the page color stays exact.
private struct SolidFill: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.backgroundColor = color.cgColor
    }
}

enum GardenTextStyle {
    case display, title, heading, cardTitle, body, label, meta
}

private struct GardenText: ViewModifier {
    let style: GardenTextStyle
    @Environment(\.gardenPalette) private var palette

    func body(content: Content) -> some View {
        switch style {
        case .display: content.font(GardenFont.display).foregroundStyle(palette.ink)
        case .title: content.font(GardenFont.title).foregroundStyle(palette.ink)
        case .heading: content.font(GardenFont.heading).foregroundStyle(palette.ink)
        case .cardTitle: content.font(GardenFont.cardTitle).foregroundStyle(palette.ink)
        case .body: content.font(GardenFont.body).lineSpacing(GardenFont.bodyLineSpacing).foregroundStyle(palette.ink)
        case .label: content.font(GardenFont.label).foregroundStyle(palette.accent)
        case .meta: content.font(GardenFont.meta).foregroundStyle(palette.muted)
        }
    }
}

private struct GardenCardSurface: ViewModifier {
    let padding: CGFloat
    @Environment(\.gardenPalette) private var palette

    func body(content: Content) -> some View {
        let dark = palette.colorScheme == .dark
        content
            .padding(padding)
            .background(palette.card, in: .garden(GardenRadius.card))
            .overlay {
                if dark { RoundedRectangle.garden(GardenRadius.card).strokeBorder(palette.line, lineWidth: 1) }
            }
            // The mockup shadow is a 30 px CSS blur. A SwiftUI shadow radius is about half a CSS blur.
            .shadow(color: dark ? .clear : palette.accent.opacity(0.10), radius: 15, y: 10)
    }
}

/// A soft Garden card around its content.
struct GardenCard<Content: View>: View {
    var padding: CGFloat = GardenSpacing.m
    @ViewBuilder let content: Content

    var body: some View {
        content.gardenCard(padding: padding)
    }
}

/// The Garden pill button: `.primary` (accent fill with a 3D base) or `.soft` (soft fill), `.regular` or `.small`.
struct GardenButtonStyle: ButtonStyle {
    enum Kind { case primary, soft }
    enum Size { case regular, small }

    var kind: Kind
    var size: Size

    init(_ kind: Kind = .primary, _ size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        GardenButton(configuration: configuration, kind: kind, size: size)
    }
}

extension ButtonStyle where Self == GardenButtonStyle {
    static func garden(_ kind: GardenButtonStyle.Kind = .primary, _ size: GardenButtonStyle.Size = .regular) -> GardenButtonStyle {
        GardenButtonStyle(kind, size)
    }
}

private struct GardenButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: GardenButtonStyle.Kind
    let size: GardenButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        let regular = size == .regular
        let base: CGFloat = kind == .primary && isEnabled ? (regular ? 4 : 3) : 0
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(.system(size: regular ? 15.5 : 13.5, weight: .heavy))
            .lineLimit(1)
            .padding(.horizontal, regular ? 24 : 16)
            .frame(height: regular ? 46 : 36)
            .foregroundStyle(kind == .primary ? palette.onAccent : palette.ink)
            .background(kind == .primary ? palette.accent : palette.soft, in: Capsule())
            .offset(y: pressed ? 3 : 0)
            .background {
                if base > 0 { Capsule().fill(palette.accentBase).offset(y: base) }
            }
            .padding(.bottom, base)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            // Keep the system focus ring, in the pill shape.
            .contentShape(.focusEffect, Capsule())
    }
}

/// Stepping-stone progress: one 10 pt stone per lecture. Rows wrap. VoiceOver reads one summary.
struct SteppingStones: View {
    enum Style {
        case standard
        /// For stones on an accent fill: done is white, todo is white at 30%.
        case onAccent
    }

    let states: [SteppingStone]
    var style: Style = .standard
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        GardenFlowLayout(spacing: 5) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                stone(state)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SteppingStone.accessibilityLabel(states))
    }

    private func stone(_ state: SteppingStone) -> some View {
        let onAccent = style == .onAccent
        let ring: Color = onAccent ? .white : palette.accent
        let fill: Color = switch state {
        case .done: onAccent ? .white : palette.accent
        case .next: onAccent ? palette.accent : palette.card
        case .todo: onAccent ? .white.opacity(0.3) : palette.line
        case .missed: palette.wrong
        }
        return Circle()
            .fill(fill)
            .overlay {
                // The ring is outside the stone, like a CSS box-shadow spread.
                if state == .next { Circle().stroke(ring, lineWidth: 2.5).padding(-1.25) }
            }
            .frame(width: 10, height: 10)
    }
}

/// Places views left to right and wraps them to a new row when the width is used.
struct GardenFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

struct GardenDesign_Previews: PreviewProvider {
    static let stones: [SteppingStone] = Array(repeating: .done, count: 7) + [.next] + Array(repeating: .todo, count: 8)

    static func sample(_ theme: CourseTheme?) -> some View {
        VStack(alignment: .leading, spacing: GardenSpacing.m) {
            Text("SECTION 2").gardenText(.label)
            Text("Plan a course").gardenText(.title)
            Text("7 of 16 lectures · 42 min").gardenText(.meta).monospacedDigit()
            GardenCard {
                VStack(alignment: .leading, spacing: GardenSpacing.s) {
                    Text("Your progress").gardenText(.cardTitle)
                    SteppingStones(states: stones)
                    SteppingStones(states: [.done, .done, .missed, .next, .todo])
                    Text("Each stone is one lecture. Filled stones are done.").gardenText(.body)
                }
            }
            HStack(spacing: GardenSpacing.xs) {
                Button("Resume", systemImage: "play.fill") {}.buttonStyle(.garden())
                Button("Outline") {}.buttonStyle(.garden(.soft))
                Button("Next") {}.buttonStyle(.garden(.primary, .small))
                Button("Skip") {}.buttonStyle(.garden(.soft, .small))
                Button("Locked") {}.buttonStyle(.garden()).disabled(true)
            }
            OnAccentSample(stones: stones)
        }
        .padding(GardenSpacing.l)
        .frame(width: 640)
        .gardenColumn()
        .gardenTheme(theme)
    }

    static var previews: some View {
        Group {
            sample(CourseTheme(accentColor: "#286644", appearance: .light)).previewDisplayName("Course light")
            sample(CourseTheme(accentColor: "#7FD3A0", appearance: .dark)).previewDisplayName("Course dark")
            sample(CourseTheme(accentColor: "#FFD60A", appearance: .light)).previewDisplayName("Low-contrast accent")
            sample(nil).preferredColorScheme(.light).previewDisplayName("Library light")
            sample(nil).preferredColorScheme(.dark).previewDisplayName("Library dark")
        }
    }

    private struct OnAccentSample: View {
        let stones: [SteppingStone]
        @Environment(\.gardenPalette) private var palette

        var body: some View {
            SteppingStones(states: stones, style: .onAccent)
                .padding(GardenSpacing.m)
                .background(palette.accent, in: .garden(GardenRadius.hero))
        }
    }
}
