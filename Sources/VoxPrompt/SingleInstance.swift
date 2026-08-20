import AppKit
import Foundation

/// Garde-fou anti double lancement.
///
/// Cas réel : le bundle de développement (`./build/VoxPrompt.app`) lancé alors que la copie
/// de /Applications tourne déjà depuis le login. Les deux instances installent leurs monitors
/// clavier, enregistrent en parallèle et collent DEUX fois le même texte, sans que rien
/// d'autre ne le signale.
enum SingleInstance {

    /// Termine l'instance courante si une autre du même bundle id tourne déjà.
    /// No-op quand le binaire tourne hors bundle (SwiftPM en développement) : dans ce cas
    /// `Bundle.main.bundleIdentifier` est nil et LaunchServices ne connaît pas le process.
    static func enforce() {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else { return }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let myLaunch = NSRunningApplication.current.launchDate ?? Date()

        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }

        guard !others.isEmpty else { return }

        // Départage si deux instances démarrent en même temps : seule la plus récente s'efface,
        // sinon les deux se suicident mutuellement et l'utilisateur se retrouve sans app.
        let older = others.filter { ($0.launchDate ?? .distantPast) <= myLaunch }
        guard let survivor = older.first ?? others.first else { return }

        let path = survivor.bundleURL?.path ?? "?"
        VPLog.log("another VoxPrompt instance is already running (pid=\(survivor.processIdentifier) path=\(path)), terminating this one (pid=\(myPID))")

        // [.activateIgnoringOtherApps] : l'autre instance est en .accessory, l'activation
        // coopérative ne la ramènerait pas au premier plan.
        survivor.activate(options: [.activateIgnoringOtherApps])

        // exit() plutôt que NSApp.terminate() : enforce() est appelé avant que la boucle
        // d'évènements tourne, où terminate() ne ferait que revenir sans rien terminer.
        // Il n'y a aucun état à sauvegarder.
        exit(0)
    }
}
