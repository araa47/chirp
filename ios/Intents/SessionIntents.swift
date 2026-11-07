import AppIntents
import Foundation

private enum IntentSetupError: LocalizedError {
    case openChirp
    var errorDescription: String? { "Open Chirp to finish pairing, microphone permission and session setup, then try again." }
}

private func unavailableIntentMessage() throws -> String { throw IntentSetupError.openChirp }

#if CHIRP_APP
// Extensions cannot conform; only the app process ever performs these intents.
extension StartChirpIntent: ForegroundContinuableIntent {}

/// Opens Chirp only when it must: to pair or ask for the microphone. A paired Chirp with the microphone starts
/// and stops without leaving the editor, arming a session first when none runs.
@MainActor private func continueInForegroundIfNeeded(_ intent: some ForegroundContinuableIntent) async throws {
    guard SessionCoordinator.shared.needsForegroundToStart else { return }
    try await continueInForeground(intent)
}

@MainActor private func continueInForeground(_ intent: some ForegroundContinuableIntent) async throws {
    let dialog: IntentDialog = "Open Chirp to start a session."
    if #available(iOS 26.0, *) { try await intent.continueInForeground(dialog, alwaysConfirm: false) }
    else { try await intent.requestToContinueInForeground(dialog) }
}

/// Start or Toggle. When it arms a new session from another app and iOS refuses that in the background (the
/// microphone or the Live Activity), Chirp opens and tries once more on screen. A computer that does not answer
/// fails the same way on screen, so that error is returned as it is.
@MainActor func startOrToggle(_ intent: some ForegroundContinuableIntent, _ action: SessionAction) async throws -> String {
    try await continueInForegroundIfNeeded(intent)
    let coordinator = SessionCoordinator.shared
    let background = coordinator.startsSessionInBackground
    do { return try await coordinator.perform(action: action) }
    catch {
        switch error as? SessionFailure {
        case .mac?, .connection?, .timeout?, .notesRecording?: throw error
        default:
            guard background, !coordinator.armed else { throw error }
            try await continueInForeground(intent)
            return try await coordinator.perform(action: action)
        }
    }
}
#endif

// Both memberships are intentional: the widget extension's Controls and Live Activity buttons need these types.
// LiveActivityIntent selects the containing app process. The extension build has no coordinator, audio or network
// code. Toggle and the App Shortcuts list are app-only (AppShortcuts.swift), so Shortcuts and Full Keyboard Access
// never find a copy of them in the extension.
struct StartChirpIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Start Chirp dictation" }
    static var description: IntentDescription {
        IntentDescription("Starts dictation, starting a Chirp session first when none is running. Opens Chirp only to pair or allow the microphone. The microphone stays active until you end the session.")
    }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        let message = try await startOrToggle(self, .start)
        #else
        let message = try unavailableIntentMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}

struct StopChirpIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Stop Chirp dictation" }
    static var description: IntentDescription {
        IntentDescription("Finishes companion dictation and explicitly copies its fresh final. The session microphone remains active; End session turns it off.")
    }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        let message = try await SessionCoordinator.shared.perform(action: .stop)
        #else
        let message = try unavailableIntentMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}

struct CancelChirpIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Cancel Chirp dictation" }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        let message = try await SessionCoordinator.shared.perform(action: .cancel)
        #else
        let message = try unavailableIntentMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}

struct EndChirpSessionIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "End Chirp session" }
    static var description: IntentDescription { IntentDescription("Stops microphone capture and ends the session.") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        #if CHIRP_APP
        let message = try await SessionCoordinator.shared.perform(action: .end)
        #else
        let message = try unavailableIntentMessage()
        #endif
        return .result(dialog: "\(message)")
    }
}
