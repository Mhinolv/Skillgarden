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

/// Owns the player of one video lecture. The caption text changes only when the cue changes, not on each time tick.
@MainActor @Observable
final class VideoPlayback {
    let player: AVPlayer
    private(set) var captionText: String?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var lastSaved: Double = 0
    @ObservationIgnored private let save: @MainActor (Double) -> Void

    /// `save` gets the position every `PlaybackResume.saveInterval` seconds, on pause and on `stop()`.
    init(url: URL, start: Double, captions: WebVTT?, save: @escaping @MainActor (Double) -> Void) {
        player = AVPlayer(url: url)
        self.save = save
        lastSaved = start
        if start > 0 { player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                let text = captions?.text(at: time.seconds)
                if text != self.captionText { self.captionText = text }
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
        player.play()
    }

    /// Pauses the player, saves the position and removes the observers.
    func stop() {
        statusObserver?.invalidate()
        statusObserver = nil
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

/// The content block of a video lecture: the metadata row, the player and the controls row.
/// Before the first play the poster shows with a play button. The player starts on a click or Space.
struct VideoLectureView: View {
    let video: LectureVideo?
    /// The seek time for the first play.
    let startSeconds: @MainActor () -> Double
    let saveResumePosition: @MainActor @Sendable (Double) -> Void
    @Environment(\.imageLoads) private var imageLoads
    @State private var poster: NSImage?
    @State private var available: Bool?
    @State private var captions: WebVTT?
    @State private var playback: VideoPlayback?
    @State private var showsCaptions = true

    private static let maxWidth: CGFloat = 960

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let video {
                HStack(spacing: CourseStyle.spacing) {
                    Label(video.metadataLabel, systemImage: LectureType.video.symbolName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if video.isFreePreview { FreePreviewBadge() }
                }
            }
            if available == false || video == nil {
                ContentUnavailableView("Video unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Publish the course again to restore this file."))
            } else {
                player
                if video?.captionsURL != nil {
                    HStack {
                        Toggle(isOn: $showsCaptions) { Label("Captions", systemImage: "captions.bubble") }
                            .toggleStyle(.button)
                            .disabled(captions == nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .task(id: video) { await load() }
        .onDisappear { playback?.stop() }
    }

    private var player: some View {
        Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let playback {
                    VideoPlayer(player: playback.player) {
                        if showsCaptions, let text = playback.captionText { CaptionOverlay(text: text) }
                    }
                } else {
                    posterView
                }
            }
            .clipShape(.rect(cornerRadius: CourseStyle.cornerRadius))
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
        playback = VideoPlayback(url: video.url, start: startSeconds(), captions: captions, save: saveResumePosition)
    }

    /// Checks the video file and reads the poster and the captions off the main actor.
    private func load() async {
        playback?.stop()
        playback = nil
        poster = nil
        captions = nil
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
        available = exists
        imageLoads?.finish(loaded: exists)
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
