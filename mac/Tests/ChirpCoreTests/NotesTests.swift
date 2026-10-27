import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

private let speech = Level(peak: 0.5, rms: 0.2)
private let quiet = Level(peak: 0.01, rms: 0.005)
private let frame = 0.05

@Suite struct NotesSegmenterTests {
    /// Feeds `seconds` of `level` and returns the time of the first cut, if any.
    private func run(_ s: inout NotesSegmenter, _ level: Level, for seconds: Double) -> Double? {
        for _ in 0..<Int((seconds / frame).rounded()) where s.feed(level, duration: frame) { return s.elapsed }
        return nil
    }

    @Test func neverCutsBeforeTwelveSecondsEvenWithPauses() {
        var s = NotesSegmenter()
        for _ in 0..<5 {
            #expect(run(&s, speech, for: 1) == nil)
            #expect(run(&s, quiet, for: 1) == nil)
        }
        #expect(s.elapsed < NotesSegmenter.minSegment)
    }

    @Test func cutsAtAPauseOfPointSixAfterTwelveSeconds() {
        var s = NotesSegmenter()
        #expect(run(&s, speech, for: 15) == nil)
        #expect(run(&s, quiet, for: 0.5) == nil)
        let cut = run(&s, quiet, for: 0.5)
        #expect(cut != nil && abs(cut! - 15.6) < 0.01)
    }

    @Test func aShortPauseIsEnoughAfterThirtySeconds() {
        var s = NotesSegmenter()
        #expect(run(&s, speech, for: 15) == nil)
        #expect(run(&s, quiet, for: 0.35) == nil)   // 0.35 s does not cut at 15 s
        #expect(run(&s, speech, for: 15) == nil)
        let cut = run(&s, quiet, for: 1)
        #expect(cut != nil && abs(cut! - 30.65) < 0.01)
    }

    @Test func forcedCutAtExactlyFortyFiveSecondsOfSpeech() {
        var s = NotesSegmenter()
        let cut = run(&s, speech, for: 60)
        #expect(cut != nil && abs(cut! - NotesSegmenter.maxSegment) < 0.001)
    }

    @Test func resetStartsANewSegment() {
        var s = NotesSegmenter()
        _ = run(&s, speech, for: 45)
        s.reset()
        #expect(s.elapsed == 0 && s.quiet == 0)
        #expect(run(&s, quiet, for: 10) == nil)
    }
}

@Suite struct NotesMarkdownTests {
    @Test func parsesTheSubset() {
        let md = "## Kickoff\n### Detail\n- Ship **Friday**\n  - nested\n- [ ] Maya sends the spec\n_(nothing yet)_\nplain words"
        #expect(NotesMarkdown.blocks(md) == [
            .heading(level: 2, text: "Kickoff"), .heading(level: 3, text: "Detail"),
            .bullet(indent: 0, text: "Ship **Friday**", task: false, checked: false),
            .bullet(indent: 1, text: "nested", task: false, checked: false),
            .bullet(indent: 0, text: "Maya sends the spec", task: true, checked: false), .placeholder, .paragraph("plain words"),
        ])
    }

    @Test func unknownLinesBecomeParagraphs() {
        #expect(NotesMarkdown.blocks("#### deep") == [.paragraph("#### deep")])
        #expect(NotesMarkdown.blocks("| a | b |") == [.paragraph("| a | b |")])
        #expect(NotesMarkdown.blocks("<b>html</b>") == [.paragraph("<b>html</b>")])
        #expect(NotesMarkdown.blocks("- ") == [.paragraph("-")])
        #expect(NotesMarkdown.blocks("## ") == [.paragraph("##")])
    }

    @Test func emptyInputAndCRLF() {
        #expect(NotesMarkdown.blocks("").isEmpty)
        #expect(NotesMarkdown.blocks("\n\n  \n").isEmpty)
        #expect(NotesMarkdown.blocks("## A\r\n- b\r\n") == [.heading(level: 2, text: "A"), .bullet(indent: 0, text: "b", task: false, checked: false)])
    }

    @Test func inlineStylingDropsLinksAndSurvivesBadInput() {
        let bold = NotesMarkdown.inline("Ship **Friday**")
        #expect(String(bold.characters) == "Ship Friday")
        let link = NotesMarkdown.inline("see [site](https://example.com)")
        #expect(link.runs.allSatisfy { $0.link == nil })
        #expect(String(NotesMarkdown.inline("**unclosed").characters).contains("unclosed"))
    }
}

