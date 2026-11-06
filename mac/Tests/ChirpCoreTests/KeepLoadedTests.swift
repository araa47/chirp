import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

// A fake server for /v1/correction/settings: URLProtocol answers from a closure, which may fail like a dead network.
private final class SettingsFake: URLProtocol, @unchecked Sendable {
    struct Seen { var method: String; var path: String; var auth: String?; var contentType: String?; var body: Data? }
    nonisolated(unsafe) static var handler: ((URLRequest) -> Result<(Int, Data), URLError>)?
    nonisolated(unsafe) static var seen: [Seen] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        SettingsFake.seen.append(Seen(method: request.httpMethod ?? "GET", path: request.url?.path ?? "",
                                      auth: request.value(forHTTPHeaderField: "Authorization"),
                                      contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body))
        switch SettingsFake.handler?(request) ?? .success((500, Data())) {
        case .success(let (status, data)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
    static func session(_ handler: @escaping (URLRequest) -> Result<(Int, Data), URLError>) -> URLSession {
        SettingsFake.handler = handler
        SettingsFake.seen = []
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [SettingsFake.self]
        return URLSession(configuration: c)
    }
    static func reply(_ status: Int, _ json: String = "{}") -> (URLRequest) -> Result<(Int, Data), URLError> {
        { _ in .success((status, Data(json.utf8))) }
    }
}

private let loadedJSON = """
{"keep_loaded":true,"loaded":true,"loading":false,"model":"qwen3-4b","memory_mb":2662,"memory_estimated":false,"mode":"managed"}
"""
private let estimateJSON = """
{"keep_loaded":false,"loaded":false,"loading":false,"model":"qwen3-4b","memory_mb":2662,"memory_estimated":true,"mode":"managed"}
"""
private let loadingJSON = """
{"keep_loaded":true,"loaded":false,"loading":true,"model":"qwen3-4b","memory_mb":2662,"memory_estimated":true,"mode":"managed"}
"""
private let offJSON = """
{"keep_loaded":false,"loaded":false,"loading":false,"model":null,"memory_mb":null,"memory_estimated":false,"mode":"off"}
"""

private func decode(_ json: String) throws -> CleanupModelSettings {
    try JSONDecoder().decode(CleanupModelSettings.self, from: Data(json.utf8))
}

private let home = ServerConfig(baseURL: URL(string: "http://127.0.0.1:7821/chirp")!, token: "tok")

@Suite struct KeepLoadedDecodingTests {
    @Test func decodesTheDocumentedShape() throws {
        let s = try decode(loadedJSON)
        #expect(s == CleanupModelSettings(keepLoaded: true, loaded: true, loading: false, model: "qwen3-4b", memoryMB: 2662,
                                          memoryEstimated: false, mode: .managed))
        #expect(s.memoryText == "2.6 GB")
        let e = try decode(estimateJSON)
        #expect(!e.keepLoaded && e.memoryEstimated && e.memoryText == "about 2.6 GB")
        #expect(try decode(loadingJSON).loading)
    }

