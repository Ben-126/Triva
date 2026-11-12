//
//  ChatHistoryStoreTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 24/09/2026.
//

import Testing
import Foundation
import SwiftData
@testable import Triva

// MARK: - Conteneur

@MainActor
@Suite("Historique — conteneur SwiftData")
struct TrivaModelContainerTests {
    /// Premier test de la suite, et le plus important : TOUS les autres supposent
    /// qu'un conteneur en mémoire est neuf et isolé. Si c'était faux, les tests
    /// de « base vide » et de comptage échoueraient en ayant l'air d'un bug de
    /// logique alors que ce serait une contamination. Les deux conteneurs
    /// partagent le même `configurationName` : c'est le cas à couvrir.
    @Test("Deux conteneurs en mémoire sont totalement isolés l'un de l'autre")
    func inMemoryContainersAreIsolated() throws {
        let premier = try historyMakeStore()
        let second = try historyMakeStore()

        try premier.createConversation(title: "Seulement dans le premier", now: historyDate(0))

        #expect(try premier.conversations().count == 1)
        #expect(try second.conversations().isEmpty)
    }

    @Test("Un conteneur en mémoire neuf démarre sur un historique vide")
    func freshContainerIsEmpty() throws {
        let store = try historyMakeStore()

        #expect(try store.conversations().isEmpty)
        #expect(try historyStoredConversationCount(in: store) == 0)
    }

    /// Le conteneur est partagé : l'historique (1.9) y déclare ses trois modèles, les favoris
    /// (1.10) y ajoutent les deux leurs. Ce test vérifie le schéma COMPLET, pas seulement la
    /// part de l'historique — un modèle oublié ferait planter l'app au premier accès.
    @Test("Le schéma déclare les modèles de l'historique et ceux des favoris")
    func schemaDeclaresHistoryAndFavoritesModels() {
        let noms = TrivaModelContainer.models.map { String(describing: $0) }

        #expect(noms.contains("StoredConversation"))
        #expect(noms.contains("StoredMessage"))
        #expect(noms.contains("StoredSource"))
        #expect(noms.contains("StoredFavorite"))
        #expect(noms.contains("StoredFavoriteSource"))
        #expect(noms.count == 5)
    }
}

// MARK: - Création et ajout de messages

@MainActor
@Suite("Historique — création et ajout")
struct ChatHistoryCreationTests {
    @Test("Une conversation créée est immédiatement listable, avec ses deux dates")
    func createConversation() throws {
        let store = try historyMakeStore()

        let conversation = try store.createConversation(title: "Photosynthèse", now: historyDate(0))

        #expect(conversation.title == "Photosynthèse")
        #expect(conversation.createdAt == historyDate(0))
        #expect(conversation.updatedAt == historyDate(0))
        #expect(conversation.messages.isEmpty)

        let listées = try store.conversations()
        #expect(listées.count == 1)
        #expect(listées.first?.id == conversation.id)
    }

    @Test("Le titre est dérivé de la première question quand on ne l'impose pas")
    func titleDerivedFromFirstQuestion() throws {
        let store = try historyMakeStore()

        let conversation = try store.createConversation(
            firstQuestion: "Comment fonctionne la photosynthèse ?",
            now: historyDate(0)
        )

        #expect(conversation.title == "Comment fonctionne la photosynthèse ?")
    }

    @Test("Les messages conservent leur ordre d'ajout après relecture")
    func messageOrderIsPreserved() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Suite", now: historyDate(0))

        try store.appendUserMessage(to: conversation, text: "Première question", now: historyDate(1))
        try store.appendAssistantMessage(to: conversation, text: "Première réponse", now: historyDate(2))
        try store.appendUserMessage(to: conversation, text: "Deuxième question", now: historyDate(3))
        try store.appendAssistantMessage(to: conversation, text: "Deuxième réponse", now: historyDate(4))

        // Relecture par le store, pas via la variable locale : c'est ce que fera
        // la Library en rouvrant une conversation.
        let relue = try #require(try store.conversations().first)

