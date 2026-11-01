//
//  FavoritesStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 30/09/2026.
//

import Testing
import Foundation
import SwiftData
@testable import Triva

// MARK: - Fabriques et outils

// Toutes les suites sont `@MainActor`, comme `FavoritesStore` et
// `ChatHistoryStore` qui travaillent sur le `mainContext`. Aucune ne mesure de
// temps réel écoulé, donc aucune ne relève de l'exception documentée dans
// `WidgetExecutorTests`.

/// Les deux stores de l'app, adossés au MÊME conteneur en mémoire neuf — comme
/// dans l'app, où ils partagent `TrivaModelContainer.shared`. Indispensable pour
/// tester ce qui arrive à un favori quand l'historique supprime sa
/// conversation. Jamais `TrivaModelContainer.shared` : aucun test ne touche le
/// fichier réel de l'utilisateur.
@MainActor
private struct Stores {
    let history: ChatHistoryStore
    let favorites: FavoritesStore

    init() throws {
        let container = try TrivaModelContainer.makeInMemory()
        let locale = Locale(identifier: "fr_FR")
        history = ChatHistoryStore(container: container, locale: locale)
        favorites = FavoritesStore(container: container, locale: locale)
    }

    /// Contexte **neuf** : il ne voit que ce qui a réellement atteint le store.
    /// Vérifier depuis le `mainContext` passerait même sans aucun `save()`,
    /// puisque les stores désactivent l'autosave.
    func freshContext() -> ModelContext {
        ModelContext(favorites.container)
    }

    func storedFavorites() throws -> [StoredFavorite] {
        try freshContext().fetch(FetchDescriptor<StoredFavorite>())
    }

    func storedFavoriteSourceCount() throws -> Int {
        try freshContext().fetchCount(FetchDescriptor<StoredFavoriteSource>())
    }

    /// Conversation à deux tours, pour vérifier que la question retrouvée est
    /// bien celle qui PRÉCÈDE la réponse marquée, et non la première.
    func makeTwoTurnConversation() throws -> (StoredConversation, first: StoredMessage, second: StoredMessage) {
        let conversation = try history.createConversation(title: "Marées", now: date(0))
        try history.appendUserMessage(to: conversation, text: "Qu'est-ce qu'une marée ?", now: date(1))
        let first = try history.appendAssistantMessage(
            to: conversation, text: "Une variation du niveau de la mer [1].",
            sources: makeSources(1), now: date(2)
        )
        try history.appendUserMessage(to: conversation, text: "Et les grandes marées ?", now: date(3))
        let second = try history.appendAssistantMessage(
            to: conversation, text: "Elles surviennent aux syzygies [1][2].",
            sources: makeSources(2), now: date(4)
        )
        return (conversation, first, second)
    }
}

/// Date déterministe : aucun test ne dort ni ne dépend de l'horloge.
private func date(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
}

private func makeSource(_ index: Int, content: String?) -> SearXNGSearchResult {
    SearXNGSearchResult(
        title: "Source \(index)",
        url: "https://exemple\(index).fr/article",
        content: content,
        imgSrc: nil,
        thumbnailSrc: nil,
        thumbnail: nil,
        author: nil,
        iframeSrc: nil
    )
}

private func makeSources(_ count: Int) -> [SearXNGSearchResult] {
    (1...count).map { makeSource($0, content: "Extrait \($0)") }
}

/// Marquage direct, sans passer par l'historique : suffisant pour les tests de
/// liste, de tri et de recherche, qui ne portent pas sur la conversation.
@MainActor
@discardableResult
private func markDirect(
    _ store: FavoritesStore,
    question: String,
    answer: String = "Réponse",
    sources: [SearXNGSearchResult] = [],
    at offset: TimeInterval
) throws -> StoredFavorite {
    try store.mark(
        messageID: UUID(),
        conversationID: nil,
        question: question,
        answer: answer,
        sources: sources,
        now: date(offset)
    )
}

// MARK: - Schéma

