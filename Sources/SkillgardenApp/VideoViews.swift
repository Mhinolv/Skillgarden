import AppKit
import AVKit
import SwiftUI
import SkillgardenCore

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
    /// Goes up by one each time the player starts to play. A play stops the "Up next" countdown (#99).
    private(set) var playCount = 0
    @ObservationIgnored private let captions: WebVTT?
    @ObservationIgnored private let transcript: Transcript?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lastSaved: Double = 0
    @ObservationIgnored private var pendingSeeks = 0
    @ObservationIgnored private var autoCompleteTicks = VideoAutoComplete()
    @ObservationIgnored private let save: @MainActor (Double) -> Void
    @ObservationIgnored private let complete: @MainActor () -> Void

    /// `save` gets the position every `PlaybackResume.saveInterval` seconds, on pause and on `stop()`.
    /// `complete` runs when play passes 90% of `duration` or reaches the end (#79). The item duration replaces `duration` when it is known.
    /// If `plays` is false, the player opens paused (the snapshot harness).
    init(url: URL, start: Double, duration: Double?, captions: WebVTT?, transcript: Transcript?, plays: Bool = true,
         save: @escaping @MainActor (Double) -> Void, complete: @escaping @MainActor () -> Void) {
        player = AVPlayer(url: url)
        self.captions = captions
        self.transcript = transcript
        self.save = save
        self.complete = complete
        lastSaved = start
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        update(at: start)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                if self.pendingSeeks == 0 { self.update(at: time.seconds) }
                let itemDuration = self.player.currentItem?.duration.seconds
                if self.autoCompleteTicks.tick(seconds: time.seconds, duration: itemDuration?.isFinite == true ? itemDuration : duration,
                                               isPlaying: self.pendingSeeks == 0 && self.player.timeControlStatus == .playing) {
                    self.complete()
                }
                if abs(time.seconds - self.lastSaved) >= PlaybackResume.saveInterval {
                    self.lastSaved = time.seconds
                    self.save(time.seconds)
                }
            }
        }
        statusObserver = player.observe(\.timeControlStatus) { [weak self] player, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch player.timeControlStatus {
                    case .paused: self.saveCurrentTime()
                    case .playing: self.playCount += 1
                    default: break
                    }
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endCount += 1
                self?.complete()
            }
        }
        if plays { player.play() }
    }

    /// Seeks exactly to `seconds` and plays. A click on a transcript line calls it.
    /// A transcript search result passes `plays: false`, so the player pauses at the cue (#18).
    /// Time ticks during a seek can show the old time, so they do not change the active line until the seek ends.
    func seek(to seconds: Double, plays: Bool = true) {
        pendingSeeks += 1
        autoCompleteTicks.reset()
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pendingSeeks -= 1 }
            }
        }
        update(at: seconds)
        if plays { player.play() } else { player.pause() }
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

/// The content block of a video lecture: the metadata row, the player, the controls row with the complete control,
/// the transcript and the quick checks.
/// Before the first play the poster shows with a play button. The player starts on a click or Space.
/// The quick-check card is hidden when the lecture opens. It shows at the video end or from the "Quick Check" button.
/// With Auto-play on, the video end shows the "Up next" overlay on the player (#99). Open quick checks hold it back.
struct VideoLectureView: View {
    let video: LectureVideo?
    /// Nil when the video has no quick checks.
    var quickChecks: QuickCheckSession?
    var answerQuickCheck: (Int, String) -> Void = { _, _ in }
    var retryQuickCheck: (Int) -> Void = { _ in }
    /// The seek time for the first play.
    let startSeconds: @MainActor () -> Double
    let saveResumePosition: @MainActor @Sendable (Double) -> Void
    /// The saved choice for all video lectures (#97).
    @Binding var showsCaptions: Bool
    /// The saved choice for all video lectures (#97). View > Show Transcript and a transcript search result change it too.
    @Binding var showsTranscript: Bool
    /// The theater mode of the window (#85). View > Enter Theater Mode and Escape change it too.
    @Binding var theater: Bool
    /// The width cap of the player and the controls row. Nil in theater, so the player fills the page column.
    var playerMaxWidth: CGFloat? = TheaterMode.videoWidth
    /// A transcript search result of this lecture (#18). The player seeks to the cue and stays paused.
    var seekRequest: TranscriptSeek? = nil
    /// The complete control sits at the right end of the controls row (#78).
    let completed: Bool
    let toggleComplete: () -> Void
    var completeIsPrimary = true
    /// False after the learner marks the lecture incomplete by hand (#79).
    var autoCompletes = false
    /// Play past 90% or to the end calls this. It returns true if the lecture changes to complete.
    var autoComplete: @MainActor () -> Bool = { false }
    /// The title of the next outline lecture (#99). Nil when Auto-play is off or no next lecture exists, so no overlay shows.
    var upNextTitle: String? = nil
    /// Opens the next lecture. The countdown end and "Play Now" call it.
    var playNext: () -> Void = {}
    /// True starts the player after the load. The page that auto-play opens gets true one time only.
    var startsPlaying: @MainActor () -> Bool = { false }
    /// Gets true while the "Up next" overlay shows, so Escape cancels the countdown and does not end theater.
    var upNextShowsChanged: (Bool) -> Void = { _ in }
    @Environment(\.imageLoads) private var imageLoads
    @Environment(\.opensVideoPlayer) private var opensVideoPlayer
    @Environment(\.snapshotVideoStart) private var snapshotVideoStart
    @Environment(\.snapshotShowsQuickChecks) private var snapshotShowsQuickChecks
    @Environment(\.lectureScrollProxy) private var scrollProxy
    @Environment(\.pageVisibleTop) private var pageVisibleTop
    @Environment(\.snapshotShowsUpNext) private var snapshotShowsUpNext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var poster: NSImage?
    @State private var available: Bool?
    @State private var captions: WebVTT?
    @State private var transcript: Transcript?
    @State private var playback: VideoPlayback?
    @State private var showsQuickChecks = false
    @State private var upNext = UpNextCountdown()

