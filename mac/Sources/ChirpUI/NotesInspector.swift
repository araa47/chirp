import ChirpCore
import SwiftUI

/// The transcript inspector (⌥⌘T): one row per paragraph with its time and speaker, ▶ where the note kept the audio
/// (the row highlights while it plays), and a quiet divider where Continue recording picked the note up again.
struct NotesInspector: View {
    @Bindable var model: NotesModel
    let library: NotesLibraryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Transcript").pondFont(.section).foregroundStyle(NotesInk.primary).accessibilityAddTraits(.isHeader)
                if !model.document.segments.isEmpty {
                    Text(NotesLibraryText.duration(model.elapsed) ?? "")
                        .pondFont(.meta)
                        .foregroundStyle(NotesInk.secondary)
                }
                Spacer()
                if !model.document.namableSpeakers.isEmpty {
                    Button { model.beginNamingSpeakers() } label: { Image(systemName: "person.2") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Name the people in this note")
                        .accessibilityLabel("Name speakers")
                }
                Toggle("Raw", isOn: $model.showRaw)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Show each segment as Chirp first heard it")
                if library.canRetranscribe(model) || library.canRestoreTranscript(model) {
                    Menu {
                        if library.canRetranscribe(model) {
                            Button(NotesRetranscribeText.menuTitle) { library.onRetranscribe(model.document.id, nil) }
                        }
                        if library.canRestoreTranscript(model) {
                            Button(NotesRetranscribeText.showChanges) { library.onShowTranscriptChanges(model.document.id) }
                            Button(NotesRetranscribeText.restore) { library.onRestoreTranscript(model.document.id) }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More transcript actions")
                        .accessibilityLabel("More transcript actions")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, model.document.transcribedWith == nil ? 10 : 2)
            if let engine = model.document.transcribedWith {
                Text(NotesRetranscribeText.transcribedWith(engine))
                    .pondFont(.caption)
                    .foregroundStyle(NotesInk.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            if let run = library.retranscribeRun, run.note == model.document.id {
                RetranscribeBanner(library: library, run: run)
                Divider()
            }
            if let banner = model.visibleSpeakerBanner { SpeakerBannerView(model: model, banner: banner) }
            TranscriptList(model: model, library: library)
        }
        .background(Color.chirp.background.ignoresSafeArea())
    }
}

/// What sits between two transcript rows: nothing, or the divider of a capture that continued the note.
private struct TranscriptItem: Identifiable {
    var row: TranscriptRow
    var continued: Date?
    var id: String { row.id }
}

private struct TranscriptList: View {
    @Bindable var model: NotesModel
    let library: NotesLibraryModel
    private var player: NotesPlayer { library.player }

    /// Rows with the Continue boundaries placed before the first row of each later capture.
    private var items: [TranscriptItem] {
        var boundaries = model.document.sessions.dropFirst().map { ($0.firstSegment, $0.startedAt) }
        return model.transcriptRows.map { row in
            var item = TranscriptItem(row: row)
            while let first = boundaries.first, first.0 <= row.paragraph.segments.upperBound {
                item.continued = first.1
                boundaries.removeFirst()
            }
            return item
        }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if model.document.segments.isEmpty && model.document.livePartial.isEmpty {
                            Text(model.state.isLive ? "Segments appear here as you talk." : "No transcript — this note was typed.")
                                .pondFont(.callout)
                                .foregroundStyle(NotesInk.tertiary)
                                .padding(.vertical, 8)
                        }
                        ForEach(items) { item in
                            if let date = item.continued { ContinuedDivider(date: date) }
                            TranscriptRowView(model: model, library: library, row: item.row)
                        }
                        if !model.document.livePartial.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(model.document.livePartial)
                                    .pondFont(13)
                                    .foregroundStyle(NotesInk.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 8)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named("transcriptScroll")).maxY }) { bottom in
                        model.transcriptAtBottom = bottom <= viewport.size.height + 40
                    }
                }
                .coordinateSpace(name: "transcriptScroll")
                .onChange(of: model.document) {
                    if model.transcriptAtBottom, model.highlightedParagraph == nil, model.state.isLive { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.transcriptJump) {
                    guard let id = model.highlightedParagraph else { return }
                    proxy.scrollTo(id, anchor: .top)
                }
                .onAppear { if let id = model.highlightedParagraph { proxy.scrollTo(id, anchor: .top) } }
                .task(id: model.transcriptJump) {
                    guard model.highlightedParagraph != nil else { return }
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { model.highlightedParagraph = nil }
                }
            }
        }
    }
}

