//
//  HandoffSnapshotSourceTests.swift
//  TrivaTests
//
//  Chantier 2.3 (mission H2) : ce que l'appareil d'origine accepte de servir quand l'autre appareil demande la discussion.
//  Il répond pour la conversation ANNONCÉE (celle de l'activité), et revérifie le réglage et l'existence au moment de servir.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Handoff conversation : ce que l'envoyeur sert")
struct HandoffSnapshotSourceTests {
    private func store(withAnswer: Bool = true) throws -> (ChatHistoryStore, UUID) {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Titre", now: historyDate(0))
        try store.appendUserMessage(to: conversation, text: "Question finie", now: historyDate(1))
        if withAnswer {
            try store.appendAssistantMessage(to: conversation, text: "Réponse finie", sources: [historyMakeSource(0, content: nil)], now: historyDate(2))
        }
        try store.appendUserMessage(to: conversation, text: "Question dont la réponse arrive", now: historyDate(3))
        return (store, conversation.id)
    }

    @Test("Ce qui est fini est servi ; la réponse encore en cours n'existe pas dans la base, donc n'est pas envoyée")
    func servesWhatIsFinished() throws {
        let (store, id) = try store()
        let data = try #require(HandoffSnapshotSource.data(for: id, isEnabled: true, store: store))
        let snapshot = try HandoffSnapshotCodec.decode(data, expectedConversationID: id)
        #expect(snapshot.messages.map(\.text) == ["Question finie", "Réponse finie", "Question dont la réponse arrive"])
        #expect(snapshot.messages[1].sources.map(\.title) == ["Source 0"])
        #expect(snapshot.messages[1].sources.map(\.snippet) == [nil])
    }

    @Test("Réglage éteint entre-temps : rien n'est servi")
    func disabledServesNothing() throws {
        let (store, id) = try store()
        #expect(HandoffSnapshotSource.data(for: id, isEnabled: false, store: store) == nil)
    }

    @Test("Conversation supprimée, identifiant absent ou inconnu : rien n'est servi")
    func missingServesNothing() throws {
        let (store, id) = try store()
        #expect(HandoffSnapshotSource.data(for: nil, isEnabled: true, store: store) == nil)
        #expect(HandoffSnapshotSource.data(for: UUID(), isEnabled: true, store: store) == nil)
        try store.delete(try #require(try store.conversation(with: id)))
        #expect(HandoffSnapshotSource.data(for: id, isEnabled: true, store: store) == nil)
    }

    @Test("Base indisponible : rien n'est servi, pas d'erreur")
    func unavailableStorageServesNothing() {
        struct Refusal: Error {}
        let storage = TrivaStorage(opener: { throw Refusal() }, retryDelaysMilliseconds: [], pause: { _ in })
        let store = ChatHistoryStore(storage: storage)
        #expect(HandoffSnapshotSource.data(for: UUID(), isEnabled: true, store: store) == nil)
    }

    @Test("Une conversation vide (aucun message) n'est pas servie")
    func emptyConversationServesNothing() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Vide", now: historyDate(0))
        #expect(HandoffSnapshotSource.data(for: conversation.id, isEnabled: true, store: store) == nil)
    }
}