    /// The transcript and the quick checks keep this cap in theater.
    private static let maxWidth = TheaterMode.videoWidth
    private static let playerScrollID = "video-player"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let video {
                Label(video.metadataLabel, systemImage: LectureType.video.symbolName)
                    .gardenText(.meta)
            }
            if isUnavailable {
                ContentUnavailableView("Video unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Publish the course again to restore this file."))
                controlsRow
            } else {
                player
                controlsRow
                if hasCaptions, showsTranscript, let transcript {
                    TranscriptPanel(transcript: transcript, activeLine: playback?.activeLine, seek: seek)
                        .frame(maxWidth: Self.maxWidth)
                }
                if showsQuickChecks, let quickChecks {
                    QuickCheckCard(session: quickChecks, answer: answerQuickCheck, retry: retryQuickCheck, close: closeQuickChecks)
                        .frame(maxWidth: Self.maxWidth)
                        .id(QuickCheckCard.scrollID)
                }
            }
        }
        .focusedSceneValue(\.showsTranscript, hasCaptions ? $showsTranscript : nil)
        .focusedSceneValue(\.theaterMode, isUnavailable ? nil : $theater)
        .task(id: video) { await load() }
        .onChange(of: seekRequest) { applySeekRequest() }
        .onChange(of: playback?.endCount) { _, count in
            if let count, count > 0 { videoEnded() }
        }
        .modifier(UpNextEvents(view: self))
        .onDisappear {
            playback?.stop()
            if upNext.showsOverlay { upNextShowsChanged(false) }
        }
    }

    /// The "Up next" countdown steps and the events that start or stop it (#99).
    private struct UpNextEvents: ViewModifier {
        let view: VideoLectureView

        func body(content: Content) -> some View {
            content
                .task(id: view.upNext.secondsLeft) { await view.countDown() }
                // A new player starts at 0, so only a count that goes up is a play.
                .onChange(of: view.playback?.playCount) { old, new in
                    if let old, let new, new > old { view.upNext.cancel() }
                }
                .onChange(of: view.quickChecks?.isAnswered) { _, answered in
                    if answered == true, view.upNext.quickChecksDone() { view.scrollToPlayer() }
                }
                .onChange(of: view.upNext.showsOverlay) { _, shows in
                    view.upNextShowsChanged(shows)
                    if shows, let title = view.upNextTitle { AccessibilityNotification.Announcement("Up next: \(title)").post() }
                }
        }
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

    /// The card "Close" button. If auto-play waits for the checks, the countdown starts.
    private func closeQuickChecks() {
        showsQuickChecks = false
        if upNext.quickChecksDone() { scrollToPlayer() }
    }

    /// The overlay shows on the player, so the page scrolls back to it after the quick checks.
    private func scrollToPlayer() {
        let proxy = scrollProxy
        DispatchQueue.main.async {
            withAnimation { proxy?.scrollTo(Self.playerScrollID, anchor: .center) }
        }
    }

    /// Open quick checks with an unanswered check hold the countdown back (#99 owner decision).
    /// If the learner answered all checks before, the card does not open again and the countdown starts.
    private func videoEnded() {
        let waits = quickChecks.map { !$0.isAnswered } ?? false
        upNext.videoEnded(autoPlays: upNextTitle != nil, waitsForQuickChecks: waits)
        if waits || upNextTitle == nil { openQuickChecks() }
    }

    /// One step of the countdown. Each new value of `secondsLeft` starts a new step, and a cancel ends it.
    /// The snapshot harness keeps the overlay at 5.
    private func countDown() async {
        guard upNext.showsOverlay, !snapshotShowsUpNext else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        if upNext.tick() { playNext() }
    }

    private func playNow() {
        if upNext.playNow() { playNext() }
    }

    /// True shows "Video unavailable" and a controls row with the complete control only.
    private var isUnavailable: Bool { available == false || video == nil }

    /// False hides the Captions and Transcript toggles and the transcript.
    private var hasCaptions: Bool { video?.captionsURL != nil && available != false }

    /// Captions, Transcript, Theater, Quick Check, then the complete control at the right edge.
    /// If the row is too narrow, Captions, Transcript and Theater become icon-only. The complete label stays.
    private var controlsRow: some View {
        ViewThatFits(in: .horizontal) {
            controls(iconOnly: false)
            controls(iconOnly: true)
        }
        .frame(maxWidth: playerMaxWidth)
    }

    private func controls(iconOnly: Bool) -> some View {
        HStack(spacing: GardenSpacing.xs) {
            if hasCaptions {
                Group {
                    Toggle(isOn: $showsCaptions) { Label("Captions", systemImage: "captions.bubble") }
                        .help(showsCaptions ? "Hide Captions" : "Show Captions")
                    Toggle(isOn: $showsTranscript) { Label("Transcript", systemImage: "text.quote") }
                        .help(showsTranscript ? "Hide Transcript (⌥⌘T)" : "Show Transcript (⌥⌘T)")
                }
                .toggleStyle(GardenPillToggleStyle())
                .labelStyle(ToolbarLabelStyle(iconOnly: iconOnly))
                .disabled(captions == nil)
            }
            if !isUnavailable {
                Toggle(isOn: $theater) { Label("Theater", systemImage: "tv") }
                    .help(theater ? "Exit Theater Mode (⇧⌘T)" : "Enter Theater Mode (⇧⌘T)")
                    .toggleStyle(GardenPillToggleStyle())
                    .labelStyle(ToolbarLabelStyle(iconOnly: iconOnly))
            }
            Spacer()
            if let quickChecks, !isUnavailable {
                Button(action: openQuickChecks) { Label(quickChecks.buttonTitle, systemImage: "checkmark.bubble") }
                    .buttonStyle(.garden(.bordered))
            }
            MarkCompleteButton(completed: completed, isPrimary: completeIsPrimary,
                               help: autoCompletes ? "Completes when you watch 90% of the video" : nil, toggle: toggleComplete)
        }
    }

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
            .overlay {
                if let upNextTitle, let secondsLeft = upNext.secondsLeft {
                    UpNextOverlay(title: upNextTitle, secondsLeft: secondsLeft, cancel: { upNext.cancel() }, playNow: playNow)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: upNext.showsOverlay)
            .clipShape(.garden(GardenRadius.card))
            .mask { PageTopClip(visibleTop: pageVisibleTop) }
            .frame(maxWidth: playerMaxWidth)
            .id(Self.playerScrollID)
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
                    // A dark disc behind the white play glyph keeps it visible on a light poster without a shadow.
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel("Play video")
            }
        }
    }

    /// The manifest length, for the time before the player knows the item duration.
    private var duration: Double? { video.map { Double($0.durationSeconds) } }

    /// The button changes to "Completed". VoiceOver hears "Lecture complete". Nothing else shows (#79).
    private func completeAutomatically() {
        guard autoComplete() else { return }
        AccessibilityNotification.Announcement("Lecture complete").post()
    }

    private func play() {
        guard let video, playback == nil else { return }
        playback = VideoPlayback(url: video.url, start: snapshotVideoStart ?? startSeconds(), duration: duration,
                                 captions: captions, transcript: transcript, plays: !opensVideoPlayer, save: saveResumePosition,
                                 complete: completeAutomatically)
    }

    /// Seeks to the start of the line and plays. Before the first play, the player starts at the line.
    private func seek(_ line: Transcript.Line) {
        upNext.cancel()
        if let playback {
            playback.seek(to: line.start)
        } else if let video, available == true {
            playback = VideoPlayback(url: video.url, start: line.start, duration: duration, captions: captions,
                                     transcript: transcript, save: saveResumePosition, complete: completeAutomatically)
        }
    }

    /// Checks the video file and reads the poster and the captions off the main actor.
    private func load() async {
        playback?.stop()
        playback = nil
        upNext.cancel()
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
        // The page that auto-play opens starts its player at once (#99).
        if exists && (opensVideoPlayer || startsPlaying()) { play() }
        applySeekRequest()
        if snapshotShowsQuickChecks { showsQuickChecks = true }
        if snapshotShowsUpNext { upNext.videoEnded(autoPlays: upNextTitle != nil, waitsForQuickChecks: false) }
        imageLoads?.finish(loaded: exists)
    }

    /// Opens the player paused at the cue of the search result and shows the transcript with the cue active.
    /// Before the load ends this does nothing. The load calls it again.
    private func applySeekRequest() {
        guard let seekRequest, let video, available == true else { return }
        if captions != nil { showsTranscript = true }
        if let playback {
            playback.seek(to: seekRequest.seconds, plays: false)
        } else {
            playback = VideoPlayback(url: video.url, start: seekRequest.seconds, duration: duration, captions: captions,
                                     transcript: transcript, plays: false, save: saveResumePosition, complete: completeAutomatically)
        }
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

private struct SnapshotShowsUpNextKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The snapshot harness sets this, so the "Up next" overlay shows after the load and stays at 5 (#99). The app sets none.
    var snapshotShowsUpNext: Bool {
        get { self[SnapshotShowsUpNextKey.self] }
        set { self[SnapshotShowsUpNextKey.self] = newValue }
    }
}

/// The "Up next" overlay on the player after the video ends (#99): the next lecture title and a 5-second countdown.
/// Cancel (Escape) hides it and keeps the page. Play Now (Return) opens the next lecture at once.
struct UpNextOverlay: View {
    let title: String
    let secondsLeft: Int
    let cancel: () -> Void
    let playNow: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: GardenSpacing.xs) {
                Text("Up next")
                    .font(GardenFont.meta)
                    .foregroundStyle(.white.opacity(0.7))
                Text(title)
                    .font(GardenFont.heading)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("Starts in \(secondsLeft)")
                    .font(GardenFont.meta.monospacedDigit())
                    .foregroundStyle(.white)
                HStack(spacing: GardenSpacing.xs) {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.garden(.bordered))
                        .keyboardShortcut(.cancelAction)
                    Button("Play Now", action: playNow)
                        .buttonStyle(.garden(.primary))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, GardenSpacing.xxs)
            }
            .padding(GardenSpacing.l)
        }
        .accessibilityElement(children: .contain)
    }
}