@MainActor
@Suite("Favoris — schéma")
struct FavoritesSchemaTests {
    @Test("Le schéma unique contient les modèles des favoris ET ceux de l'historique")
    func schemaListsEveryModel() {
        let noms = TrivaModelContainer.models.map { String(describing: $0) }

        #expect(noms.contains("StoredFavorite"))
        #expect(noms.contains("StoredFavoriteSource"))
        // L'extension ne doit rien avoir retiré de 1.9.
        #expect(noms.contains("StoredConversation"))
        #expect(noms.contains("StoredMessage"))
        #expect(noms.contains("StoredSource"))
        #expect(noms.count == 5)
    }

    @Test("Un conteneur neuf ne contient aucun favori")
    func freshContainerIsEmpty() throws {
        let stores = try Stores()

        #expect(try stores.favorites.favorites().isEmpty)
        #expect(try stores.favorites.favoritedMessageIDs().isEmpty)
        #expect(try stores.storedFavorites().isEmpty)
    }
}

// MARK: - Marquage

@MainActor
@Suite("Favoris — marquage")
struct FavoritesMarkingTests {
    @Test("Marquer une réponse recopie SA question, sa réponse, ses sources et la date")
    func markCopiesEverything() throws {
        let stores = try Stores()
        let (conversation, _, second) = try stores.makeTwoTurnConversation()

        let favorite = try stores.favorites.mark(second, now: date(100))

        #expect(favorite.messageID == second.id)
        #expect(favorite.conversationID == conversation.id)
        // La question du 2e tour, pas la première de la conversation.
        #expect(favorite.question == "Et les grandes marées ?")
        #expect(favorite.answer == "Elles surviennent aux syzygies [1][2].")
        #expect(favorite.savedAt == date(100))
        #expect(favorite.orderedSources.map(\.title) == ["Source 1", "Source 2"])
        #expect(favorite.orderedSources.map(\.order) == [0, 1])
        #expect(favorite.orderedSources.first?.snippet == "Extrait 1")
    }

    @Test("Marquage direct : les sources gardent l'ordre de citation, extrait absent accepté")
    func markDirectKeepsCitationOrder() throws {
        let stores = try Stores()
        let sources = [makeSource(3, content: nil), makeSource(1, content: "Un"), makeSource(2, content: "Deux")]

        let favorite = try markDirect(stores.favorites, question: "Q", sources: sources, at: 0)

        #expect(favorite.orderedSources.map(\.title) == ["Source 3", "Source 1", "Source 2"])
        #expect(favorite.orderedSources.first?.snippet == nil)
        #expect(favorite.orderedSources.first?.url == "https://exemple3.fr/article")
    }

