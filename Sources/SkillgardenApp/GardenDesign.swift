import AppKit
import SwiftUI
import SkillgardenCore

// The Quiet Garden design system (`docs/design/garden-quiet.html`). Screens use only these tokens and components.
// White surfaces, hairlines and the accent only on the primary action, progress, the current row and focus.

/// Quiet Garden type: the standard system font, weights 600, 500 and 400.
/// Code stays `.monospaced()`. Numbers use `.monospacedDigit()`.
enum GardenFont {
    /// The course title.
    static let display = Font.system(size: 24, weight: .semibold)
    /// The page title: lecture, section, Library and credits.
    static let title = Font.system(size: 20, weight: .semibold)
    /// A quiz question and the empty-state title.
    static let heading = Font.system(size: 15, weight: .semibold)
    static let cardTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyLineSpacing: CGFloat = 3
    static let label = Font.system(size: 11.5, weight: .regular)
    static let meta = Font.system(size: 12, weight: .regular)
    static let small = Font.system(size: 11, weight: .regular)
}

enum GardenSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

/// Corner radii. Use them with `style: .continuous`.
enum GardenRadius {
    static let card: CGFloat = 8
    static let button: CGFloat = 6
    static let image: CGFloat = 6
    static let row: CGFloat = 5
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

    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
    }
}

/// The Quiet Garden colors for one accent and color scheme. `gardenTheme(_:)` puts it in the environment.
struct GardenPalette: Equatable, Sendable {
    let colorScheme: ColorScheme
    /// The accent color, lighter in dark mode. Only the primary action, progress, the current row and focus use it.
    let accent: Color
    /// The accent for small text and icons on a tint: a bit darker in light mode.
    let accentInk: Color
    /// The text color on an accent fill: white, or ink for light accents.
    let onAccent: Color
    /// The content page: white, or #1E1E20 in dark mode.
    let page: Color
    /// The surface of cards and bordered buttons. It is the page color, so a hairline separates it.
    let card: Color
    /// The sidebar column: the accent at 4% (6% in dark mode) on an off-white or dark gray.
    let sidebar: Color
    /// A light accent tint: the objective line, a selected quiz choice and a correct answer.
    let tint: Color
    /// The fill of the selected sidebar row: the accent at 14% (24% in dark mode) on the sidebar gray (#89).
    let selection: Color
    /// A neutral fill: search fields, an "on" toggle button and code blocks.
    let fill: Color
    /// The empty part of a progress stone.
    let track: Color
    /// The 1 pt hairline between surfaces.
    let line: Color
    let ink: Color
    let muted: Color
    let faint: Color
    /// Only for wrong answers.
    let wrong: Color
    let wrongFill: Color

