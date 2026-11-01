import AppKit
import ChirpCore
import SwiftUI

/// The v2 dictation island in the snapshots: every state in notch mode over a stand-in menu bar with a black cutout,
/// the main ones floating under a plain menu bar, and Reduce Motion and Increase Contrast. Nothing in the app shows the
/// island yet; these are for review only and are not in the committed set.
@MainActor
extension Snapshots {
    private static let islandSentence = "Please move the standup to three thirty and let everyone know"
    private static let islandRaw = "move the standup to three thirty and uh let everyone know"
    private static let islandCleaned = "Move the standup to 3:30 and let everyone know."

    static func island(_ name: String, mode: IslandMode = .notch, notch: CGSize = IslandMetrics.defaultNotch,
                       _ configure: @escaping (HUDModel) -> Void) -> Scenario {
        Scenario(name: "island-\(mode.rawValue)-\(name)") {
            let model = HUDModel()
            model.duration = "0:24 / 10:00"
            model.pulsePhase = 0.4
            configure(model)
            return NSHostingView(rootView: IslandBackdrop(mode: mode, notch: notch) { IslandView(model: model, mode: mode, notch: notch) })
        }
    }

    private static func islandOutcome(_ outcome: InsertionOutcome, final: FinalResult, showChanges: Bool = false,
                                      to m: HUDModel) {
        let p = OutcomePresentation.of(outcome, final: final, showChanges: showChanges)
        m.status = p.status; m.indicator = p.indicator; m.isError = p.isError; m.showUseRaw = p.showUseRaw
        m.cleaned = p.cleaned; m.keptOriginal = p.keptOriginal
    }

