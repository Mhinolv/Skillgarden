import AppKit
import SwiftUI
import SkillgardenCore

/// Offscreen snapshot harness: `SkillgardenApp --snapshot <out-dir> --fixture <course-folder> [--screen <screen>]`.
/// Renders each `SnapshotScreen` in light and dark mode to `<out-dir>/<screen>-<light|dark>.png`.
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
            for item in SnapshotPlan.reviewAnswers(for: output.screen) { library.answerReview(questionID: item.questionID, choiceID: item.choiceID) }
        }

        let imageLoads = ImageLoadTracker()
        let appearance = NSAppearance(named: output.appearance == .dark ? .darkAqua : .aqua)!
        let content = ContentView(library: library, reloadsOnAppear: false, customRootPath: output.screen.customRootPath)
            .environment(\.locale, Locale(identifier: SnapshotPlan.localeIdentifier))
            .environment(\.timeZone, TimeZone(identifier: SnapshotPlan.timeZoneIdentifier)!)
            .environment(\.imageLoads, imageLoads)
            .environment(\.opensVideoPlayer, output.screen.opensVideoPlayer)
            .environment(\.snapshotVideoStart, output.screen.videoStartSeconds)
            .environment(\.showsReviewInline, true)
            .transaction { $0.disablesAnimations = true; $0.animation = nil }
        let size = NSSize(width: SnapshotPlan.width, height: SnapshotPlan.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = appearance
        window.title = "Skillgarden"
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

        let png = try image(of: frameView, appearance: appearance)
        try png.write(to: output.url, options: .atomic)
        if output.screen.checksTitlebarForVideo {
            // The title bar and the toolbar are the part of the window above the content layout rect.
            let titlebar = window.frame.height - window.contentLayoutRect.maxY
            let rows = Int(titlebar.rounded(.down)) * SnapshotPlan.scale
            let black = SnapshotCheck.blackPixels(png: png, topRows: rows) ?? 0
            if black > 0 { throw SnapshotError.videoOverTitlebar(output.url.lastPathComponent, black) }
        }
    }

    /// Runs the main run loop in short steps until `done` is true or the time limit passes.
    private static func pump(limit: TimeInterval = 10, until done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: limit)
        while !done(), Date() < end {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
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
        NSGraphicsContext.restoreGraphicsState()
        guard let data = result.representation(using: .png, properties: [:]) else { throw SnapshotError.image }
        return data
    }
}

enum SnapshotError: Error, CustomStringConvertible {
    case load(String)
    case image
    case courseImage
    case videoOverTitlebar(String, Int)

    var description: String {
        switch self {
        case let .load(message): "cannot load the snapshot library: \(message)"
        case .image: "cannot create the PNG image"
        case .courseImage: "course image did not load"
        case let .videoOverTitlebar(name, count): "\(name): the video draws \(count) black pixels over the title bar"
        }
    }
}
