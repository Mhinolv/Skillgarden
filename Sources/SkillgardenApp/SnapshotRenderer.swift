import AppKit
import AVKit
import PDFKit
import SwiftUI
import SkillgardenCore

/// Offscreen snapshot harness: `SkillgardenApp --snapshot <out-dir> --fixture <course-folder> [--screen <screen>]`.
/// Renders each `SnapshotScreen` in light and dark mode to `<out-dir>/<screen>-<light|dark>.png`.
/// Course screens also render in dark mode with no course theme to `<out-dir>/<screen>-unthemed-dark.png`.
/// `--screen` renders only that screen. Repeat it for more screens.
@MainActor
enum SnapshotRenderer {
    static func run(arguments: [String]) -> Int32 {
        guard let outPath = arguments.first, !outPath.hasPrefix("--"),
              let fixtureIndex = arguments.firstIndex(of: "--fixture"), fixtureIndex + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: SkillgardenApp --snapshot <out-dir> --fixture <course-folder> [--screen <screen>]\n".utf8))
            return 2
        }
        var screens: Set<SnapshotScreen>?
        for (index, argument) in arguments.enumerated() where argument == "--screen" {
            guard index + 1 < arguments.count, let screen = SnapshotScreen(rawValue: arguments[index + 1]) else {
                FileHandle.standardError.write(Data("snapshot: unknown screen after --screen\n".utf8))
                return 2
            }
            screens = (screens ?? []).union([screen])
        }
        let outDirectory = URL(fileURLWithPath: outPath).standardizedFileURL
        let fixture = URL(fileURLWithPath: arguments[fixtureIndex + 1])
        do {
            try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
            configureEnvironment()
            let outputs = SnapshotPlan.outputs(outDirectory: outDirectory, screens: screens)
            for output in outputs {
                try render(output, fixture: fixture)
                print(output.url.path)
            }
            print("Wrote \(outputs.count) snapshots to \(outDirectory.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
            return 1
        }
    }