    /// A nil accent uses the system accent. `increasedContrast` selects the stronger neutral tokens (#219).
    init(accent theme: ThemeColor?, colorScheme: ColorScheme, increasedContrast: Bool = false) {
        let shown = theme?.displayAccent(for: CourseAppearance(colorScheme))
        let accent = shown?.color ?? .accentColor
        let dark = colorScheme == .dark
        let neutrals = GardenNeutrals(appearance: CourseAppearance(colorScheme), increasedContrast: increasedContrast)
        func tinted(_ base: Int, _ fraction: Double) -> Color {
            ThemeColor(hexValue: base).color.mix(with: accent, by: fraction, in: .device)
        }
        self.colorScheme = colorScheme
        self.accent = accent
        accentInk = dark ? accent : accent.mix(with: .black, by: 0.15, in: .device)
        onAccent = (shown ?? .systemAccent).onAccent.color
        wrong = ThemeColor(hexValue: 0xC2412C).color
        if dark {
            page = ThemeColor(hexValue: 0x1E1E20).color
            sidebar = tinted(0x262628, 0.06)
            tint = tinted(0x1E1E20, 0.14)
            selection = tinted(0x262628, SidebarSelection.fraction(for: .dark))
            fill = .white.opacity(neutrals.fillOpacity)
            track = .white.opacity(neutrals.trackOpacity)
            line = .white.opacity(neutrals.lineOpacity)
            ink = ThemeColor(hexValue: 0xF2F2F7).color
            wrongFill = page.mix(with: wrong, by: 0.2, in: .device)
        } else {
            page = .white
            sidebar = tinted(0xF4F4F3, 0.04)
            tint = tinted(0xFFFFFF, 0.08)
            selection = tinted(0xF4F4F3, SidebarSelection.fraction(for: .light))
            fill = .black.opacity(neutrals.fillOpacity)
            track = .black.opacity(neutrals.trackOpacity)
            line = .black.opacity(neutrals.lineOpacity)
            ink = ThemeColor.ink.color
            wrongFill = ThemeColor(hexValue: 0xFCEDEA).color
        }
        muted = ThemeColor(hexValue: neutrals.muted).color
        faint = ThemeColor(hexValue: neutrals.faint).color
        card = page
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

/// The column of a split view: the sidebar or the content page.
enum GardenColumnKind {
    case sidebar, page
}

extension View {
    /// Apply at the window root. Every window uses the system accent (#182). The course theme sets only the light or dark look.
    /// `appearance` is the app setting. Dark and Light win over the theme appearance (#93).
    /// System uses the theme, then the system color scheme.
    /// `increasedContrast` overrides the macOS "Increase contrast" setting for the snapshot harness (#219). Nil reads the system.
    func gardenTheme(_ theme: CourseTheme?, appearance: AppAppearance = .system, increasedContrast: Bool? = nil) -> some View {
        modifier(GardenTheme(theme: theme, appearance: appearance, increasedContrast: increasedContrast))
    }

    /// Fills a split view column with the sidebar or the page color.
    func gardenColumn(_ kind: GardenColumnKind = .page) -> some View {
        modifier(GardenColumn(kind: kind))
    }

    /// A Garden text style: font, line spacing and color.
    func gardenText(_ style: GardenTextStyle) -> some View {
        modifier(GardenText(style: style))
    }

    /// The Garden card surface: the card color, radius 8, a hairline and padding. No shadow.
    func gardenCard(padding: CGFloat = GardenSpacing.m) -> some View {
        modifier(GardenCardSurface(padding: padding))
    }
}

private struct GardenTheme: ViewModifier {
    let theme: CourseTheme?
    let appearance: AppAppearance
    let increasedContrast: Bool?
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.colorSchemeContrast) private var systemContrast

    func body(content: Content) -> some View {
        let resolved = appearance.resolved(course: theme?.appearance)
        let colorScheme = resolved?.colorScheme ?? systemColorScheme
        // #182: the manifest accent stays valid but does not color the window. Cover image and title brand a course.
        let palette = GardenPalette(accent: nil, colorScheme: colorScheme,
                                    increasedContrast: increasedContrast ?? (systemContrast == .increased))
        content
            .tint(palette.accent)
            .environment(\.gardenPalette, palette)
            .environment(\.colorScheme, colorScheme)
            .preferredColorScheme(theme == nil ? nil : resolved?.colorScheme)
            // Hide the toolbar material, so the page colors of the Library home and the columns show below the toolbar.
            .toolbarBackground(.hidden, for: .windowToolbar)
            .background(TransparentTitlebar(isTransparent: true))
    }
}

/// Makes the window titlebar transparent. The Library home and the columns fill below the toolbar,
/// so each toolbar band shows the solid color of its column (#101).
private struct TransparentTitlebar: NSViewRepresentable {
    let isTransparent: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The view gets its window after SwiftUI adds it to the hierarchy.
        DispatchQueue.main.async { [isTransparent] in
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = isTransparent
            context.coordinator.observe(window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Hides the titlebar material again when AppKit lays out the toolbar sections:
    /// a window resize, a sidebar toggle or a divider drag.
    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        func observe(_ window: NSWindow) {
            TitlebarMaterial.hide(in: window)
            guard window !== self.window else { return }
            self.window = window
            observers.forEach(NotificationCenter.default.removeObserver)
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated { if let window { TitlebarMaterial.hide(in: window) } }
                },
                // The split view of any window posts it. Only the split view of this window counts.
                center.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) { [weak window] note in
                    let splitView = note.object as? NSView
                    MainActor.assumeIsolated {
                        guard let window, splitView?.window === window else { return }
                        TitlebarMaterial.hide(in: window)
                    }
                },
            ]
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// The AppKit material of the toolbar row (#101). The unified toolbar puts one material view over the sidebar
/// and one over the page. Each one tints and lightens its band, so the toolbar does not match the columns.
@MainActor
enum TitlebarMaterial {
    /// The visible material views in the titlebar of `window`.
    static func visibleViews(in window: NSWindow) -> [NSVisualEffectView] {
        materialViews(in: window).filter { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 }
    }

