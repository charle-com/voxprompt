import AppKit
import Combine
import Foundation

/// Vérification de mise à jour, opt-in et désactivée par défaut.
///
/// Un seul appel réseau vers l'API publique GitHub, aucune donnée envoyée hormis le
/// User-Agent (imposé par GitHub), aucun identifiant, aucun cookie (session éphémère).
/// L'app reste utilisable hors ligne : toute erreur atterrit dans `lastError` et rien d'autre.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// Version plus récente disponible. nil = à jour, ou pas encore vérifié.
    @Published var latest: (version: String, url: URL)?
    @Published var lastCheck: Date?
    @Published var lastError: String?

    /// Clés UserDefaults lues directement : `Settings` les exposera côté UI.
    static let enabledKey = "update.checkEnabled"
    static let lastCheckKey = "update.lastCheck"

    private static let endpoint = URL(string: "https://api.github.com/repos/charle-com/voxprompt/releases/latest")!
    private static let minimumInterval: TimeInterval = 24 * 60 * 60
    private static let timeout: TimeInterval = 10

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = UpdateChecker.timeout
        config.timeoutIntervalForResource = UpdateChecker.timeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    init() {
        lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
    }

    // MARK: API

    /// Appel silencieux au démarrage : ne fait rien si l'option est désactivée,
    /// et au plus une vérification par tranche de 24 h.
    func checkIfEnabled() async {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.minimumInterval {
            return
        }
        await checkNow()
    }

    /// Vérification forcée, pour le bouton des préférences. Ignore l'intervalle de 24 h
    /// mais respecte le reste (timeout, aucune donnée envoyée).
    func checkNow() async {
        let current = Self.currentVersion
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = Self.timeout
        // GitHub rejette les requêtes sans User-Agent. C'est la seule chose qu'on transmet.
        request.setValue("VoxPrompt/\(current)", forHTTPHeaderField: "User-Agent")

        let now = Date()
        lastCheck = now
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                lastError = "GitHub a répondu \(http.statusCode)"
                VPLog.log("update check http \(http.statusCode)")
                return
            }
            guard let release = Self.parse(data) else {
                lastError = "Réponse GitHub illisible"
                VPLog.log("update check: unparsable payload (\(data.count) bytes)")
                return
            }
            lastError = nil
            if Self.isNewer(release.version, than: current) {
                latest = (version: release.version, url: release.url)
                VPLog.log("update available: \(release.version) (current \(current))")
            } else {
                latest = nil
                VPLog.log("no update: latest=\(release.version) current=\(current)")
            }
        } catch {
            // Réseau absent, DNS KO, timeout : on n'insiste pas et surtout on ne crashe pas.
            lastError = (error as NSError).localizedDescription
            VPLog.log("update check failed: \(error)")
        }
    }

    func openLatest() {
        guard let latest else { return }
        NSWorkspace.shared.open(latest.url)
    }

    // MARK: Parsing et semver (nonisolated : testable sans MainActor)

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    nonisolated static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// Extrait `tag_name` (forme `vX.Y.Z`) et `html_url` du JSON de l'API releases.
    nonisolated static func parse(_ data: Data) -> (version: String, url: URL)? {
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        let version = normalized(release.tagName)
        guard !version.isEmpty, let url = URL(string: release.htmlURL) else { return nil }
        return (version, url)
    }

    /// `v0.2.0` devient `0.2.0`. Le `v` est une convention de tag, pas une partie de la version.
    nonisolated static func normalized(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        return value
    }

    /// Comparaison semver tolérante : nombre de composants variable, suffixe de pré-release
    /// ignoré pour le numérique mais départageant à égalité (1.0.0-beta < 1.0.0).
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        let count = max(a.numbers.count, b.numbers.count)
        for index in 0..<count {
            let left = index < a.numbers.count ? a.numbers[index] : 0
            let right = index < b.numbers.count ? b.numbers[index] : 0
            if left != right { return left > right }
        }
        // Numériquement égaux : une version finale l'emporte sur une pré-release.
        if a.prerelease == nil && b.prerelease != nil { return true }
        return false
    }

    private nonisolated static func components(_ version: String) -> (numbers: [Int], prerelease: String?) {
        var value = normalized(version)
        // On jette le build metadata (+sha), il ne participe jamais à la précédence.
        if let plus = value.firstIndex(of: "+") { value = String(value[value.startIndex..<plus]) }
        var prerelease: String?
        if let dash = value.firstIndex(of: "-") {
            prerelease = String(value[value.index(after: dash)...])
            value = String(value[value.startIndex..<dash])
        }
        let numbers = value.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        return (numbers.isEmpty ? [0] : numbers, prerelease)
    }
}