/// Answers every request to the stubbed host with the scripted status and body.
final class NotesURLStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [NotesURLStub.self]
        return URLSession(configuration: c)
    }
}

@Suite(.serialized) struct NotesProtocolTests {
    @Test func requestHasExactlyTheWireKeys() throws {
        let r = NotesStructureRequest(transcript: "hi", outline: ["A"], final: true, windowEnd: 7)
        let o = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        #expect(Set(o.keys) == ["transcript", "outline", "final"])
        #expect(o["transcript"] as? String == "hi" && o["final"] as? Bool == true)
    }

    @Test func responsesDecode() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let good = try decoder.decode(NotesStructureResponse.self, from: Data(###"{"markdown":"## A\n- b","structured":true,"error":null,"timings_ms":{"structure":1234.5}}"###.utf8))
        #expect(good.structured && good.markdown == "## A\n- b" && good.timingsMs?.values.first == 1234.5)
        let bad = try decoder.decode(NotesStructureResponse.self, from: Data(#"{"markdown":null,"structured":false,"error":"rejected","timings_ms":{}}"#.utf8))
        #expect(!bad.structured && bad.markdown == nil && bad.error == "rejected")
        let lenient = try decoder.decode(NotesStructureResponse.self, from: Data(#"{"structured":true,"future":1}"#.utf8))
        #expect(!lenient.structured)
    }

    @Test func healthDecodesNotesStructure() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(Health.self, from: Data(#"{"ok":true,"notes_structure":true}"#.utf8)).notesStructure == true)
        #expect(try decoder.decode(Health.self, from: Data(#"{"ok":true}"#.utf8)).notesStructure == nil)
    }

    @Test func urlKeepsTheBasePath() {
        #expect(ServerConfig(baseURL: URL(string: "https://mainframe.x.ts.net/chirp")!).notesStructureURL.absoluteString
                == "https://mainframe.x.ts.net/chirp/v1/notes/structure")
        #expect(ServerConfig().notesStructureURL.absoluteString == "http://127.0.0.1:7821/v1/notes/structure")
    }

    @Test func structureNotesPostsAndDecodes() async throws {
        NotesURLStub.status = 200
        NotesURLStub.body = Data(#"{"markdown":"- a","structured":true,"error":null,"timings_ms":{"structure":5}}"#.utf8)
        let config = ServerConfig(token: "tok")
        let r = try await config.structureNotes(NotesStructureRequest(transcript: "a", windowEnd: 3), session: NotesURLStub.session)
        #expect(r.markdown == "- a")
        #expect(NotesURLStub.lastRequest?.httpMethod == "POST")
        #expect(NotesURLStub.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(NotesURLStub.lastBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(sent.keys) == ["transcript", "outline", "final"])
    }

    @Test(arguments: [(401, NotesStructureError.auth), (404, .unsupported(404)), (409, .off), (503, .busy), (500, .http(500))])
    func structureNotesMapsErrors(status: Int, expected: NotesStructureError) async {
        NotesURLStub.status = status
        NotesURLStub.body = Data(#"{"type":"error","code":"x","message":"y"}"#.utf8)
        do {
            _ = try await ServerConfig().structureNotes(NotesStructureRequest(transcript: "a"), session: NotesURLStub.session)
            Issue.record("expected an error")
        } catch let e as NotesStructureError {
            #expect(e == expected)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}

@Suite struct NotesPreferencesTests {
    @Test func anOptInAppliesOnlyWhereItWasMade() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        let local = Health(correction: "available", correctionLeavesMachine: false)
        let remoteA = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "a.example.com")
        let remoteB = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "b.example.com")
        // On for this Mac never carries over to an endpoint on another host.
        prefs.setNotesStructure(true, health: local)
        #expect(prefs.notesStructureEnabled(health: local) && !prefs.notesStructureEnabled(health: remoteA))
        // Opting in for host A applies to A only; this Mac falls back to its default (on).
        prefs.setNotesStructure(true, health: remoteA)
        #expect(prefs.notesStructureEnabled(health: remoteA) && !prefs.notesStructureEnabled(health: remoteB))
        #expect(prefs.notesStructureEnabled(health: local))
        // Off for this Mac stays off here.
        prefs.setNotesStructure(false, health: local)
        #expect(!prefs.notesStructureEnabled(health: local) && !prefs.notesStructureEnabled(health: remoteA))
        // A flip while health is unknown is not recorded.
        prefs.setNotesStructure(true, health: nil)
        #expect(!prefs.notesStructureEnabled(health: local))
    }

    @Test func structureDefaultFollowsTheServerUntilTheUserChooses() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        let local = Health(correction: "available", correctionLeavesMachine: false)
        let remote = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "llm.example.com")
        #expect(prefs.notesStructureEnabled(health: local))
        // Unknown health never enables structuring: nothing says where the text would go.
        #expect(!prefs.notesStructureEnabled(health: nil))
        prefs.notesStructure = true                                  // a choice saved before scoping: local only
        #expect(!prefs.notesStructureEnabled(health: nil))
        #expect(!prefs.notesStructureEnabled(health: remote))
        #expect(!prefs.notesStructureEnabled(health: Health(correction: "available", correctionLeavesMachine: true)))
        #expect(prefs.notesTab == "notes")
        prefs.notesTab = "split"
        #expect(Preferences(defaults: defaults).notesTab == "split")
    }

    /// Clean-up nobody chose follows dictation: on for a local destination, never for an external or unknown one.
    @Test func segmentsCleanUpByDefaultOnlyWhereDictationWould() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        let local = Health(correction: "available", correctionLeavesMachine: false)
        let external = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "cleanup.example")
        let unknown = Health(correction: "available")
        #expect(prefs.notesStartOptions(health: local).correction)
        #expect(!prefs.notesStartOptions(health: external).correction)
        #expect(!prefs.notesStartOptions(health: unknown).correction)
        #expect(!prefs.notesStartOptions(health: Health(correction: "available", correctionLeavesMachine: true,
                                                         correctionHost: "cleanup.example", notesCorrection: true)).correction)
        for health in [local, external, unknown] {
            #expect(prefs.notesStartOptions(health: health).correction == prefs.permitsCorrection(health: health))
        }
        prefs.correction = true
        #expect(prefs.notesStartOptions(health: external).correction)
        prefs.correction = false
        #expect(!prefs.notesStartOptions(health: local).correction)
    }