        #expect(relue.messages.count == 4)
        #expect(relue.orderedMessages.map(\.order) == [0, 1, 2, 3])
        #expect(relue.orderedMessages.map(\.text) == [
            "Première question",
            "Première réponse",
            "Deuxième question",
            "Deuxième réponse",
        ])
        #expect(relue.orderedMessages.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    @Test("Ajouter un message remonte updatedAt sans toucher createdAt")
    func appendingUpdatesTimestamp() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Horodatage", now: historyDate(0))

        try store.appendUserMessage(to: conversation, text: "Question", now: historyDate(42))

        #expect(conversation.createdAt == historyDate(0))
        #expect(conversation.updatedAt == historyDate(42))
    }

    @Test("Les sources d'une réponse sont persistées dans l'ordre de citation")
    func assistantSourcesArePersistedInOrder() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Sources", now: historyDate(0))

        let réponse = try store.appendAssistantMessage(
            to: conversation,
            text: "Réponse appuyée sur [1] et [2].",
            sources: historyMakeSources(3),
            now: historyDate(1)
        )

        #expect(réponse.sources.count == 3)
        #expect(réponse.orderedSources.map(\.order) == [0, 1, 2])
        #expect(réponse.orderedSources.map(\.title) == ["Source 1", "Source 2", "Source 3"])
        #expect(réponse.orderedSources.first?.url == "https://exemple1.fr/article")
        #expect(réponse.orderedSources.first?.snippet == "Extrait 1")
    }

    @Test("Une source sans extrait est acceptée telle quelle")
    func sourceWithoutSnippet() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Sans extrait", now: historyDate(0))

        let réponse = try store.appendAssistantMessage(
            to: conversation,
            text: "Réponse",
            sources: [historyMakeSource(7, content: nil)],
            now: historyDate(1)
        )

        #expect(réponse.orderedSources.first?.snippet == nil)
        #expect(réponse.orderedSources.first?.title == "Source 7")
    }

    @Test("Un message utilisateur n'a jamais de source attachée")
    func userMessageHasNoSource() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Question seule", now: historyDate(0))

        let question = try store.appendUserMessage(to: conversation, text: "Pourquoi ?", now: historyDate(1))

        #expect(question.sources.isEmpty)
        #expect(question.role == .user)
    }

    /// Fige le point 3 de la politique d'écriture : le store n'a PAS le droit de
    /// jeter silencieusement un message confié. C'est `ChatViewModel` qui doit
    /// s'abstenir d'appeler avec un texte vide — déplacer cette décision ici
    /// ferait échouer ce test, donc rouvrir la politique au lieu de la contourner.
    @Test("Un texte vide confié au store est écrit fidèlement, jamais ignoré")
    func blankAssistantTextIsWrittenFaithfully() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Réponse vide", now: historyDate(0))

        try store.appendAssistantMessage(to: conversation, text: "", now: historyDate(1))

        #expect(try historyStoredMessages(in: store).count == 1)
        #expect(try historyStoredMessages(in: store).first?.text == "")
    }

    @Test("Deux conversations ne partagent jamais leurs messages")
    func messagesStayInTheirConversation() throws {
        let store = try historyMakeStore()
        let première = try store.createConversation(title: "Première", now: historyDate(0))
        let seconde = try store.createConversation(title: "Seconde", now: historyDate(1))

        try store.appendUserMessage(to: première, text: "Chez la première", now: historyDate(2))
        try store.appendUserMessage(to: seconde, text: "Chez la seconde", now: historyDate(3))

        #expect(première.messages.map(\.text) == ["Chez la première"])
        #expect(seconde.messages.map(\.text) == ["Chez la seconde"])
        // Chaque conversation repart de 0 : `order` est local à la conversation.
        #expect(première.orderedMessages.first?.order == 0)
        #expect(seconde.orderedMessages.first?.order == 0)
    }
}

// MARK: - Persistance réelle (« fermer l'app, la rouvrir »)

@MainActor
@Suite("Historique — persistance réelle")
struct ChatHistoryPersistenceTests {
    /// Version en mémoire du test manuel du plan 1.9 : « fermer l'app, la
    /// rouvrir, retrouver une conversation précédente ». Un test unitaire ne
    /// relance pas le processus, mais un `ModelContext` neuf donne la garantie
    /// qui compte : les écritures ont été validées, pas laissées en attente.
    @Test("Un contexte neuf retrouve la conversation, ses messages ordonnés et ses sources")
    func freshContextSeesEverything() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(
            firstQuestion: "Comment naissent les marées ?",
            now: historyDate(0)
        )
        try store.appendUserMessage(to: conversation, text: "Comment naissent les marées ?", now: historyDate(1))
        try store.appendAssistantMessage(
            to: conversation,
            text: "La Lune attire les océans [1].",
            sources: historyMakeSources(2),
            now: historyDate(2)
        )
        let identifiant = conversation.id

        // Tout ce qui suit passe par un contexte qui n'a jamais vu ces objets.
        let contexte = historyFreshContext(store)
        let relues = try contexte.fetch(FetchDescriptor<StoredConversation>())
        let relue = try #require(relues.first { $0.id == identifiant })

