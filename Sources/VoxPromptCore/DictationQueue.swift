import Foundation

/// File d'attente FIFO à consommateur unique, qui découple la capture audio du travail
/// long (transcription puis collage).
///
/// Sans elle, relâcher la touche bloquait jusqu'à la fin du collage : impossible
/// d'enchaîner un second vocal sans attendre le premier. Ici, déposer une prise rend la
/// main tout de suite, et un seul consommateur vide la file dans l'ordre de dictée.
///
/// Le consommateur unique n'est pas un détail de performance, c'est une garantie de
/// correction : deux collages concurrents sauvegardent et restaurent le presse-papier
/// chacun de leur côté, et le second rend à l'utilisateur le presse-papier du premier.
///
/// Structure volontairement passive et synchrone (pas d'acteur, pas de verrou) : elle est
/// destinée à un seul contexte d'isolation (le main actor côté app) et reste ainsi
/// testable de bout en bout sans concurrence.
public struct DictationQueue<Job> {

    /// Prises déposées, pas encore consommées, dans l'ordre d'arrivée.
    public private(set) var pending: [Job] = []

    /// Vrai tant qu'un consommateur tourne. Empêche qu'un second démarre en parallèle.
    public private(set) var isDraining = false

    /// Au-delà, `enqueue` refuse : ce n'est plus un enchaînement mais un moteur qui a
    /// décroché, et chaque prise en attente immobilise un fichier audio.
    public let capacity: Int

    public init(capacity: Int = 8) {
        self.capacity = capacity
    }

    public var count: Int { pending.count }
    public var isEmpty: Bool { pending.isEmpty }
    /// Vrai quand il ne reste rien à faire, ni en file ni en cours.
    public var isSettled: Bool { pending.isEmpty && !isDraining }

    /// Travaux pas encore terminés, celui en cours de traitement compris. C'est le chiffre
    /// à montrer à l'utilisateur : `count` seul oublierait la dictée déjà sortie de la file
    /// mais toujours en transcription, et afficherait « rien en attente » à tort.
    public var outstanding: Int { pending.count + (isDraining ? 1 : 0) }

    /// Dépose une prise. Renvoie `false` si la file est pleine, auquel cas la prise est
    /// refusée : mieux vaut le dire à l'utilisateur que gonfler une file qui n'avance plus.
    @discardableResult
    public mutating func enqueue(_ job: Job) -> Bool {
        guard pending.count < capacity else { return false }
        pending.append(job)
        return true
    }

    /// Vrai si la file est pleine, donc si `enqueue` refuserait.
    public var isFull: Bool { pending.count >= capacity }

    /// Réclame le rôle de consommateur. Renvoie `true` UNE SEULE fois tant que le
    /// consommateur tourne : l'appelant qui reçoit `true` doit boucler sur `next()`.
    public mutating func claimConsumer() -> Bool {
        guard !isDraining else { return false }
        isDraining = true
        return true
    }

    /// Prise suivante à traiter, dans l'ordre de dictée. `nil` quand la file est vide :
    /// le rôle de consommateur est alors rendu, et un prochain dépôt pourra le reprendre.
    public mutating func next() -> Job? {
        guard !pending.isEmpty else {
            isDraining = false
            return nil
        }
        return pending.removeFirst()
    }
}
