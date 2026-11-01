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

// MARK: - Fabriques et outils

// Toutes les suites sont `@MainActor`, comme `ChatHistoryStore` et
// `TrivaModelContainer` qui travaillent sur le `mainContext` (isolation
// expliquée en tête de `ChatHistoryModels.swift`). Aucune ne mesure de temps
// réel écoulé, donc aucune n'a besoin de rester non isolée comme
// `WidgetExecutorTests`.

/// Store de test, adossé à un conteneur **en mémoire** neuf. Jamais
/// `TrivaModelContainer.shared` : un test ne doit ni lire ni toucher le fichier
/// réel de l'utilisateur. Locale imposée plutôt que `.current`, pour que le
/// repliement de casse et d'accents ne dépende pas de la machine de test.
@MainActor
private func makeStore() throws -> ChatHistoryStore {
    let container = try TrivaModelContainer.makeInMemory()
    return ChatHistoryStore(container: container, locale: Locale(identifier: "fr_FR"))
}

/// Date déterministe : les tests d'ordre chronologique doivent pouvoir
/// fabriquer un ordre exact sans jamais dormir ni dépendre de l'horloge.
private func date(_ offset: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + offset)
}

/// Source reconnaissable à son index. `content` est explicite et sans valeur par
/// défaut : un extrait réellement absent (`nil`) doit être exprimable.
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

/// Contexte **neuf** sur le même conteneur : l'outil central de ce fichier.
///
/// Le store désactive `autosaveEnabled` et relit tout par le `mainContext` : un
/// test qui vérifie une écriture depuis ce même contexte passerait même si
/// `save()` n'était jamais appelé. Un contexte neuf ne voit que ce qui a
/// réellement atteint le store — seule façon de prouver qu'une écriture a été
/// validée et qu'une cascade a bien effacé les enfants.
@MainActor
private func freshContext(_ store: ChatHistoryStore) -> ModelContext {
    ModelContext(store.container)
}

@MainActor
private func storedConversationCount(in store: ChatHistoryStore) throws -> Int {
    try freshContext(store).fetchCount(FetchDescriptor<StoredConversation>())
}

@MainActor
private func storedMessages(in store: ChatHistoryStore) throws -> [StoredMessage] {
    try freshContext(store).fetch(FetchDescriptor<StoredMessage>())
}

