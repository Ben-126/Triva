//
//  HandoffConversationImportTests.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H2) : une discussion reçue par Handoff est enregistrée comme une conversation locale :
//  nouvelle si elle n'existe pas ici, fusionnée (messages manquants seulement) si le même identifiant existe, copiée
//  sous un autre identifiant si une fenêtre la tient déjà (aucune fenêtre ne se retrouve avec un fil périmé).
//

import Foundation
import SwiftData
import Testing
@testable import Triva

@MainActor
@Suite("Handoff conversation : enregistrement")
struct HandoffConversationImportTests {
    private let id = HandoffFixtures.conversationID

    @Test("Conversation inconnue ici : créée avec le même identifiant, les mêmes messages, sources, dates et mentions")
    func createsANewConversation() throws {
        let store = try historyMakeStore()
        var snapshot = HandoffFixtures.snapshot(pairs: 2, title: "Les volcans")
        snapshot.messages[1].notes = HandoffConversationSnapshot.Notes(uncitableSourceNumbers: [1], answeredWithoutSearch: true)
        snapshot.messages[3].reportsNoReliableSources = true

        let result = try store.importHandoff(snapshot)

        #expect(result.conversationID == id)
        #expect(result.disposition == .created)
        let stored = try #require(try store.conversation(with: id))
        #expect(stored.title == "Les volcans")
        #expect(stored.createdAt == snapshot.createdAt)
        #expect(stored.updatedAt == snapshot.updatedAt)
        let messages = stored.orderedMessages
        #expect(messages.map(\.id) == snapshot.messages.map(\.id))
        #expect(messages.map(\.text) == snapshot.messages.map(\.text))
        #expect(messages.map(\.role) == snapshot.messages.map(\.role))
        #expect(messages[1].orderedSources.map(\.url) == ["https://example.org/page/0"])
        #expect(messages[1].orderedSources.first?.snippet == "Extrait 0")
        #expect(messages[1].answerNotes.uncitableSourceNumbers == [1])
        #expect(messages[1].answerNotes.answeredWithoutSearch)
        #expect(messages[3].reportsNoReliableSources)
    }

    @Test("Même identifiant ici : fusion, seuls les messages manquants s'ajoutent, à la suite")
    func mergesMissingMessages() throws {
        let store = try historyMakeStore()
        let first = HandoffFixtures.snapshot(pairs: 1)
        try store.importHandoff(first)

        var longer = first
        longer.messages.append(HandoffFixtures.message(2, text: "Nouvelle question"))
        longer.messages.append(HandoffFixtures.message(3, text: "Nouvelle réponse", sources: [HandoffFixtures.source(0)]))
        longer.updatedAt = HandoffFixtures.date(100)
        longer.title = "Autre titre côté autre appareil"

        let result = try store.importHandoff(longer)

        #expect(result.conversationID == id)
        #expect(result.disposition == .merged(added: 2))
        let stored = try #require(try store.conversation(with: id))
        #expect(stored.orderedMessages.map(\.text) == ["Question 0", "Réponse 1 [1]", "Nouvelle question", "Nouvelle réponse"])
        #expect(stored.orderedMessages.map(\.order) == [0, 1, 2, 3])
        #expect(stored.updatedAt == HandoffFixtures.date(100))
        // Le titre local n'est pas écrasé.
        #expect(stored.title == "Une conversation")
        #expect(try store.conversations().count == 1)
    }

    @Test("Recevoir deux fois la même discussion n'ajoute rien (idempotent)")
    func importingTwiceChangesNothing() throws {
        let store = try historyMakeStore()
        let snapshot = HandoffFixtures.snapshot(pairs: 2)
        try store.importHandoff(snapshot)
        let result = try store.importHandoff(snapshot)
        #expect(result.disposition == .merged(added: 0))
        #expect(try #require(try store.conversation(with: id)).messageList.count == 4)
        #expect(try store.conversations().count == 1)
    }

    @Test("Les deux appareils ont continué chacun de leur côté : les messages des deux sont gardés, sans perte")
    func divergedConversationsKeepBothSides() throws {
        let store = try historyMakeStore()
        let base = HandoffFixtures.snapshot(pairs: 1)
        try store.importHandoff(base)
        // Ici : une question de plus, posée localement.
        let local = try #require(try store.conversation(with: id))
        try store.appendUserMessage(to: local, text: "Question posée ici", now: HandoffFixtures.date(50))

        var remote = base
        remote.messages.append(HandoffFixtures.message(2, text: "Question posée ailleurs"))
        let result = try store.importHandoff(remote)

        #expect(result.disposition == .merged(added: 1))
        let texts = try #require(try store.conversation(with: id)).orderedMessages.map(\.text)
        #expect(texts == ["Question 0", "Réponse 1 [1]", "Question posée ici", "Question posée ailleurs"])
    }

    @Test("Une fenêtre tient déjà cette conversation : la discussion reçue devient une COPIE, l'originale n'est pas touchée")
    func heldConversationBecomesACopy() throws {
        let store = try historyMakeStore()
        let base = HandoffFixtures.snapshot(pairs: 1)
        try store.importHandoff(base)
        var longer = base
        longer.messages.append(HandoffFixtures.message(2, text: "Venue d'ailleurs"))

        let result = try store.importHandoff(longer, isHeldByAWindow: true)

        #expect(result.conversationID != id)
        #expect(result.disposition == .createdAsCopy)
        #expect(try #require(try store.conversation(with: id)).messageList.count == 2)
        let copy = try #require(try store.conversation(with: result.conversationID))
        #expect(copy.orderedMessages.map(\.text) == ["Question 0", "Réponse 1 [1]", "Venue d'ailleurs"])
        #expect(Set(copy.messageList.map(\.id)).isDisjoint(with: Set(try #require(try store.conversation(with: id)).messageList.map(\.id))))
        #expect(try store.conversations().count == 2)
    }

    @Test("Tenue par une fenêtre mais inconnue ici : créée normalement (rien à protéger)")
    func heldButUnknownIsCreated() throws {
        let store = try historyMakeStore()
        let result = try store.importHandoff(HandoffFixtures.snapshot(), isHeldByAWindow: true)
        #expect(result.conversationID == id)
        #expect(result.disposition == .created)
    }

    @Test("La discussion reçue réveille les vues : la révision de l'historique avance")
    func revisionAdvances() throws {
        let store = try historyMakeStore()
        let before = store.revision
        try store.importHandoff(HandoffFixtures.snapshot())
        #expect(store.revision > before)
    }

    @Test("Base indisponible : l'erreur remonte, rien n'est inventé")
    func unavailableStorageThrows() throws {
        struct Refusal: Error {}
        let storage = TrivaStorage(opener: { throw Refusal() }, retryDelaysMilliseconds: [], pause: { _ in })
        let store = ChatHistoryStore(storage: storage)
        #expect(throws: ChatHistoryStoreError.storageUnavailable) {
            try store.importHandoff(HandoffFixtures.snapshot())
        }
    }
}
