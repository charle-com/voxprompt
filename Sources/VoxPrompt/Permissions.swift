import AppKit
import AVFoundation
import ApplicationServices
import CoreServices
import Combine

/// État d'une autorisation TCC. `unknown` couvre les cas où l'OS ne sait pas répondre
/// (service absent, appel qui échoue) : à traiter comme "on ne sait pas", jamais comme un refus.
enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined
    case unknown

    var isUsable: Bool { self == .granted }

    var label: String {
        switch self {
        case .granted: return "Autorisée"
        case .denied: return "Refusée"
        case .notDetermined: return "Non demandée"
        case .unknown: return "Indéterminée"
        }
    }
}

/// Lecture et demande des trois autorisations dont VoxPrompt dépend :
/// Accessibilité (capter le raccourci global + poster les CGEvent),
/// Microphone (enregistrer), Automatisation vers System Events (fallback AppleScript du collage).
enum Permissions {

    // MARK: Accessibilité

    /// `prompt: true` affiche la fenêtre système "autoriser dans les Réglages".
    /// L'état retourné reste celui de l'instant : macOS ne met à jour le trust
    /// qu'après validation de l'utilisateur, sans notification.
    static func accessibility(prompt: Bool) -> PermissionState {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: [String: Any] = [key: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary) ? .granted : .denied
    }

    // MARK: Microphone

    static func microphone() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    static func requestMicrophone() async -> PermissionState {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        let state: PermissionState = granted ? .granted : microphone()
        VPLog.log("microphone permission after request: \(state)")
        return state
    }

    // MARK: Automatisation (System Events)

    private static let systemEventsBundleID = "com.apple.systemevents"

    /// Lecture non bloquante de l'autorisation d'automatiser System Events.
    /// N'affiche jamais de dialogue (`askUserIfNeeded: false`).
    static func automationSystemEvents() -> PermissionState {
        determineAutomation(askUserIfNeeded: false)
    }

    /// Déclenche le dialogue de consentement Automatisation.
    ///
    /// ATTENTION : cet appel BLOQUE le thread appelant tant que l'utilisateur n'a pas répondu.
    /// Ne jamais l'appeler depuis le main thread (le popover de préférences gèlerait) :
    /// utiliser `requestAutomationSystemEventsAsync()` depuis l'UI.
    static func requestAutomationSystemEvents() -> PermissionState {
        if Thread.isMainThread {
            VPLog.log("WARNING: requestAutomationSystemEvents() called on main thread, UI will freeze until the user answers")
        }
        let state = determineAutomation(askUserIfNeeded: true)
        VPLog.log("automation permission after request: \(state)")
        return state
    }

    /// Variante sûre pour l'UI : le dialogue bloquant part sur une queue de fond.
    static func requestAutomationSystemEventsAsync() async -> PermissionState {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: determineAutomation(askUserIfNeeded: true))
            }
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` (macOS 10.14+) est le seul moyen documenté
    /// de connaître l'état d'une autorisation Automation sans tenter un Apple Event réel.
    /// Codes retour : noErr = accordée, errAEEventNotPermitted (-1743) = refusée,
    /// errAEEventWouldRequireUserConsent (-1744) = jamais demandée, procNotFound (-600) = cible absente.
    private static func determineAutomation(askUserIfNeeded: Bool) -> PermissionState {
        var target = AEAddressDesc()
        let idData = Data(systemEventsBundleID.utf8)
        // AECreateDesc renvoie un OSErr (Int16), pas un OSStatus (Int32).
        let created = idData.withUnsafeBytes { raw -> OSErr in
            AECreateDesc(DescType(typeApplicationBundleID), raw.baseAddress, raw.count, &target)
        }
        guard created == OSErr(noErr) else {
            VPLog.log("AECreateDesc failed (status=\(created))")
            return .unknown
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )

        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(procNotFound):
            return .unknown
        default:
            VPLog.log("AEDeterminePermissionToAutomateTarget unexpected status=\(status)")
            return .unknown
        }
    }

    // MARK: Réglages Système

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Emplacement du bundle

    /// TCC identifie une app par son chemin autant que par sa signature : une copie hors
    /// /Applications perd ses autorisations dès qu'elle est déplacée ou re-téléchargée.
    static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// Gatekeeper "app translocation" : une app lancée depuis un DMG ou depuis Downloads
    /// tourne depuis un point de montage aléatoire en lecture seule. Les autorisations TCC
    /// accordées à ce chemin fantôme disparaissent au redémarrage : il FAUT copier dans
    /// /Applications avant d'accorder l'accessibilité.
    static var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    // MARK: Dépannage

    /// Commande à donner à l'utilisateur quand une autorisation est bloquée dans un état
    /// incohérent (typique après un changement de signature ou un déplacement du bundle).
    /// Services attendus : `Accessibility`, `Microphone`, `AppleEvents`, `All`.
    static func resetHint(for service: String) -> String {
        let id = Bundle.main.bundleIdentifier ?? "fr.charlesneveu.voxprompt"
        return "tccutil reset \(service) \(id)"
    }

    /// Nom de service tccutil correspondant à chaque autorisation gérée ici.
    enum Service {
        static let accessibility = "Accessibility"
        static let microphone = "Microphone"
        static let automation = "AppleEvents"
    }
}

/// Rafraîchit les trois états toutes les 2 s tant qu'il tourne, plus à chaque retour au
/// premier plan : un toggle fait dans Réglages Système n'émet aucune notification, la seule
/// façon de voir le changement en direct dans les préférences est de re-sonder.
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published var accessibility: PermissionState = .unknown
    @Published var microphone: PermissionState = .unknown
    @Published var automation: PermissionState = .unknown

    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private static let interval: TimeInterval = 2

    init() {
        refresh()
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        refresh()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // .common : sinon le sondage est gelé pendant qu'un menu ou un popover est ouvert,
        // c'est-à-dire exactement quand l'écran des préférences est visible.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        VPLog.log("permission monitor started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    /// Accessibilité et micro sont des lectures locales bon marché. L'automatisation passe
    /// par une IPC vers tccd : on la sort du main thread pour ne pas la payer à chaque tick.
    func refresh() {
        let ax = Permissions.accessibility(prompt: false)
        let mic = Permissions.microphone()
        publish { monitor in
            if monitor.accessibility != ax { monitor.accessibility = ax }
            if monitor.microphone != mic { monitor.microphone = mic }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let auto = Permissions.automationSystemEvents()
            self?.publish { monitor in
                if monitor.automation != auto { monitor.automation = auto }
            }
        }
    }

    private func publish(_ block: @escaping (PermissionMonitor) -> Void) {
        if Thread.isMainThread {
            block(self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                block(self)
            }
        }
    }
}
