import ChirpCore
import ChirpIOSCore
import SwiftUI

/// Live Notes speaker labels (#201, Pond #151): the capsule that starts a person's turn, its menu (rename, this turn
/// is, same person as, separate), the rename sheet and the status line while the Mac fetches its model. Names are note content and are
/// never logged.

/// The canonical speaker chip (#271 2.3), the same as the Mac's and Android's: a colour dot and the name in the person's
/// hue on a 12/18% tint of it, with a trailing ✓ for a recognised voice. Each hue is 4.5:1 on its own tint.
struct SpeakerChip: View {
    let name: String
    let colorIndex: Int
    var recognised = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let hue = SpeakerPalette.color(colorIndex)
        HStack(spacing: 6) {
            Circle().fill(hue).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(name + (recognised ? " ✓" : "")).font(.subheadline.weight(.semibold)).foregroundStyle(hue).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(hue.opacity(scheme == .dark ? SpeakerPalette.tint.dark : SpeakerPalette.tint.light), in: Capsule())
        .contentShape(Capsule())
    }
}

/// One labelled segment: a chip, then the words, for each turn. Tapping a chip opens its menu.
struct SpeakerTurnsView: View {
    @ObservedObject var notes: LiveNotesController
    let segment: NotesSegment
    let segmentIndex: Int
    let showRaw: Bool
    let clock: (TimeInterval) -> String
    let rename: (Int) -> Void
    let nameAll: () -> Void

    var body: some View {
        let roster = notes.document.roster
        VStack(alignment: .leading, spacing: 12) {
            // A turn a re-transcribe left without words keeps its place (and index) but is not shown.
            ForEach(Array((segment.turns ?? []).enumerated()).filter { !(showRaw ? $0.element.raw : $0.element.text).isEmpty }, id: \.offset) { turnIndex, turn in
                let menu = SpeakerFixups.menu(for: turn.person, in: roster)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Menu {
                            if let match = notes.recognisedVoice(turn.person) {
                                Button("Not \(match.name)") { notes.rejectVoice(turn.person) }
                                    .accessibilityIdentifier("chirp.notes.speaker.not")
                            }
                            if notes.canUpdateVoice(turn.person) {
                                Button("Update \(menu.name)’s voice") { notes.updateVoice(turn.person) }
                                    .accessibilityIdentifier("chirp.notes.speaker.updateVoice")
                            }
                            Button("Rename “\(menu.name)”…", systemImage: "pencil") { rename(turn.person) }
                                .accessibilityIdentifier("chirp.notes.speaker.rename")
                            Button("Name speakers…", systemImage: "person.2", action: nameAll)
                                .accessibilityIdentifier("chirp.notes.speaker.nameAll")
                            // Just this turn, as on the Mac and Android (A2-10): the rest of this person's turns stay.
                            Menu("This turn is", systemImage: "arrow.left.arrow.right") {
                                ForEach(menu.mergeTargets, id: \.self) { id in
                                    Button(roster.displayName(id)) { notes.reassignTurn(segment: segmentIndex, turn: turnIndex, to: id) }
                                        .accessibilityIdentifier("chirp.notes.speaker.turn.\(id)")
                                }
                                if !menu.mergeTargets.isEmpty { Divider() }
                                Button("New person", systemImage: "person.badge.plus") { notes.reassignTurn(segment: segmentIndex, turn: turnIndex, to: nil) }
                                    .accessibilityIdentifier("chirp.notes.speaker.turn.new")
                            }.accessibilityIdentifier("chirp.notes.speaker.reassign")
                            if !menu.mergeTargets.isEmpty {
                                Menu("Same person as", systemImage: "person.2") {
                                    ForEach(menu.mergeTargets, id: \.self) { id in
                                        Button(roster.displayName(id)) { notes.mergeSpeaker(turn.person, into: id) }
                                    }
                                }.accessibilityIdentifier("chirp.notes.speaker.merge")
                            }
                            ForEach(menu.separable, id: \.self) { id in
                                Button("Separate “\(roster.person(id: id)?.name ?? "Person \(id)")”", systemImage: "person.badge.minus") {
                                    notes.separateSpeaker(id)
                                }.accessibilityIdentifier("chirp.notes.speaker.separate")
                            }
                        } label: {
                            SpeakerChip(name: menu.name, colorIndex: roster.colorIndex(turn.person), recognised: notes.recognisedVoice(turn.person) != nil)
                        }
                        .accessibilityValue(notes.recognisedVoice(turn.person) == nil ? "" : "Recognised").accessibilityLabel(menu.name).accessibilityHint("Rename, merge or reassign this speaker")
                        .accessibilityIdentifier("chirp.notes.speaker.chip.\(segmentIndex).\(turnIndex)")
                        if turnIndex > 0 {
                            Text(clock(turn.start)).font(ChirpType.timer(.caption)).foregroundStyle(Color.chirp.inkMuted)
                        }
                    }
                    Text(showRaw ? turn.raw : turn.text).textSelection(.enabled)
                        .accessibilityIdentifier("chirp.notes.speaker.text.\(segmentIndex).\(turnIndex)")
                }
            }
        }
    }
}

