import AppKit
import SwiftUI
import Carbon.HIToolbox

struct KeyChord: Equatable, Codable, Hashable {
    var keyCode: UInt32
    var modifierFlags: UInt

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    var displayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result + Self.keyNames[UInt(keyCode), default: "Key \(keyCode)"]
    }

    static let quickNoteDefault = KeyChord(
        keyCode: UInt32(kVK_ANSI_N),
        modifierFlags: NSEvent.ModifierFlags([.control, .option, .command]).rawValue
    )

    static let activateDefault = KeyChord(
        keyCode: UInt32(kVK_ANSI_S),
        modifierFlags: NSEvent.ModifierFlags([.control, .option, .command]).rawValue
    )

    private static let keyNames: [UInt: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`",
        51: "⌫", 53: "⎋", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12"
    ]
}

final class HotKeyCenter {
    private struct Registration {
        let id: UInt32
        let hotKey: EventHotKeyRef
        let action: () -> Void
    }

    static let shared = HotKeyCenter()
    private static let signature: OSType = 0x53484B4E // SHKN

    private var eventHandler: EventHandlerRef?
    private var byChord: [KeyChord: Registration] = [:]
    private var byID: [UInt32: KeyChord] = [:]
    private var nextID: UInt32 = 1

    private init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
                center.perform(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func replaceAll(_ chords: [(KeyChord?, () -> Void)]) {
        unregisterAll()
        for (chord, action) in chords {
            _ = register(chord, action: action)
        }
    }

    @discardableResult
    func register(_ chord: KeyChord?, action: @escaping () -> Void) -> Bool {
        guard let chord, byChord[chord] == nil else { return false }
        let id = nextID
        nextID &+= 1
        var hotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            chord.keyCode,
            chord.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard status == noErr, let hotKey else { return false }
        byChord[chord] = Registration(id: id, hotKey: hotKey, action: action)
        byID[id] = chord
        return true
    }

    func unregisterAll() {
        for registration in byChord.values {
            UnregisterEventHotKey(registration.hotKey)
        }
        byChord.removeAll()
        byID.removeAll()
    }

    private func perform(id: UInt32) {
        guard let chord = byID[id], let action = byChord[chord]?.action else { return }
        DispatchQueue.main.async(execute: action)
    }
}

/// What the bring-to-front shortcut does on a given press.
///
/// Split out of the handler so the rule can be read — and tested — without a
/// window: it is a pure function of four booleans AppKit can answer for.
enum ActivateShortcutAction: Equatable {
    /// Show the library, deminiaturizing it and activating the app as needed.
    case raise
    /// The library is already in front of the user; put it away.
    case close

    /// - Parameters:
    ///   - applicationIsActive: `NSApp.isActive`.
    ///   - windowIsVisible: the library window exists and is on screen.
    ///   - windowIsKey: the library window is the key window.
    ///   - windowIsMiniaturized: the library window is in the Dock.
    ///
    /// Close only when all three of *app active*, *window visible* and *window
    /// key* hold: the shortcut's main job is reaching the library from another
    /// application, and a press from over there must raise it, never put it
    /// away unseen.
    ///
    /// The miniaturized window falls out of the same rule rather than needing
    /// one of its own — a window in the Dock is neither visible nor key — but
    /// it is named here anyway, so the outcome does not rest on that AppKit
    /// subtlety being remembered: a minimized library is restored, never
    /// "closed".
    static func decide(
        applicationIsActive: Bool,
        windowIsVisible: Bool,
        windowIsKey: Bool,
        windowIsMiniaturized: Bool
    ) -> ActivateShortcutAction {
        guard applicationIsActive,
              !windowIsMiniaturized,
              windowIsVisible,
              windowIsKey
        else { return .raise }
        return .close
    }
}

@MainActor
enum GlobalShortcuts {
    static func register() {
        let settings = AppSettings.shared
        HotKeyCenter.shared.replaceAll([
            (settings.quickNoteShortcut, {
                Task { @MainActor in
                    LibraryModel.shared.createQuickNote()
                }
            }),
            (settings.activateShortcut, {
                Task { @MainActor in
                    performActivateShortcut()
                }
            })
        ])
    }

    /// The shortcut is a toggle: it brings the library to the front, and a
    /// second press with the library already in front puts it away.
    ///
    /// Closing goes through `NSWindow.close()` and not `performClose(_:)`,
    /// deliberately. `close()` posts `willCloseNotification` — so the preview's
    /// `WKWebView` and its three helper processes are released by
    /// `windowWillClose(_:)`, exactly as a red-button close releases them — but
    /// it does *not* ask `windowShouldClose(_:)`, which is where the
    /// "Quit Shokonotes when closing the library window" setting lives. That
    /// setting is scoped to the red button and ⌘W; a global shortcut is
    /// neither, so this toggle never quits the app.
    static func performActivateShortcut() {
        let window = LibraryWindowController.currentWindow
        let action = ActivateShortcutAction.decide(
            applicationIsActive: NSApp.isActive,
            windowIsVisible: window?.isVisible ?? false,
            windowIsKey: window?.isKeyWindow ?? false,
            windowIsMiniaturized: window?.isMiniaturized ?? false
        )
        switch action {
        case .close:
            window?.close()
        case .raise:
            NSApp.activate(ignoringOtherApps: true)
            LibraryWindowController.show()
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var chord: KeyChord?

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.chord = chord
        view.onChange = { context.coordinator.report($0) }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        context.coordinator.onChange = { chord = $0 }
        if nsView.chord != chord {
            nsView.chord = chord
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onChange: ((KeyChord?) -> Void)?
        func report(_ value: KeyChord?) { onChange?(value) }
    }
}

final class ShortcutRecorderView: NSView {
    var chord: KeyChord? { didSet { refreshTitle() } }
    var onChange: ((KeyChord?) -> Void)?

    private let button = NSButton()
    private var recording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(beginRecording)
        button.autoresizingMask = [.width, .height]
        button.frame = bounds
        addSubview(button)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        recording = false
        refreshTitle()
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            chord = nil
            onChange?(nil)
            window?.makeFirstResponder(nil)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
            NSSound.beep()
            return
        }
        let value = KeyChord(keyCode: UInt32(event.keyCode), modifierFlags: flags.rawValue)
        chord = value
        onChange?(value)
        window?.makeFirstResponder(nil)
    }

    @objc private func beginRecording() {
        recording = true
        refreshTitle()
        window?.makeFirstResponder(self)
    }

    private func refreshTitle() {
        if recording {
            button.title = NSLocalizedString("Type Shortcut", comment: "")
        } else {
            button.title = chord?.displayName ?? NSLocalizedString("Record Shortcut", comment: "")
        }
    }
}