@MainActor
private func storedSources(in store: ChatHistoryStore) throws -> [StoredSource] {
    try freshContext(store).fetch(FetchDescriptor<StoredSource>())
}

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
        let premier = try makeStore()
        let second = try makeStore()

        try premier.createConversation(title: "Seulement dans le premier", now: date(0))

        #expect(try premier.conversations().count == 1)
        #expect(try second.conversations().isEmpty)
    }

    @Test("Un conteneur en mémoire neuf démarre sur un historique vide")
    func freshContainerIsEmpty() throws {
        let store = try makeStore()

        #expect(try store.conversations().isEmpty)
        #expect(try storedConversationCount(in: store) == 0)
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
        let store = try makeStore()

        let conversation = try store.createConversation(title: "Photosynthèse", now: date(0))

        #expect(conversation.title == "Photosynthèse")
        #expect(conversation.createdAt == date(0))
        #expect(conversation.updatedAt == date(0))
        #expect(conversation.messages.isEmpty)

        let listées = try store.conversations()
        #expect(listées.count == 1)
        #expect(listées.first?.id == conversation.id)
    }

    @Test("Le titre est dérivé de la première question quand on ne l'impose pas")
    func titleDerivedFromFirstQuestion() throws {
        let store = try makeStore()

        let conversation = try store.createConversation(
            firstQuestion: "Comment fonctionne la photosynthèse ?",
            now: date(0)
        )

        #expect(conversation.title == "Comment fonctionne la photosynthèse ?")
    }

    @Test("Les messages conservent leur ordre d'ajout après relecture")
    func messageOrderIsPreserved() throws {
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Suite", now: date(0))

        try store.appendUserMessage(to: conversation, text: "Première question", now: date(1))
        try store.appendAssistantMessage(to: conversation, text: "Première réponse", now: date(2))
        try store.appendUserMessage(to: conversation, text: "Deuxième question", now: date(3))
        try store.appendAssistantMessage(to: conversation, text: "Deuxième réponse", now: date(4))

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
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Horodatage", now: date(0))

        try store.appendUserMessage(to: conversation, text: "Question", now: date(42))

        #expect(conversation.createdAt == date(0))
        #expect(conversation.updatedAt == date(42))
    }

    @Test("Les sources d'une réponse sont persistées dans l'ordre de citation")
    func assistantSourcesArePersistedInOrder() throws {
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Sources", now: date(0))

        let réponse = try store.appendAssistantMessage(
            to: conversation,
            text: "Réponse appuyée sur [1] et [2].",
            sources: makeSources(3),
            now: date(1)
        )

        #expect(réponse.sources.count == 3)
        #expect(réponse.orderedSources.map(\.order) == [0, 1, 2])
        #expect(réponse.orderedSources.map(\.title) == ["Source 1", "Source 2", "Source 3"])
        #expect(réponse.orderedSources.first?.url == "https://exemple1.fr/article")
        #expect(réponse.orderedSources.first?.snippet == "Extrait 1")
    }

    @Test("Une source sans extrait est acceptée telle quelle")
    func sourceWithoutSnippet() throws {
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Sans extrait", now: date(0))

        let réponse = try store.appendAssistantMessage(
            to: conversation,
            text: "Réponse",
            sources: [makeSource(7, content: nil)],
            now: date(1)
        )

        #expect(réponse.orderedSources.first?.snippet == nil)
        #expect(réponse.orderedSources.first?.title == "Source 7")
    }

    @Test("Un message utilisateur n'a jamais de source attachée")
    func userMessageHasNoSource() throws {
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Question seule", now: date(0))

        let question = try store.appendUserMessage(to: conversation, text: "Pourquoi ?", now: date(1))

        #expect(question.sources.isEmpty)
        #expect(question.role == .user)
    }

    /// Fige le point 3 de la politique d'écriture : le store n'a PAS le droit de
    /// jeter silencieusement un message confié. C'est `ChatViewModel` qui doit
    /// s'abstenir d'appeler avec un texte vide — déplacer cette décision ici
    /// ferait échouer ce test, donc rouvrir la politique au lieu de la contourner.
    @Test("Un texte vide confié au store est écrit fidèlement, jamais ignoré")
    func blankAssistantTextIsWrittenFaithfully() throws {
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Réponse vide", now: date(0))

        try store.appendAssistantMessage(to: conversation, text: "", now: date(1))

        #expect(try storedMessages(in: store).count == 1)
        #expect(try storedMessages(in: store).first?.text == "")
    }

    @Test("Deux conversations ne partagent jamais leurs messages")
    func messagesStayInTheirConversation() throws {
        let store = try makeStore()
        let première = try store.createConversation(title: "Première", now: date(0))
        let seconde = try store.createConversation(title: "Seconde", now: date(1))

        try store.appendUserMessage(to: première, text: "Chez la première", now: date(2))
        try store.appendUserMessage(to: seconde, text: "Chez la seconde", now: date(3))

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
        let store = try makeStore()
        let conversation = try store.createConversation(
            firstQuestion: "Comment naissent les marées ?",
            now: date(0)
        )
        try store.appendUserMessage(to: conversation, text: "Comment naissent les marées ?", now: date(1))
        try store.appendAssistantMessage(
            to: conversation,
            text: "La Lune attire les océans [1].",
            sources: makeSources(2),
            now: date(2)
        )
        let identifiant = conversation.id

        // Tout ce qui suit passe par un contexte qui n'a jamais vu ces objets.
        let contexte = freshContext(store)
        let relues = try contexte.fetch(FetchDescriptor<StoredConversation>())
        let relue = try #require(relues.first { $0.id == identifiant })

        #expect(relue.title == "Comment naissent les marées ?")
        #expect(relue.createdAt == date(0))
        #expect(relue.updatedAt == date(2))
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
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Avant", now: date(0))
        let réponse = try store.appendAssistantMessage(to: conversation, text: "Partielle", now: date(1))
        let idConversation = conversation.id
        let idMessage = réponse.id

        try store.rename(conversation, to: "Après", now: date(5))
        try store.updateText(of: réponse, to: "Complète", now: date(9))

        let relues = try freshContext(store).fetch(FetchDescriptor<StoredConversation>())
        #expect(relues.first { $0.id == idConversation }?.title == "Après")
        #expect(try storedMessages(in: store).first { $0.id == idMessage }?.text == "Complète")
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
        let store = try makeStore()
        #expect(store.revision == 0)

        let conversation = try store.createConversation(title: "Compteur", now: date(0))
        #expect(store.revision == 1)

        try store.appendUserMessage(to: conversation, text: "Question", now: date(1))
        #expect(store.revision == 2)

        try store.appendAssistantMessage(to: conversation, text: "Réponse", now: date(2))
        #expect(store.revision == 3)

        try store.rename(conversation, to: "Renommée", now: date(3))
        #expect(store.revision == 4)

        try store.delete(conversation)
        #expect(store.revision == 5)
    }

    @Test("Une simple lecture ne change pas revision")
    func readingDoesNotBumpRevision() throws {
        let store = try makeStore()
        try store.createConversation(title: "Lue", now: date(0))
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
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Régénération", now: date(0))
        let réponse = try store.appendAssistantMessage(
            to: conversation,
            text: "Réponse partielle",
            now: date(1)
        )

        try store.updateText(of: réponse, to: "Réponse complète", now: date(9))

        #expect(réponse.text == "Réponse complète")
        #expect(conversation.updatedAt == date(9))
        // Le rang ne bouge pas : corriger un message ne le déplace pas dans la
        // conversation.
        #expect(réponse.order == 0)
    }

    @Test("Renommer une conversation retire les espaces superflus")
    func renameTrimsWhitespace() throws {
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Ancien titre", now: date(0))

        try store.rename(conversation, to: "   Nouveau titre  ", now: date(5))

        #expect(conversation.title == "Nouveau titre")
        #expect(conversation.updatedAt == date(5))
    }

    @Test("Un titre vide est remplacé par le titre de repli, jamais accepté tel quel")
    func renameWithBlankTitleFallsBack() throws {
        let store = try makeStore()
        let conversation = try store.createConversation(title: "Ancien titre", now: date(0))

        try store.rename(conversation, to: "   \n  ", now: date(5))

        #expect(conversation.title == ConversationTitleBuilder.fallbackTitle)
    }
}

