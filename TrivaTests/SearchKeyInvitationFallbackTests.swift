//
//  SearchKeyInvitationFallbackTests.swift
//  TrivaTests
//
//  Created by ben podrojsky on 11/11/2026.
//

import Foundation
import Testing
@testable import Triva

// Invitation discrète à ajouter une clé APRÈS une réponse réussie venue d'une source de secours
// (mission A2, décision 7 de Ben) : SearXNG n'a rien donné, une autre source a répondu. Logique
// pure, puis le vrai `ChatViewModel`. Aucun réseau, aucun modèle système.

private typealias Provider = ScriptedWebSearchProvider

private func setAside(_ source: WebSearchSourceKind) -> WebSearchSourceFailure {
    WebSearchSourceFailure(source: source, reason: .noUsableAnswer)
}

private func failed(_ source: WebSearchSourceKind, _ error: WebSearchError = .unavailable) -> WebSearchSourceFailure {
    WebSearchSourceFailure(source: source, reason: .searchFailed(error))
}

// MARK: - Logique pure

@Suite("SearchKeyInvitation — après une réponse de secours")
struct SearchKeyInvitationAfterFallbackTests {
    private func invitation(
        _ passedOver: [WebSearchSourceFailure],
        retained: WebSearchSourceKind?,
        webSourceCount: Int = 3
    ) -> SearchKeyInvitation? {
        SearchKeyInvitation(
            afterFallback: WebSearchChainReport(passedOver: passedOver),
            retainedSource: retained,
            webSourceCount: webSourceCount
        )
    }

    @Test("SearXNG sans réponse utile ou en échec, une source ouverte répond : inviter à ajouter une clé", arguments: [
        setAside(.searxng), failed(.searxng),
    ])
    func searXNGPassedOverInvitesToAddAKey(searxng: WebSearchSourceFailure) throws {
        let result = try #require(invitation([searxng], retained: .wikipedia))

        #expect(result.actionTitle == SearchKeyInvitation.addKeyTitle)
        #expect(result.explanation == SearchKeyInvitation.addKeyExplanation)
    }

    @Test("Repli jusqu'à la recherche cloud ou Marginalia : même invitation", arguments: [
        WebSearchSourceKind.cloudProviderWebSearch, .marginalia, .openAlex, .arXiv,
    ])
    func everyFallbackSourceInvites(retained: WebSearchSourceKind) {
        #expect(invitation([setAside(.searxng)], retained: retained)?.actionTitle == SearchKeyInvitation.addKeyTitle)
    }

    @Test("SearXNG a fourni les résultats : rien à proposer")
    func searXNGAnswerDoesNotInvite() {
        #expect(invitation([], retained: .searxng) == nil)
    }

    @Test("Aucune source web affichée (toutes à vide) : la question n'a pas de résultat, pas d'invitation")
    func noWebSourceDoesNotInvite() {
        #expect(invitation([setAside(.searxng)], retained: .wikipedia, webSourceCount: 0) == nil)
    }

    @Test("Sans recherche web (source inconnue) : pas d'invitation")
    func noRetainedSourceDoesNotInvite() {
        #expect(invitation([setAside(.searxng)], retained: nil) == nil)
    }

    @Test("Réponse retenue d'une clé personnelle : en ajouter une n'y changerait rien", arguments: [
        WebSearchSourceKind.braveSearch, .tavily,
    ])
    func keyAnswerDoesNotInvite(retained: WebSearchSourceKind) {
        #expect(invitation([setAside(.searxng)], retained: retained) == nil)
    }

    @Test("Une clé qui a répondu sans rien de retenu fonctionne : pas d'invitation")
    func aWorkingKeyDoesNotInvite() {
        #expect(invitation([setAside(.braveSearch), setAside(.searxng)], retained: .wikipedia) == nil)
    }

    @Test("Une clé en échec (refusée, quota, illisible) : on nomme le service et on propose de la vérifier", arguments: [
        (failed(.braveSearch, .unauthorized), "Brave Search"),
        (failed(.tavily, .rateLimited), "Tavily"),
        (WebSearchSourceFailure(source: .tavily, reason: .keychainUnreadable), "Tavily"),
    ])
    func aFailingKeyAsksToCheckIt(key: WebSearchSourceFailure, name: String) throws {
        let result = try #require(invitation([key, setAside(.searxng)], retained: .wikipedia))

        #expect(result.actionTitle == SearchKeyInvitation.checkKeysTitle)
        #expect(result.explanation == "Ta clé \(name) n'a pas fonctionné.")
    }

