import ChirpCore
import ChirpIOSCore
import SwiftUI

// Dictation parity (#271 wave 3): Learn from my edits, Learned and Teach Chirp (A2-5), and Stop dictation "When I
// pause" (A2-14), with the Mac's and Android's words (docs/copy.md). The learned items live in `IOSLearnedStore`.

enum LearningText {
    static let toggle = "Learn from my edits"
    static let learned = "Learned"
    static let teach = "Teach Chirp"
    static let empty = "Nothing learned yet."
    static let emptyDetail = "Use Teach Chirp in History, or fix a word in a Chirp Keyboard dictation and make the same fix twice."
    /// Exactly what iOS learns (the setting's footer).
    static let footer = "Chirp learns the names and technical words you correct. Teach Chirp in History uses a fix at once. "
        + "In Chirp Keyboard, a word you fix in a dictation within a minute of it landing counts, and the same fix twice is used. "
        + "iOS doesn’t tell Chirp which app you type in, so it learns no per-app style. "
        + "Learned words are encrypted on this device and go only to your computer with each dictation. "
        + "Nothing is learned while dictation history is off or in a private session."
    static let teachDetail = "Edit this to what you wanted. Chirp learns the names and technical words you fix and uses them from the next dictation."
    static let nothingToLearn = "No new correction found. Fix a name or technical word; an item turned off stays off until you approve it in Learned."
    static let notAllowed = "Turn on dictation history and Learn from my edits, and turn off Pause dictation history, to teach Chirp."
    static func learned(_ titles: [String]) -> String { "Learned: " + titles.joined(separator: ", ") }

    static func summary(_ items: [LearnedItem]) -> String {
        let active = items.filter { $0.state == .active }.count, learning = items.filter { $0.state == .learning }.count
        if items.isEmpty { return "Nothing yet" }
        let parts = [active > 0 ? "\(active) in use" : nil, learning > 0 ? "\(learning) learning" : nil].compactMap { $0 }
        return parts.isEmpty ? "All off" : parts.joined(separator: " · ")
    }
    static func state(_ item: LearnedItem) -> String {
        switch item.state {
        case .active: "In use"
        case .learning: "Learning · \(min(item.count, LearnedStore.threshold - 1)) of \(LearnedStore.threshold)"
        case .off: "Off"
        }
    }
    static func detail(_ item: LearnedItem) -> String {
        guard case .term(let heard, let term) = item.correction else { return "" }
        return heard.lowercased() == term.lowercased() ? "Spelled \(term)" : "Heard as “\(heard)”"
    }
    static func source(_ item: LearnedItem) -> String {
        "From your edit: “\(clip(item.inserted))” → “\(clip(item.edited))”" + (item.count > 1 ? " · seen \(item.count)×" : "")
    }
    private static func clip(_ text: String, limit: Int = 60) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}

enum StopText {
    static let title = "Stop dictation"
    static let tap = "When I tap"
    static let pause = "When I pause"
    static let length = "Pause length"
    static let keepListening = "Keep listening until I stop"
    static let keepListeningHelp = "Chirp keeps the microphone on through pauses and long dictations. It stops only when you tap Stop."
    static func seconds(_ value: TimeInterval) -> String {
        (value.rounded() == value ? String(Int(value)) : String(value)) + " s"
    }
    static func info(onPause: Bool, keepListening: Bool = false) -> String {
        if keepListening {
            return keepListeningHelp + " Pauses, silence and long dictations never end it, and there is no 10-minute limit. Cancel, or leaving the keyboard or Chirp, also ends it."
        }
        return onPause
            ? "Chirp stops after you pause, judged against the room’s background noise. It never stops before you speak, and gives up after 10 seconds of silence. Stop always works, and a hardware key held to talk ignores pauses. Either way, dictation ends at 10 minutes, unless Keep listening until I stop is on."
            : "Tap Stop to finish. Either way, dictation ends at 10 minutes, unless Keep listening until I stop is on."
    }
}

// MARK: - Settings → Dictation

/// "When I tap" (default) or "When I pause" with the pause length, and "Keep listening until I stop", which hides
/// both choices (only Stop ends it). Read at each dictation's start.
struct StopDictationGroup: View {
    @ObservedObject var model: SessionCoordinator
    var body: some View {
        let onPause = model.preferences.stopOnPause == true
        let keep = model.preferences.continuousListening
        SettingsGroup(title: StopText.title) {
            SwitchRow(title: StopText.keepListening, isOn: keep, summary: StopText.keepListeningHelp,
                      identifier: "chirp.settings.keepListening",
                      set: { model.preferences.continuousListening = $0; model.savePreferences() })
            SettingsItem {
                if !keep {
                    ChoiceChips(options: [false, true],
                                selection: Binding(get: { onPause },
                                                   set: { model.preferences.stopOnPause = $0 ? true : nil; model.savePreferences() }),
                                label: { $0 ? StopText.pause : StopText.tap })
                        .accessibilityIdentifier("chirp.settings.stopDictation")
                }
                if onPause, !keep {
                    Text(StopText.length).font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                    ChoiceChips(options: AutoStopDetector.silenceChoices,
                                selection: Binding(get: { model.preferences.pauseLength },
                                                   set: { model.preferences.pauseSeconds = $0; model.savePreferences() }),
                                label: StopText.seconds)
                        .accessibilityIdentifier("chirp.settings.pauseLength")
                }
                LearnMore(title: StopText.title, label: "About Stop dictation") { Text(StopText.info(onPause: onPause, keepListening: keep)) }
            }
        }
    }
}

