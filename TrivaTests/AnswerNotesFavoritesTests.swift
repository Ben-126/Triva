//
//  AnswerNotesFavoritesTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 12/11/2026.
//

import Foundation
import SwiftData
import Testing
@testable import Triva

// Mission E2b : « Sources probablement hors sujet » et « SearXNG injoignable » survivent à la
// réouverture depuis la Bibliothèque, et les petites mentions de la bulle (« Réponse sans
// recherche », « Hors connexion, sans source », « Réponse sans source lisible », « Sources
// probablement hors sujet ») se retrouvent dans le détail d'un favori, avec les composants de la
// bulle. Aucun réseau, aucun modèle système, jamais le store réel.

private typealias Provider = ScriptedWebSearchProvider

private struct E2bConstantScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0.5, count: candidates.count)
    }
}

private struct E2bNoDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

private struct E2bUnknownLanguage: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

private struct E2bNoScrape: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "", content: "", succeeded: false)
    }
}

private let question = "Quelle est la hauteur de la tour Eiffel ?"
private let onTopic = [ChainFixtures.result(
    "Tour Eiffel", url: "https://fr.wikipedia.org/wiki/Tour_Eiffel", content: "La tour Eiffel mesure 330 mètres de hauteur."
)]
private let offTopic = [ChainFixtures.result(
    "Paris Saint-Germain", url: "https://fr.wikipedia.org/wiki/Paris_Saint-Germain", content: "Club de football."
)]

private func classification(skipSearch: Bool) -> String {
    """
    {"classification":{"skipSearch":\(skipSearch),"personalSearch":false,"academicSearch":false,\
    "discussionSearch":false,"showWeatherWidget":false,"showStockWidget":false,\
    "showCalculationWidget":false},"standaloneFollowUp":"\(question)"}
    """
}

private let allNotes = StoredAnswerNotes(
    uncitableSourceNumbers: [2], answeredWithoutSearch: true, answeredOffline: true,
    answeredWithoutReadableSource: true, sourcesMayBeOffTopic: true, searXNGUnreachable: true
)

// MARK: - Modèles et stores

@MainActor
@Suite("Mentions E2b — persistance d'un message et copie dans un favori")
struct AnswerNotesE2bStoreTests {
    private func stores() throws -> (history: ChatHistoryStore, favorites: FavoritesStore) {
        let container = try TrivaModelContainer.makeInMemory()
        let locale = Locale(identifier: "fr_FR")
        return (ChatHistoryStore(container: container, locale: locale), FavoritesStore(container: container, locale: locale))
    }

    @Test("Hors sujet et SearXNG injoignable : valeurs par défaut sur un message sans mention")
    func defaultsAreFalse() throws {
        let stores = try stores()
        let conversation = try stores.history.createConversation(title: "T")
        let answer = try stores.history.appendAssistantMessage(to: conversation, text: "Réponse")
        #expect(!answer.sourcesMayBeOffTopic && !answer.searXNGUnreachable)
        #expect(answer.answerNotes == StoredAnswerNotes())
    }

    @Test("Chaque drapeau atteint le store seul : relu depuis un contexte neuf, sans entraîner l'autre")
    func eachFlagReachesTheStore() throws {
        let stores = try stores()
        let conversation = try stores.history.createConversation(title: "T")
        let offTopicOnly = try stores.history.appendAssistantMessage(
            to: conversation, text: "A", notes: StoredAnswerNotes(sourcesMayBeOffTopic: true)
        )
        let unreachableOnly = try stores.history.appendAssistantMessage(
            to: conversation, text: "B", notes: StoredAnswerNotes(searXNGUnreachable: true)
        )
        let everything = try stores.history.appendAssistantMessage(to: conversation, text: "C", notes: allNotes)

        let fresh = ModelContext(stores.history.container)
        let messages = try fresh.fetch(FetchDescriptor<StoredMessage>())
        func stored(_ message: StoredMessage) throws -> StoredMessage {
            try #require(messages.first { $0.id == message.id })
        }
        let a = try stored(offTopicOnly)
        #expect(a.sourcesMayBeOffTopic && !a.searXNGUnreachable)
        let b = try stored(unreachableOnly)
        #expect(b.searXNGUnreachable && !b.sourcesMayBeOffTopic)
        #expect(try stored(everything).answerNotes == allNotes)
    }

