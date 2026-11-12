//
//  ChatHistoryStoreQueryTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 24/09/2026.
//

import Testing
import Foundation
import SwiftData
@testable import Triva

// MARK: - Suppression

@MainActor
@Suite("Historique — suppression")
struct ChatHistoryDeletionTests {
    /// Vérifié depuis un contexte NEUF, pas via le graphe d'objets de la
    /// conversation supprimée : `conversation.messages.isEmpty` ne prouverait
    /// rien (un objet supprimé reste lisible, voir le piège noté sur le store).
    @Test("Supprimer une conversation supprime ses messages ET les sources de ces messages")
    func deleteCascadesToMessagesAndSources() throws {
        let store = try historyMakeStore()
        let conversation = try store.createConversation(title: "À effacer", now: historyDate(0))
        try store.appendUserMessage(to: conversation, text: "Question", now: historyDate(1))
        try store.appendAssistantMessage(
            to: conversation,
            text: "Réponse",
            sources: historyMakeSources(3),
            now: historyDate(2)
        )

        #expect(try historyStoredMessages(in: store).count == 2)
        #expect(try historyStoredSources(in: store).count == 3)

        try store.delete(conversation)

        // Cascade transitive : conversation → messages → sources. Sans elle, des
        // données personnelles resteraient dans le fichier SQLite alors que
        // l'UI afficherait un historique vide.
        #expect(try store.conversations().isEmpty)
        #expect(try historyStoredConversationCount(in: store) == 0)
        #expect(try historyStoredMessages(in: store).isEmpty)
        #expect(try historyStoredSources(in: store).isEmpty)
    }

    @Test("Supprimer une conversation ne touche pas les autres")
    func deleteOnlyAffectsTargetConversation() throws {
        let store = try historyMakeStore()
        let àEffacer = try store.createConversation(title: "À effacer", now: historyDate(0))
        let àGarder = try store.createConversation(title: "À garder", now: historyDate(1))

        try store.appendUserMessage(to: àEffacer, text: "Perdue", now: historyDate(2))
        try store.appendAssistantMessage(
            to: àGarder,
            text: "Conservée",
            sources: historyMakeSources(2),
            now: historyDate(3)
        )

        try store.delete(àEffacer)

        #expect(try store.conversations().map(\.title) == ["À garder"])
        #expect(try historyStoredMessages(in: store).map(\.text) == ["Conservée"])
        #expect(try historyStoredSources(in: store).count == 2)
    }

    @Test("Tout effacer ne laisse aucune conversation, aucun message, aucune source")
    func deleteAllClearsEverything() throws {
        let store = try historyMakeStore()
        for index in 0..<5 {
            let conversation = try store.createConversation(
                title: "Conversation \(index)",
                now: historyDate(TimeInterval(index))
            )
            try store.appendUserMessage(to: conversation, text: "Question \(index)", now: historyDate(100))
            try store.appendAssistantMessage(
                to: conversation,
                text: "Réponse \(index)",
                sources: historyMakeSources(2),
                now: historyDate(200)
            )
        }

        try store.deleteAll()

        #expect(try store.conversations().isEmpty)
        #expect(try historyStoredConversationCount(in: store) == 0)
        #expect(try historyStoredMessages(in: store).isEmpty)
        #expect(try historyStoredSources(in: store).isEmpty)
    }

    @Test("Tout effacer sur un historique déjà vide ne lève aucune erreur")
    func deleteAllOnEmptyStoreIsSafe() throws {
        let store = try historyMakeStore()

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
        let store = try historyMakeStore()
        try store.createConversation(title: "Ancienne", now: historyDate(0))
        try store.createConversation(title: "Intermédiaire", now: historyDate(10))
        try store.createConversation(title: "Récente", now: historyDate(20))

        #expect(try store.conversations().map(\.title) == ["Récente", "Intermédiaire", "Ancienne"])
    }

    @Test("Relancer une vieille conversation la fait remonter en tête")
    func reactivatedConversationMovesToTop() throws {
        let store = try historyMakeStore()
        let ancienne = try store.createConversation(title: "Ancienne", now: historyDate(0))
        try store.createConversation(title: "Récente", now: historyDate(10))

        try store.appendUserMessage(to: ancienne, text: "On reprend", now: historyDate(30))

        #expect(try store.conversations().map(\.title) == ["Ancienne", "Récente"])
    }