    @Test("Marquer un message utilisateur est refusé et n'écrit rien")
    func markingUserMessageThrows() throws {
        let stores = try Stores()
        let conversation = try stores.history.createConversation(title: "T", now: date(0))
        let question = try stores.history.appendUserMessage(to: conversation, text: "Question", now: date(1))
        let revisionBefore = stores.favorites.revision

        #expect(throws: FavoritesStoreError.notAnAssistantMessage) {
            try stores.favorites.mark(question)
        }
        #expect(try stores.storedFavorites().isEmpty)
        #expect(stores.favorites.revision == revisionBefore)
    }

    @Test("Une réponse sans question qui la précède donne une question vide, pas une erreur")
    func answerWithoutQuestionYieldsEmptyQuestion() throws {
        let stores = try Stores()
        let conversation = try stores.history.createConversation(title: "T", now: date(0))
        let answer = try stores.history.appendAssistantMessage(to: conversation, text: "Seule", now: date(1))

        let favorite = try stores.favorites.mark(answer, now: date(2))

        #expect(favorite.question.isEmpty)
        #expect(favorite.answer == "Seule")
    }

    @Test("Marquer deux fois ne crée aucun doublon et ne réécrit ni la date ni revision")
    func markingTwiceIsIdempotent() throws {
        let stores = try Stores()
        let (_, _, second) = try stores.makeTwoTurnConversation()

        let first = try stores.favorites.mark(second, now: date(100))
        let revisionAfterFirst = stores.favorites.revision
        let again = try stores.favorites.mark(second, now: date(200))
        let direct = try stores.favorites.mark(
            messageID: second.id, conversationID: nil, question: "Autre", answer: "Autre", now: date(300)
        )

        #expect(again.id == first.id)
        #expect(direct.id == first.id)
        #expect(again.savedAt == date(100))
        #expect(stores.favorites.revision == revisionAfterFirst)
        #expect(try stores.storedFavorites().count == 1)
        #expect(try stores.storedFavoriteSourceCount() == 2)
    }

    @Test("Retirer supprime le favori et ses sources du store")
    func unmarkRemovesFavoriteAndSources() throws {
        let stores = try Stores()
        let (_, _, second) = try stores.makeTwoTurnConversation()
        try stores.favorites.mark(second, now: date(100))

        let removed = try stores.favorites.unmark(messageID: second.id)

        #expect(removed)
        #expect(try stores.favorites.isFavorite(messageID: second.id) == false)
        #expect(try stores.storedFavorites().isEmpty)
        #expect(try stores.storedFavoriteSourceCount() == 0)
    }

    @Test("Retirer un message absent des favoris renvoie false sans rien écrire")
    func unmarkUnknownIsNoOp() throws {
        let stores = try Stores()
        try markDirect(stores.favorites, question: "Gardé", at: 0)
        let revisionBefore = stores.favorites.revision

        #expect(try stores.favorites.unmark(messageID: UUID()) == false)
        #expect(stores.favorites.revision == revisionBefore)
        #expect(try stores.storedFavorites().count == 1)
    }

    @Test("Marquer, retirer puis re-marquer donne un seul favori, daté du nouveau marquage")
    func remarkAfterUnmark() throws {
        let stores = try Stores()
        let (_, _, second) = try stores.makeTwoTurnConversation()

        try stores.favorites.mark(second, now: date(100))
        try stores.favorites.unmark(messageID: second.id)
        let remarked = try stores.favorites.mark(second, now: date(500))

        #expect(remarked.savedAt == date(500))
        #expect(try stores.storedFavorites().count == 1)
        #expect(try stores.storedFavoriteSourceCount() == 2)
        #expect(try stores.favorites.isFavorite(messageID: second.id))
    }

    @Test("toggle renvoie le nouvel état à chaque bascule")
    func toggleReturnsNewState() throws {
        let stores = try Stores()
        let (_, first, _) = try stores.makeTwoTurnConversation()

        #expect(try stores.favorites.toggle(first, now: date(10)) == true)
        #expect(try stores.favorites.isFavorite(messageID: first.id))
        #expect(try stores.favorites.toggle(first, now: date(20)) == false)
        #expect(try stores.favorites.isFavorite(messageID: first.id) == false)
        #expect(try stores.favorites.toggle(first, now: date(30)) == true)
        #expect(try stores.storedFavorites().count == 1)
    }

    @Test("Retirer un favori chargé depuis la liste l'efface du store")
    func removeLoadedFavorite() throws {
        let stores = try Stores()
        try markDirect(stores.favorites, question: "À retirer", sources: makeSources(2), at: 0)
        try markDirect(stores.favorites, question: "À garder", at: 1)

        let target = try #require(try stores.favorites.favorites(matching: "retirer").first)
        try stores.favorites.remove(target)

        #expect(try stores.storedFavorites().map(\.question) == ["À garder"])
        #expect(try stores.storedFavoriteSourceCount() == 0)
    }
}

// MARK: - Recherche rapide

