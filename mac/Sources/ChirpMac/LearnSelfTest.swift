import ChirpCore
import Foundation

/// `ChirpMac --learn-selftest [--url URL] [--token-file PATH]`: Learn from my edits end to end without a microphone,
/// Accessibility or the real Keychain. Each "dictation" goes into a test text field the way Chirp inserts it, the
/// user's edit is made in that field, and the field watcher, the correction extractor and a throwaway sealed store do
/// the rest (the second dictation is found in the field as a paste is): after the second identical fix the term is active, and the third dictation's `start` carries it and its
/// text comes out respelled. With `--url` the `start` (with `learned`) also goes to that server with half a second of
/// silence, to check it accepts the block. Prints counts and the synthetic text only; writes only to a temp folder.
@MainActor
enum LearnSelfTest {
    static func run(_ args: [String]) async -> Int32 {
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-learn-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let learning = EditLearning(store: LearnedStore(directory: dir, keys: MemoryHistoryKeyStore()),
                                    watcher: EditWatcher(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }))
        var learned: [String] = []
        learning.onLearned = { learned += $0.map(\.correction.title) }
        let app = (id: "com.apple.TextEdit", name: "TextEdit")
        let heard = "Deploy the fix to cooper netties tonight."
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("  \(ok ? "ok  " : "FAIL") \(what)")
            if !ok { failures += 1 }
        }

        print("learn-selftest: two dictations fixed the same way, then a third")
        for round in 1...2 {
            let options = StartOptions(correction: true, learned: learning.payload(for: app.id))
            let text = options.learned?.apply(to: heard) ?? heard
            let field = TestTextField("Status: ")
            let range = field.insert(text)
            // The first goes in the way an AX write does (its range known), the second as a paste is found in the field.
            let watching = round == 1
                ? learning.watcher.watch(field, inserted: text, range: range, raw: heard, bundleID: app.id, appName: app.name)
                : await learning.watcher.watchPasted({ field }, inserted: text, raw: heard, bundleID: app.id, appName: app.name)
            check(watching, round == 1 ? "the inserted field is watched" : "the pasted text is found in its field and watched")
            field.edit("cooper netties", to: "Kubernetes")
            print("  dictation \(round): inserted “\(text)”, edited to “\(field.text.dropFirst(8))”")
            learning.watcher.finish()
            for _ in 0..<100 where learning.items.first?.count != round { try? await Task.sleep(for: .milliseconds(10)) }
            check(learning.items.first?.count == round, "the edit counted (\(round) of \(LearnedStore.threshold))")
            check((round < LearnedStore.threshold) == learned.isEmpty,
                  round < LearnedStore.threshold ? "not used before the threshold" : "learned after the threshold: \(learned.joined(separator: ", "))")
        }
        let payload = learning.payload(for: "com.apple.mail")
        let options = StartOptions(correction: true, learned: payload)
        let start = ClientMessage.start(options)
        check(start.contains("\"learned\"") && start.contains("Kubernetes"), "the next start carries the term (in any app)")
        let third = payload.apply(to: heard)
        print("  dictation 3: “\(heard)” → “\(third)”")
        check(third == "Deploy the fix to Kubernetes tonight.", "the next dictation applies it")

        if let url = value("--url") {
            var config = ServerConfig.load(urlString: url, tokenPath: value("--token-file") ?? ServerConfig.defaultTokenPath)
            if let t = ProcessInfo.processInfo.environment["CHIRP_TOKEN"] { config.token = t }
            let session = StreamSession(config: config, options: options)
            let reader = Task { () -> String in
                for await event in session.events {
                    switch event {
                    case .message(.final): return "final"
                    case .message(.error(let code, _)): return "error \(code)"
                    case .closed(let reason): return "closed \(reason ?? "")"
                    default: continue
                    }
                }
                return "ended"
            }
            await session.open()
            for _ in 0..<10 { session.sendAudio(Data(count: 1600)) }
            await session.stop()
            let outcome = await withTaskGroup(of: String.self) { group in
                group.addTask { await reader.value }
                group.addTask { try? await Task.sleep(for: .seconds(30)); return "timed out" }
                let first = await group.next()!
                group.cancelAll()
                return first
            }
            await session.close()
            check(outcome == "final", "the server accepts start.learned (\(outcome))")
        }
        print(failures == 0 ? "learn-selftest: PASS" : "learn-selftest: FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
