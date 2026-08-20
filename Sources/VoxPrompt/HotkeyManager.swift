import Cocoa
import Carbon.HIToolbox
import ApplicationServices

struct HotkeyBinding: Codable, Equatable, Hashable {
    enum Kind: String, Codable, Hashable { case key, modifier }
    var kind: Kind
    var keyCode: UInt16          // virtual keyCode ou flag brut selon kind
    var label: String            // libellé humain (ex "Right Option")

    static let defaultBinding = HotkeyBinding(
        kind: .modifier,
        keyCode: UInt16(NX_DEVICERALTKEYMASK),
        label: "Right Option"
    )

    /// Virtual keycode physique correspondant au binding, pour interroger
    /// `CGEventSource.keyState` (le seul moyen de connaître l'état RÉEL d'une touche
    /// quand un keyUp a été perdu).
    ///
    /// Piège : pour un binding `.modifier`, `keyCode` contient un masque device
    /// (`NX_DEVICERALTKEYMASK`...) qui n'est ni un `CGEventFlags` ni un virtual keycode.
    /// Il faut le traduire explicitement.
    var physicalKeyCode: CGKeyCode? {
        switch kind {
        case .key:
            return CGKeyCode(keyCode)
        case .modifier:
            switch UInt32(keyCode) {
            case UInt32(NX_DEVICELCTLKEYMASK):   return CGKeyCode(kVK_Control)        // 59
            case UInt32(NX_DEVICERCTLKEYMASK):   return CGKeyCode(kVK_RightControl)   // 62
            case UInt32(NX_DEVICELALTKEYMASK):   return CGKeyCode(kVK_Option)         // 58
            case UInt32(NX_DEVICERALTKEYMASK):   return CGKeyCode(kVK_RightOption)    // 61
            case UInt32(NX_DEVICELSHIFTKEYMASK): return CGKeyCode(kVK_Shift)          // 56
            case UInt32(NX_DEVICERSHIFTKEYMASK): return CGKeyCode(kVK_RightShift)     // 60
            case UInt32(NX_DEVICELCMDKEYMASK):   return CGKeyCode(kVK_Command)        // 55
            case UInt32(NX_DEVICERCMDKEYMASK):   return CGKeyCode(kVK_RightCommand)   // 54
            default: return nil
            }
        }
    }
}

final class HotkeyManager {
    /// Appelé au keyDown du hotkey. Le `NSRunningApplication?` est l'app frontmost capturée
    /// au moment du press : c'est la cible où on collera le texte transcrit.
    var onPress: ((NSRunningApplication?) -> Void)?
    /// Appelé au keyUp du hotkey. Reçoit la cible capturée au press (peut différer de la
    /// frontmost actuelle si l'utilisateur a switché d'app pendant qu'il parlait).
    var onRelease: ((NSRunningApplication?) -> Void)?

    /// Durée maximale d'un maintien. Au-delà, release forcé : sans ce garde-fou, un keyUp
    /// perdu laisserait le micro ouvert et le fichier WAV grossir indéfiniment.
    var maxHoldDuration: TimeInterval = 180

    /// État courant de la touche, exposé pour l'UI et pour les garde-fous côté AppDelegate.
    private(set) var isHeld = false

    private var flagsMonitor: Any?
    private var flagsLocalMonitor: Any?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var keyDownLocalMonitor: Any?
    private var keyUpLocalMonitor: Any?
    private var binding: HotkeyBinding = .defaultBinding
    private var capturedFrontApp: NSRunningApplication?
    private var watchdog: Timer?
    private var holdStartedAt: Date?

    /// Période du watchdog qui relit l'état physique de la touche pendant un maintien.
    private static let watchdogInterval: TimeInterval = 0.25

    // MARK: Permissions

    /// Sans l'accessibilité, les monitors globaux ne reçoivent AUCUN évènement : c'est le
    /// mode de panne silencieux numéro un de l'app (le raccourci ne fait simplement rien).
    static func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: Cycle de vie

