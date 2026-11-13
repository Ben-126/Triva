//
//  AnswerNotesPersistenceTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation
import SwiftData
import Testing
@testable import Triva

// Mission E1a : les mentions d'une réponse (sources non lues, « Réponse sans recherche », « Hors
// connexion, sans source », « Réponse sans source lisible ») survivent à la réouverture depuis la
// Bibliothèque et se retrouvent dans un favori. Aucun réseau, aucun modèle système, jamais le store réel.

private typealias Provider = ScriptedWebSearchProvider

private struct E1aConstantScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0.5, count: candidates.count)
    }
}

private struct E1aNoDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

private struct E1aUnknownLanguage: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

/// Aucune page n'est lisible : seuls les extraits de la recherche comptent.
private struct E1aNoScrape: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "", content: "", succeeded: false)
    }
}

private func e1aClassification(skipSearch: Bool) -> String {
    """
    {"classification":{"skipSearch":\(skipSearch),"personalSearch":false,"academicSearch":false,\
    "discussionSearch":false,"showWeatherWidget":false,"showStockWidget":false,\
    "showCalculationWidget":false},"standaloneFollowUp":"Question"}
    """
}

private let readable = ChainFixtures.result(
    "Tour Eiffel", url: "https://fr.wikipedia.org/wiki/Tour_Eiffel", content: "La tour Eiffel mesure 330 mètres de hauteur."
)
private let unreadable = ChainFixtures.result("Page vide", url: "https://exemple.test/vide", content: "")

private func fixedArtifacts(
    searchPerformed: Bool = true, citable: Int = 0, uncitable: Set<Int> = [], withoutSearch: Bool = false,
    offline: Bool = false, widgets: [SearchWidgetOutput] = []
) -> SearchArtifacts {
    var artifacts = SearchArtifacts(
        sources: [readable], attachmentSourceCount: 0, widgets: widgets,
        images: .notRequested, videos: .notRequested, mode: .quick, promptComplexity: .full,
        citableSourceCount: citable, searchPerformed: searchPerformed, searchQuery: "q",
        uncitableSourceNumbers: uncitable, answeredWithoutSearch: withoutSearch
    )
    artifacts.answeredOffline = offline
    return artifacts
}

// MARK: - Codec

@Suite("SourceNumberCodec — numéros de sources stockés en texte")
struct SourceNumberCodecTests {
    @Test("Aller-retour, trié, sans doublon")
    func roundTrip() {
        #expect(SourceNumberCodec.encode([3, 1, 2]) == "1,2,3")
        #expect(SourceNumberCodec.decode("1,2,3") == [1, 2, 3])
        #expect(SourceNumberCodec.decode(SourceNumberCodec.encode([])) == [])
        #expect(SourceNumberCodec.encode([]) == "")
    }

    @Test("Lecture défensive : le non numérique, zéro et le négatif sont ignorés, jamais d'échec")
    func defensiveDecode() {
        #expect(SourceNumberCodec.decode("2, x ,0,-1,,3,2") == [2, 3])
        #expect(SourceNumberCodec.decode("n'importe quoi") == [])
        #expect(SourceNumberCodec.encode([0, -4, 5]) == "5")
    }
}

// MARK: - Artefacts et message

@MainActor
@Suite("SearchArtifacts — « Réponse sans source lisible »")
struct AnswerWithoutReadableSourceTests {
    @Test("Recherche faite mais rien de lisible : la mention est due ; sinon non")
    func derivedFromExistingFields() {
        #expect(fixedArtifacts(searchPerformed: true, citable: 0).answeredWithoutReadableSource)
        #expect(!fixedArtifacts(searchPerformed: true, citable: 2).answeredWithoutReadableSource)
        #expect(!fixedArtifacts(searchPerformed: false, citable: 0, withoutSearch: true).answeredWithoutReadableSource)
    }

    @Test("Un widget abouti l'écarte : sa donnée vient d'un service, pas de la mémoire du modèle")
    func widgetSuppressesIt() {
        let widget = SearchWidgetOutput(kind: .calculation, llmContext: "2+2=4")
        #expect(!fixedArtifacts(searchPerformed: true, citable: 0, widgets: [widget]).answeredWithoutReadableSource)
    }