    @Test("Un favori copie au marquage les trois mentions et « hors sujet », depuis le message comme depuis le chat")
    func favoriteCopiesTheMentions() throws {
        let stores = try stores()
        let conversation = try stores.history.createConversation(title: "T")
        try stores.history.appendUserMessage(to: conversation, text: "Question")
        let answer = try stores.history.appendAssistantMessage(to: conversation, text: "Texte", notes: allNotes)

        let fromMessage = try stores.favorites.mark(answer)
        let direct = try stores.favorites.mark(messageID: UUID(), conversationID: nil, question: "Q", answer: "R", notes: allNotes)
        let plain = try stores.favorites.mark(messageID: UUID(), conversationID: nil, question: "Q", answer: "R")

        // SearXNG injoignable ne dit rien dans un favori : il n'est pas gardé.
        let expected = StoredAnswerNotes(
            uncitableSourceNumbers: [2], answeredWithoutSearch: true, answeredOffline: true,
            answeredWithoutReadableSource: true, sourcesMayBeOffTopic: true
        )
        #expect(fromMessage.answerNotes == expected)
        #expect(direct.answerNotes == expected)
        #expect(plain.answerNotes == StoredAnswerNotes())

        let fresh = ModelContext(stores.favorites.container)
        let favorites = try fresh.fetch(FetchDescriptor<StoredFavorite>())
        #expect(favorites.filter { $0.answerNotes == expected }.count == 2)
        let freshPlain = try #require(favorites.first { $0.messageID == plain.messageID })
        #expect(!freshPlain.sourcesMayBeOffTopic && !freshPlain.answeredWithoutSearch)
    }

    @Test("Chaque mention d'un favori se relit seule, depuis un contexte neuf")
    func eachFavoriteFlagIsIndependent() throws {
        let stores = try stores()
        let cases: [(String, StoredAnswerNotes, KeyPath<StoredFavorite, Bool>)] = [
            ("sans recherche", StoredAnswerNotes(answeredWithoutSearch: true), \.answeredWithoutSearch),
            ("hors connexion", StoredAnswerNotes(answeredOffline: true), \.answeredOffline),
            ("sans source lisible", StoredAnswerNotes(answeredWithoutReadableSource: true), \.answeredWithoutReadableSource),
            ("hors sujet", StoredAnswerNotes(sourcesMayBeOffTopic: true), \.sourcesMayBeOffTopic),
        ]
        var ids: [UUID] = []
        for (name, notes, _) in cases {
            let id = UUID()
            ids.append(id)
            try stores.favorites.mark(messageID: id, conversationID: nil, question: name, answer: "R", notes: notes)
        }
        let fresh = ModelContext(stores.favorites.container)
        let favorites = try fresh.fetch(FetchDescriptor<StoredFavorite>())
        for (index, (name, _, keyPath)) in cases.enumerated() {
            let favorite = try #require(favorites.first { $0.messageID == ids[index] })
            #expect(favorite[keyPath: keyPath], "\(name)")
            let others = cases.indices.filter { $0 != index }.map { cases[$0].2 }
            #expect(others.allSatisfy { !favorite[keyPath: $0] }, "\(name) seul")
        }
    }
}

// MARK: - Message du fil

@MainActor
@Suite("Mentions E2b — message du fil")
struct AnswerNotesE2bMessageTests {
    @Test("`storedNotes` et `restore` sont inverses l'un de l'autre, drapeaux E2b compris")
    func storedNotesAndRestoreAreInverse() {
        var message = ChatViewModel.Message(role: .assistant, text: "Texte")
        message.restore(allNotes)
        #expect(message.sourcesMayBeOffTopic && message.searXNGUnreachable)
        #expect(message.storedNotes == allNotes)
        #expect(ChatViewModel.Message(role: .assistant, text: "x").storedNotes == StoredAnswerNotes())
    }

