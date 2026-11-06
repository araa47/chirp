import Foundation
import KeyboardKit
import KeyboardPolicy
import KeyboardTyping
import Testing
import UIKit

/// The typing keyboard's behaviour through KeyboardKit's real action handling, on a text proxy stand-in (no host
/// app, no extension). The pure decisions are covered in KeyboardPolicyTests.
@MainActor @Suite(.serialized) struct KeyboardTypingTests {
    @MainActor final class FakeProxy: NSObject, UITextDocumentProxy {
        var text = ""
        var autocapitalizationType: UITextAutocapitalizationType = .sentences
        var keyboardType: UIKeyboardType = .default
        var documentContextBeforeInput: String? { text.isEmpty ? nil : text }
        var documentContextAfterInput: String? { nil }
        var selectedText: String? { nil }
        var documentInputMode: UITextInputMode? { nil }
        var documentIdentifier = UUID()
        var hasText: Bool { !text.isEmpty }
        func adjustTextPosition(byCharacterOffset offset: Int) {}
        func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
        func unmarkText() {}
        func insertText(_ text: String) { self.text += text }
        func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    }

    /// The keyboard reads the host's document identifier without trapping when the system has none.
    @Test func documentIdentifierReadsTheHostsWithoutBridgingTrap() {
        let proxy = FakeProxy()
        #expect(proxy.chirpDocumentIdentifier == proxy.documentIdentifier)
    }

    @MainActor struct Rig {
        let controller: KeyboardInputViewController
        let proxy: FakeProxy
        let autocomplete: ChirpAutocompleteService
        let actions: ChirpActionHandler
        var context: KeyboardContext { controller.state.keyboardContext }

        func type(_ text: String) {
            for character in text {
                actions.handle(.release, on: character == " " ? .space : .character(String(character)))
            }
        }

        /// What the suggestion bar would show now (KeyboardKit applies the result on the next main-queue turn).
        func suggest() async throws {
            let result = try await autocomplete.autocomplete(proxy.text)
            controller.state.autocompleteContext.suggestionsFromService = result.suggestions
        }
    }

    func rig(_ text: String = "", type: UIKeyboardType = .default) -> Rig {
        let controller = KeyboardInputViewController()
        let proxy = FakeProxy()
        proxy.text = text; proxy.keyboardType = type
        controller.state.keyboardContext.originalTextDocumentProxy = proxy
        controller.hasPerformedInitialSetup = true
        let typing = TypingKeyboard.install(on: controller) { false }
        controller.state.keyboardContext.keyboardCase = controller.state.keyboardContext.preferredKeyboardCase
        return Rig(controller: controller, proxy: proxy, autocomplete: typing.autocomplete, actions: typing.actions)
    }

    // MARK: Casing

    @Test func sentenceStartsAreCapitalisedAndTheRestIsNot() {
        let r = rig()
        #expect(r.context.keyboardCase == .uppercased, "an empty field starts a sentence")
        r.type("H")
        #expect(r.proxy.text == "H" && r.context.keyboardCase == .lowercased)
        r.type("i. ")
        #expect(r.context.keyboardCase == .uppercased, "after a full stop and a space")
        r.type("ok")
        #expect(r.context.keyboardCase == .lowercased)
    }

    @Test func noAutocapitalisationWhenTheFieldSaysNone() {
        let r = rig()
        r.proxy.autocapitalizationType = .none
        r.context.keyboardCase = r.context.preferredKeyboardCase
        #expect(r.context.keyboardCase == .lowercased)
    }

    @Test func doubleTapOnShiftLocksCapsUntilShiftAgain() async throws {
        let r = rig("x ")
        // KeyboardKit times double taps from its creation; a keyboard on screen is older than its 0.5 s window.
        try await Task.sleep(for: .milliseconds(600))
        r.context.keyboardCase = .lowercased
        r.actions.handle(.release, on: .shift(.lowercased))
        r.actions.handle(.release, on: .shift(r.context.keyboardCase))
        #expect(r.context.keyboardCase == .capsLocked)
        r.type("ab")
        #expect(r.context.keyboardCase == .capsLocked, "caps lock survives letters")
    }

    @Test func doubleSpaceEndsTheSentence() {
        let r = rig("Hello")
        r.type("  ")
        #expect(r.proxy.text == "Hello. ")
    }