    @Test("Une clé en échec et une qui marche : seule la clé en échec est nommée")
    func onlyTheFailingKeyIsNamed() throws {
        let result = try #require(invitation(
            [setAside(.braveSearch), failed(.tavily, .unauthorized), setAside(.searxng)], retained: .wikipedia
        ))

        #expect(result.actionTitle == SearchKeyInvitation.checkKeysTitle)
        #expect(result.explanation == "Ta clé Tavily n'a pas fonctionné.")
    }
}

// MARK: - ChatViewModel de bout en bout

/// Provider IA factice : classification vide (repli sûr, recherche web générale), puis une réponse
/// ou, s'il y en a une, `answerError` au moment de rédiger.
private final class FallbackInvitationAIProvider: AIGenerating {
    /// Modifiable entre deux envois (mission A5) : une panne, puis le retour à la normale.
    var answerError: (any Error)?

    init(answerError: (any Error)? = nil) {
        self.answerError = answerError
    }

    func generate(prompt: String) async throws -> String {
        if prompt.contains("<user_query>") { return "" }
        if let answerError { throw answerError }
        return "La tour Eiffel mesure 330 mètres [1]."
    }
}

@MainActor
@Suite("ChatViewModel — invitation après une réponse de secours")
struct ChatViewModelFallbackInvitationTests {
    private static let question = "Quelle est la hauteur de la tour Eiffel ?"
    private static let onTopic = [ChainFixtures.result(
        "Tour Eiffel", url: "https://fr.wikipedia.org/wiki/Tour_Eiffel", content: "La tour Eiffel mesure 330 mètres de hauteur."
    )]
    private static let offTopic = [ChainFixtures.result(
        "Paris Saint-Germain", url: "https://fr.wikipedia.org/wiki/Paris_Saint-Germain", content: "Club de football."
    )]

    private func chain(searxng: Provider.Outcome, wikipedia: Provider.Outcome) -> WebSearchChain {
        let searxngStep = Provider(kind: .searxng, outcome: searxng)
        let wikipediaStep = Provider(kind: .wikipedia, outcome: wikipedia)
        return WebSearchChain(searxng: searxngStep, openSourceProviders: { _ in [wikipediaStep] })
    }

    private func viewModel(
        aiProvider: FallbackInvitationAIProvider = FallbackInvitationAIProvider(),
        chains: [WebSearchChain]
    ) -> ChatViewModel {
        let manager = FailoverManager(client: ChainSearXNGClient(shouldFail: true), instances: [ChainFixtures.instance])
        var remaining = chains
        return ChatViewModel(
            resolveProvider: { aiProvider },
            resolveFailoverManager: { manager },
            resolveWebSearchChain: { _ in remaining.isEmpty ? nil : remaining.removeFirst() },
            readResponseMode: { .quick },
            generateSuggestions: { _, _ in [] }
        )
    }

    @Test("SearXNG hors sujet, Wikipédia répond : réponse normale, sans bandeau, avec l'invitation")
    func offTopicSearXNGThenWikipediaInvites() async throws {
        let model = viewModel(chains: [chain(searxng: .results(Self.offTopic), wikipedia: .results(Self.onTopic))])

        await model.send(query: Self.question)

        let answer = try #require(model.messages.last)
        #expect(answer.status == .completed)
        #expect(answer.webSourceKind == .wikipedia)
        #expect(model.errorDescription == nil)
        #expect(model.searchKeyInvitation?.actionTitle == SearchKeyInvitation.addKeyTitle)
    }

    @Test("SearXNG en échec, Wikipédia répond : même invitation")
    func failingSearXNGThenWikipediaInvites() async {
        let model = viewModel(chains: [chain(searxng: .failure(WebSearchError.unavailable), wikipedia: .results(Self.onTopic))])

        await model.send(query: Self.question)

        #expect(model.errorDescription == nil)
        #expect(model.searchKeyInvitation?.actionTitle == SearchKeyInvitation.addKeyTitle)
    }

    @Test("SearXNG répond sur le sujet : aucune invitation")
    func searXNGAnswerDoesNotInvite() async {
        let model = viewModel(chains: [chain(searxng: .results(Self.onTopic), wikipedia: .results(Self.onTopic))])

        await model.send(query: Self.question)

        #expect(model.searchKeyInvitation == nil)
    }

    @Test("Toutes les sources à vide : pas d'invitation (décision D3 de RI1b)")
    func allEmptyDoesNotInvite() async {
        let model = viewModel(chains: [chain(searxng: .results([]), wikipedia: .results([]))])

        await model.send(query: Self.question)

        #expect(model.errorDescription == nil)
        #expect(model.searchKeyInvitation == nil)
    }