    @Test("À activité identique, la conversation la plus récemment créée passe devant")
    func tiesBrokenByCreationDate() throws {
        let store = try historyMakeStore()
        let ancienne = try store.createConversation(title: "Créée en premier", now: historyDate(0))
        let récente = try store.createConversation(title: "Créée ensuite", now: historyDate(10))

        // Même `updatedAt` : sans départage sur `createdAt`, l'ordre serait
        // indéterminé et la liste « sauterait » d'un affichage à l'autre.
        try store.rename(ancienne, to: "Créée en premier", now: historyDate(50))
        try store.rename(récente, to: "Créée ensuite", now: historyDate(50))

        #expect(try store.conversations().map(\.title) == ["Créée ensuite", "Créée en premier"])
    }

    @Test("Un grand nombre de conversations reste listé, trié et bornable")
    func manyConversations() throws {
        let store = try historyMakeStore()
        for index in 0..<200 {
            try store.createConversation(
                title: "Conversation \(index)",
                now: historyDate(TimeInterval(index))
            )
        }

        let toutes = try store.conversations()
        #expect(toutes.count == 200)
        #expect(toutes.first?.title == "Conversation 199")
        #expect(toutes.last?.title == "Conversation 0")
        #expect(try historyStoredConversationCount(in: store) == 200)

        let dixPremières = try store.conversations(limit: 10)
        #expect(dixPremières.count == 10)
        #expect(dixPremières.first?.title == "Conversation 199")
        #expect(dixPremières.last?.title == "Conversation 190")
    }

    @Test("Une limite nulle ou négative renvoie une liste vide, jamais l'historique entier")
    func nonPositiveLimitReturnsNothing() throws {
        let store = try historyMakeStore()
        try store.createConversation(title: "Une", now: historyDate(0))
        try store.createConversation(title: "Deux", now: historyDate(1))

        // `fetchLimit` est un `Int?` : seul `nil` veut dire « aucune limite »,
        // et on ne parie pas sur l'interprétation d'un 0 par le store.
        #expect(try store.conversations(limit: 0).isEmpty)
        #expect(try store.conversations(limit: -5).isEmpty)
    }

    @Test("Une conversation se retrouve par son identifiant métier")
    func lookupByIdentifier() throws {
        let store = try historyMakeStore()
        let cible = try store.createConversation(title: "Cible", now: historyDate(0))
        try store.createConversation(title: "Autre", now: historyDate(1))

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
        let store = try historyMakeStore()

        let marées = try store.createConversation(title: "Discussion du soir", now: historyDate(0))
        try store.appendUserMessage(to: marées, text: "Parle-moi des marées", now: historyDate(1))

        let élections = try store.createConversation(title: "Élections européennes", now: historyDate(10))
        try store.appendUserMessage(to: élections, text: "Quand a lieu le scrutin ?", now: historyDate(11))

        let cuisine = try store.createConversation(title: "Cuisine", now: historyDate(20))
        try store.appendUserMessage(to: cuisine, text: "Recette du gratin", now: historyDate(21))

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
        let store = try historyMakeStore()
        let première = try store.createConversation(title: "Jardin en hiver", now: historyDate(0))
        let seconde = try store.createConversation(title: "Jardin en été", now: historyDate(10))
        try store.appendUserMessage(to: première, text: "Que planter ?", now: historyDate(1))
        try store.appendUserMessage(to: seconde, text: "Que planter ?", now: historyDate(11))

        #expect(try store.conversations(matching: "jardin").map(\.title) == ["Jardin en été", "Jardin en hiver"])
    }

    @Test("La limite de recherche s'applique après le filtrage, pas avant")
    func searchLimitAppliesAfterFiltering() throws {
        let store = try historyMakeStore()
        // Les trois plus récentes ne correspondent PAS : une limite posée sur le
        // fetch les consommerait et la recherche renverrait zéro résultat.
        try store.createConversation(title: "Pomme de terre", now: historyDate(0))
        try store.createConversation(title: "Compote de pommes", now: historyDate(1))
        try store.createConversation(title: "Bricolage", now: historyDate(10))
        try store.createConversation(title: "Musique", now: historyDate(11))
        try store.createConversation(title: "Voyage", now: historyDate(12))

        #expect(try store.conversations(matching: "pomme").count == 2)
        #expect(try store.conversations(matching: "pomme", limit: 1).map(\.title) == ["Compote de pommes"])
    }

    @Test("Chercher dans un historique vide ne lève pas et ne renvoie rien")
    func searchOnEmptyStore() throws {
        let store = try historyMakeStore()

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
        let message = StoredMessage(role: .user, text: "Question", createdAt: historyDate(0), order: 0)

        #expect(message.role == .user)
        #expect(message.roleRawValue == "user")

        message.role = .assistant
        #expect(message.roleRawValue == "assistant")
    }

    @Test("Un rôle inconnu, écrit par une version ultérieure de l'app, est lu comme une réponse")
    func unknownRoleFallsBackToAssistant() {
        let message = StoredMessage(role: .user, text: "Contenu", createdAt: historyDate(0), order: 0)

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