    @Test("`storedNotes` reprend les quatre mentions des artefacts")
    func storedNotesMirrorTheArtifacts() {
        let notes = fixedArtifacts(searchPerformed: true, citable: 0, uncitable: [2], offline: true).storedNotes
        #expect(notes == StoredAnswerNotes(
            uncitableSourceNumbers: [2], answeredWithoutSearch: false, answeredOffline: true, answeredWithoutReadableSource: true
        ))
    }

    @Test("`attach` recopie la mention, « Aucune source fiable » l'efface, `restore` la rend")
    func messageLifecycle() {
        var message = ChatViewModel.Message(role: .assistant, text: "Texte")
        message.attach(fixedArtifacts(searchPerformed: true, citable: 0))
        #expect(message.answeredWithoutReadableSource)

        message.markNoReliableSources(searchQuery: "q", at: Date(timeIntervalSince1970: 0))
        #expect(!message.answeredWithoutReadableSource)

        message.restore(StoredAnswerNotes(
            uncitableSourceNumbers: [2], answeredWithoutSearch: true, answeredOffline: true, answeredWithoutReadableSource: true
        ))
        #expect(message.uncitableSourceNumbers == [2])
        #expect(message.answeredWithoutSearch && message.answeredOffline && message.answeredWithoutReadableSource)
    }

    @Test("La mention : texte exact, jamais avec « Aucune source fiable », la mention hors connexion l'emporte")
    func presentation() {
        typealias Snapshot = MessageBubblePresentation.AnswerSnapshot
        let plain = Snapshot(state: .completed, hasBody: true, answeredWithoutReadableSource: true)
        #expect(MessageBubblePresentation.answerWithoutReadableSourceLabel == "Réponse sans source lisible")
        #expect(MessageBubblePresentation.answerNote(plain) == "Réponse sans source lisible")
        #expect(MessageBubblePresentation.answerNoteIdentifier(plain) == "chat.answerWithoutReadableSource")

        #expect(MessageBubblePresentation.answerNote(Snapshot(state: .completed, answeredWithoutReadableSource: true)) == nil)
        #expect(MessageBubblePresentation.answerNote(
            Snapshot(state: .noReliableSources, hasBody: true, answeredWithoutReadableSource: true)
        ) == nil)

        let offline = Snapshot(state: .completed, hasBody: true, answeredOffline: true, answeredWithoutReadableSource: true)
        #expect(MessageBubblePresentation.answerNote(offline) == MessageBubblePresentation.answerOfflineLabel)
        #expect(MessageBubblePresentation.answerNote(Snapshot(state: .completed, hasBody: true, answeredWithoutSearch: true))
            == MessageBubblePresentation.answerWithoutSearchLabel)
    }

    @Test("Le résumé d'un message reprend le drapeau")
    func snapshotCarriesTheFlag() {
        var message = ChatViewModel.Message(role: .assistant, text: "Texte")
        message.answeredWithoutReadableSource = true
        #expect(MessageBubbleView.answerSnapshot(of: message).answeredWithoutReadableSource)
    }
}

// MARK: - Store

@MainActor
@Suite("ChatHistoryStore — mentions persistées")
struct StoredAnswerNotesStoreTests {
    private func stores() throws -> (history: ChatHistoryStore, favorites: FavoritesStore) {
        let container = try TrivaModelContainer.makeInMemory()
        let locale = Locale(identifier: "fr_FR")
        return (ChatHistoryStore(container: container, locale: locale), FavoritesStore(container: container, locale: locale))
    }

    @Test("Sans mention, un message garde les valeurs par défaut (anciens appels inchangés)")
    func defaultsAreEmpty() throws {
        let stores = try stores()
        let conversation = try stores.history.createConversation(title: "T")
        let answer = try stores.history.appendAssistantMessage(to: conversation, text: "Réponse", sources: [readable])
        #expect(answer.answerNotes == StoredAnswerNotes())
        #expect(answer.uncitableSourceNumbersRaw == "")
    }