/// "Continued · Oct 24, 3:12 PM", between the captures of one note.
private struct ContinuedDivider: View {
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(NotesInk.tertiary.opacity(0.5)).frame(height: 1)
            Text(NotesLibraryText.continued(date))
                .pondFont(12, weight: .medium)
                .foregroundStyle(NotesInk.secondary)
                .fixedSize()
            Rectangle().fill(NotesInk.tertiary.opacity(0.5)).frame(height: 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct TranscriptRowView: View {
    @Bindable var model: NotesModel
    let library: NotesLibraryModel
    private var player: NotesPlayer { library.player }
    let row: TranscriptRow
    @Environment(\.chirpTextScale) private var textScale
    @Environment(\.colorScheme) private var scheme

    /// This paragraph's segments that have kept audio, in order.
    private var audio: [(segment: Int, url: URL)] {
        var seen = Set<Int>()
        return row.paragraph.parts.compactMap { part in
            guard seen.insert(part.segment).inserted, let url = model.keptAudio[part.segment] else { return nil }
            return (part.segment, url)
        }
    }

    var body: some View {
        let p = row.paragraph
        let playing = player.isPlaying(note: model.document.id, paragraph: p.id)
        let audio = audio
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !audio.isEmpty {
                    Button {
                        player.toggle(note: model.document.id, paragraph: p.id, segments: audio)
                    } label: {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .pondFont(8, weight: .bold)
                            .foregroundStyle(playing ? Color.chirp.onKoi : Color.chirp.koi)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(playing ? Color.chirp.koi : Color.chirp.koiContainer.opacity(0.8)))
                    }
                    .buttonStyle(.plain)
                    .help(playing ? "Stop" : "Play what was said here")
                    .accessibilityLabel(playing ? "Stop playback" : "Play from \(NotesDocument.timestamp(row.offset))")
                }
                Text(NotesStatus.clock(row.offset))
                    .pondFont(12, weight: .medium, digits: true)
                    .foregroundStyle(playing ? Color.chirp.koi : NotesInk.secondary)
                    .help(NotesDocument.timestamp(row.offset))
                if let chip = row.chip, let person = p.person, p.failure == nil {
                    Menu { SpeakerMenuItems(model: model, row: p.id, person: person, turns: NotesDocument.turnRefs(p)) } label: {
                        SpeakerChip(name: chip.name, color: chip.color, approximate: chip.approximate, recognised: model.voices.recognised.contains(person))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(library.isRetranscribing(model.document.id))
                    .help(SpeakerMenuItems.help)
                    .accessibilityLabel("Speaker: \(chip.name)" + (model.voices.recognised.contains(person) ? ", recognised" : ""))
                    .accessibilityHint(SpeakerMenuItems.help)
                    if model.voices.recognised.contains(person), let name = model.voices.linked[person] {
                        Button("Not \(name)") { model.onSpeakerEdit(.declineVoice(person)) }
                            .buttonStyle(.plain)
                            .pondFont(.caption)
                            .foregroundStyle(.secondary)
                            .help("Remove this recognised name for this note")
                    }

                }
                if playing {
                    Text("Playing").pondFont(12, weight: .semibold).foregroundStyle(Color.chirp.koi)
                }
                Spacer(minLength: 0)
            }
            if let failure = p.failure {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⚠︎ audio not transcribed (\(failure))")
                        .pondFont(13)
                        .foregroundStyle(Color.chirp.moon)
                    if library.canRetranscribe(model), model.keptAudio[p.parts[0].segment] != nil {
                        Button(NotesRetranscribeText.gapAgain) { library.onRetranscribe(model.document.id, p.parts[0].segment) }
                            .buttonStyle(.link)
                            .pondFont(12, weight: .medium)
                    }
                }
            } else {
                paragraphText(p, hovered: model.hoveredParagraph == p.id)
                    .pondFont(13)
                    .foregroundStyle(NotesInk.primary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if p.parts.contains(where: \.keptOriginal) && !model.showRaw { keptOriginal }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(background(playing: playing, highlighted: model.highlightedParagraph == p.id))
        .modifier(SpeakerRowMenu(model: model, paragraph: p, library: library))
        .popover(isPresented: Binding(get: { model.renaming?.row == p.id }, set: { if !$0 { model.renaming = nil } }),
                 arrowEdge: .bottom) {
            if let r = model.renaming { SpeakerRenameField(model: model, person: r.person) }
        }
        .id(p.id)
        .onHover { inside in
            if inside { model.hoveredParagraph = p.id } else if model.hoveredParagraph == p.id { model.hoveredParagraph = nil }
        }
    }

    private func background(playing: Bool, highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: ChirpRadius.row)
            .fill(playing ? Color.chirp.koi.opacity(scheme == .dark ? 0.16 : 0.12) : Color.chirp.koi.opacity(highlighted ? 0.12 : 0))
            .overlay(alignment: .leading) {
                if playing {
                    Capsule().fill(Color.chirp.koi).frame(width: 3).padding(.vertical, 6)
                }
            }
    }

    /// The paragraph's segments as one text; while hovered, each later segment shows its own `[hh:mm:ss]` in place.
    /// While a segment plays, its words are drawn in koi.
    private func paragraphText(_ p: TranscriptParagraph, hovered: Bool) -> Text {
        let playingSegment = player.isPlaying(note: model.document.id, paragraph: p.id) ? player.segment : nil
        return p.parts.enumerated().reduce(Text("")) { text, item in
            let (i, part) = item
            var body = Text((i == 0 ? "" : " ") + part.text(model.showRaw))
            if part.segment == playingSegment { body = body.fontWeight(.medium) }
            guard hovered, i > 0 else { return text + body }
            return text + Text(" [\(NotesDocument.timestamp(part.offset))]").font(.system(size: 12 * textScale).monospacedDigit()).foregroundColor(NotesInk.secondary) + body
        }
    }

    private var keptOriginal: some View {
        Text("kept original")
            .pondFont(.caption, weight: .medium)
            .foregroundStyle(NotesInk.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(NotesInk.tertiary))
    }
}

/// The Pond 8 speaker hues, shared with iOS and Android. Index zero is koi.
enum SpeakerPalette {
    static let light: [ChirpColor.RGB] = [0xC2410C, 0x2F7A4F, 0x4F46E5, 0xA21CAF, 0x0F766E, 0x8A5A00, 0x0369A1, 0xBE123C].map(ChirpColor.hex)
    static let dark: [ChirpColor.RGB] = [0xFF8A4C, 0x7CCB9B, 0xA5B4FC, 0xF0ABFC, 0x5EEAD4, 0xF5C566, 0x7DD3FC, 0xFDA4AF].map(ChirpColor.hex)
    static let tint = (light: 0.12, dark: 0.18)

    static func color(_ index: Int) -> Color {
        let i = ((index % light.count) + light.count) % light.count
        return ChirpColor.color(light[i], dark[i])
    }
}

/// The canonical speaker chip: a dot, tinted capsule, name in hue and trailing recognition checkmark.
struct SpeakerChip: View {
    let name: String
    let color: Int
    var approximate = false
    var recognised = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let hue = SpeakerPalette.color(color)
        HStack(spacing: 5) {
            Circle().fill(hue).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(name).lineLimit(1)
            if recognised { Text("✓").accessibilityHidden(true) }
        }
        .pondFont(.caption, weight: .semibold)
        .foregroundStyle(hue)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(hue.opacity(scheme == .dark ? SpeakerPalette.tint.dark : SpeakerPalette.tint.light)))
        .fixedSize()
        .accessibilityLabel("Speaker: \(name)" + (approximate ? ", approximate" : "") + (recognised ? ", recognised" : ""))
    }
}
