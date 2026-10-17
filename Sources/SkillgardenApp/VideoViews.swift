import AppKit
import AVKit
import SwiftUI
import SkillgardenCore

/// The "Free preview" capsule of the lecture header and the lecture rows.
/// In a row the capsule is filled, so it stays readable on a gray or dark selected row.
/// On an accent-colored selected row the capsule uses white.
struct FreePreviewBadge: View {
    var filled = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let selected = prominence == .increased
        Text("Free preview")
            .font(.caption.weight(.semibold))
            .foregroundStyle(selected || filled ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(selected ? AnyShapeStyle(.white.opacity(0.25))
                        : filled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.15)), in: .capsule)
            .fixedSize()
            .accessibilityLabel("Free preview")
    }
}

/// Owns the player of one video lecture.
/// The caption text and the active transcript line change only when the cue changes, not on each time tick.
@MainActor @Observable
final class VideoPlayback {
    let player: AVPlayer
    private(set) var captionText: String?
    /// The index of the active line in `transcript`.
    private(set) var activeLine: Int?
    /// Goes up by one each time playback reaches the end of the video.
    private(set) var endCount = 0
    @ObservationIgnored private let captions: WebVTT?
    @ObservationIgnored private let transcript: Transcript?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lastSaved: Double = 0
    @ObservationIgnored private var pendingSeeks = 0
    @ObservationIgnored private let save: @MainActor (Double) -> Void

    /// `save` gets the position every `PlaybackResume.saveInterval` seconds, on pause and on `stop()`.
    /// If `plays` is false, the player opens paused (the snapshot harness).
    init(url: URL, start: Double, captions: WebVTT?, transcript: Transcript?, plays: Bool = true,
         save: @escaping @MainActor (Double) -> Void) {
        player = AVPlayer(url: url)
        self.captions = captions
        self.transcript = transcript
        self.save = save
        lastSaved = start
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        update(at: start)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                if self.pendingSeeks == 0 { self.update(at: time.seconds) }
                if abs(time.seconds - self.lastSaved) >= PlaybackResume.saveInterval {
                    self.lastSaved = time.seconds
                    self.save(time.seconds)
                }
            }
        }
        statusObserver = player.observe(\.timeControlStatus) { [weak self] player, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, player.timeControlStatus == .paused else { return }
                    self.saveCurrentTime()
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endCount += 1 }
        }
        if plays { player.play() }
    }

    /// Seeks exactly to `seconds` and plays. A click on a transcript line calls it.
    /// Time ticks during a seek can show the old time, so they do not change the active line until the seek ends.
    func seek(to seconds: Double) {
        pendingSeeks += 1
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pendingSeeks -= 1 }
            }
        }
        update(at: seconds)
        player.play()
    }

    private func update(at seconds: Double) {
        let text = captions?.text(at: seconds)
        if text != captionText { captionText = text }
        let line = transcript?.activeLine(at: seconds)
        if line != activeLine { activeLine = line }
    }

    /// Pauses the player, saves the position and removes the observers.
    func stop() {
        statusObserver?.invalidate()
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        saveCurrentTime()
    }

    private func saveCurrentTime() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        lastSaved = seconds
        save(seconds)
    }
}

/// The content block of a video lecture: the metadata row, the player, the controls row, the transcript and the quick checks.
/// Before the first play the poster shows with a play button. The player starts on a click or Space.
/// The quick-check card is hidden when the lecture opens. It shows at the video end or from the "Quick Check" button.
struct VideoLectureView: View {
    let video: LectureVideo?
    /// Nil when the video has no quick checks.
    var quickChecks: QuickCheckSession?
    var answerQuickCheck: (Int, String) -> Void = { _, _ in }
    var retryQuickCheck: (Int) -> Void = { _ in }
    /// The seek time for the first play.
    let startSeconds: @MainActor () -> Double
    let saveResumePosition: @MainActor @Sendable (Double) -> Void
    /// The window keeps this choice for all lectures. View > Show Transcript changes it too.
    @Binding var showsTranscript: Bool
    @Environment(\.imageLoads) private var imageLoads
    @Environment(\.opensVideoPlayer) private var opensVideoPlayer
    @Environment(\.snapshotVideoStart) private var snapshotVideoStart
    @Environment(\.snapshotShowsQuickChecks) private var snapshotShowsQuickChecks
    @Environment(\.lectureScrollProxy) private var scrollProxy
    @Environment(\.pageVisibleTop) private var pageVisibleTop
    @State private var poster: NSImage?
    @State private var available: Bool?
    @State private var captions: WebVTT?
    @State private var transcript: Transcript?
    @State private var playback: VideoPlayback?
    @State private var showsCaptions = true
    @State private var showsQuickChecks = false