@MainActor
@Suite("Favoris — recherche rapide par message")
struct FavoritesLookupTests {
    @Test("isFavorite distingue un message marqué d'un message qui ne l'est pas")
    func isFavoriteLookup() throws {
        let stores = try Stores()
        let (_, first, second) = try stores.makeTwoTurnConversation()

        try stores.favorites.mark(second, now: date(10))

        #expect(try stores.favorites.isFavorite(messageID: second.id))
        #expect(try stores.favorites.isFavorite(messageID: first.id) == false)
        #expect(try stores.favorites.isFavorite(messageID: UUID()) == false)
    }

    @Test("favoritedMessageIDs renvoie exactement les messages marqués")
    func favoritedIDsSet() throws {
        let stores = try Stores()
        let (_, first, second) = try stores.makeTwoTurnConversation()

        try stores.favorites.mark(first, now: date(10))
        try stores.favorites.mark(second, now: date(11))
        try stores.favorites.unmark(messageID: first.id)

        #expect(try stores.favorites.favoritedMessageIDs() == [second.id])
    }

    @Test("favorite(forMessageID:) retrouve le favori, ou nil pour un inconnu")
    func favoriteForMessageID() throws {
        let stores = try Stores()
        let (_, _, second) = try stores.makeTwoTurnConversation()
        let marked = try stores.favorites.mark(second, now: date(10))

        #expect(try stores.favorites.favorite(forMessageID: second.id)?.id == marked.id)
        #expect(try stores.favorites.favorite(forMessageID: UUID()) == nil)
    }

    @Test("Les lectures ne changent pas revision, chaque écriture réussie l'incrémente")
    func revisionTracksWritesOnly() throws {
        let stores = try Stores()
        let (_, first, _) = try stores.makeTwoTurnConversation()
        let start = stores.favorites.revision

        try stores.favorites.mark(first, now: date(10))
        #expect(stores.favorites.revision == start + 1)

        _ = try stores.favorites.isFavorite(messageID: first.id)
        _ = try stores.favorites.favorites()
        _ = try stores.favorites.favorites(matching: "marée")
        _ = try stores.favorites.favoritedMessageIDs()
        #expect(stores.favorites.revision == start + 1)

        try stores.favorites.unmark(messageID: first.id)
        #expect(stores.favorites.revision == start + 2)
    }
}

// MARK: - Persistance et survie à la conversation

@MainActor
@Suite("Favoris — persistance et indépendance vis-à-vis de l'historique")
struct FavoritesPersistenceTests {
    @Test("Un store recréé sur le même conteneur retrouve les favoris et leurs sources")
    func persistsAcrossStoreRecreation() throws {
        let stores = try Stores()
        let (_, _, second) = try stores.makeTwoTurnConversation()
        try stores.favorites.mark(second, now: date(100))

        let recreated = FavoritesStore(container: stores.favorites.container, locale: Locale(identifier: "fr_FR"))

        #expect(try recreated.isFavorite(messageID: second.id))
        let reloaded = try #require(try recreated.favorites().first)
        #expect(reloaded.question == "Et les grandes marées ?")
        #expect(reloaded.orderedSources.map(\.title) == ["Source 1", "Source 2"])

        // Et depuis un contexte neuf : la donnée a bien atteint le store.
        let stored = try #require(try stores.storedFavorites().first)
        #expect(stored.messageID == second.id)
        #expect(stored.orderedSources.count == 2)
    }

    @Test("Supprimer la conversation d'origine laisse le favori intact, sources comprises")
    func favoriteSurvivesConversationDeletion() throws {
        let stores = try Stores()
        let (conversation, _, second) = try stores.makeTwoTurnConversation()
        let conversationID = conversation.id
        let messageID = second.id
        try stores.favorites.mark(second, now: date(100))

        try stores.history.delete(conversation)
        // À partir d'ici, `conversation` et `second` ne sont plus lus : on ne
        // raisonne que sur les identifiants capturés avant la suppression (piège
        // `isDeleted` documenté dans ChatHistoryStore).

        // L'historique n'a plus la conversation ni ses sources…
        #expect(try stores.history.conversation(with: conversationID) == nil)
        #expect(try stores.freshContext().fetchCount(FetchDescriptor<StoredSource>()) == 0)

        // …mais le favori est entier, vu depuis un contexte neuf.
        let stored = try #require(try stores.storedFavorites().first)
        #expect(stored.messageID == messageID)
        #expect(stored.conversationID == conversationID)
        #expect(stored.question == "Et les grandes marées ?")
        #expect(stored.answer == "Elles surviennent aux syzygies [1][2].")
        #expect(stored.orderedSources.map(\.title) == ["Source 1", "Source 2"])
        #expect(try stores.favorites.isFavorite(messageID: messageID))
    }

