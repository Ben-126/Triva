//
//  AnswerNotesTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import Testing
@testable import Triva

// Mentions sous la réponse (mission A2) : « Réponse sans recherche » (décision 3 de Ben) et
// « Sources probablement hors sujet » (décision 6). Logique pure d'abord, puis le vrai
// `SearchOrchestrator` et le vrai `ChatViewModel`. Aucun réseau, aucun modèle système.

private typealias Provider = ScriptedWebSearchProvider

/// JSON valide pour `QueryClassifier.parse` : recherche web générale, ou rien (`skipSearch`).
private func classification(skipSearch: Bool, followUp: String) -> String {
    """
    {"classification":{"skipSearch":\(skipSearch),"personalSearch":false,"academicSearch":false,\
    "discussionSearch":false,"showWeatherWidget":false,"showStockWidget":false,\
    "showCalculationWidget":false},"standaloneFollowUp":"\(followUp)"}
    """
}

private let tourEiffelQuestion = "Quelle est la hauteur de la tour Eiffel ?"
private let onTopic = [ChainFixtures.result(
    "Tour Eiffel", url: "https://fr.wikipedia.org/wiki/Tour_Eiffel", content: "La tour Eiffel mesure 330 mètres de hauteur."
)]
private let offTopic = [ChainFixtures.result(
    "Paris Saint-Germain", url: "https://fr.wikipedia.org/wiki/Paris_Saint-Germain", content: "Club de football."
)]

// MARK: - Salutations

@Suite("SmallTalk — un message de pure politesse")
struct SmallTalkTests {
    @Test("Salutations, remerciements, au revoir, « ça va ? » : reconnus", arguments: [
        "Bonjour !", "bonjour", "Salut Triva", "Coucou tout le monde", "Hello", "Hi there", "Bonsoir",
        "Merci beaucoup !", "Merci pour ta réponse", "Ça va ?", "Comment vas-tu ?", "Bonne journée",
        "Au revoir", "À bientôt !", "Good morning", "D'accord, merci",
    ])
    func greetingsAreRecognised(message: String) {
        #expect(SmallTalk.isGreeting(message))
    }

    @Test("Une question précédée d'un bonjour, une demande d'écriture ou un calcul : pas une salutation", arguments: [
        "Bonjour, quelle est la hauteur de la tour Eiffel ?", "Écris un haïku sur l'automne.", "Combien font 1284 × 37 ?",
        "Merci de m'expliquer la photosynthèse", "", "   ", "?!",
    ])
    func otherMessagesAreNotGreetings(message: String) {
        #expect(!SmallTalk.isGreeting(message))
    }

    @Test("Au-delà de huit mots, même tous polis, c'est une phrase")
    func longMessagesAreNotGreetings() {
        #expect(!SmallTalk.isGreeting("bonjour bonjour bonjour bonjour bonjour bonjour bonjour bonjour bonjour"))
    }

    @Test("Salutation pure : bonjour, salut, merci…", arguments: [
        "Bonjour !", "bonjour", "Salut Triva", "Coucou tout le monde", "Hello", "Bonsoir", "Merci beaucoup !", "Thank you",
    ])
    func bareSalutationsAreRecognised(message: String) {
        #expect(SmallTalk.isBareSalutation(message))
    }

    /// Polis, mais aussi des suites de conversation : elles gardent l'historique.
    @Test("Pas une salutation pure : « Ok », « D'accord », « Super », « Ça va ? », une question", arguments: [
        "Ok", "D'accord", "Super", "Parfait, merci", "Ça va ?", "Oui", "Continue",
        "Bonjour, quelle est la hauteur de la tour Eiffel ?", "", "?!",
    ])
    func followUpsAreNotBareSalutations(message: String) {
        #expect(!SmallTalk.isBareSalutation(message))
    }
}

// MARK: - Règle de la mention

@Suite("SearchArtifacts.answersWithoutSearch — quand dire « Réponse sans recherche »")
struct AnswersWithoutSearchTests {
    @Test("Aucune recherche, aucun widget, pas une salutation : la mention")
    func noSearchNeedsTheMention() {
        #expect(SearchArtifacts.answersWithoutSearch(question: "Écris un haïku sur l'automne.", searchPerformed: false, widgetCount: 0))
    }

    @Test("Une recherche a eu lieu (web ou fichiers joints) : pas de mention")
    func searchMeansNoMention() {
        #expect(!SearchArtifacts.answersWithoutSearch(question: tourEiffelQuestion, searchPerformed: true, widgetCount: 0))
    }

