import Foundation
import Testing
@testable import ChirpCore

private func learnedDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("chirp-learned-\(UUID().uuidString)", isDirectory: true)
}

/// The edited span: only edits inside what Chirp inserted count.
struct EditRegionTests {
    private let before = "Notes: deploy it to cooper netties today. Thanks"
    private var range: NSRange { (before as NSString).range(of: "deploy it to cooper netties today.") }

    @Test func anEditInsideTheSpanIsReturned() {
        let after = "Notes: deploy it to Kubernetes today. Thanks"
        #expect(EditRegion.edited(before: before, after: after, range: range) == "deploy it to Kubernetes today.")
    }

    @Test func noChangeIsTheSpanItself() {
        #expect(EditRegion.edited(before: before, after: before, range: range) == "deploy it to cooper netties today.")
    }

    @Test func anEditOutsideTheSpanIsIgnored() {
        #expect(EditRegion.edited(before: before, after: "Notes: deploy it to cooper netties today. Thanks!!", range: range) == nil)
        #expect(EditRegion.edited(before: before, after: "Todo: deploy it to cooper netties today. Thanks", range: range) == nil)
        // One edit inside and one outside: mixed, so nothing.
        #expect(EditRegion.edited(before: before, after: "Todo: deploy it to Kubernetes today. Thanks", range: range) == nil)
    }

    @Test func typingMoreAtTheEdgesIsNotAnEdit() {
        let start = "deploy it", r = NSRange(location: 0, length: 9)
        #expect(EditRegion.edited(before: start, after: "deploy it now", range: r) == nil)
        #expect(EditRegion.edited(before: start, after: "please deploy it", range: r) == nil)
        // Deleting the whole span leaves an empty edit (a large rewrite, which teaches nothing).
        #expect(EditRegion.edited(before: start, after: "", range: r) == "")
    }

    @Test func aRangeOutsideTheTextIsRefused() {
        #expect(EditRegion.edited(before: "short", after: "shorter", range: NSRange(location: 3, length: 10)) == nil)
    }
}

/// Fixtures of typical edits and what each teaches.
struct EditCorrectionsTests {
    private func extract(_ inserted: String, _ edited: String) -> [LearnedCorrection] {
        EditCorrections.extract(inserted: inserted, edited: edited)
    }

    @Test func aMisheardNameBecomesATerm() {
        #expect(extract("Deploy it to cooper netties today.", "Deploy it to Kubernetes today.")
                == [.term(heard: "cooper netties", term: "Kubernetes")])
        #expect(extract("Thanks to the folks at and throw pick.", "Thanks to the folks at Anthropic.")
                == [.term(heard: "and throw pick", term: "Anthropic")])
        #expect(extract("Ping my a for the review.", "Ping Maya for the review.").isEmpty == false)
        #expect(extract("push it to get hub", "push it to GitHub") == [.term(heard: "get hub", term: "GitHub")])
        #expect(extract("the i o s build", "the iOS build") == [.term(heard: "i o s", term: "iOS")])
        // A bare number is not a term; the name is.
        #expect(extract("run it on python three", "run it on Python 3") == [.term(heard: "python", term: "Python")])
    }

    @Test func aNameWrittenProperlyIsATerm() {
        #expect(extract("we moved to kubernetes last week", "we moved to Kubernetes last week")
                == [.term(heard: "kubernetes", term: "Kubernetes")])
        #expect(extract("open the github page", "open the GitHub page") == [.term(heard: "github", term: "GitHub")])
    }

    @Test func grammarAndSentenceCaseAreNotTerms() {
        #expect(extract("I put it over their.", "I put it over there.").isEmpty)
        #expect(extract("their going home", "There going home").isEmpty)     // sentence start
        #expect(extract("we should go now", "we must go now").isEmpty)
        #expect(extract("i think so", "I think so").isEmpty)
    }

    @Test func aRewriteTeachesNothing() {
        #expect(extract("Please move the standup to three thirty.", "Can we skip it this week? I'm out.").isEmpty)
        #expect(extract("one two three four", "").isEmpty)
        #expect(extract("same text", "same text").isEmpty)
    }

    @Test func addedOrDeletedWordsAreNotLearned() {
        #expect(extract("send the draft to Maya", "send the final draft to Maya").isEmpty)
        #expect(extract("send the the draft", "send the draft").isEmpty)
    }

    @Test func chatStyleIsLearned() {
        #expect(extract("Sounds good, I'll push it after lunch.", "sounds good, I'll push it after lunch")
                == [.style(.lowercaseStart), .style(.noFinalPeriod)])
        #expect(extract("On my way.", "On my way") == [.style(.noFinalPeriod)])
        #expect(extract("Lunch at noon?", "lunch at noon?") == [.style(.lowercaseStart)])
    }

    @Test func styleNeverFiresForIOrAcronymsOrEllipses() {
        #expect(extract("I'll be late.", "i'll be late.").isEmpty)
        #expect(extract("NASA called.", "nASA called.").isEmpty)
        #expect(extract("Wait...", "Wait..").isEmpty)
    }

    @Test func aTermAndAStyleTogether() {
        #expect(Set(extract("Deploy to cooper netties.", "deploy to Kubernetes"))
                == [.term(heard: "cooper netties", term: "Kubernetes"), .style(.lowercaseStart), .style(.noFinalPeriod)])
    }
}

