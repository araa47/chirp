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
    /// The last start/stop the bubble asked for, shown on the card ("Copied", or why it could not start).
    private var outcome: String?
    private var listeningSince: Date?
    /// The system's reason the last start failed.
    private var lastError: String?

    /// Square: the window is just a mic.
    static var size: CGSize {
        #if DEBUG
        // UI tests compare how big iPadOS makes the window for each shape: `--chirp-bubble-size 480x160`.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--chirp-bubble-size"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { return CGSize(width: parts[0], height: parts[1]) }
        }
        #endif
        // A 3:1 pill: the smallest window iPadOS gives by default (measured on iPadOS 27: 1:1 → 400×400 pt, 2:1 → 400×200,
        // 3:1 → 408×136, 4:1 → 544×136; the height stops at 136 pt). People can pinch it smaller still.
        return CGSize(width: 600, height: 200)
    }

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
        applyControls()
    }

    // MARK: Buttons or indicator only

    /// Settings → Dictation → Floating mic → Record button. Off (the default): the window shows no buttons at all, only
    /// the pill's state, and dictation starts and stops with a dictation key or Toggle. On: a tap shows iOS's buttons,
    /// whose Stop records and stops; iOS adds its ±10 s buttons too, and no API keeps one without the others.
    static let buttonsKey = "chirp.floatingMic.buttons"
    static var showsButtons: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--chirp-floating-mic-buttons") { return true }
        #endif
        return !canHideButtons || UserDefaults.standard.bool(forKey: buttonsKey)
    }
    /// Hiding the buttons uses an unofficial controller setting (`controlsStyle`: 0 all buttons, 1 none), fine for a
    /// personal install, not for the App Store. Where iOS lacks it, the window keeps its buttons.
    static var canHideButtons: Bool { AVPictureInPictureController.instancesRespond(to: NSSelectorFromString("setControlsStyle:")) }

    /// Applies the setting to the window, also while it is up.
    func applyControls() {
        guard let controller, Self.canHideButtons else { return }
        controller.setValue(Self.showsButtons ? 0 : 1, forKey: "controlsStyle")
    }

    /// The system's button (shown as ❚❚, see `pictureInPictureControllerIsPlaybackPaused`): each press records when idle
    /// and stops and copies while listening. Toggle's own rules apply; a press while polishing does nothing.
    fileprivate func pressed(play: Bool) {
        guard let model, model.phase != .correcting else { return }
        outcome = nil
        refresh()
        Task { @MainActor in
            do {
                let message = try await model.perform(action: .toggle)
                outcome = message.hasPrefix("Copied") || message.hasPrefix("Typed") ? "Copied · press ⌘V" : nil
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
        // Always "playing": iOS keeps its controls on screen over paused content, and fades them while it plays, so
        // the window rests as just the pill. A tap shows the system's ❚❚; pressing it records or stops (`pressed`).
        false
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) { completionHandler() }
}

/// What the bubble draws: a quiet pill, no text. A small red ⏺ when ready, ⏹ with a soft ring while listening, grey
/// dots while polishing, a small green check once the text is copied. Low contrast so it sits over any app unnoticed.
struct BubbleCard: View {
    enum Tone { case idle, listening, polishing, done, error }
    struct State: Equatable { var tone: Tone; var clock: String? }
    let state: State

    private static let record = Color(red: 0.93, green: 0.27, blue: 0.27)

    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.12, blue: 0.14)
            switch state.tone {
            case .idle:
                Circle().fill(Self.record).frame(width: 72, height: 72)
            case .listening:
                ZStack {
                    Circle().stroke(Self.record.opacity(0.35), lineWidth: 10).frame(width: 128, height: 128)
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.record).frame(width: 56, height: 56)
                }
            case .polishing:
                HStack(spacing: 18) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.45)).frame(width: 18, height: 18) } }
            case .done:
                Image(systemName: "checkmark").font(.system(size: 64, weight: .bold)).foregroundStyle(Color(red: 0.35, green: 0.78, blue: 0.55))
            case .error:
                Image(systemName: "exclamationmark").font(.system(size: 60, weight: .bold)).foregroundStyle(Color.white.opacity(0.5))
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
                    .frame(width: 54, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityHidden(true)
                Button(bubble.active ? "Hide floating mic" : "Floating mic", systemImage: bubble.active ? "pip.exit" : "pip.enter") {
                    if bubble.active { bubble.hide() } else { bubble.show() }
                }
                .buttonStyle(.pondTonal)
                .disabled(!model.paired || model.working)
                .accessibilityIdentifier("chirp.bubble.toggle")
                LearnMore(title: "Floating mic") {
                    Text("A small pill that stays on top of every app: ⏺ when ready, ⏹ with a soft ring while it listens, a check once the text is copied (press ⌘V where you want it). Start and stop with your dictation key or Toggle. With Settings → Dictation → Floating mic → Record button on, tapping the pill also shows a Stop button that records and stops. Pinch it smaller, or drag it to an edge to tuck it away.")
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