    /// Hides the material views, so the solid column fills show through the transparent titlebar.
    static func hide(in window: NSWindow) {
        for view in materialViews(in: window) where !view.isHidden { view.isHidden = true }
    }

    /// The material views in the titlebar view: the view of the window buttons, below the toolbar items.
    private static func materialViews(in window: NSWindow) -> [NSVisualEffectView] {
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return [] }
        return titlebar.subviews.compactMap { $0 as? NSVisualEffectView }
    }
}

private struct GardenColumn: ViewModifier {
    let kind: GardenColumnKind
    @Environment(\.gardenPalette) private var palette

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background {
                SolidFill(color: NSColor(kind == .sidebar ? palette.sidebar : palette.page)).ignoresSafeArea()
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
        case .label: content.font(GardenFont.label).foregroundStyle(palette.muted)
        case .meta: content.font(GardenFont.meta).foregroundStyle(palette.muted)
        }
    }
}

private struct GardenCardSurface: ViewModifier {
    let padding: CGFloat
    @Environment(\.gardenPalette) private var palette

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(palette.card, in: .garden(GardenRadius.card))
            .overlay { RoundedRectangle.garden(GardenRadius.card).strokeBorder(palette.line, lineWidth: 1) }
    }
}

/// A Garden card around its content: the card color and a hairline.
struct GardenCard<Content: View>: View {
    var padding: CGFloat = GardenSpacing.m
    @ViewBuilder let content: Content

    var body: some View {
        content.gardenCard(padding: padding)
    }
}

/// The Garden button, radius 6. `.primary` has the accent fill: use it for one action per screen.
/// `.bordered` has the card color and a hairline. `.plain` has muted text only.
/// `.regular` is 28 pt high, `.small` is 24 pt high.
struct GardenButtonStyle: ButtonStyle {
    enum Kind { case primary, bordered, plain }
    enum Size { case regular, small }

    var kind: Kind
    var size: Size
    /// A bordered "on" toggle has the neutral fill.
    var isOn = false

    init(_ kind: Kind = .primary, _ size: Size = .regular, isOn: Bool = false) {
        self.kind = kind
        self.size = size
        self.isOn = isOn
    }

    func makeBody(configuration: Configuration) -> some View {
        GardenButton(configuration: configuration, kind: kind, size: size, isOn: isOn)
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
    let isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.gardenPalette) private var palette

    private var foreground: Color {
        switch kind {
        case .primary: palette.onAccent
        case .bordered: palette.ink
        case .plain: palette.muted
        }
    }

    private var background: Color {
        switch kind {
        case .primary: palette.accent
        case .bordered: isOn ? palette.fill : palette.card
        case .plain: .clear
        }
    }

    var body: some View {
        let regular = size == .regular
        let shape = RoundedRectangle.garden(GardenRadius.button)
        configuration.label
            .font(.system(size: regular ? 12.5 : 12, weight: kind == .primary ? .semibold : .medium))
            .labelStyle(GardenButtonLabelStyle())
            .lineLimit(1)
            .padding(.horizontal, kind == .plain ? 6 : (regular ? 12 : 10))
            .frame(height: regular ? 28 : 24)
            .foregroundStyle(foreground)
            .background(background, in: shape)
            .overlay {
                if kind == .bordered { shape.strokeBorder(palette.line, lineWidth: 1) }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(shape)
            // Keep the system focus ring, in the button shape.
            .contentShape(.focusEffect, shape)
    }
}

/// A 13 pt icon 6 pt before the title, like the mockup buttons.
/// `ToolbarLabelStyle(iconOnly: true)` shows the icon only and keeps the title as the accessibility label (#181).
private struct GardenButtonLabelStyle: LabelStyle {
    @Environment(\.gardenLabelIconOnly) private var iconOnly

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            Label(configuration).labelStyle(.iconOnly).imageScale(.small)
        } else {
            HStack(spacing: 6) {
                configuration.icon.imageScale(.small)
                configuration.title
            }
        }
    }
}