    private static let maxWidth: CGFloat = 960

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let video {
                HStack(spacing: CourseStyle.spacing) {
                    Label(video.metadataLabel, systemImage: LectureType.video.symbolName)
                        .gardenText(.meta)
                    if video.isFreePreview { FreePreviewBadge() }
                }
            }
            if available == false || video == nil {
                ContentUnavailableView("Video unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Publish the course again to restore this file."))
            } else {
                player
                if hasCaptions || quickChecks != nil {
                    HStack(spacing: GardenSpacing.xs) {
                        if hasCaptions {
                            Group {
                                Toggle(isOn: $showsCaptions) { Label("Captions", systemImage: "captions.bubble") }
                                Toggle(isOn: $showsTranscript) { Label("Transcript", systemImage: "text.quote") }
                                    .help(showsTranscript ? "Hide Transcript (⌥⌘T)" : "Show Transcript (⌥⌘T)")
                            }
                            .toggleStyle(GardenPillToggleStyle())
                            .disabled(captions == nil)
                        }
                        Spacer()
                        if let quickChecks {
                            Button(action: openQuickChecks) { Label(quickChecks.buttonTitle, systemImage: "checkmark.bubble") }
                                .buttonStyle(.garden(.soft, .small))
                        }
                    }
                    .frame(maxWidth: Self.maxWidth)
                }
                if hasCaptions, showsTranscript, let transcript {
                    TranscriptPanel(transcript: transcript, activeLine: playback?.activeLine, seek: seek)
                        .frame(maxWidth: Self.maxWidth)
                }
                if showsQuickChecks, let quickChecks {
                    QuickCheckCard(session: quickChecks, answer: answerQuickCheck, retry: retryQuickCheck)
                        .frame(maxWidth: Self.maxWidth)
                        .id(QuickCheckCard.scrollID)
                }
            }
        }
        .focusedSceneValue(\.showsTranscript, hasCaptions ? $showsTranscript : nil)
        .task(id: video) { await load() }
        .onChange(of: playback?.endCount) { _, count in
            if let count, count > 0 { openQuickChecks() }
        }
        .onDisappear { playback?.stop() }
    }

    /// Shows the quick-check card and scrolls it into view after the next layout.
    private func openQuickChecks() {
        guard quickChecks != nil else { return }
        showsQuickChecks = true
        let proxy = scrollProxy
        DispatchQueue.main.async {
            withAnimation { proxy?.scrollTo(QuickCheckCard.scrollID, anchor: .bottom) }
        }
    }

    /// False hides the Captions and Transcript toggles and the transcript.
    private var hasCaptions: Bool { video?.captionsURL != nil && available != false }

    private var player: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let playback {
                    PlayerView(player: playback.player)
                        .overlay {
                            if showsCaptions, let text = playback.captionText { CaptionOverlay(text: text) }
                        }
                } else {
                    posterView
                }
            }
            .clipShape(.garden(24))
            .mask { PageTopClip(visibleTop: pageVisibleTop) }
            .frame(maxWidth: Self.maxWidth)
    }

    private var posterView: some View {
        ZStack {
            if let poster {
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel(video?.posterAlt ?? "")
            }
            if available == nil {
                ProgressView().controlSize(.small)
            } else {
                Button(action: play) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white)
                        .shadow(radius: 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel("Play video")
            }
        }
    }

    private func play() {
        guard let video, playback == nil else { return }
        playback = VideoPlayback(url: video.url, start: snapshotVideoStart ?? startSeconds(), captions: captions, transcript: transcript,
                                 plays: !opensVideoPlayer, save: saveResumePosition)
    }

    /// Seeks to the start of the line and plays. Before the first play, the player starts at the line.
    private func seek(_ line: Transcript.Line) {
        if let playback {
            playback.seek(to: line.start)
        } else if let video, available == true {
            playback = VideoPlayback(url: video.url, start: line.start, captions: captions, transcript: transcript,
                                     save: saveResumePosition)
        }
    }

    /// Checks the video file and reads the poster and the captions off the main actor.
    private func load() async {
        playback?.stop()
        playback = nil
        poster = nil
        captions = nil
        transcript = nil
        available = nil
        guard let video else { return }
        imageLoads?.start()
        let (exists, posterData, cues) = await Task.detached {
            (FileManager.default.fileExists(atPath: video.url.path),
             video.posterURL.flatMap { try? Data(contentsOf: $0) },
             try? video.loadCaptions())
        }.value
        poster = posterData.flatMap(NSImage.init(data:))
        captions = cues
        transcript = cues.map(Transcript.init(captions:))
        available = exists
        if exists && opensVideoPlayer { play() }
        if snapshotShowsQuickChecks { showsQuickChecks = true }
        imageLoads?.finish(loaded: exists)
    }
}

private struct OpensVideoPlayerKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The snapshot harness sets this, so a video lecture opens its player, paused, after the load. The app sets none.
    var opensVideoPlayer: Bool {
        get { self[OpensVideoPlayerKey.self] }
        set { self[OpensVideoPlayerKey.self] = newValue }
    }

    /// The snapshot harness sets this, so the paused player opens at a fixed time instead of the saved position.
    var snapshotVideoStart: Double? {
        get { self[SnapshotVideoStartKey.self] }
        set { self[SnapshotVideoStartKey.self] = newValue }
    }
}