    @Test("Un widget a répondu (calcul, météo) : pas de mention, la donnée vient d'un service")
    func widgetMeansNoMention() {
        #expect(!SearchArtifacts.answersWithoutSearch(question: "Combien font 1284 × 37 ?", searchPerformed: false, widgetCount: 1))
    }

    @Test("Une salutation : pas de mention, elle serait du bruit")
    func greetingMeansNoMention() {
        #expect(!SearchArtifacts.answersWithoutSearch(question: "Bonjour !", searchPerformed: false, widgetCount: 0))
    }
}

// MARK: - Présentation dans la bulle

@MainActor
@Suite("MessageBubblePresentation — mentions de la mission A2")
struct AnswerNotesPresentationTests {
    private typealias Snapshot = MessageBubblePresentation.AnswerSnapshot

    @Test("« Réponse sans recherche » sous un texte terminé ou en cours")
    func answerWithoutSearchShowsUnderText() {
        let completed = Snapshot(state: .completed, hasBody: true, answeredWithoutSearch: true)
        let streaming = Snapshot(state: .streaming, hasBody: true, answeredWithoutSearch: true)
        let summaryOnly = Snapshot(state: .completed, hasTLDR: true, answeredWithoutSearch: true)

        #expect(MessageBubblePresentation.showsAnswerWithoutSearch(completed))
        #expect(MessageBubblePresentation.showsAnswerWithoutSearch(streaming))
        #expect(MessageBubblePresentation.showsAnswerWithoutSearch(summaryOnly))
        #expect(MessageBubblePresentation.answerWithoutSearchLabel == "Réponse sans recherche")
    }

    @Test("Pas de mention sans texte, sur l'état « Aucune source fiable », ni sans le drapeau")
    func answerWithoutSearchNeedsAnAnswer() {
        #expect(!MessageBubblePresentation.showsAnswerWithoutSearch(Snapshot(state: .streaming, answeredWithoutSearch: true)))
        #expect(!MessageBubblePresentation.showsAnswerWithoutSearch(
            Snapshot(state: .noReliableSources, hasBody: true, answeredWithoutSearch: true)
        ))
        #expect(!MessageBubblePresentation.showsAnswerWithoutSearch(Snapshot(state: .completed, hasBody: true)))
    }

    @Test("« Sources probablement hors sujet » seulement avec au moins une source web affichée")
    func offTopicNoteNeedsWebSources() {
        let flagged = Snapshot(state: .completed, hasBody: true, sourceCount: 2, webSourceCount: 2, sourcesMayBeOffTopic: true)
        let attachmentsOnly = Snapshot(state: .completed, hasBody: true, sourceCount: 2, webSourceCount: 0, sourcesMayBeOffTopic: true)
        let unflagged = Snapshot(state: .completed, hasBody: true, sourceCount: 2, webSourceCount: 2)

        #expect(MessageBubblePresentation.showsOffTopicSources(flagged))
        #expect(!MessageBubblePresentation.showsOffTopicSources(attachmentsOnly))
        #expect(!MessageBubblePresentation.showsOffTopicSources(unflagged))
        #expect(MessageBubblePresentation.offTopicSourcesLabel == "Sources probablement hors sujet")
    }

    @Test("Le résumé d'un message reprend ses deux drapeaux")
    func snapshotCarriesTheFlags() {
        var message = ChatViewModel.Message(role: .assistant, text: "Texte", sources: onTopic)
        message.answeredWithoutSearch = true
        message.sourcesMayBeOffTopic = true

        let snapshot = MessageBubbleView.answerSnapshot(of: message)

        #expect(snapshot.answeredWithoutSearch)
        #expect(snapshot.sourcesMayBeOffTopic)
    }
}

// MARK: - Message

@MainActor
@Suite("ChatViewModel.Message — drapeaux de la mission A2")
struct AnswerNotesMessageTests {
    private func artifacts(answeredWithoutSearch: Bool, matchesQuestion: Bool) -> SearchArtifacts {
        SearchArtifacts(
            sources: onTopic, attachmentSourceCount: 0, widgets: [],
            images: .notRequested, videos: .notRequested, mode: .quick, promptComplexity: .full,
            citableSourceCount: 1, searchPerformed: !answeredWithoutSearch, searchQuery: "q",
            webSearchReport: WebSearchChainReport(matchesQuestion: matchesQuestion),
            answeredWithoutSearch: answeredWithoutSearch
        )
    }