    @Test("Les quatre mentions atteignent le store : relues depuis un contexte neuf")
    func notesReachTheStore() throws {
        let stores = try stores()
        let conversation = try stores.history.createConversation(title: "T")
        let notes = StoredAnswerNotes(
            uncitableSourceNumbers: [2, 4], answeredWithoutSearch: true, answeredOffline: true, answeredWithoutReadableSource: true
        )
        let answer = try stores.history.appendAssistantMessage(to: conversation, text: "Réponse", notes: notes)

        let fresh = ModelContext(stores.history.container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<StoredMessage>()).first { $0.id == answer.id })
        #expect(stored.answerNotes == notes)
        #expect(stored.uncitableSourceNumbersRaw == "2,4")
    }

    @Test("Un favori copie les numéros non lus au marquage, depuis le message ou depuis le chat")
    func favoriteCopiesUnreadNumbers() throws {
        let stores = try stores()
        let conversation = try stores.history.createConversation(title: "T")
        try stores.history.appendUserMessage(to: conversation, text: "Question")
        let answer = try stores.history.appendAssistantMessage(
            to: conversation, text: "Texte[1][2].", sources: [readable, unreadable],
            notes: StoredAnswerNotes(uncitableSourceNumbers: [2])
        )

        let fromMessage = try stores.favorites.mark(answer)
        #expect(fromMessage.uncitableSourceNumbers == [2])
        let content = FavoritePresentation.detailContent(copying: fromMessage)
        #expect(content.uncitableSourceNumbers == [2])
        #expect(content.sources.count == 2)

        let direct = try stores.favorites.mark(
            messageID: UUID(), conversationID: nil, question: "Q", answer: "R[1].", sources: [readable, unreadable],
            notes: StoredAnswerNotes(uncitableSourceNumbers: [2])
        )
        #expect(direct.uncitableSourceNumbers == [2])
        let plain = try stores.favorites.mark(messageID: UUID(), conversationID: nil, question: "Q", answer: "R")
        #expect(plain.uncitableSourceNumbers.isEmpty)

        let fresh = ModelContext(stores.favorites.container)
        let storedFavorites = try fresh.fetch(FetchDescriptor<StoredFavorite>())
        #expect(storedFavorites.filter { $0.uncitableSourceNumbers == [2] }.count == 2)
    }
}

// MARK: - De bout en bout