// MARK: - Suppression

@MainActor
@Suite("Historique — suppression")
struct ChatHistoryDeletionTests {
    /// Vérifié depuis un contexte NEUF, pas via le graphe d'objets de la
    /// conversation supprimée : `conversation.messages.isEmpty` ne prouverait
    /// rien (un objet supprimé reste lisible, voir le piège noté sur le store).
    @Test("Supprimer une conversation supprime ses messages ET les sources de ces messages")
    func deleteCascadesToMessagesAndSources() throws {
        let store = try makeStore()
        let conversation = try store.createConversation(title: "À effacer", now: date(0))
        try store.appendUserMessage(to: conversation, text: "Question", now: date(1))
        try store.appendAssistantMessage(
            to: conversation,
            text: "Réponse",
            sources: makeSources(3),
            now: date(2)
        )

        #expect(try storedMessages(in: store).count == 2)
        #expect(try storedSources(in: store).count == 3)

        try store.delete(conversation)

        // Cascade transitive : conversation → messages → sources. Sans elle, des
        // données personnelles resteraient dans le fichier SQLite alors que
        // l'UI afficherait un historique vide.
        #expect(try store.conversations().isEmpty)
        #expect(try storedConversationCount(in: store) == 0)
        #expect(try storedMessages(in: store).isEmpty)
        #expect(try storedSources(in: store).isEmpty)
    }