    @Test("Effacer tout l'historique n'efface aucun favori")
    func historyDeleteAllKeepsFavorites() throws {
        let stores = try Stores()
        let (_, first, second) = try stores.makeTwoTurnConversation()
        try stores.favorites.mark(first, now: date(10))
        try stores.favorites.mark(second, now: date(11))

        try stores.history.deleteAll()

        #expect(try stores.history.conversations().isEmpty)
        #expect(try stores.storedFavorites().count == 2)
        #expect(try stores.storedFavoriteSourceCount() == 3)
    }

    @Test("Réécrire la réponse d'origine ne modifie pas le favori (copie figée)")
    func favoriteIsASnapshot() throws {
        let stores = try Stores()
        let (_, _, second) = try stores.makeTwoTurnConversation()
        try stores.favorites.mark(second, now: date(100))

        try stores.history.updateText(of: second, to: "Réponse régénérée", now: date(200))

        let stored = try #require(try stores.storedFavorites().first)
        #expect(stored.answer == "Elles surviennent aux syzygies [1][2].")
    }

    @Test("Effacer les favoris ne touche pas l'historique et ne laisse aucune source")
    func favoritesDeleteAllKeepsHistory() throws {
        let stores = try Stores()
        let (_, first, second) = try stores.makeTwoTurnConversation()
        try stores.favorites.mark(first, now: date(10))
        try stores.favorites.mark(second, now: date(11))

        try stores.favorites.deleteAll()

        #expect(try stores.storedFavorites().isEmpty)
        #expect(try stores.storedFavoriteSourceCount() == 0)
        #expect(try stores.history.conversations().count == 1)
        #expect(try stores.freshContext().fetchCount(FetchDescriptor<StoredMessage>()) == 4)
    }

    @Test("Effacer des favoris déjà vides ne lève aucune erreur")
    func deleteAllOnEmptyIsSafe() throws {
        let stores = try Stores()

        try stores.favorites.deleteAll()

        #expect(try stores.favorites.favorites().isEmpty)
    }
}

// MARK: - Liste et tri

@MainActor
@Suite("Favoris — liste et tri")
struct FavoritesListingTests {
    @Test("Les favoris sont listés du plus récemment marqué au plus ancien")
    func sortedByMostRecentFirst() throws {
        let stores = try Stores()
        try markDirect(stores.favorites, question: "Ancien", at: 0)
        try markDirect(stores.favorites, question: "Récent", at: 20)
        try markDirect(stores.favorites, question: "Milieu", at: 10)

        #expect(try stores.favorites.favorites().map(\.question) == ["Récent", "Milieu", "Ancien"])
    }

    @Test("À date identique, l'ordre est déterministe (départage par question)")
    func tiesAreDeterministic() throws {
        let stores = try Stores()
        try markDirect(stores.favorites, question: "Bêta", at: 5)
        try markDirect(stores.favorites, question: "Alpha", at: 5)
        try markDirect(stores.favorites, question: "Gamma", at: 5)

        let first = try stores.favorites.favorites().map(\.question)
        let second = try stores.favorites.favorites().map(\.question)

        #expect(first == ["Alpha", "Bêta", "Gamma"])
        #expect(first == second)
    }