/// The store: the threshold, Teach Chirp, Undo, Reset, sealing and the cap.
@Suite(.serialized) struct LearnedStoreTests {
    private let kube = LearnedCorrection.term(heard: "cooper netties", term: "Kubernetes")

    private func store(_ keys: HistoryKeyStore = MemoryHistoryKeyStore(), dir: URL = learnedDirectory()) -> LearnedStore {
        LearnedStore(directory: dir, keys: keys)
    }

    @Test func aCorrectionIsUsedOnlyAfterItIsSeenTwice() async throws {
        let s = store()
        #expect(try await s.observe([kube], bundleID: "com.apple.TextEdit", appName: "TextEdit", inserted: "a", edited: "b", said: nil).isEmpty)
        #expect(try await s.payload(for: "com.apple.TextEdit").isEmpty)
        let activated = try await s.observe([kube], bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", inserted: "a", edited: "b", said: nil)
        #expect(activated.map(\.correction) == [kube])
        // A term is the user's everywhere, even in an app it was never seen in.
        #expect(try await s.payload(for: "com.apple.mail").terms == [.init(term: "Kubernetes", heard: ["cooper netties"])])
        // A third sighting activates nothing new.
        #expect(try await s.observe([kube], bundleID: nil, appName: nil, inserted: "a", edited: "b", said: nil).isEmpty)
        let all = try await s.all()
        #expect(all.count == 1 && all[0].count == 3)
    }

    @Test func teachChirpIsEnoughOnce() async throws {
        let s = store()
        let activated = try await s.observe([kube], bundleID: nil, appName: nil, inserted: "a", edited: "b", said: nil, explicit: true)
        #expect(activated.count == 1 && activated[0].state == .active)
    }

    @Test func styleIsPerAppWithItsExample() async throws {
        let s = store()
        for _ in 0..<2 {
            try await s.observe([.style(.noFinalPeriod)], bundleID: "slack", appName: "Slack", inserted: "On my way.",
                                edited: "On my way", said: "on my way")
        }
        let slack = try await s.payload(for: "slack")
        #expect(slack.style == [.noFinalPeriod])
        #expect(slack.examples == [.init(said: "on my way", wanted: "On my way")])
        #expect(try await s.payload(for: "mail").isEmpty)
        #expect(try await s.payload(for: nil).style.isEmpty)
    }

    @Test func undoKeepsItOffApproveTurnsItOnResetAndDelete() async throws {
        let s = store()
        try await s.observe([kube], bundleID: "a", appName: "A", inserted: "x", edited: "y", said: nil, explicit: true)
        let id = try await s.all()[0].id
        try await s.set(id, state: .off)
        // Seeing it again does not bring back what the user undid.
        #expect(try await s.observe([kube], bundleID: "a", appName: "A", inserted: "x", edited: "y", said: nil).isEmpty)
        #expect(try await s.payload(for: "a").isEmpty)
        try await s.set(id, state: .active)
        #expect(try await !s.payload(for: "a").isEmpty)
        try await s.observe([.style(.lowercaseStart)], bundleID: "b", appName: "B", inserted: "x", edited: "y", said: nil)
        try await s.reset(bundleID: "a")
        #expect(try await s.all().map(\.bundleID) == ["b"])
        let remaining = try await s.all()
        try await s.delete(remaining[0].id)
        #expect(try await s.all().isEmpty)
    }

    @Test func sealedAndReadBackAndALostKeyStartsOver() async throws {
        let dir = learnedDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryHistoryKeyStore()
        try await store(keys, dir: dir).observe([kube], bundleID: nil, appName: nil, inserted: "deploy to cooper netties",
                                                edited: "deploy to Kubernetes", said: nil)
        let bytes = try Data(contentsOf: dir.appendingPathComponent(LearnedStore.fileName))
        #expect(bytes.range(of: Data("Kubernetes".utf8)) == nil && bytes.range(of: Data("cooper".utf8)) == nil)
        #expect(try await store(keys, dir: dir).all().count == 1)
        #expect(try await store(MemoryHistoryKeyStore(), dir: dir).all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(LearnedStore.fileName).path))
    }

    @Test func theListIsCappedOldestLearningFirst() async throws {
        let s = store()
        try await s.observe([kube], bundleID: nil, appName: nil, inserted: "x", edited: "y", said: nil, explicit: true)
        for i in 0..<(LearnedStore.maxItems + 20) {
            try await s.observe([.term(heard: "word \(i)", term: "Term\(i)X")], bundleID: nil, appName: nil, inserted: "x",
                                edited: "y", said: nil)
        }
        let all = try await s.all()
        #expect(all.count == LearnedStore.maxItems)
        #expect(all.contains { $0.correction == kube })   // the active one stays
        #expect(!all.contains { $0.correction == .term(heard: "word 0", term: "Term0X") })
    }

    @Test func itemsNeverPrintWhatWasSaid() async throws {
        let s = store()
        let item = try #require(try await s.observe([kube], bundleID: nil, appName: nil, inserted: "secret words",
                                                    edited: "secret Words", said: nil, explicit: true).first)
        #expect(!"\(item)".contains("secret"))
    }
}

