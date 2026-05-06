import Foundation
import ServiceManagement

/// Wrapper sur SMAppService pour gérer le lancement au login.
/// API moderne macOS 13+ : pas de helper bundle, l'app se register elle-même via son bundle id.
/// Source : https://developer.apple.com/documentation/servicemanagement/smappservice
enum LoginItem {
    /// État actuel : true si l'app est enregistrée et activée pour le login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// L'utilisateur doit valider dans Réglages > Général > Éléments d'ouverture.
    /// Apparaît quand l'app vient de demander l'enregistrement mais que macOS attend la confirmation user.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Active ou désactive le launch at login. Retourne true si l'opération a réussi.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                VPLog.log("login item registered (status=\(statusLabel))")
            } else {
                try SMAppService.mainApp.unregister()
                VPLog.log("login item unregistered (status=\(statusLabel))")
            }
            return true
        } catch {
            VPLog.log("login item toggle error: \(error)")
            return false
        }
    }

    private static var statusLabel: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        case .requiresApproval: return "requiresApproval"
        @unknown default: return "unknown"
        }
    }
}