    @Test("Un message relu montre « hors sujet » et masque les boutons médias, comme en direct")
    func restoredSnapshotMatchesTheLiveOne() {
        var message = ChatViewModel.Message(role: .assistant, text: "Texte", sources: offTopic)
        message.restore(StoredAnswerNotes(sourcesMayBeOffTopic: true, searXNGUnreachable: true))
        let snapshot = MessageBubbleView.answerSnapshot(of: message)
        #expect(MessageBubblePresentation.showsOffTopicSources(snapshot))
        #expect(!MessageBubblePresentation.showsMediaSearch(snapshot))
    }

    @Test("Les notes persistées sont celles que `attach` affiche (une seule vérité)")
    func persistedNotesMatchWhatAttachShows() {
        var artifacts = SearchArtifacts(
            sources: offTopic, attachmentSourceCount: 0, widgets: [], images: .notRequested, videos: .notRequested,
            mode: .quick, promptComplexity: .full, citableSourceCount: 1, searchPerformed: true, searchQuery: "q"
        )
        artifacts.webSearchReport = WebSearchChainReport(
            passedOver: [WebSearchSourceFailure(source: .searxng, reason: .searchFailed(.unavailable))], matchesQuestion: false
        )
        var message = ChatViewModel.Message(role: .assistant, text: "Texte")
        message.attach(artifacts)

        #expect(message.sourcesMayBeOffTopic && message.searXNGUnreachable)
        #expect(ChatViewModel.Message.storedNotes(of: artifacts) == message.storedNotes)
    }
}

// MARK: - Détail d'un favori

@MainActor
@Suite("Mentions E2b — détail d'un favori")
struct FavoriteDetailNotesTests {
    private func content(notes: StoredAnswerNotes, sources: [SearXNGSearchResult] = offTopic, answer: String = "Texte[1].") throws -> FavoriteDetailContent {
        let container = try TrivaModelContainer.makeInMemory()
        let store = FavoritesStore(container: container, locale: Locale(identifier: "fr_FR"))
        let favorite = try store.mark(messageID: UUID(), conversationID: nil, question: "Q", answer: answer, sources: sources, notes: notes)
        return FavoritePresentation.detailContent(copying: favorite)
    }

    @Test("Le détail reçoit les mentions copiées au marquage")
    func detailReceivesTheNotes() throws {
        let detail = try content(notes: allNotes)
        #expect(detail.notes.answeredWithoutSearch && detail.notes.answeredOffline)
        #expect(detail.notes.answeredWithoutReadableSource && detail.notes.sourcesMayBeOffTopic)
        #expect(detail.uncitableSourceNumbers == [2])
    }

    @Test("Les trois mentions du bas de réponse : mêmes textes que la bulle, une seule à la fois", arguments: [
        (StoredAnswerNotes(answeredWithoutSearch: true), "Réponse sans recherche", "chat.answerWithoutSearch"),
        (StoredAnswerNotes(answeredOffline: true), "Hors connexion, sans source", "chat.answerOffline"),
        (StoredAnswerNotes(answeredWithoutReadableSource: true), "Réponse sans source lisible", "chat.answerWithoutReadableSource"),
    ])
    func answerNoteTexts(notes: StoredAnswerNotes, label: String, identifier: String) throws {
        let snapshot = FavoritePresentation.answerSnapshot(of: try content(notes: notes, sources: []))
        #expect(MessageBubblePresentation.answerNote(snapshot) == label)
        #expect(MessageBubblePresentation.answerNoteIdentifier(snapshot) == identifier)
    }

    @Test("Hors connexion l'emporte sur « sans recherche », comme dans la bulle")
    func offlineWinsLikeInTheBubble() throws {
        let snapshot = FavoritePresentation.answerSnapshot(
            of: try content(notes: StoredAnswerNotes(answeredWithoutSearch: true, answeredOffline: true), sources: [])
        )
        #expect(MessageBubblePresentation.answerNote(snapshot) == MessageBubblePresentation.answerOfflineLabel)
    }

    @Test("Aucune mention sur un favori ordinaire")
    func plainFavoriteHasNoNote() throws {
        let snapshot = FavoritePresentation.answerSnapshot(of: try content(notes: StoredAnswerNotes(), sources: onTopic))
        #expect(MessageBubblePresentation.answerNote(snapshot) == nil)
        #expect(!MessageBubblePresentation.showsOffTopicSources(snapshot))
    }