/// What a dictation sends and what Chirp applies itself.
struct LearnedPayloadTests {
    private let payload = LearnedPayload(terms: [.init(term: "Kubernetes", heard: ["cooper netties"]), .init(term: "Koi", heard: ["coy"]),
                                                 .init(term: "GitHub", heard: ["github"])],
                                         style: [.lowercaseStart, .noFinalPeriod],
                                         examples: [.init(said: "on my way", wanted: "on my way")])

    @Test func theStartMessageCarriesVersionOne() throws {
        let message = ClientMessage.start(StartOptions(correction: true, learned: payload))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        let learned = try #require(json["learned"] as? [String: Any])
        #expect(learned["v"] as? Int == 1)
        #expect(learned["style"] as? [String] == ["lowercase_start", "no_final_period"])
        #expect((learned["terms"] as? [[String: Any]])?.first?["heard"] as? [String] == ["cooper netties"])
        #expect((learned["examples"] as? [[String: String]]) == [["said": "on my way", "wanted": "on my way"]])
        // Nothing learned: the start message is exactly what it was.
        #expect(ClientMessage.start(StartOptions(learned: LearnedPayload())) == ClientMessage.start(StartOptions()))
        #expect(!ClientMessage.start(StartOptions()).contains("learned"))
    }

    @Test func applyRespellsSafePhrasesAndRestyles() {
        #expect(payload.apply(to: "Deploy it to Cooper  netties and github.") == "deploy it to Kubernetes and GitHub")
        // A single ordinary word ("coy") is left to clean-up, which has the context.
        #expect(payload.apply(to: "She was coy about it.") == "she was coy about it")
        #expect(payload.apply(to: "I'm on my way.") == "I'm on my way")
        #expect(payload.apply(to: "Wait...") == "wait...")
        #expect(LearnedPayload(terms: [.init(term: "Kubernetes", heard: ["cooper netties"])]).apply(to: "supercooper netties") == "supercooper netties")
    }
}

/// The watcher on a test-mode field: the window, focus, secure fields, the next dictation.
@MainActor struct EditWatcherTests {
    /// A watcher whose clock is the test's: each poll waits for `tick()`.
    private func watcher() -> (EditWatcher, [EditWatcher.Edit]) {
        (EditWatcher(window: .seconds(60), interval: .seconds(1), sleep: { _ in await Task.yield() }), [])
    }