    @Test("`attach` recopie les deux drapeaux des artefacts")
    func attachCopiesTheFlags() {
        var message = ChatViewModel.Message(role: .assistant)

        message.attach(artifacts(answeredWithoutSearch: true, matchesQuestion: false))
        #expect(message.answeredWithoutSearch)
        #expect(message.sourcesMayBeOffTopic)

        message.attach(artifacts(answeredWithoutSearch: false, matchesQuestion: true))
        #expect(!message.answeredWithoutSearch)
        #expect(!message.sourcesMayBeOffTopic)
    }

    @Test("« Aucune source fiable » efface les deux drapeaux, comme le reste")
    func noReliableSourcesClearsTheFlags() {
        var message = ChatViewModel.Message(role: .assistant)
        message.attach(artifacts(answeredWithoutSearch: true, matchesQuestion: false))

        message.markNoReliableSources(searchQuery: "q", at: Date(timeIntervalSince1970: 0))

        #expect(!message.answeredWithoutSearch)
        #expect(!message.sourcesMayBeOffTopic)
    }
}

// MARK: - Orchestrateur et chat, de bout en bout

/// Classement neutre : ordre d'arrivée, aucun embedding système.
private struct NotesConstantScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0.5, count: candidates.count)
    }
}

private struct NotesNeverDuplicateScorer: TextSimilarityScoring {
    func similarities(of reference: String, against candidates: [String]) async -> [Double] {
        Array(repeating: 0, count: candidates.count)
    }
}

private struct NotesUnknownLanguage: TextLanguageIdentifying {
    func dominantLanguage(of text: String) -> String? { nil }
}

private struct NotesNoScrape: ScrapeServing {
    func scrape(url: String) async -> ScrapedPage {
        ScrapedPage(url: url, title: "", content: "", succeeded: false)
    }
}

@MainActor
@Suite("SearchOrchestrator — mentions et rappel hors sujet")
struct AnswerNotesOrchestratorTests {
    private static let offTopicReminder = "aucun document ci-dessus ne reprend les mots de la question"

    private func orchestrator(aiProvider: ChainAIProvider, chain: WebSearchChain?) -> SearchOrchestrator {
        SearchOrchestrator(
            failoverManager: FailoverManager(client: ChainSearXNGClient(shouldFail: true), instances: [ChainFixtures.instance]),
            aiProvider: aiProvider,
            responseMode: .quick,
            configuration: .cloud,
            scrapeService: NotesNoScrape(),
            sourceRanker: SourceRanker(
                relevanceScorer: NotesConstantScorer(),
                duplicateScorer: NotesNeverDuplicateScorer(),
                languageIdentifier: NotesUnknownLanguage()
            ),
            widgets: [],
            webSearchChain: chain
        )
    }

    private func chain(searxng: [SearXNGSearchResult], wikipedia: [SearXNGSearchResult]) -> WebSearchChain {
        let searxngStep = Provider(kind: .searxng, outcome: .results(searxng))
        let wikipediaStep = Provider(kind: .wikipedia, outcome: .results(wikipedia))
        return WebSearchChain(searxng: searxngStep, openSourceProviders: { _ in [wikipediaStep] })
    }

    private func writerPrompt(of aiProvider: ChainAIProvider) -> String? {
        aiProvider.receivedPrompts.last { !$0.contains("<user_query>") }
    }

    @Test("Sans recherche, une demande d'écriture porte la mention")
    func writingWithoutSearchIsFlagged() async throws {
        let aiProvider = ChainAIProvider(classification: classification(skipSearch: true, followUp: "Haïku sur l'automne"))

        let result = try await orchestrator(aiProvider: aiProvider, chain: nil).answer(query: "Écris un haïku sur l'automne.")

        #expect(!result.artifacts.searchPerformed)
        #expect(result.artifacts.answeredWithoutSearch)
    }

    @Test("Sans recherche, « Bonjour » n'en porte pas, même reformulé par le classifieur")
    func greetingIsNotFlagged() async throws {
        let aiProvider = ChainAIProvider(classification: classification(skipSearch: true, followUp: "Comment puis-je vous aider ?"))

        let result = try await orchestrator(aiProvider: aiProvider, chain: nil).answer(query: "Bonjour !")

        #expect(!result.artifacts.answeredWithoutSearch)
    }