/// Learn from my edits and the Learned list, with exactly what iOS learns underneath.
struct LearningGroup: View {
    @ObservedObject var model: SessionCoordinator
    @State private var items: [LearnedItem] = []
    @State private var historyOn = false
    var body: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
            SettingsGroup(title: "Learning") {
                SwitchRow(title: LearningText.toggle, isOn: model.preferences.learning,
                          summary: historyOn ? "On while dictation history is on" : "Needs dictation history",
                          symbol: "graduationcap", identifier: "chirp.settings.learn",
                          set: { on in model.preferences.learnFromEdits = on ? nil : false; model.savePreferences() })
                NavRow(title: LearningText.learned, summary: LearningText.summary(items), symbol: "text.book.closed",
                       identifier: "chirp.settings.learned") {
                    LearnedPage(model: model)
                }
            }
            Text(LearningText.footer).font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                .padding(.horizontal, ChirpSpacing.s8).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chirp.settings.learnFooter")
        }
        .onAppear(perform: reload)
    }
    private func reload() {
        items = (try? model.services?.learned.all()) ?? []
        historyOn = (try? model.services?.history.settings().enabled) == true
    }
}

// MARK: - Learned

/// What Chirp learned: each term with its state and the edit it came from; Approve, Undo (turn off) or Delete.
struct LearnedPage: View {
    @ObservedObject var model: SessionCoordinator
    @State private var items: [LearnedItem] = []
    @State private var failed = false
    var body: some View {
        SettingsPageScroll {
            Text("Your words, used in every app.").font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
            if failed {
                PondBanner(kind: .error, title: "Couldn’t open learned items", detail: SessionFailure.storage.localizedDescription)
            } else if items.isEmpty {
                VStack(alignment: .leading, spacing: ChirpSpacing.s4) {
                    Text(LearningText.empty).font(.headline).foregroundStyle(Color.chirp.ink)
                    Text(LearningText.emptyDetail).font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine).accessibilityIdentifier("chirp.learned.empty")
            } else {
                SettingsGroup {
                    ForEach(items) { item in row(item) }
                }
            }
        }
        .navigationTitle(LearningText.learned)
        .onAppear(perform: reload)
    }

    private func row(_ item: LearnedItem) -> some View {
        SettingsItem {
            HStack(alignment: .firstTextBaseline) {
                Text(item.correction.title).font(.headline).foregroundStyle(Color.chirp.ink)
                Spacer(minLength: ChirpSpacing.s8)
                Text(LearningText.state(item)).font(.footnote.weight(.semibold))
                    .foregroundStyle(item.state == .active ? Color.chirp.koi : Color.chirp.inkMuted)
            }
            Text(LearningText.detail(item)).font(.subheadline).foregroundStyle(Color.chirp.ink)
            Text(LearningText.source(item)).font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: ChirpSpacing.s8) {
                if item.state != .active { Button("Approve") { change { try $0.set(item.id, state: .active) } }.buttonStyle(.capsuleChip) }
                if item.state != .off { Button("Undo") { change { try $0.set(item.id, state: .off) } }.buttonStyle(.capsuleChip) }
                Button("Delete", role: .destructive) { change { try $0.delete(item.id) } }
                    .buttonStyle(CapsuleChipStyle()).foregroundStyle(Color.chirp.record)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chirp.learned.item")
    }

    private func change(_ action: (IOSLearnedStore) throws -> Void) {
        do {
            guard let store = model.services?.learned else { throw SessionFailure.storage }
            try action(store)
        } catch { failed = true }
        reload()
    }
    private func reload() {
        do {
            guard let store = model.services?.learned else { throw SessionFailure.storage }
            items = try store.all(); failed = false
        } catch { items = []; failed = true }
    }
}

// MARK: - Teach Chirp

/// A History dictation in an editor: Teach learns from the difference at once (one fix is enough).
struct TeachChirpSheet: View {
    let entry: HistoryEntry
    let store: IOSLearnedStore?
    var done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var wanted: String
    @State private var message: String?
    @FocusState private var focused: Bool

    init(entry: HistoryEntry, store: IOSLearnedStore?, done: @escaping (String) -> Void) {
        self.entry = entry; self.store = store; self.done = done
        _wanted = State(initialValue: entry.text)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ChirpSpacing.s12) {
                    Text(LearningText.teachDetail).font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $wanted)
                        .focused($focused)
                        .font(.body).scrollContentBackground(.hidden).padding(ChirpSpacing.s8)
                        .frame(minHeight: 140)
                        .background(Color.chirp.surface, in: RoundedRectangle(cornerRadius: ChirpRadius.row, style: .continuous))
                        .accessibilityLabel("What you wanted")
                        .accessibilityIdentifier("chirp.teach.text")
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(Color.chirp.record)
                            .accessibilityIdentifier("chirp.teach.message")
                    }
                }
                .padding(ChirpSpacing.s24)
                .frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.chirp.background)
            .navigationTitle(LearningText.teach).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Teach") { teach() }.disabled(wanted == entry.text)
                        .accessibilityIdentifier("chirp.teach.commit")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(ChirpRadius.sheet)
        .modifier(PrivacyShield())
        .onAppear { focused = true }
    }

    private func teach() {
        guard let store, store.allowed else { message = LearningText.notAllowed; return }
        do {
            let learned = try store.learn(inserted: entry.text, edited: String(wanted.prefix(20_000)),
                                          said: entry.raw ?? entry.text, explicit: true)
            guard !learned.isEmpty else { message = LearningText.nothingToLearn; return }
            done(LearningText.learned(learned.map(\.correction.title)))
            dismiss()
        } catch { message = SessionFailure.storage.localizedDescription }
    }
}