        #expect(relue.title == "Comment naissent les marées ?")
        #expect(relue.createdAt == historyDate(0))
        #expect(relue.updatedAt == historyDate(2))
        #expect(relue.orderedMessages.map(\.role) == [.user, .assistant])
        #expect(relue.orderedMessages.map(\.order) == [0, 1])

        let réponse = try #require(relue.orderedMessages.last)
        #expect(réponse.text == "La Lune attire les océans [1].")
        #expect(réponse.orderedSources.map(\.order) == [0, 1])
        #expect(réponse.orderedSources.map(\.title) == ["Source 1", "Source 2"])
        // `[1]` renvoie à la source d'`order` 0 : c'est la convention que
        // `CitationParser` applique (`sources[index - 1]`).
        #expect(réponse.orderedSources.first?.url == "https://exemple1.fr/article")
    }

    /// Les deux modifications d'un objet DÉJÀ persisté (contrairement à une
    /// insertion) : elles n'ont de valeur que si elles atteignent réellement le
    /// store, ce que seul un contexte neuf peut montrer.
    @Test("Un renommage et une réécriture de texte atteignent le store")
    func modificationsReachTheStore() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Avant", now: historyDate(0))
        let réponse = try store.appendAssistantMessage(to: conversation, text: "Partielle", now: historyDate(1))
        let idConversation = conversation.id
        let idMessage = réponse.id

        try store.rename(conversation, to: "Après", now: historyDate(5))
        try store.updateText(of: réponse, to: "Complète", now: historyDate(9))

        let relues = try historyFreshContext(store).fetch(FetchDescriptor<StoredConversation>())
        #expect(relues.first { $0.id == idConversation }?.title == "Après")
        #expect(try historyStoredMessages(in: store).first { $0.id == idMessage }?.text == "Complète")
    }
}

// MARK: - Signal de changement

@MainActor
@Suite("Historique — signal de changement")
struct ChatHistoryRevisionTests {
    /// La Library et la Recherche coexistent à l'écran sur iPad `regular` et sur
    /// macOS : sans ce compteur, une liste récupérée une fois ne saurait jamais
    /// que le Chat vient d'ajouter un message.
    @Test("Chaque écriture réussie incrémente revision")
    func revisionIncrementsOnEveryWrite() throws {
        let store = try historyMakeStore()
        #expect(store.revision == 0)

        let conversation = try store.createConversation(title: "Compteur", now: historyDate(0))
        #expect(store.revision == 1)

        try store.appendUserMessage(to: conversation, text: "Question", now: historyDate(1))
        #expect(store.revision == 2)

        try store.appendAssistantMessage(to: conversation, text: "Réponse", now: historyDate(2))
        #expect(store.revision == 3)

        try store.rename(conversation, to: "Renommée", now: historyDate(3))
        #expect(store.revision == 4)

        try store.delete(conversation)
        #expect(store.revision == 5)
    }

    @Test("Une simple lecture ne change pas revision")
    func readingDoesNotBumpRevision() throws {
        let store = try historyMakeStore()
        try store.createConversation(title: "Lue", now: historyDate(0))
        let avant = store.revision

        _ = try store.conversations()
        _ = try store.conversations(matching: "lue")
        _ = try store.conversation(with: UUID())

        #expect(store.revision == avant)
    }
}

// MARK: - Mise à jour

@MainActor
@Suite("Historique — mise à jour")
struct ChatHistoryUpdateTests {
    @Test("Remplacer le texte d'un message met à jour la conversation")
    func updateMessageText() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Régénération", now: historyDate(0))
        let réponse = try store.appendAssistantMessage(
            to: conversation,
            text: "Réponse partielle",
            now: historyDate(1)
        )

        try store.updateText(of: réponse, to: "Réponse complète", now: historyDate(9))

        #expect(réponse.text == "Réponse complète")
        #expect(conversation.updatedAt == historyDate(9))
        // Le rang ne bouge pas : corriger un message ne le déplace pas dans la
        // conversation.
        #expect(réponse.order == 0)
    }

    @Test("Renommer une conversation retire les espaces superflus")
    func renameTrimsWhitespace() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Ancien titre", now: historyDate(0))

        try store.rename(conversation, to: "   Nouveau titre  ", now: historyDate(5))

        #expect(conversation.title == "Nouveau titre")
        #expect(conversation.updatedAt == historyDate(5))
    }

    @Test("Un titre vide est remplacé par le titre de repli, jamais accepté tel quel")
    func renameWithBlankTitleFallsBack() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "Ancien titre", now: historyDate(0))

        try store.rename(conversation, to: "   \n  ", now: historyDate(5))

        #expect(conversation.title == ConversationTitleBuilder.fallbackTitle)
    }
}