    @Test func segmentsUseTheDefaultStyleAndTheEditedDefaultPrompt() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        prefs.correction = true
        prefs.correctionProfile = "email"
        prefs.wordWaveform = true
        prefs.correctionPrompts = ["default": "Keep it tidy.", "email": "Formal."]
        let o = prefs.notesStartOptions(health: Health(correction: "available"))
        #expect(o == StartOptions(client: "mac", correction: true, correctionProfile: "default", correctionPrompt: "Keep it tidy.", wordTimings: true))
        #expect(!prefs.notesStartOptions(health: Health(correction: "off")).correction)
        #expect(!prefs.notesStartOptions(health: nil).correction)
    }

    @Test func segmentsUseTheHiddenNotesStyleWhenTheServerHasIt() {
        let name = "chirp-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        prefs.correction = true
        prefs.correctionPrompts = ["default": "Keep it tidy."]
        let o = prefs.notesStartOptions(health: Health(correction: "available", notesCorrection: true))
        // The edited dictation prompt never replaces the notes style, whose prompt matches its guard.
        #expect(o == StartOptions(client: "mac", correction: true, correctionProfile: "live_notes", wordTimings: true))
        #expect(ClientMessage.start(o).contains("\"correction_profile\":\"live_notes\""))
        #expect(!ClientMessage.start(o).contains("correction_prompt"))
        #expect(!prefs.notesStartOptions(health: Health(correction: "off", notesCorrection: true)).correction)
        // An older server (no `notes_correction`, or false) keeps the default style.
        #expect(prefs.notesStartOptions(health: Health(correction: "available", notesCorrection: false)).correctionProfile == "default")
    }

    @Test func healthDecodesNotesCorrection() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let new = try decoder.decode(Health.self, from: Data(#"{"ok":true,"notes_structure":true,"notes_correction":true}"#.utf8))
        #expect(new.notesCorrection == true)
        #expect(try decoder.decode(Health.self, from: Data(#"{"ok":true,"notes_structure":true}"#.utf8)).notesCorrection == nil)
    }
}

