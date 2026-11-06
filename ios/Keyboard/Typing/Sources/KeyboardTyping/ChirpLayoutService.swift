import KeyboardKit
import SwiftUI

/// KeyboardKit's layouts with one fix: its iPad layout ignores the field type, so an e-mail field had no @ near the
/// space bar. Apple's iPad e-mail keyboard has @ before the space bar and . after it, and so does Chirp's now. The
/// iPhone layout already has its own e-mail row and is left alone.
final class ChirpLayoutService: KeyboardLayoutService {
    private let base: KeyboardLayoutService

    init(base: KeyboardLayoutService) { self.base = base }

    func keyboardLayout(for context: KeyboardContext) -> KeyboardLayout {
        let layout = base.keyboardLayout(for: context)
        guard context.deviceTypeForKeyboard == .pad, context.keyboardType == .email else { return layout }
        return Self.addingEmailKeys(to: layout)
    }

    /// @ before the space bar and . after it, sized like letter keys, on the bottom row.
    static func addingEmailKeys(to layout: KeyboardLayout) -> KeyboardLayout {
        guard var bottom = layout.itemRows.last, !bottom.contains(where: { $0.action == .character("@") }),
              let space = bottom.firstIndex(where: { $0.action == .space }) else { return layout }
        let item = bottom[space]
        func key(_ character: String) -> KeyboardLayout.Item {
            KeyboardLayout.Item(action: .character(character), size: .init(width: .input, height: item.size.height),
                                alignment: item.alignment, edgeInsets: item.edgeInsets)
        }
        bottom.insert(key("."), at: space + 1)
        bottom.insert(key("@"), at: space)
        var result = layout
        result.itemRows[result.itemRows.count - 1] = bottom
        return result
    }
}