    @Test func theNextDictationEndsTheWindowAndReportsTheEdit() {
        let w = EditWatcher(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        var edits: [EditWatcher.Edit] = []
        w.onEdit = { edits.append($0) }
        let field = TestTextField("Notes: ")
        let range = field.insert("deploy it to cooper netties")
        w.watch(field, inserted: "deploy it to cooper netties", range: range, raw: "deploy it to cooper netties",
                bundleID: "com.apple.TextEdit", appName: "TextEdit")
        #expect(w.isWatching)
        field.edit("cooper netties", to: "Kubernetes")
        w.finish()
        #expect(edits == [.init(inserted: "deploy it to cooper netties", edited: "deploy it to Kubernetes", raw: "deploy it to cooper netties",
                                bundleID: "com.apple.TextEdit", appName: "TextEdit")])
        #expect(!w.isWatching)
    }

    @Test func aFocusChangeEndsTheWindowWithTheLastTextSeen() async {
        let w = EditWatcher(window: .seconds(60), interval: .milliseconds(1), sleep: { _ in await Task.yield() })
        var edits: [EditWatcher.Edit] = []
        w.onEdit = { edits.append($0) }
        let field = TestTextField()
        let range = field.insert("ship the cooper netties fix")
        w.watch(field, inserted: "ship the cooper netties fix", range: range, raw: "", bundleID: nil, appName: nil)
        field.edit("cooper netties", to: "Kubernetes")
        for _ in 0..<5 { await Task.yield() }
        field.isFocused = false
        field.text = "something else entirely"   // what another field holds is never read
        for _ in 0..<20 where w.isWatching { await Task.yield() }
        #expect(!w.isWatching)
        #expect(edits.map(\.edited) == ["ship the Kubernetes fix"])
    }

    @Test func theWindowEndsByItself() async {
        let w = EditWatcher(window: .milliseconds(3), interval: .milliseconds(1), sleep: { _ in await Task.yield() })
        var count = 0
        w.onEdit = { _ in count += 1 }
        let field = TestTextField()
        let range = field.insert("hello there")
        w.watch(field, inserted: "hello there", range: range, raw: "", bundleID: nil, appName: nil)
        for _ in 0..<20 where w.isWatching { await Task.yield() }
        #expect(!w.isWatching && count == 0)   // no edit, nothing reported
    }

    @Test func secureFieldsAndUseRawAreNeverLearned() {
        let w = EditWatcher(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        var count = 0
        w.onEdit = { _ in count += 1 }
        let secure = TestTextField()
        secure.isSecure = true
        let r1 = secure.insert("hunter two")
        w.watch(secure, inserted: "hunter two", range: r1, raw: "", bundleID: nil, appName: nil)
        #expect(!w.isWatching)
        let field = TestTextField()
        let r2 = field.insert("a b c")
        w.watch(field, inserted: "a b c", range: r2, raw: "", bundleID: nil, appName: nil)
        field.isSecure = true
        field.text = "a B c"
        w.finish()
        let r3 = field.insert(" d")
        field.isSecure = false
        w.watch(field, inserted: " d", range: r3, raw: "", bundleID: nil, appName: nil)
        field.text = "a B c D"
        w.cancel()
        w.finish()
        #expect(count == 0)
    }

    @Test func aFieldThatDoesNotHoldTheTextIsNotWatched() {
        let w = EditWatcher()
        let field = TestTextField("something")
        w.watch(field, inserted: "other", range: NSRange(location: 0, length: 5), raw: "", bundleID: nil, appName: nil)
        #expect(!w.isWatching)
    }
}