    @Test func nullMemoryAndModelAndEveryMode() throws {
        let off = try decode(offJSON)
        #expect(off.mode == .off && off.model == nil && off.memoryMB == nil && off.memoryText == nil)
        let endpoint = try decode(#"{"keep_loaded":false,"loaded":false,"loading":false,"model":null,"memory_mb":null,"memory_estimated":false,"mode":"endpoint"}"#)
        #expect(endpoint.mode == .endpoint)
        #expect(try decode(#"{"keep_loaded":false,"mode":"cluster"}"#).mode == .other("cluster"))
    }

    @Test func missingOptionalFieldsTakeDefaultsButKeepLoadedIsRequired() throws {
        let s = try decode(#"{"keep_loaded":true}"#)
        #expect(s.keepLoaded && !s.loaded && !s.loading && s.model == nil && s.memoryMB == nil && !s.memoryEstimated && s.mode == .managed)
        #expect(throws: DecodingError.self) { try decode(#"{"loaded":true}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"keep_loaded":"yes"}"#) }
    }

    @Test func authenticatedHealthCarriesTheTwoNewFlagsAndOlderHealthDoesNot() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let h = try decoder.decode(Health.self, from: Data(#"{"ok":true,"correction":"available","correction_keep_loaded":true,"correction_loaded":false}"#.utf8))
        #expect(h.correctionKeepLoaded == true && h.correctionLoaded == false)
        let old = try decoder.decode(Health.self, from: Data(#"{"ok":true}"#.utf8))
        #expect(old.correctionKeepLoaded == nil && old.correctionLoaded == nil)
    }
}

@Suite struct KeepLoadedFormattingTests {
    @Test func megabytesBecomeGigabytesWithOneDecimal() {
        #expect(KeepLoaded.memoryText(mb: 2662, estimated: false) == "2.6 GB")
        #expect(KeepLoaded.memoryText(mb: 2662, estimated: true) == "about 2.6 GB")
        #expect(KeepLoaded.memoryText(mb: 1024, estimated: false) == "1.0 GB")
        #expect(KeepLoaded.memoryText(mb: 3072, estimated: false) == "3.0 GB")
        #expect(KeepLoaded.memoryText(mb: 512, estimated: false) == "0.5 GB")
        #expect(KeepLoaded.memoryText(mb: 0, estimated: false) == "0.0 GB")
        #expect(KeepLoaded.memoryText(mb: 10_240, estimated: true) == "about 10.0 GB")
        // rounds, never truncates: 2.65 GB is 2713.6 MB
        #expect(KeepLoaded.memoryText(mb: 2714, estimated: false) == "2.7 GB")
        #expect(KeepLoaded.memoryText(mb: -5, estimated: false) == "0.0 GB")
    }

    @Test func hostPhraseFollowsTheGlossaryForLocalAndRemoteServers() {
        #expect(KeepLoaded.hostPhrase(ServerConfig()) == "this Mac")
        #expect(KeepLoaded.hostPhrase(ServerConfig(baseURL: URL(string: "http://localhost:7821")!)) == "this Mac")
        #expect(KeepLoaded.hostPhrase(ServerConfig(baseURL: URL(string: "https://mainframe.example.ts.net/chirp")!)) == "your Chirp server")
    }
}

@Suite(.serialized) struct KeepLoadedRequestTests {
    @Test func putBodyIsExactlyTheDocumentedObject() {
        #expect(String(decoding: ServerConfig.keepLoadedBody(true), as: UTF8.self) == #"{"keep_loaded":true}"#)
        #expect(String(decoding: ServerConfig.keepLoadedBody(false), as: UTF8.self) == #"{"keep_loaded":false}"#)
    }

    @Test func getHitsTheSettingsRouteWithTheToken() async throws {
        let session = SettingsFake.session(SettingsFake.reply(200, loadedJSON))
        let s = try await home.fetchCleanupSettings(session: session)
        #expect(s.loaded && s.memoryMB == 2662)
        let seen = try #require(SettingsFake.seen.first)
        #expect(seen.method == "GET" && seen.path == "/chirp/v1/correction/settings")
        #expect(seen.auth == "Bearer tok" && seen.body == nil)
    }

    @Test func putSendsTheBodyAndAnswersLikeGet() async throws {
        for on in [true, false] {
            let session = SettingsFake.session(SettingsFake.reply(200, on ? loadingJSON : estimateJSON))
            let s = try await home.setKeepLoaded(on, session: session)
            #expect(s.keepLoaded == on)
            let seen = try #require(SettingsFake.seen.first)
            #expect(seen.method == "PUT" && seen.path == "/chirp/v1/correction/settings")
            #expect(seen.auth == "Bearer tok" && seen.contentType == "application/json")
            #expect(seen.body.map { String(decoding: $0, as: UTF8.self) } == (on ? #"{"keep_loaded":true}"# : #"{"keep_loaded":false}"#))
        }
    }

    @Test func statusCodesMapToErrors() async {
        let cases: [(Int, CleanupSettingsError)] = [(401, .unauthorized), (404, .serverTooOld), (409, .unsupported),
                                                    (400, .badRequest), (500, .server(500)), (503, .server(503))]
        for (status, expected) in cases {
            let session = SettingsFake.session(SettingsFake.reply(status, #"{"error":{"code":"x"}}"#))
            await #expect(throws: expected) { try await home.fetchCleanupSettings(session: session) }
            await #expect(throws: expected) { try await home.setKeepLoaded(true, session: session) }
        }
    }

    @Test func aDeadNetworkAndAGarbledAnswerAreTold() async {
        for code in [URLError.Code.notConnectedToInternet, .cannotConnectToHost, .timedOut] {
            let session = SettingsFake.session { _ in .failure(URLError(code)) }
            await #expect(throws: CleanupSettingsError.unreachable) { try await home.fetchCleanupSettings(session: session) }
            await #expect(throws: CleanupSettingsError.unreachable) { try await home.setKeepLoaded(false, session: session) }
        }
        let garbled = SettingsFake.session(SettingsFake.reply(200, "<html>"))
        await #expect(throws: CleanupSettingsError.malformed) { try await home.fetchCleanupSettings(session: garbled) }
    }

    @Test func everyErrorHasAnInlineSentence() {
        let all: [CleanupSettingsError] = [.unauthorized, .serverTooOld, .unsupported, .badRequest, .unreachable, .server(500), .malformed]
        for e in all { #expect(!e.changeFailure.isEmpty) }
        #expect(CleanupSettingsError.serverTooOld.changeFailure == "Update the Chirp server to use this.")
        #expect(CleanupSettingsError.server(502).changeFailure.contains("502"))
    }
}

@Suite struct KeepLoadedStateTests {
    private func available(_ json: String) throws -> KeepLoadedState {
        var s = KeepLoadedState()
        s.fetched(try decode(json))
        return s
    }

    @Test func startsUnknownAndDisabled() {
        let p = KeepLoadedPresentation(KeepLoadedState())
        #expect(!p.isEnabled && !p.isOn && p.status == nil && p.help == "Checking the server…")
    }

    @Test func aManagedServerOffersTheSwitchWithItsCost() throws {
        var s = try available(estimateJSON)
        #expect(s.availability == .available)
        var p = KeepLoadedPresentation(s, host: "this Mac")
        #expect(p.isEnabled && !p.isOn && p.status == "Not loaded")
        #expect(p.help == "Keeps the clean-up model in memory, so clean-up starts instantly instead of loading the model after a pause. Uses about 2.6 GB of RAM on this Mac.")
        s = try available(loadedJSON)
        p = KeepLoadedPresentation(s, host: "mainframe")
        #expect(p.isOn && p.status == "Loaded · 2.6 GB" && p.statusTone == .ok)
        #expect(p.help.hasSuffix("Uses 2.6 GB of RAM on mainframe."))
        s = try available(loadingJSON)
        p = KeepLoadedPresentation(s)
        #expect(p.isOn && p.status == "Loading…" && p.statusTone == .busy && s.isLoading)
    }

    @Test func withoutAMemoryFigureTheHelpOmitsTheCost() throws {
        let s = try available(#"{"keep_loaded":false,"mode":"managed"}"#)
        let p = KeepLoadedPresentation(s)
        #expect(p.help == "Keeps the clean-up model in memory, so clean-up starts instantly instead of loading the model after a pause.")
        let loaded = try available(#"{"keep_loaded":true,"loaded":true,"mode":"managed"}"#)
        #expect(KeepLoadedPresentation(loaded).status == "Loaded")
    }

    @Test func offAndEndpointModesDisableItWithAReason() throws {
        var s = try available(loadedJSON)
        s.fetched(try decode(offJSON))
        #expect(s.availability == .unavailable(.cleanupOff) && s.settings == nil)
        var p = KeepLoadedPresentation(s)
        #expect(!p.isEnabled && !p.isOn && p.help == "The server has clean-up turned off." && p.status == nil)
        s.fetched(try decode(#"{"keep_loaded":false,"mode":"endpoint"}"#))
        #expect(s.availability == .unavailable(.remoteModel))
        p = KeepLoadedPresentation(s)
        #expect(!p.isEnabled && p.help == "Not needed: this server sends text to a remote model.")
        // coming back to managed offers it again
        s.fetched(try decode(estimateJSON))
        #expect(s.availability == .available)
    }

    @Test func fetchFailuresDisableItWithTheRightReason() throws {
        var s = try available(loadedJSON)
        s.fetchFailed(.serverTooOld)
        #expect(KeepLoadedPresentation(s).help == "Update the Chirp server to use this." && !KeepLoadedPresentation(s).isEnabled)
        for e in [CleanupSettingsError.unreachable, .server(500), .malformed, .badRequest] {
            s = try available(loadedJSON)
            s.fetchFailed(e)
            #expect(s.availability == .unavailable(.unreachable) && KeepLoadedPresentation(s).help == "Can’t reach the server.")
        }
        s.fetchFailed(.unauthorized)
        #expect(s.availability == .unavailable(.unauthorized))
        // and it recovers when the server answers again
        s.fetched(try decode(loadedJSON))
        #expect(s.availability == .available && KeepLoadedPresentation(s).isEnabled)
    }

    @Test func theSwitchChangesAtOnceAndLocksUntilTheServerAnswers() throws {
        var s = try available(estimateJSON)
        let ok = s.toggle(to: true)
        #expect(ok)
        var p = KeepLoadedPresentation(s)
        #expect(p.isOn && !p.isEnabled && p.status == "Loading…" && p.error == nil)
        let second = s.toggle(to: false)
        #expect(!second)   // one change at a time
        s.toggleSucceeded(try decode(loadingJSON))
        p = KeepLoadedPresentation(s)
        #expect(p.isOn && p.isEnabled && p.status == "Loading…")
        s.fetched(try decode(loadedJSON))
        #expect(KeepLoadedPresentation(s).status == "Loaded · 2.6 GB")
    }

    @Test func turningItOffKeepsTheStatusUntilTheIdleTimerUnloads() throws {
        var s = try available(loadedJSON)
        let off = s.toggle(to: false)
        #expect(off)
        var p = KeepLoadedPresentation(s)
        #expect(!p.isOn && !p.isEnabled && p.status == "Loaded · 2.6 GB")
        s.toggleSucceeded(try decode(#"{"keep_loaded":false,"loaded":true,"mode":"managed","memory_mb":2662}"#))
        p = KeepLoadedPresentation(s)
        #expect(!p.isOn && p.isEnabled && p.status == "Loaded · 2.6 GB")
    }

    @Test func aFailedChangeRevertsAndShowsTheErrorInline() throws {
        var s = try available(estimateJSON)
        _ = s.toggle(to: true)
        s.toggleFailed(.unreachable)
        let p = KeepLoadedPresentation(s)
        #expect(!p.isOn && p.isEnabled && p.error == CleanupSettingsError.unreachable.changeFailure && p.status == "Not loaded")
        // a new attempt clears the error
        let again = s.toggle(to: true)
        #expect(again)
        #expect(KeepLoadedPresentation(s).error == nil)
        s.toggleFailed(.badRequest)
        #expect(KeepLoadedPresentation(s).error == CleanupSettingsError.badRequest.changeFailure)
        s.toggleFailed(.server(500))
        #expect(KeepLoadedPresentation(s).error?.contains("500") == true)
    }

    @Test func aRefusalThatMeansItCannotWorkStopsOfferingTheSwitch() throws {
        var s = try available(estimateJSON)
        _ = s.toggle(to: true)
        s.toggleFailed(.unsupported)
        #expect(s.availability == .unavailable(.remoteModel) && !KeepLoadedPresentation(s).isOn && KeepLoadedPresentation(s).error == nil)
        s = try available(estimateJSON)
        _ = s.toggle(to: true)
        s.toggleFailed(.serverTooOld)
        #expect(KeepLoadedPresentation(s).help == "Update the Chirp server to use this.")
        s = try available(estimateJSON)
        _ = s.toggle(to: true)
        s.toggleFailed(.unauthorized)
        #expect(s.availability == .unavailable(.unauthorized))
    }

    @Test func aRefreshLandingDuringAChangeDoesNotUndoIt() throws {
        var s = try available(estimateJSON)
        _ = s.toggle(to: true)
        s.fetched(try decode(estimateJSON))
        s.fetchFailed(.unreachable)
        #expect(s.pending == true && s.availability == .available && KeepLoadedPresentation(s).isOn)
    }

    @Test func cannotToggleWhileUnavailable() {
        var s = KeepLoadedState()
        let first = s.toggle(to: true)
        s.fetchFailed(.serverTooOld)
        let second = s.toggle(to: true)
        #expect(!first && !second && s.pending == nil)
    }
}

@MainActor @Suite struct KeepLoadedFormTests {
    private func form(_ state: KeepLoadedState, host: String = "this Mac") -> SettingsForm {
        var s = SettingsState()
        s.keepLoaded = state
        s.serverHost = host
        return SettingsForm(s)
    }

    private func texts(in view: NSView) -> [String] {
        var out: [String] = []
        func walk(_ v: NSView) {
            if let f = v as? NSTextField, !f.isHidden { out.append(f.stringValue) }
            for sub in v.subviews where !sub.isHidden { walk(sub) }
        }
        walk(view)
        return out
    }

    @Test func theSwitchIsOnTheCleanupPageWithItsVoiceOverLabel() throws {
        let f = form(KeepLoadedState(settings: try decode(loadedJSON), availability: .available))
        #expect(f.keepLoaded.title == "Keep clean-up ready")
        #expect(f.keepLoaded.state == .on && f.keepLoaded.isEnabled)
        #expect(f.keepLoaded.isDescendant(of: f.view(for: .cleanup)))
        #expect(f.keepLoaded.accessibilityHelp()?.contains("2.6 GB") == true)
        let shown = texts(in: f.view(for: .cleanup))
        #expect(shown.contains("Loaded · 2.6 GB"))
        #expect(shown.contains("Keeps the clean-up model in memory, so clean-up starts instantly instead of loading the model after a pause. Uses 2.6 GB of RAM on this Mac."))
    }

    @Test func followsTheStateThroughTransitions() throws {
        let f = form(KeepLoadedState())
        #expect(!f.keepLoaded.isEnabled && f.keepLoaded.state == .off)
        #expect(texts(in: f.view(for: .cleanup)).contains("Checking the server…"))

        var s = KeepLoadedState(settings: try decode(estimateJSON), availability: .available)
        f.showKeepLoaded(s, host: "mainframe.example.ts.net")
        #expect(f.keepLoaded.isEnabled && f.keepLoaded.state == .off)
        var shown = texts(in: f.view(for: .cleanup))
        #expect(shown.contains("Not loaded"))
        #expect(shown.contains { $0.hasSuffix("Uses about 2.6 GB of RAM on mainframe.example.ts.net.") })

        _ = s.toggle(to: true)
        f.showKeepLoaded(s, host: "this Mac")
        #expect(f.keepLoaded.state == .on && !f.keepLoaded.isEnabled)
        #expect(texts(in: f.view(for: .cleanup)).contains("Loading…"))

        s.toggleFailed(.unreachable)
        f.showKeepLoaded(s, host: "this Mac")
        #expect(f.keepLoaded.state == .off && f.keepLoaded.isEnabled)
        shown = texts(in: f.view(for: .cleanup))
        #expect(shown.contains(CleanupSettingsError.unreachable.changeFailure))

        _ = s.toggle(to: true)
        s.toggleSucceeded(try decode(loadedJSON))
        f.showKeepLoaded(s, host: "this Mac")
        shown = texts(in: f.view(for: .cleanup))
        #expect(f.keepLoaded.state == .on && shown.contains("Loaded · 2.6 GB") && !shown.contains(CleanupSettingsError.unreachable.changeFailure))
    }

    @Test func unavailableDisablesItWithOneLineOfReason() {
        for (why, line) in [(KeepLoaded.Unavailable.cleanupOff, "The server has clean-up turned off."),
                            (.remoteModel, "Not needed: this server sends text to a remote model."),
                            (.serverTooOld, "Update the Chirp server to use this."),
                            (.unreachable, "Can’t reach the server.")] {
            let f = form(KeepLoadedState(availability: .unavailable(why)))
            #expect(!f.keepLoaded.isEnabled && f.keepLoaded.state == .off)
            let shown = texts(in: f.view(for: .cleanup))
            #expect(shown.contains(line))
            #expect(!shown.contains("Loading…") && !shown.contains("Not loaded"))
        }
    }

    @Test func theCleanupPageStillHasAMeasuredSize() {
        // the row must not break the page's measured size
        let f = form(KeepLoadedState())
        let size = f.fittingSize(for: .cleanup)
        #expect(size.width == SettingsForm.pageWidth && size.height > 300)
    }

    @Test func itSitsNearTheTopOfCleanupAndIsGoneFromAdvanced() {
        let f = form(KeepLoadedState())
        #expect(!f.keepLoaded.isDescendant(of: f.view(for: .advanced)))
        let page = f.view(for: .cleanup)
        page.layoutSubtreeIfNeeded()
        // Right under the on/off switch and the style, above the long style-prompt editor.
        let keep = f.keepLoaded.convert(f.keepLoaded.bounds, to: page)
        let prompts = f.prompts.view.convert(f.prompts.view.bounds, to: page)
        let enabled = f.cleanupEnabled.convert(f.cleanupEnabled.bounds, to: page)
        #expect(page.isFlipped ? (keep.minY > enabled.minY && keep.minY < prompts.minY) : (keep.minY < enabled.minY && keep.minY > prompts.minY))
    }
}

@Suite struct KeepLoadedHintTests {
    private let cold = CleanupModelSettings(keepLoaded: false, loaded: false, model: "qwen3-4b", memoryMB: 2662)

    @Test func coldOnlyForAManagedModelThatIsNotKeptReady() {
        #expect(KeepLoadedHint.coldLoad(cold))
        #expect(KeepLoadedHint.coldLoad(CleanupModelSettings(keepLoaded: false, loaded: false, loading: true)))
        // Already in memory: the wait was the generation itself, which this switch would not shorten.
        #expect(!KeepLoadedHint.coldLoad(CleanupModelSettings(keepLoaded: false, loaded: true)))
        // Already kept ready, or no local model to keep.
        #expect(!KeepLoadedHint.coldLoad(CleanupModelSettings(keepLoaded: true, loaded: false, loading: true)))
        #expect(!KeepLoadedHint.coldLoad(CleanupModelSettings(keepLoaded: false, mode: .endpoint)))
        #expect(!KeepLoadedHint.coldLoad(CleanupModelSettings(keepLoaded: false, mode: .off)))
    }

    @Test func showsOnceAfterANoticeableColdWait() {
        #expect(KeepLoadedHint.shouldShow(alreadyShown: false, cold: true, waited: 2.0))
        #expect(KeepLoadedHint.shouldShow(alreadyShown: false, cold: true, waited: 5.4))
        #expect(!KeepLoadedHint.shouldShow(alreadyShown: false, cold: true, waited: 1.2))
        #expect(!KeepLoadedHint.shouldShow(alreadyShown: false, cold: false, waited: 5.4))
        #expect(!KeepLoadedHint.shouldShow(alreadyShown: true, cold: true, waited: 5.4))
    }

    @Test func theWordingNamesWhereToFixIt() {
        #expect(KeepLoadedHint.message == "Clean-up was loading its model. Keep it ready in Settings → Clean-up.")
        // Two lines of the island's message body at most.
        #expect(KeepLoadedHint.message.count <= 80)
        #expect(LocalModelsView.keepReadyNote.contains("Keep clean-up ready in Settings → Clean-up"))
    }
}