    @Test("Supprimer une conversation ne touche pas les autres")
    func deleteOnlyAffectsTargetConversation() throws {
        let store = try makeStore()
        let àEffacer = try store.createConversation(title: "À effacer", now: date(0))
        let àGarder = try store.createConversation(title: "À garder", now: date(1))

        try store.appendUserMessage(to: àEffacer, text: "Perdue", now: date(2))
        try store.appendAssistantMessage(
            to: àGarder,
            text: "Conservée",
            sources: makeSources(2),
            now: date(3)
        )

        try store.delete(àEffacer)

        #expect(try store.conversations().map(\.title) == ["À garder"])
        #expect(try storedMessages(in: store).map(\.text) == ["Conservée"])
        #expect(try storedSources(in: store).count == 2)
    }

    @Test("Tout effacer ne laisse aucune conversation, aucun message, aucune source")
    func deleteAllClearsEverything() throws {
        let store = try makeStore()
        for index in 0..<5 {
            let conversation = try store.createConversation(
                title: "Conversation \(index)",
                now: date(TimeInterval(index))
            )
            try store.appendUserMessage(to: conversation, text: "Question \(index)", now: date(100))
            try store.appendAssistantMessage(
                to: conversation,
                text: "Réponse \(index)",
                sources: makeSources(2),
                now: date(200)
            )
        }

        try store.deleteAll()

        #expect(try store.conversations().isEmpty)
        #expect(try storedConversationCount(in: store) == 0)
        #expect(try storedMessages(in: store).isEmpty)
        #expect(try storedSources(in: store).isEmpty)
    }

    @Test("Tout effacer sur un historique déjà vide ne lève aucune erreur")
    func deleteAllOnEmptyStoreIsSafe() throws {
        let store = try makeStore()

        try store.deleteAll()
        try store.deleteAll()

        #expect(try store.conversations().isEmpty)
    }
}

// MARK: - Liste et tri

@MainActor
@Suite("Historique — liste et tri")
struct ChatHistoryListingTests {
    @Test("Les conversations sont listées de la plus récemment active à la plus ancienne")
    func sortedByMostRecentActivity() throws {
        let store = try makeStore()
        try store.createConversation(title: "Ancienne", now: date(0))
        try store.createConversation(title: "Intermédiaire", now: date(10))
        try store.createConversation(title: "Récente", now: date(20))

        #expect(try store.conversations().map(\.title) == ["Récente", "Intermédiaire", "Ancienne"])
    }

    @Test("Relancer une vieille conversation la fait remonter en tête")
    func reactivatedConversationMovesToTop() throws {
        let store = try makeStore()
        let ancienne = try store.createConversation(title: "Ancienne", now: date(0))
        try store.createConversation(title: "Récente", now: date(10))

        try store.appendUserMessage(to: ancienne, text: "On reprend", now: date(30))

        #expect(try store.conversations().map(\.title) == ["Ancienne", "Récente"])
    }

    @Test("À activité identique, la conversation la plus récemment créée passe devant")
    func tiesBrokenByCreationDate() throws {
        let store = try makeStore()
        let ancienne = try store.createConversation(title: "Créée en premier", now: date(0))
        let récente = try store.createConversation(title: "Créée ensuite", now: date(10))

        // Même `updatedAt` : sans départage sur `createdAt`, l'ordre serait
        // indéterminé et la liste « sauterait » d'un affichage à l'autre.
        try store.rename(ancienne, to: "Créée en premier", now: date(50))
        try store.rename(récente, to: "Créée ensuite", now: date(50))

        #expect(try store.conversations().map(\.title) == ["Créée ensuite", "Créée en premier"])
    }

    @Test("Un grand nombre de conversations reste listé, trié et bornable")
    func manyConversations() throws {
        let store = try makeStore()
        for index in 0..<200 {
            try store.createConversation(
                title: "Conversation \(index)",
                now: date(TimeInterval(index))
            )
        }

        let toutes = try store.conversations()
        #expect(toutes.count == 200)
        #expect(toutes.first?.title == "Conversation 199")
        #expect(toutes.last?.title == "Conversation 0")
        #expect(try storedConversationCount(in: store) == 200)

        let dixPremières = try store.conversations(limit: 10)
        #expect(dixPremières.count == 10)
        #expect(dixPremières.first?.title == "Conversation 199")
        #expect(dixPremières.last?.title == "Conversation 190")
    }