/// The selftest's path, in-process: dictate, edit, learn after the threshold, and the next dictation applies it.
@MainActor @Suite(.serialized) struct LearnLoopTests {
    @Test func twoEditsTeachATermAndTheNextDictationUsesIt() async throws {
        let dir = learnedDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let learning = EditLearning(store: LearnedStore(directory: dir, keys: MemoryHistoryKeyStore()),
                                    watcher: EditWatcher(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }))
        var learned: [String] = []
        learning.onLearned = { learned += $0.map(\.correction.title) }
        for round in 1...2 {
            let field = TestTextField("Status \(round): ")
            let text = learning.payload(for: "com.apple.TextEdit").apply(to: "Deploy it to cooper netties.")
            #expect(text == "Deploy it to cooper netties.")
            let range = field.insert(text)
            learning.watcher.watch(field, inserted: text, range: range, raw: "deploy it to cooper netties",
                                   bundleID: "com.apple.TextEdit", appName: "TextEdit")
            field.edit("cooper netties", to: "Kubernetes")
            learning.watcher.finish()
            for _ in 0..<50 where learning.items.first?.count != round { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(learned == ["Kubernetes"])
        let next = learning.payload(for: "com.apple.mail")
        #expect(next.terms == [.init(term: "Kubernetes", heard: ["cooper netties"])])
        #expect(next.apply(to: "Deploy it to cooper netties.") == "Deploy it to Kubernetes.")
        #expect(ClientMessage.start(StartOptions(correction: true, learned: next)).contains("cooper netties"))
    }

    @Test func teachChirpFromHistoryActivatesAtOnce() async throws {
        let dir = learnedDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let learning = EditLearning(store: LearnedStore(directory: dir, keys: MemoryHistoryKeyStore()))
        let taught = await learning.teach(inserted: "Ask and throw pick about it.", wanted: "ask Anthropic about it",
                                          raw: "ask and throw pick about it", bundleID: "slack", appName: "Slack")
        #expect(Set(taught.map(\.correction)) == [.term(heard: "and throw pick", term: "Anthropic"), .style(.lowercaseStart),
                                                  .style(.noFinalPeriod)])
        #expect(learning.payload(for: "slack").style == [.lowercaseStart, .noFinalPeriod])
        #expect(await learning.teach(inserted: "same", wanted: "same", raw: nil, bundleID: nil, appName: nil).isEmpty)
    }
}

/// A clock the test moves: each watcher sleep waits for `tick()`.
@MainActor private final class EditClock {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func sleep() async { await withCheckedContinuation { waiters.append($0) } }
    func tick(_ times: Int = 1) async {
        for _ in 0..<times {
            for _ in 0..<10 { await Task.yield() }
            let w = waiters
            waiters = []
            w.forEach { $0.resume() }
            for _ in 0..<10 { await Task.yield() }
        }
    }
}

/// Real-use edits (#220 follow-up): the window must survive what people do after a dictation, and a pasted dictation
/// (Chromium, Electron, an unconfirmed AX write) must be found in its field.
@MainActor @Suite(.serialized) struct EditWatcherRealUseTests {
    private func learning(_ clock: EditClock, _ dir: URL) -> EditLearning {
        EditLearning(store: LearnedStore(directory: dir, keys: MemoryHistoryKeyStore()),
                     watcher: EditWatcher(window: .seconds(60), interval: .milliseconds(400), sleep: { _ in await clock.sleep() }))
    }

    private func settle(_ learning: EditLearning, count: Int) async throws {
        for _ in 0..<100 where learning.items.first?.count != count { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func oneWordFixedInATextEditFieldThenFocusMovesIsLearnedAndAppliedNextTime() async throws {
        let dir = learnedDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = EditClock()
        let learning = learning(clock, dir)
        var learned: [String] = []
        learning.onLearned = { learned += $0.map(\.correction.title) }
        let heard = "Push it to github tonight."
        for round in 1...2 {
            let text = learning.payload(for: "com.apple.TextEdit").apply(to: heard)
            #expect(text == heard)
            let field = TestTextField("Notes from today.\n")
            let range = field.insert(text)
            #expect(learning.watcher.watch(field, inserted: text, range: range, raw: heard, bundleID: "com.apple.TextEdit",
                                           appName: "TextEdit"))
            await clock.tick(3)   // the user reads it
            field.edit("github", to: "GitHub")
            await clock.tick()    // one poll sees the fix
            field.isFocused = false   // then they click into another window
            field.text = ""
            await clock.tick()
            #expect(!learning.watcher.isWatching)
            try await settle(learning, count: round)
            #expect(learning.items.first?.count == round)
        }
        #expect(learned == ["GitHub"])
        #expect(learning.payload(for: "com.apple.mail").apply(to: heard) == "Push it to GitHub tonight.")
    }

