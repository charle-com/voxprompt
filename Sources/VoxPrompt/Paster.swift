import Cocoa
import Carbon.HIToolbox

final class Paster {
    /// Copie dans le presse-papier puis simule Cmd+V dans l'app active.
    func copyAndPaste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Petit delay pour laisser le pasteboard se propager
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.simulateCmdV()
        }
    }

    private static func simulateCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vCode = CGKeyCode(kVK_ANSI_V)

        let down = CGEvent(keyboardEventSource: src, virtualKey: vCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vCode, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