    // MARK: Layouts

    @Test func fieldTypesOpenTheirLayouts() {
        let r = rig()
        for (layout, type) in [(TypingLayout.email, Keyboard.KeyboardType.email), (.url, .url), (.numberPad, .numberPad),
                               (.numbers, .numeric), (.webSearch, .webSearch), (.letters, .alphabetic)] {
            TypingKeyboard.apply(layout, to: r.controller)
            #expect(r.context.keyboardType == type, "\(layout)")
        }
        TypingKeyboard.apply(.email, to: r.controller)
        let bottom = r.controller.services.layoutService.keyboardLayout(for: r.context).itemRows.last?.map(\.action) ?? []
        #expect(bottom.filter { $0 == .character("@") }.count == 1, "the e-mail layout has one @ beside the space bar: \(bottom)")
        if r.context.deviceTypeForKeyboard == .pad {
            // KeyboardKit's iPad row ignores the field type; Chirp adds Apple's @ and . around the space bar.
            let space = bottom.firstIndex(of: .space)
            #expect(space.map { bottom[$0 - 1] == .character("@") && bottom[$0 + 1] == .character(".") } == true, "\(bottom)")
        }
    }

    @Test func numbersPageReturnsToLettersAfterSpace() {
        let r = rig("a")
        r.context.keyboardType = .numeric
        r.type("1 ")
        #expect(r.proxy.text == "a1 " && r.context.keyboardType == .alphabetic, "as on Apple's keyboard")
    }

    // MARK: Suggestions and autocorrect

    @Test func autocorrectOnSpaceAndDeleteRevertsIt() async throws {
        let r = rig("I saw teh")
        defer { UITextChecker.unlearnWord("teh") }
        try await r.suggest()
        let bar = r.controller.state.autocompleteContext.suggestions
        #expect(bar.first?.text == "teh" && bar.first?.isUnknown == true, "the typed word comes first, in quotes")
        #expect(bar.contains { $0.isAutocorrect && $0.text == "the" })
        r.type(" ")
        #expect(r.proxy.text == "I saw the ")
        r.actions.handle(.press, on: .backspace)
        #expect(r.proxy.text == "I saw teh", "Delete right after the correction puts back what was typed")
        #expect(UITextChecker.hasLearnedWord("teh"), "a rejected correction is learned on device")
        try await r.suggest()
        #expect(!r.controller.state.autocompleteContext.suggestions.contains { $0.isAutocorrect })
    }

    @Test func correctlySpelledWordsAreNeverReplaced() async throws {
        let r = rig("I saw the")
        try await r.suggest()
        #expect(!r.controller.state.autocompleteContext.suggestions.contains { $0.isAutocorrect })
        r.type(" ")
        #expect(r.proxy.text == "I saw the ")
    }

    @Test func tappingASuggestionReplacesTheWord() async throws {
        let r = rig("Good morn")
        try await r.suggest()
        let morning = try #require(r.controller.state.autocompleteContext.suggestions.first { $0.text.lowercased() == "morning" })
        r.actions.handle(morning)
        #expect(r.proxy.text == "Good morning ")
    }

    @Test func noSuggestionsWhereTheFieldIsAnAddress() async throws {
        let r = rig("someone@exampel")
        r.autocomplete.allowsAutocorrect = false
        try await r.suggest()
        #expect(r.controller.state.autocompleteContext.suggestions.isEmpty)
    }

    @Test func textReplacementShortcutsAutocorrect() async throws {
        let r = rig("omw")
        r.autocomplete.lexicon = [LexiconEntry(input: "omw", output: "On my way!")]
        try await r.suggest()
        r.type(" ")
        #expect(r.proxy.text == "On my way! ")
    }

    // MARK: Chirp hooks

    @Test func editsReleaseDictationButKeyboardSwitchesDoNot() {
        let r = rig()
        var edits = 0
        r.actions.willEdit = { edits += 1 }
        r.actions.handle(.release, on: .shift(.lowercased))
        r.actions.handle(.release, on: .keyboardType(.numeric))
        #expect(edits == 0)
        r.type("a ")
        r.actions.handle(.press, on: .backspace)
        r.actions.handle(.release, on: .primary(.return))
        #expect(edits == 4)
    }
}
