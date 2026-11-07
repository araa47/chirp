import AppIntents
import Foundation

// App target only (generate-project.py gives the widget extension an explicit file list without this file).
//
// On an iPad (iPadOS 27.2), running Toggle from Shortcuts with Chirp closed brought Chirp to the front without
// starting a session, and a trace in the app's perform() was never written. The likely cause: Toggle and this
// App Shortcuts list were also compiled into the widget extension, whose Toggle only says "Open Chirp…". The
// extension uses neither, so both live here, where only the app defines them.

extension ToggleChirpDictationIntent: ForegroundContinuableIntent {}

/// Runs in the background so a hardware-keyboard shortcut can drive dictation from any app: starts (arming a session
/// when none runs), or stops and copies the final for ⌘V. It opens Chirp only to pair or allow the microphone.
struct ToggleChirpDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource { "Toggle Chirp dictation" }
    static var description: IntentDescription {
        IntentDescription("Starts dictation, or stops it and copies the text so you can paste it. Starts a Chirp session first when none is running. Give it a key in Full Keyboard Access to dictate from any app.")
    }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await startOrToggle(self, .toggle)
        return .result(dialog: "\(message)")
    }
}

struct ChirpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartChirpIntent(), phrases: ["Start dictation with \(.applicationName)"],
                    shortTitle: "Start dictation", systemImageName: "mic")
        AppShortcut(intent: ToggleChirpDictationIntent(), phrases: ["Toggle dictation with \(.applicationName)"],
                    shortTitle: "Toggle dictation", systemImageName: "mic.circle")
        AppShortcut(intent: StopChirpIntent(), phrases: ["Stop dictation with \(.applicationName)"],
                    shortTitle: "Stop dictation", systemImageName: "stop.fill")
        AppShortcut(intent: CancelChirpIntent(), phrases: ["Cancel dictation with \(.applicationName)"],
                    shortTitle: "Cancel dictation", systemImageName: "xmark")
        AppShortcut(intent: EndChirpSessionIntent(), phrases: ["End session with \(.applicationName)"],
                    shortTitle: "End session", systemImageName: "mic.slash")
        AppShortcut(intent: StartChirpNotesIntent(), phrases: ["Start a note with \(.applicationName)", "Record a note with \(.applicationName)"],
                    shortTitle: "Record note", systemImageName: "record.circle")
        AppShortcut(intent: PauseChirpNotesIntent(), phrases: ["Pause or resume the note with \(.applicationName)"],
                    shortTitle: "Pause or resume note", systemImageName: "pause.circle")
        AppShortcut(intent: StopChirpNotesIntent(), phrases: ["Stop the note with \(.applicationName)"],
                    shortTitle: "Stop note", systemImageName: "stop.fill")
    }
}
