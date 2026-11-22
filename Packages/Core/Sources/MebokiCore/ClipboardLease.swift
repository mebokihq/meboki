import Foundation

/// When the clipboard the user had before a paste fallback is saved, and when it goes back. Pure state, so it is
/// unit-tested; the pasteboard itself lives in the app (`Clipboard`). `Snapshot` is whatever the app saves.
///
/// An apply holds the lease (`begin` … `end`, paired like the key guard). The first paste of the hold saves the
/// clipboard; `end` asks for one restore, a moment later, so the app has read the last ⌘V. The restore happens only
/// while the clipboard still holds Meboki's last paste: whatever the user (or another app) copied since wins, and
/// the saved contents are dropped. An apply that starts while a restore is pending keeps the first snapshot, so
/// Meboki's own text is never taken for the user's.
public struct ClipboardLease<Snapshot> {
    /// Restore delay after a paste the field took: the app has read the clipboard.
    public static var settledDelay: TimeInterval { 0.3 }
    /// Restore delay after a paste that didn't show in the field in time: a slow app may still be reading ⌘V,
    /// and must not paste the user's own clipboard instead.
    public static var unsettledDelay: TimeInterval { 1.0 }

    public private(set) var saved: Snapshot?
    /// The pasteboard's change count right after Meboki's last paste.
    public private(set) var ours: Int?
    /// Open holds (an apply inside a hold, or a probe, nests).
    public private(set) var depth = 0
    /// Bumped by every `begin` and restore: a restore scheduled earlier with an older token does nothing.
    public private(set) var generation = 0
    /// The last paste showed in the field.
    public private(set) var lastPasteSettled = true

    public init() {}

    public var holding: Bool { depth > 0 }
    /// A snapshot waits to go back.
    public var hasSaved: Bool { saved != nil }

    public mutating func begin() {
        depth += 1
        generation += 1  // a restore still pending from the last apply waits for this one's end
    }

    /// Called right before a paste puts text on the clipboard. Returns true when the caller must save the clipboard
    /// now (`save`): nothing is saved yet, or the user copied something since Meboki's last paste.
    public mutating func needsSnapshot(changeCount: Int) -> Bool {
        if saved != nil, let ours, changeCount != ours {
            // The clipboard isn't Meboki's paste any more: what's on it now is the user's.
            saved = nil
        }
        return saved == nil
    }

    public mutating func save(_ snapshot: Snapshot) { saved = snapshot }

    /// The paste went onto the clipboard; `changeCount` is the pasteboard's count right after it.
    public mutating func didPaste(changeCount: Int) {
        ours = changeCount
        lastPasteSettled = true
    }

    /// Whether the field showed the paste in time (`AX.replace`'s check after ⌘V).
    public mutating func pasteSettled(_ settled: Bool) { lastPasteSettled = settled }

    /// Ends one hold. When the last one ends with a snapshot saved, returns the token and delay for the restore.
    public mutating func end() -> (token: Int, delay: TimeInterval)? {
        guard depth > 0 else { return nil }
        depth -= 1
        guard depth == 0, saved != nil else { return nil }
        generation += 1
        return (generation, lastPasteSettled ? Self.settledDelay : Self.unsettledDelay)
    }

    /// The scheduled restore is due: the snapshot to write back, or nil (a newer hold took over, the user copied
    /// something since, or there's nothing saved). Clears the lease when it is this restore's turn.
    public mutating func restore(token: Int, changeCount: Int) -> Snapshot? {
        guard token == generation, depth == 0 else { return nil }
        return take(changeCount: changeCount)
    }

    /// Restore now, whatever is pending or held (the app quits).
    public mutating func restoreNow(changeCount: Int) -> Snapshot? {
        depth = 0
        return take(changeCount: changeCount)
    }

    private mutating func take(changeCount: Int) -> Snapshot? {
        defer {
            saved = nil
            ours = nil
            lastPasteSettled = true
            generation += 1
        }
        guard let saved, let ours, changeCount == ours else { return nil }
        return saved
    }
}
