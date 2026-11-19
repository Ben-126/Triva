//
//  ExternalQueryInboxTests.swift
//  TrivaTests
//
//  Chantier 2.2 (M1) : boîte d'entrée des questions venues de l'extérieur (Services, barre des menus).
//

import Foundation
import Testing
@testable import Triva

@MainActor
struct ExternalQueryInboxTests {
    @Test("deposit puis take(for:) rend le texte UNE seule fois")
    func takeOnlyOnce() {
        let inbox = ExternalQueryInbox()
        let id = inbox.deposit("Pourquoi le ciel est bleu ?")
        #expect(inbox.take(for: id) == "Pourquoi le ciel est bleu ?")
        #expect(inbox.take(for: id) == nil)
    }

    @Test("take pour un identifiant inconnu : nil")
    func unknownIdentifier() {
        let inbox = ExternalQueryInbox()
        _ = inbox.deposit("a")
        #expect(inbox.take(for: UUID()) == nil)
    }

    @Test("Deux dépôts : identifiants distincts, chacun rend son propre texte")
    func independentDeposits() {
        let inbox = ExternalQueryInbox()
        let first = inbox.deposit("un")
        let second = inbox.deposit("deux")
        #expect(first != second)
        #expect(inbox.take(for: second) == "deux")
        #expect(inbox.take(for: first) == "un")
    }

    @Test("revision augmente à chaque dépôt, pas à chaque lecture ; lastDepositID suit le dernier dépôt")
    func revisionAndLastDeposit() {
        let inbox = ExternalQueryInbox()
        #expect(inbox.revision == 0)
        #expect(inbox.lastDepositID == nil)
        let first = inbox.deposit("un")
        #expect(inbox.revision == 1)
        #expect(inbox.lastDepositID == first)
        let second = inbox.deposit("deux")
        #expect(inbox.revision == 2)
        #expect(inbox.lastDepositID == second)
        _ = inbox.take(for: first)
        #expect(inbox.revision == 2)
    }

    @Test("Mémoire bornée : au-delà de la capacité, les plus anciens dépôts sont oubliés")
    func capacityDropsOldest() {
        let inbox = ExternalQueryInbox(capacity: 3)
        let ids = (0..<5).map { inbox.deposit("q\($0)") }
        #expect(inbox.pendingCount == 3)
        #expect(inbox.take(for: ids[0]) == nil)
        #expect(inbox.take(for: ids[1]) == nil)
        #expect(inbox.take(for: ids[4]) == "q4")
        #expect(inbox.take(for: ids[2]) == "q2")
    }

    @Test("discardAll vide la boîte (rien ne traîne en mémoire)")
    func discardAll() {
        let inbox = ExternalQueryInbox()
        let id = inbox.deposit("secret")
        inbox.discardAll()
        #expect(inbox.pendingCount == 0)
        #expect(inbox.take(for: id) == nil)
    }
}
