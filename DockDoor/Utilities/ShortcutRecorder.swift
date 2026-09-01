import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Lets the settings shortcut recorder capture chords through the global event
/// tap, so shortcuts that DockDoor itself consumes (e.g. the Window Switcher's
/// ⌘Tab) can be recorded. While a recording is active the tap hands every
/// key-down to the handler instead of acting on it.
final class ShortcutRecorder {
    struct Capture {
        let keyCode: UInt16
        let flags: CGEventFlags
    }

    static let shared = ShortcutRecorder()

    typealias Token = UUID

    private let lock = NSLock()
    /// Called on the main thread; nil capture means the recording was cancelled
    /// (Escape, focus loss, or another recorder taking over).
    private var handler: ((Capture?) -> Void)?
    private var owner: Token?

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return handler != nil
    }

    /// Starts a recording, cancelling any recorder that was armed before.
    func begin(_ handler: @escaping (Capture?) -> Void) -> Token {
        lock.lock()
        let previous = self.handler
        let token = Token()
        self.handler = handler
        owner = token
        lock.unlock()
        if let previous {
            DispatchQueue.main.async { previous(nil) }
        }
        return token
    }

    /// Ends the recording owned by `token`; a recorder that was already
    /// replaced leaves the newer one untouched.
    func end(_ token: Token) {
        lock.lock(); defer { lock.unlock() }
        guard owner == token else { return }
        handler = nil
        owner = nil
    }

    /// Event-tap entry point. Returns true when the event was consumed by the recorder.
    func handleKeyDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        lock.lock()
        guard let handler else { lock.unlock(); return false }
        lock.unlock()

        let key = UInt16(truncatingIfNeeded: keyCode)
        if KeybindConflicts.isModifierKeyCode(key) {
            return true
        }
        let capture: Capture? = key == UInt16(kVK_Escape) ? nil : Capture(keyCode: key, flags: flags)
        DispatchQueue.main.async { handler(capture) }
        return true
    }
}
