//
//  ConversationQueryTests.swift
//  TrivaTests
//
//  Chantier 2.1 (mission A) : ce que Raccourcis, Siri et Spotlight voient de l'historique (titre et date), sur un
//  conteneur en mémoire. Les tests visent les fonctions statiques : le registre de dépendances de l'app, lui, ne
//  se contrôle pas depuis un test.
//

import Foundation
import Testing
@testable import Triva

@MainActor
@Suite("Entité conversation")
struct ConversationQueryTests {
    private func makeStore() throws -> ChatHistoryStore {
        ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))
    }

    @discardableResult
    private func add(_ title: String, at day: Int, to store: ChatHistoryStore) throws -> UUID {
        let date = Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
        return try store.createConversation(title: title, now: date).id
    }

    @Test("Par identifiants : les conversations connues, titre et date repris tels quels ; les inconnues sont absentes")
    func entitiesForIdentifiers() throws {
        let store = try makeStore()
        let ciel = try add("Le ciel", at: 10, to: store)
        _ = try add("Les mers", at: 11, to: store)

        let found = try ConversationQuery.entities(for: [ciel, UUID()], in: store)

        #expect(found.map(\.id) == [ciel])
        #expect(found.first?.title == "Le ciel")
        #expect(found.first?.updatedAt == Date(timeIntervalSince1970: 10 * 86_400))
    }

    @Test("Par texte : titre sans tenir compte des accents ni de la casse, la plus récente d'abord")
    func entitiesMatchingText() throws {
        let store = try makeStore()
        try add("Éléphants d'Afrique", at: 1, to: store)
        try add("Recette de crêpes", at: 2, to: store)
        let recent = try add("Les elephants de mer", at: 3, to: store)

        let found = try ConversationQuery.entities(matching: "ÉLÉPHANT", in: store)

        #expect(found.count == 2)
        #expect(found.first?.id == recent)
    }

    @Test("Par texte : 20 résultats au plus")
    func searchIsCapped() throws {
        let store = try makeStore()
        for day in 0..<(ConversationQuery.searchLimit + 7) { try add("Voyage \(day)", at: day, to: store) }

        let found = try ConversationQuery.entities(matching: "voyage", in: store)

        #expect(found.count == ConversationQuery.searchLimit)
    }

    @Test("Suggestions : les 10 plus récentes, dans l'ordre")
    func suggestionsAreTheTenMostRecent() throws {
        let store = try makeStore()
        for day in 0..<14 { try add("Sujet \(day)", at: day, to: store) }

        let found = try ConversationQuery.suggested(in: store)

        #expect(found.count == ConversationQuery.suggestionLimit)
        #expect(found.first?.title == "Sujet 13")
        #expect(found.last?.title == "Sujet 4")
    }

    @Test("Historique vide : aucune entité, aucune erreur")
    func emptyHistory() throws {
        let store = try makeStore()
        #expect(try ConversationQuery.suggested(in: store).isEmpty)
        #expect(try ConversationQuery.entities(matching: "x", in: store).isEmpty)
        #expect(try ConversationQuery.entities(for: [UUID()], in: store).isEmpty)
    }

    @Test("L'entité ne porte que l'identifiant, le titre et la date : jamais le texte des réponses")
    func entityCarriesNoAnswerText() throws {
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Titre seul")
        _ = try store.appendUserMessage(to: conversation, text: "Texte secret de la question")

        let entity = try #require(try ConversationQuery.suggested(in: store).first)

        #expect(!String(describing: entity).contains("secret"))
        #expect(entity.title == "Titre seul")
    }
}
