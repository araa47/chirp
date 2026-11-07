import AVFoundation
import AVKit
import ChirpCore
import ChirpIOSCore
import Combine
import CoreMedia
import SwiftUI
import UIKit
import os

/// The floating bubble: a small Picture in Picture window that stays on top of every app, shows what Chirp is doing
/// and starts or stops dictation with its play/pause button (the text is copied for ⌘V, as with Toggle).
///
/// iOS has no overlays for apps. Android's dictation bubbles draw over other apps; on iOS the only always-on-top
/// window an app can show is Picture in Picture, so the bubble is a live "video" Chirp renders itself
/// (`AVSampleBufferDisplayLayer` frames of `BubbleCard`). While it is up Chirp stays in the foreground's company,
/// which also lets a start from another app (the bubble, Toggle, a Full Keyboard Access key) open the microphone
/// without bringing Chirp to the front. Typeless keeps a hidden PiP window for the same reason; this one is visible
/// and is the control. It needs a keyboard session (microphone on), which showing it starts.
@MainActor
final class FloatingBubble: NSObject, ObservableObject {
    static let shared = FloatingBubble()

    /// The PiP window is up.
    @Published private(set) var active = false
    /// Why the last attempt to show it failed.
    @Published private(set) var failure: String?

    /// The PiP source. It has to sit in a visible view when the window starts (`BubbleSource`).
    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private weak var model: SessionCoordinator?
    private var watch: AnyCancellable?
    private var ticker: Timer?
    private var format: CMVideoFormatDescription?
    /// Read by the playback delegate off the main actor.
    private let paused = OSAllocatedUnfairLock(initialState: true)
    /// The last start/stop the bubble asked for, shown on the card ("Copied", or why it could not start).
    private var outcome: String?
    private var listeningSince: Date?

    static let size = CGSize(width: 640, height: 220)

    var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ model: SessionCoordinator) {
        guard self.model !== model else { return }
        self.model = model
        watch = model.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the change lands.
            Task { @MainActor in self?.refresh() }
        }
        displayLayer.videoGravity = .resizeAspect
        refresh()
    }

    /// Gets the window ready while Dictate shows the control: an audio session, the controller and a first frame.
    /// iOS only starts Picture in Picture straight from a tap, so `show()` can't wait for any of this.
    func prepareSource() {
        guard supported else { return }
        // Picture in Picture needs an active audio session. A keyboard session has one (play and record);
        // otherwise a silent, mixable playback session stands in (it plays nothing and interrupts nothing).
        let audio = AVAudioSession.sharedInstance()
        if audio.category != .playAndRecord {
            try? audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? audio.setActive(true)
        }
        prepare()
        refresh()
    }

    /// Shows the window from the tap, then starts a keyboard session if none runs, so ▶ can dictate at once.
    func show() {
        failure = nil
        guard supported else { failure = "This device doesn’t support Picture in Picture."; return }
        prepareSource()
        guard let controller, controller.isPictureInPicturePossible else {
            failure = "Picture in Picture isn’t available right now. Check Settings → General → Picture in Picture."
            return
        }
        controller.startPictureInPicture()
        Task { @MainActor in
            if let model, !model.armed {
                do { try await model.armSession() }
                catch { failure = (error as? LocalizedError)?.errorDescription ?? "Couldn’t start a session." }
            }
            refresh()
            for _ in 0..<50 where !active { try? await Task.sleep(for: .milliseconds(100)) }
            if !active, failure == nil { failure = "Picture in Picture didn’t start." }
        }
    }

    func hide() { controller?.stopPictureInPicture() }

    private func prepare() {
        guard controller == nil else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true // no ±10 s skip buttons: there is nothing to skip
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller = controller
    }

    /// The play/pause button: start dictation when idle, stop and copy when listening. Toggle's own rules apply.
    fileprivate func pressed(play: Bool) {
        guard let model else { return }
        let listening = [.connecting, .listening].contains(model.phase)
        guard play != listening else { return }
        outcome = nil
        refresh()
        Task { @MainActor in
            do {
                let message = try await model.perform(action: .toggle)
                outcome = message.hasPrefix("Copied") ? "Copied · press ⌘V" : nil
            } catch {
                outcome = (error as? LocalizedError)?.errorDescription ?? "Couldn’t start."
            }
            refresh()
        }
    }

    // MARK: Frames

    private func state() -> BubbleCard.State {
        guard let model else { return .init(title: "Chirp", detail: "Open Chirp", tone: .idle, clock: nil) }
        let listening = model.phase == .listening || model.phase == .connecting
        if listening { if listeningSince == nil { listeningSince = .now } } else { listeningSince = nil }
        let clock = listeningSince.map { DictateView.clock(Date().timeIntervalSince($0)) }
        switch model.phase {
        case .connecting: return .init(title: "Connecting…", detail: "Press ❚❚ to stop", tone: .listening, clock: clock)
        case .listening: return .init(title: "Listening…", detail: "Press ❚❚ to stop and copy", tone: .listening, clock: clock)
        case .correcting: return .init(title: "Polishing…", detail: "One moment", tone: .polishing, clock: nil)
        case .finished: return .init(title: outcome ?? "Copied · press ⌘V", detail: "Press ▶ to dictate again", tone: .done, clock: nil)
        case .armed: return .init(title: outcome ?? "Ready", detail: "Press ▶ to dictate", tone: .idle, clock: nil)
        case .idle: return .init(title: outcome ?? "Microphone off", detail: "Press ▶ to start", tone: .idle, clock: nil)
        case .failed: return .init(title: outcome ?? "Session unavailable", detail: "Open Chirp", tone: .error, clock: nil)
        }
    }

    private func refresh() {
        guard let model else { return }
        let listening = [.connecting, .listening].contains(model.phase)
        paused.withLock { $0 = !listening }
        controller?.invalidatePlaybackState()
        enqueue(state())
        // A running clock needs a frame a second; otherwise frames follow the session's changes.
        if listening, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        } else if !listening {
            ticker?.invalidate(); ticker = nil
        }
    }

    private func enqueue(_ state: BubbleCard.State) {
        let renderer = ImageRenderer(content: BubbleCard(state: state).frame(width: Self.size.width, height: Self.size.height))
        renderer.scale = 1
        guard let image = renderer.cgImage, let buffer = Self.pixelBuffer(image) else { return }
        if format == nil {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description)
            format = description
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if displayLayer.sampleBufferRenderer.status == .failed { displayLayer.sampleBufferRenderer.flush() }
        displayLayer.sampleBufferRenderer.enqueue(sample)
    }

    private static func pixelBuffer(_ image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}