    @Test("Une limite nulle ou négative renvoie une liste vide, jamais l'historique entier")
    func nonPositiveLimitReturnsNothing() throws {
        let store = try makeStore()
        try store.createConversation(title: "Une", now: date(0))
        try store.createConversation(title: "Deux", now: date(1))

        // `fetchLimit` est un `Int?` : seul `nil` veut dire « aucune limite »,
        // et on ne parie pas sur l'interprétation d'un 0 par le store.
        #expect(try store.conversations(limit: 0).isEmpty)
        #expect(try store.conversations(limit: -5).isEmpty)
    }

    @Test("Une conversation se retrouve par son identifiant métier")
    func lookupByIdentifier() throws {
        let store = try makeStore()
        let cible = try store.createConversation(title: "Cible", now: date(0))
        try store.createConversation(title: "Autre", now: date(1))

        #expect(try store.conversation(with: cible.id)?.title == "Cible")
        #expect(try store.conversation(with: UUID()) == nil)
    }
}

// MARK: - Recherche

@MainActor
@Suite("Historique — recherche")
struct ChatHistorySearchTests {
    /// Jeu d'essai commun : un titre accentué, un contenu accentué, et une
    /// conversation qui ne doit jamais ressortir.
    private func makePopulatedStore() throws -> ChatHistoryStore {
        let store = try makeStore()

        let marées = try store.createConversation(title: "Discussion du soir", now: date(0))
        try store.appendUserMessage(to: marées, text: "Parle-moi des marées", now: date(1))

        let élections = try store.createConversation(title: "Élections européennes", now: date(10))
        try store.appendUserMessage(to: élections, text: "Quand a lieu le scrutin ?", now: date(11))

        let cuisine = try store.createConversation(title: "Cuisine", now: date(20))
        try store.appendUserMessage(to: cuisine, text: "Recette du gratin", now: date(21))

        return store
    }

    @Test("La recherche trouve un mot présent dans le titre")
    func searchMatchesTitle() throws {
        let store = try makePopulatedStore()

        #expect(try store.conversations(matching: "élections").map(\.title) == ["Élections européennes"])
    }

    @Test("La recherche trouve un mot présent seulement dans le contenu d'un message")
    func searchMatchesMessageContent() throws {
        let store = try makePopulatedStore()

        #expect(try store.conversations(matching: "marées").map(\.title) == ["Discussion du soir"])
    }

    @Test("La recherche ignore les accents, dans les deux sens")
    func searchIgnoresDiacritics() throws {
        let store = try makePopulatedStore()

        // Requête sans accent → texte accentué.
        #expect(try store.conversations(matching: "marees").count == 1)
        #expect(try store.conversations(matching: "elections").count == 1)
        // Requête accentuée → doit rester vraie.
        #expect(try store.conversations(matching: "Élections").count == 1)
    }

    @Test("La recherche ignore la casse")
    func searchIgnoresCase() throws {
        let store = try makePopulatedStore()

        #expect(try store.conversations(matching: "MARÉES").count == 1)
        #expect(try store.conversations(matching: "cUiSiNe").count == 1)
    }

    @Test("Une requête vide ou uniquement composée d'espaces renvoie tout l'historique")
    func emptyQueryReturnsEverything() throws {
        let store = try makePopulatedStore()

        #expect(try store.conversations(matching: "").count == 3)
        #expect(try store.conversations(matching: "    \n ").count == 3)
    }

    @Test("Une requête sans correspondance renvoie une liste vide")
    func noMatchReturnsEmpty() throws {
        let store = try makePopulatedStore()

        #expect(try store.conversations(matching: "astrophysique").isEmpty)
    }

    @Test("Les résultats de recherche gardent le tri par activité récente")
    func searchResultsKeepSortOrder() throws {
        let store = try makeStore()
        let première = try store.createConversation(title: "Jardin en hiver", now: date(0))
        let seconde = try store.createConversation(title: "Jardin en été", now: date(10))
        try store.appendUserMessage(to: première, text: "Que planter ?", now: date(1))
        try store.appendUserMessage(to: seconde, text: "Que planter ?", now: date(11))

        #expect(try store.conversations(matching: "jardin").map(\.title) == ["Jardin en été", "Jardin en hiver"])
    }

