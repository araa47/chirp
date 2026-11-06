import SwiftUI
import UIKit
import KeyboardKit
import KeyboardPolicy

/// What Chirp's UIKit row tells the SwiftUI keys: whether the suggestion bar shows word suggestions (or gives way to
/// Chirp's state laid over it), how tall it is, and how much room its ⋯ (leading) and mic (trailing) take.
@MainActor
public final class TypingChrome: ObservableObject {
    @Published public var showsSuggestions = true
    @Published public var suggestionHeight: CGFloat = 40
    @Published public var leadingInset: CGFloat = 0
    @Published public var trailingInset: CGFloat = 0
    public init() {}
}

/// The one place the keyboard extension touches KeyboardKit's setup, so swapping or upgrading it stays local.
@MainActor
public enum TypingKeyboard {
    /// Installs Chirp's autocomplete, key handling and feedback on a KeyboardKit controller.
    public static func install(on controller: KeyboardInputViewController, hasFullAccess: @escaping () -> Bool)
        -> (autocomplete: ChirpAutocompleteService, actions: ChirpActionHandler) {
        let services = controller.services
        let autocomplete = ChirpAutocompleteService()
        services.autocompleteService = autocomplete
        services.feedbackService = ChirpFeedbackService(hasFullAccess: hasFullAccess)
        if !(services.layoutService is ChirpLayoutService) { services.layoutService = ChirpLayoutService(base: services.layoutService) }
        let actions = ChirpActionHandler(controller: controller)
        services.actionHandler = actions
        return (autocomplete, actions)
    }

    /// The keys and the suggestion row, in a hosting controller sized by its content (the system keyboard metrics
    /// KeyboardKit applies per device and orientation).
    public static func makeKeys(for controller: KeyboardInputViewController, chrome: TypingChrome) -> UIViewController {
        let host = UIHostingController(rootView: TypingKeys(controller: controller, chrome: chrome).keyboardState(controller.state))
        host.sizingOptions = .intrinsicContentSize
        host.view.backgroundColor = .clear
        return host
    }

    /// Opens the layout for the host field (QWERTY, 123, the digit pad, e-mail or URL keys).
    public static func apply(_ layout: TypingLayout, to controller: KeyboardInputViewController) {
        let type: Keyboard.KeyboardType = switch layout {
        case .letters: .alphabetic
        case .numbers: .numeric
        case .numberPad: .numberPad
        case .email: .email
        case .url: .url
        case .webSearch: .webSearch
        }
        let context = controller.state.keyboardContext
        if context.keyboardType != type { context.keyboardType = type }
    }
}

/// KeyboardKit's system-style keyboard with stable identifiers on the keys Chirp's UI tests and VoiceOver users
/// rely on. The emoji keyboard is not part of the open-source core, so the globe (or the system's own globe below
/// the keyboard) is the way to emoji.
struct TypingKeys: View {
    unowned let controller: KeyboardInputViewController
    @ObservedObject var chrome: TypingChrome
    /// The layout (shift state, 123 page, field type) is computed when the view is built, so the view has to
    /// rebuild whenever the keyboard context changes, as KeyboardKit's own root view does.
    @EnvironmentObject private var keyboardContext: KeyboardContext

    var body: some View {
        KeyboardView(
            state: controller.state,
            services: controller.services,
            renderBackground: false,
            // Apple's space bar is blank (VoiceOver still reads "space").
            buttonContent: { params in
                if params.item.action == .space { Color.clearInteractable } else { params.view }
            },
            buttonView: { params in params.view.accessibilityIdentifier(Self.identifier(for: params.item.action)) },
            collapsedView: { $0.view },
            emojiKeyboard: { $0.view },
            toolbar: { params in
                params.view
                    .padding(.leading, chrome.leadingInset)
                    .padding(.trailing, chrome.trailingInset)
                    .opacity(chrome.showsSuggestions ? 1 : 0)
                    .allowsHitTesting(chrome.showsSuggestions)
                    .accessibilityHidden(!chrome.showsSuggestions)
            }
        )
        .autocompleteToolbarStyle(Autocomplete.ToolbarStyle(height: chrome.suggestionHeight))
    }

    static func identifier(for action: KeyboardAction) -> String {
        let name = switch action {
        case .space: "space"
        case .backspace: "delete"
        case .primary: "return"
        case .nextKeyboard: "globe"
        case .shift: "shift"
        case .keyboardType(let type): "type." + type.id
        case .character(let char): "key." + char
        default: "key"
        }
        return "chirp.keyboard." + name
    }
}

/// Key clicks through `UIDevice.playInputClick` (honours the user's Keyboard Clicks setting and needs no Full
/// Access), and light haptics only with Full Access, as Apple requires.
/// KeyboardKit calls it from the main thread only; the generator is created and used there.
final class ChirpFeedbackService: FeedbackService, @unchecked Sendable {
    private let hasFullAccess: () -> Bool
    private var impact: UIImpactFeedbackGenerator?

    init(hasFullAccess: @escaping () -> Bool) { self.hasFullAccess = hasFullAccess }

    func triggerAudioFeedback(_ feedback: Feedback.Audio) {
        guard feedback != .none else { return }
        MainActor.assumeIsolated { UIDevice.current.playInputClick() }
    }

    func triggerHapticFeedback(_ feedback: Feedback.Haptic) {
        guard feedback != .none, hasFullAccess() else { return }
        MainActor.assumeIsolated {
            if impact == nil { impact = UIImpactFeedbackGenerator(style: .light) }
            impact?.impactOccurred()
        }
    }
}