    @Test func aMessageSentAfterTheFixIsLearnedFromTheLastTextSeen() async throws {
        let dir = learnedDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = EditClock()
        let learning = learning(clock, dir)
        let field = TestTextField()
        let text = "ask coy about the deploy"
        let range = field.insert(text)
        learning.watcher.watch(field, inserted: text, range: range, raw: text, bundleID: "com.apple.MobileSMS", appName: "Messages")
        field.edit("coy", to: "Koi")
        await clock.tick()
        field.text = ""   // Return sent it; the field is empty and still focused
        await clock.tick()
        #expect(!learning.watcher.isWatching)
        try await settle(learning, count: 1)
        #expect(learning.items.map(\.correction) == [.term(heard: "coy", term: "Koi")])
        #expect(learning.items.first?.state == .learning)
    }

    @Test func typingOnAfterTheDictationKeepsTheWindowOpen() async throws {
        let clock = EditClock()
        let w = EditWatcher(window: .seconds(60), interval: .milliseconds(400), sleep: { _ in await clock.sleep() })
        var edits: [EditWatcher.Edit] = []
        w.onEdit = { edits.append($0) }
        let field = TestTextField("Plan: ")
        let range = field.insert("move the cooper netties cluster")
        w.watch(field, inserted: "move the cooper netties cluster", range: range, raw: "", bundleID: nil, appName: nil)
        field.text += " and then"
        await clock.tick(2)
        #expect(w.isWatching)
        field.edit("cooper netties", to: "Kubernetes")
        await clock.tick()
        w.finish()
        #expect(edits.map(\.edited) == ["move the Kubernetes cluster and then"])
    }

    @Test func aPastedDictationIsFoundOnceTheAppAppliesIt() async throws {
        let dir = learnedDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = EditClock()
        let learning = learning(clock, dir)
        let field = TestTextField("Hi team, ")
        var applied = false
        let text = "the cooper netties upgrade is done"
        let found = Task { @MainActor in
            await learning.watcher.watchPasted({ applied ? field : nil }, inserted: text, raw: text,
                                               bundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        }
        await clock.tick()
        #expect(!learning.watcher.isWatching)
        field.insert(text)   // Slack reads the pasteboard
        applied = true
        await clock.tick()
        #expect(await found.value)
        #expect(learning.watcher.isWatching)
        field.edit("cooper netties", to: "Kubernetes")
        await clock.tick()
        learning.watcher.finish()
        try await settle(learning, count: 1)
        #expect(learning.items.map(\.correction) == [.term(heard: "cooper netties", term: "Kubernetes")])
        #expect(learning.items.first?.bundleID == "com.tinyspeck.slackmacgap")
    }

    @Test func thePasteSearchGivesUpForTheNextDictationOrAnUnreadableField() async {
        let clock = EditClock()
        let w = EditWatcher(window: .seconds(60), interval: .milliseconds(400), sleep: { _ in await clock.sleep() })
        let field = TestTextField()
        let search = Task { @MainActor in
            await w.watchPasted({ field }, inserted: "hello", raw: "", bundleID: nil, appName: nil)
        }
        await clock.tick()
        w.finish()   // the next dictation started
        field.insert("hello")
        await clock.tick()
        #expect(await search.value == false)
        #expect(!w.isWatching)
        #expect(await w.watchPasted({ nil }, inserted: "hello", raw: "", bundleID: nil, appName: nil, attempts: 1) == false)
    }
}

/// Where a pasted dictation went, and whether the text around it still holds.
struct EditRegionPasteTests {
    @Test func theTextBeforeTheCaretOrItsOnlyOccurrence() {
        let value = "ok ok then ok"
        #expect(EditRegion.pasted("ok", in: value, caret: NSRange(location: 5, length: 0)) == NSRange(location: 3, length: 2))
        #expect(EditRegion.pasted("ok", in: value, caret: nil) == nil)              // three of them, no caret
        #expect(EditRegion.pasted("then", in: value, caret: nil) == NSRange(location: 6, length: 4))
        #expect(EditRegion.pasted("then", in: value, caret: NSRange(location: 0, length: 0)) == NSRange(location: 6, length: 4))
        #expect(EditRegion.pasted("later", in: value, caret: nil) == nil)
        #expect(EditRegion.pasted("", in: value, caret: nil) == nil)
    }

