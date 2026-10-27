import AVFoundation
import ChirpCore
import CoreAudio

/// `AVAudioEngine` behind the `CaptureEngine` seam.
final class SystemCaptureEngine: CaptureEngine, @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var onConfigurationChange: (@Sendable () -> Void)?
    /// The device the user picked (nil follows the system default input), read at every (re)start so a
    /// device that was unplugged falls back to the default.
    private let pickedDevice: @Sendable () -> AudioObjectID?
    /// The device the input unit is pinned to; nil while it follows the system default.
    private var pinned: AudioObjectID?
    private var tapFormat: AVAudioFormat?
    private var lastCaptureFormat: AVAudioFormat?
    /// After a failed rebuild: 1 follows the system default even if the picked device is back, 2 pins the
    /// built-in microphone. Reset when capture ends.
    private var fallbackStep = 0
    private(set) var inputName: String?

    init(pickedDevice: @escaping @Sendable () -> AudioObjectID? = { nil }) {
        self.pickedDevice = pickedDevice
        // A device that appears while capture waits for one (every input was gone) restarts it.
        InputDevice.observeChanges { [weak self] in
            guard let self, let handler = self.onConfigurationChange, !self.engine.isRunning else { return }
            handler()
        }
    }

    /// Bluetooth can negotiate a new hardware sample rate as recording starts. The old
    /// engine caches its output format even after a configuration-change notification.
    /// Rebuild only when that input format changes. Reusing a valid graph avoids
    /// repeated Bluetooth route negotiation and the audio loss it causes.
    func resetForCapture() {
        if let lastCaptureFormat {
            let hardware = engine.inputNode.inputFormat(forBus: 0)
            if hardware.sampleRate == lastCaptureFormat.sampleRate,
               hardware.channelCount == lastCaptureFormat.channelCount { return }
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.stop()
        engine = AVAudioEngine()
        pinned = nil
        observe()
    }

    var inputFormat: AVAudioFormat? {
        applyPickedDevice()
        refreshInputName()
        let format = engine.inputNode.inputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
    }

    func fallBack() -> Bool {
        if fallbackStep == 0, pinned != nil || pickedDevice() != nil {
            fallbackStep = 1
            return true
        }
        guard fallbackStep < 2, let builtIn = InputDevice.builtIn(), builtIn.id != pinned else { return false }
        fallbackStep = 2
        return true
    }

    /// Pins the input unit to the picked device. Going back to the default needs a fresh engine, because a unit
    /// bound to a device no longer follows the system default.
    private func applyPickedDevice() {
        let wanted = wantedDevice()
        guard wanted != pinned else { return }
        if let wanted {
            do { try engine.inputNode.auAudioUnit.setDeviceID(wanted) } catch {
                chirpLog.error("input device pin failed status=\((error as NSError).code, privacy: .public)")
                return
            }
        } else {
            engine = AVAudioEngine()
            observe()
        }
        pinned = wanted
    }

    /// The device the input unit should be pinned to now: the picked one while it is connected, else the fallback
    /// step's (nil follows the system default).
    private func wantedDevice() -> AudioObjectID? {
        fallbackStep == 2 ? InputDevice.builtIn()?.id : fallbackStep == 1 ? nil : pickedDevice()
    }

    private func refreshInputName() {
        inputName = pinned.flatMap(InputDevice.name) ?? InputDevice.systemDefault()?.input.name
    }

    func resumeAfterConfigurationChange() -> Bool {
        if !engine.isRunning {
            let hardware = engine.inputNode.inputFormat(forBus: 0)
            guard AudioCapture.canResume(on: pinned, wanted: wantedDevice(), tap: tapFormat, input: hardware) else {
                return false
            }
            do { try engine.start() } catch { return false }
        }
        // The unpinned unit follows the system default, which may be another input now.
        refreshInputName()
        return true
    }

    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let input = engine.inputNode
        let format = inputFormat
        tapFormat = format
        lastCaptureFormat = format
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in block(buffer) }
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0); tapFormat = nil }
    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }

    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) {
        onConfigurationChange = handler
        if handler == nil { fallbackStep = 0 }
        observe()
    }

    private func observe() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard onConfigurationChange != nil else { return }
        let observedEngine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: observedEngine, queue: .main) { [weak self, weak observedEngine] _ in
                guard let self, let observedEngine, self.engine === observedEngine,
                      !observedEngine.isRunning, let handler = self.onConfigurationChange else { return }
                handler()
            }
    }
}