    @Test("La limite de recherche s'applique après le filtrage, pas avant")
    func searchLimitAppliesAfterFiltering() throws {
        let store = try makeStore()
        // Les trois plus récentes ne correspondent PAS : une limite posée sur le
        // fetch les consommerait et la recherche renverrait zéro résultat.
        try store.createConversation(title: "Pomme de terre", now: date(0))
        try store.createConversation(title: "Compote de pommes", now: date(1))
        try store.createConversation(title: "Bricolage", now: date(10))
        try store.createConversation(title: "Musique", now: date(11))
        try store.createConversation(title: "Voyage", now: date(12))

        #expect(try store.conversations(matching: "pomme").count == 2)
        #expect(try store.conversations(matching: "pomme", limit: 1).map(\.title) == ["Compote de pommes"])
    }

    @Test("Chercher dans un historique vide ne lève pas et ne renvoie rien")
    func searchOnEmptyStore() throws {
        let store = try makeStore()

        #expect(try store.conversations(matching: "peu importe").isEmpty)
        #expect(try store.conversations(matching: "").isEmpty)
    }
}

// MARK: - Rôle d'un message

@MainActor
@Suite("Historique — rôle d'un message")
struct StoredMessageRoleTests {
    @Test("Le rôle typé reflète la valeur brute stockée, dans les deux sens")
    func roleRoundTrip() {
        let message = StoredMessage(role: .user, text: "Question", createdAt: date(0), order: 0)

        #expect(message.role == .user)
        #expect(message.roleRawValue == "user")

        message.role = .assistant
        #expect(message.roleRawValue == "assistant")
    }

    @Test("Un rôle inconnu, écrit par une version ultérieure de l'app, est lu comme une réponse")
    func unknownRoleFallsBackToAssistant() {
        let message = StoredMessage(role: .user, text: "Contenu", createdAt: date(0), order: 0)

        message.roleRawValue = "outil_inconnu"

        // Repli documenté : on n'attribue jamais à tort des propos à
        // l'utilisateur, et la Library ne doit jamais planter à la relecture.
        #expect(message.role == .assistant)
    }
}

// MARK: - Titre automatique

@MainActor
@Suite("Historique — titre automatique")
struct ConversationTitleBuilderTests {
    @Test("Une question courte devient le titre tel quel, sans points de suspension")
    func shortQuestionIsKeptWhole() {
        let titre = ConversationTitleBuilder.title(from: "Pourquoi le ciel est bleu ?")

        #expect(titre == "Pourquoi le ciel est bleu ?")
        #expect(titre.hasSuffix("…") == false)
    }

    @Test("Une question exactement à la longueur maximale n'est pas tronquée")
    func exactLengthIsNotTruncated() {
        let question = "Douze caractères et quelques mots de plus"
        let titre = ConversationTitleBuilder.title(from: question, maxLength: question.count)

        #expect(titre == question)
    }

    @Test("Une question trop longue est coupée sur une frontière de mot")
    func longQuestionIsCutOnWordBoundary() {
        let question = "Comment fonctionne la photosynthèse chez les plantes aquatiques"
        let titre = ConversationTitleBuilder.title(from: question, maxLength: 30)

        #expect(titre.hasSuffix("…"))
        #expect(titre.count <= 30)
        #expect(titre.dropLast().hasSuffix(" ") == false)

        // Aucun mot partiel : chaque mot du titre existe entier dans la question.
        let motsDeLaQuestion = question.split(separator: " ").map(String.init)
        let motsDuTitre = titre.dropLast().split(separator: " ").map(String.init)
        #expect(motsDuTitre.isEmpty == false)
        #expect(motsDuTitre.allSatisfy { motsDeLaQuestion.contains($0) })
    }

    @Test("Le titre ne dépasse jamais la longueur demandée, points de suspension compris")
    func neverExceedsRequestedLength() {
        let question = "Une question interminable qui continue encore et encore sans jamais s'arrêter"

        for longueur in 2...40 {
            let titre = ConversationTitleBuilder.title(from: question, maxLength: longueur)
            #expect(titre.count <= longueur)
        }
    }