    /// Each state once, by name, so both modes render the same list.
    private static func islandStates(_ mode: IslandMode) -> [Scenario] {
        let corrected = FinalResult(text: islandCleaned, raw: islandRaw, corrected: true)
        let (stable, tail) = splitPartial(text: islandSentence + " about the release", stable: islandSentence)
        func s(_ name: String, _ c: @escaping (HUDModel) -> Void) -> Scenario { island(name, mode: mode, c) }
        return [
            s("idle") { _ in },
            s("connecting") { $0.status = HUDStatus.connecting; $0.duration = nil },
            s("listening") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.6) },
            s("live") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.8); $0.stable = stable; $0.unstable = tail },
            s("polishing") { $0.beginPolishing(raw: islandRaw, style: "Email"); $0.shimmerPhase = 0.45 },
            s("diff") {
                $0.status = HUDStatus.polished; $0.indicator = .sparkle; $0.styleName = "Email"
                $0.diff = WordDiff.segments(raw: islandRaw, cleaned: islandCleaned)
            },
            s("done") { islandOutcome(.inserted(.ax), final: FinalResult(text: islandCleaned), to: $0) },
            s("done-use-raw") { islandOutcome(.inserted(.ax), final: corrected, showChanges: true, to: $0); $0.stable = islandCleaned },
            s("error") {
                $0.status = "Server rejected the token (check ~/.config/chirp/token)"; $0.isError = true; $0.indicator = .warning
            },
        ]
    }

    public static var islandScenarios: [Scenario] {
        let corrected = FinalResult(text: islandCleaned, raw: islandRaw, corrected: true)
        let long = Array(repeating: "and then we should also check the rollout plan with the whole team", count: 4).joined(separator: ", ")
        let notchOnly: [Scenario] = [
            island("rolling") { $0.status = HUDStatus.listening; $0.duration = "2:01 / 10:00"; $0.stable = long; $0.unstable = " and finally"; $0.levels = .demo(peak: 0.8) },
            island("private") { $0.status = HUDStatus.listening; $0.privateSession = true; $0.stable = islandSentence; $0.levels = .demo(peak: 0.6) },
            island("duration-limit") { $0.status = HUDStatus.finishing; $0.duration = "10:00 / 10:00"; $0.stable = islandSentence },
            island("finishing") { $0.status = HUDStatus.finishing; $0.stable = islandSentence },
            island("inserting") { $0.status = HUDStatus.inserting; $0.stable = islandCleaned; $0.duration = nil },
            island("done-cleaned") { islandOutcome(.inserted(.ax), final: corrected, to: $0) },
            island("done-return-sent") { islandOutcome(.inserted(.ax), final: FinalResult(text: islandCleaned), to: $0); $0.status += HUDStatus.returnSent },
            island("copied") { islandOutcome(.copied, final: FinalResult(text: islandCleaned), to: $0) },
            island("unverified") { islandOutcome(.insertedUnverified, final: FinalResult(text: islandCleaned), to: $0) },
            island("kept-original") {
                islandOutcome(.inserted(.ax), final: FinalResult(text: islandRaw, corrected: false, correctionError: "timeout"), to: $0)
                $0.styleName = "Email"
            },
            island("secure-field") { islandOutcome(.refusedSecure, final: FinalResult(text: islandCleaned), to: $0) },
            island("no-speech") { $0.status = HUDStatus.noSpeech; $0.indicator = .none; $0.duration = nil },
            island("blocked") { $0.status = "Notes is recording — stop it to dictate"; $0.indicator = .warning; $0.duration = nil },
            island("learned") { $0.status = "Learned: Kubernetes"; $0.indicator = .sparkle; $0.duration = nil },
            island("debug-idle") { $0.debugRetention = true },
            island("debug-listening") { $0.status = HUDStatus.listening; $0.debugRetention = true; $0.privateSession = true; $0.stable = islandSentence; $0.levels = .demo(peak: 0.5) },
            island("debug-done") { islandOutcome(.inserted(.ax), final: corrected, showChanges: true, to: $0); $0.debugRetention = true },
            island("reduce-motion-live") { $0.reduceMotion = true; $0.status = HUDStatus.listening; $0.stable = islandSentence; $0.levels = .demo(peak: 0.6) },
            island("reduce-motion-polishing") { $0.reduceMotion = true; $0.beginPolishing(raw: islandRaw, style: "Chat") },
            island("contrast-live") { $0.increaseContrast = true; $0.status = HUDStatus.listening; $0.stable = islandSentence; $0.unstable = " about"; $0.levels = .demo(peak: 0.6) },
            island("contrast-done") { $0.increaseContrast = true; islandOutcome(.inserted(.ax), final: corrected, showChanges: true, to: $0) },
            island("wide-notch", notch: CGSize(width: 236, height: 38)) { $0.status = HUDStatus.listening; $0.stable = islandSentence; $0.levels = .demo(peak: 0.6) },
        ]
        let floatingExtra: [Scenario] = [
            island("private", mode: .floating) { $0.status = HUDStatus.listening; $0.privateSession = true; $0.stable = islandSentence; $0.levels = .demo(peak: 0.6) },
            island("debug-listening", mode: .floating) { $0.status = HUDStatus.listening; $0.debugRetention = true; $0.stable = islandSentence; $0.levels = .demo(peak: 0.5) },
            island("copied", mode: .floating) { islandOutcome(.copied, final: FinalResult(text: islandCleaned), to: $0) },
            island("contrast-live", mode: .floating) { $0.increaseContrast = true; $0.status = HUDStatus.listening; $0.stable = islandSentence; $0.levels = .demo(peak: 0.6) },
        ]
        return islandStates(.notch) + notchOnly + islandStates(.floating) + floatingExtra
    }
}

/// A stand-in for the top of a screen: desktop colour, a menu bar strip and (in notch mode) the black hardware cutout,
/// with the island drawn over it as the fixed panel would.
private struct IslandBackdrop<Content: View>: View {
    let mode: IslandMode
    let notch: CGSize
    @ViewBuilder var content: Content

    private var bar: CGFloat { mode == .notch ? notch.height : 24 }
    private var panel: CGSize { IslandMetrics.panelSize(mode: mode, notch: notch) }

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 0.45, green: 0.52, blue: 0.66)
            Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)).frame(height: bar).frame(maxHeight: .infinity, alignment: .top)
            if mode == .notch {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                    .fill(Color.black)
                    .frame(width: notch.width, height: bar)
            }
            content
                .frame(width: panel.width - 2 * IslandMetrics.shadowMargin, height: panel.height - IslandMetrics.shadowMargin)
                .padding(.top, mode == .notch ? 0 : bar + NotchGeometry.floatingGap)
        }
        .frame(width: panel.width + 40, height: panel.height + (mode == .notch ? 20 : bar + 30))
    }
}
