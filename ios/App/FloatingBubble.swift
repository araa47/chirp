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
    /// The system's reason the last start failed.
    private var lastError: String?

    /// Square: the window is just a mic.
    static let size = CGSize(width: 320, height: 320)

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

    /// Gets the window ready while Dictate shows the control: the controller and a first frame. It leaves the
    /// audio session alone, so opening Dictate never interrupts what else is playing.
    func prepareSource() {
        guard supported else { return }
        prepare()
        refresh()
    }

    /// Shows the window from the tap (iOS only starts Picture in Picture straight from one), then starts a keyboard
    /// session if none runs, so ▶ can dictate at once. The window needs an active audio session that allows
    /// playback; the tap sets the microphone's own one (`MicrophoneCapture.category`), so arming the session
    /// afterwards changes nothing under the window.
    func show() {
        failure = nil
        guard supported else { failure = "This device doesn’t support Picture in Picture."; return }
        prepareSource()
        if let model, !model.armed {
            let audio = AVAudioSession.sharedInstance()
            do {
                try audio.setCategory(MicrophoneCapture.category, mode: MicrophoneCapture.mode, options: MicrophoneCapture.options)
                try audio.setActive(true)
            } catch { failure = "The microphone is busy. Try again in a moment."; return }
        }
        guard let controller else { return }
        let possible = controller.isPictureInPicturePossible
        if possible { controller.startPictureInPicture() }
        Task { @MainActor in
            if let model, !model.armed {
                do { try await model.armSession() }
                catch { failure = (error as? LocalizedError)?.errorDescription ?? "Couldn’t start a session."; return }
            }
            refresh()
            guard possible else { failure = "Tap Floating mic again to show it."; return }
            for _ in 0..<50 where !active { try? await Task.sleep(for: .milliseconds(100)) }
            if !active, failure == nil { failure = lastError ?? "Picture in Picture didn’t start." }
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
        guard let model else { return .init(tone: .idle, clock: nil) }
        let listening = model.phase == .listening || model.phase == .connecting
        if listening { if listeningSince == nil { listeningSince = .now } } else { listeningSince = nil }
        let clock = listeningSince.map { DictateView.clock(Date().timeIntervalSince($0)) }
        switch model.phase {
        case .connecting, .listening: return .init(tone: .listening, clock: clock)
        case .correcting: return .init(tone: .polishing, clock: nil)
        case .finished: return .init(tone: outcome == nil || outcome?.hasPrefix("Copied") == true ? .done : .error, clock: nil)
        case .armed, .idle: return .init(tone: outcome == nil ? .idle : .error, clock: nil)
        case .failed: return .init(tone: .error, clock: nil)
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
        let reason = error.localizedDescription
        Task { @MainActor in self.active = false; self.lastError = "Picture in Picture didn’t start: \(reason)"; self.failure = self.lastError }
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

/// What the bubble draws: one mic, the whole window in its state's colour. Koi when ready, `record` red with the clock while
/// listening, moon while polishing, a green check once the text is copied; the system's ▶ / ❚❚ is the button.
struct BubbleCard: View {
    enum Tone { case idle, listening, polishing, done, error }
    struct State: Equatable { var tone: Tone; var clock: String? }
    let state: State

    private var fill: Color {
        switch state.tone {
        case .idle: Color(red: 0.95, green: 0.42, blue: 0.11)      // koiDecor
        case .listening: Color(red: 0.86, green: 0.15, blue: 0.15) // record
        case .polishing: Color(red: 0.45, green: 0.50, blue: 0.85) // moon
        case .done: Color(red: 0.13, green: 0.60, blue: 0.40)      // lily
        case .error: Color(red: 0.40, green: 0.42, blue: 0.48)
        }
    }
    private var symbol: String {
        switch state.tone {
        case .idle: "mic.fill"
        case .listening: "waveform"
        case .polishing: "ellipsis"
        case .done: "checkmark"
        case .error: "exclamationmark"
        }
    }

    var body: some View {
        ZStack {
            // The whole window is the button's colour, so it reads as one mic, not a card.
            fill
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 104, weight: .bold)).foregroundStyle(.white)
                if let clock = state.clock {
                    Text(clock).font(.system(size: 34, weight: .semibold).monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                Button(bubble.active ? "Hide floating mic" : "Floating mic", systemImage: bubble.active ? "pip.exit" : "pip.enter") {
                    if bubble.active { bubble.hide() } else { bubble.show() }
                }
                .buttonStyle(.pondTonal)
                .disabled(!model.paired || model.working)
                .accessibilityIdentifier("chirp.bubble.toggle")
                LearnMore(title: "Floating mic") {
                    Text("A small mic that stays on top of every app. Tap it, then ▶ to dictate and ❚❚ to stop. It turns red while it listens and green when the text is copied: press ⌘V where you want it. Drag it to an edge to tuck it away.")
                    Text("iOS lets no app draw over other apps or paste into them, so the mic is a Picture in Picture window, and its buttons are the system’s. It keeps a keyboard session running, so the microphone stays ready while it is up. To have the text typed in for you, dictate with Chirp Keyboard instead.")
                }
            }
            if let failure = bubble.failure {
                Text(failure).font(.footnote).foregroundStyle(Color.chirp.record).accessibilityIdentifier("chirp.bubble.failure")
            }
        }
        .onAppear { bubble.attach(model); bubble.prepareSource() }
    }
}