    @Test("Une longueur maximale absurde est bornée à deux caractères")
    func lengthIsClampedToTwo() {
        #expect(ConversationTitleBuilder.title(from: "abcdef", maxLength: 2) == "a…")
        #expect(ConversationTitleBuilder.title(from: "abcdef", maxLength: 0) == "a…")
        #expect(ConversationTitleBuilder.title(from: "abcdef", maxLength: -10) == "a…")
    }

    @Test("Un mot unique plus long que le budget est coupé net")
    func singleLongWordIsCutSharp() {
        let url = "https://fr.wikipedia.org/wiki/Photosynthese_des_plantes_aquatiques"
        let titre = ConversationTitleBuilder.title(from: url, maxLength: 20)

        #expect(titre.count == 20)
        #expect(titre.hasPrefix("https://fr.wikipedi"))
        #expect(titre.hasSuffix("…"))
    }

    @Test("Une question vide ou seulement composée d'espaces donne le titre de repli")
    func blankQuestionFallsBack() {
        #expect(ConversationTitleBuilder.title(from: "") == ConversationTitleBuilder.fallbackTitle)
        #expect(
            ConversationTitleBuilder.title(from: "   \n\t  ") == ConversationTitleBuilder.fallbackTitle
        )
    }

    @Test("Les retours à la ligne et espaces multiples sont réduits à une espace simple")
    func whitespaceIsCollapsed() {
        let titre = ConversationTitleBuilder.title(from: "Première ligne\nDeuxième    ligne")

        #expect(titre == "Première ligne Deuxième ligne")
        #expect(titre.contains("\n") == false)
    }

    @Test("Une famille emoji composée par ZWJ n'est jamais coupée en deux")
    func zwjSequenceIsNeverSplit() {
        let famille = "👨‍👩‍👧‍👦"
        #expect(famille.count == 1)

        let question = Array(repeating: famille, count: 20).joined(separator: " ")
        let titre = ConversationTitleBuilder.title(from: question, maxLength: 10)

        #expect(titre.count <= 10)
        #expect(titre.hasSuffix("…"))
        // Une grappe cassée laisserait apparaître un 👨 isolé ou un ZWJ nu.
        #expect(titre.dropLast().allSatisfy { $0 == Character(famille) || $0 == " " })
    }

    @Test("Un drapeau, formé de deux indicateurs régionaux, n'est jamais coupé en deux")
    func flagSequenceIsNeverSplit() {
        let drapeau = "🇫🇷"
        #expect(drapeau.count == 1)

        let question = String(repeating: drapeau, count: 30)
        let titre = ConversationTitleBuilder.title(from: question, maxLength: 8)

        #expect(titre.count == 8)
        #expect(titre.dropLast().allSatisfy { $0 == Character(drapeau) })
        // 7 drapeaux de 2 scalaires + les points de suspension : aucun
        // indicateur régional n'a été perdu ni laissé seul.
        #expect(titre.unicodeScalars.count == 15)
    }

    @Test("Un « é » décomposé garde son accent combinant")
    func decomposedCharacterKeepsItsAccent() {
        let eAigu = "e\u{0301}"
        #expect(eAigu.count == 1)

        let question = String(repeating: eAigu, count: 30)
        let titre = ConversationTitleBuilder.title(from: question, maxLength: 10)

        #expect(titre.count == 10)
        // 9 grappes de 2 scalaires + les points de suspension. Une coupe au
        // scalaire laisserait un « e » nu ou un accent orphelin.
        #expect(titre.unicodeScalars.count == 19)
    }

    @Test("Le titre dérivé d'une vraie question longue reste lisible")
    func realisticLongQuestion() {
        let question = """
        Peux-tu m'expliquer en détail comment les marées sont provoquées par la Lune \
        et pourquoi il y en a deux par jour ?
        """
        let titre = ConversationTitleBuilder.title(from: question)

        #expect(titre.count <= ConversationTitleBuilder.maxTitleLength)
        #expect(titre.hasSuffix("…"))
        #expect(titre.hasPrefix("Peux-tu m'expliquer"))
        #expect(titre.contains("\n") == false)
    }
}