    func start(binding: HotkeyBinding) {
        // Changement de raccourci alors que la touche est tenue (l'utilisateur bricole ses
        // préférences en pleine dictée) : on ferme proprement la session en cours, sinon
        // le keyUp du nouveau binding n'arrivera jamais et le micro reste ouvert.
        if isHeld {
            VPLog.log("start() called while key is held, synthesizing release before rearm")
            synthesizeRelease(reason: "rearm")
        }

        stop()
        self.binding = binding
        self.capturedFrontApp = nil

        if !Self.hasAccessibility() {
            VPLog.log("ACCESSIBILITY MISSING: les monitors globaux ne recevront aucun evenement, le raccourci restera muet. Reglages Systeme > Confidentialite et securite > Accessibilite > VoxPrompt")
        }

        switch binding.kind {
        case .modifier:
            let handler: (NSEvent) -> Void = { [weak self] event in
                guard let self else { return }
                let flagBit = UInt(self.binding.keyCode)
                let raw = UInt(event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue))
                let pressed = (raw & flagBit) != 0
                if pressed && !self.isHeld {
                    self.beginHold()
                } else if !pressed && self.isHeld {
                    self.endHold(reason: "keyUp")
                }
            }
            flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler)
            // Jumeau local : quand VoxPrompt est l'app active (popover de préférences ouvert),
            // le monitor GLOBAL ne reçoit rien. Sans ce jumeau le keyUp est perdu et le micro
            // reste ouvert indéfiniment. On renvoie l'event inchangé pour ne rien consommer.
            flagsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                handler(event)
                return event
            }
            VPLog.log("hotkey monitor installed (modifier) keyCode=\(binding.keyCode) label=\(binding.label)")

        case .key:
            let down: (NSEvent) -> Void = { [weak self] event in
                guard let self else { return }
                guard event.keyCode == self.binding.keyCode else { return }
                if !event.isARepeat && !self.isHeld {
                    self.beginHold()
                }
            }
            let up: (NSEvent) -> Void = { [weak self] event in
                guard let self else { return }
                guard event.keyCode == self.binding.keyCode else { return }
                if self.isHeld {
                    self.endHold(reason: "keyUp")
                }
            }
            keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: down)
            keyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: up)
            keyDownLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                down(event)
                return event
            }
            keyUpLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
                up(event)
                return event
            }
            VPLog.log("hotkey monitor installed (key) keyCode=\(binding.keyCode) label=\(binding.label)")
        }
    }

    func stop() {
        if isHeld {
            VPLog.log("stop() called while key is held, synthesizing release")
            synthesizeRelease(reason: "stop")
        }
        stopWatchdog()
        [flagsMonitor, flagsLocalMonitor,
         keyDownMonitor, keyUpMonitor,
         keyDownLocalMonitor, keyUpLocalMonitor].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        flagsMonitor = nil
        flagsLocalMonitor = nil
        keyDownMonitor = nil
        keyUpMonitor = nil
        keyDownLocalMonitor = nil
        keyUpLocalMonitor = nil
    }

    /// Clôt de force la session en cours (écran verrouillé, panique côté AppDelegate...).
    /// No-op si aucune touche n'est tenue.
    func forceRelease() {
        guard isHeld else { return }
        runOnMain { [weak self] in
            self?.synthesizeRelease(reason: "forceRelease")
        }
    }

    // MARK: Transitions

    private func beginHold() {
        isHeld = true
        holdStartedAt = Date()
        let app = NSWorkspace.shared.frontmostApplication
        capturedFrontApp = app
        VPLog.log("hotkey down (\(binding.kind.rawValue)), captured frontApp=\(app?.localizedName ?? "?") pid=\(app?.processIdentifier ?? -1)")
        startWatchdog()
        onPress?(app)
    }

    private func endHold(reason: String) {
        guard isHeld else { return }
        isHeld = false
        holdStartedAt = nil
        stopWatchdog()
        let app = capturedFrontApp
        capturedFrontApp = nil
        if reason != "keyUp" {
            VPLog.log("hotkey release synthesized (\(reason)) target=\(app?.localizedName ?? "?")")
        }
        onRelease?(app)
    }

    private func synthesizeRelease(reason: String) {
        endHold(reason: reason)
    }

    // MARK: Watchdog

    /// Un keyUp peut être perdu : écran verrouillé pendant le maintien, champ Secure Input,
    /// app qui consomme le flagsChanged, remapping Karabiner. Le seul recours fiable est de
    /// relire l'état PHYSIQUE de la touche à intervalle régulier.
    private func startWatchdog() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.watchdog?.invalidate()
            let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
                self?.watchdogTick()
            }
            // .common : sinon le timer est gelé pendant un tracking de menu ou un popover.
            RunLoop.main.add(timer, forMode: .common)
            self.watchdog = timer
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func watchdogTick() {
        guard isHeld else {
            stopWatchdog()
            return
        }

        if let started = holdStartedAt, Date().timeIntervalSince(started) > maxHoldDuration {
            VPLog.log("hotkey held longer than \(Int(maxHoldDuration))s, forced release by watchdog")
            synthesizeRelease(reason: "maxHoldDuration")
            return
        }

        guard let code = binding.physicalKeyCode else {
            // Binding non traduisible en keycode physique : on ne peut rien vérifier,
            // seul le plafond maxHoldDuration protège encore.
            return
        }
        if !CGEventSource.keyState(.combinedSessionState, key: code) {
            VPLog.log("hotkey keyUp missed (physical state = up, keyCode=\(code)), release synthesized by watchdog")
            synthesizeRelease(reason: "keyUp manqué")
        }
    }

    // MARK: Utilitaires

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

enum HotkeyCatalog {
    static let presets: [HotkeyBinding] = [
        .defaultBinding,
        HotkeyBinding(kind: .modifier, keyCode: UInt16(NX_DEVICELALTKEYMASK), label: "Left Option"),
        HotkeyBinding(kind: .modifier, keyCode: UInt16(NX_DEVICERCTLKEYMASK), label: "Right Control"),
        HotkeyBinding(kind: .key, keyCode: UInt16(kVK_F13), label: "F13"),
        HotkeyBinding(kind: .key, keyCode: UInt16(kVK_F14), label: "F14"),
        HotkeyBinding(kind: .key, keyCode: UInt16(kVK_F15), label: "F15"),
        HotkeyBinding(kind: .key, keyCode: UInt16(kVK_F16), label: "F16"),
    ]
}