extension FloatingBubble: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.active = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.active = false }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in self.active = false; self.failure = "Picture in Picture didn’t start." }
    }
    /// Tapping the window's "back to app" button opens Chirp.
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

extension FloatingBubble: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in self.pressed(play: playing) }
    }
    /// A live stream: no scrubbing, no skip buttons.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        paused.withLock { $0 }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) { completionHandler() }
}

/// What the bubble draws: always dark, so it reads over any app.
struct BubbleCard: View {
    enum Tone { case idle, listening, polishing, done, error }
    struct State: Equatable { var title: String; var detail: String; var tone: Tone; var clock: String? }
    let state: State

    private var accent: Color {
        switch state.tone {
        case .idle: Color(red: 1.0, green: 0.54, blue: 0.30)
        case .listening: Color(red: 1.0, green: 0.36, blue: 0.36)
        case .polishing: Color(red: 0.62, green: 0.68, blue: 1.0)
        case .done: Color(red: 0.42, green: 0.85, blue: 0.62)
        case .error: Color(red: 1.0, green: 0.42, blue: 0.42)
        }
    }

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                Circle().fill(accent.opacity(0.18))
                Image(systemName: state.tone == .listening ? "waveform" : state.tone == .done ? "doc.on.clipboard" : "mic.fill")
                    .font(.system(size: 64, weight: .semibold)).foregroundStyle(accent)
            }
            .frame(width: 140, height: 140)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(state.title).font(.system(size: 46, weight: .bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
                    if let clock = state.clock {
                        Text(clock).font(.system(size: 40, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                    }
                }
                Text(state.detail).font(.system(size: 32, weight: .medium)).foregroundStyle(.white.opacity(0.72)).lineLimit(1).minimumScaleFactor(0.5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.06, green: 0.08, blue: 0.13))
    }
}

/// Hosts the bubble's source layer. PiP can only start from a layer in a visible window, so this shows it as a small
/// live preview where the bubble is offered.
struct BubbleSource: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = LayerHost()
        view.layer.addSublayer(FloatingBubble.shared.displayLayer)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class LayerHost: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            FloatingBubble.shared.displayLayer.frame = bounds
        }
    }
}

/// Dictate's control for the bubble: the live preview and Show / Hide.
struct FloatingBubbleControl: View {
    @ObservedObject var bubble = FloatingBubble.shared
    @ObservedObject var model: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
            HStack(spacing: ChirpSpacing.s12) {
                BubbleSource()
                    .frame(width: 96, height: 33)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                Button(bubble.active ? "Hide floating bubble" : "Floating bubble", systemImage: bubble.active ? "pip.exit" : "pip.enter") {
                    if bubble.active { bubble.hide() } else { bubble.show() }
                }
                .buttonStyle(.pondTonal)
                .disabled(!model.paired || model.working)
                .accessibilityIdentifier("chirp.bubble.toggle")
                LearnMore(title: "Floating bubble") {
                    Text("A small window that stays on top of every app. Press ▶ in it to dictate and ❚❚ to stop: the text is copied, so press ⌘V where you want it. Tap it to show its buttons; drag it to an edge to tuck it away.")
                    Text("It is a Picture in Picture window, the only kind iOS lets an app keep over other apps. It keeps a keyboard session running, so the microphone stays ready while it is up. Close it with its × or here.")
                }
            }
            if let failure = bubble.failure {
                Text(failure).font(.footnote).foregroundStyle(Color.chirp.record).accessibilityIdentifier("chirp.bubble.failure")
            }
        }
        .onAppear { bubble.attach(model); bubble.prepareSource() }
    }
}