    @Test("« Hors sujet » : sous les sources web, jamais pour un favori qui n'a que des fichiers joints")
    func offTopicNeedsWebSources() throws {
        let withWeb = FavoritePresentation.answerSnapshot(of: try content(notes: StoredAnswerNotes(sourcesMayBeOffTopic: true)))
        #expect(MessageBubblePresentation.showsOffTopicSources(withWeb))
        #expect(withWeb.webSourceCount == 1)

        let attachment = SearXNGSearchResult(
            title: "Cours.pdf", url: UploadsSearchResultBuilder.sourceURL(for: UUID()), content: "Extrait",
            imgSrc: nil, thumbnailSrc: nil, thumbnail: nil, author: nil, iframeSrc: nil
        )
        let filesOnly = FavoritePresentation.answerSnapshot(
            of: try content(notes: StoredAnswerNotes(sourcesMayBeOffTopic: true), sources: [attachment])
        )
        #expect(filesOnly.sourceCount == 1 && filesOnly.webSourceCount == 0)
        #expect(!MessageBubblePresentation.showsOffTopicSources(filesOnly))

        let noSource = FavoritePresentation.answerSnapshot(of: try content(notes: StoredAnswerNotes(sourcesMayBeOffTopic: true), sources: []))
        #expect(!MessageBubblePresentation.showsOffTopicSources(noSource))
    }

    @Test("Un favori ancien, sans les champs, se lit sans mention")
    func favoriteWithoutFieldsReadsAsEmpty() throws {
        let favorite = StoredFavorite(messageID: UUID(), conversationID: nil, question: "Q", answer: "R", savedAt: .now)
        #expect(favorite.answerNotes == StoredAnswerNotes())
        let snapshot = FavoritePresentation.answerSnapshot(of: FavoritePresentation.detailContent(copying: favorite))
        #expect(MessageBubblePresentation.answerNote(snapshot) == nil)
    }
}

// MARK: - De bout en bout