private struct SnapshotVideoStartKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

private struct PageVisibleTopKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The bottom edge of the toolbar in global coordinates. The lecture page sets it. Nil shows the whole player.
    var pageVisibleTop: CGFloat? {
        get { self[PageVisibleTopKey.self] }
        set { self[PageVisibleTopKey.self] = newValue }
    }
}

/// The mask of the player block: it hides the part above the toolbar bottom (#55).
/// The lecture page scrolls under the transparent title bar, and the black player must not cover the window title.
/// Only this mask reads the scroll position, so a scroll publishes no state.
private struct PageTopClip: View {
    let visibleTop: CGFloat?

    var body: some View {
        if let visibleTop {
            GeometryReader { proxy in
                let hidden = PlayerClip.hiddenTop(playerMinY: proxy.frame(in: .global).minY, height: proxy.size.height,
                                                  visibleTop: visibleTop)
                Rectangle().padding(.top, hidden)
            }
        } else {
            Rectangle()
        }
    }
}

/// The AVKit player view with inline controls.
/// SwiftUI `VideoPlayer` crashes on macOS 15 when the app is built with the macOS 26 SDK (#42), so do not use it.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}

/// A small Garden pill for an on and off toggle: primary when on, soft when off.
struct GardenPillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(.garden(configuration.isOn ? .primary : .soft, .small))
            .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// The text of the current cue over the bottom of the video.
struct CaptionOverlay: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.title3)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: .rect(cornerRadius: 6))
                .padding(.horizontal, 24)
                .padding(.bottom, 56)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

/// The interactive transcript under the controls row. A click on a line seeks the player to the line start and plays.
/// The panel scrolls to keep the active line in view. After the learner scrolls the panel, auto-scroll stops for 5 seconds.
struct TranscriptPanel: View {
    let transcript: Transcript
    let activeLine: Int?
    let seek: (Transcript.Line) -> Void
    @Environment(\.gardenPalette) private var palette
    @State private var autoScroll = TranscriptAutoScroll()
    @State private var learnerScrolls = false

    static let height: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: GardenSpacing.xs) {
            Text("Transcript")
                .font(.headline)
                .foregroundStyle(palette.ink)
            if transcript.lines.isEmpty {
                Text("No transcript for this lecture.")
                    .foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                lines
            }
        }
        .gardenCard(padding: GardenSpacing.s)
    }

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(transcript.lines) { line in
                        TranscriptRow(line: line, isActive: line.id == activeLine) { seek(line) }
                            .id(line.id)
                    }
                }
            }
            .frame(height: Self.height)
            .onScrollPhaseChange { old, new in
                // `.animating` is a scroll from `scrollTo`. The other moving phases come from the learner.
                learnerScrolls = new == .interacting || new == .decelerating
                if learnerScrolls || old == .interacting || old == .decelerating { autoScroll.learnerScrolled(at: .now) }
            }
            .onChange(of: activeLine) { _, line in
                guard let line, !learnerScrolls, autoScroll.allowsAutoScroll(at: .now) else { return }
                withAnimation { proxy.scrollTo(line, anchor: .center) }
            }
            .onAppear {
                if let activeLine { proxy.scrollTo(activeLine, anchor: .center) }
            }
        }
    }
}

/// One transcript line: the start time and the cue text. Each line is a button for the keyboard and VoiceOver.
private struct TranscriptRow: View {
    let line: Transcript.Line
    let isActive: Bool
    let action: () -> Void
    @Environment(\.gardenPalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: GardenSpacing.xs) {
                Text(line.timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? palette.accent : palette.muted)
                    .frame(width: 48, alignment: .leading)
                Text(line.text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(TranscriptRowStyle(isActive: isActive))
        .accessibilityLabel(line.accessibilityLabel)
        .accessibilityHint("Jumps to this moment.")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct TranscriptRowStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        TranscriptRowBody(configuration: configuration, isActive: isActive)
    }
}

/// Default: no fill. Hover: quaternary fill and a hand pointer. Active: accent fill at 15% and the time in accent.
private struct TranscriptRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool
    @Environment(\.gardenPalette) private var palette
    @State private var hovers = false

    var body: some View {
        // The time label sets its own color: the muted color, or the accent on the active line.
        configuration.label
            .foregroundStyle(palette.ink)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 6).fill(palette.accent.opacity(0.15))
                } else if hovers {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.rect(cornerRadius: 6))
            .contentShape(.focusEffect, .rect(cornerRadius: 6))
            .onHover { hovers = $0 }
            .pointerStyle(.link)
    }
}

private struct ShowsTranscriptFocusKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    /// Set while a video lecture with captions shows. View > Show Transcript uses it.
    var showsTranscript: Binding<Bool>? {
        get { self[ShowsTranscriptFocusKey.self] }
        set { self[ShowsTranscriptFocusKey.self] = newValue }
    }
}
