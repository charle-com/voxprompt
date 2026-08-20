import Foundation
import AppKit

/// Fonctions PURES de nettoyage du texte transcrit : aucune dépendance à WhisperKit,
/// à CoreML ni à l'état de l'app. Regroupées ici pour être testables isolément
/// (un exécutable de test peut compiler ce seul fichier).
///
/// Trois familles :
///   1. détection / effondrement des boucles de répétition du décodeur ;
///   2. exemption des suites numériques, qui se répètent LÉGITIMEMENT à l'oral ;
///   3. glossaire (correction des noms propres et du jargon) avec garde-fou dictionnaire.
public enum TextCleanup {

    // MARK: - Seuils

    /// Nombre de répétitions consécutives à partir duquel on EFFONDRE le motif dans le
    /// texte final. Un mot seul doit être répété 5 fois : « non non non » et
    /// « très très bien » sont des tournures orales normales, pas des boucles.
    /// Un motif de 2 mots ou plus reste à 3 : « je vais je vais je vais » n'a aucun
    /// équivalent naturel.
    public static func collapseThreshold(patternSize: Int) -> Int {
        patternSize == 1 ? 5 : 3
    }

    /// Nombre de répétitions à partir duquel on envisage de COUPER le décodage en vol.
    /// Un cran au-dessus du seuil d'effondrement : couper est destructif (on perd la
    /// suite de la phrase), donc on attend une preuve plus nette.
    public static func abortThreshold(patternSize: Int) -> Int {
        patternSize == 1 ? 6 : 4
    }

    // MARK: - Tokens numériques

