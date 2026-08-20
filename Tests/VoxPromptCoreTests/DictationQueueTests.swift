import XCTest
@testable import VoxPromptCore

/// La file est le mécanisme qui permet d'enchaîner deux vocaux sans attendre la
/// transcription du premier. Ce qu'on vérifie ici : l'ordre de dictée est préservé, un
/// seul consommateur tourne à la fois, et une prise déposée pendant le drain n'est
/// jamais oubliée.
final class DictationQueueTests: XCTestCase {

    func testDeliversJobsInDictationOrder() {
        var q = DictationQueue<Int>()
        q.enqueue(1); q.enqueue(2); q.enqueue(3)

        XCTAssertTrue(q.claimConsumer())
        XCTAssertEqual([q.next(), q.next(), q.next()], [1, 2, 3])
        XCTAssertNil(q.next())
    }

    func testEnqueueDoesNotWaitOnTheConsumer() {
        // Le cas d'usage : la dictée 1 est en cours de transcription et la 2 est relâchée.
        var q = DictationQueue<String>()
        q.enqueue("première")
        XCTAssertTrue(q.claimConsumer())
        let first = q.next()

        // Pendant que « première » est traitée, une seconde prise arrive.
        XCTAssertTrue(q.enqueue("deuxième"))
        XCTAssertEqual(first, "première")
        XCTAssertEqual(q.next(), "deuxième")
    }

    func testOnlyOneConsumerAtATime() {
        var q = DictationQueue<Int>()
        q.enqueue(1)
        XCTAssertTrue(q.claimConsumer())
        // Un second dépôt ne doit pas démarrer un deuxième consommateur : deux collages
        // concurrents se voleraient le presse-papier.
        q.enqueue(2)
        XCTAssertFalse(q.claimConsumer())
    }

    func testConsumerRoleIsReleasedWhenQueueEmpties() {
        var q = DictationQueue<Int>()
        q.enqueue(1)
        XCTAssertTrue(q.claimConsumer())
        _ = q.next()
        XCTAssertNil(q.next())            // file vidée : le rôle est rendu
        XCTAssertTrue(q.claimConsumer())  // un nouveau dépôt peut relancer un worker
    }

    func testJobArrivingAfterDrainEndsIsPickedUpByANewConsumer() {
        var q = DictationQueue<Int>()
        q.enqueue(1)
        XCTAssertTrue(q.claimConsumer())
        _ = q.next()
        XCTAssertNil(q.next())

        q.enqueue(2)
        XCTAssertTrue(q.claimConsumer())
        XCTAssertEqual(q.next(), 2)
    }

    func testRefusesJobsBeyondCapacity() {
        var q = DictationQueue<Int>(capacity: 2)
        XCTAssertTrue(q.enqueue(1))
        XCTAssertTrue(q.enqueue(2))
        XCTAssertTrue(q.isFull)
        XCTAssertFalse(q.enqueue(3))
        XCTAssertEqual(q.count, 2)

        // Une place se libère dès qu'une prise part en traitement.
        XCTAssertTrue(q.claimConsumer())
        _ = q.next()
        XCTAssertFalse(q.isFull)
        XCTAssertTrue(q.enqueue(3))
    }

    func testIsSettledOnlyWhenNothingIsLeft() {
        var q = DictationQueue<Int>()
        XCTAssertTrue(q.isSettled)

        q.enqueue(1)
        XCTAssertFalse(q.isSettled)          // en file
        XCTAssertTrue(q.claimConsumer())
        _ = q.next()
        XCTAssertFalse(q.isSettled)          // vide, mais un job est en cours de traitement
        XCTAssertNil(q.next())
        XCTAssertTrue(q.isSettled)           // rien en file, plus de consommateur
    }
}

extension DictationQueueTests {

    /// Le compteur montré à l'utilisateur pendant qu'il enchaîne un vocal doit inclure la
    /// dictée déjà en cours de transcription, sans quoi le HUD annonce « rien en attente »
    /// alors qu'un texte est sur le point d'être collé.
    func testOutstandingCountsTheJobBeingProcessed() {
        var q = DictationQueue<Int>()
        XCTAssertEqual(q.outstanding, 0)

        q.enqueue(1)
        XCTAssertEqual(q.outstanding, 1)

        XCTAssertTrue(q.claimConsumer())
        _ = q.next()                       // la dictée 1 est sortie de la file, mais en cours
        XCTAssertEqual(q.count, 0)
        XCTAssertEqual(q.outstanding, 1)

        q.enqueue(2)                       // second vocal relâché pendant le traitement
        XCTAssertEqual(q.outstanding, 2)

        _ = q.next()
        XCTAssertEqual(q.outstanding, 1)
        XCTAssertNil(q.next())
        XCTAssertEqual(q.outstanding, 0)
    }
}