@MainActor
@Suite struct NotesModelTests {
    private func model(_ configure: (NotesModel) -> Void = { _ in }) -> NotesModel {
        let m = NotesModel()
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0))
        d.append(NotesSegment(id: 0, offset: 5, raw: "we ship friday"))
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: "- Ship Friday", structured: true), for: r) }
        m.document = d
        configure(m)
        return m
    }

    @Test func statusFollowsTheRecorder() {
        #expect(model { $0.state = .starting }.statusText == NotesStatus.connecting)
        #expect(model { $0.state = .recording }.statusText == NotesStatus.listening)
        #expect(model { $0.state = .recording; $0.structuring = .running }.statusText == NotesStatus.updating)
        #expect(model { $0.state = .stopping }.statusText == NotesStatus.finishing)
        #expect(model { $0.state = .stopped }.statusText == NotesStatus.stopped)
        let failed = model { $0.state = .error("Notes stopped: Server is busy") }
        #expect(failed.statusText == "Notes stopped: Server is busy" && failed.isError)
    }

    @Test func controlsFollowTheStateTable() {
        let empty = NotesModel()
        #expect(empty.canToggle && !empty.canExport && empty.isBlank && empty.displayTitle == NotesLibraryText.untitled)
        let recording = model { $0.state = .recording }
        #expect(recording.isRecording && recording.canExport && !recording.isBlank)
        let stopping = model { $0.state = .stopping }
        #expect(!stopping.canToggle && !stopping.canExport)
        let stopped = model { $0.state = .stopped }
        #expect(stopped.canToggle && stopped.canExport)
    }

    @Test func aStartErrorNeverHidesARunningRecorder() {
        #expect(NotesModel.displayState(recorder: .idle, startError: "No microphone input device") == .error("No microphone input device"))
        #expect(NotesModel.displayState(recorder: .stopped, startError: "x") == .error("x"))
        for running in [NotesRecorderState.starting, .recording, .stopping] {
            #expect(NotesModel.displayState(recorder: running, startError: "x") == running)
            #expect(!NotesModel.acceptsStartError(running))
        }
        #expect(NotesModel.displayState(recorder: .stopping, startError: nil) == .stopping)
        #expect(model { $0.structuring = .off(.waiting) }.explanation?.hasPrefix("Waiting for the server") == true)
        #expect(!model { $0.structuring = .off(.waiting) }.structuringAvailable)
    }

    @Test func elapsedReadsAsMinutesThenHours() {
        #expect(model { $0.elapsed = 65 }.elapsedText == "01:05")
        #expect(model { $0.elapsed = 3725 }.elapsedText == "1:02:05")
    }

    @Test func copyIsTheNotesOrTheTranscriptWithoutThem() {
        let notes = model()
        #expect(notes.copyText.contains("- Ship Friday") && !notes.copyText.contains("## Transcript"))
        // The inspector showing changes nothing: Copy Markdown is the note.
        let library = NotesLibraryModel()
        library.showsInspector = true
        #expect(library.displayed(notes).copyText == notes.copyText)
        // The notes are text the user can edit: with structuring off they are still the notes.
        let off = model { $0.structuring = .off(.correctionOff) }
        #expect(off.copyText.contains("- Ship Friday") && !off.copyText.contains("## Transcript"))
        #expect(model().saveText.contains("- Ship Friday") && model().saveText.contains("## Transcript"))
        #expect(model { $0.structuring = .off(.unsupported) }.saveText.contains("- Ship Friday"))
        let empty = model { $0.document = NotesDocument(startedAt: Date(timeIntervalSince1970: 0)) }
        empty.document.append(NotesSegment(id: 0, offset: 0, raw: "only speech"))
        #expect(empty.copyText.contains("## Transcript") && empty.copyText.contains("only speech"))
    }

    @Test func explanationsAndRetryNote() {
        #expect(model().explanation == nil && model().retryNote == nil)
        #expect(model { $0.structuring = .off(.disabled) }.explanation?.hasPrefix("Structuring is off") == true)
        let local = model { $0.structuring = .off(.correctionOff); $0.canManageModels = true }
        #expect(local.explanation?.contains("Models on this Mac") == true && local.offersModels)
        let remote = model { $0.structuring = .off(.correctionOff) }
        #expect(remote.explanation != nil && !remote.offersModels)
        #expect(model { $0.structuring = .off(.unsupported) }.explanation?.contains("newer Chirp server") == true)
        #expect(model { $0.structuring = .failed("timeout") }.retryNote == "Couldn’t update notes (timeout) — will retry")
    }

    @Test func hearingShowsUnstructuredTextThenThePartial() {
        let m = model()
        m.document.append(NotesSegment(id: 1, offset: 30, raw: "budget talk"))
        m.document.livePartial = "and then"
        #expect(m.hearingText == "budget talk and then")
        m.structuring = .off(.disabled)
        #expect(m.hearingText == "and then")
    }

    @Test func reorganizeIsEnabledOnlyWhenItCanRun() {
        #expect(model().canReorganize && !model().reorganizeHidden)
        #expect(!model { $0.reorganizeStatus = .running }.canReorganize)
        #expect(!model { $0.state = .stopping }.canReorganize)
        #expect(!model { $0.document = NotesDocument() }.canReorganize)
        #expect(model { $0.state = .stopped }.canReorganize && model { $0.state = .idle }.canReorganize)
        // Structuring off: the recorder reports the reason; the button stays visible but disabled.
        let off = model { $0.structuring = .off(.disabled); $0.reorganizeStatus = .unavailable(.disabled) }
        #expect(!off.canReorganize && !off.reorganizeHidden && !off.autoReorganizeAvailable)
        // An old server: appends work, Reorganize is hidden and the toggle explains why.
        let old = model { $0.reorganizeStatus = .unavailable(.unsupported) }
        #expect(!old.canReorganize && old.reorganizeHidden && !old.autoReorganizeAvailable)
    }

    @Test func reorganizeNotesAndTheUndoChip() {
        #expect(model { $0.reorganizeStatus = .failed("timeout") }.reorganizeNote == "Couldn’t organize (timeout) — will retry")
        #expect(model { $0.reorganizeStatus = .failed("rejected: negation") }.reorganizeNote == "Couldn’t organize (rejected: negation) — will retry")
        #expect(model { $0.reorganizeStatus = .conflict }.reorganizeNote == "Notes changed while organizing — try again")
        #expect(model { $0.reorganizeStatus = .tooLong }.reorganizeNote?.hasPrefix("Too long to organize") == true)
        // Organize: progress, then a clear result.
        #expect(model { $0.state = .stopped; $0.reorganizeStatus = .organizing(step: 2, of: 4) }.statusText == "Organizing notes… 2/4")
        let done = model { $0.reorganizeStatus = .organized(failed: 0, reason: nil) }
        #expect(done.reorganizeNote == "Organized" && done.reorganizeNoteIsSuccess)
        let partial = model { $0.reorganizeStatus = .organized(failed: 1, reason: "rejected: novel_name") }
        #expect(partial.reorganizeNote == "Couldn’t organize 1 section (rejected: novel_name) — kept as is" && !partial.reorganizeNoteIsSuccess)
        #expect(model { $0.reorganizeStatus = .organized(failed: 2, reason: nil) }.reorganizeNote == "Couldn’t organize 2 sections — kept as is")
        #expect(!model { $0.reorganizeStatus = .organizing(step: 1, of: 3) }.canReorganize)
        // Finishing shows how long it has taken once it is more than a moment.
        #expect(model { $0.state = .stopping; $0.finishingElapsed = 1 }.statusText == NotesStatus.finishing)
        #expect(model { $0.state = .stopping; $0.finishingElapsed = 12.4 }.statusText == NotesStatus.finishing + " · 12 s")
        #expect(model { $0.state = .recording; $0.reorganizeStatus = .running }.statusText == NotesStatus.reorganizing)
        #expect(model { $0.state = .stopping; $0.reorganizeStatus = .running }.statusText == NotesStatus.reorganizing)
        let m = model { $0.reorganizeStatus = .applied(at: 5) }
        #expect(m.showUndoChip)
        m.dismissUndoChip()
        #expect(!m.showUndoChip)
        m.reorganizeStatus = .applied(at: 9)                 // a later reorganize shows it again
        #expect(m.showUndoChip)
        m.reorganizeStatus = .idle                           // the next edit or append
        #expect(!m.showUndoChip)
    }

    @Test func pendingChangesReachOnlyAnAttachedEditor() {
        let m = model()
        let change = NotesTextChange(range: NSRange(location: 0, length: 0), replacement: "x", kind: .append)
        m.enqueue([change])
        #expect(m.takePendingChanges().isEmpty)              // no editor: dropped, it loads the text when it appears
        var drained: [NotesTextChange] = []
        m.onPendingChanges = { drained += m.takePendingChanges() }
        m.enqueue([change, change])
        #expect(drained.count == 2)
    }

    @Test func theEmptyStateNeedsNoTextNoRecordingAndNoFocus() {
        let m = NotesModel()
        #expect(m.showsEmptyState)
        m.editorFocused = true
        #expect(!m.showsEmptyState)
        let typed = NotesModel()
        typed.document.userEdit(NSRange(location: 0, length: 0), "x")
        #expect(!typed.showsEmptyState && typed.hasContent)
    }
}

