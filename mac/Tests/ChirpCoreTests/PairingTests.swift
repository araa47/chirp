import AppKit
import CoreImage
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

private let host = "my-mac.example-tailnet.ts.net"
private let sampleToken = "test-only-token-aB3_-x"

@Suite struct PairingLinkTests {
    @Test func theLinkIsWhatChirpServerPairPrints() throws {
        // Python: urlencode({"url": ..., "token": ...}), as `chirp-server pair` builds it.
        let link = try PairingLink(serverURL: URL(string: "https://\(host)/chirp")!, token: "aB3_-x\n")
        #expect(link.uri == "chirp://pair?url=https%3A%2F%2Fmy-mac.example-tailnet.ts.net%2Fchirp&token=aB3_-x")
        #expect(PairingLink.formEncode("a b+c/=~é") == "a+b%2Bc%2F%3D~%C3%A9")
    }

    @Test func thePhoneReadsBackTheSameURLAndToken() throws {
        let link = try PairingLink(serverURL: TailscaleServe.pairingURL(host: host), token: sampleToken)
        let parts = try #require(URLComponents(string: link.uri))
        #expect(parts.scheme == "chirp" && parts.host == "pair")
        let items = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items == ["url": "https://\(host)/chirp", "token": sampleToken])
    }

    @Test func itRefusesWhatChirpServerPairRefuses() {
        for bad in ["ftp://\(host)/chirp", "https://user:pw@\(host)/chirp", "chirp://pair", "/chirp"] {
            #expect(throws: PairingError.invalidURL) { try PairingLink(serverURL: URL(string: bad)!, token: sampleToken) }
        }
        #expect(throws: PairingError.noToken) { try PairingLink(serverURL: URL(string: "https://\(host)/chirp")!, token: " \n") }
    }

    @Test func theTokenNeverShowsInDescriptionsOrDumps() throws {
        let link = try PairingLink(serverURL: TailscaleServe.pairingURL(host: host), token: sampleToken)
        var dumped = ""
        dump(link, to: &dumped)
        for text in ["\(link)", String(reflecting: link), dumped, "\(PairingStep.ready(link))", String(reflecting: PairingStep.ready(link))] {
            #expect(!text.contains(sampleToken), "\(text)")
        }
    }

    @Test func theSharedTokenSourceReadsTheTokenFileLikeChirpServer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("token").path
        await #expect(throws: PairingError.noToken) { try await SharedTokenPairing(tokenPath: path).link(serverURL: TailscaleServe.pairingURL(host: host)) }
        try (sampleToken + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let link = try await SharedTokenPairing(tokenPath: path).link(serverURL: TailscaleServe.pairingURL(host: host))
        #expect(link == (try PairingLink(serverURL: URL(string: "https://\(host)/chirp")!, token: sampleToken)))
    }
}

@Suite struct TailscaleServeTests {
    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    static func serve(_ handlers: [String: Any], host: String = host, funnel: Bool = false) -> Data {
        var root: [String: Any] = ["TCP": ["443": ["HTTPS": true]], "Web": ["\(host):443": ["Handlers": handlers]]]
        if funnel { root["AllowFunnel"] = ["\(host):443": true] }
        return json(root)
    }

    @Test func readsThisMacsMagicDNSName() {
        let running = Self.json(["BackendState": "Running", "Self": ["DNSName": "My-Mac.example-tailnet.ts.net."]])
        #expect(TailscaleServe.dnsName(statusJSON: running) == host)
        // The CLI may warn about a version mismatch before the JSON.
        #expect(TailscaleServe.dnsName(statusJSON: Data("Warning: client version \"1\" != tailscaled server version \"2\"\n".utf8) + running) == host)
        #expect(TailscaleServe.dnsName(statusJSON: Self.json(["BackendState": "Stopped", "Self": ["DNSName": "\(host)."]])) == nil)
        #expect(TailscaleServe.dnsName(statusJSON: Self.json(["BackendState": "NeedsLogin", "Self": ["DNSName": ""]])) == nil)
        #expect(TailscaleServe.dnsName(statusJSON: Data("failed to connect to local tailscaled".utf8)) == nil)
    }