@MainActor
@Suite("ChatViewModel — drapeaux E2b persistés, restaurés, copiés dans le favori")
struct AnswerNotesE2bRestorationTests {
    private func viewModel(
        history: ChatHistoryStore, favorites: FavoritesStore? = nil, aiProvider: ChainAIProvider, chain: WebSearchChain?
    ) -> ChatViewModel {
        let manager = FailoverManager(client: ChainSearXNGClient(shouldFail: true), instances: [ChainFixtures.instance])
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
                    configuration: inputs.configuration, scrapeService: E2bNoScrape(),
                    sourceRanker: SourceRanker(
                        relevanceScorer: E2bConstantScorer(), duplicateScorer: E2bNoDuplicateScorer(), languageIdentifier: E2bUnknownLanguage()
                    ),
                    widgets: [], webSearchChain: inputs.webSearchChain
                )
            },
            generateSuggestions: { _, _ in [] }
        )
    }

    private func reopened(_ original: ChatViewModel, in store: ChatHistoryStore) throws -> ChatViewModel.Message {
        let id = try #require(original.currentConversationID)
        let fresh = viewModel(history: store, aiProvider: ChainAIProvider(), chain: nil)
        #expect(fresh.loadConversation(id: id))
        return try #require(fresh.messages.last)
    }

    @Test("Sources hors sujet : « Sources probablement hors sujet » revient à la réouverture")
    func offTopicSurvivesReopening() async throws {
        let store = ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))
        let chain = WebSearchChain(searxng: Provider(kind: .searxng, outcome: .results(offTopic)), openSourceProviders: { _ in [] })
        let model = viewModel(history: store, aiProvider: ChainAIProvider(classification: classification(skipSearch: false), answer: "Un club[1]."), chain: chain)

        await model.send(query: question)

        let live = try #require(model.messages.last)
        #expect(live.sourcesMayBeOffTopic)
        let restored = try reopened(model, in: store)
        #expect(restored.sourcesMayBeOffTopic)
        #expect(!restored.searXNGUnreachable)
        #expect(MessageBubblePresentation.showsOffTopicSources(MessageBubbleView.answerSnapshot(of: restored)))
    }

    @Test("SearXNG injoignable : les boutons images et vidéos restent masqués à la réouverture")
    func unreachableSurvivesReopening() async throws {
        let store = ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))
        let searxng = Provider(kind: .searxng, outcome: .failure(WebSearchError.unavailable))
        let wikipedia = Provider(kind: .wikipedia, outcome: .results(onTopic))
        let chain = WebSearchChain(searxng: searxng, openSourceProviders: { _ in [wikipedia] })
        let model = viewModel(history: store, aiProvider: ChainAIProvider(classification: classification(skipSearch: false), answer: "330 mètres[1]."), chain: chain)

        await model.send(query: question)

        let live = try #require(model.messages.last)
        #expect(live.searXNGUnreachable)
        #expect(!MessageBubblePresentation.showsMediaSearch(MessageBubbleView.answerSnapshot(of: live)))
        let restored = try reopened(model, in: store)
        #expect(restored.searXNGUnreachable)
        #expect(!restored.sourcesMayBeOffTopic)
        #expect(!MessageBubblePresentation.showsMediaSearch(MessageBubbleView.answerSnapshot(of: restored)))
    }

    @Test("Réponse normale : ni « hors sujet » ni SearXNG injoignable, avant comme après réouverture")
    func plainAnswerKeepsBothFlagsOff() async throws {
        let store = ChatHistoryStore(container: try TrivaModelContainer.makeInMemory(), locale: Locale(identifier: "fr_FR"))
        let chain = WebSearchChain(searxng: Provider(kind: .searxng, outcome: .results(onTopic)), openSourceProviders: { _ in [] })
        let model = viewModel(history: store, aiProvider: ChainAIProvider(classification: classification(skipSearch: false), answer: "330 mètres[1]."), chain: chain)

        await model.send(query: question)

        let restored = try reopened(model, in: store)
        #expect(!restored.sourcesMayBeOffTopic && !restored.searXNGUnreachable)
    }

    @Test("L'étoile du chat copie les mentions dans le favori, que le détail affiche")
    func chatStarCopiesTheNotesIntoTheFavorite() async throws {
        let container = try TrivaModelContainer.makeInMemory()
        let locale = Locale(identifier: "fr_FR")
        let store = ChatHistoryStore(container: container, locale: locale)
        let favorites = FavoritesStore(container: container, locale: locale)
        let chain = WebSearchChain(searxng: Provider(kind: .searxng, outcome: .results(offTopic)), openSourceProviders: { _ in [] })
        let model = viewModel(
            history: store, favorites: favorites,
            aiProvider: ChainAIProvider(classification: classification(skipSearch: false), answer: "Un club[1]."), chain: chain
        )

        await model.send(query: question)
        model.toggleFavorite(messageID: try #require(model.messages.last).id)

        let favorite = try #require(try favorites.favorites().first)
        #expect(favorite.sourcesMayBeOffTopic)
        let snapshot = FavoritePresentation.answerSnapshot(of: FavoritePresentation.detailContent(copying: favorite))
        #expect(MessageBubblePresentation.showsOffTopicSources(snapshot))
    }

    @Test("L'étoile d'une réponse sans recherche copie « Réponse sans recherche » dans le favori")
    func withoutSearchNoteReachesTheFavorite() async throws {
        let container = try TrivaModelContainer.makeInMemory()
        let locale = Locale(identifier: "fr_FR")
        let store = ChatHistoryStore(container: container, locale: locale)
        let favorites = FavoritesStore(container: container, locale: locale)
        let model = viewModel(
            history: store, favorites: favorites,
            aiProvider: ChainAIProvider(classification: classification(skipSearch: true), answer: "Feuilles rousses au vent."), chain: nil
        )

        await model.send(query: "Écris un haïku sur l'automne.")
        model.toggleFavorite(messageID: try #require(model.messages.last).id)

        let favorite = try #require(try favorites.favorites().first)
        let snapshot = FavoritePresentation.answerSnapshot(of: FavoritePresentation.detailContent(copying: favorite))
        #expect(MessageBubblePresentation.answerNote(snapshot) == MessageBubblePresentation.answerWithoutSearchLabel)
    }
}
