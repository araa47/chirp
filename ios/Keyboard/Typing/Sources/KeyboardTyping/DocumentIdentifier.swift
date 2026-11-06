import UIKit

extension UITextDocumentProxy {
    /// `documentIdentifier`, or nil when the host has none. Swift imports it as a non-optional `UUID`, but the system can
    /// return nil (iOS 27 simulators: the keyboard trapped bridging it in `textDidChange`, over and over in a UI run).
    /// Key-Value Coding (public API) hands that nil back as an optional instead.
    public var chirpDocumentIdentifier: UUID? { (self as AnyObject).value(forKey: "documentIdentifier") as? UUID }
}