private struct GardenLabelIconOnlyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True draws the icon only in a Garden button label. `ToolbarLabelStyle` sets it, because the button style
    /// replaces the label style of its label.
    var gardenLabelIconOnly: Bool {
        get { self[GardenLabelIconOnlyKey.self] }
        set { self[GardenLabelIconOnlyKey.self] = newValue }
    }
}

/// Stepping-stone progress: one 8 pt stone per lecture. Rows wrap. VoiceOver reads one summary.
struct SteppingStones: View {
    let states: [SteppingStone]
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        GardenFlowLayout(spacing: 4) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                stone(state)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SteppingStone.accessibilityLabel(states))
    }

    private func stone(_ state: SteppingStone) -> some View {
        let fill: Color = switch state {
        case .done: palette.accent
        case .next: palette.card
        case .todo: palette.track
        case .missed: palette.wrong
        }
        return Circle()
            .fill(fill)
            .overlay {
                if state == .next { Circle().strokeBorder(palette.accent, lineWidth: 1.5) }
            }
            .frame(width: 8, height: 8)
    }
}

/// Course progress: one 10 pt stone per section. A stone fills from the bottom as its lectures are done.
/// The first section that is not done has a thin ring. Rows wrap. VoiceOver reads one summary.
struct SectionStones: View {
    let stones: [SectionStone]
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        GardenFlowLayout(spacing: 4) {
            ForEach(Array(stones.enumerated()), id: \.offset) { _, stone in
                self.stone(stone)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SectionStone.accessibilityLabel(stones))
    }

    private func stone(_ stone: SectionStone) -> some View {
        Circle()
            .fill(palette.track)
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    palette.accent.frame(height: geometry.size.height * stone.fraction)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .clipShape(Circle())
            .overlay {
                // The ring is outside the stone, like a CSS box-shadow spread.
                if stone.isNext { Circle().stroke(palette.accent, lineWidth: 1.5).padding(-0.75) }
            }
            .frame(width: 10, height: 10)
    }
}

/// Places views left to right and wraps them to a new row when the width is used.
/// The cache keeps the ideal size of each view, so a layout pass measures each view once (#165).
struct GardenFlowLayout: Layout {
    var spacing: CGFloat

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, sizes: cache)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        var y = bounds.minY
        for row in rows(width: bounds.width, sizes: cache) {
            var x = bounds.minX
            for index in row.indices {
                let size = cache[index]
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

    private func rows(width: CGFloat, sizes: [CGSize]) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, size) in sizes.enumerated() {
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
            Text("Section 2 · Lecture 3").gardenText(.label)
            Text("Plan a course").gardenText(.title)
            Text("7 of 16 lectures · 42 min").gardenText(.meta).monospacedDigit()
            GardenCard {
                VStack(alignment: .leading, spacing: GardenSpacing.s) {
                    Text("Your progress").gardenText(.cardTitle)
                    SteppingStones(states: stones)
                    SteppingStones(states: [.done, .done, .missed, .next, .todo])
                    SectionStones(stones: [SectionStone(completed: 4, total: 4, isNext: false),
                                           SectionStone(completed: 1, total: 3, isNext: true),
                                           SectionStone(completed: 0, total: 5, isNext: false)])
                    Text("Each stone is one lecture. Filled stones are done.").gardenText(.body)
                }
            }
            HStack(spacing: GardenSpacing.xs) {
                Button("Resume", systemImage: "play.fill") {}.buttonStyle(.garden())
                Button("Outline") {}.buttonStyle(.garden(.bordered))
                Button("Captions", systemImage: "captions.bubble") {}.buttonStyle(GardenButtonStyle(.bordered, isOn: true))
                Button("Skip") {}.buttonStyle(.garden(.plain))
                Button("Locked") {}.buttonStyle(.garden()).disabled(true)
            }
        }
        .padding(GardenSpacing.l)
        .frame(width: 640)
        .gardenColumn()
        .gardenTheme(theme)
    }

    static var previews: some View {
        Group {
            // #182: a course window uses the system accent. The manifest accent has no effect.
            sample(CourseTheme(accentColor: "", appearance: .light)).previewDisplayName("Course light")
            sample(CourseTheme(accentColor: "", appearance: .dark)).previewDisplayName("Course dark")
            sample(nil).preferredColorScheme(.light).previewDisplayName("Library light")
            sample(nil).preferredColorScheme(.dark).previewDisplayName("Library dark")
        }
    }
}