    @Test("Une limite borne la liste ; nulle ou négative, elle renvoie une liste vide")
    func limitBehaviour() throws {
        let stores = try Stores()
        for index in 0..<5 {
            try markDirect(stores.favorites, question: "Q\(index)", at: TimeInterval(index))
        }

        #expect(try stores.favorites.favorites(limit: 2).map(\.question) == ["Q4", "Q3"])
        #expect(try stores.favorites.favorites(limit: 0).isEmpty)
        #expect(try stores.favorites.favorites(limit: -3).isEmpty)
        #expect(try stores.favorites.favorites().count == 5)
    }

    @Test("Au-delà de 100 favoris, aucun n'est supprimé (pas de plafond comme sur le web)")
    func noSilentCap() throws {
        let stores = try Stores()
        for index in 0..<101 {
            try markDirect(stores.favorites, question: "Q\(index)", at: TimeInterval(index))
        }

        #expect(try stores.storedFavorites().count == 101)
        #expect(try stores.favorites.favorites().last?.question == "Q0")
    }
}

// MARK: - Recherche

@MainActor
@Suite("Favoris — recherche")
struct FavoritesSearchTests {
    private func makePopulatedStores() throws -> Stores {
        let stores = try Stores()
        try markDirect(stores.favorites, question: "Pourquoi les marées ?", answer: "La Lune attire l'eau.", at: 0)
        try markDirect(
            stores.favorites, question: "Scrutin", answer: "Les élections européennes ont lieu en juin.", at: 10
        )
        try markDirect(
            stores.favorites, question: "Recette", answer: "Gratin dauphinois.",
            sources: [makeSource(7, content: nil)], at: 20
        )
        return stores
    }

    @Test("La recherche trouve un mot de la question, de la réponse ou d'un titre de source")
    func searchesAllFields() throws {
        let stores = try makePopulatedStores()

        #expect(try stores.favorites.favorites(matching: "marées").map(\.question) == ["Pourquoi les marées ?"])
        #expect(try stores.favorites.favorites(matching: "européennes").map(\.question) == ["Scrutin"])
        #expect(try stores.favorites.favorites(matching: "Source 7").map(\.question) == ["Recette"])
    }

    @Test("La recherche ignore la casse et les accents, dans les deux sens")
    func searchIgnoresCaseAndDiacritics() throws {
        let stores = try makePopulatedStores()

        #expect(try stores.favorites.favorites(matching: "MAREES").count == 1)
        #expect(try stores.favorites.favorites(matching: "elections").count == 1)
        #expect(try stores.favorites.favorites(matching: "Élections").count == 1)
    }

    @Test("Une requête vide ou blanche renvoie tous les favoris, triés")
    func emptyQueryReturnsAll() throws {
        let stores = try makePopulatedStores()

        #expect(try stores.favorites.favorites(matching: "").map(\.question) == ["Recette", "Scrutin", "Pourquoi les marées ?"])
        #expect(try stores.favorites.favorites(matching: "  \n ").count == 3)
    }

    @Test("Une requête sans correspondance renvoie une liste vide")
    func noMatch() throws {
        let stores = try makePopulatedStores()

        #expect(try stores.favorites.favorites(matching: "astrophysique").isEmpty)
    }

    @Test("La limite de recherche s'applique après le filtrage")
    func limitAfterFiltering() throws {
        let stores = try Stores()
        try markDirect(stores.favorites, question: "Pomme de terre", at: 0)
        try markDirect(stores.favorites, question: "Compote de pommes", at: 1)
        try markDirect(stores.favorites, question: "Bricolage", at: 10)
        try markDirect(stores.favorites, question: "Musique", at: 11)

        #expect(try stores.favorites.favorites(matching: "pomme").count == 2)
        #expect(try stores.favorites.favorites(matching: "pomme", limit: 1).map(\.question) == ["Compote de pommes"])
    }

    @Test("Chercher dans des favoris vides ne lève pas et ne renvoie rien")
    func searchOnEmpty() throws {
        let stores = try Stores()

        #expect(try stores.favorites.favorites(matching: "peu importe").isEmpty)
    }
}
