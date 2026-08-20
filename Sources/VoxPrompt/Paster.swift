import Cocoa
import Carbon.HIToolbox

/// Résultat d'un collage. Permet au HUD de distinguer "Collé" (le texte est arrivé
/// dans l'app cible) de "Dans le presse-papier" (rien n'a été inséré, l'utilisateur
/// doit faire Cmd+V lui-même).
enum PasteOutcome: Equatable {
    case pasted(method: String)
    case clipboardOnly(reason: String)
}

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

    // MARK: Constantes

    /// Types conventionnels (nspasteboard.com) posés par les gestionnaires de mots de passe
    /// et les presse-papiers éphémères. Rejouer ces données leur donne un changeCount neuf,
    /// ce qui casse leur auto-effacement : on ne restaure jamais un contenu marqué ainsi.
    private static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]

    /// Fenêtre de restauration : 12 sondages de 50 ms = 600 ms max.
    /// Les cibles lentes (Electron, JetBrains, onglet Chrome occupé) lisent le presse-papier
    /// bien après le Cmd+V ; restaurer trop tôt leur fait coller l'ancien contenu.
    private static let restorePollInterval: UInt64 = 50_000_000
    private static let restorePollSteps = 12

    /// Bundle ids à router directement en AppleScript, sans tenter le CGEvent.
    /// Aucune liste vérifiée n'est livrée en dur (la cascade générique couvre le cas) :
    /// la clé UserDefaults `paste.appleScriptBundleIDs` (tableau de strings) permet d'ajouter
    /// une app récalcitrante sans recompiler.
    private static let appleScriptBundleIDsKey = "paste.appleScriptBundleIDs"

    /// Snapshot du presse-papier pris avant qu'on écrive le texte transcrit.
    private struct ClipboardSnapshot {
        let items: [(NSPasteboard.PasteboardType, Data)]
        /// false si le contenu portait un marqueur de confidentialité : on ne le rejoue pas.
        let isRestorable: Bool
        let blockedReason: String?
    }

    // MARK: API

    /// Copie le texte dans le presse-papier puis tente le paste auto selon `Settings.shared.pasteMode`.
    /// Retourne quand la stratégie de collage est jouée (la restauration du presse-papier, elle,
    /// continue en tâche de fond jusqu'à 600 ms pour ne pas retarder le HUD).
    @MainActor
    @discardableResult
    func copyAndPaste(_ text: String, targetApp: NSRunningApplication?) async -> PasteOutcome {
        let mode = Settings.shared.pasteMode
        let appName = targetApp?.localizedName ?? "?"
        let pid = targetApp?.processIdentifier ?? -1
        VPLog.log("paste start mode=\(mode.rawValue) target=\(appName) pid=\(pid)")

        // Mode "clipboard seul" : on copie et on s'arrête là (l'utilisateur fera Cmd+V)
        if mode == .clipboardOnly {
            setClipboard(text)
            VPLog.log("paste done mode=clipboardOnly")
            return .clipboardOnly(reason: "Mode presse-papier")
        }

        // Cible = VoxPrompt : le popover de préférences avait le focus au moment du press.
        // Coller ici écrirait dans notre propre champ glossaire, pas chez l'utilisateur.
        if isSelf(targetApp) {
            setClipboard(text)
            VPLog.log("target is VoxPrompt itself, no paste (text in clipboard)")
            return .clipboardOnly(reason: "VoxPrompt était au premier plan")
        }

        if let app = targetApp, app.isTerminated {
            setClipboard(text)
            VPLog.log("target terminated during transcription, paste aborted (text in clipboard)")
            return .clipboardOnly(reason: "\(appName) a quitté")
        }

        // Mode "unicode" : insertion directe sans clipboard. Pas recommandé pour Terminal.
        if mode == .unicode {
            await activateAndWait(targetApp)
            postUnicodeString(text, targetApp: targetApp)
            VPLog.log("paste done mode=unicode")
            return .pasted(method: "unicode")
        }

        // Modes auto et appleScriptOnly : on passe par le clipboard
        let snapshot = saveClipboard()
        setClipboard(text)
        let ourChangeCount = NSPasteboard.general.changeCount

        await activateAndWait(targetApp)

        var method: String?
        var lastFailure = "aucune méthode disponible"

        if mode == .auto {
            if prefersAppleScript(targetApp) {
                VPLog.log("target routed to AppleScript by \(Self.appleScriptBundleIDsKey)")
            } else {
                switch postCmdV(targetApp: targetApp) {
                case .success(let name):
                    method = name
                    VPLog.log("paste sent via \(name)")
                case .failure(let why):
                    lastFailure = why
                    VPLog.log("CGEvent paste not credible (\(why)), fallback to AppleScript")
                }
            }
        }

        if method == nil {
            if let blocker = appleScriptBlocker(targetApp) {
                lastFailure = blocker
                VPLog.log("AppleScript paste skipped (\(blocker)), text remains in clipboard")
            } else if let why = runPasteAppleScript() {
                lastFailure = why
                VPLog.log("AppleScript paste failed (\(why)), text remains in clipboard")
            } else {
                method = "AppleScript"
                VPLog.log("paste sent via AppleScript")
            }
        }

        // La restauration attend que la cible ait consommé le presse-papier ; elle ne doit pas
        // retarder le retour (le HUD affiche le résultat tout de suite).
        scheduleClipboardRestore(snapshot, ourChangeCount: ourChangeCount)

        if let method {
            return .pasted(method: method)
        }
        return .clipboardOnly(reason: lastFailure)
    }

    // MARK: Identité

    /// Vrai si la cible est VoxPrompt lui-même (comparaison par PID, plus fiable que le bundle id
    /// quand le binaire tourne hors bundle en développement).
    private func isSelf(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        if let mine = Bundle.main.bundleIdentifier, !mine.isEmpty, app.bundleIdentifier == mine { return true }
        return false
    }

    private func prefersAppleScript(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier?.lowercased(), !id.isEmpty else { return false }
        let list = UserDefaults.standard.stringArray(forKey: Self.appleScriptBundleIDsKey) ?? []
        return list.contains { $0.lowercased() == id }
    }

    // MARK: Clipboard helpers

    @MainActor
    private func saveClipboard() -> ClipboardSnapshot? {
        let pb = NSPasteboard.general
        guard let types = pb.types else { return nil }

        let markers = types.map(\.rawValue).filter { Self.sensitiveTypes.contains($0) }
        var items: [(NSPasteboard.PasteboardType, Data)] = []
        for type in types {
            if let data = pb.data(forType: type) {
                items.append((type, data))
            }
        }
        guard !items.isEmpty else { return nil }

        if let marker = markers.first {
            VPLog.log("clipboard marked \(marker), it will not be restored")
            return ClipboardSnapshot(items: items, isRestorable: false, blockedReason: marker)
        }
        return ClipboardSnapshot(items: items, isRestorable: true, blockedReason: nil)
    }

    /// Ne restaure que si le presse-papier porte toujours NOTRE changeCount : si l'utilisateur
    /// a fait un Cmd+C entre-temps, ou si un gestionnaire de presse-papier a écrit, on n'écrase rien.
    @MainActor
    private func scheduleClipboardRestore(_ snapshot: ClipboardSnapshot?, ourChangeCount: Int) {
        guard let snapshot else { return }
        guard snapshot.isRestorable else {
            VPLog.log("clipboard not restored (\(snapshot.blockedReason ?? "contenu confidentiel")), transcript stays in clipboard")
            return
        }
        Task { @MainActor in
            let pb = NSPasteboard.general
            for _ in 0..<Self.restorePollSteps {
                try? await Task.sleep(nanoseconds: Self.restorePollInterval)
                if pb.changeCount != ourChangeCount {
                    VPLog.log("clipboard written by someone else (changeCount=\(pb.changeCount), ours=\(ourChangeCount)), no restore")
                    return
                }
            }
            guard pb.changeCount == ourChangeCount else { return }
            pb.clearContents()
            for (type, data) in snapshot.items {
                pb.setData(data, forType: type)
            }
            VPLog.log("clipboard restored (\(snapshot.items.count) types)")
        }
    }

    @MainActor
    private func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: Activation

    /// Ramène la cible au premier plan et attend qu'elle ait VRAIMENT repris le focus.
    /// Retourne false si elle ne l'a pas repris : dans ce cas ni le CGEvent ni l'AppleScript
    /// n'iraient au bon endroit, et l'AppleScript en particulier collerait dans l'app qui a
    /// le focus à la place. Mieux vaut ne rien coller et le dire.
    @MainActor
    @discardableResult
    private func activateAndWait(_ app: NSRunningApplication?) async -> Bool {
        guard let app, !app.isTerminated else { return false }
        // [.activateIgnoringOtherApps] est marqué deprecated sur macOS 14+ mais reste l'API
        // qui marche pour menu bar apps en .accessory : la nouvelle activate() coopérative
        // suppose que l'app courante est régulière et possède le focus.
        app.activate(options: [.activateIgnoringOtherApps])
        // Sondage plutôt qu'un délai fixe : 40 ms suffisent la plupart du temps, mais une app
        // lente à reconstruire sa fenêtre (Electron) peut demander plus. Plafond 400 ms.
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if app.isActive { return true }
        }
        VPLog.log("target \(app.localizedName ?? "?") did not regain focus after 400 ms")
        return false
    }

    // MARK: Stratégie 1 : CGEvent Cmd+V

    private enum PostAttempt {
        case success(String)
        case failure(String)
    }

    /// Poste Cmd+V et ne déclare le succès que si un signal plausible existe.
    /// Le seul signal observable côté émetteur est le focus : un Cmd+V posté à une app qui
    /// n'est pas frontmost part dans une fenêtre inactive et n'insère rien, alors que la
    /// création des CGEvent, elle, réussit toujours. C'est ce qui rendait le fallback
    /// AppleScript inatteignable et faisait annoncer "Collé" à tort.
    @MainActor
    private func postCmdV(targetApp: NSRunningApplication?) -> PostAttempt {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vCode = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vCode, keyDown: false) else {
            return .failure("création CGEvent impossible")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand

        let front = NSWorkspace.shared.frontmostApplication
        let frontPID = front?.processIdentifier ?? -1

        if let app = targetApp, app.processIdentifier > 0 {
            if app.isTerminated {
                return .failure("\(app.localizedName ?? "la cible") a quitté")
            }
            // Deux lectures du même fait, prises à des sources différentes : NSWorkspace peut
            // avoir une frame de retard juste après une activation.
            guard app.isActive || frontPID == app.processIdentifier else {
                return .failure("\(app.localizedName ?? "la cible") n'a pas le focus (front=\(front?.localizedName ?? "?"))")
            }
            // postToPid cible directement le process : plus fiable que cghidEventTap qui peut
            // être intercepté par des utilitaires clavier.
            down.postToPid(app.processIdentifier)
            up.postToPid(app.processIdentifier)
            return .success("CGEvent postToPid")
        }

        // Sans PID : session tap. Le Cmd+V ira à l'app frontmost, donc au minimum il ne faut
        // pas que ce soit nous, sinon on colle dans notre propre popover.
        guard let front, !isSelf(front) else {
            return .failure("aucune cible et VoxPrompt est au premier plan")
        }
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return .success("CGEvent sessionTap vers \(front.localizedName ?? "?")")
    }

    // MARK: Stratégie 2 : AppleScript fallback

    /// `keystroke` de System Events va toujours à l'app qui a le focus, pas à un PID.
    /// Tant que la cible n'a pas le focus, déclencher l'AppleScript collerait le texte
    /// ailleurs (typiquement dans le champ qu'on vient de quitter). Retourne la raison
    /// du blocage, nil si la voie est libre.
    @MainActor
    private func appleScriptBlocker(_ target: NSRunningApplication?) -> String? {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, isSelf(front) {
            return "VoxPrompt est au premier plan"
        }
        if let target {
            guard target.isActive || front?.processIdentifier == target.processIdentifier else {
                return "\(target.localizedName ?? "la cible") n'a pas repris le focus"
            }
        }
        return nil
    }

    /// System Events est un client de confiance pour AppKit, donc même les apps qui rejettent
    /// les CGEvents privés acceptent ce keystroke. Lent (~150ms compile + IPC) mais robuste.
    /// Requiert NSAppleEventsUsageDescription dans Info.plist + autorisation Automation au 1er run.
    ///
    /// Exécuté sur le MainActor : Apple documente NSAppleScript comme main thread only.
    /// Les ~150 ms bloquants sont acceptés (menu bar app, aucune animation en cours).
    /// Retourne nil en cas de succès, la raison de l'échec sinon.
    @MainActor
    private func runPasteAppleScript() -> String? {
        let source = "tell application \"System Events\" to keystroke \"v\" using command down"
        guard let script = NSAppleScript(source: source) else {
            return "script non compilable"
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        guard let error else { return nil }

        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        VPLog.log("AppleScript paste error: \(error)")
        switch code {
        case -1743:  // errAEEventNotPermitted
            return "Automation refusée (Réglages > Confidentialité > Automatisation)"
        case -1744:  // errAEEventWouldRequireUserConsent
            return "Automation pas encore autorisée"
        case -600:   // procNotFound
            return "System Events indisponible"
        default:
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "erreur \(code)"
            return "AppleScript: \(message)"
        }
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