    /// Un token « numérique » : chiffres nus (« 06 », « 44 »), heure (« 12h30 »),
    /// prix (« 19,90 », « 12 € »), pourcentage, numéro de série.
    ///
    /// Ces tokens se répètent légitimement dans la dictée : un numéro de téléphone
    /// (« 06 44 44 44 44 »), une adresse, un montant. Les compter comme une boucle de
    /// décodage détruisait l'information (« 06 44 »). On les exempte donc totalement,
    /// aussi bien de l'effondrement que de la coupe.
    public static func isNumericToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var sawDigit = false
        for ch in token {
            if ch.isNumber { sawDigit = true; continue }
            // Séparateurs et unités qui font partie d'un nombre, d'une heure ou d'un prix.
            if ",.:;/-+'’hH€$£%°".contains(ch) { continue }
            return false
        }
        return sawDigit
    }

    /// Vrai si TOUS les tokens du motif sont numériques. Un motif mixte
    /// (« merci 44 merci 44 ») reste traité comme une boucle potentielle.
    public static func isNumericPattern(_ pattern: [String]) -> Bool {
        !pattern.isEmpty && pattern.allSatisfy(isNumericToken)
    }

    // MARK: - Effondrement des répétitions

    /// Réduit à une seule occurrence tout motif de 1 à 6 mots répété au moins
    /// `collapseThreshold(patternSize:)` fois consécutivement. Renvoie le texte original
    /// intact si rien n'est répété. Les motifs entièrement numériques sont préservés.
    public static func collapseRepetitions(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Le plus petit motif effondrable fait 5 mots (1 mot x 5 répétitions).
        guard words.count >= 5 else { return text }
        var touched = false
        var changed = true
        while changed {
            changed = false
            // Du plus petit motif au plus grand : une répétition mono-mot (« prêt prêt
            // prêt… ») doit s'effondrer entièrement avant qu'un bigramme ne la capture
            // partiellement (sinon 10 mots identiques se réduisent à 2 au lieu de 1).
            for size in 1...6 {
                let minReps = collapseThreshold(patternSize: size)
                var i = 0
                while i + size * minReps <= words.count {
                    let slice = Array(words[i..<i + size])
                    if isNumericPattern(slice) { i += 1; continue }
                    let pattern = slice.map { $0.lowercased() }
                    var reps = 1
                    var j = i + size
                    while j + size <= words.count,
                          words[j..<j + size].map({ $0.lowercased() }) == pattern {
                        reps += 1
                        j += size
                    }
                    if reps >= minReps {
                        words.removeSubrange((i + size)..<(i + size * reps))
                        changed = true
                        touched = true
                    }
                    // Avance d'un seul mot (et non d'un motif entier) pour ne jamais rater
                    // l'alignement de phase d'une répétition décalée (« on y va on y va… »
                    // capté à partir du bon mot plutôt que de « y va on »).
                    i += 1
                }
                if changed { break }
            }
        }
        return touched ? words.joined(separator: " ") : text
    }

    // MARK: - Détection de boucle en vol

    /// Détecte une boucle de répétition en FIN de texte et renvoie le nombre de mots
    /// UTILES qui la précèdent (la « tête »). `nil` = pas de boucle.
    ///
    /// Cette tête est ce qui permet de distinguer un décodeur réellement bloqué (la tête
    /// n'avance plus d'un callback à l'autre) d'un texte qui contient une répétition mais
    /// continue de progresser derrière.
    public static func repetitionHeadWordCount(_ text: String) -> Int? {
        let raw = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        guard raw.count >= 8 else { return nil }
        let tailRaw = Array(raw.suffix(60))
        let tail = tailRaw.map { $0.lowercased() }
        let offset = raw.count - tailRaw.count
        let n = tail.count
        for size in 1...6 {
            let minReps = abortThreshold(patternSize: size)
            guard n >= size * minReps else { continue }
            if isNumericPattern(Array(tailRaw.suffix(size))) { continue }
            let pattern = Array(tail.suffix(size))
            var reps = 1
            var idx = n - size
            while idx - size >= 0 {
                if Array(tail[(idx - size)..<idx]) == pattern {
                    reps += 1
                    idx -= size
                } else {
                    break
                }
            }
            if reps >= minReps { return offset + idx }
        }
        return nil
    }

    /// Compatibilité : vrai si le texte se termine par une boucle de répétition.
    /// À utiliser seulement pour un diagnostic ponctuel ; pour couper un décodage en
    /// cours, passer par `RepetitionMonitor`, qui exige en plus une absence de progrès.
    public static func isRepetitionLoop(_ text: String) -> Bool {
        repetitionHeadWordCount(text) != nil
    }

    // MARK: - Glossaire

    /// Applique le glossaire mot à mot en préservant ponctuation et espaces.
    /// `isKnownWord` est injecté pour garder la fonction testable sans AppKit.
    public static func applyGlossary(
        _ text: String,
        glossary: [String],
        isKnownWord: (String) -> Bool = TextCleanup.dictionaryKnowsWord
    ) -> String {
        let items = glossary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        guard !items.isEmpty else { return text }

        var output = ""
        var buffer = ""
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "-" {
                buffer.append(ch)
            } else {
                if !buffer.isEmpty {
                    output.append(glossaryReplacement(for: buffer, glossary: items, isKnownWord: isKnownWord))
                    buffer = ""
                }
                output.append(ch)
            }
        }
        if !buffer.isEmpty {
            output.append(glossaryReplacement(for: buffer, glossary: items, isKnownWord: isKnownWord))
        }
        return output
    }

    /// Découpe une chaîne de glossaire saisie dans les Préférences (« GYL, Klaviyo ; X-Water »).
    public static func parseGlossary(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",\n;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    /// Décide du remplacement d'UN mot.
    ///
    /// Règles (durcies : l'ancienne tolérance de 1 dès 3 lettres transformait « gel » en
    /// « GYL » et « dandy » en « Gandy ») :
    ///   - correspondance exacte insensible à la casse : toujours appliquée, elle ne fait
    ///     que rétablir la graphie canonique ;
    ///   - terme de glossaire de moins de 5 lettres : correspondance exacte SEULEMENT ;
    ///   - 5 à 7 lettres : distance de Levenshtein 1 ;
    ///   - 8 lettres et plus : distance 2 ;
    ///   - un mot déjà présent au dictionnaire n'est JAMAIS remplacé en flou.
    public static func glossaryReplacement(
        for word: String,
        glossary: [String],
        isKnownWord: (String) -> Bool = TextCleanup.dictionaryKnowsWord
    ) -> String {
        guard word.count >= 2 else { return word }
        let wLower = word.lowercased()

        // 1. Exact : prime sur tout, et s'applique même à un mot du dictionnaire.
        for item in glossary where item.lowercased() == wLower { return item }

        // 2. Flou : interdit sur un mot que le dictionnaire reconnaît déjà.
        if isKnownWord(word) { return word }

        var best: (item: String, distance: Int)?
        for item in glossary {
            let maxDist: Int
            switch item.count {
            case ..<5: continue          // trop court pour un rapprochement flou fiable
            case 5...7: maxDist = 1
            default: maxDist = 2
            }
            // Borne rapide : un écart de longueur supérieur à la tolérance est rédhibitoire.
            if abs(item.count - word.count) > maxDist { continue }
            let d = levenshtein(wLower, item.lowercased())
            if d <= maxDist, best == nil || d < best!.distance {
                best = (item, d)
            }
        }
        return best?.item ?? word
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        let m = aChars.count, n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }

    // MARK: - Dictionnaire système

    /// Vrai si le mot est orthographiquement valide en français OU en anglais.
    ///
    /// `NSSpellChecker` n'est pas documenté comme thread-safe, mais il a été vérifié
    /// fonctionnel hors du main thread sur cette machine (macOS 26.5, appels sur une file
    /// globale : réponses correctes, ~2 ms par mot après le premier appel). On le
    /// sérialise donc derrière un verrou plutôt que de faire un aller-retour vers le main
    /// thread : la transcription tourne dans un actor et un saut MainActor par mot
    /// risquerait un blocage si le main thread est occupé. En cas d'indisponibilité, on
    /// renvoie `false` (aucun mot connu), ce qui restaure simplement l'ancien
    /// comportement flou sans jamais planter.
    public static func dictionaryKnowsWord(_ word: String) -> Bool {
        SpellDictionary.shared.knows(word)
    }
}

/// Accès sérialisé au correcteur orthographique système.
public final class SpellDictionary: @unchecked Sendable {
    public static let shared = SpellDictionary()
    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    public func knows(_ word: String) -> Bool {
        let key = word.lowercased()
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        let checker = NSSpellChecker.shared
        var known = false
        for language in ["fr", "en"] {
            let range = checker.checkSpelling(of: word, startingAt: 0, language: language,
                                              wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if range.location == NSNotFound || range.length == 0 { known = true; break }
        }
        if cache.count < 4_000 { cache[key] = known }
        lock.unlock()
        return known
    }
}

/// Suit les callbacks successifs du décodeur pour décider s'il faut COUPER.
///
/// Une répétition isolée ne suffit plus : on ne coupe que si le texte n'a pas progressé
/// HORS de la boucle sur les 3 derniers callbacks. Un décodeur qui répète puis repart
/// (cas fréquent sur une hésitation) n'est donc plus tué à tort.
public final class RepetitionMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var heads: [Int] = []

    public init() {}

    public func shouldAbort(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let head = TextCleanup.repetitionHeadWordCount(text) else {
            heads.removeAll()
            return false
        }
        heads.append(head)
        if heads.count > 3 { heads.removeFirst() }
        return heads.count == 3 && heads.allSatisfy { $0 == heads[0] }
    }
}
