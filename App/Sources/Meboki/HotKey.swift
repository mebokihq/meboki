import Carbon

/// System-wide hotkey via Carbon `RegisterEventHotKey` (no extra permission needed). Registered exclusively,
/// so registration fails when another app already holds the same shortcut.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    /// The `OSStatus` of the last failed registration (`eventHotKeyExistsErr` when another app holds it).
    private(set) static var lastError: OSStatus = noErr

    /// `keyCode`: a `kVK_*` value. `modifiers`: Carbon flags such as `controlKey | optionKey`. Nil when the
    /// system refuses the shortcut (taken by another app, or invalid).
    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1, handler: @escaping () -> Void) {
        self.id = id
        if !HotKey.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKey.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            HotKey.handlerInstalled = true
        }
        let hkID = EventHotKeyID(signature: OSType(0x5052_4652), id: id)  // 'PRFR'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, ref != nil else {
            HotKey.lastError = status
            return nil
        }
        HotKey.handlers[id] = handler
    }

    convenience init?(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, handler: handler)
    }

    deinit {
        // The handler stays: a replacement registered under the same id may already have set its own, and
        // an unregistered hotkey never fires.
        if let ref { UnregisterEventHotKey(ref) }
    }
}
