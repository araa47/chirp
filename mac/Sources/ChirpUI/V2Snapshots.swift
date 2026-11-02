import AppKit
import SwiftUI

/// The v2 welcome hero in the snapshots: Wake with the orb in each of its five states (a fixed frame each), and the
/// Reduce Motion still. Review only; these names are not in the committed set.
@MainActor
extension Snapshots {
    public static var v2Scenarios: [Scenario] {
        // A fixed moment inside each state of the demo cycle (idle 0-1.8, listening to 5.4, polishing to 7.4, done).
        let frames: [(HeroOrbState, Double)] = [(.idle, 0.9), (.listening, 3.4), (.polishing, 6.2), (.done, 7.9), (.off, 1.0)]
        var scenarios = frames.map { state, time in
            Scenario(name: "v2-hero-wake-\(state.rawValue)") { heroView(WelcomeHero(state: state, time: time)) }
        }
        scenarios.append(Scenario(name: "v2-hero-wake-reduce-motion") { heroView(WelcomeHero(reduceMotion: true)) })
        return scenarios
    }

    private static func heroView(_ hero: WelcomeHero) -> NSView {
        let host = NSHostingView(rootView: hero.frame(width: 460, height: WelcomeHero.height).padding(20))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: WelcomeHero.height + 40)
        return host
    }
}