    @Test("Moteur IA en panne après une réponse de secours : bandeau, l'invitation disparaît")
    func engineFailureRemovesTheInvitation() async {
        let aiProvider = FallbackInvitationAIProvider(answerError: ChatViewModelError.emptyResponse)
        let model = viewModel(
            aiProvider: aiProvider,
            chains: [chain(searxng: .results(Self.offTopic), wikipedia: .results(Self.onTopic))]
        )

        await model.send(query: Self.question)

        #expect(model.errorDescription != nil)
        #expect(model.searchKeyInvitation == nil)
    }

    @Test("L'envoi suivant, servi par SearXNG, efface l'invitation")
    func theNextSendClearsTheInvitation() async {
        let model = viewModel(chains: [
            chain(searxng: .results(Self.offTopic), wikipedia: .results(Self.onTopic)),
            chain(searxng: .results(Self.onTopic), wikipedia: .results(Self.onTopic)),
        ])

        await model.send(query: Self.question)
        #expect(model.searchKeyInvitation != nil)

        await model.send(query: "Et la hauteur de la tour Eiffel avec son antenne ?")

        #expect(model.searchKeyInvitation == nil)
    }

    // MARK: - Une seule fois par conversation (mission A5)

    private static let secondQuestion = "Et la hauteur de la tour Eiffel avec son antenne ?"

    @Test("Deux réponses de secours d'affilée : l'invitation n'est faite qu'à la première")
    func invitesOnlyOncePerConversation() async {
        let model = viewModel(chains: [
            chain(searxng: .failure(WebSearchError.unavailable), wikipedia: .results(Self.onTopic)),
            chain(searxng: .failure(WebSearchError.unavailable), wikipedia: .results(Self.onTopic)),
            chain(searxng: .failure(WebSearchError.unavailable), wikipedia: .results(Self.onTopic)),
        ])

        await model.send(query: Self.question)
        #expect(model.searchKeyInvitation?.actionTitle == SearchKeyInvitation.addKeyTitle)

        await model.send(query: Self.secondQuestion)
        #expect(model.searchKeyInvitation == nil)
        #expect(model.messages.last?.webSourceKind == .wikipedia)

        await model.send(query: Self.question)
        #expect(model.searchKeyInvitation == nil)
    }

    @Test("Une nouvelle conversation peut de nouveau recevoir l'invitation")
    func newConversationInvitesAgain() async {
        let model = viewModel(chains: [
            chain(searxng: .failure(WebSearchError.unavailable), wikipedia: .results(Self.onTopic)),
            chain(searxng: .failure(WebSearchError.unavailable), wikipedia: .results(Self.onTopic)),
        ])

        await model.send(query: Self.question)
        #expect(model.searchKeyInvitation != nil)

        model.startNewConversation()
        await model.send(query: Self.question)

        #expect(model.searchKeyInvitation?.actionTitle == SearchKeyInvitation.addKeyTitle)
    }

    @Test("Un échange servi par SearXNG entre deux replis ne consomme pas l'invitation")
    func aSearXNGAnswerDoesNotConsumeTheInvitation() async {
        let model = viewModel(chains: [
            chain(searxng: .results(Self.onTopic), wikipedia: .results(Self.onTopic)),
            chain(searxng: .failure(WebSearchError.unavailable), wikipedia: .results(Self.onTopic)),
        ])

        await model.send(query: Self.question)
        #expect(model.searchKeyInvitation == nil)

        await model.send(query: Self.secondQuestion)
        #expect(model.searchKeyInvitation?.actionTitle == SearchKeyInvitation.addKeyTitle)
    }

    @Test("Invitation effacée par une panne du moteur IA avant d'avoir été vue : la suivante est permise")
    func anInvitationLostToAnEngineFailureIsStillOwed() async throws {
        let aiProvider = FallbackInvitationAIProvider(answerError: ChatViewModelError.emptyResponse)
        let model = viewModel(
            aiProvider: aiProvider,
            chains: [
                chain(searxng: .failure(WebSearchError.unavailable), wikipedia: .results(Self.onTopic)),
                chain(searxng: .failure(WebSearchError.unavailable), wikipedia: .results(Self.onTopic)),
            ]
        )

        await model.send(query: Self.question)
        #expect(model.searchKeyInvitation == nil)
        #expect(model.errorDescription != nil)

        aiProvider.answerError = nil
        await model.send(query: Self.secondQuestion)

        #expect(model.errorDescription == nil)
        #expect(model.searchKeyInvitation?.actionTitle == SearchKeyInvitation.addKeyTitle)
    }
}
