import XCTest
@testable import VoxPromptCore

/// Ces tests protegent les deux traitements qui peuvent SILENCIEUSEMENT abimer une
/// transcription correcte : l'effondrement des repetitions et la correction par glossaire.
/// Un faux positif ici ne plante pas l'app, il reecrit ce que l'utilisateur a dit.
final class TextCleanupTests: XCTestCase {

    // MARK: Repetitions legitimes preservees

    func testKeepsDeliberateDoubling() {
        XCTAssertEqual(TextCleanup.collapseRepetitions("c'est très très bien"),
                       "c'est très très bien")
    }

    func testKeepsTripledWord() {
        // "non non non" est une insistance courante a l'oral, pas une boucle de decodeur.
        XCTAssertEqual(TextCleanup.collapseRepetitions("non non non je ne veux pas"),
                       "non non non je ne veux pas")
    }

    func testKeepsRepeatedDigitsInPhoneNumber() {
        let phone = "mon numéro est 06 44 44 44 44"
        XCTAssertEqual(TextCleanup.collapseRepetitions(phone), phone)
    }

    func testKeepsRepeatedPrices() {
        let prices = "19,90 19,90 19,90 19,90 19,90"
        XCTAssertEqual(TextCleanup.collapseRepetitions(prices), prices)
    }

    func testShortTextIsNeverTouched() {
        XCTAssertEqual(TextCleanup.collapseRepetitions("oui oui"), "oui oui")
    }

    // MARK: Vraies boucles de decodeur effondrees

    func testCollapsesRunawaySingleWord() {
        let looped = "merci merci merci merci merci merci merci"
        let cleaned = TextCleanup.collapseRepetitions(looped)
        XCTAssertEqual(cleaned, "merci")
    }

    func testCollapsesRunawayPhrase() {
        let looped = "je vais le faire je vais le faire je vais le faire je vais le faire"
        let cleaned = TextCleanup.collapseRepetitions(looped)
        XCTAssertEqual(cleaned, "je vais le faire")
    }

    func testCollapsePreservesSurroundingText() {
        let looped = "bonjour prêt prêt prêt prêt prêt prêt à partir"
        let cleaned = TextCleanup.collapseRepetitions(looped)
        XCTAssertTrue(cleaned.hasPrefix("bonjour "), "début perdu: \(cleaned)")
        XCTAssertTrue(cleaned.hasSuffix(" à partir"), "fin perdue: \(cleaned)")
        XCTAssertFalse(cleaned.contains("prêt prêt prêt"), "boucle non traitée: \(cleaned)")
    }

    // MARK: Detection de boucle en cours de decodage

    func testDoesNotAbortOnNormalSpeech() {
        XCTAssertFalse(TextCleanup.isRepetitionLoop(
            "bonjour je teste la dictée vocale sur mon Mac ce matin"))
    }

    func testDoesNotAbortOnRepeatedNumbers() {
        XCTAssertFalse(TextCleanup.isRepetitionLoop(
            "le code est 44 44 44 44 44 44 44 44"))
    }

    func testAbortsOnRunawayLoop() {
        XCTAssertTrue(TextCleanup.isRepetitionLoop(
            "et donc voilà voilà voilà voilà voilà voilà voilà voilà"))
    }

    // MARK: Tokens numeriques

    func testNumericTokenRecognition() {
        for token in ["44", "19,90", "12h30", "2026", "3.14"] {
            XCTAssertTrue(TextCleanup.isNumericToken(token), "\(token) devrait être numérique")
        }
        for token in ["bonjour", "GYL", "l'année"] {
            XCTAssertFalse(TextCleanup.isNumericToken(token), "\(token) ne devrait pas être numérique")
        }
    }

    // MARK: Glossaire

    private let glossary = ["GYL", "Klaviyo", "Shopify", "SEOPITAL", "Kwanko"]

    func testGlossaryFixesCloseMatch() {
        XCTAssertEqual(applied("envoie sur klavyo demain"), "envoie sur Klaviyo demain")
    }

    func testGlossaryFixesCasing() {
        XCTAssertEqual(applied("le sac gyl est prêt"), "le sac GYL est prêt")
    }

    func testGlossaryKeepsCorrectWord() {
        XCTAssertEqual(applied("publie sur Shopify"), "publie sur Shopify")
    }

    func testGlossaryNeverRewritesRealWords() {
        // Le piege historique : "gel" transforme en "GYL", "dandy" en "Gandy".
        for sentence in ["mets du gel dans tes cheveux",
                         "un vrai dandy",
                         "je tape sur le clavier",
                         "direction l'hôpital"] {
            XCTAssertEqual(applied(sentence), sentence, "mot du dictionnaire abîmé")
        }
    }

    func testGlossaryPreservesPunctuationAndSpacing() {
        XCTAssertEqual(applied("Shopify, klavyo ; puis gyl."),
                       "Shopify, Klaviyo ; puis GYL.")
    }

    func testEmptyGlossaryIsNoOp() {
        let text = "rien ne doit changer ici"
        XCTAssertEqual(TextCleanup.applyGlossary(text, glossary: []), text)
    }

    func testGlossaryParsingAcceptsCommasAndNewlines() {
        let parsed = TextCleanup.parseGlossary("GYL, Klaviyo\nShopify ;  \n\n Kwanko")
        XCTAssertEqual(parsed.sorted(), ["GYL", "Klaviyo", "Kwanko", "Shopify"])
    }

    // MARK: Levenshtein

    func testLevenshteinBasics() {
        XCTAssertEqual(TextCleanup.levenshtein("chat", "chat"), 0)
        XCTAssertEqual(TextCleanup.levenshtein("chat", "chats"), 1)
        XCTAssertEqual(TextCleanup.levenshtein("", "abc"), 3)
        XCTAssertEqual(TextCleanup.levenshtein("klavyo", "klaviyo"), 1)
    }

    // MARK: Robustesse

    func testHandlesEmptyAndWhitespace() {
        XCTAssertEqual(TextCleanup.collapseRepetitions(""), "")
        XCTAssertEqual(TextCleanup.collapseRepetitions("   "), "   ")
        XCTAssertFalse(TextCleanup.isRepetitionLoop(""))
    }

    func testHandlesLongTextWithoutHanging() {
        let long = Array(repeating: "phrase normale de dictée", count: 200).joined(separator: " ")
        let started = Date()
        _ = TextCleanup.collapseRepetitions(long)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "traitement trop lent")
    }

    // MARK: Helper

    private func applied(_ text: String) -> String {
        TextCleanup.applyGlossary(text, glossary: glossary)
    }
}