    @Test func servedOnlyWhenChirpProxiesToThisServer() {
        #expect(TailscaleServe.status(serveJSON: Self.serve(["/chirp": ["Proxy": "http://127.0.0.1:7821"], "/other": ["Proxy": "http://127.0.0.1:7710"]]),
                                      host: host, port: 7821) == .served)
        #expect(TailscaleServe.status(serveJSON: Self.serve(["/chirp": ["Proxy": "http://localhost:7821"]]), host: host, port: 7821) == .served)
        #expect(TailscaleServe.status(serveJSON: Self.serve(["/chirp": ["Proxy": "http://127.0.0.1:9000"]]), host: host, port: 7821)
                == .conflict("http://127.0.0.1:9000"))
        #expect(TailscaleServe.status(serveJSON: Self.serve(["/chirp": ["Text": "hi"]]), host: host, port: 7821) == .conflict("another handler"))
        #expect(TailscaleServe.status(serveJSON: Self.serve(["/koi": ["Proxy": "http://127.0.0.1:7710"]]), host: host, port: 7821) == .notServed)
        #expect(TailscaleServe.status(serveJSON: Data("{}".utf8), host: host, port: 7821) == .notServed)
        // Another node's name in the config is not this Mac.
        #expect(TailscaleServe.status(serveJSON: Self.serve(["/chirp": ["Proxy": "http://127.0.0.1:7821"]], host: "other.example-tailnet.ts.net"),
                                      host: host, port: 7821) == .notServed)
        #expect(TailscaleServe.status(serveJSON: Data("not json".utf8), host: host, port: 7821) == .unreadable)
    }

    @Test func funnelOnThisHostBlocksPairing() {
        #expect(TailscaleServe.status(serveJSON: Self.serve(["/chirp": ["Proxy": "http://127.0.0.1:7821"]], funnel: true), host: host, port: 7821) == .funnel)
        #expect(TailscaleServe.status(serveJSON: Self.serve([:], funnel: true), host: host, port: 7821) == .funnel)
    }

    @Test func aForegroundServeSessionCounts() {
        let session: [String: Any] = ["Web": ["\(host):443": ["Handlers": ["/chirp": ["Proxy": "http://127.0.0.1:7821"]]]]]
        #expect(TailscaleServe.status(serveJSON: Self.json(["Foreground": ["abc": session]]), host: host, port: 7821) == .served)
    }

    @Test func thePublishCommandIsTailnetOnly() {
        #expect(TailscaleServe.publishArguments(port: 7821) == ["serve", "--bg", "--set-path", "/chirp", "http://127.0.0.1:7821"])
        #expect(TailscaleServe.publishCommand(port: 7821) == "tailscale serve --bg --set-path /chirp http://127.0.0.1:7821")
        #expect(!TailscaleServe.publishArguments(port: 7821).contains { $0.contains("funnel") })
        #expect(TailscaleServe.pairingURL(host: host).absoluteString == "https://\(host)/chirp")
    }

    @Test func findsTheCLIWithoutAShellPath() {
        #expect(TailscaleServe.findCLI { $0 == "/opt/homebrew/bin/tailscale" }?.path == "/opt/homebrew/bin/tailscale")
        #expect(TailscaleServe.findCLI { _ in true }?.path == "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        #expect(TailscaleServe.findCLI { _ in false } == nil)
    }
}

/// A Tailscale CLI that answers from a table and records what it was asked to run.
private final class FakeCLI: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: CommandResult] = [:]
    private var calls: [[String]] = []
    var ran: [[String]] { lock.withLock { calls } }
    func answer(_ args: String, _ result: CommandResult) { lock.withLock { answers[args] = result } }
    var run: CommandRunner {
        { [self] _, arguments, _ in
            lock.withLock {
                calls.append(arguments)
                return answers[arguments.joined(separator: " ")] ?? CommandResult(status: 1, error: "unexpected")
            }
        }
    }

    static func running() -> FakeCLI {
        let cli = FakeCLI()
        cli.answer("status --json", CommandResult(status: 0, output: TailscaleServeTests.json(["BackendState": "Running", "Self": ["DNSName": "\(host)."]])))
        return cli
    }
}