/// Rename a person everywhere in the note; blank goes back to "Person N". Offers to replace the old name in the notes too.
struct RenameSpeakerSheet: View {
    @ObservedObject var notes: LiveNotesController
    let person: Int
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var replace = true
    @State private var remember = true
    @FocusState private var focused: Bool

    var body: some View {
        let roster = notes.document.roster
        let old = roster.displayName(person)
        let offer = SpeakerFixups.replaceOffer(person, renamingTo: name, in: notes.document)
        NavigationStack {
            Form {
                Section {
                    TextField("Person \(roster.resolve(person))", text: $name).focused($focused)
                        .textInputAutocapitalization(.words).autocorrectionDisabled().submitLabel(.done)
                        .onSubmit(commit).accessibilityIdentifier("chirp.notes.speaker.name")
                        .onChange(of: name) { _, value in if value.count > SpeakerFixups.maxNameLength { name = String(value.prefix(SpeakerFixups.maxNameLength)) } }
                } header: { Text("Name") } footer: {
                    Text("Used everywhere in this note: the transcript, the notes Chirp writes and exports.")
                }
                if notes.rememberVoices {
                    Toggle("Remember voice", isOn: $remember).accessibilityIdentifier("chirp.notes.speaker.remember")
                }
                if let offer {
                    Section {
                        Toggle("Also replace “\(offer.old)” with “\(offer.new)” in the notes (\(offer.count == 1 ? "1 place" : "\(offer.count) places"))",
                               isOn: $replace).accessibilityIdentifier("chirp.notes.speaker.replace")
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Color.chirp.background)
            .navigationTitle("Rename “\(old)”").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Rename", action: commit).accessibilityIdentifier("chirp.notes.speaker.confirm") }
            }
        }
        .tint(Color.chirp.koi).presentationDetents([.medium])
        .onAppear { name = roster.person(id: roster.resolve(person))?.name ?? ""; focused = true }
    }

    private func commit() {
        let offer = SpeakerFixups.replaceOffer(person, renamingTo: name, in: notes.document)
        notes.renameSpeaker(person, to: name, replaceInNotes: replace && offer != nil, remember: remember)
        dismiss()
    }
}

/// The one line in the note's banner slot while labels are on but not working yet: never a dialog, always with a way out.
struct SpeakerStatusLine: View {
    @ObservedObject var notes: LiveNotesController
    let status: SpeakerNotice.Status

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { label; Spacer(minLength: 8); actions }
            VStack(alignment: .leading, spacing: 8) { label; HStack(spacing: 12) { actions } }
        }
        .padding(12).background(Color.chirp.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain).accessibilityIdentifier("chirp.notes.speakers.note")
    }

    private var label: some View {
        Label {
            Text(status.text)
        } icon: {
            if case .preparing = status { ProgressView().controlSize(.small) }
            else { Image(systemName: "exclamationmark.triangle") }
        }.font(.footnote).foregroundStyle(Color.chirp.inkMuted)
    }

    @ViewBuilder private var actions: some View {
        if status.canRetry {
            Button("Retry") { notes.retrySpeakerModel() }.accessibilityIdentifier("chirp.notes.speakers.retry")
        }
        if status.canTurnOff {
            Button("Turn off") { notes.setLabelSpeakers(false) }.accessibilityIdentifier("chirp.notes.speakers.turnoff")
        }
    }
}

/// All the note's speakers in one native sheet. Audio is decrypted into memory for replay.
struct NameSpeakersSheet: View {
    @ObservedObject var notes: LiveNotesController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var mergingPerson: Int?
    @State private var draft: SpeakerNamesDraft?
    @FocusState private var focused: Int?
    @StateObject private var player = NotesSegmentPlayer()