@MainActor
@Suite("ChatViewModel — mentions persistées puis restaurées (mission E1a)")
struct AnswerNotesRestorationTests {
    private func viewModel(
        history: ChatHistoryStore, favorites: FavoritesStore? = nil, aiProvider: ChainAIProvider, results: [SearXNGSearchResult]?
    ) -> ChatViewModel {
        let manager = FailoverManager(client: ChainSearXNGClient(shouldFail: true), instances: [ChainFixtures.instance])
        let chain = results.map { WebSearchChain(searxng: Provider(kind: .searxng, outcome: .results($0)), openSourceProviders: { _ in [] }) }
        return ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { manager },
            resolveWebSearchChain: { _ in chain },
            resolvePipelineConfiguration: { .cloud },
            readResponseMode: { .quick },
            historyStore: history,
            favoritesStore: favorites,
            makeOrchestrator: { inputs in
                SearchOrchestrator(
                    failoverManager: inputs.failoverManager, aiProvider: inputs.provider, responseMode: inputs.responseMode,
                    configuration: inputs.configuration, scrapeService: E1aNoScrape(),
                    sourceRanker: SourceRanker(
                        relevanceScorer: E1aConstantScorer(), duplicateScorer: E1aNoDuplicateScorer(), languageIdentifier: E1aUnknownLanguage()
                    ),
                    widgets: [], webSearchChain: inputs.webSearchChain
                )
            },
            generateSuggestions: { _, _ in [] }
        )
    }

    private func history() throws -> ChatHistoryStore {
        ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))
    }

    /// Un second `ChatViewModel` sur le même store, comme après un relancement de l'app.
    private func reopened(_ original: ChatViewModel, in store: ChatHistoryStore) throws -> ChatViewModel.Message {
        let id = try #require(original.currentConversationID)
        let fresh = viewModel(history: store, aiProvider: ChainAIProvider(), results: nil)
        #expect(fresh.loadConversation(id: id))
        return try #require(fresh.messages.last)
    }

    @Test("TROU 1 : une source jamais lue le reste à la réouverture (texte simple, « non lue »)")
    func unreadSourceSurvivesReopening() async throws {
        let store = try history()
        let ai = ChainAIProvider(classification: e1aClassification(skipSearch: false), answer: "Elle mesure 330 mètres[1], dit une page vide[2].")
        let model = viewModel(history: store, aiProvider: ai, results: [readable, unreadable])

        await model.send(query: "Hauteur de la tour Eiffel ?")

        let live = try #require(model.messages.last)
        #expect(live.status == .completed)
        #expect(live.uncitableSourceNumbers == [2])

        let restored = try reopened(model, in: store)
        #expect(restored.uncitableSourceNumbers == [2])
        #expect(restored.sources.count == 2)
        #expect(!restored.answeredWithoutReadableSource)
        #expect(SourcesListPresentation.unreadLabel == "non lue")
    }

    @Test("TROU 2 : « Réponse sans recherche » revient à la réouverture")
    func answeredWithoutSearchSurvivesReopening() async throws {
        let store = try history()
        let ai = ChainAIProvider(classification: e1aClassification(skipSearch: true), answer: "Feuilles rousses au vent.")
        let model = viewModel(history: store, aiProvider: ai, results: nil)

        await model.send(query: "Écris un haïku sur l'automne.")

        #expect(try #require(model.messages.last).answeredWithoutSearch)
        let restored = try reopened(model, in: store)
        #expect(restored.answeredWithoutSearch)
        #expect(MessageBubblePresentation.answerNote(MessageBubbleView.answerSnapshot(of: restored))
            == MessageBubblePresentation.answerWithoutSearchLabel)
    }

    @Test("Recherche faite, rien de lisible : « Réponse sans source lisible », en direct puis relue")
    func noReadableSourceSurvivesReopening() async throws {
        let store = try history()
        let ai = ChainAIProvider(classification: e1aClassification(skipSearch: false), answer: "Je crois que c'est 330 mètres.")
        let model = viewModel(history: store, aiProvider: ai, results: [unreadable])

        await model.send(query: "Hauteur de la tour Eiffel ?")

        let live = try #require(model.messages.last)
        #expect(live.answeredWithoutReadableSource)
        #expect(!live.answeredWithoutSearch)
        let restored = try reopened(model, in: store)
        #expect(restored.answeredWithoutReadableSource)
        #expect(MessageBubblePresentation.answerNote(MessageBubbleView.answerSnapshot(of: restored))
            == MessageBubblePresentation.answerWithoutReadableSourceLabel)
    }

    @Test("Réponse normale : aucune mention persistée, aucune relue")
    func plainAnswerHasNoNotes() async throws {
        let store = try history()
        let ai = ChainAIProvider(classification: e1aClassification(skipSearch: false), answer: "330 mètres[1].")
        let model = viewModel(history: store, aiProvider: ai, results: [readable])

        await model.send(query: "Hauteur de la tour Eiffel ?")

        let restored = try reopened(model, in: store)
        #expect(restored.uncitableSourceNumbers.isEmpty)
        #expect(!restored.answeredWithoutSearch && !restored.answeredOffline && !restored.answeredWithoutReadableSource)
    }

    @Test("L'étoile du chat transmet les numéros non lus au favori")
    func chatStarPassesUnreadNumbers() async throws {
        let container = try TrivaModelContainer.makeInMemory()
        let locale = Locale(identifier: "fr_FR")
        let store = ChatHistoryStore(container: container, locale: locale)
        let favorites = FavoritesStore(container: container, locale: locale)
        let ai = ChainAIProvider(classification: e1aClassification(skipSearch: false), answer: "330 mètres[1], page vide[2].")
        let model = viewModel(history: store, favorites: favorites, aiProvider: ai, results: [readable, unreadable])

        await model.send(query: "Hauteur de la tour Eiffel ?")
        let answer = try #require(model.messages.last)
        model.toggleFavorite(messageID: answer.id)

        let favorite = try #require(try favorites.favorites().first)
        #expect(favorite.uncitableSourceNumbers == [2])
    }
}