struct UpNextOverlay_Previews: PreviewProvider {
    static var previews: some View {
        UpNextOverlay(title: "Read the plan", secondsLeft: 5, cancel: {}, playNow: {})
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(width: 640)
            .background(.gray)
    }
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

/// The AVKit player view with inline controls and the full-screen button (#85).
/// AVKit has no public API to start full screen from code, so only this button starts it.
/// SwiftUI `VideoPlayer` crashes on macOS 15 when the app is built with the macOS 26 SDK (#42), so do not use it.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
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

/// A bordered Garden button for an on and off toggle. "On" adds the neutral fill. It never uses the accent fill.
struct GardenPillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(GardenButtonStyle(.bordered, isOn: configuration.isOn))
            .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// Title and icon, or the icon only for a narrow row. The icon-only form keeps the title as the accessibility label.
struct ToolbarLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
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
                .gardenText(.cardTitle)
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
                    .font(GardenFont.body)
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

/// Default: no fill. Hover: the neutral fill and a hand pointer. Active: the accent tint and the time in accent.
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
                    RoundedRectangle(cornerRadius: GardenRadius.row).fill(palette.tint)
                } else if hovers {
                    RoundedRectangle(cornerRadius: GardenRadius.row).fill(palette.fill)
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

    /// Set while a video lecture with an available video shows. View > Enter Theater Mode uses it (#85).
    var theaterMode: Binding<Bool>? {
        get { self[TheaterModeFocusKey.self] }
        set { self[TheaterModeFocusKey.self] = newValue }
    }
}

private struct TheaterModeFocusKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}
