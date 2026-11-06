import Foundation
#if os(macOS)
import AppKit
#endif

/// One pasteboard item as `type → data`.
public typealias PasteboardItem = [String: Data]

@MainActor
public protocol PasteboardClient {
    var changeCount: Int { get }
    func snapshot() -> [PasteboardItem]
    /// Writes `text` (optionally marked transient/concealed so clipboard managers skip it); returns the new change count.
    func write(text: String, transient: Bool) -> Int
    func restore(_ items: [PasteboardItem])
    /// Writes `text` like a transient `write`, but hands the string over only when an app asks for it, so
    /// `trackedReadUptime` can say whether (and when) anyone read it after ⌘V. Returns the new change count.
    func writeTracked(text: String) -> Int
    /// Whether this pasteboard can tell when the text of the last `writeTracked` is read.
    var tracksReads: Bool { get }
    /// System uptime when an app first asked for the text of the last `writeTracked`; nil while nobody has (or when
    /// `tracksReads` is false).
    var trackedReadUptime: TimeInterval? { get }
}

extension PasteboardClient {
    public func writeTracked(text: String) -> Int { write(text: text, transient: true) }
    public var tracksReads: Bool { false }
    public var trackedReadUptime: TimeInterval? { nil }
}

public enum PasteboardMarkers {
    public static let transient = "org.nspasteboard.TransientType"
    public static let concealed = "org.nspasteboard.ConcealedType"
}

#if os(macOS)
@MainActor
public struct SystemPasteboard: PasteboardClient {
    private let board: NSPasteboard
    /// The general pasteboard; tests pass a private named one so they never touch the user's clipboard.
    public init(board: NSPasteboard = .general) { self.board = board }

    public var changeCount: Int { board.changeCount }

    public func snapshot() -> [PasteboardItem] {
        (board.pasteboardItems ?? []).map { item in
            var out: PasteboardItem = [:]
            for type in item.types { if let d = item.data(forType: type) { out[type.rawValue] = d } }
            return out
        }
    }

    public func write(text: String, transient: Bool) -> Int {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient {
            item.setData(Data(), forType: .init(PasteboardMarkers.transient))
            item.setData(Data(), forType: .init(PasteboardMarkers.concealed))
        }
        board.writeObjects([item])
        return board.changeCount
    }

    /// The promise behind the last `writeTracked` on each pasteboard; the pasteboard item keeps it too.
    private static var promises: [NSPasteboard.Name: PromisedText] = [:]

    public func writeTracked(text: String) -> Int {
        board.clearContents()
        let promised = PromisedText(text)
        Self.promises[board.name] = promised
        let item = NSPasteboardItem()
        item.setDataProvider(promised, forTypes: [.string])
        item.setData(Data(), forType: .init(PasteboardMarkers.transient))
        item.setData(Data(), forType: .init(PasteboardMarkers.concealed))
        board.writeObjects([item])
        return board.changeCount
    }

    public var tracksReads: Bool { true }
    public var trackedReadUptime: TimeInterval? { Self.promises[board.name]?.firstRead }

    public func restore(_ items: [PasteboardItem]) {
        board.clearContents()
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: .init(type)) }
            return item
        }
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}

/// The text of one tracked write, handed to whichever app asks for it first (AppKit keeps the answer after that), with
/// the moment it was asked. AppKit calls the provider on the main thread; the lock keeps it safe either way.
final class PromisedText: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let lock = NSLock()
    private var read: TimeInterval?

    init(_ text: String) { self.text = text }

    var firstRead: TimeInterval? { lock.withLock { read } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.withLock { if read == nil { read = ProcessInfo.processInfo.systemUptime } }
        item.setString(text, forType: type)
    }
}

#endif