private struct FixedLinks: PairingLinkMaker {
    var token: String? = sampleToken
    func link(serverURL: URL) async throws -> PairingLink {
        guard let token else { throw PairingError.noToken }
        return try PairingLink(serverURL: serverURL, token: token)
    }
}

@MainActor
@Suite struct PairingFlowTests {
    private func flow(_ cli: FakeCLI, server: String = "http://127.0.0.1:7821", installed: Bool = true, links: PairingLinkMaker = FixedLinks()) -> PairingFlow {
        PairingFlow(serverURL: { URL(string: server)! }, cli: { installed ? URL(fileURLWithPath: "/fake/tailscale") : nil },
                    run: cli.run, links: links)
    }

    @Test func servedGivesTheLinkToTheTailnetURL() async throws {
        let cli = FakeCLI.running()
        cli.answer("serve status --json", CommandResult(status: 0, output: TailscaleServeTests.serve(["/chirp": ["Proxy": "http://127.0.0.1:7821"]])))
        let f = flow(cli)
        await f.check()
        let link = try PairingLink(serverURL: URL(string: "https://\(host)/chirp")!, token: sampleToken)
        #expect(f.step == .ready(link))
        // Read-only checks only.
        #expect(cli.ran == [["status", "--json"], ["serve", "status", "--json"]])
    }

    @Test func notServedShowsTheCommandAndRunsItOnlyOnPublish() async throws {
        let cli = FakeCLI.running()
        cli.answer("serve status --json", CommandResult(status: 0, output: Data("{}".utf8)))
        let f = flow(cli, server: "http://localhost:7900")
        await f.check()
        #expect(f.step == .notServed(command: "tailscale serve --bg --set-path /chirp http://127.0.0.1:7900"))
        #expect(!cli.ran.contains { $0.contains("--set-path") })
        cli.answer("serve --bg --set-path /chirp http://127.0.0.1:7900", CommandResult(status: 0))
        cli.answer("serve status --json", CommandResult(status: 0, output: TailscaleServeTests.serve(["/chirp": ["Proxy": "http://127.0.0.1:7900"]])))
        await f.publish()
        #expect(cli.ran.filter { $0.contains("--set-path") } == [["serve", "--bg", "--set-path", "/chirp", "http://127.0.0.1:7900"]])
        guard case .ready = f.step else { Issue.record("\(f.step)"); return }
    }

    @Test func aFailedPublishSaysWhyAndCanBeRetried() async {
        let cli = FakeCLI.running()
        cli.answer("serve status --json", CommandResult(status: 0, output: Data("{}".utf8)))
        cli.answer("serve --bg --set-path /chirp http://127.0.0.1:7821",
                   CommandResult(status: -1, output: Data("Serve is not enabled on your tailnet.\nTo enable, visit the admin console.\n".utf8)))
        let f = flow(cli)
        await f.check()
        await f.publish()
        let command = TailscaleServe.publishCommand(port: 7821)
        #expect(f.step == .publishFailed(command: command, reason: "Serve is not enabled on your tailnet.\nTo enable, visit the admin console."))
        #expect(PairingPresentation(f.step).action == "Run Command…")
    }

    @Test func publishDoesNothingUnlessTheCommandWasShown() async {
        let cli = FakeCLI.running()
        cli.answer("serve status --json", CommandResult(status: 0, output: TailscaleServeTests.serve(["/chirp": ["Proxy": "http://127.0.0.1:9000"]])))
        let f = flow(cli)
        await f.check()
        #expect(f.step == .conflict("http://127.0.0.1:9000"))
        await f.publish()
        #expect(!cli.ran.contains { $0.contains("--set-path") })
    }

    @Test func eachReasonItCannotPair() async {
        let cli = FakeCLI.running()
        cli.answer("serve status --json", CommandResult(status: 0, output: TailscaleServeTests.serve([:], funnel: true)))
        var f = flow(cli)
        await f.check()
        #expect(f.step == .funnel)
        f = flow(cli, server: "https://other.example-tailnet.ts.net/chirp")
        await f.check()
        #expect(f.step == .remoteServer("other.example-tailnet.ts.net") && cli.ran.count == 2)
        f = flow(cli, installed: false)
        await f.check()
        #expect(f.step == .noTailscale)
        let stopped = FakeCLI()
        stopped.answer("status --json", CommandResult(status: 1, output: TailscaleServeTests.json(["BackendState": "Stopped", "Self": [:]])))
        f = flow(stopped)
        await f.check()
        #expect(f.step == .tailscaleOff)
        cli.answer("serve status --json", CommandResult(status: 0, output: TailscaleServeTests.serve(["/chirp": ["Proxy": "http://127.0.0.1:7821"]])))
        f = flow(cli, links: FixedLinks(token: nil))
        await f.check()
        #expect(f.step == .noToken)
        cli.answer("serve status --json", CommandResult(status: 1, error: "permission denied"))
        f = flow(cli)
        await f.check()
        #expect(f.step == .failed("permission denied"))
    }