    /// Vu sur iPad et iPhone : « Bonjour ! » envoyé après un haïku recevait le haïku recopié. Sans
    /// le haïku dans son prompt, le rédacteur ne peut plus le recopier ; la reformulation, qui
    /// ramenait parfois la demande précédente, reste dehors aussi. Une reprise demandée garde tout.
    @Test("Salutation pure : ni historique ni reformulation pour le rédacteur ; une traduction garde les deux")
    func bareSalutationReachesTheWriterAlone() async throws {
        let haiku = "La pluie tombe doucement."
        let history = [
            ClassifierChatMessage(role: .user, content: "Écris un haïku sur la pluie"),
            ClassifierChatMessage(role: .assistant, content: haiku),
        ]
        let greeting = ChainAIProvider(classification: classification(skipSearch: true, followUp: "Écris un haïku sur la pluie"))
        _ = try await orchestrator(aiProvider: greeting, chain: nil).answer(query: "Bonjour !", chatHistory: history)
        let greetingPrompt = try #require(writerPrompt(of: greeting))
        #expect(!greetingPrompt.contains(haiku))
        #expect(!greetingPrompt.contains("Question reformulée"))

        let translation = ChainAIProvider(classification: classification(skipSearch: true, followUp: "Traduis le haïku en anglais"))
        _ = try await orchestrator(aiProvider: translation, chain: nil).answer(query: "Traduis ta réponse en anglais", chatHistory: history)
        let translationPrompt = try #require(writerPrompt(of: translation))
        #expect(translationPrompt.contains(haiku))
        #expect(translationPrompt.contains("Question reformulée d'après la conversation : Traduis le haïku en anglais"))
    }

    @Test("Recherche web sur le sujet : ni mention, ni rappel hors sujet dans le prompt")
    func onTopicSearchHasNoNote() async throws {
        let aiProvider = ChainAIProvider()

        let result = try await orchestrator(aiProvider: aiProvider, chain: chain(searxng: onTopic, wikipedia: []))
            .answer(query: tourEiffelQuestion)

        #expect(!result.artifacts.answeredWithoutSearch)
        #expect(result.artifacts.webSearchReport == WebSearchChainReport())
        let prompt = try #require(writerPrompt(of: aiProvider))
        #expect(!prompt.contains(Self.offTopicReminder))
    }

    @Test("Rien sur le sujet : le constat remonte aux artefacts, le prompt prévient et donne le refus exact")
    func offTopicSourcesReachTheArtifactsAndThePrompt() async throws {
        let aiProvider = ChainAIProvider()

        let result = try await orchestrator(aiProvider: aiProvider, chain: chain(searxng: offTopic, wikipedia: offTopic))
            .answer(query: tourEiffelQuestion)

        #expect(!result.artifacts.webSearchReport.matchesQuestion)
        #expect(result.artifacts.webSourceKind == .searxng)
        let prompt = try #require(writerPrompt(of: aiProvider))
        #expect(prompt.contains(Self.offTopicReminder))
        #expect(prompt.contains(PromptTemplates.noRelevantInformationAnswer))
    }
}

@MainActor
@Suite("ChatViewModel — mentions de la mission A2 de bout en bout")
struct AnswerNotesViewModelTests {
    private func viewModel(aiProvider: ChainAIProvider, chain: WebSearchChain?) -> ChatViewModel {
        let manager = FailoverManager(client: ChainSearXNGClient(shouldFail: true), instances: [ChainFixtures.instance])
        return ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { manager },
            resolveWebSearchChain: { _ in chain },
            readResponseMode: { .quick },
            generateSuggestions: { _, _ in [] }
        )
    }

    @Test("Un haïku sans recherche : le message porte la mention, la bulle l'affiche")
    func haikuShowsTheMention() async throws {
        let aiProvider = ChainAIProvider(
            classification: classification(skipSearch: true, followUp: "Haïku sur l'automne"),
            answer: "Feuilles rousses au vent."
        )
        let model = viewModel(aiProvider: aiProvider, chain: nil)

        await model.send(query: "Écris un haïku sur l'automne.")

        let answer = try #require(model.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.answeredWithoutSearch)
        #expect(MessageBubblePresentation.showsAnswerWithoutSearch(MessageBubbleView.answerSnapshot(of: answer)))
    }

    @Test("Sources hors sujet : le message le note, la bulle l'affiche sous les sources")
    func offTopicSourcesAreShown() async throws {
        let searxng = Provider(kind: .searxng, outcome: .results(offTopic))
        let model = viewModel(aiProvider: ChainAIProvider(), chain: WebSearchChain(searxng: searxng, openSourceProviders: { _ in [] }))

        await model.send(query: tourEiffelQuestion)

        let answer = try #require(model.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.sourcesMayBeOffTopic)
        #expect(!answer.answeredWithoutSearch)
        #expect(MessageBubblePresentation.showsOffTopicSources(MessageBubbleView.answerSnapshot(of: answer)))
    }
}
