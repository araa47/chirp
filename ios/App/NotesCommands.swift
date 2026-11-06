import ChirpCore
import SwiftUI

/// The Notes menu: the Mac's Notes keys, as app commands so they work from every tab, while typing in a note, and show
/// in the iPad's hold-⌘ overlay and menu bar. ⌘N opens a blank note to type in, ⌃⌥N starts a new note that records
/// (the Mac's New note), ⌘⇧R records into the note on screen or stops the one that records, ⌘⇧P pauses and resumes.
struct NotesCommands: Commands {
    @ObservedObject var notes: LiveNotesController
    @FocusedBinding(\.chirpTab) private var tab

    var body: some Commands {
        CommandMenu("Notes") {
            Button("New Note") { show(); Task { await notes.keyNewNote() } }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(tab == nil)
            Button(notes.captureState == .paused ? "Resume Recording" : "New Note and Record") {
                show(); Task { await notes.keyNewRecording() }
            }
            .keyboardShortcut("n", modifiers: [.control, .option])
            .disabled(tab == nil || !notes.paired || notes.starting || (notes.isActive && notes.captureState != .paused))
            Divider()
            if notes.captureState.isLive {
                Button("Stop Recording") { Task { await notes.keyRecordOrStop() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(notes.captureState == .paused ? "Resume" : "Pause") { Task { await notes.togglePause() } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            } else {
                Button("Record") { show(); Task { await notes.keyRecordOrStop() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(tab == nil || !notes.paired || notes.isActive || notes.isRetranscribing)
                Button("Pause") {}
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(true)
            }
        }
    }

    private func show() { if tab != .notes { tab = .notes } }
}