    @Test func resetForgetsTheLinkAndDropsALateAnswer() async {
        let cli = FakeCLI.running()
        cli.answer("serve status --json", CommandResult(status: 0, output: TailscaleServeTests.serve(["/chirp": ["Proxy": "http://127.0.0.1:7821"]])))
        let f = flow(cli)
        let pending = Task { await f.check() }
        f.reset()
        await pending.value
        // Whichever ran first, a reset afterwards always leaves no link.
        f.reset()
        #expect(f.step == .checking)
    }
}

/// Sleeps park until the test lets them go.
private final class ParkedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var count: Int { lock.withLock { parked.count } }
    var sleep: @Sendable (Duration) async -> Void {
        { [self] _ in await withCheckedContinuation { c in park { parked.append(c) } } }
    }
    /// Suspends until a sleep has parked. It never spins: under load a `Task.yield()` loop starves the pool (#315).
    func waitForSleeper() async { await withCheckedContinuation { c in park { waiters.append(c) } } }
    /// Runs `change` under the lock, then wakes the waiters once a sleep is parked.
    private func park(_ change: () -> Void) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            change()
            guard !parked.isEmpty else { return [] }
            defer { waiters = [] }
            return waiters
        }
        for c in ready { c.resume() }
    }
    func fire() { let s = lock.withLock { let s = parked; parked = []; return s }; for c in s { c.resume() } }
}

@MainActor
@Suite struct PairingTimerTests {
    @Test func countsDownTwoMinutesThenHidesOnce() async {
        let clock = ParkedClock()
        let timer = PairingTimer(sleep: clock.sleep)
        var ticks: [Int] = []
        var expired = 0
        timer.onTick = { ticks.append($0) }
        timer.onExpire = { expired += 1 }
        timer.start()
        #expect(timer.remaining == 120 && timer.isRunning && ticks == [120])
        for _ in 0..<120 {
            await clock.waitForSleeper()
            clock.fire()
            await Task.yield()
        }
        #expect(await pollUntil(within: 60) { expired > 0 })
        #expect(ticks == Array((0...120).reversed()) && expired == 1 && !timer.isRunning)
        #expect(PairingTimer.text(107) == "1:47" && PairingTimer.text(5) == "0:05")
    }

    @Test func cancelStopsItWithoutHiding() async {
        let clock = ParkedClock()
        let timer = PairingTimer(sleep: clock.sleep)
        var expired = false
        timer.onExpire = { expired = true }
        timer.start(seconds: 1)
        await clock.waitForSleeper()
        timer.cancel()
        clock.fire()
        for _ in 0..<20 { await Task.yield() }
        #expect(!expired && !timer.isRunning)
    }
}

@MainActor
@Suite struct PairingViewTests {
    static let link = try! PairingLink(serverURL: TailscaleServe.pairingURL(host: host), token: sampleToken)