    var body: some View {
        NavigationStack {
            Form {
                if let draft {
                    let preview = draft.preview(notes.document)
                    ForEach(preview.namableSpeakers, id: \.self) { id in
                        Section {
                            HStack(spacing: 12) {
                                Circle().fill(SpeakerPalette.color(preview.roster.colorIndex(id))).frame(width: 10, height: 10).accessibilityHidden(true)
                                TextField("Person \(id)", text: nameBinding(id)).focused($focused, equals: id)
                                    .textInputAutocapitalization(.words).autocorrectionDisabled()
                                    .accessibilityLabel("Name for Person \(id)")
                                    .accessibilityIdentifier("chirp.notes.speakers.name.\(id)")
                            }
                            if focused == id {
                                let taking = draft.names.filter { $0.key != id }.map(\.value)
                                let suggestions = SpeakerNameSuggestions.names(saved: notes.savedVoices?.voices.map(\.name) ?? [], recent: notes.recentSpeakerNames,
                                                                              taking: taking, matching: draft.names[id] ?? "")
                                if !suggestions.isEmpty {
                                    ScrollView(.horizontal) {
                                        HStack {
                                            ForEach(suggestions, id: \.self) { name in
                                                Button(name) { self.draft?.names[id] = name }
                                                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                                                    .accessibilityIdentifier("chirp.notes.speakers.suggestion.\(name)")
                                            }
                                        }
                                    }
                                }
                            }
                            if let sample = sample(id) {
                                HStack(alignment: .top) {
                                    Text("“\(sample.text)”").font(.footnote).foregroundStyle(Color.chirp.inkMuted).lineLimit(2)
                                    Spacer(minLength: 8)
                                    if notes.hasAudio(sample.segment) {
                                        Button(player.segment == sample.segment ? "Stop sample" : "Play sample", systemImage: player.segment == sample.segment ? "stop.fill" : "play.fill") {
                                            play(sample.segment, offset: sample.offset)
                                        }.labelStyle(.iconOnly).disabled(notes.isActive)
                                            .accessibilityIdentifier("chirp.notes.speakers.sample.\(id)")
                                    }
                                }
                            }
                            if notes.rememberVoices {
                                Toggle("Remember voice", isOn: Binding(get: { self.draft?.remember[id] != false }, set: { self.draft?.remember[id] = $0 }))
                                    .accessibilityIdentifier("chirp.notes.speakers.remember.\(id)")
                            }
                            if preview.namableSpeakers.count > 1 {
                                Button("Same person as…") { focused = nil; mergingPerson = id }
                                    .accessibilityIdentifier("chirp.notes.speakers.same.\(id)")
                            }
                        } header: { Text("Person \(id)") }
                    }
                    let count = draft.replacementCount(in: notes.document)
                    if count > 0 {
                        Toggle("Also replace names in the notes (\(count == 1 ? "1 place" : "\(count) places"))",
                               isOn: Binding(get: { self.draft?.replace ?? true }, set: { self.draft?.replace = $0 }))
                            .accessibilityIdentifier("chirp.notes.speakers.replace")
                    }
                    Section {} footer: { Text("Names are used everywhere in this note: the transcript, the notes Chirp writes and exports.") }
                }
            }.scrollContentBackground(.hidden).background(Color.chirp.background)
                .navigationTitle("Name speakers").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { if let draft { notes.nameSpeakers(draft) }; dismiss() }
                            .accessibilityIdentifier("chirp.notes.speakers.name.done")
                    }
                }
        }.tint(Color.chirp.koi)
            .presentationDetents(sizeClass == .regular ? [.medium, .large] : [.large])
            .presentationDragIndicator(.visible)
            .task { if draft == nil { draft = SpeakerNamesDraft(notes.document) }; await notes.loadRecentSpeakerNames() }
            .confirmationDialog("Same person as", isPresented: Binding(get: { mergingPerson != nil }, set: { if !$0 { mergingPerson = nil } }), titleVisibility: .visible) {
                if let id = mergingPerson, let draft {
                    let preview = draft.preview(notes.document)
                    ForEach(preview.namableSpeakers.filter { $0 != id }, id: \.self) { other in
                        Button(preview.roster.displayName(other)) { player.stop(); self.draft?.merges[id] = other; mergingPerson = nil }
                            .accessibilityIdentifier("chirp.notes.speakers.merge.into.\(other)")
                    }
                }
            }
            .onDisappear { player.stop() }
    }

    private func nameBinding(_ id: Int) -> Binding<String> {
        Binding(get: { draft?.names[id] ?? "" }, set: { draft?.names[id] = String($0.prefix(SpeakerFixups.maxNameLength)) })
    }

    private func sample(_ id: Int) -> (segment: Int, text: String, offset: TimeInterval)? {
        for (index, segment) in notes.document.segments.enumerated() {
            if let turn = segment.turns?.first(where: { notes.document.roster.resolve($0.person) == id }) {
                return (index, String(turn.text.prefix(100)), max(0, turn.start - segment.offset))
            }
        }
        return nil
    }

    private func play(_ segment: Int, offset: TimeInterval) {
        if player.segment == segment { player.stop(); return }
        let request = player.beginLoading(), id = notes.document.id
        Task {
            do {
                guard let data = try await notes.audioData(segment: segment), notes.document.id == id,
                      player.accepts(request), !notes.isActive else { return }
                player.play(data, segment: segment, offset: offset)
            } catch { if player.accepts(request) { player.failed() } }
        }
    }
}