    private static func configureEnvironment() {
        NSTimeZone.default = TimeZone(identifier: SnapshotPlan.timeZoneIdentifier)!
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "NSAutomaticWindowAnimationsEnabled")
        defaults.set(false, forKey: "NSScrollAnimationEnabled")
        defaults.set(Double.greatestFiniteMagnitude, forKey: "NSTextInsertionPointBlinkPeriodOn")
        defaults.set(0, forKey: "NSTextInsertionPointBlinkPeriodOff")
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSAnimationContext.current.duration = 0
    }

    private static func render(_ output: SnapshotPlan.Output, fixture: URL) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SkillgardenSnapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let courseID = try SnapshotPlan.seedStore(for: output.screen, root: root, fixture: fixture)

        let library = LibraryModel(root: root, reviewRandom: SeededRandomNumberGenerator(seed: SnapshotPlan.reviewSeed))
        var loaded = false
        Task { await library.reload(); loaded = true }
        pump { loaded }
        if let message = library.errorMessage { throw SnapshotError.load(message) }
        if let courseID, output.screen.selectsCourse {
            library.selectCourse(courseID)
            library.selectDestination(SnapshotPlan.destination(for: output.screen))
            for action in SnapshotPlan.quizActions(for: output.screen) { library.performQuizAction(action) }
            for id in SnapshotPlan.rubricChecks(for: output.screen) { library.toggleRubricCriterion(id) }
            for item in SnapshotPlan.quickCheckAnswers(for: output.screen) { library.answerQuickCheck(item.checkID, choiceID: item.choiceID) }
            for item in SnapshotPlan.reviewAnswers(for: output.screen) { library.answerReview(questionID: item.questionID, choiceID: item.choiceID) }
            if let query = output.screen.transcriptQuery {
                library.transcriptQuery = query
                library.searchTranscripts()
            }
        }

        let imageLoads = ImageLoadTracker()
        let appearance = NSAppearance(named: output.appearance == .dark ? .darkAqua : .aqua)!
        let content = ContentView(library: library, reloadsOnAppear: false, customRootPath: output.screen.customRootPath,
                                  appearance: output.appearance == .dark ? .dark : .light)
            // The system color scheme of the capture. `GardenTheme` reads it when the window has no course theme (#82).
            // The harness sets it on the content too, so the capture does not depend on the window appearance only.
            .environment(\.colorScheme, output.appearance == .dark ? .dark : .light)
            .environment(\.snapshotIgnoresCourseTheme, output.ignoresCourseTheme)
            .environment(\.locale, Locale(identifier: SnapshotPlan.localeIdentifier))
            .environment(\.timeZone, TimeZone(identifier: SnapshotPlan.timeZoneIdentifier)!)
            .environment(\.imageLoads, imageLoads)
            .environment(\.opensVideoPlayer, output.screen.opensVideoPlayer)
            .environment(\.snapshotVideoStart, output.screen.videoStartSeconds)
            .environment(\.snapshotShowsQuickChecks, output.screen.showsQuickChecks)
            .environment(\.snapshotStartsTheater, output.screen.startsTheater)
            .environment(\.snapshotShowsLandingDetails, output.screen.showsLandingDetails)
            .environment(\.showsReviewInline, true)
            .environment(\.showsPDFPreviewInline, output.screen.showsPDFPreviewInline)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
        let size = NSSize(width: SnapshotPlan.width, height: SnapshotPlan.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = appearance
        window.title = "Skillgarden"
        // The same style as `.windowToolbarStyle(.unifiedCompact(showsTitle: false))` on the app window.
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: content)
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        defer { window.close() }

        let frameView = window.contentView!.superview ?? window.contentView!
        var ticks = 0
        pump { frameView.layoutSubtreeIfNeeded(); ticks += 1; return ticks >= 20 }
        let expected = SnapshotPlan.imageLoads(for: output.screen)
        if expected > 0 {
            // Capture only after all loads end, then let SwiftUI draw the loaded images.
            // An article starts its image loads after its Markdown loads, so wait two times.
            for _ in 0..<2 {
                pump {
                    frameView.layoutSubtreeIfNeeded()
                    return imageLoads.finished >= expected && imageLoads.pending == 0
                }
                ticks = 0
                pump { frameView.layoutSubtreeIfNeeded(); ticks += 1; return ticks >= 5 }
            }
            guard imageLoads.loaded > 0 else { throw SnapshotError.courseImage }
        }
        if output.screen.scrollsLectureToEnd {
            scrollToEnd(in: frameView)
            ticks = 0
            pump { frameView.layoutSubtreeIfNeeded(); ticks += 1; return ticks >= 5 }
        }

        if output.screen.showsPDFPreviewInline {
            // The sheet must create the real PDFKit view with a page, so a blank sheet fails the run.
            func pdfViews(in view: NSView) -> [PDFView] {
                ((view as? PDFView).map { [$0] } ?? []) + view.subviews.flatMap(pdfViews(in:))
            }
            let pdfView = pdfViews(in: frameView).first
            guard let pdfView, pdfView.currentPage != nil, (pdfView.document?.pageCount ?? 0) > 0 else {
                throw SnapshotError.pdfView(output.url.lastPathComponent)
            }
            // PDFKit draws the page into tile layers off the main thread. Wait until a tile has contents.
            pump { frameView.layoutSubtreeIfNeeded(); return hasLayerContents(pdfView.documentView?.layer) }
            guard hasLayerContents(pdfView.documentView?.layer) else { throw SnapshotError.pdfView(output.url.lastPathComponent) }
        }

        if output.screen.opensVideoPlayer { try checkPlayers(in: frameView, output: output) }

        // Theater hides the sidebar, so the outline has no rows to check.
        if output.screen.selectsCourse, output.screen.transcriptQuery == nil, !output.screen.startsTheater {
            for pitch in outlineRowPitches(in: frameView) where abs(pitch - CourseOutlineView.rowHeight) > 0.5 {
                throw SnapshotError.outlineRowPitch(output.url.lastPathComponent, pitch)
            }
        }

        let png = try image(of: frameView, appearance: appearance)
        try png.write(to: output.url, options: .atomic)
        // The title bar and the toolbar are the part of the window above the content layout rect.
        let titlebar = window.frame.height - window.contentLayoutRect.maxY
        if titlebar > maxToolbarHeight { throw SnapshotError.tallToolbar(output.url.lastPathComponent, titlebar) }
        if output.screen.checksTitlebarForVideo {
            let rows = Int(titlebar.rounded(.down)) * SnapshotPlan.scale
            let black = SnapshotCheck.blackPixels(png: png, topRows: rows) ?? 0
            if black > 0 { throw SnapshotError.videoOverTitlebar(output.url.lastPathComponent, black) }
        }
    }

    /// Every player shows the AVKit full-screen button (#85). In theater, the sidebar is hidden and the player is wider than 960 pt.
    private static func checkPlayers(in view: NSView, output: SnapshotPlan.Output) throws {
        func players(in view: NSView) -> [AVPlayerView] {
            ((view as? AVPlayerView).map { [$0] } ?? []) + view.subviews.flatMap(players(in:))
        }
        let name = output.url.lastPathComponent
        let found = players(in: view)
        // A page that scrolls the player out of view can have no player view.
        guard found.allSatisfy(\.showsFullScreenToggleButton) else { throw SnapshotError.fullScreenButton(name) }
        guard output.screen.startsTheater else { return }
        guard let player = found.first else { throw SnapshotError.theaterPlayer(name, .zero) }
        let frame = player.convert(player.bounds, to: nil)
        // The narrowest sidebar is 260 pt, so a player that starts left of it has no sidebar next to it.
        if frame.width <= TheaterMode.videoWidth || frame.minX >= 260 { throw SnapshotError.theaterPlayer(name, frame) }
    }

    /// The compact toolbar row is about 38 pt. The default style makes a 52 pt row below the window buttons.
    private static let maxToolbarHeight: CGFloat = 40

    /// Runs the main run loop in short steps until `done` is true or the time limit passes.
    private static func pump(limit: TimeInterval = 10, until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: limit)
        while !done(), Date() < end {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// The distance from the top of one outline row to the top of the next row, for each row after the course card.
    /// The outline is the table view nearest to the left edge of the window.
    private static func outlineRowPitches(in view: NSView) -> [CGFloat] {
        func tableViews(in view: NSView) -> [NSTableView] {
            ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tableViews(in:))
        }
        guard let outline = tableViews(in: view).min(by: {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }) else { return [] }
        // The course card is the tallest row. The rows after it are "Course Overview", the sections, the lectures and "Credits".
        let rows = 0..<outline.numberOfRows
        guard let card = rows.max(by: { outline.rect(ofRow: $0).height < outline.rect(ofRow: $1).height }),
              card + 2 < outline.numberOfRows else { return [] }
        return (card + 1..<outline.numberOfRows - 1).map { outline.rect(ofRow: $0 + 1).minY - outline.rect(ofRow: $0).minY }
    }

    /// Scrolls the scroll view with the most hidden content (the lecture page) to its end.
    /// The sidebar list and the transcript panel scroll less, so they stay as they are.
    private static func scrollToEnd(in view: NSView) {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
        }
        func hiddenHeight(_ scrollView: NSScrollView) -> CGFloat {
            (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
        }
        guard let scrollView = scrollViews(in: view).max(by: { hiddenHeight($0) < hiddenHeight($1) }),
              let document = scrollView.documentView, hiddenHeight(scrollView) > 0 else { return }
        let clip = scrollView.contentView
        let y = document.isFlipped ? document.frame.height - clip.bounds.height : 0
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private static func image(of view: NSView, appearance: NSAppearance) throws -> Data {
        let scale = SnapshotPlan.scale
        guard let capture = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: SnapshotPlan.width * scale, pixelsHigh: SnapshotPlan.height * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let result = capture.copy() as? NSBitmapImageRep else { throw SnapshotError.image }
        capture.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: capture)

        // Put the capture on the window background so translucent sidebar areas are opaque.
        result.size = view.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: result)
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        capture.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: false, hints: nil)
        if let context = NSGraphicsContext.current?.cgContext { drawPDFPages(in: view, of: view, to: context) }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = result.representation(using: .png, properties: [:]) else { throw SnapshotError.image }
        return data
    }

    /// True when a layer in the tree has contents. The PDFKit tiles of a drawn page have contents.
    private static func hasLayerContents(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        return layer.contents != nil || (layer.sublayers ?? []).contains { hasLayerContents($0) }
    }

    /// Draws the visible pages of each PDF view at the place that the view shows them.
    /// `cacheDisplay` reads the IOSurface tiles of PDFKit as one solid color, so the capture misses the page.
    private static func drawPDFPages(in view: NSView, of root: NSView, to context: CGContext) {
        if let pdfView = view as? PDFView {
            let visible = pdfView.convert(pdfView.visibleRect, to: root)
            for page in pdfView.visiblePages {
                let box = page.bounds(for: pdfView.displayBox)
                var rect = pdfView.convert(pdfView.convert(box, from: page), to: root)
                // The capture has its origin at the bottom left.
                var clip = visible
                if root.isFlipped {
                    rect.origin.y = root.bounds.height - rect.maxY
                    clip.origin.y = root.bounds.height - clip.maxY
                }
                context.saveGState()
                context.clip(to: clip)
                context.translateBy(x: rect.minX, y: rect.minY)
                context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
                context.setFillColor(.white)
                context.fill(CGRect(origin: .zero, size: box.size))
                page.draw(with: pdfView.displayBox, to: context)
                context.restoreGState()
            }
        }
        for subview in view.subviews where !subview.isHidden { drawPDFPages(in: subview, of: root, to: context) }
    }
}

enum SnapshotError: Error, CustomStringConvertible {
    case load(String)
    case image
    case courseImage
    case videoOverTitlebar(String, Int)
    case pdfView(String)
    case tallToolbar(String, CGFloat)
    case outlineRowPitch(String, CGFloat)
    case fullScreenButton(String)
    case theaterPlayer(String, NSRect)

    var description: String {
        switch self {
        case let .load(message): "cannot load the snapshot library: \(message)"
        case .image: "cannot create the PNG image"
        case .courseImage: "course image did not load"
        case let .videoOverTitlebar(name, count): "\(name): the video draws \(count) black pixels over the title bar"
        case let .pdfView(name): "\(name): the PDF preview sheet has no PDFKit view with a drawn page"
        case let .tallToolbar(name, height): "\(name): the toolbar row is \(Int(height)) pt high, not the compact row"
        case let .outlineRowPitch(name, pitch): "\(name): the outline rows are \(pitch) pt apart, not \(CourseOutlineView.rowHeight) pt"
        case let .fullScreenButton(name): "\(name): a video player has no full-screen button"
        case let .theaterPlayer(name, frame): "\(name): the theater player frame is \(frame), not wider than 960 pt next to the window edge"
        }
    }
}
