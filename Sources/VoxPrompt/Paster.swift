import Cocoa
import Carbon.HIToolbox

/// Colle un texte dans l'app cible avec une cascade de stratégies.
///
/// Pourquoi cascade : aucune technique de paste auto n'est 100% fiable sur macOS, chaque app
/// (Cocoa native, Electron, Terminal, Java...) a ses limites. On essaie d'abord la plus rapide
/// et propre (CGEvent Cmd+V sur le PID cible), avec AppleScript en fallback (lent mais robuste
/// car System Events est trusted par AppKit).
///
/// Inspirations open-source : Pindrop (watzon/pindrop, OutputManager.swift) et VoiceInk
/// (Beingpax/VoiceInk, CursorPaster.swift).
final class Paster {
    /// Copie le texte dans le presse-papier puis tente le paste auto selon `Settings.shared.pasteMode`.
    /// Retourne quand le paste est terminé (ou abandonné).
    @MainActor
    func copyAndPaste(_ text: String, targetApp: NSRunningApplication?) async {
        let mode = Settings.shared.pasteMode
        let appName = targetApp?.localizedName ?? "?"
        let pid = targetApp?.processIdentifier ?? -1
        VPLog.log("paste start mode=\(mode.rawValue) target=\(appName) pid=\(pid)")

        // Mode "clipboard seul" : on copie et on s'arrête là (l'utilisateur fera Cmd+V)
        if mode == .clipboardOnly {
            setClipboard(text)
            VPLog.log("paste done mode=clipboardOnly")
            return
        }

        // Mode "unicode" : insertion directe sans clipboard. Pas recommandé pour Terminal.
        if mode == .unicode {
            await activateAndWait(targetApp)
            postUnicodeString(text, targetApp: targetApp)
            VPLog.log("paste done mode=unicode")
            return
        }

        // Modes auto et appleScriptOnly : on passe par le clipboard
        let savedClipboard = saveClipboard()
        setClipboard(text)

        if let app = targetApp, app.isTerminated {
            VPLog.log("target terminated during transcription, paste aborted (text in clipboard)")
            return
        }

        await activateAndWait(targetApp)

        var success = false
        if mode == .auto {
            success = postCmdV(targetApp: targetApp)
            if success {
                VPLog.log("paste sent via CGEvent Cmd+V")
            } else {
                VPLog.log("CGEvent paste failed, fallback to AppleScript")
            }
        }
        if !success {
            success = await runPasteAppleScript()
            if success {
                VPLog.log("paste sent via AppleScript")
            } else {
                VPLog.log("AppleScript paste failed, text remains in clipboard")
            }
        }

        // Délai pour laisser la cible consommer le clipboard avant restauration.
        // Si le user fait Cmd+V manuel pendant cette fenêtre, il colle bien notre texte.
        try? await Task.sleep(nanoseconds: 250_000_000)
        if let saved = savedClipboard {
            restoreClipboard(saved)
            VPLog.log("clipboard restored")
        }
    }

    // MARK: Clipboard helpers

    @MainActor
    private func saveClipboard() -> [(NSPasteboard.PasteboardType, Data)]? {
        let pb = NSPasteboard.general
        guard let types = pb.types else { return nil }
        var items: [(NSPasteboard.PasteboardType, Data)] = []
        for type in types {
            if let data = pb.data(forType: type) {
                items.append((type, data))
            }
        }
        return items.isEmpty ? nil : items
    }

    @MainActor
    private func restoreClipboard(_ items: [(NSPasteboard.PasteboardType, Data)]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        for (type, data) in items {
            pb.setData(data, forType: type)
        }
    }

    @MainActor
    private func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: Activation

    @MainActor
    private func activateAndWait(_ app: NSRunningApplication?) async {
        guard let app, !app.isTerminated else { return }
        // [.activateIgnoringOtherApps] est marqué deprecated sur macOS 14+ mais reste l'API
        // qui marche pour menu bar apps en .accessory : la nouvelle activate() coopérative
        // suppose que l'app courante est régulière et possède le focus.
        app.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 80_000_000)  // 80 ms : le focus se stabilise
    }

    // MARK: Stratégie 1 : CGEvent Cmd+V

    private func postCmdV(targetApp: NSRunningApplication?) -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vCode = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vCode, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        if let pid = targetApp?.processIdentifier, pid > 0 {
            // postToPid cible directement le process : plus fiable que cghidEventTap qui peut
            // être intercepté par des utilitaires clavier.
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            // Fallback : annotated session tap (livré au session, marqué "user-generated")
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
        return true
    }

    // MARK: Stratégie 2 : AppleScript fallback

    /// System Events est un client de confiance pour AppKit, donc même les apps qui rejettent
    /// les CGEvents privés acceptent ce keystroke. Lent (~150ms compile + IPC) mais robuste.
    /// Requiert NSAppleEventsUsageDescription dans Info.plist + autorisation Automation au 1er run.
    private func runPasteAppleScript() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            let source = "tell application \"System Events\" to keystroke \"v\" using command down"
            guard let script = NSAppleScript(source: source) else { return false }
            _ = script.executeAndReturnError(&error)
            if let error {
                VPLog.log("AppleScript paste error: \(error)")
                return false
            }
            return true
        }.value
    }

    // MARK: Stratégie 3 (opt-in) : injection Unicode directe

    /// Insère le texte sans passer par le clipboard. Casse Terminal et certains layouts non-QWERTY.
    /// À ne proposer qu'en mode opt-in via Settings.
    private func postUnicodeString(_ text: String, targetApp: NSRunningApplication?) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) else { return }
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buf in
            event.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        if let pid = targetApp?.processIdentifier, pid > 0 {
            event.postToPid(pid)
        } else {
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