    /// Reads the QR code back the way a phone camera would.
    static func decode(_ image: NSImage, side: Int = 600) -> String? {
        let height = Int((Double(side) * image.size.height / max(image.size.width, 1)).rounded())
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: side, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: height).insetBy(dx: CGFloat(side) / 15, dy: CGFloat(height) / 15))
        NSGraphicsContext.restoreGraphicsState()
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(bitmapImageRep: rep)!).first as? CIQRCodeFeature)?.messageString
    }

    @Test func theQRCodeCarriesExactlyTheLink() throws {
        let image = try #require(QRCode.image(Self.link.uri, side: 220))
        #expect(Self.decode(image) == Self.link.uri)
        // Blurred past reading.
        let blurred = try #require(QRCode.blurred(Self.link.uri, side: 220))
        #expect(Self.decode(blurred) == nil)
    }

    @Test func readyShowsTheCodeAndConcealedBlursItAndLocksCopy() throws {
        let view = PairingView()
        view.apply(.ready(Self.link), remaining: 65)
        #expect(view.copyLink.isEnabled && view.action.isHidden && !view.isConcealed)
        let images = Self.images(in: view)
        let sharp = try #require(images.first)
        #expect(Self.decode(sharp) == Self.link.uri)
        #expect(Self.texts(in: view).contains("Hides in 1:05") && Self.texts(in: view).contains(PairingView.secretWarning))
        view.apply(.ready(Self.link), remaining: 64, concealed: true)
        #expect(!view.copyLink.isEnabled && view.isConcealed)
        let concealed = try #require(Self.images(in: view).first)
        #expect(concealed !== sharp && Self.decode(concealed) == nil)
        #expect(Self.texts(in: view).contains(PairingView.concealedText))
        // Hidden or closed: no image encodes the link any more.
        view.forget()
        #expect(Self.images(in: view).isEmpty && !view.copyLink.isEnabled)
    }

    @Test func notServedShowsTheExactCommandAndAsks() {
        let view = PairingView()
        let command = TailscaleServe.publishCommand(port: 7821)
        view.apply(.notServed(command: command))
        #expect(Self.texts(in: view).contains(command))
        #expect(!view.action.isHidden && view.action.title == "Run Command…" && !view.copyLink.isEnabled)
        let p = PairingPresentation(.notServed(command: command))
        #expect(p.detail.contains("never the internet") && p.detail.contains(TailscaleServe.undoCommand) && !p.showsCode)
    }

    @Test func everyStepHasWordsAndOnlyReadyShowsACode() throws {
        let steps: [PairingStep] = [.checking, .remoteServer("h"), .noTailscale, .tailscaleOff, .notServed(command: "c"), .publishing(command: "c"),
                                    .publishFailed(command: "c", reason: "r"), .conflict("t"), .funnel, .failed("r"), .noToken, .ready(Self.link)]
        for step in steps {
            let p = PairingPresentation(step)
            #expect(!p.headline.isEmpty && !p.detail.isEmpty)
            #expect(p.showsCode == (step == .ready(Self.link)))
            #expect(!p.detail.contains(sampleToken) && !p.headline.contains(sampleToken))
        }
        #expect(PairingPresentation(.funnel).tone == .error && PairingPresentation(.checking).action == nil)
    }

    @Test func pairAPhoneLivesOnTheDevicesTab() {
        let form = SettingsForm(SettingsState())
        #expect(form.pairButton.isDescendant(of: form.view(for: .devices)) && form.pairButton.title == "Pair a Phone…")
        #expect(!form.pairButton.isDescendant(of: form.view(for: .advanced)))
    }

    @Test func theWindowRendersInLightAndDark() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-pairing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try Snapshots.render(to: dir, scenarios: Snapshots.pairingScenarios)
        #expect(files.count == Snapshots.pairingScenarios.count * 2)
        let ready = try #require(NSImage(contentsOf: dir.appendingPathComponent("pairing-ready-light.png")))
        #expect(ready.size.height > 400 && Self.decode(ready, side: 900) == Snapshots.sampleLink.uri)
        let light = try Data(contentsOf: dir.appendingPathComponent("pairing-ready-light.png"))
        let dark = try Data(contentsOf: dir.appendingPathComponent("pairing-ready-dark.png"))
        #expect(light != dark && light.count < 250_000)
    }

    static func images(in view: NSView) -> [NSImage] {
        view.subviews.flatMap { sub -> [NSImage] in
            if sub.isHidden { return [] }
            if let iv = sub as? NSImageView, iv.accessibilityLabel() == "Pairing QR code" { return iv.image.map { [$0] } ?? [] }
            return images(in: sub)
        }
    }

    static func texts(in view: NSView) -> [String] {
        view.subviews.flatMap { sub -> [String] in
            if sub.isHidden { return [] }
            return ((sub as? NSTextField).map { [$0.stringValue] } ?? []) + texts(in: sub)
        }
    }
}