/// Opt-in check against a real server: `CHIRP_LIVE_NOTES_URL=http://127.0.0.1:7899 CHIRP_LIVE_NOTES_TOKEN_FILE=…
/// ./scripts/test.sh --filter NotesLiveServer`. Skipped otherwise, so CI and the normal run never need a server.
@Suite(.serialized) struct NotesLiveServerTests {
    static let url = ProcessInfo.processInfo.environment["CHIRP_LIVE_NOTES_URL"]

    @Test(.enabled(if: url != nil)) func structuresASampleThroughTheRealEndpoint() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = ServerConfig.load(urlString: Self.url, tokenPath: env["CHIRP_LIVE_NOTES_TOKEN_FILE"] ?? ServerConfig.defaultTokenPath)
        let health = try await config.fetchHealth()
        #expect(health.notesStructure == true)
        let transcript = """
            Okay so the kickoff for the Lantern project. We decided to keep the vendor contract.
            Maya will send the draft spec by Friday. We will not add new headcount this quarter.
            """
        let r = try await config.structureNotes(NotesStructureRequest(transcript: transcript, outline: ["Intro"], final: true))
        if health.correction == "off" {
            Issue.record("server has correction off; expected 409 before this point")
            return
        }
        #expect(r.structured, "structured:false error=\(r.error ?? "nil")")
        let blocks = NotesMarkdown.blocks(r.markdown ?? "")
        #expect(blocks.contains { if case .bullet = $0 { true } else { false } })
        // Prints the timings only, never the notes, like the app's logs.
        print("live notes: structured=\(r.structured) blocks=\(blocks.count) timings=\(r.timingsMs ?? [:])")
    }

    /// The whole client path: document scope → `reorganizeNotes` on the wire → `applyReorganize`.
    @Test(.enabled(if: url != nil)) func reorganizesADocumentThroughTheRealEndpoint() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = ServerConfig.load(urlString: Self.url, tokenPath: env["CHIRP_LIVE_NOTES_TOKEN_FILE"] ?? ServerConfig.defaultTokenPath)
        let health = try await config.fetchHealth()
        #expect(health.notesReorganize == true)
        let text = """
            ## Budget
            - Venue quote is **$4,200** for **2** days
            - [ ] **Maya** to send the draft budget by **Friday**
            ## Speakers
            - Two keynotes confirmed, a third is maybe
            - We will **not** hire a contractor this quarter
            - **Decision:** keep the vendor contract
            ## Budget
            - venue quote 4,200, deposit due in **June**
            - [x] Sam booked the demo room
            ask jo re: invoices
            """
        var document = NotesDocument(text: text)
        let request = try #require(document.reorganizeRequest(final: true, manual: true))
        let r = try await config.reorganizeNotes(request)
        #expect(r.reorganized, "reorganized:false error=\(r.error ?? "nil")")
        if r.changed {
            let change = document.applyReorganize(r, for: request)
            #expect(change?.kind == .reorganize && document.text.contains("4,200") && document.text.contains("- [x] "))
        } else {
            #expect(r.markdown == request.notes)
        }
        // Prints counts and timings only, never the notes, like the app's logs.
        print("live reorganize: reorganized=\(r.reorganized) changed=\(r.changed) chars=\(request.notes.count) timings=\(r.timingsMs ?? [:])")
    }

    /// Managed server only, with a correction sent while this runs (for example `client_sim.py --correction` a few
    /// seconds in): the reorganize gives way and comes back `preempted`, which the client treats as not run.
    @Test(.enabled(if: url != nil && ProcessInfo.processInfo.environment["CHIRP_LIVE_NOTES_PREEMPT"] != nil))
    func aReorganizeGivesWayToACorrection() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = ServerConfig.load(urlString: Self.url, tokenPath: env["CHIRP_LIVE_NOTES_TOKEN_FILE"] ?? ServerConfig.defaultTokenPath)
        // About 3300 characters: a reorganize long enough (10+ s) for the correction to arrive mid-generation.
        let text = (1...30).map { "## Station \($0)\n- Crate \($0) holds \($0 * 3) parts for the north line\n- [ ] check crate \($0) seals\n" }
            .joined()
        var document = NotesDocument(text: text)
        let request = try #require(document.reorganizeRequest(final: false, manual: true))
        let r = try await config.reorganizeNotes(request)
        #expect(r.preempted && r.markdown == nil && !r.changed, "error=\(r.error ?? "nil")")
        #expect(document.applyReorganize(r, for: request) == nil)
        print("live preempt: error=\(r.error ?? "nil") reason=\(r.reason ?? "nil") timings=\(r.timingsMs ?? [:])")
    }

    /// Against a server whose backend answers with an invented name (endpoint mode with a stub): the rejection reaches
    /// the client with the guard's name.
    @Test(.enabled(if: url != nil && ProcessInfo.processInfo.environment["CHIRP_LIVE_NOTES_REJECT"] != nil))
    func aRejectedStructureCarriesItsReason() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = ServerConfig.load(urlString: Self.url, tokenPath: env["CHIRP_LIVE_NOTES_TOKEN_FILE"] ?? ServerConfig.defaultTokenPath)
        let r = try await config.structureNotes(NotesStructureRequest(transcript: "we will ship the beta next week", outline: []))
        #expect(!r.structured && r.markdown == nil && r.error == "rejected")
        #expect(NotesFailure.guardName(r.reason) == r.reason && r.reason != nil)
        print("live reject: error=\(r.error ?? "nil") reason=\(r.reason ?? "nil") label=\(r.failureLabel)")
    }
}