    @Test func holdsWhileTheSurroundingsAreUnchanged() {
        let before = "To: Sam\nship it Friday\nThanks"
        let range = (before as NSString).range(of: "ship it Friday")
        #expect(EditRegion.holds(before: before, after: before, range: range))
        #expect(EditRegion.holds(before: before, after: "To: Sam\nship it Monday, ok\nThanks", range: range))
        #expect(!EditRegion.holds(before: before, after: "", range: range))
        #expect(!EditRegion.holds(before: before, after: "To: Sam\n\nThanks", range: range))
        #expect(!EditRegion.holds(before: before, after: "To: Kim\nship it Friday\nThanks", range: range))
        #expect(!EditRegion.holds(before: "hi", after: "hi", range: NSRange(location: 1, length: 5)))
        // The whole field, or its very start or end.
        #expect(EditRegion.holds(before: "ship it", after: "ship it now", range: NSRange(location: 0, length: 7)))
        #expect(EditRegion.holds(before: "To: ship it", after: "To: Ship it", range: NSRange(location: 4, length: 7)))
        #expect(!EditRegion.holds(before: "ship it", after: "", range: NSRange(location: 0, length: 7)))
    }
}

/// Every gate holds for a paste exactly as for an AX write; only a dictation that passes them all may be looked for in
/// its field (the one case where a Chromium or Electron app is asked to expose it).
struct LearnWatchPlanTests {
    private func plan(learning: Bool = true, history: Bool = true, isPrivate: Bool = false, excluded: Bool = false,
                      secure: Bool = false, _ outcome: InsertionOutcome, range: NSRange? = nil) -> LearnWatchPlan {
        LearnWatchPlan.plan(learningEnabled: learning, historyEnabled: history, isPrivate: isPrivate, excluded: excluded,
                            secureField: secure, outcome: outcome, axRange: range)
    }

    @Test func everyGateAppliesToEveryInsertion() {
        let r = NSRange(location: 0, length: 3)
        for (outcome, range) in [(InsertionOutcome.inserted(.ax), r), (.inserted(.ax), nil), (.inserted(.paste), nil),
                                 (.insertedUnverified, nil)] as [(InsertionOutcome, NSRange?)] {
            #expect(plan(learning: false, history: false, outcome, range: range) == .skip(gate: "historyOff"))
            #expect(plan(learning: false, outcome, range: range) == .skip(gate: "learningOff"))
            #expect(plan(isPrivate: true, outcome, range: range) == .skip(gate: "private"))
            #expect(plan(excluded: true, outcome, range: range) == .skip(gate: "excludedApp"))
            #expect(plan(secure: true, outcome, range: range) == .skip(gate: "secure"))
        }
    }

    @Test func onlyAnInsertionThatPassedIsWatchedOrLookedFor() {
        let r = NSRange(location: 4, length: 2)
        #expect(plan(.inserted(.ax), range: r) == .watch(r))
        #expect(plan(.inserted(.ax)) == .find)
        #expect(plan(.inserted(.paste)) == .find)
        #expect(plan(.insertedUnverified) == .find)
        #expect(plan(.copied) == .skip(gate: "notInserted"))
        #expect(plan(.inserted(.copy)) == .skip(gate: "notInserted"))
        #expect(plan(.refusedSecure) == .skip(gate: "notInserted"))
    }
}

@MainActor struct EditWatcherPasteGateTests {
    @Test func useRawOrAPrivateSessionStopsThePasteSearch() async {
        let clock = EditClock()
        let w = EditWatcher(window: .seconds(60), interval: .milliseconds(400), sleep: { _ in await clock.sleep() })
        let field = TestTextField()
        let search = Task { @MainActor in await w.watchPasted({ field }, inserted: "hello", raw: "", bundleID: nil, appName: nil) }
        await clock.tick()
        w.cancel()   // Use raw, or a private session turned on: both cancel the watcher
        field.insert("hello")
        await clock.tick()
        #expect(await search.value == false)
        #expect(!w.isWatching)
    }

    @Test func aSecureFieldIsNeverReadOnThePastePath() async {
        let w = EditWatcher(sleep: { _ in await Task.yield() })
        final class Probe: WatchedField {
            var reads = 0
            func value() -> String? { reads += 1; return "hunter two" }
            func selection() -> NSRange? { NSRange(location: 10, length: 0) }
            var isFocused: Bool { true }
            var isSecure: Bool { true }
        }
        let probe = Probe()
        #expect(await w.watchPasted({ probe }, inserted: "hunter two", raw: "", bundleID: nil, appName: nil) == false)
        #expect(probe.reads == 0 && !w.isWatching)
    }
}
